import SwiftUI
import AppKit
import AVFoundation

struct Transmitter: Decodable, Identifiable, Equatable { var id: Int { index }; let index: Int; let noise_mode: String }
struct Receiver: Decodable, Identifiable, Equatable {
    var id: String { serial }
    let serial, name, firmware, status, virtual_uid, usb_location, recording_path, error: String
    let connected, recording, can_delete, control_busy: Bool
    let transmitters: [Transmitter]
    let meters: [Double]
    let recorded_seconds: Double
    let dropped: UInt64
}
struct MatrixRoute: Codable, Equatable { var serial: String; var channel: Int }
struct Snapshot: Decodable {
    var receivers: [Receiver] = []
    var unidentified = 0
    var error = ""
    var bus_channels = 16
    var bus_in_use = false
    var routes: [MatrixRoute?] = []
}

@MainActor final class MicStore: ObservableObject {
    @Published var snapshot = Snapshot()
    @Published var failure = ""
    @Published var running = false
    @Published var folder: URL
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var stderr: Pipe?
    private var stopping = false
    private var latest = Snapshot()
    private var visibilityObserver: NSObjectProtocol?
    private var visible = true
    init() {
        folder = UserDefaults.standard.url(forKey: "recordingFolder") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/DJI Mic Recordings", isDirectory: true)
        visibilityObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.visible = NSApplication.shared.occlusionState.contains(.visible)
                if self.visible { self.snapshot = self.latest }
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
        // 受信と JSON decode は background。UI への反映だけ MainActor、最大 10Hz。
        let reader = SnapshotReader { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.latest = result
                // 隠れたウィンドウにメーターの再描画を要求しない。メニューの台数だけ追従。
                if self.visible || self.snapshot.receivers.map(\.connected) != result.receivers.map(\.connected) || self.snapshot.receivers.map(\.serial) != result.receivers.map(\.serial) {
                    self.snapshot = result
                }
            }
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
        var command = values; command["op"] = op
        do {
            var data = try JSONSerialization.data(withJSONObject: command); data.append(10)
            try input?.fileHandleForWriting.write(contentsOf: data)
        } catch { failure = error.localizedDescription }
    }
    func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false; panel.directoryURL = folder
        panel.message = "Mac 側の 4ch 録音を保存するフォルダー"; panel.prompt = "選択"
        if panel.runModal() == .OK, let chosen = panel.url {
            folder = chosen; UserDefaults.standard.set(chosen, forKey: "recordingFolder")
        }
    }
}
// FileHandle の callback は直列処理し、分割された UTF-8 / JSON 行を保持する。
final class SnapshotReader: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private let receiveSnapshot: @Sendable (Snapshot) -> Void
    init(_ callback: @escaping @Sendable (Snapshot) -> Void) { receiveSnapshot = callback }
    func receive(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        pending.append(data)
        while let end = pending.firstIndex(of: 10) {
            let line = pending[..<end]; pending.removeSubrange(...end)
            if let value = try? JSONDecoder().decode(Snapshot.self, from: line) { receiveSnapshot(value) }
        }
        if pending.count > 4_194_304 { pending.removeAll() }
    }
}

