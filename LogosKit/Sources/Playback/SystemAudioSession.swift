import AVFoundation
import Foundation

/// The real ``AudioSession``: the shared `AVAudioSession`'s iOS 27 lifecycle messages (`didBecomeInactive` for an
/// interruption, `resumptionRecommendation` for its end), route changes and media-services resets. It only reports;
/// the ``Player`` engine owns the rules.
public final class SystemAudioSession: AudioSession {
    public var onEvent: ((AudioSessionEvent) -> Void)?

    private var messageTokens: [NotificationCenter.ObservationToken] = []
    private var notificationObservers: [any NSObjectProtocol] = []

    public init() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        messageTokens = [
            center.addObserver(of: session, for: .didBecomeInactive) { [weak self] message in
                self?.becameInactive(message.deactivationResult)
            },
            center.addObserver(of: session, for: .resumptionRecommendation) { [weak self] message in
                self?.onEvent?(.interruptionEnded(shouldResume: message.recommendation == .shouldResume))
            },
        ]
        notificationObservers = [
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) {
                @Sendable [weak self] notification in
                let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                    .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
                MainActor.assumeIsolated { self?.routeChanged(reason) }
            },
            center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main
            ) { @Sendable [weak self] _ in
                MainActor.assumeIsolated { self?.onEvent?(.mediaServicesReset) }
            },
        ]
    }

    isolated deinit {
        let center = NotificationCenter.default
        for token in messageTokens { center.removeObserver(token) }
        for observer in notificationObservers { center.removeObserver(observer) }
    }

    private func becameInactive(_ result: AVAudioSession.DeactivationResult) {
        switch result {
        case .systemInterruption(let context):
            log.notice("Audio session interrupted (reason \(context.reason.rawValue, privacy: .public))")
            onEvent?(.interrupted)
        case .appDeactivated:
            break
        @unknown default:
            // Some other way the session went inactive: audio stopped, so treat it like an interruption.
            onEvent?(.interrupted)
        }
    }

    private func routeChanged(_ reason: AVAudioSession.RouteChangeReason?) {
        switch reason {
        case .oldDeviceUnavailable:
            log.notice("Audio route lost")
            onEvent?(.routeLost)
        case .newDeviceAvailable:
            log.notice("Audio route added")
            onEvent?(.routeAdded)
        default:
            break
        }
    }
}
