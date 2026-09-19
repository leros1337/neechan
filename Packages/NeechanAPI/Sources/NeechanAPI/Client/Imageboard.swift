import Foundation
import Synchronization

/// The imageboard the app is pointed at.
///
/// Orthogonal to `DvachDomain`, which selects between 2ch's own mirrors: those
/// serve byte-identical JSON, while a different imageboard is a different API,
/// a different markup dialect and a different set of things it can do.
///
/// The raw values are persisted — in `UserDefaults` and as the `siteRaw` column
/// on every stored record — so renaming a case orphans the reader's data.
/// `AppShellTests` pins them for exactly that reason.
public enum Imageboard: String, CaseIterable, Sendable, Codable, Identifiable, Hashable {
    case dvach
    case fourchan

    /// Where a fresh install starts.
    ///
    /// Only a starting point: the choice is stored the moment the reader flips
    /// the switch on the board list, so this moves nobody who has already
    /// chosen.
    public static let `default` = Imageboard.fourchan

    public var id: String { rawValue }

    /// The site's own name for itself. Not localized: it is a proper noun.
    public var displayName: String {
        switch self {
        case .dvach: "2ch"
        case .fourchan: "4chan"
        }
    }

    /// Whether a board code may be all digits.
    ///
    /// Without a letter a bare post number reads as a board code, which is why
    /// `BoardCode` rejects one by default. 4chan has `/3/`.
    public var allowsNumericBoardCodes: Bool {
        switch self {
        case .dvach: false
        case .fourchan: true
        }
    }

    /// Hosts whose cookie jars belong to this site.
    ///
    /// Used to enumerate and clear cookies. A site's jar is its own: nothing is
    /// ever copied between two of them.
    public var cookieHosts: [URL] {
        switch self {
        case .dvach:
            DvachDomain.allCases.map(\.baseURL)
        case .fourchan:
            [
                URL(string: "https://4chan.org")!,
                URL(string: "https://4channel.org")!,
                URL(string: "https://boards.4chan.org")!,
                URL(string: "https://sys.4chan.org")!,
            ]
        }
    }

    /// Substrings that identify one of this site's cookie domains.
    ///
    /// A substring rather than host equality because cookie domains come back
    /// with a leading dot (`.2ch.org`), and because `4chan` covers
    /// `4channel.org` too.
    public var cookieMatchTokens: Set<String> {
        switch self {
        case .dvach: ["2ch"]
        case .fourchan: ["4chan", "4cdn"]
        }
    }

    /// The cookies a gate issues, and the reason for opening a web view at all.
    ///
    /// A check counts as passed when one of these is newly set: 4chan's own
    /// interstitial writes `_tcs` from JavaScript and never touches
    /// Cloudflare's, so watching only for `cf_clearance` threw away the very
    /// thing the reader had just earned.
    public var gateCookieNames: Set<String> {
        switch self {
        case .dvach: ["cf_clearance"]
        case .fourchan: ["_tcs", "cf_clearance"]
        }
    }

    /// Hosts a pasted link may name, so a link resolves to the site it came
    /// from rather than the one currently selected.
    public var linkHosts: Set<String> {
        switch self {
        case .dvach: ["2ch.org", "2ch.life", "2ch.hk", "2ch.su", "2ch.pm"]
        case .fourchan: ["4chan.org", "4channel.org", "boards.4chan.org", "boards.4channel.org"]
        }
    }
}

/// Which imageboard, and — when it is 2ch — which of its mirrors.
///
/// One value because the client needs both to build a URL, and because the
/// mirror is meaningless off 2ch.
public struct SiteSelection: Sendable, Hashable, Codable {
    public var site: Imageboard
    /// Ignored unless `site` is `.dvach`.
    public var mirror: DvachDomain

    public init(site: Imageboard = .default, mirror: DvachDomain = .default) {
        self.site = site
        self.mirror = mirror
    }

    public static let `default` = SiteSelection()

    public var endpoints: SiteEndpoints { SiteEndpoints(self) }

    public var capabilities: SiteCapabilities { .of(site) }
}

/// Supplies the current selection to long-lived collaborators (the HTTP client,
/// the posting service) so a change in settings takes effect without rebuilding
/// them.
///
/// The client reads this from its own actor's executor, so a provider must be
/// callable from any isolation. Use `SiteHolder` rather than closing over
/// main-actor state.
public typealias SiteProvider = @Sendable () -> SiteSelection

/// A mutable selection that can be read from any isolation.
///
/// The same bridge `DomainHolder` is, and for the same reason: settings live on
/// the main actor, the client reads the selection from its own executor on
/// every request, and a lock is the only correct way across.
public final class SiteHolder: Sendable {
    private let storage: Mutex<SiteSelection>

    public init(_ initial: SiteSelection = .default) {
        storage = Mutex(initial)
    }

    /// What requests should use right now.
    public var value: SiteSelection {
        storage.withLock { $0 }
    }

    public func set(_ selection: SiteSelection) {
        storage.withLock { $0 = selection }
    }

    /// A provider bound to this holder.
    public var provider: SiteProvider {
        { [self] in value }
    }
}
