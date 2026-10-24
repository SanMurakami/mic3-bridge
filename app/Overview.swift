import SwiftUI
import AppKit

struct ReceiverOverview: View {
    let receiver: Receiver
    @ObservedObject var store: MicStore
    @State private var editingName = false
    @State private var name = ""
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
                Menu {
                    Button("入力名を変更…") { name = receiver.name; editingName = true }.disabled(store.settingsLocked)
                    Button("機器の状態を更新") { store.send("refresh_controls", receiver: receiver) }.disabled(!receiver.connected)
                    if !receiver.recording_path.isEmpty {
                        Button("録音ファイルを表示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: receiver.recording_path)]) }
                    }
                    Divider()
                    Text("RX \(receiver.serial)")
                    Text("FW \(receiver.firmware)")
                    Button("登録を削除", role: .destructive) { store.send("delete", receiver: receiver) }.disabled(!receiver.can_delete || store.settingsLocked)
                } label: { Image(systemName: "ellipsis").frame(width: 16, height: 20) }.menuStyle(.borderlessButton).fixedSize()

            }.font(.system(size: 9, weight: .semibold, design: .monospaced)).padding(12)
            HStack { LosslessControl(receiver: receiver, store: store); Spacer(); BatteryIndicator(code: receiver.battery_code, connected: receiver.connected, charging: receiver.charging).accessibilityLabel("レシーバー電池") }.padding(.horizontal, 12).padding(.bottom, 10)
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
            .sheet(isPresented: $editingName) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("仮想入力の名前").font(.headline)
                    TextField("名前", text: $name).textFieldStyle(.roundedBorder)
                    HStack { Spacer(); Button("キャンセル") { editingName = false }; Button("保存") {
                        store.send("rename", receiver: receiver, values: ["name": name]); editingName = false
                    }.keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                }.padding(24).frame(width: 400)
            }
    }
}
struct CompactChannel: View {
    let tx: Transmitter
    let receiver: Receiver
    @ObservedObject var store: MicStore
    @State private var editing = false
    @State private var draft = ""
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
            Button {
                store.send("device_record_tx", receiver: receiver, values: ["target": String(tx.index), "tx_serial": tx.serial, "value": tx.device_recording ? "0" : "1"])
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: tx.connected && tx.device_recording ? "stop.fill" : "record.circle")
                    Text(!tx.connected ? "OFFLINE" : tx.device_recording ? "TX REC" : "TX STOP")
                }.frame(maxWidth: .infinity, minHeight: 22)
            }.buttonStyle(.plain).foregroundStyle(tx.connected ? Color.red : Console.muted)
                .background(tx.connected && tx.device_recording ? Color.red.opacity(0.1) : Color.clear).clipShape(RoundedRectangle(cornerRadius: 3))
                .disabled(!tx.connected || tx.serial.isEmpty)
                .accessibilityLabel("TX\(tx.index) / \(receiver.serial.suffix(6)) 本体録音\(tx.device_recording ? "停止" : "開始")")
            BatteryIndicator(code: tx.battery_code, connected: tx.connected, charging: tx.charging)
            Text(tx.connected && tx.storage_total > 0 && tx.storage_remaining >= 0 && tx.storage_remaining <= tx.storage_total ? String(format: "空 %.0f%%", Double(tx.storage_remaining) / Double(tx.storage_total) * 100) : "空 —")
                .foregroundStyle(Console.muted)
            ProcessingControls(tx: tx, receiver: receiver, store: store)
        }.font(.system(size: 8, design: .monospaced)).padding(6).frame(maxWidth: .infinity).background(Console.strip)
    }
}

struct BatteryIndicator: View {
    let code: Int
    let connected: Bool
    let charging: Bool
    private var bars: Int? { connected ? Console.batteryBars(code) : nil }
    private var color: Color { guard let bars else { return Console.muted }; return bars <= 1 ? .red : bars <= 2 ? .orange : Color(white: 0.8) }
    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 2) {
                ForEach(0..<6, id: \.self) { segment in
                    RoundedRectangle(cornerRadius: 0.5).fill(segment < (bars ?? 0) ? color : Console.muted.opacity(0.2)).frame(width: 4, height: 8)
                }
            }.padding(3).overlay(RoundedRectangle(cornerRadius: 2).stroke(color.opacity(0.7), lineWidth: 1))
                .overlay(alignment: .trailing) { Rectangle().fill(color).frame(width: 2, height: 5).offset(x: 3) }
            if charging && connected { Image(systemName: "bolt.fill").foregroundStyle(Console.cyan).font(.system(size: 9)) }
            if bars == nil { Text("—").foregroundStyle(Console.muted) }
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel(bars.map { "電池残量 \($0) 段階 / 6\(charging ? "、充電中" : "")" } ?? "電池残量不明")
    }
}
