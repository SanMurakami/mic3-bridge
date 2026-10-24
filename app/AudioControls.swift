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
        slider.isVertical = true
        slider.isContinuous = false
        slider.numberOfTickMarks = 5; slider.allowsTickMarkValuesOnly = false
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
            Text("GAIN").font(.system(size: 7, weight: .semibold)).tracking(1).foregroundStyle(Console.muted).frame(height: 12)
            NativeGainFader(value: (-12...12).contains(gain) ? gain : 0, enabled: enabled, label: "TX\(tx.index) / \(receiver.serial.suffix(6)) 入力ゲイン dB", action: set)
                .frame(width: 25, height: height).disabled(!enabled)
            HStack(spacing: 2) {
                Button { set(gain - 1) } label: { Image(systemName: "minus").frame(width: compact ? 7 : 9, height: 16) }.disabled(!enabled || gain <= -12).accessibilityLabel("TX\(tx.index) / \(receiver.serial.suffix(6)) ゲインを1dB下げる")
                Text((-12...12).contains(gain) ? String(format: "%+d", gain) : "—").monospacedDigit().frame(width: compact ? 17 : 21)
                Button { set(gain + 1) } label: { Image(systemName: "plus").frame(width: compact ? 7 : 9, height: 16) }.disabled(!enabled || gain >= 12).accessibilityLabel("TX\(tx.index) / \(receiver.serial.suffix(6)) ゲインを1dB上げる")
            }.font(.system(size: compact ? 8 : 9, design: .monospaced)).buttonStyle(.plain)
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
                store.send("noise", receiver: receiver, values: ["target": String(tx.index), "mode": $0])
            })) {
                Text("NC · OFF").tag("none"); Text("NC · BASIC").tag("basic"); Text("NC · STRONG").tag("strong")
                if tx.noise_mode == "unknown" { Text("NC · —").tag("unknown") }
            }.disabled(!tx.connected || store.settingsLocked)
        }.labelsHidden().controlSize(.mini)
    }
}
struct LosslessControl: View {
    let receiver: Receiver
    @ObservedObject var store: MicStore
    var body: some View {
        Toggle(isOn: Binding(get: { receiver.lossless == 1 }, set: {
            store.send("lossless", receiver: receiver, values: ["enabled": $0 ? "1" : "0"])
        })) {
            Text("LOSSLESS \(receiver.lossless == 1 ? "ON" : receiver.lossless == 0 ? "OFF" : "—")")
                .font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(Console.cyan)
        }.toggleStyle(.switch).controlSize(.mini).tint(Console.cyan)
            .disabled(!receiver.connected || (receiver.lossless ?? -1) < 0 || store.settingsLocked)
    }
}
struct BatchAudioPanel: View {
    @ObservedObject var store: MicStore
    @Environment(\.dismiss) private var dismiss
    @State private var lossless = -1
    @State private var agc = -1
    @State private var noise = "keep"
    private var changed: Bool { lossless >= 0 || agc >= 0 || noise != "keep" }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text("一括設定").font(.system(size: 20, weight: .medium))
                Spacer()
                Text("\(store.targets.count) RX / \(store.targets.flatMap(\.transmitters).filter(\.connected).count) TX")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Console.muted)
            }
            VStack(spacing: 14) {
                Picker("ロスレス無線伝送", selection: $lossless) { Text("変更しない").tag(-1); Text("OFF").tag(0); Text("ON · 48k / 24-bit").tag(1) }
                Picker("自動ゲイン", selection: $agc) { Text("変更しない").tag(-1); Text("OFF").tag(0); Text("Automatic").tag(1); Text("Dynamic").tag(2) }
                Picker("ノイキャン", selection: $noise) { Text("変更しない").tag("keep"); Text("OFF").tag("none"); Text("BASIC").tag("basic"); Text("STRONG").tag("strong") }
            }.pickerStyle(.menu)
            Divider()
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(store.targets) { r in
                        HStack { StatusDot(active: true); Text(r.name).lineLimit(1); Spacer(); Text("\(r.transmitters.filter(\.connected).count) TX").foregroundStyle(Console.muted) }.font(.system(size: 11))
                    }
                }
            }.frame(maxHeight: 100)
            HStack {
                Button("キャンセル") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("選択RXへ適用") {
                    store.bulk("audio_all", values: ["lossless": String(lossless), "agc": String(agc), "noise": noise]); dismiss()
                }.buttonStyle(ConsoleButton(active: true, color: Console.cyan)).disabled(!changed || store.targets.isEmpty || store.targetsBusy || store.settingsLocked)
            }
        }.padding(24).frame(width: 430).background(Console.panel)
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
