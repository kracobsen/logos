import Foundation

/// The throwaway audiobookshelf that `scripts/integration-test.sh` starts in Docker and seeds.
///
/// The script passes its address and fixture accounts as `TEST_RUNNER_LOGOS_IT_*` environment variables, which
/// xcodebuild hands to the test process without the prefix. Only a loopback address is accepted, so integration
/// tests can never reach a real Server.
struct IntegrationServer: Sendable {
    enum ConfigurationError: Error, CustomStringConvertible {
        case notConfigured(String)
        case notLoopback(String)

        var description: String {
            switch self {
            case .notConfigured(let name):
                "\(name) is not set; run the integration tests through scripts/integration-test.sh"
            case .notLoopback(let url):
                "\(url) is not a loopback address; integration tests only run against the local Docker Server"
            }
        }
    }

    struct Account: Sendable {
        let username: String
        let password: String
    }

    /// The Server's base URL, e.g. `http://127.0.0.1:13378`.
    let baseURL: URL
    /// The fixture user with local sign-in and access to the fixture Library.
    let user: Account
    /// The root user, for setting up or inspecting state the fixture user can't.
    let admin: Account
    /// The id of the fixture book Library.
    let libraryID: String
    /// An ephemeral session, so no cookies or caches leak between tests or into the Server's refresh-cookie flow.
    let session: URLSession

    static var isConfigured: Bool {
        ProcessInfo.processInfo.environment["LOGOS_IT_SERVER_URL"] != nil
    }

    static func current() throws -> IntegrationServer {
        let environment = ProcessInfo.processInfo.environment
        func value(_ name: String) throws -> String {
            guard let value = environment[name], !value.isEmpty else { throw ConfigurationError.notConfigured(name) }
            return value
        }
        return IntegrationServer(
            baseURL: try loopbackURL(try value("LOGOS_IT_SERVER_URL")),
            user: Account(username: try value("LOGOS_IT_USERNAME"), password: try value("LOGOS_IT_PASSWORD")),
            admin: Account(
                username: try value("LOGOS_IT_ADMIN_USERNAME"),
                password: try value("LOGOS_IT_ADMIN_PASSWORD")
            ),
            libraryID: try value("LOGOS_IT_LIBRARY_ID"),
            session: URLSession(configuration: .ephemeral)
        )
    }

    /// Parses `string` and returns it only if it is an http(s) URL whose host is a loopback address.
    static func loopbackURL(_ string: String) throws -> URL {
        guard
            let components = URLComponents(string: string),
            let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
            let host = components.host?.lowercased(),
            ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host),
            let url = components.url
        else { throw ConfigurationError.notLoopback(string) }
        return url
    }
}
