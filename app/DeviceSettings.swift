import SwiftUI
import AppKit

extension MicStore {
    func selectControl(_ selection: ControlSelection) {
        let extending = NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift)
        let sameKind = controlSelection.allSatisfy { ($0.transmitter == nil) == (selection.transmitter == nil) }
        if extending && sameKind {
            if controlSelection.contains(selection) { controlSelection.remove(selection) } else { controlSelection.insert(selection) }
        } else { controlSelection = [selection] }
        inspectorVisible = true
    }
}

struct DeviceInspector: View {
    @ObservedObject var store: MicStore
    @State private var confirmingLoop = false
    @State private var recordingExpanded = true
    @State private var hardwareExpanded = false
    private var isTX: Bool { store.controlSelection.contains { $0.transmitter != nil } }
    private var selected: [(Receiver, Transmitter?)] { store.snapshot.controlTargets(store.controlSelection) }
    private var live: [(Receiver, Transmitter?)] { selected.filter { $0.0.connected && (!isTX || $0.1?.connected == true) } }
    private func common(_ getter: (Receiver, Transmitter?) -> Int?) -> Int {
        let values = selected.compactMap { item -> Int? in guard let value = getter(item.0,item.1), value >= 0 else { return nil }; return value }
        guard values.count == selected.count, let value = values.first else { return -2 }
        return values.allSatisfy { $0 == value } ? value : -1
    }
    private func settingValue(_ key: String) -> Int { common { rx, tx in (isTX ? tx?.settings : rx.settings)?[key] } }
    private func apply(_ key: String, _ value: Int) {
        for (rx, tx) in live where (isTX ? tx?.settings : rx.settings)?[key] != nil {
            store.send("setting", receiver: rx, values: ["target": String(tx?.index ?? 0), "tx_serial": tx?.serial ?? "-", "key": key, "value": String(value)])
        }
    }
    private func audio(_ op: String, _ value: Int) {
        for (rx, tx) in live {
            if op == "noise", let tx {
                store.send("noise", receiver: rx, values: ["target": String(tx.index), "tx_serial": tx.serial, "mode": ["none","basic","strong"][value]])
            }
            else if op == "lossless" { store.send(op, receiver: rx, values: ["enabled": String(value)]) }
            else if let tx {
                let name = op == "low_cut" ? "value" : "mode"
                store.send(op, receiver: rx, values: ["target": String(tx.index), "tx_serial": tx.serial, name: String(value)])
            }
        }
    }
    private func row(_ title: String, value: Int, options: [(Int, String)], disabled: Bool = false, action: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(Color(white: 0.76))
            Spacer(minLength: 4)
            Group {
                if options.map(\.1) == ["OFF", "ON"] {
                    HStack(spacing: 1) {
                        ForEach(options, id: \.0) { option in
                            Button { action(option.0) } label: {
                                Text(option.1).font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundStyle(value == option.0 ? Console.cyan : Console.muted)
                                    .frame(maxWidth: .infinity, minHeight: 23).contentShape(Rectangle())
                                    .background(value == option.0 ? Color(white: 0.19) : Color.clear, in: RoundedRectangle(cornerRadius: 2))
                            }.buttonStyle(ConsoleCompactButton(active: value == option.0, color: Console.cyan, height: 23, padding: 0)).accessibilityLabel("\(title) \(option.1)")
                        }
                    }.padding(2).background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 3))
                        .overlay(alignment: .leading) { if value == -1 { Text("混在").font(.system(size: 8)).foregroundStyle(Console.muted).offset(x: -30) } }
                        .frame(width: 116)
                } else {
                    Picker(title, selection: Binding(get: { value }, set: action)) {
                        if value < 0 { Text(value == -1 ? "混在" : "—").tag(value) }
                        ForEach(options, id: \.0) { option in Text(option.1).tag(option.0) }
                    }.labelsHidden().pickerStyle(.menu).frame(width: 116).controlSize(.small)
                }
            }.disabled(disabled || live.isEmpty || store.settingsLocked || value == -2)
        }.frame(minHeight: 29)
    }
    private func boolean(_ title: String, _ key: String, sensitive: Bool = false) -> some View {
        row(title, value: settingValue(key), options: [(0,"OFF"),(1,"ON")], disabled: sensitive && live.contains { $0.1?.device_recording == true }) { value in
            if key == "loop_record" && value == 1 { confirmingLoop = true } else { apply(key, value) }
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("INSPECTOR").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(Console.muted)
                Spacer()
                Button { store.inspectorVisible = false } label: { Image(systemName: "sidebar.right") }.buttonStyle(ConsoleCompactButton(minWidth: 24)).accessibilityLabel("インスペクターを閉じる")
            }.padding(14).frame(height: 44)
            Divider()
            HStack(spacing: 8) {
                Button("全TX") { store.controlSelection = Set(store.targets.flatMap { rx in rx.transmitters.filter { $0.connected && !$0.serial.isEmpty }.map { ControlSelection(receiver: rx.serial, transmitter: $0.serial) } }) }
                Button("全RX") { store.controlSelection = Set(store.targets.map { ControlSelection(receiver: $0.serial) }) }
                Spacer()
                Text("\(selected.count) \(isTX ? "TX" : "RX")").monospacedDigit().foregroundStyle(Console.muted)
            }.buttonStyle(ConsoleButton()).padding(12)
            if selected.isEmpty {
                Spacer(); Image(systemName: "slider.horizontal.3").font(.title2).foregroundStyle(Console.muted); Text("チャンネルを選択").foregroundStyle(Console.muted).padding(.top, 8); Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 5) {
                            if selected.count == 1, let (rx, tx) = selected.first {
                                Text(tx.map { $0.label.isEmpty ? "TX \($0.index)" : $0.label } ?? rx.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                                Text(tx?.serial ?? rx.serial).font(.system(size: 9, design: .monospaced)).foregroundStyle(Console.muted).textSelection(.enabled)
                            } else { Text("\(selected.count) \(isTX ? "マイク" : "レシーバー") 選択").font(.headline) }
                        }.padding(.bottom, 2)
                        if isTX {
                            section("音声") {
                                row("自動ゲイン", value: common { _, tx in tx?.agc }, options: [(0,"OFF"),(1,"Automatic"),(2,"Dynamic")]) { audio("agc", $0) }
                                row("ノイキャン", value: common { _, tx in ["none":0,"basic":1,"strong":2][tx?.noise_mode ?? ""] }, options: [(0,"OFF"),(1,"BASIC"),(2,"STRONG")]) { audio("noise", $0) }
                                row("音質", value: common { _, tx in tx?.eq }, options: [(0,"Regular"),(1,"Rich"),(2,"Bright")]) { audio("eq", $0) }
                                row("Low Cut", value: common { _, tx in tx?.low_cut }, options: [(0,"OFF"),(1,"ON")]) { audio("low_cut", $0) }
                                boolean("ミュート", "mute")
                            }
                            DisclosureGroup("本体録音", isExpanded: $recordingExpanded) {
                                VStack(spacing: 0) {
                                    boolean("32-bit float", "float_recording", sensitive: true)
                                    boolean("起動時録音", "auto_record")
                                    boolean("低電力時録音", "low_power_record")
                                    boolean("ループ録音", "loop_record", sensitive: true)
                                }.padding(.top, 6)
                            }
                            Divider()
                            DisclosureGroup("操作・電源", isExpanded: $hardwareExpanded) {
                                VStack(spacing: 0) {
                                    boolean("録音ボタン", "record_button")
                                    boolean("NCボタン", "noise_button")
                                    boolean("振動", "vibration")
                                    boolean("自動電源OFF", "auto_off")
                                }.padding(.top, 6)
                            }
                        } else {
                            section("無線") { row("ロスレス", value: common { rx, _ in rx.lossless }, options: [(0,"OFF"),(1,"ON")]) { audio("lossless", $0) } }
                            section("電源") { boolean("自動電源OFF", "auto_off"); boolean("カメラ連動", "camera_power") }
                        }
                        ForEach(store.snapshot.receivers.filter { rx in !rx.error.isEmpty && selected.contains { $0.0.serial == rx.serial } }) { rx in Text(rx.error).font(.caption).foregroundStyle(.orange) }
                    }.padding(14)
                }
            }
            Divider()
            HStack { Image(systemName: store.settingsLocked ? "lock.fill" : "lock.open"); Text(store.settingsLocked ? "LOCK" : "EDIT"); Spacer(); if live.count < selected.count { Text("\(selected.count-live.count) OFFLINE") } }.font(.system(size: 9, design: .monospaced)).foregroundStyle(Console.muted).padding(12)
        }.font(.system(size: 11)).frame(width: 280).background(Console.panel)
        .confirmationDialog("ストレージが一杯になると古い録音を上書きします。", isPresented: $confirmingLoop, titleVisibility: .visible) {
            Button("ループ録音を有効にする", role: .destructive) { apply("loop_record", 1) }
        }
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(Console.muted); VStack(spacing: 0, content: content) }; }
}
