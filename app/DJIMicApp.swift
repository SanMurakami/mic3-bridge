import SwiftUI
import AppKit
import AVFoundation

@MainActor final class MicStore: ObservableObject {
    @Published var snapshot = Snapshot()
    @Published var failure = ""
    @Published var running = false
    @Published var settingsLocked = UserDefaults.standard.bool(forKey: "settingsLocked") {
        didSet { UserDefaults.standard.set(settingsLocked, forKey: "settingsLocked") }
    }
    @Published var recordingMode = UserDefaults.standard.string(forKey: "recordingMode") ?? "mac" {
        didSet { UserDefaults.standard.set(recordingMode, forKey: "recordingMode") }
    }
    var histories: [String: WaveHistory] = [:]
    let clock = LiveClock()
    private var feeds: [String: ReceiverFeed] = [:]
    func feed(_ serial: String) -> ReceiverFeed {
        if let existing = feeds[serial] { return existing }
        let created = ReceiverFeed(); feeds[serial] = created; return created
    }
    var timelineOrigin: Double?
    @Published var excluded: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "excludedReceivers") ?? []) {
        didSet { UserDefaults.standard.set(Array(excluded).sorted(), forKey: "excludedReceivers") }
    }
    var targets: [Receiver] { snapshot.receivers.filter { $0.connected && !excluded.contains($0.serial) } }
    var targetsBusy: Bool { targets.contains { $0.control_busy } }
    func bulk(_ op: String, values: [String: String] = [:]) {
        var command = values; command["serials"] = targets.map(\.serial).joined(separator: ",")
        send(op, values: command)
    }
    @Published var folder: URL
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var stderr: Pipe?
    private var stopping = false
    private var latest = Snapshot()
    private var visibilityObserver: NSObjectProtocol?
    private var visible = true
    private var perfStart = 0.0
    private var perfFrames = 0, perfControls = 0
    init() {
        folder = UserDefaults.standard.url(forKey: "recordingFolder") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/DJI Mic Recordings", isDirectory: true)
        visibilityObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.visible = NSApplication.shared.occlusionState.contains(.visible)
                if self.visible { self.snapshot = self.latest; self.perfStart = 0 }
            }
        }
    }
    func start() async {
        guard process == nil else { return }
        NSLog("DJI Mic 起動: マイク権限=%ld", AVCaptureDevice.authorizationStatus(for: .audio).rawValue)
        let allowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: allowed = true
        case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .audio)
        default: allowed = false
        }
        guard allowed else { failure = "システム設定の「プライバシーとセキュリティ → マイク」で DJI Mic 3 Bridge を許可してください。"; return }
        stopping = false; failure = ""
        let child = Process(), outgoing = Pipe(), incoming = Pipe(), errors = Pipe()
        child.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/dji-mic-bridge")
        child.standardInput = outgoing; child.standardOutput = incoming; child.standardError = errors
        // 受信と JSON decode は background。UI への反映だけ MainActor、約30Hz。
        let reader = SnapshotReader { [weak self] result, history in
            guard let self, self.running else { return }
            self.histories = history
            if self.timelineOrigin == nil { self.timelineOrigin = history.values.compactMap { $0.bins.first?.time }.min() }
            let now = result.host_seconds ?? 0
            let serials = Set(result.receivers.map(\.serial)); self.feeds = self.feeds.filter { serials.contains($0.key) }
            if self.visible {
                for r in result.receivers { self.feed(r.serial).update(r, now: now) }
                self.clock.now = now
            }
            if self.visible && !self.snapshot.sameControls(as: result) { self.snapshot = result; self.perfControls += 1 }
            else if self.snapshot.receivers.map(\.connected) != result.receivers.map(\.connected) || self.snapshot.receivers.map(\.serial) != result.receivers.map(\.serial) { self.snapshot = result }
            if self.visible {
                if self.perfStart == 0 { self.perfStart = now; self.perfFrames = 0; self.perfControls = 0 }
                self.perfFrames += 1
                if now - self.perfStart >= 10 {
                    NSLog("UI配送 %.1fHz / 制御画面更新 %d回 / %.1f秒", Double(self.perfFrames) / (now - self.perfStart), self.perfControls, now - self.perfStart)
                    self.perfStart = now; self.perfFrames = 0; self.perfControls = 0
                }
            }
            self.latest = result
        }
        incoming.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { reader.receive(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let line = String(data: data, encoding: .utf8), !line.isEmpty {
                NSLog("DJI Mic helper: %@", line)
            }
        }
        child.terminationHandler = { [weak self] child in
            Task { @MainActor in
                guard let self else { return }
                self.output?.fileHandleForReading.readabilityHandler = nil
                self.stderr?.fileHandleForReading.readabilityHandler = nil
                self.process = nil; self.input = nil; self.output = nil; self.stderr = nil; self.running = false
                self.snapshot.receivers = []
                if !self.stopping { self.failure = "音声サービスが終了しました（\(child.terminationStatus)）。再開してください。" }
            }
        }
        do {
            try child.run(); process = child; input = outgoing; output = incoming; stderr = errors; running = true
        } catch { failure = error.localizedDescription; NSLog("DJI Mic 起動失敗: %@", failure) }
    }
    func stop() { stopping = true; process?.terminate() }
    func send(_ op: String, receiver: Receiver, values: [String: String] = [:]) {
        var command = values; command["serial"] = receiver.serial; send(op, values: command)
    }
    func send(_ op: String, values: [String: String] = [:]) {
        let guarded: Set<String> = ["gain", "agc", "lossless", "audio_all", "noise", "tc", "tc_all", "route", "bus_channels", "delete", "rename"]
        guard !settingsLocked || !guarded.contains(op) else { return }
        var command = values; command["op"] = op
        do {
            var data = try JSONSerialization.data(withJSONObject: command); data.append(10)
            try input?.fileHandleForWriting.write(contentsOf: data)
        } catch { failure = error.localizedDescription }
    }
    func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false; panel.directoryURL = folder
        panel.prompt = "選択"
        if panel.runModal() == .OK, let chosen = panel.url {
            folder = chosen; UserDefaults.standard.set(chosen, forKey: "recordingFolder")
        }
    }
}
// FileHandle の callback は直列処理し、分割された UTF-8 / JSON 行を保持する。
final class SnapshotReader: @unchecked Sendable {
    private let lock = NSLock(), deliveryLock = NSLock()
    private var pending = Data()
    private var histories: [String: WaveHistory] = [:]
    private var delivery: (Snapshot, [String: WaveHistory])?
    private var scheduled = false
    private let receiveSnapshot: @MainActor @Sendable (Snapshot, [String: WaveHistory]) -> Void
    init(_ callback: @escaping @MainActor @Sendable (Snapshot, [String: WaveHistory]) -> Void) { receiveSnapshot = callback }
    func receive(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        pending.append(data)
        while let end = pending.firstIndex(of: 10) {
            let line = pending[..<end]; pending.removeSubrange(...end)
            if let value = try? JSONDecoder().decode(Snapshot.self, from: line) {
                let now = value.host_seconds ?? 0
                for r in value.receivers { histories[r.serial, default: WaveHistory()].append(r, now: now) }
                let serials = Set(value.receivers.map(\.serial)); histories = histories.filter { serials.contains($0.key) }
                deliveryLock.lock(); delivery = (value, histories); let enqueue = !scheduled; scheduled = true; deliveryLock.unlock()
                if enqueue { Task { @MainActor [self] in
                    if let value = takeDelivery() { receiveSnapshot(value.0, value.1) }
                } }
            }
        }
        if pending.count > 4_194_304 { pending.removeAll() }
    }
    private func takeDelivery() -> (Snapshot, [String: WaveHistory])? {
        deliveryLock.lock(); defer { deliveryLock.unlock() }
        let value = delivery; delivery = nil; scheduled = false; return value
    }
}

