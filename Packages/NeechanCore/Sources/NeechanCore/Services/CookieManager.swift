import Foundation
import NeechanAPI

/// A cookie the site set, as a value the settings screen can list.
public struct CookieRecord: Sendable, Hashable, Identifiable {
    public let name: String
    public let value: String
    public let domain: String
    public let expiresAt: Date?
    /// Which imageboard's jar it came from, so the settings screen can group
    /// them. A reader must be able to see and clear both sites' cookies from
    /// either site, or the screen quietly hides half of what is stored.
    public let site: Imageboard

    public var id: String { "\(domain)|\(name)" }

    /// Cookies that carry identity rather than bookkeeping, so the reader can
    /// see at a glance which ones matter.
    public var isSignificant: Bool {
        ["passcode_auth", "usercode_auth", "cf_clearance", "ageallow", "4chan_pass"].contains(name)
    }
}

/// Reads and clears the cookies the sites set.
public actor CookieManager {
    private let storage: HTTPCookieStorage
    private let site: SiteProvider

    public init(storage: HTTPCookieStorage = .shared, site: @escaping SiteProvider) {
        self.storage = storage
        self.site = site
    }

    /// Every cookie held for every host this app talks to.
    ///
    /// Deliberately not scoped to the selected site: this backs the screen the
    /// reader clears their session from, and one that showed only half of what
    /// is stored would be worse than useless.
    public func cookies() -> [CookieRecord] {
        Imageboard.allCases
            .flatMap { site in
                site.cookieHosts
                    .flatMap { storage.cookies(for: $0) ?? [] }
                    .map { cookie in
                        CookieRecord(
                            name: cookie.name,
                            value: cookie.value,
                            domain: cookie.domain,
                            expiresAt: cookie.expiresDate,
                            site: site
                        )
                    }
            }
            // One host can appear under two of a site's URLs, and a cookie set
            // on a parent domain is returned for each subdomain it covers.
            .reduce(into: [CookieRecord]()) { unique, record in
                if !unique.contains(where: { $0.id == record.id }) { unique.append(record) }
            }
            .sorted { ($0.site.rawValue, $0.name) < ($1.site.rawValue, $1.name) }
    }

    public func remove(name: String, domain cookieDomain: String) {
        for cookie in storage.cookies ?? []
        where cookie.name == name && cookie.domain == cookieDomain {
            storage.deleteCookie(cookie)
        }
    }

    /// Clears what a site set, which signs the reader out of a passcode.
    ///
    /// - Parameter site: nil clears every imageboard's. The screen that offers
    ///   this says which it means, because clearing the site the reader is not
    ///   looking at is not what they asked for.
    public func removeAll(for site: Imageboard? = nil) {
        let sites = site.map { [$0] } ?? Imageboard.allCases
        for site in sites {
            for host in site.cookieHosts {
                for cookie in storage.cookies(for: host) ?? [] {
                    storage.deleteCookie(cookie)
                }
            }
        }
    }

    /// Copies a cookie onto the mirror now in use.
    ///
    /// Mirrors, not sites. Cookies are per host, so switching mirrors would
    /// otherwise sign the reader out of their passcode and lose the browser
    /// check they just passed — but a passcode belongs to the site that issued
    /// it, and copying one onto another imageboard's host would put a paid
    /// session token in a third party's access logs. Nothing crosses sites.
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
