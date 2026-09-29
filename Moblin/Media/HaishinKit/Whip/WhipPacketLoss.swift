import Foundation

func whipPacketLossText(_ fraction: Double?) -> String {
    guard let fraction, fraction.isFinite, (0 ... 1).contains(fraction) else {
        return String(localized: "Video packet loss: unavailable")
    }
    let percent = if fraction > 0, fraction < 0.001 {
        "<0.1%"
    } else {
        String(format: "%.1f%%", fraction * 100)
    }
    return String(localized: "Video packet loss: \(percent)")
}