enum Console {
    static let cyan = Color(red: 0.35, green: 0.82, blue: 0.98)
    static let background = Color(red: 0.055, green: 0.067, blue: 0.082)
    static let panel = Color(red: 0.09, green: 0.105, blue: 0.125)
    static let strip = Color(red: 0.068, green: 0.08, blue: 0.097)
    static let line = Color.white.opacity(0.09)
    static let muted = Color(red: 0.48, green: 0.54, blue: 0.61)
    static let fps = ["23.98", "24", "25", "29.97", "29.97 DF", "30", "50", "60"]
    static let outputs = ["L-IN", "L-OUT", "A-OUT", "N/A"]
    static func batteryBars(_ code: Int) -> Int? { (1...7).contains(code) ? 7 - code : nil }
    static func fpsName(_ value: Int) -> String { fps.indices.contains(value) ? fps[value] : "—" }
    static func outputName(_ value: Int) -> String { outputs.indices.contains(value) ? outputs[value] : "—" }
}
struct ConsoleButton: ButtonStyle {
    var active = false
    var color = Color(white: 0.74)
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 11, weight: .semibold)).padding(.horizontal, 12).padding(.vertical, 9)
            .foregroundStyle(active ? Color.black : color)
            .background(active ? color : color.opacity(configuration.isPressed ? 0.22 : 0.08), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(color.opacity(0.3)))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
