import SwiftUI
import AppKit

struct CompactChannel: View {
    let tx: Transmitter
    let receiver: Receiver
    @ObservedObject var store: MicStore
    @State private var editing = false
    var compact = false
    var showProcessing = true
    @State private var processing = false
    @State private var showingGain = false
    var narrow = false
    var availableMeterHeight: Double? = nil
    private var meterHeight: Double { availableMeterHeight ?? (compact ? 180 : 250) }
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
        VStack(spacing: 5) {
            Button { store.selectControl(ControlSelection(receiver: receiver.serial, transmitter: tx.serial)) } label: {
                HStack {
                    Text(String(format: "CH %02d", tx.index)).font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(tx.connected ? Color(white: 0.9) : Console.muted)
                    Spacer(); StatusDot(active: tx.connected)
                }.frame(maxWidth: .infinity, minHeight: 22).contentShape(Rectangle())
            }.buttonStyle(ConsoleSelectionButton(selected: !tx.serial.isEmpty && store.controlSelection.contains(ControlSelection(receiver: receiver.serial, transmitter: tx.serial)))).disabled(tx.serial.isEmpty).accessibilityLabel("TX\(tx.index) / \(receiver.serial.suffix(6)) を選択").help("⌘クリックで複数選択")
            Button { editing = true } label: {
                Text(tx.label.isEmpty ? "—" : tx.label).font(.system(size: compact ? 13 : 15, weight: .semibold))
                    .lineLimit(1).frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            }.buttonStyle(ConsoleSelectionButton(labelPlate: true)).help("人物ラベル・マイクの引き継ぎ").popover(isPresented: $editing) {
                LabelEditor(tx: tx, receiver: receiver, store: store)
            }
            HStack(spacing: 4) {
                Rectangle().fill(tx.connected ? Color.green : Console.muted.opacity(0.35)).frame(width: 5, height: 5)
                Text(tx.connected ? "LINK" : "OFFLINE").font(.system(size: 8, weight: .medium, design: .monospaced))
                Spacer(minLength: 0)
                Text(tx.serial.isEmpty ? "—" : String(tx.serial.suffix(4))).font(.system(size: 8, design: .monospaced))
            }.foregroundStyle(Console.muted)
            HStack(alignment: .top, spacing: 4) {
                ProductionMeter(feed: store.feed(receiver.serial), channel: tx.index - 1, height: meterHeight)
                if !narrow {
                    GainControl(tx: tx, receiver: receiver, store: store, height: meterHeight, compact: availableMeterHeight != nil || compact)
                }
            }
            if narrow {
                Button { showingGain = true } label: {
                    HStack {
                        Text("GAIN")
                        Spacer(minLength: 2)
                        Text(tx.gain_db.flatMap { (-12...12).contains($0) ? String(format: "%+d dB", $0) : nil } ?? "—")
                    }.font(.system(size: 8, design: .monospaced)).frame(maxWidth: .infinity, minHeight: 18)
                }.buttonStyle(ConsoleCompactButton(height: 20, padding: 3))
                    .disabled(!tx.connected || tx.serial.isEmpty)
                    .popover(isPresented: $showingGain) {
                        GainControl(tx: tx, receiver: receiver, store: store, height: 190).padding(16)
                    }
            }
            Toggle(isOn: Binding(get: { tx.settings?["mute"] == 1 }, set: { muted in
                store.send("setting", receiver: receiver, values: ["target": String(tx.index), "tx_serial": tx.serial, "key": "mute", "value": muted ? "1" : "0"])
            })) {
                HStack(spacing: 4) {
                    Rectangle().fill(tx.settings?["mute"] == 1 ? Console.cyan : Color(white: 0.28)).frame(width: 5, height: 5)
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
                    Circle().fill(tx.connected && tx.device_recording ? Color.red : Color(white: 0.28)).frame(width: 6, height: 6)
                    Text(tx.connected && tx.device_recording ? "REC / STOP" : "TX REC")
                }.frame(maxWidth: .infinity, minHeight: compact ? 24 : 28).contentShape(Rectangle())
            }.buttonStyle(ConsoleCompactButton(active: tx.connected && tx.device_recording, color: .red, padding: 0)).foregroundStyle(tx.connected ? Color.red : Console.muted)
                .disabled(!tx.connected || tx.serial.isEmpty)
                .accessibilityLabel("TX\(tx.index) / \(receiver.serial.suffix(6)) 本体録音\(tx.device_recording ? "停止" : "開始")")
            HStack {
                Text("BAT").foregroundStyle(Console.muted)
                Spacer(minLength: 2)
                BatteryIndicator(code: tx.battery_code, connected: tx.connected, charging: tx.charging)
            }.font(.system(size: 8, design: .monospaced))
            HStack {
                Text("FREE").foregroundStyle(Console.muted)
                Spacer()
                Text(storage).monospacedDigit()
            }.font(.system(size: 9, design: .monospaced)).help("本体ストレージの空き容量")
            Rectangle().fill(Console.line).frame(height: 1)
            if availableMeterHeight != nil {
                Button { store.selectControl(ControlSelection(receiver: receiver.serial, transmitter: tx.serial)) } label: {
                    HStack { Text("設定"); Spacer(); Image(systemName: "slider.horizontal.3") }.frame(maxWidth: .infinity, minHeight: 22)
                }.buttonStyle(ConsoleCompactButton()).disabled(tx.serial.isEmpty).accessibilityLabel("TX\(tx.index) 設定を表示")
            } else if showProcessing {
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
            Text(destinations.isEmpty ? "OUT —" : "OUT " + destinations.prefix(2).map { String(format: "%02d", $0) }.joined(separator: ",") + (destinations.count > 2 ? "+" : ""))
                .font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(Console.muted)
                .help(destinations.isEmpty ? "共通入力への割り当てなし" : "共通入力: " + destinations.map { "CH \($0)" }.joined(separator: ", "))
        }.font(.system(size: 9, design: .monospaced)).padding(.horizontal, availableMeterHeight != nil ? 6 : compact ? 7 : 10).padding(.vertical, 10).frame(maxWidth: .infinity).background(Console.strip)
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
