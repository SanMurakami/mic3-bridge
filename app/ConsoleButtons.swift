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
