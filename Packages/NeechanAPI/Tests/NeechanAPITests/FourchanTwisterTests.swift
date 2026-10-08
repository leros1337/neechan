import Foundation
import NeechanTestSupport
import Testing
@testable import NeechanAPI

/// Reading what 4chan's captcha frame hands its page.
///
/// The frame posts one object, which the site's own script reads field by
/// field in a fixed order. These pin that order, because it decides what the
/// reader is shown: a wait comes before a refusal, and either comes before a
/// puzzle. Nothing here answers a step.
@Suite("4chan captcha, as the frame sends it")
struct FourchanTwisterTests {
    private func captcha(_ json: String) throws -> FourchanCaptcha {
        try JSONDecoder().decode(FourchanCaptcha.self, from: Data(json.utf8))
    }

    @Test("a puzzle is read into its steps, its lifetime and its cooldown")
    func steps() throws {
        let read = try captcha(#"""
        {"challenge":"abc","ttl":120,"cd":30,"ticket":"t1",
         "tasks":[{"str":"Pick the one","items":["AA","BB","CC"]},{"img":"PP","items":["DD","EE"]}]}
        """#)
        #expect(read.challenge == "abc")
        #expect(read.ttl == 120)
        #expect(read.cooldown == 30)
        #expect(read.ticket == .keep("t1"))
        #expect(read.steps.count == 2)
        #expect(read.steps[0].text == "Pick the one")
        #expect(read.steps[0].image == nil)
        #expect(read.steps[0].items == ["AA", "BB", "CC"])
        #expect(read.steps[1].image == "PP")
        #expect(read.outcome == .steps(challenge: "abc", steps: read.steps))
    }

    /// `false` is the site's way of saying the stored ticket is no good.
    @Test("a ticket of false means the stored one is to be thrown away")
    func ticketDiscarded() throws {
        #expect(try captcha(#"{"ticket":false,"error":"x"}"#).ticket == .discard)
        #expect(try captcha(#"{"error":"x"}"#).ticket == nil)
        // An empty string carries nothing to keep, and is not a reason to
        // throw away one that works either.
        #expect(try captcha(#"{"ticket":"","error":"x"}"#).ticket == nil)
    }

    @Test("a refusal keeps the site's words and its cooldown")
    func refused() throws {
        let read = try captcha(#"{"error":"You have to wait a while before doing this again.","cd":300}"#)
        #expect(read.cooldown == 300)
        #expect(read.outcome == .refused("You have to wait a while before doing this again."))
    }

    /// The site checks for a wait before it looks at an error, so a reply
    /// carrying both is a wait.
    @Test("a wait is read before a refusal, as the site reads it")
    func waitBeforeRefusal() throws {
        let read = try captcha(#"{"pcd":95,"pcd_msg":"Please wait.","error":"no","cd":10}"#)
        #expect(read.ticketWait == 95)
        #expect(read.outcome == .waiting(seconds: 95, message: "Please wait."))
    }

    @Test("a wait with no message of its own still says so")
    func waitWithoutMessage() throws {
        #expect(try captcha(#"{"pcd":60}"#).outcome == .waiting(seconds: 60, message: nil))
    }

    /// And a further check comes before both.
    @Test("a ticket captcha is read before anything else the site checks")
    func ticketCaptchaFirst() throws {
        let read = try captcha(#"{"mpcd":1,"sitekey":"key","pcd":20,"error":"no","challenge":"c"}"#)
        #expect(read.outcome == .ticketCaptcha(siteKey: "key"))
        #expect(try captcha(#"{"mpcd":true,"sitekey":"key"}"#).outcome == .ticketCaptcha(siteKey: "key"))
        #expect(try captcha(#"{"mpcd":0,"challenge":"c"}"#).outcome == .notRequired(challenge: "c"))
    }

    /// A challenge with nothing to do is still a challenge: the site sends it
    /// back with an empty answer, so it has to be kept.
    @Test("a challenge with no steps needs no answer, but is still sent back")
    func notRequired() throws {
        #expect(try captcha(#"{"challenge":"noop","ttl":120}"#).outcome == .notRequired(challenge: "noop"))
        #expect(try captcha(#"{"challenge":"c","tasks":[]}"#).outcome == .notRequired(challenge: "c"))
    }

    /// The April 2026 variant, only ever served to a page that asks for it.
    @Test("the extended variant is recognised rather than half-drawn")
    func extended() throws {
        let read = try captcha(#"{"challenge":"c","ttl":120,"extTask":{"mode":2,"str":"x"}}"#)
        #expect(read.hasExtendedTask)
        #expect(read.outcome == .extended)
    }

    @Test("nothing usable is said to be unreadable")
    func unreadable() throws {
        #expect(try captcha("{}").outcome == .unreadable)
        #expect(try captcha(#"{"cd":30}"#).outcome == .unreadable)
    }

    /// Being strict costs the reader the whole feature and tells them only that
    /// something was unreadable, so every number is taken as it comes.
    @Test("a number that arrives in another form is still read")
    func numbersAreTolerated() throws {
        #expect(try captcha(#"{"challenge":"a","ttl":"120"}"#).ttl == 120)
        #expect(try captcha(#"{"challenge":"a","ttl":119.6}"#).ttl == 120)
        #expect(try captcha(#"{"error":"slow down","cd":27.5}"#).cooldown == 28)
        #expect(try captcha(#"{"pcd":"45"}"#).ticketWait == 45)
    }

    /// One malformed item must not cost the reader the whole step.
    @Test("an item that is not a picture is skipped")
    func badItemsAreSkipped() throws {
        let read = try captcha(#"{"challenge":"c","tasks":[{"str":"s","items":["AA",3,null,"BB"]}]}"#)
        #expect(read.steps.first?.items == ["AA", "BB"])
    }

    @Test("a step with nothing to pick from is not a step")
    func emptyStepsAreDropped() throws {
        let read = try captcha(#"{"challenge":"c","tasks":[{"str":"s","items":[]},{"str":"t","items":["AA"]}]}"#)
        #expect(read.steps.map(\.text) == ["t"])
    }

    @Test("every synthesized reply reads as the case it stands for")
    func fixtures() throws {
        func outcome(_ fixture: Fixture) throws -> FourchanCaptcha.Outcome {
            try FixtureLoader.decode(FourchanCaptcha.self, from: fixture).outcome
        }
        guard case .steps = try outcome(.fourchanTwisterTasksSmall) else {
            Issue.record("the small puzzle should be steps")
            return
        }
        guard case .refused = try outcome(.fourchanTwisterRefused) else {
            Issue.record("the refusal should be refused")
            return
        }
        guard case .waiting = try outcome(.fourchanTwisterTicketWait) else {
            Issue.record("the ticket wait should be waiting")
            return
        }
        guard case .ticketCaptcha = try outcome(.fourchanTwisterTicketCaptcha) else {
            Issue.record("the ticket captcha should ask for one")
            return
        }
        guard case .notRequired = try outcome(.fourchanTwisterNoop) else {
            Issue.record("the noop should need nothing")
            return
        }
        #expect(try outcome(.fourchanTwisterExtended) == .extended)
        #expect(
            try FixtureLoader.decode(FourchanCaptcha.self, from: .fourchanTwisterTicketRevoked).ticket
                == .discard
        )
    }
}

/// Stepping through a puzzle, which only the reader ever does.
///
/// These pin the rule the whole feature rests on: nothing is chosen until the
/// reader chooses it. The slider starts on the instructions, Next refuses to
/// move from there, and every pick is put back to the start for the next step.
@Suite("4chan captcha progress")
struct FourchanCaptchaProgressTests {
    private let steps = [
        FourchanCaptcha.Step(text: "first", image: nil, items: ["A", "B", "C"]),
        FourchanCaptcha.Step(text: nil, image: "P", items: ["D", "E"]),
    ]

    @Test("it starts on the instructions, with nothing chosen")
    func startsOnThePrompt() {
        let progress = FourchanCaptchaProgress(steps: steps)
        #expect(progress.index == 0)
        #expect(progress.selection == 0)
        #expect(progress.canAdvance == false)
        #expect(progress.isDone == false)
        #expect(progress.response.isEmpty)
        #expect(progress.shown == .prompt(FourchanCaptchaMarkup(html: "first")))
    }

    @Test("Next does nothing until the reader has moved the slider")
    func nextWaitsForTheReader() {
        var progress = FourchanCaptchaProgress(steps: steps)
        progress.next()
        #expect(progress.index == 0)
        #expect(progress.response.isEmpty)
    }

    @Test("each pick is the picture's position, counted from zero")
    func responseIsPositions() {
        var progress = FourchanCaptchaProgress(steps: steps)
        progress.select(3)
        #expect(progress.shown == .image("C"))
        progress.next()
        #expect(progress.selection == 0, "the next step starts on its instructions too")
        #expect(progress.shown == .image("P"), "a step's own picture is preferred over its words")
        progress.select(1)
        progress.next()
        #expect(progress.isDone)
        #expect(progress.response == "20")
    }

    @Test("the slider cannot go past either end")
    func selectionIsClamped() {
        var progress = FourchanCaptchaProgress(steps: steps)
        progress.select(9)
        #expect(progress.selection == 3)
        progress.select(-4)
        #expect(progress.selection == 0)
    }

    @Test("Next counts the steps as the site's button does")
    func label() {
        var progress = FourchanCaptchaProgress(steps: steps)
        #expect(progress.position == 1)
        #expect(progress.count == 2)
        progress.select(1)
        progress.next()
        #expect(progress.position == 2)
    }

    @Test("once done, nothing further moves")
    func doneIsFinal() {
        var progress = FourchanCaptchaProgress(steps: steps)
        progress.select(1)
        progress.next()
        progress.select(2)
        progress.next()
        let finished = progress
        progress.select(1)
        progress.next()
        #expect(progress == finished)
        #expect(progress.shown == nil)
    }

    @Test("a puzzle with no steps is done from the start")
    func noSteps() {
        let progress = FourchanCaptchaProgress(steps: [])
        #expect(progress.isDone)
        #expect(progress.response.isEmpty)
    }
}
