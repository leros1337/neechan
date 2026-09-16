import NeechanAPI
import NeechanCore
import PhotosUI
import SwiftUI

/// The formatting and attachment bar above the keyboard.
struct MarkupToolbar: View {
    let canAttach: Bool
    var onStyle: (WakabaMarkup.Style) -> Void
    var onPickPhotos: () -> Void
    @Binding var photoSelection: [PhotosPickerItem]
    var onPickFiles: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    PhotosPicker(
                        selection: $photoSelection,
                        maxSelectionCount: 4,
                        matching: .any(of: [.images, .videos])
                    ) {
                        Image(systemName: "photo.on.rectangle")
                    }
                    .buttonStyle(.glass)
                    .disabled(!canAttach)

                    Button(action: onPickFiles) {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.glass)
                    .disabled(!canAttach)

                    Divider().frame(height: 22)

                    ForEach(WakabaMarkup.Style.allCases) { style in
                        Button {
                            onStyle(style)
                        } label: {
                            Image(systemName: style.systemImage)
                        }
                        .buttonStyle(.glass)
                        .accessibilityLabel(style.accessibilityLabel)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
        }
    }
}

extension WakabaMarkup.Style {
    /// Symbols alone do not say what these do; VoiceOver needs words.
    var accessibilityLabel: Text {
        switch self {
        case .bold: Text("Bold", bundle: .module)
        case .italic: Text("Italic", bundle: .module)
        case .underline: Text("Underline", bundle: .module)
        case .strikethrough: Text("Strikethrough", bundle: .module)
        case .overline: Text("Overline", bundle: .module)
        case .spoiler: Text("Spoiler", bundle: .module)
        case .code: Text("Code", bundle: .module)
        case .superscript: Text("Superscript", bundle: .module)
        case .subscript: Text("Subscript", bundle: .module)
        }
    }
}
