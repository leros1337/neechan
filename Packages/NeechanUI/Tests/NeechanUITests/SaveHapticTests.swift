import Foundation
import SwiftUI
import Testing
@testable import NeechanUI

/// Which tap answers a finished save.
///
/// The haptic itself cannot be observed from a test, so the choice is kept as a
/// value and only the choosing is asserted here.
@Suite("Save haptic")
struct SaveHapticTests {
    @Test("nothing saved yet asks for no tap")
    func nothingRecorded() {
        #expect(SaveHaptic.feedback(for: nil) == nil)
    }

    @Test("a saved video asks for the success tap")
    func saved() {
        let outcome = GalleryViewModel.VideoSaveOutcome(succeeded: true)
        #expect(SaveHaptic.feedback(for: outcome) == .success)
    }

    /// A different pattern, so a save that did not work is recognisable without
    /// looking at the screen.
    @Test("a failed save asks for the error tap")
    func failed() {
        let outcome = GalleryViewModel.VideoSaveOutcome(succeeded: false)
        #expect(SaveHaptic.feedback(for: outcome) == .error)
    }

    /// The trigger has to change for the feedback to fire again, so two saves
    /// that ended the same way must not be equal.
    @Test("two saves that ended alike are still two separate events")
    func outcomesAreDistinct() {
        let first = GalleryViewModel.VideoSaveOutcome(succeeded: true)
        let second = GalleryViewModel.VideoSaveOutcome(succeeded: true)
        #expect(first != second)
    }
}
