import SwiftUI

/// Which tap answers a finished save.
///
/// Kept apart from the view because a haptic cannot be observed from a test,
/// while the choice between the two can.
enum SaveHaptic {
    static func feedback(for outcome: MediaTransferController.VideoSaveOutcome?) -> SensoryFeedback? {
        guard let outcome else { return nil }
        // `.success` is the light double tap, which is the small confirmation a
        // finished save wants. `.error` is unmistakably different, so a save
        // that did not work is recognisable without looking at the screen.
        return outcome.succeeded ? .success : .error
    }
}
