// Starts a build of an Xcode Cloud workflow on a branch through the App Store Connect API, and optionally waits for it.
// Run it through scripts/release.sh, which checks the git state first and passes the arguments.
//
// Usage: swift start-build.swift <bundle-id> <workflow-name> <branch> [--wait]
// Environment: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (an App Store Connect API key and its .p8 file).

import CryptoKit
import Foundation

struct ReleaseError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: Authentication

func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

/// An ES256 JSON Web Token for the App Store Connect API, valid for 15 minutes (Apple allows 20; the margin covers a
/// Mac clock running ahead).
func makeToken(keyID: String, issuerID: String, keyPEM: String, now: Date = Date()) throws -> String {
    let key = try P256.Signing.PrivateKey(pemRepresentation: keyPEM)
    let issuedAt = Int(now.timeIntervalSince1970)
    let header: [String: Any] = ["alg": "ES256", "kid": keyID, "typ": "JWT"]
    let payload: [String: Any] = [
        "iss": issuerID, "iat": issuedAt, "exp": issuedAt + 15 * 60, "aud": "appstoreconnect-v1",
    ]
    let signingInput = [header, payload]
        .map { base64URL(try! JSONSerialization.data(withJSONObject: $0, options: .sortedKeys)) }
        .joined(separator: ".")
    let signature = try key.signature(for: Data(signingInput.utf8))
    return signingInput + "." + base64URL(signature.rawRepresentation)
}

// MARK: API

/// Signs a fresh token for every request, so polling a build that takes longer than a token lives keeps working.
struct API {
    let keyID: String
    let issuerID: String
    let keyPEM: String
    let base = URL(string: "https://api.appstoreconnect.apple.com")!

    func get(_ path: String, query: [String: String] = [:]) async throws -> [String: Any] {
        var components = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return try await send(URLRequest(url: components.url!))
    }

    func post(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> [String: Any] {
        var request = request
        let token = try makeToken(keyID: keyID, issuerID: issuerID, keyPEM: keyPEM)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            let errors = (json["errors"] as? [[String: Any]] ?? [])
                .map { "\($0["title"] ?? "") \($0["detail"] ?? "")" }
                .joined(separator: "; ")
            let method = request.httpMethod ?? "GET"
            let path = request.url?.path ?? ""
            throw ReleaseError(
                "\(method) \(path) failed with HTTP \(status): \(errors.isEmpty ? "no details" : errors)")
        }
        return json
    }
}

typealias Resource = [String: Any]

func resources(_ json: [String: Any]) -> [Resource] {
    if let list = json["data"] as? [Resource] { return list }
    if let one = json["data"] as? Resource { return [one] }
    return []
}

func resourceID(_ resource: Resource) -> String { resource["id"] as? String ?? "" }

func attribute(_ resource: Resource, _ name: String) -> Any? {
    (resource["attributes"] as? [String: Any])?[name]
}

// MARK: Main

let arguments = Array(CommandLine.arguments.dropFirst())
let positional = arguments.filter { !$0.hasPrefix("--") }
let wait = arguments.contains("--wait")
guard positional.count == 3 else {
    let usage = "usage: start-build.swift <bundle-id> <workflow-name> <branch> [--wait]\n"
    FileHandle.standardError.write(Data(usage.utf8))
    exit(2)
}
let (bundleID, workflowName, branch) = (positional[0], positional[1], positional[2])

func environment(_ name: String) throws -> String {
    guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
        throw ReleaseError("\(name) is not set; see docs/releasing.md")
    }
    return value
}

