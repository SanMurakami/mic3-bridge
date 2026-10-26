import SwiftUI

// 背景・枠・ヒット領域をlabel内で揃える。
struct ConsoleButtonFace: ViewModifier {
    var active = false
    var color = Color(white: 0.74)
    var pressed = false
    var solid = false
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false
    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .background(solid && active ? color : (active ? color.opacity(0.12) : Color.white.opacity(pressed ? 0.16 : hovered && enabled ? 0.10 : 0.045)), in: RoundedRectangle(cornerRadius: 3))
            .overlay(alignment: .top) {
                Rectangle().fill(Color.white.opacity(pressed ? 0 : 0.08)).frame(height: 1).padding(.horizontal, 2).allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(active ? color.opacity(0.65) : Color.white.opacity(hovered && enabled ? 0.38 : 0.15), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .opacity(!enabled ? 0.35 : pressed ? 0.72 : 1)
            .onHover { hovered = $0 }
            .transaction { $0.animation = nil }
    }
}
struct ConsoleCompactButton: ButtonStyle {
    var active = false
    var color = Color(white: 0.74)
    var height: CGFloat = 24
    var minWidth: CGFloat = 0
    var padding: CGFloat = 5
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(.horizontal, padding).frame(minWidth: minWidth, minHeight: height)
            .contentShape(Rectangle())
            .modifier(ConsoleButtonFace(active: active, color: color, pressed: configuration.isPressed))
    }
}

// 選択面と操作キーの表示を分ける。
struct ConsoleSelectionButton: ButtonStyle {
    var selected = false
    var labelPlate = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(.horizontal, 6).frame(minHeight: labelPlate ? 30 : 24)
            .contentShape(Rectangle())
            .modifier(SelectionSurface(selected: selected, labelPlate: labelPlate, pressed: configuration.isPressed))
    }
}
private struct SelectionSurface: ViewModifier {
    let selected: Bool
    let labelPlate: Bool
    let pressed: Bool
    @State private var hovered = false
    func body(content: Content) -> some View {
        content
            .background(labelPlate ? Color(white: pressed ? 0.16 : 0.08) : Color.white.opacity(hovered || pressed ? 0.08 : selected ? 0.05 : 0))
            .overlay(alignment: .bottom) {
                Rectangle().fill(selected ? Console.cyan : Color.white.opacity(hovered ? 0.4 : labelPlate ? 0.2 : 0.08)).frame(height: selected ? 2 : 1).allowsHitTesting(false)
            }
            .onHover { hovered = $0 }
            .transaction { $0.animation = nil }
    }
}
