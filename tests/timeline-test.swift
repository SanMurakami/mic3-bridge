import Foundation
struct TimecodeState { let known, enabled: Bool; let fps: Int; let timecode: String; let observed_host_seconds: Double? }
struct Transmitter { let index: Int; let label: String }
struct Receiver { var transmitters: [Transmitter] = []; let waveform: [WaveBin]?; let tc: TimecodeState }
@main struct TimelineTests {
    static func main() {
        assert(abs(TimecodeClock.rates[0] - 23.976023976) < 0.00001)
        for fps in 0..<8 {
            let n = Int(TimecodeClock.rates[fps].rounded())
            let day = fps == 4 ? 2_589_408 : n * 86400
            // 一日全体を走査し、DF の毎分・10分境界・日跨ぎを含む往復。
            for frame in stride(from: 0, to: day, by: 29) {
                assert(TimecodeClock.frames(TimecodeClock.text(frames: frame, fps: fps), fps: fps) == frame)
            }
            assert(TimecodeClock.text(frames: day, fps: fps) == (fps == 4 ? "00:00:00;00" : "00:00:00:00"))
        }
        assert(TimecodeClock.text(frames: 1800, fps: 4) == "00:01:00;02")
        assert(TimecodeClock.frames("00:01:00;00", fps: 4) == nil)
        let tc = TimecodeState(known: true, enabled: true, fps: 1, timecode: "01:00:00:00", observed_host_seconds: 100)
        let anchor = ClockAnchor(host: 100, tc: tc)
        assert(anchor.text(at: 101) == "01:00:01:00"); assert(anchor.text(at: 112) == nil)
        var history = WaveHistory()
        let bin = WaveBin(time: 100, duration: 0.02, low: [-0.5,0,0,0], high: [0.5,0,0,0])
        history.append(Receiver(transmitters: [Transmitter(index: 2, label: "人物A")], waveform: [bin], tc: tc), now: 101)
        assert(history.bins.count == 1 && history.timecode(at: 101) == "01:00:01:00")
        history.append(Receiver(transmitters: [Transmitter(index: 2, label: "人物B")], waveform: [], tc: tc), now: 102)
        assert(history.labels.count == 2 && history.labels[0].labels[1] == "人物A" && history.labels[1].labels[1] == "人物B")
        history.append(Receiver(transmitters: [Transmitter(index: 2, label: "人物B")], waveform: [], tc: tc), now: 222)
        assert(history.bins.isEmpty && history.anchors.count == 1)
        print("timeline: rates, DF roundtrip, rollover, stale clock, bounded history passed")
    }
}
