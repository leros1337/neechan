import Foundation
import NeechanCore
import Testing

/// Whether a thread's subject is worth drawing above its own text.
///
/// 2ch fills `subject` with the beginning of the opening post when the poster
/// left it empty, so the card drew the same words twice: in bold as a title and
/// again underneath as the preview.
@Suite("Thread subjects")
struct ThreadSubjectTests {
    @Test("a subject the site made from the comment is recognised")
    func echoedSubject() {
        #expect(ThreadSubject.echoes(
            "ГОЛОВА ДАЙ ДЕНЕГ Итак, этот тред является Храмом ГОЛОВЫ. Я расскажу не...",
            comment: "ГОЛОВА ДАЙ ДЕНЕГ\nИтак, этот тред является Храмом ГОЛОВЫ. Я расскажу немного о себе."
        ))
    }

    @Test("a subject the poster wrote is kept")
    func realSubject() {
        #expect(ThreadSubject.echoes(
            "Тред о погоде",
            comment: "Сегодня в Москве дождь, и это надолго."
        ) == false)
    }

    @Test("the ellipsis the site truncates with is not part of the comparison")
    func truncationIsIgnored() {
        #expect(ThreadSubject.echoes("Начало поста…", comment: "Начало поста, которое продолжается"))
        #expect(ThreadSubject.echoes("Начало поста...", comment: "Начало поста, которое продолжается"))
    }

    @Test("line breaks and runs of spaces are not a difference")
    func whitespaceIsNormalised() {
        #expect(ThreadSubject.echoes("один два три", comment: "Один  два\n\nтри четыре"))
    }

    @Test("an empty subject or an empty comment echoes nothing")
    func emptyInputs() {
        #expect(ThreadSubject.echoes("", comment: "что-то") == false)
        #expect(ThreadSubject.echoes("что-то", comment: "") == false)
    }
}
