import CoreFoundation
import Foundation

/// One preference, as a backup holds it.
///
/// Written as the bare JSON value rather than wrapped in its case, so the file
/// stays something a person can read: `"interface.textScale": 1.3`.
public enum PreferenceValue: Sendable, Equatable, Codable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    /// A map of strings, which is how the per-board layouts are kept.
    case strings([String: String])

    /// What `UserDefaults` handed back, if it is something a backup can carry.
    ///
    /// A `Bool` comes back as an `NSNumber`, and so does every number, so the
    /// boolean has to be told apart by its Core Foundation type: read as a
    /// number it would turn `true` into `1`, which `bool(forKey:)` still reads,
    /// but the file would say something else.
    init?(propertyList value: Any) {
        switch value {
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number) {
                self = .double(number.doubleValue)
            } else {
                self = .int(number.intValue)
            }
        case let string as String:
            self = .string(string)
        case let map as [String: String]:
            self = .strings(map)
        case let map as [String: Any]:
            let strings = map.compactMapValues { $0 as? String }
            guard strings.count == map.count else { return nil }
            self = .strings(strings)
        default:
            return nil
        }
    }

    /// The value to hand `UserDefaults`.
    var propertyList: Any {
        switch self {
        case .bool(let value): value
        case .int(let value): value
        case .double(let value): value
        case .string(let value): value
        case .strings(let value): value
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            self = .strings(try container.decode([String: String].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .strings(let value): try container.encode(value)
        }
    }
}

/// The preferences a backup carries.
public struct PreferencesBackup: Sendable, Equatable {
    /// Every carried preference that was set, by its defaults key.
    public var values: [String: PreferenceValue]
    /// The carried preferences left at their defaults, which an import resets.
    public var unset: [String]

    public init(values: [String: PreferenceValue] = [:], unset: [String] = []) {
        self.values = values
        self.unset = unset
    }
}
