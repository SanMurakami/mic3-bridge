import SwiftUI
import AppKit

struct ReceiverOverview: View {
    let receiver: Receiver
    @ObservedObject var store: MicStore
    var compact = false
    var showProcessing = true
    @State private var editingName = false
    @State private var name = ""
    var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: 8) {
                Toggle("一括操作の対象", isOn: Binding(get: { !store.excluded.contains(receiver.serial) }, set: {
                    if $0 { store.excluded.remove(receiver.serial) } else { store.excluded.insert(receiver.serial) }
                })).toggleStyle(.checkbox).labelsHidden().disabled(!receiver.connected)
                StatusDot(active: receiver.connected)
                Button { store.selectControl(ControlSelection(receiver: receiver.serial)) } label: {
                    Text(receiver.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                }.buttonStyle(ConsoleCompactButton(active: store.controlSelection.contains(ControlSelection(receiver: receiver.serial)))).accessibilityLabel("RX \(receiver.serial.suffix(6)) を選択")
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
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 26).contentShape(Rectangle()) }.menuStyle(.borderlessButton).fixedSize()

            }.font(.system(size: 9, weight: .semibold, design: .monospaced)).padding(.horizontal, 12).frame(height: 44)
            HStack { LosslessControl(receiver: receiver, store: store); Spacer(); BatteryIndicator(code: receiver.battery_code, connected: receiver.connected, charging: receiver.charging).accessibilityLabel("レシーバー電池") }.padding(.horizontal, 12).padding(.bottom, 10)
            HStack(spacing: 1) {
                ForEach(receiver.transmitters) { tx in
                    CompactChannel(tx: tx, receiver: receiver, store: store, compact: compact, showProcessing: showProcessing)
                }
            }.background(Console.line)
            HStack {
                Text(String(receiver.serial.suffix(6)))
                Spacer()
                LiveTimecode(receiver: receiver, feed: store.feed(receiver.serial))
                Text(Console.fpsName(receiver.tc.fps))
            }.font(.system(size: 10, design: .monospaced)).foregroundStyle(Console.muted).padding(.horizontal, 12).frame(height: 34)
            if !receiver.error.isEmpty { Text(receiver.error).font(.caption).foregroundStyle(.orange).padding(8) }
        }.background(Console.panel).clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(store.controlSelection.contains(ControlSelection(receiver: receiver.serial)) ? Console.cyan.opacity(0.7) : receiver.connected ? Console.line : Console.muted.opacity(0.2), lineWidth: 1))
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
    var compact = false
    var showProcessing = true
    @State private var processing = false
    private var meterHeight: Double { compact ? 180 : 250 }
    private var destinations: [Int] {
        store.snapshot.routes.enumerated().compactMap { offset, route in
            offset < store.snapshot.bus_channels && route?.serial == receiver.serial && route?.channel == tx.index ? offset + 1 : nil
        }
    }
    private var storage: String {
        guard tx.connected, tx.storage_total > 0, (0...tx.storage_total).contains(tx.storage_remaining) else { return "—" }
        return String(format: "%.0f%%", Double(tx.storage_remaining) / Double(tx.storage_total) * 100)
    }
    var body: some View {
        VStack(spacing: compact ? 7 : 10) {
            Button { store.selectControl(ControlSelection(receiver: receiver.serial, transmitter: tx.serial)) } label: {
                HStack {
                    Text(String(format: "%02d", tx.index)).font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(tx.connected ? Color(white: 0.9) : Console.muted)
                    Spacer(); StatusDot(active: tx.connected)
                }.frame(maxWidth: .infinity, minHeight: 22).contentShape(Rectangle())
            }.buttonStyle(ConsoleCompactButton(active: !tx.serial.isEmpty && store.controlSelection.contains(ControlSelection(receiver: receiver.serial, transmitter: tx.serial)), color: Console.cyan, height: 22, padding: 3)).disabled(tx.serial.isEmpty).accessibilityLabel("TX\(tx.index) / \(receiver.serial.suffix(6)) を選択").help("⌘クリックで複数選択")
            Button { editing = true } label: {
                Text(tx.label.isEmpty ? "—" : tx.label).font(.system(size: compact ? 11 : 13, weight: .semibold))
                    .lineLimit(1).frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            }.buttonStyle(ConsoleCompactButton()).help("人物ラベル・マイクの引き継ぎ").popover(isPresented: $editing) {
                LabelEditor(tx: tx, receiver: receiver, store: store)
            }
            HStack(alignment: .top, spacing: 1) {
                ProductionMeter(feed: store.feed(receiver.serial), channel: tx.index - 1, height: meterHeight)
                GainControl(tx: tx, receiver: receiver, store: store, height: meterHeight, compact: compact)
            }
            Toggle(isOn: Binding(get: { tx.settings?["mute"] == 1 }, set: { muted in
                store.send("setting", receiver: receiver, values: ["target": String(tx.index), "tx_serial": tx.serial, "key": "mute", "value": muted ? "1" : "0"])
            })) {
                HStack(spacing: 4) {
                    Image(systemName: tx.settings?["mute"] == 1 ? "mic.slash.fill" : "mic.fill")
                    Text("MUTE")
                    Text(tx.settings?["mute"].map { $0 == 1 ? "ON" : "OFF" } ?? "—").foregroundStyle(Console.cyan)
                }.frame(maxWidth: .infinity, minHeight: compact ? 24 : 28).contentShape(Rectangle())
            }.toggleStyle(.button).buttonStyle(ConsoleCompactButton(active: tx.settings?["mute"] == 1, color: Console.cyan, padding: 0))
                .foregroundStyle(tx.settings?["mute"] == 1 ? Console.cyan : Console.muted)
                .disabled(!tx.connected || tx.serial.isEmpty || tx.settings?["mute"] == nil || store.settingsLocked)
                .accessibilityLabel("TX\(tx.index) / \(receiver.serial.suffix(6)) ミュート")
                .help("送信機のミュート")
            Button {
                store.send("device_record_tx", receiver: receiver, values: ["target": String(tx.index), "tx_serial": tx.serial, "value": tx.device_recording ? "0" : "1"])
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: tx.connected && tx.device_recording ? "stop.fill" : "record.circle")
                    Text(!tx.connected ? "OFFLINE" : "REC")
                }.frame(maxWidth: .infinity, minHeight: compact ? 24 : 28).contentShape(Rectangle())
            }.buttonStyle(ConsoleCompactButton(active: tx.connected && tx.device_recording, color: .red, padding: 0)).foregroundStyle(tx.connected ? Color.red : Console.muted)
                .disabled(!tx.connected || tx.serial.isEmpty)
                .accessibilityLabel("TX\(tx.index) / \(receiver.serial.suffix(6)) 本体録音\(tx.device_recording ? "停止" : "開始")")
            BatteryIndicator(code: tx.battery_code, connected: tx.connected, charging: tx.charging)
            HStack(spacing: 4) { Image(systemName: "internaldrive"); Text(storage) }.foregroundStyle(Console.muted).help("本体ストレージの空き容量")
            Rectangle().fill(Console.line).frame(height: 1)
            if showProcessing {
                ProcessingControls(tx: tx, receiver: receiver, store: store)
            } else {
                Button { processing = true } label: { Label("処理", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity, minHeight: 22) }
                    .buttonStyle(ConsoleCompactButton()).foregroundStyle(Console.muted).accessibilityLabel("TX\(tx.index) / \(receiver.serial.suffix(6)) 処理設定").popover(isPresented: $processing) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("CH \(tx.index) · \(tx.label.isEmpty ? String(receiver.serial.suffix(6)) : tx.label)").font(.headline)
                            ProcessingControls(tx: tx, receiver: receiver, store: store)
                            Text(tx.serial.isEmpty ? "—" : tx.serial).font(.system(size: 9, design: .monospaced)).foregroundStyle(Console.muted).textSelection(.enabled)
                        }.padding(18).frame(width: 230)
                    }
            }
            Text(destinations.isEmpty ? "M —" : "M " + destinations.prefix(2).map { String(format: "%02d", $0) }.joined(separator: ",") + (destinations.count > 2 ? "+" : ""))
                .font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(Console.muted)
                .help(destinations.isEmpty ? "共通入力への割り当てなし" : "共通入力: " + destinations.map { "CH \($0)" }.joined(separator: ", "))
        }.font(.system(size: 9, design: .monospaced)).padding(.horizontal, compact ? 8 : 12).padding(.vertical, 10).frame(maxWidth: .infinity).background(Console.strip)
            .overlay(alignment: .top) { if !tx.serial.isEmpty && store.controlSelection.contains(ControlSelection(receiver: receiver.serial, transmitter: tx.serial)) { Rectangle().fill(Console.cyan).frame(height: 2) } }
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
