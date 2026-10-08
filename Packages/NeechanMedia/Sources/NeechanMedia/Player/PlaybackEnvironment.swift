import Foundation
#if canImport(AVFAudio)
import AVFAudio
#endif
#if canImport(UIKit)
import UIKit
#endif

/// The things playing a video does to the rest of the device.
///
/// The idle timer, and the sound: a clip heard out loud stops whatever music
/// another app was playing, and a clip that stops being heard (paused, muted,
/// finished, closed) lets that music carry on. The rules for when are
/// `AudioSessionPolicy`'s; this carries them out.
@MainActor
enum PlaybackEnvironment {
    /// Keeps the screen on, or lets it sleep again.
    static func keepScreenAwake(_ keepAwake: Bool) {
        #if canImport(UIKit) && !os(watchOS)
        UIApplication.shared.isIdleTimerDisabled = keepAwake
        #endif
    }

    /// A player says what its sound amounts to now.
    static func report(_ status: SoundStatus, from player: MediaPlayer) {
        sound.report(status, from: player)
    }

    /// A player has stopped for good.
    static func playerGone(_ id: UUID) {
        sound.playerGone(id)
    }

    /// The app has gone to the background: the sound goes back at once.
    static func appWentToBackground() {
        sound.handBackNow(because: "the app went to the background")
    }

    /// Takes the sound again, if a player is being heard.
    static func claimAudioSession() {
        sound.reclaim()
    }

    /// Hands it back, so whatever the reader was listening to can resume.
    static func releaseAudioSession() {
        sound.handBackNow(because: "asked to")
    }

    private static let sound = SoundCoordinator()
}

/// Holds the policy and does what it says to the shared audio session.
@MainActor
private final class SoundCoordinator {
    /// How long the sound stays this app's after the last clip stops being
    /// heard. Long enough for a swipe in the feed, which pauses as the drag
    /// begins and plays as it settles.
    private static let grace: Duration = .seconds(1)

    private var policy = AudioSessionPolicy<UUID>()
    private var players: [UUID: Entry] = [:]
    private var handBackTask: Task<Void, Never>?
    private var interruptionObserver: NSObjectProtocol?

    private struct Entry {
        weak var player: MediaPlayer?
        var name: String
        var status: SoundStatus
    }

    init() {
        observeInterruptions()
    }

    func report(_ status: SoundStatus, from player: MediaPlayer) {
        let previous = players[player.soundID]?.status
        players[player.soundID] = Entry(player: player, name: player.name, status: status)
        let actions = policy.report(player.soundID, status)
        if status != previous || !actions.isEmpty {
            MediaLog.session.debug(
                """
                [\(player.name, privacy: .public)] \(String(describing: status), privacy: .public)\
                \(Self.describe(actions), privacy: .public)
                """
            )
        }
        apply(actions)
    }

    func playerGone(_ id: UUID) {
        guard let entry = players.removeValue(forKey: id) else { return }
        let actions = policy.playerGone(id)
        MediaLog.session.debug("[\(entry.name, privacy: .public)] gone\(Self.describe(actions), privacy: .public)")
        apply(actions)
    }

    func handBackNow(because reason: String) {
        let actions = policy.handBackNow()
        guard !actions.isEmpty else { return }
        MediaLog.session.debug("\(reason, privacy: .public)\(Self.describe(actions), privacy: .public)")
        apply(actions)
    }

    func reclaim() {
        let actions = policy.reclaim()
        guard !actions.isEmpty else { return }
        MediaLog.session.debug("asked to take it again\(Self.describe(actions), privacy: .public)")
        apply(actions)
    }

    private func graceElapsed(_ token: Int) {
        let actions = policy.graceElapsed(token)
        guard !actions.isEmpty else { return }
        MediaLog.session.debug("nothing heard for a moment\(Self.describe(actions), privacy: .public)")
        apply(actions)
    }