func run() async throws {
    let keyID = try environment("ASC_KEY_ID")
    let issuerID = try environment("ASC_ISSUER_ID")
    let keyPath = try environment("ASC_KEY_PATH")
    guard let keyPEM = try? String(contentsOfFile: keyPath, encoding: .utf8) else {
        throw ReleaseError("can't read the API key at \(keyPath)")
    }
    let api = API(keyID: keyID, issuerID: issuerID, keyPEM: keyPEM)
    _ = try makeToken(keyID: keyID, issuerID: issuerID, keyPEM: keyPEM)  // Fail early on a malformed key.

    let apps = try await api.get("/v1/apps", query: ["filter[bundleId]": bundleID, "fields[apps]": "bundleId"])
    guard let app = resources(apps).first(where: { attribute($0, "bundleId") as? String == bundleID }) else {
        throw ReleaseError("no app with bundle ID \(bundleID) in App Store Connect")
    }

    let product = try await api.get("/v1/apps/\(resourceID(app))/ciProduct")
    guard let productID = resources(product).first.map(resourceID) else {
        throw ReleaseError("the app \(bundleID) has no Xcode Cloud product")
    }

    let workflows = try await api.get(
        "/v1/ciProducts/\(productID)/workflows", query: ["fields[ciWorkflows]": "name,isEnabled", "limit": "200"])
    guard let workflow = resources(workflows).first(where: { attribute($0, "name") as? String == workflowName }) else {
        let names = resources(workflows).compactMap { attribute($0, "name") as? String }
        throw ReleaseError(
            "no Xcode Cloud workflow named \"\(workflowName)\" (found: \(names.joined(separator: ", ")))")
    }
    if attribute(workflow, "isEnabled") as? Bool == false {
        throw ReleaseError("the workflow \"\(workflowName)\" is disabled in App Store Connect")
    }

    let repository = try await api.get("/v1/ciWorkflows/\(resourceID(workflow))/repository")
    guard let repositoryID = resources(repository).first.map(resourceID) else {
        throw ReleaseError("the workflow \"\(workflowName)\" has no repository")
    }
    let references = try await api.get(
        "/v1/scmRepositories/\(repositoryID)/gitReferences", query: ["limit": "200"])
    guard
        let reference = resources(references).first(where: {
            attribute($0, "canonicalName") as? String == "refs/heads/\(branch)"
                && attribute($0, "isDeleted") as? Bool != true
        })
    else {
        throw ReleaseError("Xcode Cloud doesn't know the branch \(branch)")
    }

    let started = try await api.post(
        "/v1/ciBuildRuns",
        body: [
            "data": [
                "type": "ciBuildRuns",
                "relationships": [
                    "workflow": ["data": ["type": "ciWorkflows", "id": resourceID(workflow)]],
                    "sourceBranchOrTag": ["data": ["type": "scmGitReferences", "id": resourceID(reference)]],
                ],
            ]
        ])
    guard let buildRun = resources(started).first else { throw ReleaseError("Xcode Cloud returned no build run") }
    let number = attribute(buildRun, "number").map { "\($0)" } ?? "?"
    print("Started Xcode Cloud build \(number) of \"\(workflowName)\" on \(branch).")

    guard wait else {
        print("Follow it in Xcode (Report navigator → Cloud) or in App Store Connect (the app's Xcode Cloud tab).")
        return
    }
    var lastProgress = ""
    while true {
        try await Task.sleep(for: .seconds(30))
        // A failed poll doesn't stop the build, so report it and try again.
        let polled: [String: Any]
        do {
            polled = try await api.get("/v1/ciBuildRuns/\(resourceID(buildRun))")
        } catch {
            print("Build \(number): couldn't check (\(error)); trying again")
            continue
        }
        guard let run = resources(polled).first else { continue }
        let progress = attribute(run, "executionProgress") as? String ?? "?"
        if progress != lastProgress {
            print("Build \(number): \(progress.lowercased())")
            lastProgress = progress
        }
        if progress == "COMPLETE" {
            let status = attribute(run, "completionStatus") as? String ?? "?"
            print("Build \(number) finished: \(status.lowercased())")
            guard status == "SUCCEEDED" else { throw ReleaseError("build \(number) did not succeed") }
            print("It shows up in TestFlight once App Store Connect has processed it.")
            return
        }
    }
}

do {
    try await run()
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
