import Foundation

struct MeterState {
    var level = -60.0
    var peak = -60.0
    var clipped = false
    private var heldUntil = 0.0
    private var last = 0.0
    mutating func update(amplitude: Double, now: Double) {
        let db = amplitude > 0 && amplitude.isFinite ? max(-60, min(0, 20 * log10(amplitude))) : -60
        let dt = last > 0 ? max(0, min(0.25, now - last)) : 0
        level = max(db, level - 36 * dt)
        if db >= peak { peak = db; heldUntil = now + 1.25 }
        else if now > heldUntil { peak = max(db, peak - 12 * dt) }
        clipped = clipped || amplitude >= 1
        last = now
    }
    mutating func reset() { peak = level; clipped = false; heldUntil = last + 1.25 }
}
