import SwiftUI
import AppKit
import AVFoundation

@MainActor final class MicStore: ObservableObject {
    @Published var controlSelection: Set<ControlSelection> = []
    @Published var inspectorVisible = false
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
        let guarded: Set<String> = ["setting", "gain", "agc", "eq", "low_cut", "lossless", "audio_all", "noise", "tc", "tc_all", "tc_sync_all", "route", "bus_channels", "delete", "rename"]
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
    static let background = Color(white: 0.065)
    static let panel = Color(white: 0.15)
    static let strip = Color(white: 0.115)
    static let line = Color.white.opacity(0.08)
    static let muted = Color(white: 0.60)
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
            .contentShape(Rectangle())
            .foregroundStyle(active ? Color.black : color)
            .modifier(ConsoleButtonFace(active: active, color: color, pressed: configuration.isPressed, solid: true))
    }
}

struct StatusDot: View {
    var active: Bool
    var color = Color.green
    var body: some View { Circle().fill(active ? color : Console.muted.opacity(0.4)).frame(width: 6, height: 6) }
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
    @State private var showingTC = false
    private var connected: Int { store.snapshot.receivers.filter(\.connected).count }
    var body: some View {
        VStack(spacing: 0) {
                header
                if page != "routing" { transport }
                if page == "overview" {
                    HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        errors
                        ConsoleOverview(store: store)
                    }
                    if store.inspectorVisible { Divider(); DeviceInspector(store: store) }
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            errors
                            if page == "routing" { MatrixView(store: store).disabled(store.settingsLocked) }
                            else { RecordingTimeline(store: store) }
                        }.padding(16)
                    }
                }
                footer
        }
        .frame(minWidth: 1060, minHeight: 730)
        .background(Console.background).foregroundStyle(Color(white: 0.88))
        .tint(Color(white: 0.65)).preferredColorScheme(.dark)
        .focusEffectDisabled()
        .alert("USB 音声を TC に切り替えます", isPresented: $confirmTCOnly) {
            Button("キャンセル", role: .cancel) { }
            Button("適用", action: applyTC)
        } message: { Text("L-OUT では USB 全4chがTC信号になります。") }
    }
    @ViewBuilder private var errors: some View {
        if !store.failure.isEmpty { errorBanner(store.failure) }
        if !store.snapshot.error.isEmpty { errorBanner(store.snapshot.error) }
    }
    private func nav(_ id: String, _ title: String, _ icon: String, _ key: KeyEquivalent) -> some View {
        Button { page = id } label: {
            Label(title, systemImage: icon).font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 14).frame(height: 42)
                .foregroundStyle(page == id ? Color.white : Console.muted)
                .background(page == id ? Color.white.opacity(0.06) : .clear)
                .overlay(alignment: .bottom) { if page == id { Rectangle().fill(Console.cyan).frame(height: 2) } }
        }.buttonStyle(ConsoleSelectionButton(selected: page == id)).keyboardShortcut(key, modifiers: .command)
    }
    private var header: some View {
        HStack(spacing: 8) {
            Text("MIC 3 BRIDGE").font(.system(size: 11, weight: .bold)).tracking(1.5).padding(.horizontal, 18)
            nav("overview", "一覧", "slider.vertical.3", "1")
            nav("timeline", "タイムライン", "waveform.path", "2")
            nav("routing", "ルーティング", "point.3.connected.trianglepath.dotted", "3")
            Spacer(minLength: 12)
            SessionRecordStatus(store: store).padding(.trailing, 16)
            Menu {
                Button("接続中をすべて選択") { store.excluded.removeAll() }
                Button("選択を解除") { store.excluded.formUnion(store.snapshot.receivers.map(\.serial)) }
                Divider()
                ForEach(store.snapshot.receivers) { r in
                    Toggle(r.name, isOn: Binding(get: { !store.excluded.contains(r.serial) }, set: {
                        if $0 { store.excluded.remove(r.serial) } else { store.excluded.insert(r.serial) }
                    })).disabled(!r.connected)
                }
            } label: { Text("対象 \(store.targets.count) / \(connected) RX").font(.system(size: 10, weight: .medium, design: .monospaced)) }
                .menuStyle(.borderlessButton).fixedSize().padding(.trailing, 18)
            Button { store.settingsLocked.toggle() } label: {
                Label(store.settingsLocked ? "LOCK" : "設定", systemImage: store.settingsLocked ? "lock.fill" : "lock.open")
            }.buttonStyle(ConsoleButton(active: store.settingsLocked, color: store.settingsLocked ? Console.cyan : Color(white: 0.74)))
                .keyboardShortcut("l", modifiers: .command).accessibilityLabel(store.settingsLocked ? "設定ロックを解除" : "設定をロック").help("設定ロック ⌘L")
            Button { store.inspectorVisible.toggle() } label: { Label("インスペクター", systemImage: "sidebar.right") }
                .buttonStyle(ConsoleButton(active: store.inspectorVisible)).keyboardShortcut("i", modifiers: [.command, .option])
        }.padding(.trailing, 8).frame(height: 48).background(Console.strip)
            .overlay(alignment: .bottom) { Rectangle().fill(Console.line).frame(height: 1) }
    }
    @ViewBuilder private var transport: some View {
        HStack(spacing: 14) {
            Button {
                if let tc = store.targets.first?.tc, tc.known { tcEnabled = tc.enabled; fps = tc.fps; outputMode = tc.output }
                showingTC = true
            } label: { Label("TC", systemImage: "clock") }
                .buttonStyle(ConsoleButton()).popover(isPresented: $showingTC) { tcPanel }.help("タイムコード設定・Mac時刻へ同期")
            if let receiver = store.targets.first ?? store.snapshot.receivers.first {
                TransportTimecode(receiver: receiver, feed: store.feed(receiver.serial))
            }
            Spacer(minLength: 8)
            Picker("収録先", selection: $store.recordingMode) {
                Text("Mac").tag("mac"); Text("本体").tag("device"); Text("両方").tag("both")
            }.pickerStyle(.menu).labelsHidden().frame(width: 105)
            Button { recording(start: true) } label: { Label("一括収録", systemImage: "record.circle") }
                .buttonStyle(ConsoleButton(active: store.targets.contains { (store.recordingMode != "device" && $0.recording) || (store.recordingMode != "mac" && $0.transmitters.contains { $0.device_recording }) }, color: .red)).disabled(store.targets.isEmpty || (store.recordingMode != "mac" && store.targetsBusy))
            Button { recording(start: false) } label: { Image(systemName: "stop.fill").frame(width: 20) }
                .buttonStyle(ConsoleButton()).disabled(store.targets.isEmpty).accessibilityLabel("選択対象の収録を停止").help("選択対象の収録を停止")
        }.padding(.horizontal, 16).padding(.vertical, 12).background(Console.panel)
            .overlay(alignment: .bottom) { Rectangle().fill(Console.line).frame(height: 1) }
        if page == "overview" {
            HStack(spacing: 10) {
                Text("INPUTS").font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(Console.muted)
                Text("\(connected) RX / \(store.snapshot.receivers.flatMap(\.transmitters).filter(\.connected).count) TX").font(.system(size: 10, design: .monospaced)).foregroundStyle(Console.muted)
                Spacer()

            }.padding(.horizontal, 16).frame(height: 38).background(Console.background)
        }
    }
    private var tcPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("TIMECODE").font(.system(size: 16, weight: .medium))
            Toggle(tcEnabled ? "TC ON" : "TC OFF", isOn: $tcEnabled).toggleStyle(.switch).tint(Console.cyan).foregroundStyle(Console.cyan)
            Picker("FPS", selection: $fps) { ForEach(0..<Console.fps.count, id: \.self) { Text(Console.fps[$0]).tag($0) } }
            Picker("出力", selection: $outputMode) { ForEach(0..<Console.outputs.count, id: \.self) { Text(["L-IN · TC入力", "L-OUT · USB全ch TC", "A-OUT · CH1 TC", "N/A · 音声4ch"][$0]).tag($0) } }
            Button { showingTC = false; store.bulk("tc_sync_all", values: ["fps": String(fps)]) } label: {
                Label("Mac時刻に一括同期", systemImage: "arrow.triangle.2.circlepath")
            }.buttonStyle(ConsoleButton(active: true)).disabled(store.targets.isEmpty || store.targetsBusy || store.settingsLocked)
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
            Button("録音先…") { store.chooseFolder() }.buttonStyle(ConsoleCompactButton()).font(.system(size: 10)).foregroundStyle(Color(white: 0.78))
            Text(store.folder.path).font(.system(size: 9, design: .monospaced)).foregroundStyle(Console.muted).lineLimit(1).truncationMode(.middle)
            Spacer()
            if !store.running { Button("再開") { Task { await store.start() } }.buttonStyle(ConsoleButton()) }
            Text("MATRIX \(store.snapshot.bus_channels) CH").font(.system(size: 9, design: .monospaced)).foregroundStyle(store.snapshot.bus_in_use ? Console.cyan : Console.muted)
            Text("CAF / 32-BIT FLOAT").font(.system(size: 9, design: .monospaced)).foregroundStyle(Console.muted)
        }.padding(.horizontal, 16).padding(.vertical, 8).background(Console.strip)
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
