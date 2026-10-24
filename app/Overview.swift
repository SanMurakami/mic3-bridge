import SwiftUI

struct ReceiverOverview: View {
    let receiver: Receiver
    @ObservedObject var store: MicStore
    var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: 8) {
                StatusDot(active: receiver.connected)
                Text(receiver.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer()
                Text(receiver.tc.enabled && receiver.tc.known ? "TC ON" : "TC OFF")
                    .foregroundStyle(receiver.tc.enabled && receiver.tc.known ? Console.cyan : Console.muted)
                if receiver.recording { Text("● MAC").foregroundStyle(.red) }
            }.font(.system(size: 9, weight: .semibold, design: .monospaced)).padding(12)
            HStack(spacing: 1) {
                ForEach(receiver.transmitters) { tx in
                    CompactChannel(tx: tx, receiver: receiver, store: store)
                }
            }.background(Console.line)
            HStack {
                Text(String(receiver.serial.suffix(6)))
                Spacer()
                Text(receiver.tc.known && receiver.tc.enabled ? receiver.tc.timecode : "—:—:—:—")
                Text(Console.fpsName(receiver.tc.fps))
            }.font(.system(size: 9, design: .monospaced)).foregroundStyle(Console.muted).padding(10)
            if !receiver.error.isEmpty { Text(receiver.error).font(.caption).foregroundStyle(.orange).padding(8) }
        }.background(Console.panel).clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
struct CompactChannel: View {
    let tx: Transmitter
    let receiver: Receiver
    @ObservedObject var store: MicStore
    @State private var editing = false
    @State private var draft = ""
    private var amplitude: Double { receiver.meters.indices.contains(tx.index - 1) ? receiver.meters[tx.index - 1] : 0 }
    private var db: Double { amplitude > 0 ? max(-60, 20 * log10(amplitude)) : -60 }
    var body: some View {
        VStack(spacing: 8) {
            HStack { Text("CH \(tx.index)"); Spacer(); StatusDot(active: tx.connected) }.font(.system(size: 9, design: .monospaced))
            Button { draft = tx.label; editing = true } label: {
                Text(tx.label.isEmpty ? "—" : tx.label).font(.system(size: 11, weight: .medium)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain).popover(isPresented: $editing) {
                LabelEditor(tx: tx, receiver: receiver, store: store)
            }
            GeometryReader { p in
                ZStack(alignment: .bottom) {
                    Rectangle().fill(.black.opacity(0.5))
                    Rectangle().fill(db >= -1 ? Color.red : db >= -9 ? Color.yellow : Color.green)
                        .frame(height: p.size.height * (db + 60) / 60).animation(.linear(duration: 0.045), value: db)
                    Path { path in for i in 1...12 { let y = p.size.height * Double(i) / 13; path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: p.size.width, y: y)) } }.stroke(Console.strip, lineWidth: 2)
                }
            }.frame(width: 16, height: 90)
            Text(amplitude > 0 ? String(format: "%.1f", db) : "−∞").font(.system(size: 11, design: .monospaced))
            Text(tx.connected && tx.device_recording ? "● TX REC" : "TX STOP").foregroundStyle(tx.connected && tx.device_recording ? .red : Console.muted)
            HStack(spacing: 3) {
                Image(systemName: tx.charging ? "battery.100percent.bolt" : "battery.100percent")
                Text(tx.connected ? Console.batteryBars(tx.battery_code).map { "\($0)/6" } ?? "—" : "—")
            }
            Text(tx.connected && tx.storage_total > 0 && tx.storage_remaining >= 0 && tx.storage_remaining <= tx.storage_total ? String(format: "空 %.0f%%", Double(tx.storage_remaining) / Double(tx.storage_total) * 100) : "空 —")
                .foregroundStyle(Console.muted)
            Picker("ノイキャン CH \(tx.index)", selection: Binding(get: { tx.noise_mode }, set: {
                store.send("noise", receiver: receiver, values: ["target": String(tx.index), "mode": $0])
            })) {
                Text("NONE").tag("none"); Text("BASIC").tag("basic"); Text("STRONG").tag("strong")
                if tx.noise_mode == "unknown" { Text("—").tag("unknown") }
            }.labelsHidden().controlSize(.mini).disabled(!tx.connected || receiver.control_busy)
        }.font(.system(size: 8, design: .monospaced)).padding(9).frame(maxWidth: .infinity).background(Console.strip)
    }
}
