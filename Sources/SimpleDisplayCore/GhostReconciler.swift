import Foundation

/// Reconciles retained "ghost" rows against the live display list.
///
/// A display disabled through `CGSConfigureDisplayEnabled` drops out of
/// `CGGetOnlineDisplayList`, so the app keeps a ghost row for it, addressed by
/// the `CGDirectDisplayID` it had when it was disabled. That ID is not stable:
/// macOS reassigns IDs on topology changes, and a ghost seeded from a previous
/// session may point at an ID that now belongs to a different, live display.
/// Acting on such a ghost would toggle the wrong monitor.
///
/// This type holds the decision logic only, with no CoreGraphics dependency, so
/// it can be unit-tested. The view model maps the verdicts back onto its rows.
public enum GhostReconciler {

    /// A retained row for a disabled display, keyed by its stable UUID.
    public struct Ghost: Hashable {
        public let uuid: String
        public let id: UInt32

        public init(uuid: String, id: UInt32) {
            self.uuid = uuid
            self.id = id
        }
    }

    /// A display currently in the online list. The UUID can be missing for
    /// displays CoreGraphics cannot identify.
    public struct Live: Hashable {
        public let uuid: String?
        public let id: UInt32

        public init(uuid: String?, id: UInt32) {
            self.uuid = uuid
            self.id = id
        }
    }

    public enum Verdict: Equatable {
        /// The display is back in the online list; the ghost row is redundant.
        case backOnline
        /// Keep showing the ghost, addressed by `id`. This is the retained ID
        /// unless the UUID resolved to a fresh one.
        case keep(id: UInt32)
        /// The ID the ghost would be addressed by belongs to a different live
        /// display. Toggling it would act on the wrong monitor; drop the row.
        case collided(withLiveUUID: String?)
    }

    /// - Parameters:
    ///   - ghosts: retained rows, at most one per UUID.
    ///   - live: the current online display list.
    ///   - resolveID: maps a UUID to the ID macOS assigns it right now, or nil
    ///     when the window server does not know the display.
    /// - Returns: one verdict per ghost, keyed by UUID.
    public static func reconcile(
        ghosts: [Ghost],
        live: [Live],
        resolveID: (String) -> UInt32?
    ) -> [String: Verdict] {
        let liveUUIDs = Set(live.compactMap(\.uuid))
        let liveOwnerByID: [UInt32: String?] = Dictionary(
            live.map { ($0.id, $0.uuid) },
            uniquingKeysWith: { first, _ in first }
        )

        var verdicts: [String: Verdict] = [:]
        for ghost in ghosts {
            if liveUUIDs.contains(ghost.uuid) {
                verdicts[ghost.uuid] = .backOnline
                continue
            }
            // Prefer the ID macOS assigns the UUID right now; fall back to the
            // retained one while the display is disabled and unresolvable.
            let candidate = resolveID(ghost.uuid) ?? ghost.id
            if let owner = liveOwnerByID[candidate] {
                // `ghost.uuid` is not live, so whoever owns this ID is someone else.
                verdicts[ghost.uuid] = .collided(withLiveUUID: owner)
            } else {
                verdicts[ghost.uuid] = .keep(id: candidate)
            }
        }
        return verdicts
    }
}
