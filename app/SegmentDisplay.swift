import SwiftUI

// 固定幅の7セグ表示。
struct SegmentDisplay: View {
    let text: String
    var height: CGFloat = 20
    private static let masks: [Character: Int] = ["0": 0x3f, "1": 0x06, "2": 0x5b, "3": 0x4f, "4": 0x66, "5": 0x6d, "6": 0x7d, "7": 0x07, "8": 0x7f, "9": 0x6f, "—": 0x40, "-": 0x40]
    var body: some View {
        Group {
            if text == "TC OFF" {
                Text(text).font(.system(size: height * 0.65, weight: .medium, design: .monospaced)).foregroundStyle(Console.muted)
                    .frame(width: height * 6.6, height: height)
            } else {
                Canvas { context, _ in
                    var x: CGFloat = 0
                    let ink = Color(red: 0.72, green: 0.84, blue: 0.83)
                    let w = height * 0.5, t = max(1, height * 0.075)
                    for char in text {
                        if char == ":" || char == ";" {
                            for y in [height * 0.32, height * 0.72] {
                                context.fill(Path(CGRect(x: x + t, y: y, width: t, height: t)), with: .color(ink))
                            }
                            x += height * 0.25
                            continue
                        }
                        let mask = Self.masks[char] ?? 0
                        let bars = [
                            CGRect(x: t, y: 0, width: w - 2*t, height: t),
                            CGRect(x: w-t, y: t, width: t, height: height/2-1.5*t),
                            CGRect(x: w-t, y: height/2+t/2, width: t, height: height/2-1.5*t),
                            CGRect(x: t, y: height-t, width: w-2*t, height: t),
                            CGRect(x: 0, y: height/2+t/2, width: t, height: height/2-1.5*t),
                            CGRect(x: 0, y: t, width: t, height: height/2-1.5*t),
                            CGRect(x: t, y: height/2-t/2, width: w-2*t, height: t)
                        ]
                        for (i, rect) in bars.enumerated() {
                            context.fill(Path(roundedRect: rect.offsetBy(dx: x, dy: 0), cornerRadius: t/3), with: .color(ink.opacity(mask & (1 << i) != 0 ? 1 : 0.055)))
                        }
                        x += height * 0.65
                    }
                }.frame(width: height * 5.95, height: height)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(LinearGradient(colors: [Color(red: 0.035, green: 0.055, blue: 0.055), Color(red: 0.065, green: 0.085, blue: 0.08)], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.white.opacity(0.13)))
        .accessibilityElement(children: .ignore).accessibilityLabel(text)
    }
}
