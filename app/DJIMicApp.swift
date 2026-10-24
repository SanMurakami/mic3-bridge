import SwiftUI
import AppKit
import AVFoundation

struct Receiver: Decodable, Identifiable, Equatable {
    var id: String { serial }
    let serial, name, firmware, status, virtual_uid, usb_location, recording_path, error: String
    let connected, recording: Bool
    let meters: [Double]
    let recorded_seconds: Double
    let dropped: UInt64
}
struct Snapshot: Decodable {
    var receivers: [Receiver] = []
    var unidentified = 0
    var error = ""
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
    init() {
        folder = UserDefaults.standard.url(forKey: "recordingFolder") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/DJI Mic Recordings", isDirectory: true)
    }
    func start() async {
        guard process == nil else { return }
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
            Task { @MainActor in self?.snapshot = result }
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
        } catch { failure = error.localizedDescription }
    }
    func stop() { stopping = true; process?.terminate() }
    func send(_ op: String, receiver: Receiver, values: [String: String] = [:]) {
        var command = values; command["op"] = op; command["serial"] = receiver.serial
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
                    ForEach(store.snapshot.receivers) { receiver in ReceiverCard(receiver: receiver, store: store) }
                    GroupBox("機器側の制御") {
                        Text("ノイキャン・本体録音・TC の変更は、Mic 3 のコマンドを解析中です。現在の録音ボタンは Mac 側への保存です。")
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
        .frame(minWidth: 740, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).textSelection(.enabled)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: MicStore?
    func applicationWillTerminate(_ notification: Notification) { store?.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
@main struct DJIMicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = MicStore()
    var body: some Scene {
        Window("DJI Mic 3 Bridge", id: "main") {
            MainView(store: store).task { delegate.store = store; await store.start() }
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
