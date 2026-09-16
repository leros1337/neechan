import Foundation
import Testing
@testable import NeechanTestSupport

@Suite("Fixture loader")
struct FixtureLoaderTests {
    @Test("every declared fixture exists in the bundle", arguments: Fixture.allCases)
    func loadsEveryFixture(_ fixture: Fixture) throws {
        let data = try FixtureLoader.data(fixture)
        #expect(!data.isEmpty, "\(fixture.rawValue) is empty")
    }

    @Test("every JSON fixture parses", arguments: Fixture.allCases.filter(\.isJSON))
    func fixturesAreValidJSON(_ fixture: Fixture) throws {
        _ = try FixtureLoader.json(fixture)
    }

    @Test("a missing fixture reports the file name")
    func missingFixtureDescribesItself() {
        let error = FixtureLoader.MissingFixtureError(name: "nope.json")
        #expect(error.description.contains("nope.json"))
        #expect(error.description.contains("record-fixtures.sh"))
    }

    @Test("the comment corpus is non-trivial and carries raw HTML")
    func commentCorpusIsUsable() throws {
        let samples = try FixtureLoader.commentSamples()
        #expect(samples.count >= 20)
        #expect(samples.allSatisfy { $0.num > 0 })
        #expect(samples.contains { $0.comment.contains("<") })
    }

    @Test("the proof-of-work fixture carries a solved challenge")
    func powFixtureIsSolved() throws {
        struct PoWCase: Decodable {
            struct Challenge: Decodable {
                let hash: String
                let limit: Int
                let template: String
            }
            let challenge: Challenge
            let expectedAnswer: Int?
        }
        let powCase = try FixtureLoader.decode(PoWCase.self, from: .powCase)
        #expect(powCase.challenge.template.contains("%d"))
        #expect(powCase.challenge.limit > 0)
        #expect(powCase.challenge.hash.count == 128)
        #expect(powCase.expectedAnswer != nil, "recorded challenge was never solved")
    }
}