struct ReceiverCard: View {
    let receiver: Receiver
    @ObservedObject var store: MicStore
    @State private var editing = false
    @State private var draft = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Image(systemName: "mic.and.signal.meter.fill").font(.title2).foregroundStyle(receiver.connected ? .green : .secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(receiver.name).font(.headline).textSelection(.enabled)
                    Text("S/N \(receiver.serial)  ·  \(receiver.firmware.isEmpty ? "FW 未確認" : receiver.firmware)")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Text(receiver.status).font(.caption).foregroundStyle(receiver.connected ? .green : .secondary)
                Button("名前を変更", systemImage: "pencil") { draft = receiver.name; editing = true }
                    .labelStyle(.iconOnly).help("各アプリに表示する入力名を変更")
                Button("登録を削除", systemImage: "trash", role: .destructive) { store.send("delete", receiver: receiver) }
                    .labelStyle(.iconOnly).disabled(!receiver.can_delete)
                    .help(receiver.can_delete ? "一覧と各ソフトの仮想入力から登録を削除。録音ファイルは残ります。再接続すると新規登録します。" : "USB 未接続で、DAW などが入力を使っていないときに削除できます")
            }
            HStack(spacing: 18) {
                ForEach(0..<4) { ch in
                    VStack(alignment: .leading, spacing: 5) {
                        let amplitude = ch < receiver.meters.count ? receiver.meters[ch] : 0
                        let db = amplitude > 0 ? 20 * log10(amplitude) : -90
                        HStack {
                            Text("CH \(ch+1)").font(.caption).fontWeight(.medium)
                            Spacer()
                            Text(db > -90 ? String(format: "%.0f dB", db) : "−∞").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        ProgressView(value: min(1, max(0, (db+60)/60)))
                            .tint(db >= -1 ? .red : .green)
                            .accessibilityLabel("チャンネル \(ch+1) の入力レベル")
                    }
                }
            }
            HStack {
                Button(receiver.recording ? "録音を停止" : "Mac に 4ch 録音", systemImage: receiver.recording ? "stop.fill" : "record.circle") {
                    store.send(receiver.recording ? "stop" : "record", receiver: receiver, values: ["folder": store.folder.path])
                }
                .disabled(!receiver.connected)
                .tint(receiver.recording ? .red : .accentColor)
                if receiver.recording || receiver.recorded_seconds > 0 {
                    Text(String(format: "%@ %02d:%02d", receiver.recording ? "REC" : "保存済み", Int(receiver.recorded_seconds)/60, Int(receiver.recorded_seconds)%60))
                        .font(.caption.monospacedDigit()).foregroundStyle(receiver.recording ? .red : .secondary)
                }
                Spacer()
                if !receiver.recording_path.isEmpty {
                    Button("ファイルを表示", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: receiver.recording_path)])
                    }.font(.caption)
                }
                Text("4ch · 48 kHz 仮想入力").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("ノイキャン").font(.caption).foregroundStyle(.secondary)
                ForEach(receiver.transmitters) { tx in
                    Picker("TX \(tx.index)", selection: Binding(get: { tx.noise_mode }, set: { mode in
                        store.send("noise", receiver: receiver, values: ["target":String(tx.index),"mode":mode])
                    })) { Text("NONE").tag("none");Text("BASIC").tag("basic");Text("STRONG").tag("strong");if tx.noise_mode == "unknown" { Text("未確認").tag("unknown") } }
                    .frame(width: 165).disabled(receiver.control_busy || !receiver.connected)
                }
                Spacer()
                if receiver.control_busy { ProgressView().controlSize(.small) }
                Button("状態を更新", systemImage: "arrow.clockwise") { store.send("refresh_controls", receiver: receiver) }.font(.caption).disabled(!receiver.connected || receiver.control_busy)
            }
            if !receiver.error.isEmpty { Label(receiver.error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            if receiver.dropped > 0 { Text("転送待ちの上限に達した音声ブロック: \(receiver.dropped)").font(.caption).foregroundStyle(.orange) }
        }
        .padding(18).background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
        .sheet(isPresented: $editing) {
            VStack(alignment: .leading, spacing: 16) {
                Text("仮想入力の名前").font(.headline)
                Text("各ソフトの入力一覧に表示されます。変更後に入力一覧を開き直してください。").font(.callout).foregroundStyle(.secondary)
                TextField("名前", text: $draft).textFieldStyle(.roundedBorder)
                HStack {
                    Spacer(); Button("キャンセル", role: .cancel) { editing = false }.keyboardShortcut(.cancelAction)
                    Button("保存") { store.send("rename", receiver: receiver, values: ["name": draft]); editing = false }
                        .keyboardShortcut(.defaultAction).disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(24).frame(width: 440)
        }
    }
}

struct MatrixView: View {
    @ObservedObject var store: MicStore
    @State private var expanded = false
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("DJI Mic3 Matrix").font(.headline)
                    Spacer()
                    Picker("共通入力", selection: Binding(get: { store.snapshot.bus_channels }, set: { store.send("bus_channels", values: ["channels": String($0)]) })) {
                        ForEach([4,8,16,32,64], id: \.self) { Text("\($0)ch").tag($0) }
                    }.frame(width: 180).disabled(store.snapshot.bus_in_use)
                }
                Text(store.snapshot.bus_in_use ? "DAW が使用中です。入力とチャンネル数を維持しています。" : "チャンネル数の変更は DAW の入力を停止してから行ってください。")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("チャンネルの割り当て", isExpanded: $expanded) {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                        ForEach(0..<store.snapshot.bus_channels, id: \.self) { destination in
                            let route = destination < store.snapshot.routes.count ? store.snapshot.routes[destination] : nil
                            GridRow {
                                Text("CH \(destination+1)").font(.callout.monospacedDigit()).frame(width: 52, alignment: .leading)
                                Picker("入力元", selection: Binding(get: { route?.serial ?? "" }, set: { serial in
                                    store.send("route", values: ["destination":String(destination+1),"source_serial":serial,"channel":String(route?.channel ?? 1)])
                                })) {
                                    Text("無音").tag("")
                                    ForEach(store.snapshot.receivers) { r in Text("\(r.name)  [\(r.serial)]").tag(r.serial) }
                                    if let route, !store.snapshot.receivers.contains(where: { $0.serial == route.serial }) {
                                        Text("\(route.serial)（未登録）").tag(route.serial)
                                    }
                                }.labelsHidden().frame(maxWidth: .infinity)
                                Picker("機器のチャンネル", selection: Binding(get: { route?.channel ?? 1 }, set: { channel in
                                    store.send("route", values: ["destination":String(destination+1),"source_serial":route?.serial ?? "","channel":String(channel)])
                                })) { ForEach(1...4,id: \.self) { Text("CH \($0)").tag($0) } }
                                .labelsHidden().frame(width: 90).disabled(route == nil)
                            }
                        }
                    }.padding(.top, 10)
                }
                Text("割り当ては本体シリアルで保存します。抜き差しでは変更せず、未接続の入力元は無音になります。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(6)
        }
    }
}

