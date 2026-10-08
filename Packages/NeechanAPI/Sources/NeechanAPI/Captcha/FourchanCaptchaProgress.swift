import Foundation

/// Where the reader has got to in a 4chan puzzle.
///
/// The site's slider runs from 0 to the number of pictures: at 0 it shows the
/// step's instructions, and at any other position the picture there. Next is
/// refused on the instructions, records the picture's position counted from
/// zero, and puts the slider back at the start of the next step. The answer is
/// those positions written one after another, which is what the site's own
/// script sends as `t-response`.
///
/// Only the reader moves it. Nothing here chooses a position, suggests one or
/// starts anywhere but the instructions, and nothing should.
public struct FourchanCaptchaProgress: Sendable, Hashable {
    /// What the slider is resting on.
    public enum Shown: Sendable, Hashable {
        /// Instructions written as words, with the picture they ask about.
        case prompt(FourchanCaptchaMarkup)
        /// Base64 PNG: the instructions as a picture, or one of the pictures.
        case image(String)
    }

    public let steps: [FourchanCaptcha.Step]
    public private(set) var index = 0
    /// 0 for the instructions; otherwise the picture at `selection - 1`.
    public private(set) var selection = 0
    private var answers: [Int] = []

    public init(steps: [FourchanCaptcha.Step]) {
        self.steps = steps
    }

    public var isDone: Bool { index >= steps.count }

    public var currentStep: FourchanCaptcha.Step? {
        steps.indices.contains(index) ? steps[index] : nil
    }

    /// How far the slider goes on this step.
    public var itemCount: Int { currentStep?.items.count ?? 0 }

    /// The step being answered, counted from one, as the site's button does.
    public var position: Int { min(index + 1, steps.count) }
    public var count: Int { steps.count }

    public var canAdvance: Bool { !isDone && selection >= 1 }

    public var shown: Shown? {
        guard let step = currentStep else { return nil }
        if selection >= 1 { return .image(step.items[selection - 1]) }
        if let image = step.image { return .image(image) }
        return step.prompt.map(Shown.prompt)
    }

    /// The reader's own slider, and nothing else, calls this.
    public mutating func select(_ value: Int) {
        guard !isDone else { return }
        selection = min(max(0, value), itemCount)
    }

    public mutating func next() {
        guard canAdvance else { return }
        answers.append(selection - 1)
        index += 1
        selection = 0
    }

    public var response: String {
        answers.map(String.init).joined()
    }
}
