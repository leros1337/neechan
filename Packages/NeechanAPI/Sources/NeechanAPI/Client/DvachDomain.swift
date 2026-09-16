import Foundation
import Synchronization

/// The 2ch domain the app talks to.
///
/// 2ch serves byte-identical JSON from several mirrors. Neechan deliberately
/// exposes only these two. Every model stores server paths *relative* to the
/// domain, so switching domains needs no data migration.
public enum DvachDomain: String, CaseIterable, Sendable, Codable {
    case org = "2ch.org"
    case life = "2ch.life"

    public static let `default` = DvachDomain.org

    /// Scheme + host, with no trailing slash.
    public var baseURL: URL {
        URL(string: "https://\(rawValue)")!
    }

    /// Resolves a server-relative path (`/b/src/123/456.jpg`) against this domain.
    ///
    /// Absolute URLs are returned unchanged, so a value that already carries a
    /// host (an external link in a post) survives the round trip.
    public func url(forPath path: String) -> URL? {
        if let absolute = URL(string: path), absolute.scheme != nil {
            return absolute
        }
        return URL(string: path, relativeTo: baseURL)?.absoluteURL
    }
}

/// Supplies the current domain to long-lived collaborators (the HTTP client,
/// image loaders) so a change in settings takes effect without rebuilding them.
///
/// The client reads this from its own actor's executor, so a provider must be
/// callable from any isolation. Use `DomainHolder` rather than closing over
/// main-actor state.
public typealias DomainProvider = @Sendable () -> DvachDomain

/// A mutable domain that can be read from any isolation.
///
/// Settings live on the main actor, but the HTTP client reads the domain from
/// its own executor on every request. A lock is the only correct bridge: an
/// assumption of main-actor isolation would trap the moment a request runs.
public final class DomainHolder: Sendable {
    private let storage: Mutex<DvachDomain>

    public init(_ initial: DvachDomain = .default) {
        storage = Mutex(initial)
    }

    /// The domain requests should use right now.
    public var value: DvachDomain {
        storage.withLock { $0 }
    }

    public func set(_ domain: DvachDomain) {
        storage.withLock { $0 = domain }
    }

    /// A provider bound to this holder.
    public var provider: DomainProvider {
        { [self] in value }
    }
}
