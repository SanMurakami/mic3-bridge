import SwiftUI

private struct ConsoleInput: Identifiable {
    let receiver: Receiver
    let tx: Transmitter
    var id: String { receiver.serial + ":" + String(tx.index) }
}
struct ConsoleOverview: View {
    @ObservedObject var store: MicStore
    @AppStorage("consoleConnectedOnly") private var connectedOnly = false
    private var inputs: [ConsoleInput] {
        store.snapshot.receivers.flatMap { receiver in
            receiver.transmitters.filter { !connectedOnly || (receiver.connected && $0.connected) }
                .map { ConsoleInput(receiver: receiver, tx: $0) }
        }
    }
    var body: some View {
        GeometryReader { geometry in
            let entries = inputs
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Toggle("未接続を非表示", isOn: $connectedOnly)
                        .toggleStyle(.checkbox).font(.system(size: 11))
                    Spacer()
                    Text("\(entries.count) INPUTS").font(.system(size: 10, design: .monospaced)).foregroundStyle(Console.muted)
                }.frame(height: 24)
                if entries.isEmpty {
                    ContentUnavailableView(connectedOnly ? "接続中のマイクなし" : "登録された入力なし", systemImage: "mic.slash")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 6) {
                            ForEach(entries) { input in
                                VStack(spacing: 0) {
                                    Button { store.selectControl(ControlSelection(receiver: input.receiver.serial)) } label: {
                                        HStack {
                                            Text("RX " + String(input.receiver.serial.suffix(6)))
                                            Spacer(minLength: 2)
                                            Image(systemName: "ellipsis")
                                        }.font(.system(size: 8, design: .monospaced)).frame(height: 22)
                                    }.buttonStyle(ConsoleSelectionButton()).help(input.receiver.name)
                                    CompactChannel(tx: input.tx, receiver: input.receiver, store: store, narrow: true,
                                        availableMeterHeight: max(65, geometry.size.height - 405))
                                }
                                .frame(width: 110, alignment: .top)
                                .background(Console.panel)
                                .overlay(Rectangle().stroke(Console.line))
                            }
                        }.padding(.bottom, 12)
                    }.defaultScrollAnchor(.leading)
                }
                Spacer(minLength: 0)
            }.padding(12)
        }
    }
}
