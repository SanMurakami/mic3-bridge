import SwiftUI

struct RecordingTimeline: View {
    @ObservedObject var store: MicStore
    @ObservedObject private var clock: LiveClock
    init(store: MicStore) { self.store = store; self.clock = store.clock }
    @State private var source = ""
    @State private var choseClock = false
    @State private var span = 30.0
    @State private var waveGain = 16.0
    @State private var follow = true
    @State private var frozenEnd = 0.0
    private var liveEnd: Double {
        store.snapshot.receivers.contains(where: \.recording) ? clock.now :
            (store.histories.values.compactMap { $0.bins.last.map { $0.time + $0.duration } }.max() ?? clock.now)
    }
    private var end: Double { follow ? liveEnd : frozenEnd }
    private var origin: Double { store.timelineOrigin ?? end }
    private func clock(_ time: Double) -> String {
        if !source.isEmpty { return store.histories[source]?.timecode(at: time).map { "≈" + $0 } ?? "—:—:—:—" }
        let value = max(0, time - origin)
        return String(format: "%02d:%05.2f", Int(value) / 60, value.truncatingRemainder(dividingBy: 60))
    }
    private func selectClock() {
        if !choseClock, let receiver = store.snapshot.receivers.first(where: { $0.tc.known && $0.tc.enabled }) { source = receiver.serial; choseClock = true }
    }
    var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: 16) {
                Picker("時計", selection: Binding(get: { source }, set: { source = $0; choseClock = true })) {
                    Text("経過時間").tag("")
                    ForEach(store.snapshot.receivers) { r in Text("TC ≈ · \(r.name)").tag(r.serial) }
                }.frame(width: 240)
                Picker("表示幅", selection: $span) {
                    Text("10秒").tag(10.0); Text("30秒").tag(30.0); Text("60秒").tag(60.0); Text("120秒").tag(120.0)
                }.frame(width: 130)
                Picker("波形", selection: $waveGain) { ForEach([1.0, 4.0, 16.0, 64.0], id: \.self) { Text("×\(Int($0))").tag($0) } }.frame(width: 105)
                Spacer()
                Toggle("追従", isOn: Binding(get: { follow }, set: { frozenEnd = liveEnd; follow = $0 }))
                    .toggleStyle(.switch).controlSize(.mini).tint(Console.cyan)
                Text(clock(end)).font(.system(size: 17, weight: .medium, design: .monospaced)).frame(width: 150)
            }.padding(14).background(Console.panel)
            HStack(spacing: 0) {
                Text("TRACK / RX").font(.system(size: 9, weight: .semibold)).foregroundStyle(Console.muted).frame(width: 180, alignment: .leading)
                GeometryReader { _ in
                    let ticks = (0...4).map { clock(end - span + span * Double($0) / 4) }
                    Canvas(rendersAsynchronously: true) { context, size in
                        for tick in 0...4 {
                            let x = size.width * Double(tick) / 4
                            context.draw(Text(ticks[tick]).font(.system(size: 9, design: .monospaced)).foregroundColor(Console.muted), at: CGPoint(x: min(size.width - 42, max(42, x)), y: 15))
                        }
                    }
                }.frame(height: 30)
            }.padding(.horizontal, 12).background(Console.strip)
            ForEach(store.snapshot.receivers) { r in
                ForEach(0..<4, id: \.self) { channel in
                    HStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                StatusDot(active: r.connected)
                                Text(r.transmitters.first(where: { $0.index == channel + 1 }).map { $0.label.isEmpty ? "CH \(channel + 1)" : "CH \(channel + 1) · \($0.label)" } ?? "CH \(channel + 1)")
                                    .font(.system(size: 11, weight: .medium)).lineLimit(1)
                            }
                            Text(r.name).font(.system(size: 9)).foregroundStyle(Console.muted).lineLimit(1)
                            Text(r.recording ? "● MAC REC" : "STOP").font(.system(size: 8, design: .monospaced)).foregroundStyle(r.recording ? .red : Console.muted)
                        }.frame(width: 180, alignment: .leading)
                        WaveLane(bins: store.histories[r.serial]?.bins ?? [], labels: store.histories[r.serial]?.labels ?? [], channel: channel, end: end, span: span, gain: waveGain)
                    }.padding(.horizontal, 12).frame(height: 76).background(Console.strip)
                }
            }
        }.clipShape(RoundedRectangle(cornerRadius: 4))
        .onAppear { selectClock() }
        .onChange(of: store.snapshot.receivers.map { $0.tc.known && $0.tc.enabled }) { _, _ in selectClock() }
    }
}
struct WaveLane: View {
    let bins: [WaveBin]
    let labels: [LabelAnchor]
    let channel: Int
    let end, span, gain: Double
    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            let middle = size.height / 2, start = end - span
            var grid = Path()
            for tick in 0...4 { let x = size.width * Double(tick) / 4; grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height)) }
            grid.move(to: CGPoint(x: 0, y: middle)); grid.addLine(to: CGPoint(x: size.width, y: middle))
            context.stroke(grid, with: .color(.white.opacity(0.08)), lineWidth: 1)
            // 同じ画素に落ちる bin は extrema を統合。波形は実際に録音された範囲だけ描く。
            let width = max(1, Int(size.width.rounded(.up)))
            var lows = [Double](repeating: 0, count: width), highs = lows
            var present = [Bool](repeating: false, count: width)
            for bin in bins where bin.time + bin.duration >= start && bin.time <= end {
                guard bin.low.indices.contains(channel), bin.high.indices.contains(channel) else { continue }
                let first = max(0, Int(floor((bin.time - start) / span * size.width)))
                let last = min(width - 1, Int(ceil((bin.time + bin.duration - start) / span * size.width)))
                if first <= last { for x in first...last { present[x] = true; lows[x] = min(lows[x], bin.low[channel]); highs[x] = max(highs[x], bin.high[channel]) } }
            }
            var waveform = Path()
            for x in 0..<width where present[x] {
                waveform.move(to: CGPoint(x: Double(x), y: middle - min(1, highs[x] * gain) * (middle - 7)))
                waveform.addLine(to: CGPoint(x: Double(x), y: middle - max(-1, lows[x] * gain) * (middle - 7) + 0.6))
            }
            context.stroke(waveform, with: .color(Color(white: 0.68)), lineWidth: 1)
            for (index, label) in labels.enumerated() where label.host <= end {
                let next = index + 1 < labels.count ? labels[index + 1].host : end
                guard next >= start, label.labels.indices.contains(channel), !label.labels[channel].isEmpty else { continue }
                let x = max(0, (label.host - start) / span * size.width)
                if label.host >= start {
                    var marker = Path(); marker.move(to: CGPoint(x: x, y: 0)); marker.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(marker, with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                context.draw(Text(String(label.labels[channel].prefix(20))).font(.system(size: 9)).foregroundColor(.white), at: CGPoint(x: x + 5, y: 5), anchor: .topLeading)
            }
            var playhead = Path(); playhead.move(to: CGPoint(x: size.width - 1, y: 0)); playhead.addLine(to: CGPoint(x: size.width - 1, y: size.height))
            context.stroke(playhead, with: .color(Console.cyan), lineWidth: 1)
        }.clipped().accessibilityLabel("CH \(channel + 1) の録音波形")
    }
}
