import Foundation

/// The picker chooses a destination; its parent owns remote work after dismissal.
struct DestinationSelection {
    enum Phase { case choosing, confirmed(String), cancelled }
    private(set) var phase: Phase = .choosing
    var hasDecided: Bool { if case .choosing = phase { return false }; return true }
    mutating func confirm(_ prefix: String, canConfirm: Bool) -> String? {
        guard !hasDecided, canConfirm else { return nil }
        phase = .confirmed(prefix)
        return prefix
    }
    mutating func cancel() { if !hasDecided { phase = .cancelled } }
}
