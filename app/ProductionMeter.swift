import SwiftUI

struct LiveFrame {
    var meters = [Double](repeating: 0, count: 4)
    var ballistics = [MeterState](repeating: MeterState(), count: 4)
    var now = 0.0
    var seconds = 0.0
}
@MainActor final class ReceiverFeed: ObservableObject {
    @Published var frame = LiveFrame()
    func update(_ receiver: Receiver, now: Double) {
        var next = frame
        next.meters = receiver.meters; next.now = now; next.seconds = receiver.recorded_seconds
        for c in 0..<4 { next.ballistics[c].update(amplitude: receiver.meters.indices.contains(c) ? receiver.meters[c] : 0, now: now) }
        frame = next
    }
    func reset(_ channel: Int) { var next = frame; next.ballistics[channel].reset(); frame = next }
}
@MainActor final class LiveClock: ObservableObject { @Published var now = 0.0 }
struct ProductionMeter: View {
    @ObservedObject var feed: ReceiverFeed
    let channel: Int
    var height: Double = 190
    var numeric = true
    private var meter: MeterState { feed.frame.ballistics[channel] }
    private let green = Color(red: 0.23, green: 0.75, blue: 0.45)
    private let yellow = Color(red: 0.94, green: 0.73, blue: 0.25)
    private let red = Color(red: 0.95, green: 0.25, blue: 0.28)
    var body: some View {
        VStack(spacing: 6) {
            Button { feed.reset(channel) } label: {
                Text("CLIP").font(.system(size: 7, weight: .bold, design: .monospaced)).tracking(0.7)
                    .foregroundStyle(meter.clipped ? Color.black : Console.muted.opacity(0.5))
                    .frame(width: 29, height: 12).background(meter.clipped ? red : Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 2))
            }.buttonStyle(ConsoleCompactButton(height: 16, padding: 0))
            HStack(spacing: 4) {
                MeterScale().equatable().frame(width: 23)
                GeometryReader { p in
                    let h = p.size.height
                    ZStack(alignment: .bottom) {
                        Rectangle().fill(Color.black.opacity(0.75))
                        LinearGradient(stops: [.init(color: red, location: 0), .init(color: red, location: 0.1), .init(color: yellow, location: 0.1), .init(color: yellow, location: 0.3), .init(color: green, location: 0.3), .init(color: green, location: 1)], startPoint: .top, endPoint: .bottom)
                            .mask(alignment: .bottom) { Rectangle().frame(height: h * (meter.level + 60) / 60).animation(.linear(duration: 0.032), value: meter.level) }
                        MeterGaps().equatable()
                        Rectangle().fill(Color.white.opacity(0.8)).frame(height: 1.5)
                            .offset(y: -h * (meter.peak + 60) / 60).animation(.linear(duration: 0.032), value: meter.peak)
                    }.clipShape(RoundedRectangle(cornerRadius: 1))
                        .overlay(Rectangle().stroke(Color.white.opacity(0.08)))
                }.frame(width: 18)
            }.frame(height: height)
            if numeric {
                Text(meter.level > -60 ? String(format: "%.1f", meter.level) : "−∞")
                    .font(.system(size: 11, weight: .medium, design: .monospaced)).monospacedDigit().frame(width: 50)
            }
        }.accessibilityElement(children: .contain)
            .accessibilityLabel("CH \(channel + 1) のピークメーター")
            .accessibilityValue(meter.clipped ? "クリップ" : String(format: "%.1f dBFS", meter.level))
    }
}

private struct MeterScale: View, Equatable {
    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            for db in [0, -6, -12, -18, -24, -36, -48, -60] {
                let y = max(4, min(size.height - 4, size.height * Double(-db) / 60))
                context.draw(Text(db == 0 ? "0" : "\(db)").font(.system(size: 8, design: .monospaced)).foregroundColor(db == -18 ? Color(white: 0.85) : Console.muted), at: CGPoint(x: size.width - 1, y: y), anchor: .trailing)
            }
        }
    }
}
private struct MeterGaps: View, Equatable {
    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            var separators = Path()
            for i in 1..<40 {
                let y = size.height * Double(i) / 40
                separators.move(to: CGPoint(x: 0, y: y)); separators.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(separators, with: .color(Console.strip), lineWidth: 1)
        }
    }
}

// RXのTCを共通host時計へ投影する。
struct LiveTimecode: View {
    let receiver: Receiver
    @ObservedObject var feed: ReceiverFeed
    private var value: String {
        guard receiver.connected, receiver.tc.known else { return "—:—:—:—" }
        guard receiver.tc.enabled else { return "TC OFF" }
        guard let host = receiver.tc.observed_host_seconds, host > 0 else { return "—:—:—:—" }
        return ClockAnchor(host: host, tc: receiver.tc).text(at: feed.frame.now) ?? "—:—:—:—"
    }
    var body: some View { Text(value).monospacedDigit().accessibilityLabel("TC \(receiver.serial.suffix(6))").accessibilityValue(value) }
}

struct TransportTimecode: View {
    let receiver: Receiver
    @ObservedObject var feed: ReceiverFeed
    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            LiveTimecode(receiver: receiver, feed: feed)
                .font(.system(size: 21, weight: .medium, design: .monospaced)).foregroundStyle(Color(white: 0.9))
            VStack(alignment: .leading, spacing: 3) {
                Text(String(receiver.serial.suffix(6)))
                Text("\(Console.fpsName(receiver.tc.fps)) FPS")
            }.font(.system(size: 8, design: .monospaced)).foregroundStyle(Console.muted)
        }.fixedSize()
    }
}
