import CoreGraphics
import Foundation
import os

private let logger = Logger(subsystem: "app.simpledisplay", category: "DisplayStatePersistence")

struct PersistedDisplayState: Codable {
    let uuid: String
    var isDisabled: Bool
    var isMain: Bool
    /// Last-known display ID and name, captured when the display was disabled.
    /// A CGSConfigureDisplayEnabled-disabled display leaves the online list, so
    /// these let us rebuild a re-enableable row after an app restart. Optional
    /// for backward compatibility with state written by older versions.
    var lastKnownID: UInt32?
    var name: String?
    /// True once the user confirmed turning off the last visible (physical)
    /// display. Only then may the app re-apply that disable on launch without
    /// the revert countdown; an unconfirmed one is undone instead.
    var headless: Bool?
    /// UUID of the display this one mirrors, when the user chose to mirror it.
    var mirrorOf: String?
    /// The mode the display had when it was turned off. A display re-enabled from
    /// a row rebuilt after a relaunch has no live mode to restore otherwise, and
    /// macOS may bring it back in another one (seen: 1280x720 for a 1920x1080
    /// console).
    var lastMode: DisplayMode?
}

@MainActor
final class DisplayStatePersistence {

    private let persistenceKey = "com.simpledisplay.displayState"

    func loadAll() -> [PersistedDisplayState] {
        loadConfigs()
    }

    func state(forUUID uuid: String) -> PersistedDisplayState? {
        loadConfigs().first { $0.uuid == uuid }
    }

    func recordDisabled(uuid: String, id: CGDirectDisplayID, name: String, headless: Bool = false, lastMode: DisplayMode? = nil) {
        upsert(uuid: uuid) {
            $0.isDisabled = true
            $0.lastKnownID = id
            $0.name = name
            if let lastMode, lastMode.width > 0 { $0.lastMode = lastMode }
            $0.headless = headless ? true : nil
            // A disabled display shows nothing, so any mirror choice is moot.
            $0.mirrorOf = nil
        }
    }

    func recordEnabled(uuid: String) {
        upsert(uuid: uuid) {
            $0.isDisabled = false
            $0.headless = nil
        }
    }

    /// `lastMode` is the mode the display had before mirroring: a mirror slave
    /// adopts the master's mode and macOS does not reliably give the old one
    /// back when the mirror is dissolved (seen: 1920x1080 -> 1280x720 -> 800x600
    /// over two mirror cycles).
    func recordMirror(uuid: String, of targetUUID: String, lastMode: DisplayMode? = nil) {
        upsert(uuid: uuid) {
            $0.mirrorOf = targetUUID
            if let lastMode, lastMode.width > 0 { $0.lastMode = lastMode }
        }
    }

    func recordUnmirror(uuid: String) {
        upsert(uuid: uuid) { $0.mirrorOf = nil }
    }

    /// Marks `uuid` as main and clears the flag on every other entry.
    func recordMain(uuid: String) {
        var configs = loadConfigs()
        for idx in configs.indices {
            configs[idx].isMain = (configs[idx].uuid == uuid)
        }
        if !configs.contains(where: { $0.uuid == uuid }) {
            configs.append(PersistedDisplayState(uuid: uuid, isDisabled: false, isMain: true))
        }
        writeConfigs(configs)
    }

    /// Drops every persisted flag for `uuid`. Used when a virtual display is
    /// destroyed: its UUID derives from a reusable serial slot, so stale flags
    /// would otherwise apply to whichever display inherits that slot later.
    func forget(uuid: String) {
        writeConfigs(loadConfigs().filter { $0.uuid != uuid })
    }

    func clearAll() {
        UserDefaults.standard.removeObject(forKey: persistenceKey)
    }

    // MARK: - Private

    private func upsert(uuid: String, mutate: (inout PersistedDisplayState) -> Void) {
        var configs = loadConfigs()
        if let idx = configs.firstIndex(where: { $0.uuid == uuid }) {
            mutate(&configs[idx])
        } else {
            var entry = PersistedDisplayState(uuid: uuid, isDisabled: false, isMain: false)
            mutate(&entry)
            configs.append(entry)
        }
        writeConfigs(configs)
    }

    private func loadConfigs() -> [PersistedDisplayState] {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey) else { return [] }
        do {
            return try JSONDecoder().decode([PersistedDisplayState].self, from: data)
        } catch {
            logger.error("Failed to decode display state: \(error.localizedDescription)")
            return []
        }
    }

    private func writeConfigs(_ configs: [PersistedDisplayState]) {
        do {
            let data = try JSONEncoder().encode(configs)
            UserDefaults.standard.set(data, forKey: persistenceKey)
        } catch {
            logger.error("Failed to encode display state: \(error.localizedDescription)")
        }
    }
}
