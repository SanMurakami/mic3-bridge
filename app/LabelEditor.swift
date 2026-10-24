import SwiftUI

struct LabelEditor: View {
    let tx: Transmitter
    let receiver: Receiver
    @ObservedObject var store: MicStore
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var takeFrom = ""
    private var candidates: [(String, String)] {
        var seen = Set<String>()
        return store.snapshot.receivers.flatMap { r in
            r.transmitters.compactMap { t in
                guard !t.label.isEmpty, t.label_key != tx.label_key, seen.insert(t.label_key).inserted else { return nil }
                return (t.label_key, "\(t.label) · \(r.name) / TX\(t.index)")
            }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("人物アサイン").font(.headline)
            TextField("人物ラベル", text: $label).textFieldStyle(.roundedBorder).disabled(!takeFrom.isEmpty)
            Picker("引き継ぎ", selection: $takeFrom) {
                Text("新規・名前変更").tag("")
                ForEach(candidates, id: \.0) { key, name in Text(name).tag(key) }
            }
            HStack {
                Spacer()
                Button(takeFrom.isEmpty ? "保存" : "ラベルを入れ替え") {
                    var values = ["label_key": tx.label_key, "label": label]
                    if !takeFrom.isEmpty { values["take_from"] = takeFrom }
                    store.send("label", receiver: receiver, values: values); dismiss()
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 320).onAppear { label = tx.label }
    }
}