struct Readout: View {
    let title, value: String
    var color: Color = Color(white: 0.85)
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 9, weight: .semibold)).tracking(1.4).foregroundStyle(Console.muted)
            Text(value).font(.system(size: 15, weight: .medium, design: .monospaced)).foregroundStyle(color)
        }
    }
}
struct StatusDot: View {
    var active: Bool
    var color = Color.green
    var body: some View { Circle().fill(active ? color : Console.muted.opacity(0.4)).frame(width: 6, height: 6) }
}
struct MicrophoneStrip: View {
    let tx: Transmitter
    let receiver: Receiver
    let amplitude: Double
    @ObservedObject var store: MicStore
    @State private var editingLabel = false
    @State private var editingKey = ""
    @State private var draft = ""
    private var db: Double { amplitude > 0 ? 20 * log10(amplitude) : -90 }
    private var free: Double? {
        guard tx.connected, tx.storage_total > 0, tx.storage_remaining >= 0, tx.storage_remaining <= tx.storage_total else { return nil }
        return Double(tx.storage_remaining) / Double(tx.storage_total)
    }
    var body: some View {
        VStack(spacing: 13) {
            HStack {
                Text(String(format: "%02d", tx.index)).font(.system(size: 19, weight: .light, design: .monospaced)).foregroundStyle(Color(white: 0.78))
                Spacer()
                Text(tx.device_recording && tx.connected ? "● REC" : "TX \(tx.index)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(tx.device_recording && tx.connected ? .red : Console.muted)
            }
            Button {
                draft = tx.label; editingKey = tx.label_key; editingLabel = true
            } label: {
                HStack(spacing: 4) {
                    Text(tx.label.isEmpty ? "人物ラベルを追加" : tx.label).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "pencil").font(.system(size: 8))
                }.font(.system(size: 11, weight: .medium)).foregroundStyle(tx.label.isEmpty ? Console.muted : Color.white)
            }.buttonStyle(.plain)
                .popover(isPresented: $editingLabel) {
                    LabelEditor(tx: tx, receiver: receiver, store: store)
                }
            HStack(alignment: .top, spacing: 10) {
                ProductionMeter(feed: store.feed(receiver.serial), channel: tx.index - 1, height: 220)
                GainControl(tx: tx, receiver: receiver, store: store, height: 220)
            }.frame(maxWidth: .infinity)
            Rectangle().fill(Console.line).frame(height: 1)
            HStack {
                Text("BAT").font(.system(size: 9, weight: .semibold)).foregroundStyle(Console.muted)
                Spacer()
                if tx.charging && tx.connected { Image(systemName: "bolt.fill").foregroundStyle(Color(white: 0.78)) }
                if tx.connected, let bars = Console.batteryBars(tx.battery_code) {
                    HStack(spacing: 2) { ForEach(0..<6, id: \.self) { segment in
                        RoundedRectangle(cornerRadius: 1).fill(segment < bars ? (bars <= 1 ? Color.orange : Color(white: 0.72)) : Color.white.opacity(0.1)).frame(width: 5, height: 10)
                    } }
                    Text("\(bars)/6").font(.system(size: 10, design: .monospaced))
                } else { Text("—").font(.system(size: 10, design: .monospaced)) }
            }
            VStack(spacing: 5) {
                HStack {
                    Text("STORAGE").font(.system(size: 9, weight: .semibold)).foregroundStyle(Console.muted)
                    Spacer()
                    Text(free.map { String(format: "空き %.0f%%", $0 * 100) } ?? "—").font(.system(size: 10, design: .monospaced))
                }
                GeometryReader { p in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.white.opacity(0.07))
                        if let free { Rectangle().fill(free < 0.1 ? Color.orange : Color.white.opacity(0.38)).frame(width: p.size.width * free) }
                    }.clipShape(Capsule())
                }.frame(height: 3)
            }
            ProcessingControls(tx: tx, receiver: receiver, store: store)
            Text(tx.serial.isEmpty ? "CH \(tx.index) / 4" : tx.serial)
                .font(.system(size: 8, design: .monospaced)).foregroundStyle(Console.muted).lineLimit(1).textSelection(.enabled)
        }
        .padding(14).frame(maxWidth: .infinity)
        .background(Console.strip)

    }
    private func saveLabel() {
        store.send("label", receiver: receiver, values: ["label_key": editingKey, "label": draft]); editingLabel = false
    }
}
struct ReceiverCard: View {
    let receiver: Receiver
    @ObservedObject var store: MicStore
    @State private var editing = false
    @State private var draft = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Toggle("一括操作の対象", isOn: Binding(get: { !store.excluded.contains(receiver.serial) }, set: {
                    if $0 { store.excluded.remove(receiver.serial) } else { store.excluded.insert(receiver.serial) }
                })).toggleStyle(.checkbox).labelsHidden().disabled(!receiver.connected)
                StatusDot(active: receiver.connected)
                VStack(alignment: .leading, spacing: 4) {
                    Text(receiver.name).font(.system(size: 13, weight: .semibold))
                    Text("RX / \(receiver.serial)   ·   FW \(receiver.firmware)").font(.system(size: 9, design: .monospaced)).foregroundStyle(Console.muted).textSelection(.enabled)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(!receiver.tc.known ? "—:—:—:—" : receiver.tc.enabled ? receiver.tc.timecode : "TC OFF")
                        .font(.system(size: 18, weight: .medium, design: .monospaced)).foregroundStyle(receiver.tc.known ? Color(white: 0.82) : Console.muted)
                    Text(receiver.tc.known ? "\(Console.fpsName(receiver.tc.fps)) fps · \(Console.outputName(receiver.tc.output))" : "TC 状態未取得")
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(Console.muted)
                }
                Menu {
                    Button("入力名を変更…") { draft = receiver.name; editing = true }.disabled(store.settingsLocked)
                    Button("機器の状態を更新") { store.send("refresh_controls", receiver: receiver) }.disabled(!receiver.connected || receiver.control_busy)
                    Divider()
                    Button("登録を削除", role: .destructive) { store.send("delete", receiver: receiver) }.disabled(!receiver.can_delete || store.settingsLocked)
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }.menuStyle(.borderlessButton).fixedSize()
            }.padding(16)
            HStack(spacing: 1) {
                ForEach(receiver.transmitters) { tx in
                    MicrophoneStrip(tx: tx, receiver: receiver, amplitude: tx.index <= receiver.meters.count ? receiver.meters[tx.index - 1] : 0, store: store)
                }
            }.background(Console.line).padding(.horizontal, 1)
            HStack(spacing: 12) {
                Text(receiver.connected ? "USB ONLINE" : "OFFLINE")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(receiver.connected ? .green : Console.muted)
                LosslessControl(receiver: receiver, store: store)
                Text(Console.batteryBars(receiver.battery_code).map { "RX BAT \($0)/6\(receiver.charging ? " ⚡" : "")" } ?? "RX BAT —")
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(Console.muted)
                Spacer()
                ProgressView().controlSize(.mini).opacity(receiver.control_busy ? 1 : 0).frame(width: 12)
                if receiver.recording || receiver.recorded_seconds > 0 {
                    RecordingCounter(feed: store.feed(receiver.serial), recording: receiver.recording)
                }
                Button(receiver.recording ? "Mac 停止" : "Mac 録音") {
                    store.send(receiver.recording ? "stop" : "record", receiver: receiver, values: ["folder": store.folder.path])
                }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Color(white: 0.78)).disabled(!receiver.connected && !receiver.recording)
                if !receiver.recording_path.isEmpty {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: receiver.recording_path)]) } label: { Image(systemName: "folder") }
                        .buttonStyle(.plain).foregroundStyle(Console.muted)
                }
            }.padding(.horizontal, 16).padding(.vertical, 11)
            if !receiver.error.isEmpty {
                Label(receiver.error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange).textSelection(.enabled).padding([.horizontal, .bottom], 14)
            }
            if receiver.dropped > 0 { Text("転送待ち上限: \(receiver.dropped) blocks").font(.caption).foregroundStyle(.orange).padding(12) }
        }
        .background(Console.panel).clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Console.line))
        .sheet(isPresented: $editing) {
            VStack(alignment: .leading, spacing: 16) {
                Text("仮想入力の名前").font(.headline)
                TextField("名前", text: $draft).textFieldStyle(.roundedBorder)
                HStack { Spacer(); Button("キャンセル") { editing = false }; Button("保存") {
                    store.send("rename", receiver: receiver, values: ["name": draft]); editing = false
                }.keyboardShortcut(.defaultAction).disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }.padding(24).frame(width: 400)
        }
    }
}
struct MatrixView: View {
    @ObservedObject var store: MicStore
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("ROUTING MATRIX").font(.system(size: 20, weight: .light)).tracking(2)
                }
                Spacer()
                Picker("共通入力", selection: Binding(get: { store.snapshot.bus_channels }, set: { store.send("bus_channels", values: ["channels": String($0)]) })) {
                    ForEach([4,8,16,32,64], id: \.self) { Text("\($0) ch").tag($0) }
                }.frame(width: 190).disabled(store.snapshot.bus_in_use)
            }
            HStack { Text("DESTINATION").frame(width: 100, alignment: .leading); Text("SOURCE RECEIVER"); Spacer(); Text("SOURCE CH").frame(width: 90) }
                .font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(Console.muted)
            LazyVStack(spacing: 1) {
                ForEach(0..<store.snapshot.bus_channels, id: \.self) { destination in
                    let route = destination < store.snapshot.routes.count ? store.snapshot.routes[destination] : nil
                    HStack(spacing: 12) {
                        Text(String(format: "IN %02d", destination + 1)).font(.system(size: 13, design: .monospaced)).foregroundStyle(Color(white: 0.78)).frame(width: 88, alignment: .leading)
                        Picker("入力元 \(destination + 1)", selection: Binding(get: { route?.serial ?? "" }, set: { serial in
                            store.send("route", values: ["destination": String(destination + 1), "source_serial": serial, "channel": String(route?.channel ?? 1)])
                        })) {
                            Text("無音").tag("")
                            ForEach(store.snapshot.receivers) { r in Text("\(r.name)  /  \(r.serial)").tag(r.serial) }
                            if let route, !store.snapshot.receivers.contains(where: { $0.serial == route.serial }) { Text("\(route.serial)（未登録）").tag(route.serial) }
                        }.labelsHidden().frame(maxWidth: .infinity)
                        Image(systemName: "arrow.left").font(.caption).foregroundStyle(Console.muted)
                        Picker("入力 CH \(destination + 1)", selection: Binding(get: { route?.channel ?? 1 }, set: { channel in
                            store.send("route", values: ["destination": String(destination + 1), "source_serial": route?.serial ?? "", "channel": String(channel)])
                        })) { ForEach(1...4, id: \.self) { Text("CH \($0)").tag($0) } }
                            .labelsHidden().frame(width: 90).disabled(route == nil)
                    }.padding(12).background(destination % 2 == 0 ? Console.panel : Console.strip)
                }
            }
        }
    }
}
struct MainView: View {
    @ObservedObject var store: MicStore
    @State private var page = "overview"
    @State private var tcEnabled = true
    @State private var fps = 3
    @State private var outputMode = 3
    @State private var confirmTCOnly = false
    @State private var showingAudio = false
    @State private var showingTC = false
    private var connected: Int { store.snapshot.receivers.filter(\.connected).count }
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                header
                if page != "routing" { transport }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if !store.failure.isEmpty { errorBanner(store.failure) }
                        if !store.snapshot.error.isEmpty { errorBanner(store.snapshot.error) }
                        if page == "routing" { MatrixView(store: store).disabled(store.settingsLocked) }
                        else if page == "timeline" { RecordingTimeline(store: store) }
                        else if page == "overview" {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 400), spacing: 14)], spacing: 14) {
                                ForEach(store.snapshot.receivers) { ReceiverOverview(receiver: $0, store: store) }
                            }
                        }
                        else {
                            HStack {
                                Text("RECEIVER RACK").font(.system(size: 10, weight: .semibold)).tracking(2).foregroundStyle(Console.muted)
                                Spacer()
                                Text("4 CH / RX · 48 kHz").font(.system(size: 10, design: .monospaced)).foregroundStyle(Console.muted)
                            }
                            if store.snapshot.receivers.isEmpty {
                                ContentUnavailableView("接続なし", systemImage: "cable.connector")
                            }
                            ForEach(store.snapshot.receivers) { ReceiverCard(receiver: $0, store: store) }
                            if store.snapshot.unidentified > 0 { Text("\(store.snapshot.unidentified) 台の個体情報を確認中…").font(.caption).foregroundStyle(Console.muted) }
                        }
                    }.padding(24)
                }
                footer
            }
        }
        .frame(minWidth: 1060, minHeight: 730)
        .background(Console.background).foregroundStyle(Color(white: 0.88))
        .tint(Color(white: 0.65)).preferredColorScheme(.dark)
        .sheet(isPresented: $showingAudio) { BatchAudioPanel(store: store) }
        .alert("USB 音声を TC に切り替えます", isPresented: $confirmTCOnly) {
            Button("キャンセル", role: .cancel) { }
            Button("適用", action: applyTC)
        } message: { Text("L-OUT では USB 全4chがTC信号になります。") }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) { Rectangle().fill(Console.cyan).frame(width: 3, height: 25); Text("MIC 3 BRIDGE").font(.system(size: 18, weight: .bold)).tracking(1) }
            }.padding(.top, 10)
            VStack(spacing: 5) {
                nav("overview", "一覧", "square.grid.2x2")
                nav("timeline", "タイムライン", "waveform.path")
                nav("mixer", "受信・収録", "slider.vertical.3")
                nav("routing", "ルーティング", "point.3.connected.trianglepath.dotted")
            }
            Rectangle().fill(Console.line).frame(height: 1)
            ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("SESSION TARGETS").font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(Console.muted)
                ForEach(store.snapshot.receivers) { r in
                    Button {
                        if store.excluded.contains(r.serial) { store.excluded.remove(r.serial) } else { store.excluded.insert(r.serial) }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: store.excluded.contains(r.serial) ? "square" : "checkmark.square.fill").foregroundStyle(r.connected ? Color(white: 0.75) : Console.muted)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(r.name).font(.system(size: 10)).lineLimit(1)
                                Text(String(r.serial.suffix(6))).font(.system(size: 9, design: .monospaced)).foregroundStyle(Console.muted)
                            }
                            Spacer(minLength: 0)
                            StatusDot(active: r.connected)
                        }
                    }.buttonStyle(.plain).disabled(!r.connected)
                }
                Button("接続中をすべて選択") { store.excluded.removeAll() }.font(.system(size: 10)).foregroundStyle(Color(white: 0.78)).buttonStyle(.plain)
            }
            }.scrollIndicators(.hidden)
            VStack(alignment: .leading, spacing: 14) {
                Readout(title: "MATRIX INPUT", value: "\(store.snapshot.bus_channels) CHANNELS")
                Text(store.snapshot.bus_in_use ? "● DAW ACTIVE" : "○ DAW IDLE").font(.system(size: 9, design: .monospaced)).foregroundStyle(Console.muted)
            }
        }.padding(20).frame(width: 198).frame(maxHeight: .infinity).background(Console.strip)
            .overlay(alignment: .trailing) { Rectangle().fill(Console.line).frame(width: 1) }
    }
    private func nav(_ id: String, _ title: String, _ icon: String) -> some View {
        Button { page = id } label: {
            HStack(spacing: 10) { Image(systemName: icon).frame(width: 18); Text(title).font(.system(size: 12, weight: .medium)); Spacer() }
                .foregroundStyle(page == id ? Color(white: 0.9) : Console.muted).padding(12)
                .background(page == id ? Color.white.opacity(0.04) : .clear, in: RoundedRectangle(cornerRadius: 4))
                .overlay(alignment: .leading) { if page == id { Rectangle().fill(Console.cyan).frame(width: 2, height: 18) } }
        }.buttonStyle(.plain)
    }
    private var header: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(["overview": "一覧", "mixer": "受信・収録", "timeline": "タイムライン", "routing": "ルーティング"][page] ?? "").font(.system(size: 22, weight: .light))
            }
            Spacer()
            SessionRecordStatus(store: store)
            Button { store.settingsLocked.toggle() } label: {
                Image(systemName: store.settingsLocked ? "lock.fill" : "lock.open").foregroundStyle(store.settingsLocked ? Console.cyan : Console.muted)
            }.buttonStyle(ConsoleButton()).accessibilityLabel(store.settingsLocked ? "設定ロックを解除" : "設定をロック")
            Button("一括設定") { showingAudio = true }.buttonStyle(ConsoleButton()).disabled(store.targets.isEmpty || store.settingsLocked)
            Readout(title: "ONLINE", value: String(format: "%02d RX", connected))
            Readout(title: "SELECTED", value: String(format: "%02d RX", store.targets.count))
            Button { store.bulk("refresh_all") } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(ConsoleButton()).disabled(store.targets.isEmpty || store.targetsBusy)
        }.padding(.horizontal, 24).padding(.vertical, 20)
            .overlay(alignment: .bottom) { Rectangle().fill(Console.line).frame(height: 1) }
    }
    private var transport: some View {
        HStack(spacing: 14) {
            Button {
                if let tc = store.targets.first?.tc, tc.known { tcEnabled = tc.enabled; fps = tc.fps; outputMode = tc.output }
                showingTC = true
            } label: { Label("TC", systemImage: "clock") }
                .buttonStyle(ConsoleButton()).popover(isPresented: $showingTC) { tcPanel }
            Rectangle().fill(Console.line).frame(width: 1, height: 22)
            Picker("収録先", selection: $store.recordingMode) {
                Text("Mac").tag("mac"); Text("本体").tag("device"); Text("両方").tag("both")
            }.pickerStyle(.segmented).labelsHidden().frame(width: 190)
            Spacer()
            Button { recording(start: true) } label: { Label("一括収録開始", systemImage: "record.circle") }
                .buttonStyle(ConsoleButton(active: true, color: .red)).disabled(store.targets.isEmpty || (store.recordingMode != "mac" && store.targetsBusy))
            Button { recording(start: false) } label: { Label("停止", systemImage: "stop.fill") }
                .buttonStyle(ConsoleButton()).disabled(store.targets.isEmpty)
        }.padding(.horizontal, 24).padding(.vertical, 12).background(Console.panel)
            .overlay(alignment: .bottom) { Rectangle().fill(Console.line).frame(height: 1) }
    }
    private var tcPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("TIMECODE").font(.system(size: 16, weight: .medium))
            Toggle(tcEnabled ? "TC ON" : "TC OFF", isOn: $tcEnabled).toggleStyle(.switch).tint(Console.cyan).foregroundStyle(Console.cyan)
            Picker("FPS", selection: $fps) { ForEach(0..<Console.fps.count, id: \.self) { Text(Console.fps[$0]).tag($0) } }
            Picker("出力", selection: $outputMode) { ForEach(0..<Console.outputs.count, id: \.self) { Text(["L-IN · TC入力", "L-OUT · USB全ch TC", "A-OUT · CH1 TC", "N/A · 音声4ch"][$0]).tag($0) } }
            HStack { Spacer(); Button("選択RXへ適用") {
                showingTC = false
                if tcEnabled && outputMode == 1 { confirmTCOnly = true } else { applyTC() }
            }.buttonStyle(ConsoleButton()).disabled(store.targets.isEmpty || store.targetsBusy || store.settingsLocked) }
        }.padding(24).frame(width: 350).disabled(store.settingsLocked)
    }
    private func applyTC() {
        store.bulk("tc_all", values: ["enabled": tcEnabled ? "1" : "0", "fps": String(fps), "output": String(outputMode)])
    }
    private func recording(start: Bool) {
        if store.recordingMode != "device" { store.bulk(start ? "record_all" : "stop_all", values: ["folder": store.folder.path]) }
        if store.recordingMode != "mac" { store.bulk(start ? "device_record_all" : "device_stop_all") }
    }
    private var footer: some View {
        HStack(spacing: 10) {
            StatusDot(active: store.running)
            Text(store.running ? "ENGINE ONLINE" : "ENGINE OFFLINE").font(.system(size: 9, design: .monospaced)).foregroundStyle(store.running ? .green : Console.muted)
            Rectangle().fill(Console.line).frame(width: 1, height: 12)
            Button("録音先…") { store.chooseFolder() }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Color(white: 0.78))
            Text(store.folder.path).font(.system(size: 9, design: .monospaced)).foregroundStyle(Console.muted).lineLimit(1).truncationMode(.middle)
            Spacer()
            if !store.running { Button("再開") { Task { await store.start() } }.buttonStyle(ConsoleButton()) }
            Text("CAF / 32-BIT FLOAT").font(.system(size: 9, design: .monospaced)).foregroundStyle(Console.muted)
        }.padding(.horizontal, 20).padding(.vertical, 12).background(Console.strip)
    }
    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange).textSelection(.enabled)
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = MicStore()
    func applicationDidFinishLaunching(_ notification: Notification) { Task { await store.start() } }
    func applicationWillTerminate(_ notification: Notification) { store.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
@main struct DJIMicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private var store: MicStore { delegate.store }
    var body: some Scene {
        Window("DJI Mic 3 Bridge", id: "main") {
            MainView(store: store)
        }.defaultSize(width: 1240, height: 920)
        MenuBarExtra("DJI Mic 3 Bridge", systemImage: "mic.fill") {
            MenuContent(store: store)
        }
    }
}
struct MenuContent: View {
    @ObservedObject var store: MicStore
    @Environment(\.openWindow) var openWindow
    var body: some View {
        Text("\(store.snapshot.receivers.filter(\.connected).count) 台接続")
        Button("ウィンドウを表示") { openWindow(id: "main"); NSApplication.shared.activate(ignoringOtherApps: true) }
        Divider()
        Button("終了（音声転送も停止）") { NSApplication.shared.terminate(nil) }
    }
}
