import Foundation
import NeechanAPI
import NeechanCore
import SwiftUI

/// Turns a parsed post body into an `AttributedString` a `Text` can draw.
///
/// Rendering is separated from parsing so the expensive half (parsing HTML)
/// happens once per post off the main actor, while this half re-runs cheaply
/// when a spoiler is revealed or the text size changes.
public struct PostTextRenderer: Sendable {
    /// The colours a post body draws with, taken from the reader's scheme.
    ///
    /// Baked into the text at render time, because an `AttributedString` carries
    /// its own colours rather than inheriting them from the view.
    public struct Palette: Sendable, Equatable {
        public var quote: Color
        public var link: Color
        public var spoilerHidden: Color
        public var spoilerRevealed: Color

        public init(theme: NeechanTheme = .builtIn) {
            quote = Color(theme.quote)
            link = Color(theme.link)
            spoilerHidden = Color(theme.spoiler)
            spoilerRevealed = Color(theme.spoiler).opacity(0.35)
        }
    }

    public struct Options: Sendable, Equatable {
        /// Spoilers in this post are shown rather than blocked out.
        public var revealSpoilers: Bool
        /// The post this text belongs to, so spoiler taps know what to reveal.
        public var postNum: Int
        /// The colours to draw with.
        public var palette: Palette

        public init(
            postNum: Int,
            revealSpoilers: Bool = false,
            palette: Palette = Palette()
        ) {
            self.postNum = postNum
            self.revealSpoilers = revealSpoilers
            self.palette = palette
        }
    }

    public init() {}

    public func render(_ content: PostContent, options: Options) -> AttributedString {
        var result = AttributedString()
        append(content.nodes, to: &result, style: [], context: Context(options: options))
        return result
    }

    // MARK: Walking

    private struct Context {
        let options: Options
        var isInsideSpoiler = false
        var isInsideQuote = false
        var isInsideCode = false
        var link: URL?
    }

    private func append(
        _ nodes: [PostNode],
        to result: inout AttributedString,
        style: PostStyle,
        context: Context
    ) {
        for node in nodes {
            switch node {
            case .text(let text):
                result.append(run(text, style: style, context: context))

            case .lineBreak:
                result.append(AttributedString("\n"))

            case .style(let extra, let children):
                append(children, to: &result, style: style.union(extra), context: context)

            case .spoiler(let children):
                var inner = context
                inner.isInsideSpoiler = true
                if !context.options.revealSpoilers {
                    inner.link = NeechanURL.spoilerToggle(postNum: context.options.postNum)
                }
                append(children, to: &result, style: style, context: inner)

            case .quote(let children):
                var inner = context
                inner.isInsideQuote = true
                append(children, to: &result, style: style, context: inner)

            case .code(let children):
                var inner = context
                inner.isInsideCode = true
                append(children, to: &result, style: style.union(.monospace), context: inner)

            case .aiGenerated(let children):
                append(children, to: &result, style: style, context: context)

            case .link(let address, let children):
                var inner = context
                inner.link = URL(string: address)
                append(children, to: &result, style: style, context: inner)

            case .postLink(let reference, let children):
                var inner = context
                inner.link = NeechanURL.post(reference)
                append(children, to: &result, style: style, context: inner)
            }
        }
    }

    private func run(_ text: String, style: PostStyle, context: Context) -> AttributedString {
        var run = AttributedString(text)

        if style.contains(.bold) { run.inlinePresentationIntent = .stronglyEmphasized }
        if style.contains(.italic) {
            run.inlinePresentationIntent = run.inlinePresentationIntent.map {
                $0.union(.emphasized)
            } ?? .emphasized
        }
        if style.contains(.underline) { run.underlineStyle = .single }
        if style.contains(.strikethrough) { run.strikethroughStyle = .single }
        if style.contains(.monospace) { run.inlinePresentationIntent = .code }

        if style.contains(.superscript) { run.baselineOffset = 4 }
        if style.contains(.subscript) { run.baselineOffset = -4 }

        if context.isInsideQuote {
            run.foregroundColor = context.options.palette.quote
        }
        if context.isInsideSpoiler {
            if context.options.revealSpoilers {
                run.backgroundColor = context.options.palette.spoilerRevealed
            } else {
                // Hidden text keeps its space in the layout, so revealing it does
                // not reflow the post.
                run.foregroundColor = context.options.palette.spoilerHidden
                run.backgroundColor = context.options.palette.spoilerHidden
            }
        }
        if let link = context.link {
            run.link = link
            if !context.isInsideSpoiler {
                run.foregroundColor = context.options.palette.link
            }
        }
        return run
    }
}

extension Color {
    /// Greentext in the shipped scheme, kept so existing tests and previews can
    /// name the default colour.
    static let postQuote = Color(NeechanTheme.builtIn.quote)
}

extension Color {
    /// The shipped scheme's spoiler colours, named so tests and previews can
    /// refer to the default without building a palette.
    static let defaultSpoilerHidden = PostTextRenderer.Palette().spoilerHidden
    static let defaultSpoilerRevealed = PostTextRenderer.Palette().spoilerRevealed
}
