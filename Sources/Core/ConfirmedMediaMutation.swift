import Foundation

/// A confirmed remote mutation always invalidates its captured namespace. Active UI
/// publication is conditional, so a later account switch never redirects the effect.
@MainActor
enum ConfirmedMediaMutation {
    static func apply(identity: MediaObjectIdentity, isCurrent: () -> Bool,
                      invalidate: (MediaObjectIdentity) async -> Void,
                      publish: () -> Void) async {
        await invalidate(identity)
        if isCurrent() { publish() }
    }
}
