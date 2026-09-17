import NeechanCore
import NeechanMedia
import SwiftUI

/// The site's emoji captcha: a strip of symbols to find, and a keyboard to pick
/// them from. Each tap either advances to a new keyboard or finishes.
struct EmojiCaptchaView: View {
    let state: ReplyFormViewModel.CaptchaState
    /// What the reader has typed off a slider puzzle, if this site sets one.
    @Binding var sliderResponse: String
    let secondsRemaining: Int?
    /// What the reader has picked so far, oldest first.
    var chosenKeys: [PlatformImage] = []
    var onSelect: (Int) async -> Void
    var onReload: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 16))
    }

    /// The symbols already picked.
    ///
    /// Each step replaces the keyboard, so without this a reader part-way
    /// through has no way of telling what they have already answered.
    private var chosenStrip: some View {
        HStack(spacing: 6) {
            Text("Picked", bundle: .module)
                .font(.caption2)
                .foregroundStyle(.secondary)

            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(Array(chosenKeys.enumerated()), id: \.offset) { _, key in
                        Image(platformImage: key)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 28, height: 28)
                            .background(.white, in: .rect(cornerRadius: 6))
                    }
                }
            }
            .scrollIndicators(.hidden)

            Text(chosenKeys.count, format: .number)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(chosenKeys.count) symbols picked", bundle: .module))
    }

    private var header: some View {
        HStack {
            Text("Captcha", bundle: .module)
                .font(.subheadline.weight(.semibold))
            if let secondsRemaining, isChallenge {
                // The token lapses after a few minutes, so the countdown warns
                // the reader before a send is refused.
                Text(verbatim: "\(secondsRemaining / 60):\(String(format: "%02d", secondsRemaining % 60))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(secondsRemaining < 30 ? .red : .secondary)
            }
            Spacer(minLength: 0)
            Button {
                Task { await onReload() }
            } label: {
                Label {
                    Text("Reload captcha", bundle: .module)
                } icon: {
                    Image(systemName: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .controlSize(.small)
        }
    }

    private var isChallenge: Bool {
        if case .challenge = state { return true }
        return false
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle, .loading:
            HStack {
                ProgressView()
                Text("Loading the captcha…", bundle: .module)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        // 4chan's puzzle. Both strips are shown and the reader lines them up
        // by eye and types what they read; nothing in this app computes the
        // offset or guesses a character, and nothing should.
        case .slider(let image, let background, let backgroundWidth):
            VStack(alignment: .leading, spacing: 10) {
                Text(
                    "Slide the background until the characters line up, then type them.",
                    bundle: .module
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                SliderPuzzle(image: image, background: background, backgroundWidth: backgroundWidth)

                TextField(text: $sliderResponse) {
                    Text("What it says", bundle: .module)
                }
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                .textInputAutocapitalization(.characters)
                #endif
                .autocorrectionDisabled()
                .accessibilityIdentifier("slider-captcha-answer")
            }

        case .challenge(let image, let keys):
            VStack(alignment: .leading, spacing: 10) {
                Text("Pick every symbol shown above. Order does not matter, and some appear only later.", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let image {
                    Image(platformImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 64)
                        .frame(maxWidth: .infinity)
                        .background(.white, in: .rect(cornerRadius: 10))
                }

                if !chosenKeys.isEmpty {
                    chosenStrip
                }

                EmojiKeyboardGrid(keys: keys, onSelect: onSelect)
            }

        case .solved:
            Label {
                Text("Captcha solved", bundle: .module)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
            }
            .font(.footnote)
            .foregroundStyle(.green)

        case .notRequired:
            Label {
                Text("No captcha needed", bundle: .module)
            } icon: {
                Image(systemName: "checkmark.circle")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                Button {
                    Task { await onReload() }
                } label: {
                    Text("Try again", bundle: .module)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}

/// The keys to choose from.
struct EmojiKeyboardGrid: View {
    let keys: [PlatformImage?]
    var onSelect: (Int) async -> Void

    @State private var busyIndex: Int?

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 8)], spacing: 8) {
            ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                Button {
                    busyIndex = index
                    Task {
                        await onSelect(index)
                        busyIndex = nil
                    }
                } label: {
                    Group {
                        if let key {
                            Image(platformImage: key)
                                .resizable()
                                .scaledToFit()
                        } else {
                            Image(systemName: "questionmark")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(6)
                    .frame(width: 52, height: 52)
                    // The keys are dark glyphs on transparency, so they need a
                    // light backing to stay visible in dark mode.
                    .background(.white, in: .rect(cornerRadius: 10))
                    .opacity(busyIndex == nil || busyIndex == index ? 1 : 0.4)
                }
                .buttonStyle(.plain)
                .disabled(busyIndex != nil)
                .accessibilityLabel(Text("Symbol \(index + 1)", bundle: .module))
            }
        }
    }
}


/// 4chan's slider captcha: the characters over a background the reader shifts.
///
/// The offset is theirs to find. This view holds it, draws it and reports
/// nothing — there is deliberately no code anywhere that tries to work out what
/// the right offset would be.
private struct SliderPuzzle: View {
    let image: PlatformImage?
    let background: PlatformImage?
    let backgroundWidth: Int

    @State private var offset: Double = 0

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                if let background {
                    Image(platformImage: background)
                        .resizable()
                        .scaledToFill()
                        .offset(x: offset)
                        .clipped()
                }
                if let image {
                    Image(platformImage: image)
                        .resizable()
                        .scaledToFit()
                }
            }
            .frame(height: 80)
            .frame(maxWidth: .infinity)
            .clipShape(.rect(cornerRadius: 10))
            .background(.white, in: .rect(cornerRadius: 10))

            if background != nil {
                Slider(value: $offset, in: -Double(max(backgroundWidth, 1))...0)
                    .accessibilityIdentifier("slider-captcha-offset")
                    .accessibilityLabel(Text("Background position", bundle: .module))
            }
        }
    }
}
