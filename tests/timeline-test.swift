import Foundation
extension TimecodeState {
    init(known: Bool, enabled: Bool, fps: Int, timecode: String, observed_host_seconds: Double?) {
        self.init(known: known, enabled: enabled, fps: fps, output: 3, timecode: timecode, observed_host_seconds: observed_host_seconds)
    }
}
extension Transmitter {
    init(index: Int, label: String) {
        self.init(index: index, serial: "TX", label_key: "TX", label: label, noise_mode: "none", connected: true, charging: false, device_recording: false, battery_code: 1, storage_total: 100, storage_remaining: 90)
    }
}
extension Receiver {
    init(transmitters: [Transmitter] = [], waveform: [WaveBin]?, tc: TimecodeState, meters: [Double] = [0,0,0,0]) {
        self.init(serial: "RX", name: "RX", firmware: "", status: "", virtual_uid: "RX", usb_location: "", recording_path: "", error: "", control_message: "", connected: true, recording: false, can_delete: false, control_busy: false, charging: false, battery_code: 1, tc: tc, transmitters: transmitters, meters: meters, waveform: waveform, recorded_seconds: 0, dropped: 0)
    }
}
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
        let base = Receiver(waveform: [], tc: tc)
        let levels = Receiver(waveform: [bin], tc: tc, meters: [0.1,0,0,0])
        assert(Snapshot(receivers: [base]).sameControls(as: Snapshot(receivers: [levels])))
        assert(!base.sameControls(as: Receiver(transmitters: [Transmitter(index: 2, label: "人物A")], waveform: [], tc: tc)))
        var meter = MeterState()
        meter.update(amplitude: 0.1, now: 1); assert(abs(meter.peak + 20) < 0.001)
        meter.update(amplitude: 0, now: 1.1); assert(meter.peak == -20 && meter.level < -20)
        meter.update(amplitude: 0, now: 3); assert(meter.peak < -20)
        meter.update(amplitude: 1.1, now: 4); assert(meter.clipped); meter.reset(); assert(!meter.clipped)
        print("timeline: rates, DF roundtrip, rollover, stale clock, bounded history passed")
    }
}
