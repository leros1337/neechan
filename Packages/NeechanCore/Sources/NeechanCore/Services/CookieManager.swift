import Foundation
import NeechanAPI

/// A cookie the site set, as a value the settings screen can list.
public struct CookieRecord: Sendable, Hashable, Identifiable {
    public let name: String
    public let value: String
    public let domain: String
    public let expiresAt: Date?

    public var id: String { "\(domain)|\(name)" }

    /// Cookies that carry identity rather than bookkeeping, so the reader can
    /// see at a glance which ones matter.
    public var isSignificant: Bool {
        ["passcode_auth", "usercode_auth", "cf_clearance", "ageallow"].contains(name)
    }
}

/// Reads and clears the cookies the site set.
public actor CookieManager {
    private let storage: HTTPCookieStorage
    private let domain: DomainProvider

    public init(storage: HTTPCookieStorage = .shared, domain: @escaping DomainProvider) {
        self.storage = storage
        self.domain = domain
    }

    /// Every cookie held for the mirrors this app talks to.
    public func cookies() -> [CookieRecord] {
        DvachDomain.allCases
            .flatMap { storage.cookies(for: $0.baseURL) ?? [] }
            .map {
                CookieRecord(
                    name: $0.name,
                    value: $0.value,
                    domain: $0.domain,
                    expiresAt: $0.expiresDate
                )
            }
            .sorted { $0.name < $1.name }
    }

    public func remove(name: String, domain cookieDomain: String) {
        for cookie in storage.cookies ?? []
        where cookie.name == name && cookie.domain == cookieDomain {
            storage.deleteCookie(cookie)
        }
    }

    /// Clears everything the site set, which signs the reader out of a passcode.
    public func removeAll() {
        for domain in DvachDomain.allCases {
            for cookie in storage.cookies(for: domain.baseURL) ?? [] {
                storage.deleteCookie(cookie)
            }
        }
    }

    /// Copies a cookie onto the mirror now in use.
    ///
    /// Cookies are per host, so switching mirrors would otherwise sign the
    /// reader out of their passcode and lose the browser check they just passed.
    public func mirror(names: Set<String>, to target: DvachDomain) {
        for source in DvachDomain.allCases where source != target {
            for cookie in storage.cookies(for: source.baseURL) ?? []
            where names.contains(cookie.name) {
                var properties = cookie.properties ?? [:]
                properties[.domain] = target.baseURL.host()
                properties[.originURL] = target.baseURL
                if let copy = HTTPCookie(properties: properties) {
                    storage.setCookie(copy)
                }
            }
        }
    }

    /// The cookies worth carrying across a mirror switch.
    public static let portableCookieNames: Set<String> = ["passcode_auth", "ageallow"]

    /// Takes the cookies a web view collected, which is how a browser check is
    /// passed and handed back to the app's own requests.
    public func adopt(_ cookies: [HTTPCookie]) {
        for cookie in cookies {
            storage.setCookie(cookie)
        }
    }
}
