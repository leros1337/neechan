import Foundation
import NeechanAPI
import NeechanCore

extension DvachError {
    /// A sentence to put in front of the reader.
    ///
    /// The site's own messages are in Russian and often carry the useful part
    /// (a ban reason, a rate limit), so they are preferred over anything this
    /// app could invent. Only the failures with no server text get their own
    /// wording.
    public var readableMessage: String {
        switch self {
        case .api(let error):
            error.message.isEmpty
                ? String(localized: "The server rejected the request.", bundle: .neechanUI, locale: AppLocale.current)
                : error.message
        case .http(let status, _):
            switch status {
            case 404:
                String(localized: "Not found. It may have been deleted.", bundle: .neechanUI, locale: AppLocale.current)
            case 429:
                String(localized: "Too many requests. Try again in a moment.", bundle: .neechanUI, locale: AppLocale.current)
            case 500...599:
                String(localized: "The site is having trouble. Try again later.", bundle: .neechanUI, locale: AppLocale.current)
            default:
                String(localized: "The server answered with an error.", bundle: .neechanUI, locale: AppLocale.current)
            }
        case .decoding:
            String(localized: "The site sent something this app could not read.", bundle: .neechanUI, locale: AppLocale.current)
        case .cloudflareChallenge:
            String(localized: "The site wants to check your browser.", bundle: .neechanUI, locale: AppLocale.current)
        case .transport:
            String(localized: "No connection.", bundle: .neechanUI, locale: AppLocale.current)
        case .unsupported:
            String(
                localized: "This imageboard does not offer that.",
                bundle: .neechanUI,
                locale: AppLocale.current
            )
        }
    }

    /// True when trying the same request again is worth offering.
    public var isRetryable: Bool {
        switch self {
        case .transport, .decoding: true
        case .http(let status, _): status >= 500 || status == 429
        case .api(let error): error.code.isTransient
        case .cloudflareChallenge, .unsupported: false
        }
    }
}

extension Error {
    /// Why a save did not happen, in the reader's language.
    ///
    /// The failures worth telling apart are the ones the reader can do
    /// something about: permission and a folder that has gone away. Anything
    /// else keeps the underlying text, which is usually the system's own.
    public var readableSaveMessage: String {
        if self is CancellationError {
            return String(
                localized: "The download was cancelled.", bundle: .neechanUI, locale: AppLocale.current
            )
        }
        if let error = self as? FileDownloadSaver.SaveError, error == .destinationUnavailable {
            return String(
                localized: "The folder you chose is no longer available. Pick it again in Settings.",
                bundle: .neechanUI,
                locale: AppLocale.current
            )
        }
        if let error = self as? DvachError {
            return error.readableMessage
        }
        return String(describing: self)
    }
}

extension Bundle {
    /// This package's bundle, under a name that reads clearly at call sites.
    static let neechanUI = Bundle.module
}
