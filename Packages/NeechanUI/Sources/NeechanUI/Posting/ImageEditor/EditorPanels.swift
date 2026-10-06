import NeechanCore
import SwiftUI

// The controls under the picture, one panel per mode.

/// Tools, size and colour.
struct DrawPanel: View {
    @Bindable var model: ImageEditorModel

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        ForEach(ImageEditorModel.Tool.allCases, id: \.self) { tool in
                            Button {
                                model.tool = tool
                            } label: {
                                Label {
                                    tool.title
                                } icon: {
                                    Image(systemName: tool.symbol)
                                }
                                .labelStyle(.iconOnly)
                            }
                            .glassButtonStyle(prominent: model.tool == tool)
                            .accessibilityAddTraits(model.tool == tool ? .isSelected : [])
                        }
                    }
                }
                SizeSlider(model: model)
            }

            // Pixelation has no colour of its own: it is the photo's.
            if model.tool != .pixelate {
                ColorRow(selection: $model.color)
            }
        }
    }
}

/// The current tool's size, in screen points.
struct SizeSlider: View {
    @Bindable var model: ImageEditorModel

    var body: some View {
        Slider(
            value: Binding(
                get: { Double(model.size) },
                set: { model.size = CGFloat($0) }
            ),
            in: Double(ImageEditorModel.sizeRange(for: model.tool).lowerBound)
                ... Double(ImageEditorModel.sizeRange(for: model.tool).upperBound)
        ) {
            Text("Size", bundle: .module)
        } minimumValueLabel: {
            Image(systemName: "circle.fill").font(.system(size: 6))
        } maximumValueLabel: {
            Image(systemName: "circle.fill").font(.system(size: 16))
        }
    }
}

/// Preset colours, then the system picker for any other.
struct ColorRow: View {
    @Binding var selection: ThemeColor

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(ImageEditorModel.presetColors, id: \.self) { color in
                    let isSelected = color == selection
                    Button {
                        selection = color
                    } label: {
                        Circle()
                            .fill(Color(color))
                            .frame(width: 26, height: 26)
                            .overlay {
                                Circle().strokeBorder(
                                    .white.opacity(isSelected ? 1 : 0.35),
                                    lineWidth: isSelected ? 3 : 1
                                )
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Color", bundle: .module))
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }

                ColorPicker(
                    selection: Binding(
                        get: { Color(selection) },
                        set: { selection = ThemeColor($0) }
                    ),
                    supportsOpacity: false
                ) {
                    Text("Color", bundle: .module)
                }
                .labelsHidden()
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 2)
        }
        .scrollIndicators(.hidden)
    }
}

/// Turn, flip and the crop's shape.
struct CropPanel: View {
    let model: ImageEditorModel

    var body: some View {
        VStack(spacing: 12) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(ImageCropAspect.allCases, id: \.self) { aspect in
                        Button {
                            model.setAspect(aspect)
                        } label: {
                            aspect.title
                                .font(.footnote.monospacedDigit())
                        }
                        .glassButtonStyle(prominent: model.cropAspect == aspect)
                        .accessibilityAddTraits(model.cropAspect == aspect ? .isSelected : [])
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)

            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    iconButton("Rotate left", symbol: "rotate.left") { model.turn(clockwise: false) }
                    iconButton("Rotate right", symbol: "rotate.right") { model.turn(clockwise: true) }
                    iconButton("Flip", symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right") {
                        model.mirror()
                    }
                    Spacer(minLength: 0)
                    Button {
                        model.resetCrop()
                    } label: {
                        Label {
                            Text("Reset", bundle: .module)
                        } icon: {
                            Image(systemName: "arrow.counterclockwise")
                        }
                    }
                    .buttonStyle(.glass)
                }
            }
        }
    }

    private func iconButton(
        _ title: LocalizedStringKey,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label {
                Text(title, bundle: .module)
            } icon: {
                Image(systemName: symbol)
            }
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.glass)
    }
}

/// The scale, and the size it makes.
struct ResizePanel: View {
    let model: ImageEditorModel

    private static let presets = [25, 50, 75, 100]

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(model.outputPixelSize.width) × \(model.outputPixelSize.height) px", bundle: .module)
                    .font(.title3.weight(.semibold).monospacedDigit())
                Spacer(minLength: 8)
                Text(
                    "Original: \(model.originalPixelSize.width) × \(model.originalPixelSize.height) px",
                    bundle: .module
                )
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Text("Scale: \(model.scalePercent)%", bundle: .module)
                    .font(.footnote.monospacedDigit())
                    .frame(minWidth: 96, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { Double(model.scalePercent) },
                        set: { model.scalePercent = Int($0.rounded()) }
                    ),
                    // No step: a stepped slider draws a tick for each of the
                    // ninety values. The setter rounds instead.
                    in: Double(ImageEdit.scaleRange.lowerBound)...Double(ImageEdit.scaleRange.upperBound)
                ) {
                    Text("Resize", bundle: .module)
                } onEditingChanged: { editing in
                    model.scaleEditingChanged(editing)
                }
            }

            HStack(spacing: 8) {
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        ForEach(Self.presets, id: \.self) { percent in
                            Button {
                                model.stepScale(to: percent)
                            } label: {
                                Text(verbatim: "\(percent)%")
                                    .font(.footnote.monospacedDigit())
                            }
                            .glassButtonStyle(prominent: model.scalePercent == percent)
                        }
                    }
                }
                Spacer(minLength: 0)
                Stepper(
                    value: Binding(
                        get: { model.scalePercent },
                        set: { model.stepScale(to: $0) }
                    ),
                    in: ImageEdit.scaleRange
                ) {
                    Text("Resize", bundle: .module)
                }
                .labelsHidden()
            }
        }
    }
}

// MARK: Names

extension ImageEditorModel.Tool {
    var title: Text {
        switch self {
        case .pen: Text("Pen", bundle: .module)
        case .arrow: Text("Arrow", bundle: .module)
        case .pixelate: Text("Pixelate", bundle: .module)
        case .text: Text("Text", bundle: .module)
        }
    }

    var symbol: String {
        switch self {
        case .pen: "pencil.tip"
        case .arrow: "arrow.up.right"
        case .pixelate: "checkerboard.rectangle"
        case .text: "textformat"
        }
    }
}

extension ImageCropAspect {
    var title: Text {
        switch self {
        case .free: Text("Free", bundle: .module)
        case .original: Text("Original aspect", bundle: .module)
        case .square: Text(verbatim: "1:1")
        case .fourThree: Text(verbatim: "4:3")
        case .threeFour: Text(verbatim: "3:4")
        case .sixteenNine: Text(verbatim: "16:9")
        case .nineSixteen: Text(verbatim: "9:16")
        }
    }
}

extension View {
    /// Glass, or tinted glass for the chosen one of a set.
    @ViewBuilder
    func glassButtonStyle(prominent: Bool) -> some View {
        if prominent {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.glass)
        }
    }
}
