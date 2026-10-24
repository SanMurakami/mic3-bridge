import Foundation

struct WaveBin: Decodable, Equatable {
    let time, duration: Double
    let low, high: [Double]
}
struct TimecodeClock {
    static let rates: [Double] = [24000/1001, 24, 25, 30000/1001, 30000/1001, 30, 50, 60]
    static func frames(_ text: String, fps: Int) -> Int? {
        guard rates.indices.contains(fps) else { return nil }
        let values = text.split(whereSeparator: { $0 == ":" || $0 == ";" }).compactMap { Int($0) }
        guard values.count == 4 else { return nil }
        let n = Int(rates[fps].rounded()), h = values[0], m = values[1], s = values[2], f = values[3]
        guard (0..<24).contains(h), (0..<60).contains(m), (0..<60).contains(s), (0..<n).contains(f) else { return nil }
        let minutes = h * 60 + m
        if fps == 4 && m % 10 != 0 && s == 0 && f < 2 { return nil }
        return ((h * 3600 + m * 60 + s) * n + f) - (fps == 4 ? 2 * (minutes - minutes / 10) : 0)
    }
    static func text(frames: Int, fps: Int) -> String {
        guard rates.indices.contains(fps) else { return "—" }
        let n = Int(rates[fps].rounded()), day = fps == 4 ? 2_589_408 : n * 86_400
        var f = ((frames % day) + day) % day
        if fps == 4 {
            let blocks = f / 17_982, remaining = f % 17_982
            f += blocks * 18 + (remaining >= 2 ? 2 * ((remaining - 2) / 1_798) : 0)
        }
        return String(format: "%02d:%02d:%02d%@%02d", f / (n * 3600), (f / (n * 60)) % 60, (f / n) % 60, fps == 4 ? ";" : ":", f % n)
    }
}
struct ClockAnchor {
    let host: Double
    let tc: TimecodeState
    func text(at time: Double) -> String? {
        guard tc.known, tc.enabled, abs(time - host) < 12,
              let frame = TimecodeClock.frames(tc.timecode, fps: tc.fps) else { return nil }
        return TimecodeClock.text(frames: frame + Int(((time - host) * TimecodeClock.rates[tc.fps]).rounded()), fps: tc.fps)
    }
}
struct LabelAnchor { let host: Double; let labels: [String] }
struct WaveHistory {
    var labels: [LabelAnchor] = []
    var bins: [WaveBin] = []
    var anchors: [ClockAnchor] = []
    mutating func append(_ receiver: Receiver, now: Double) {
        let currentLabels = (1...4).map { channel in receiver.transmitters.first(where: { $0.index == channel })?.label ?? "" }
        if labels.last?.labels != currentLabels { labels.append(LabelAnchor(host: now, labels: currentLabels)) }
        // 左端の名前を復元するため、保持範囲直前のアサインを一つ残す。
        while labels.count > 1 && labels[1].host < now - 120 { labels.removeFirst() }
        if labels.count > 1000 { labels.removeFirst(labels.count - 1000) }
        bins.append(contentsOf: receiver.waveform ?? [])
        bins.removeAll { $0.time < now - 120 }
        if bins.count > 6500 { bins.removeFirst(bins.count - 6500) }
        let stamp = receiver.tc.observed_host_seconds ?? 0
        if stamp > 0 && anchors.last?.host != stamp { anchors.append(ClockAnchor(host: stamp, tc: receiver.tc)) }
        anchors.removeAll { $0.host < now - 132 }
        if anchors.count > 200 { anchors.removeFirst(anchors.count - 200) }
    }
    func timecode(at time: Double) -> String? {
        anchors.last(where: { $0.host <= time })?.text(at: time)
    }
}
