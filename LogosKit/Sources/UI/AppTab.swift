/// The four tabs of the shell. There's no separate Search tab: search lives in Library.
public enum AppTab: Hashable, CaseIterable, Sendable {
    case inProgress
    case library
    case series
    case downloaded

    public var title: String {
        switch self {
        case .inProgress: "In Progress"
        case .library: "Library"
        case .series: "Series"
        case .downloaded: "Downloaded"
        }
    }

    var systemImage: String {
        switch self {
        case .inProgress: "play.circle"
        case .library: "books.vertical"
        case .series: "square.stack"
        case .downloaded: "arrow.down.circle"
        }
    }
}
