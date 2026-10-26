import SwiftUI
import AppKit

struct NativeGainFader: NSViewRepresentable {
    let value: Int
    let enabled: Bool
    let label: String
    let action: (Int) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(value: Double(value), minValue: -12, maxValue: 12, target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        slider.cell = ConsoleFaderCell()
        slider.minValue = -12; slider.maxValue = 12; slider.doubleValue = Double(value)
        slider.target = context.coordinator; slider.action = #selector(Coordinator.changed(_:))
        slider.focusRingType = .none
        slider.isVertical = true
        slider.isContinuous = false
        slider.numberOfTickMarks = 0; slider.allowsTickMarkValuesOnly = false
        slider.setAccessibilityLabel(label)
        return slider
    }
    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.parent = self
        if !enabled || (context.coordinator.lastRemote != value && !(slider.cell?.isHighlighted ?? false)) { slider.integerValue = value; context.coordinator.lastRemote = value }
        slider.isEnabled = enabled && context.environment.isEnabled
        slider.setAccessibilityLabel(label)
    }
    final class Coordinator: NSObject {
        var parent: NativeGainFader
        var lastRemote: Int?
        init(_ parent: NativeGainFader) { self.parent = parent }
        @objc func changed(_ sender: NSSlider) { guard parent.enabled else { sender.integerValue = parent.value; return }; let value = Int(sender.doubleValue.rounded()); sender.integerValue = value; parent.action(value) }
    }
}
struct GainControl: View {
    let tx: Transmitter
    let receiver: Receiver
    @ObservedObject var store: MicStore
    var height = 190.0
    var compact = false
    @State private var requested: Int?
    private var gain: Int { requested ?? tx.gain_db ?? -1000 }
    private var enabled: Bool { tx.connected && !tx.serial.isEmpty && (-12...12).contains(gain) && tx.agc == 0 && !store.settingsLocked }
    var body: some View {
        VStack(spacing: 6) {
            Text("GAIN dB").font(.system(size: 7, weight: .semibold)).tracking(1).foregroundStyle(Console.muted).frame(height: 12)
            HStack(spacing: 0) {
            NativeGainFader(value: (-12...12).contains(gain) ? gain : 0, enabled: enabled, label: "TX\(tx.index) / \(receiver.serial.suffix(6)) 入力ゲイン dB", action: set)
                .frame(width: 25, height: height).disabled(!enabled)
                Canvas { context, size in
                    for db in [12, 6, 0, -6, -12] {
                        // NSSliderのノブ中心が動く範囲に揃える。
                        let y = 11 + (size.height - 22) * Double(12-db)/24
                        var tick = Path(); tick.move(to: CGPoint(x: 0, y: y)); tick.addLine(to: CGPoint(x: db == 0 ? 5 : 3, y: y))
                        context.stroke(tick, with: .color(db == 0 ? Color(white: 0.85) : Console.muted), lineWidth: 1)
                        context.draw(Text(db > 0 ? "+\(db)" : "\(db)").font(.system(size: 7, design: .monospaced)).foregroundColor(Console.muted), at: CGPoint(x: 7, y: y), anchor: .leading)
                    }
                }.frame(width: 23, height: height).allowsHitTesting(false)
            }
            HStack(spacing: 2) {
                Button { set(gain - 1) } label: { Image(systemName: "minus").frame(width: compact ? 7 : 9, height: 16) }.disabled(!enabled || gain <= -12).accessibilityLabel("TX\(tx.index) / \(receiver.serial.suffix(6)) ゲインを1dB下げる")
                Text((-12...12).contains(gain) ? String(format: "%+d", gain) : "—").monospacedDigit().frame(width: compact ? 17 : 21)
                Button { set(gain + 1) } label: { Image(systemName: "plus").frame(width: compact ? 7 : 9, height: 16) }.disabled(!enabled || gain >= 12).accessibilityLabel("TX\(tx.index) / \(receiver.serial.suffix(6)) ゲインを1dB上げる")
            }.font(.system(size: compact ? 8 : 9, design: .monospaced)).buttonStyle(ConsoleCompactButton(height: 22, minWidth: 18, padding: 1))
        }.opacity(tx.connected ? 1 : 0.45)
            .onChange(of: tx.gain_db) { _, value in if value == requested { requested = nil } }
            .onChange(of: receiver.control_busy) { _, busy in if !busy { requested = nil } }
            .onChange(of: tx.serial) { _, _ in requested = nil }
    }
    private func set(_ db: Int) {
        guard enabled, (-12...12).contains(db), db != gain else { return }
        requested = db
        store.send("gain", receiver: receiver, values: ["target": String(tx.index), "tx_serial": tx.serial, "value": String(db)])
    }
}
struct ProcessingControls: View {
    let tx: Transmitter
    let receiver: Receiver
    @ObservedObject var store: MicStore
    var body: some View {
        VStack(spacing: 5) {
            Picker("自動ゲイン TX\(tx.index)", selection: Binding(get: { tx.agc ?? -1 }, set: {
                store.send("agc", receiver: receiver, values: ["target": String(tx.index), "tx_serial": tx.serial, "mode": String($0)])
            })) {
                Text("AGC · OFF").tag(0); Text("AGC · AUTO").tag(1); Text("AGC · DYN").tag(2)
                if (tx.agc ?? -1) < 0 { Text("AGC · —").tag(-1) }
            }.disabled(!tx.connected || tx.serial.isEmpty || store.settingsLocked)
            Picker("ノイキャン TX\(tx.index)", selection: Binding(get: { tx.noise_mode }, set: {
                store.send("noise", receiver: receiver, values: ["target": String(tx.index), "tx_serial": tx.serial, "mode": $0])
            })) {
                Text("NC · OFF").tag("none"); Text("NC · BASIC").tag("basic"); Text("NC · STRONG").tag("strong")
                if tx.noise_mode == "unknown" { Text("NC · —").tag("unknown") }
            }.disabled(!tx.connected || store.settingsLocked)
            Picker("音質 TX\(tx.index)", selection: Binding(get: { tx.eq ?? -1 }, set: {
                store.send("eq", receiver: receiver, values: ["target": String(tx.index), "tx_serial": tx.serial, "mode": String($0)])
            })) {
                Text("EQ · Regular").tag(0); Text("EQ · Rich").tag(1); Text("EQ · Bright").tag(2)
                if (tx.eq ?? -1) < 0 { Text("EQ · —").tag(-1) }
            }.disabled(!tx.connected || tx.serial.isEmpty || (tx.eq ?? -1) < 0 || store.settingsLocked)
            Toggle(isOn: Binding(get: { tx.low_cut == 1 }, set: {
                store.send("low_cut", receiver: receiver, values: ["target": String(tx.index), "tx_serial": tx.serial, "value": $0 ? "1" : "0"])
            })) { Text("LOW CUT \(tx.low_cut == 1 ? "ON" : tx.low_cut == 0 ? "OFF" : "—")").font(.system(size: 8, design: .monospaced)).foregroundStyle(Console.cyan) }
                .toggleStyle(.button).disabled(!tx.connected || tx.serial.isEmpty || (tx.low_cut ?? -1) < 0 || store.settingsLocked)
        }.labelsHidden().controlSize(.mini)
    }
}
struct SessionRecordStatus: View {
    @ObservedObject var store: MicStore
    @ObservedObject private var clock: LiveClock
    init(store: MicStore) { self.store = store; clock = store.clock }
    var body: some View {
        let active = store.snapshot.receivers.filter(\.recording)
        let seconds = active.map { store.feed($0.serial).frame.seconds }.max() ?? 0
        HStack(spacing: 8) {
            Circle().fill(active.isEmpty ? Console.muted.opacity(0.3) : .red).frame(width: 7, height: 7)
            Text(active.isEmpty ? "MAC STOP" : String(format: "MAC REC  %02d:%02d:%02d", Int(seconds) / 3600, Int(seconds) / 60 % 60, Int(seconds) % 60))
                .font(.system(size: 11, weight: .medium, design: .monospaced)).monospacedDigit()
                .foregroundStyle(active.isEmpty ? Console.muted : .red)
            if !active.isEmpty { Text("\(active.count) RX").font(.system(size: 9, design: .monospaced)).foregroundStyle(Console.muted) }
        }
    }
}

// tracking/keyboard/accessibility は NSSlider に任せ、描画だけをコンソールに合わせる。
final class ConsoleFaderCell: NSSliderCell {
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let rail = NSRect(x: rect.midX - 2, y: rect.minY, width: 4, height: rect.height)
        NSColor(white: 0.035, alpha: 1).setFill()
        NSBezierPath(roundedRect: rail, xRadius: 2, yRadius: 2).fill()
        NSColor(white: 0.26, alpha: 1).setStroke()
        NSBezierPath(roundedRect: rail, xRadius: 2, yRadius: 2).stroke()
    }
    override func drawKnob(_ knobRect: NSRect) {
        let rect = NSRect(x: knobRect.midX-9, y: knobRect.midY-11, width: 18, height: 22)
        let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
        let alpha: CGFloat = isEnabled ? 1 : 0.35
        NSGradient(starting: NSColor(white: 0.68, alpha: alpha), ending: NSColor(white: 0.34, alpha: alpha))?.draw(in: path, angle: -90)
        NSColor(white: 0.08, alpha: 1).setStroke(); path.stroke()
        NSColor(white: 0.9, alpha: alpha).setFill()
        NSRect(x: rect.minX+2, y: rect.midY, width: rect.width-4, height: 1).fill()
    }
}
