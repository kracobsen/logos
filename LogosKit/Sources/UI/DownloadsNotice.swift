import SwiftUI

/// Why waiting Downloads aren't moving.
public enum DownloadsNotice: Sendable, Hashable {
    /// Cellular isn't allowed and there's no (unconstrained) Wi-Fi.
    case waitingForWiFi
    /// The free-space check failed: the queue is paused until there's room.
    case notEnoughStorage

    public var text: String {
        switch self {
        case .waitingForWiFi: "Waiting for Wi-Fi"
        case .notEnoughStorage: "Not enough storage"
        }
    }

    var systemImage: String {
        switch self {
        case .waitingForWiFi: "wifi.slash"
        case .notEnoughStorage: "externaldrive.badge.exclamationmark"
        }
    }

    /// A line under the notice saying what makes it go away.
    var explanation: String {
        switch self {
        case .waitingForWiFi: "Downloads continue on Wi-Fi. You can allow cellular in Settings."
        case .notEnoughStorage: "Free up space on your iPhone; Downloads continue when you come back to Logos."
        }
    }
}

/// The notice as a row, shown above the queue.
struct DownloadsNoticeView: View {
    let notice: DownloadsNotice

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(notice.text, systemImage: notice.systemImage)
                .font(.headline)
            Text(notice.explanation)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