struct MainView: View {
    @ObservedObject var store: MicStore
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("DJI Mic 3 Bridge").font(.largeTitle.bold())
                    Text("レシーバー 1 台につき、名前を持つ 4ch 入力。").foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(store.snapshot.receivers.filter(\.connected).count) 台接続").font(.headline)
            }.padding(24)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if !store.failure.isEmpty { errorBanner(store.failure) }
                    if !store.snapshot.error.isEmpty { errorBanner(store.snapshot.error) }
                    if store.snapshot.unidentified > 0 {
                        Label("\(store.snapshot.unidentified) 台の個体情報を確認しています…", systemImage: "usb.cable").foregroundStyle(.secondary)
                    }
                    if store.snapshot.receivers.isEmpty {
                        ContentUnavailableView("レシーバーを接続", systemImage: "mic", description: Text("DJI Mic 3 を USB で接続すると自動登録します。ポートを変えても同じ個体の入力へ戻ります。"))
                    }
                    MatrixView(store: store)
                    ForEach(store.snapshot.receivers) { receiver in ReceiverCard(receiver: receiver, store: store) }
                    GroupBox("機器側の制御") {
                        Text("ノイキャンは各 TX の NONE / BASIC / STRONG を変更できます。本体録音・TC の変更は解析中です。録音ボタンは Mac 側への保存です。")
                            .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                }.padding(24)
            }
            Divider()
            HStack {
                Button("保存先…", systemImage: "folder") { store.chooseFolder() }
                Text(store.folder.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(store.folder.path)
                Spacer()
                if !store.running { Button("音声サービスを再開") { Task { await store.start() } } }
                Text("CAF · Float32 · 4ch").font(.caption).foregroundStyle(.secondary)
            }.padding(14)
        }
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
        .frame(minWidth: 740, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).textSelection(.enabled)
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
        }.defaultSize(width: 880, height: 650)
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
