import NeechanAPI
import NeechanMedia
import SwiftUI

/// 4chan's captcha in the reply form, drawn the app's way and run the site's.
///
/// Get Captcha asks for one and then sits out the cooldown the site sent with
/// it, counting it down. A puzzle is a picture and a slider: the slider starts
/// on the instructions, each position shows one picture, and Next takes the
/// one showing. The reader does all of it — nothing here picks, suggests or
/// starts anywhere but the instructions.
struct FourchanCaptchaView: View {
    let model: FourchanCaptchaModel
    /// The engine the frame lives in, shown while a check needs the reader.
    let browser: (any FourchanBrowser)?

    @State private var isShowingTicketCaptcha = false
    /// A 4chan page a message linked to, open in the engine's own store.
    @State private var openedPage: OpenedPage?

    private struct OpenedPage: Identifiable {
        let url: URL
        var id: URL { url }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
            if let notice = model.notice {
                Text(FourchanCaptchaMarkup(html: notice).text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            help
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 16))
        // Only the display moves on with this; every deadline it counts down
        // to is one the site sent.
        .task {
            while !Task.isCancelled {
                model.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onChange(of: model.phase) { _, phase in
            if case .ticketCaptcha = phase { isShowingTicketCaptcha = true }
        }
        .sheet(isPresented: $isShowingTicketCaptcha) {
            ticketCaptchaSheet
        }
        // The site's messages link to its own pages — where the reader
        // verifies their email to wait less — and those have to open where
        // the captcha's cookies live, not in Safari.
        .environment(\.openURL, OpenURLAction { url in
            #if canImport(WebKit) && os(iOS)
            if FourchanPageSheet.handles(url) {
                openedPage = OpenedPage(url: url)
                return .handled
            }
            #endif
            return .systemAction
        })
        .sheet(item: $openedPage) { page in
            #if canImport(WebKit) && os(iOS)
            FourchanPageSheet(url: page.url)
            #endif
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Captcha", bundle: .module)
                .font(.subheadline.weight(.semibold))
            if let seconds = model.secondsUntilExpiry {
                // The token lapses, so the countdown warns the reader before a
                // send would be refused.
                Text(verbatim: "\(seconds / 60):\(String(format: "%02d", seconds % 60))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(seconds < 30 ? .red : .secondary)
                    .accessibilityLabel(Text("\(seconds) seconds left", bundle: .module))
            }
            Spacer(minLength: 0)
            getCaptchaButton
        }
    }

    private var getCaptchaButton: some View {
        Button {
            Task { await model.requestCaptcha() }
        } label: {
            if let seconds = model.secondsUntilRequest {
                Text("Get Captcha (\(seconds))", bundle: .module)
                    .monospacedDigit()
            } else {
                Text("Get Captcha", bundle: .module)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!model.canRequest)
        .accessibilityIdentifier("fourchan-captcha-get")
    }

    // MARK: Help

    /// How to answer, and how to wait less.
    ///
    /// The puzzle explains itself only in the site's English, and the way to
    /// skip its waits is a link the site shows only once the reader is already
    /// waiting. Both are here from the start. The link opens in the engine's
    /// own store, through `openURL` above, so what the page sets counts for
    /// the captcha.
    @ViewBuilder
    private var help: some View {
        let showsHowTo = switch model.phase {
        case .idle, .steps: true
        default: false
        }
        // The site's own wait message carries the same link.
        let showsVerification = model.notice == nil
        if showsHowTo || showsVerification {
            VStack(alignment: .leading, spacing: 4) {
                if showsHowTo {
                    Label {
                        Text(
                            "Move the slider until the picture matches what the instructions ask for, then press Next. Every step works the same way.",
                            bundle: .module
                        )
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                }
                if showsVerification {
                    Label {
                        Text(
                            "[Verify your email](https://sys.4chan.org/signin) with 4chan to skip the wait before posting.",
                            bundle: .module
                        )
                    } icon: {
                        Image(systemName: "envelope")
                    }
                    .accessibilityIdentifier("fourchan-captcha-verify-email")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            if model.notice == nil {
                Text(
                    "Get a captcha once the post is ready: the site makes you wait between them.",
                    bundle: .module
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

        case .loading:
            HStack {
                ProgressView()
                Text("Loading the captcha…", bundle: .module)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

        case .checking:
            checkFrame

        case .steps(let progress):
            steps(progress)

        case .answered:
            Label {
                Text("Done", bundle: .module)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
            }
            .font(.footnote)
            .foregroundStyle(.green)
            .accessibilityIdentifier("fourchan-captcha-done")

        case .notRequired:
            Label {
                Text("Verification not required.", bundle: .module)
            } icon: {
                Image(systemName: "checkmark.circle")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

        case .expired:
            Text("Captcha expired.", bundle: .module)
                .font(.footnote)
                .foregroundStyle(.secondary)

        case .refused(let message), .failed(let message):
            // The site's words are HTML, as its own page sets them.
            Text(FourchanCaptchaMarkup(html: message).text)
                .font(.footnote)
                .foregroundStyle(.red)
                .accessibilityIdentifier("fourchan-captcha-error")

        case .ticketCaptcha:
            VStack(alignment: .leading, spacing: 8) {
                Text("4chan wants one more check before it hands out a captcha.", bundle: .module)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button {
                    isShowingTicketCaptcha = true
                } label: {
                    Text("Answer the check", bundle: .module)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    /// The frame itself, for as long as it is showing a browser check.
    @ViewBuilder
    private var checkFrame: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cloudflare wants to check this browser first. Answer it here.", bundle: .module)
                .font(.footnote)
                .foregroundStyle(.secondary)
            #if canImport(WebKit) && os(iOS)
            if let session = browser as? FourchanBrowserSession {
                FourchanFrameView(session: session)
                    .frame(height: 110)
                    .frame(maxWidth: .infinity)
                    .clipShape(.rect(cornerRadius: 10))
            }
            #endif
        }
    }

    // MARK: Steps

    private func steps(_ progress: FourchanCaptchaProgress) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            shown(progress.shown)

            Slider(
                value: Binding(
                    get: { Double(progress.selection) },
                    set: { model.select(Int($0.rounded())) }
                ),
                in: 0...Double(max(progress.itemCount, 1)),
                step: 1
            )
            .accessibilityLabel(Text("Picture", bundle: .module))
            .accessibilityValue(
                progress.selection == 0
                    ? Text("Instructions", bundle: .module)
                    : Text("Picture \(progress.selection) of \(progress.itemCount)", bundle: .module)
            )
            .accessibilityIdentifier("fourchan-captcha-slider")

            HStack {
                Spacer(minLength: 0)
                Button {
                    model.next()
                } label: {
                    Text("Next (\(progress.position)/\(progress.count))", bundle: .module)
                        .monospacedDigit()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!progress.canAdvance)
                .accessibilityIdentifier("fourchan-captcha-next")
            }
        }
    }

    /// The instructions or the picture the slider is on, exactly as sent.
    ///
    /// A plain image: no Live Text, no lookup, no menu. The pictures are the
    /// reader's to look at and nobody else's.
    @ViewBuilder
    private func shown(_ shown: FourchanCaptchaProgress.Shown?) -> some View {
        Group {
            switch shown {
            case .image(let base64):
                if let image = model.picture(base64) {
                    Image(platformImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
            case .prompt(let prompt):
                // The instructions, with the picture they ask about on the
                // right, as the site lays them out.
                HStack(spacing: 10) {
                    if !prompt.text.characters.isEmpty {
                        Text(prompt.text)
                            .font(.callout)
                            .foregroundStyle(.black)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(Array(prompt.images.enumerated()), id: \.offset) { _, base64 in
                        if let image = model.picture(base64) {
                            Image(platformImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 120, maxHeight: 120)
                        }
                    }
                }
                .padding(10)
            case nil:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, minHeight: 80, maxHeight: 160)
        // The pictures are drawn for a light page, so they keep one in dark
        // mode, as the emoji keys do.
        .background(.white, in: .rect(cornerRadius: 10))
        .accessibilityHidden(true)
    }

    // MARK: Ticket captcha

    @ViewBuilder
    private var ticketCaptchaSheet: some View {
        #if canImport(WebKit) && os(iOS)
        if case .ticketCaptcha(let siteKey) = model.phase {
            TicketCaptchaSheet(siteKey: siteKey, board: model.board) { token in
                isShowingTicketCaptcha = false
                Task { await model.ticketCaptchaAnswered(token) }
            }
        }
        #endif
    }
}