    private func apply(_ actions: [AudioSessionPolicy<UUID>.Action]) {
        for action in actions {
            switch action {
            case .take:
                take()
            case .scheduleHandBack(let token):
                handBackTask?.cancel()
                handBackTask = Task { [weak self] in
                    try? await Task.sleep(for: Self.grace)
                    guard !Task.isCancelled else { return }
                    self?.graceElapsed(token)
                }
            case .cancelHandBack:
                handBackTask?.cancel()
                handBackTask = nil
            case .handBack:
                handBack()
            case .pause(let ids):
                // Each pause is reported back here as silence, which is why
                // this goes through a copy of the list rather than the policy.
                for id in ids {
                    players[id]?.player?.pauseForInterruption()
                }
            }
        }
    }

    private static func describe(_ actions: [AudioSessionPolicy<UUID>.Action]) -> String {
        guard !actions.isEmpty else { return "" }
        let words = actions.map { action -> String in
            switch action {
            case .take: "take"
            case .scheduleHandBack: "hand back in \(grace.seconds)s"
            case .cancelHandBack: "keep"
            case .handBack: "hand back"
            case .pause(let ids): "pause \(ids.count)"
            }
        }
        return ": " + words.joined(separator: ", ")
    }

    // MARK: - The session

    /// The sound to this app alone, which stops other apps' music.
    ///
    /// Done every time a player starts being heard, not only the first: a
    /// clip paused for an interruption, or kept across a trip to the
    /// background, comes back to a session nothing has re-activated, and the
    /// symptom is a picture that moves in silence.
    private func take() {
        #if canImport(AVFAudio) && os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
        } catch {
            MediaLog.session.error("could not set the category to play alone: \(Self.describe(error), privacy: .public)")
        }
        do {
            try session.setActive(true)
            MediaLog.session.debug("took the sound")
        } catch {
            MediaLog.session.error("could not take the sound: \(Self.describe(error), privacy: .public)")
        }
        #endif
    }

    /// Lets other apps carry on.
    ///
    /// The category becomes one that mixes first. A muted clip goes on
    /// running its audio renderer, which may activate the session again by
    /// itself, and a session that mixes then leaves the music playing. A
    /// long-form route policy cannot be combined with mixing, so it goes too.
    ///
    /// Deactivating can be refused as busy while that muted renderer runs.
    /// The log says so if it is.
    private func handBack() {
        #if canImport(AVFAudio) && os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: .mixWithOthers)
        } catch {
            MediaLog.session.error("could not set the category to mix: \(Self.describe(error), privacy: .public)")
        }
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            MediaLog.session.debug("handed the sound back")
        } catch {
            MediaLog.session.error("could not hand the sound back: \(Self.describe(error), privacy: .public)")
        }
        #endif
    }

    private static func describe(_ error: any Error) -> String {
        let error = error as NSError
        return "\(error.domain) \(error.code) \(error.localizedDescription)"
    }

    /// Another app taking the sound pauses whatever was using it.
    private func observeInterruptions() {
        #if canImport(AVFAudio) && os(iOS)
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            let reason = (note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionReason.init(rawValue:))
            MainActor.assumeIsolated {
                self?.interrupted(type: type, reason: reason)
            }
        }
        #endif
    }

    #if canImport(AVFAudio) && os(iOS)
    private func interrupted(
        type: AVAudioSession.InterruptionType?,
        reason: AVAudioSession.InterruptionReason?
    ) {
        let reasonCode = reason.map { String($0.rawValue) } ?? "none"
        guard type == .began else {
            // Ended. A clip paused for it stays paused until the reader plays
            // it again, which is what the system's own player does.
            MediaLog.session.debug("interruption ended, reason \(reasonCode, privacy: .public)")
            return
        }
        let actions = policy.interruptionBegan(becauseAppWasSuspended: reason == .appWasSuspended)
        MediaLog.session.debug(
            "interruption began, reason \(reasonCode, privacy: .public)\(Self.describe(actions), privacy: .public)"
        )
        apply(actions)
    }
    #endif
}
