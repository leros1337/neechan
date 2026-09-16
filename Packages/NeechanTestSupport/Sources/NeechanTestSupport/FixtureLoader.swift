import Foundation

/// Loads recorded fixtures from the package bundle.
public enum FixtureLoader {
    public struct MissingFixtureError: Error, CustomStringConvertible {
        public let name: String
        public var description: String {
            "Fixture '\(name)' is missing from the NeechanTestSupport bundle. "
                + "Re-record with Tools/record-fixtures.sh"
        }
    }

    /// Raw bytes of a fixture.
    public static func data(_ fixture: Fixture) throws -> Data {
        guard let url = Bundle.module.url(
            forResource: fixture.rawValue,
            withExtension: fixture.fileExtension,
            subdirectory: "Fixtures"
        ) else {
            throw MissingFixtureError(name: "\(fixture.rawValue).\(fixture.fileExtension)")
        }
        return try Data(contentsOf: url)
    }

    /// UTF-8 text of a fixture.
    public static func text(_ fixture: Fixture) throws -> String {
        let data = try data(fixture)
        guard let string = String(data: data, encoding: .utf8) else {
            throw MissingFixtureError(name: "\(fixture.rawValue) (not valid UTF-8)")
        }
        return string
    }

    /// Decodes a fixture into `type` using a decoder configured the way
    /// `DvachClient` configures its own (plain keys, no date strategy).
    public static func decode<T: Decodable>(
        _ type: T.Type,
        from fixture: Fixture,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> T {
        try decoder.decode(type, from: data(fixture))
    }

    /// Untyped JSON, for shape assertions in tests.
    public static func json(_ fixture: Fixture) throws -> Any {
        try JSONSerialization.jsonObject(with: data(fixture), options: [.fragmentsAllowed])
    }
}
