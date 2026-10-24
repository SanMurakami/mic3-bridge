import SwiftUI

struct ReceiverOverview: View {
    let receiver: Receiver
    @ObservedObject var store: MicStore
    var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: 8) {
                Toggle("一括操作の対象", isOn: Binding(get: { !store.excluded.contains(receiver.serial) }, set: {
                    if $0 { store.excluded.remove(receiver.serial) } else { store.excluded.insert(receiver.serial) }
                })).toggleStyle(.checkbox).labelsHidden().disabled(!receiver.connected)
                StatusDot(active: receiver.connected)
                Text(receiver.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer()
                ProgressView().controlSize(.mini).opacity(receiver.control_busy ? 1 : 0).frame(width: 12)
                Text(receiver.tc.enabled && receiver.tc.known ? (receiver.tc.output == 1 ? "USB TC×4" : "TC ON") : "TC OFF")
                    .foregroundStyle(receiver.tc.known && receiver.tc.enabled && receiver.tc.output == 1 ? .orange : Console.cyan)
                if receiver.recording { Text("● MAC").foregroundStyle(.red) }
            }.font(.system(size: 9, weight: .semibold, design: .monospaced)).padding(12)
            HStack { LosslessControl(receiver: receiver, store: store); Spacer() }.padding(.horizontal, 12).padding(.bottom, 10)
            HStack(spacing: 1) {
                ForEach(receiver.transmitters) { tx in
                    CompactChannel(tx: tx, receiver: receiver, store: store)
                }
            }.background(Console.line)
            HStack {
                Text(String(receiver.serial.suffix(6)))
                Spacer()
                LiveTimecode(receiver: receiver, feed: store.feed(receiver.serial))
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
    private var batterySymbol: String {
        guard tx.connected, let bars = Console.batteryBars(tx.battery_code) else { return "battery.0percent" }
        if tx.charging { return "battery.100percent.bolt" }
        return "battery.\([0, 0, 25, 50, 75, 75, 100][bars])percent"
    }
    var body: some View {
        VStack(spacing: 8) {
            HStack { Text("CH \(tx.index)"); Spacer(); StatusDot(active: tx.connected) }.font(.system(size: 9, design: .monospaced))
            Button { draft = tx.label; editing = true } label: {
                Text(tx.label.isEmpty ? "—" : tx.label).font(.system(size: 11, weight: .medium)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain).popover(isPresented: $editing) {
                LabelEditor(tx: tx, receiver: receiver, store: store)
            }
            HStack(alignment: .top, spacing: 1) {
                ProductionMeter(feed: store.feed(receiver.serial), channel: tx.index - 1)
                GainControl(tx: tx, receiver: receiver, store: store, compact: true)
            }
            Text(tx.connected && tx.device_recording ? "● TX REC" : tx.connected ? "TX STOP" : "OFFLINE").foregroundStyle(tx.connected && tx.device_recording ? .red : Console.muted)
            HStack(spacing: 3) {
                Image(systemName: batterySymbol)
                Text(tx.connected ? Console.batteryBars(tx.battery_code).map { "\($0)/6" } ?? "—" : "—")
            }
            Text(tx.connected && tx.storage_total > 0 && tx.storage_remaining >= 0 && tx.storage_remaining <= tx.storage_total ? String(format: "空 %.0f%%", Double(tx.storage_remaining) / Double(tx.storage_total) * 100) : "空 —")
                .foregroundStyle(Console.muted)
            ProcessingControls(tx: tx, receiver: receiver, store: store)
        }.font(.system(size: 8, design: .monospaced)).padding(6).frame(maxWidth: .infinity).background(Console.strip)
    }
}
