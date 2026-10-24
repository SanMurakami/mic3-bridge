import Foundation

struct Transmitter: Decodable, Identifiable, Equatable {
    var id: Int { index }
    let index: Int
    let serial, label_key, label, noise_mode: String
    let connected, charging, device_recording: Bool
    let battery_code, storage_total, storage_remaining: Int
    var gain_db: Int? = nil
    var agc: Int? = nil
}
struct TimecodeState: Decodable, Equatable {
    let known, enabled: Bool
    let fps, output: Int
    let timecode: String
    let observed_host_seconds: Double?
}
struct Receiver: Decodable, Identifiable, Equatable {
    var id: String { serial }
    let serial, name, firmware, status, virtual_uid, usb_location, recording_path, error, control_message: String
    let connected, recording, can_delete, control_busy, charging: Bool
    let battery_code: Int
    let tc: TimecodeState
    let transmitters: [Transmitter]
    let meters: [Double]
    let waveform: [WaveBin]?
    let recorded_seconds: Double
    let dropped: UInt64
    var gain_db: Int? = nil
    var lossless: Int? = nil
}
struct MatrixRoute: Codable, Equatable { var serial: String; var channel: Int }
struct Snapshot: Decodable {
    var receivers: [Receiver] = []
    var host_seconds: Double?
    var unidentified = 0
    var error = ""
    var bus_channels = 16
    var bus_in_use = false
    var routes: [MatrixRoute?] = []
}

extension Snapshot {
    func sameControls(as other: Snapshot) -> Bool {
        unidentified == other.unidentified && error == other.error && bus_channels == other.bus_channels && bus_in_use == other.bus_in_use && routes == other.routes && receivers.count == other.receivers.count && zip(receivers, other.receivers).allSatisfy { $0.sameControls(as: $1) }
    }
}
extension Receiver {
    func sameControls(as r: Receiver) -> Bool {
        serial == r.serial && name == r.name && firmware == r.firmware && status == r.status && virtual_uid == r.virtual_uid && usb_location == r.usb_location && recording_path == r.recording_path && error == r.error && control_message == r.control_message && connected == r.connected && recording == r.recording && can_delete == r.can_delete && control_busy == r.control_busy && charging == r.charging && battery_code == r.battery_code && tc == r.tc && transmitters == r.transmitters && dropped == r.dropped && gain_db == r.gain_db && lossless == r.lossless
    }
}
