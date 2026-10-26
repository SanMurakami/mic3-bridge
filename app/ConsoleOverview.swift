import SwiftUI

// ウィンドウ幅に収まるRXを表示する。
struct ConsoleOverview: View {
    @ObservedObject var store: MicStore
    @State private var bank = 0
    var body: some View {
        GeometryReader { geometry in
            let capacity = max(1, Int((geometry.size.width - 24) / 510))
            let pages = max(1, (store.snapshot.receivers.count + capacity - 1) / capacity)
            let current = min(bank, pages - 1)
            let receivers = Array(store.snapshot.receivers.dropFirst(current * capacity).prefix(capacity))
            VStack(spacing: 8) {
                if pages > 1 {
                    HStack(spacing: 10) {
                        Button { bank = max(0, current - 1) } label: { Image(systemName: "chevron.left") }
                            .disabled(current == 0).accessibilityLabel("前のレシーバー")
                        Text("BANK \(current + 1) / \(pages)").font(.system(size: 10, weight: .semibold, design: .monospaced))
                        Button { bank = min(pages - 1, current + 1) } label: { Image(systemName: "chevron.right") }
                            .disabled(current == pages - 1).accessibilityLabel("次のレシーバー")
                        Spacer()
                    }.buttonStyle(ConsoleCompactButton(height: 26, minWidth: 28))
                }
                if receivers.isEmpty {
                    ContentUnavailableView("接続なし", systemImage: "cable.connector").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(receivers) { receiver in
                            ReceiverOverview(receiver: receiver, store: store, compact: false, showProcessing: false,
                                availableMeterHeight: max(65, geometry.size.height - (pages > 1 ? 464 : 430)))
                                .frame(width: (geometry.size.width - 24 - Double(receivers.count - 1) * 12) / Double(receivers.count), alignment: .top)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }.padding(12)
        }
    }
}
