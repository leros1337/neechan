import NeechanCore
import SwiftUI

/// Typing a label.
///
/// Centred over a dimmed picture rather than at the label's spot, so the
/// keyboard can never cover what is being typed; the label takes its place on
/// the picture when the reader is done.
struct LabelEntryOverlay: View {
    @Bindable var model: ImageEditorModel
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { model.finishEditingLabel() }

            VStack(spacing: 14) {
                HStack {
                    Spacer()
                    Button {
                        model.finishEditingLabel()
                    } label: {
                        Label {
                            Text("Done", bundle: .module)
                        } icon: {
                            Image(systemName: "checkmark")
                        }
                        .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.glassProminent)
                }

                Spacer(minLength: 0)

                TextField(
                    text: $model.labelText,
                    prompt: Text("Text", bundle: .module),
                    axis: .vertical
                ) {
                    Text("Text", bundle: .module)
                }
                .font(.system(size: fontSize, weight: .bold))
                .foregroundStyle(Color(model.color))
                .tint(Color(model.color))
                .multilineTextAlignment(.center)
                .lineLimit(1...6)
                .focused($isFocused)
                // The same contrasting edge the label gets on the picture.
                .shadow(color: outline, radius: 0.8)
                .shadow(color: outline, radius: 0.8)

                Spacer(minLength: 0)

                SizeSlider(model: model)
                ColorRow(selection: $model.color)
            }
            .padding(16)
        }
        .onAppear { isFocused = true }
    }

    /// The label's size on screen, kept readable while typing.
    private var fontSize: CGFloat {
        min(max(model.labelEditingFrameInView?.fontSize ?? 28, 20), 48)
    }

    private var outline: Color {
        model.color.luminance > 0.5 ? .black : .white
    }
}
