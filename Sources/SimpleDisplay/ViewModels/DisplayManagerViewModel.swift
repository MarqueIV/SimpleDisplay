import AppKit
import CoreGraphics
import Foundation
import Observation
import os
import SimpleDisplayCore

private let logger = Logger(subsystem: "app.simpledisplay", category: "ViewModel")

// MARK: - Navigation State

enum NavigationState: Equatable {
    case displayList
    case settings
    case addVirtualDisplay
    case configuringDisplay(CGDirectDisplayID)
}

@MainActor
@Observable
final class DisplayManagerViewModel {
    var displays: [DisplayInfo] = []
    var virtualDisplayIDs: Set<CGDirectDisplayID> = []
    /// Custom names for virtual displays (macOS assigns generic names like "Display 25")
    var virtualDisplayNames: [CGDirectDisplayID: String] = [:]
    var errorMessage: String?
    var isLoading: Bool = false

    /// True while an async display operation is in progress
    var isBusy: Bool = false
    /// Human-readable status of the current operation
    var busyMessage: String?

    var navigationState: NavigationState = .displayList
    /// True briefly during navigation transitions to prevent rapid clicks
    var isNavigating: Bool = false
    var newDisplayConfig = VirtualDisplayService.VirtualDisplayConfig()

    /// Reference to locale manager for localized messages
    var locale: LocaleManager?

    private let displayService = DisplayService()
    private let virtualService = VirtualDisplayService()
    private let statePersistence = DisplayStatePersistence()
    private var changeToken: DisplayChangeToken?
    private var screenChangeObserver: Any?
    private var sleepObserver: Any?
    private var wakeObserver: Any?
    private var debounceRefreshTask: Task<Void, Never>?

    /// Last-known info, keyed by UUID, for displays we disabled that have since
    /// dropped out of the online display list. A display disabled via
    /// `CGSConfigureDisplayEnabled` is removed from `CGGetOnlineDisplayList`
    /// entirely, so we synthesize a row from this cache to keep it visible and
    /// re-enableable rather than letting it silently disappear.
    private var disabledGhosts: [String: DisplayInfo] = [:]

    init() {
        virtualService.onDisplayTerminated = { [weak self] id in
            self?.virtualDisplayIDs.remove(id)
            self?.debouncedRefresh()
        }
        let restored = virtualService.restoreSavedDisplays()
        for entry in restored {
            virtualDisplayIDs.insert(entry.id)
            virtualDisplayNames[entry.id] = entry.name
        }
        // Seed ghost rows for displays disabled in a previous session so they
        // remain re-enableable even if macOS never brought them back online.
        for entry in statePersistence.loadAll() where entry.isDisabled {
            if let id = entry.lastKnownID, let name = entry.name {
                disabledGhosts[entry.uuid] = .disabledPlaceholder(id: id, uuid: entry.uuid, name: name)
            }
        }
        refresh()
        displayService.fixDuplicateDisplayProfiles(displays: displays)
        Task { await applyPersistedState() }
        registerForDisplayChanges()
        registerForSleepWake()
    }

    private func t(_ key: String) -> String {
        locale?.t(key) ?? key
    }

    private func t(_ key: String, _ args: any CVarArg...) -> String {
        locale?.t(key, args) ?? key
    }

    // MARK: - Navigation

    /// Navigate with a brief cooldown to prevent rapid double-clicks
    func navigate(to state: NavigationState) {
        guard !isNavigating else { return }
        isNavigating = true
        navigationState = state
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            isNavigating = false
        }
    }

    // MARK: - Data Loading

    func refresh() {
        isLoading = true
        let physical = displayService.fetchDisplays()
        let vIDs = virtualDisplayIDs
        var result = physical.map { info in
            let isVirtual = vIDs.contains(info.id)
            let displayName = isVirtual ? (virtualDisplayNames[info.id] ?? info.name) : info.name
            return info.with(name: displayName, isVirtual: isVirtual)
        }

        // Re-attach rows for disabled displays that have left the online list,
        // so the user can still toggle them back on. A ghost is addressed by a
        // CGDirectDisplayID that macOS may have reassigned since it was disabled,
        // so each one is reconciled against the live list before it is shown.
        let verdicts = GhostReconciler.reconcile(
            ghosts: disabledGhosts.map { GhostReconciler.Ghost(uuid: $0.key, id: $0.value.id) },
            live: result.map { GhostReconciler.Live(uuid: $0.uuid, id: $0.id) },
            resolveID: { displayService.displayID(forUUID: $0) }
        )
        for (uuid, ghost) in disabledGhosts.sorted(by: { $0.value.name < $1.value.name }) {
            switch verdicts[uuid] {
            case .backOnline:
                // The display is live again; its real row replaces the ghost.
                disabledGhosts[uuid] = nil
            case .keep(let id):
                let row = ghost.id == id ? ghost : ghost.with(id: id)
                disabledGhosts[uuid] = row
                result.append(row)
            case .collided(let liveUUID):
                // Toggling this ghost would act on whichever display now owns its
                // ID. Drop the row but keep the persisted disabled flag, so the
                // display is disabled again (with a fresh ID) if it comes back.
                logger.warning("Dropping ghost row '\(ghost.name)' (\(uuid)): its retained ID \(ghost.id) now belongs to \(liveUUID ?? "a display without UUID")")
                disabledGhosts[uuid] = nil
            case nil:
                break
            }
        }

        displays = result
        isLoading = false
    }

    /// Debounced refresh to coalesce rapid display change callbacks
    private func debouncedRefresh() {
        debounceRefreshTask?.cancel()
        debounceRefreshTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            refresh()
        }
    }

    /// Polls the live display list until it stops changing (or a timeout), then
    /// refreshes once. Enabling or disabling a display triggers a global display
    /// reconfiguration in which *other* displays momentarily leave the online
    /// list. A single fixed-delay refresh can capture that partial snapshot and
    /// make an unrelated display's row vanish until the next system callback —
    /// which may never arrive. Waiting for the topology to stabilize avoids
    /// committing a half-finished state.
    private func settleAndRefresh(maxPolls: Int = 15) async {
        var previous: Set<CGDirectDisplayID> = []
        var stableHits = 0
        for _ in 0..<maxPolls {
            try? await Task.sleep(for: .milliseconds(200))
            let current = Set(displayService.fetchDisplays().map { $0.id })
            if current == previous {
                stableHits += 1
                if stableHits >= 2 { break }   // unchanged across ~400ms
            } else {
                stableHits = 0
                previous = current
            }
        }
        refresh()
    }

    /// Re-applies a display mode after a display has been brought back online,
    /// since `CGSConfigureDisplayEnabled` can re-enable a display at a default
    /// (often non-HiDPI) mode. The display is looked up by UUID: re-enabling is
    /// a topology change, after which macOS may hand it a new CGDirectDisplayID.
    /// No-op if the display is not back yet or already has the mode.
    private func restoreMode(_ mode: DisplayMode, forUUID uuid: String) {
        guard let current = displays.first(where: { $0.uuid == uuid && $0.isActive }) else {
            logger.info("Skipping mode restore: display \(uuid) is not active yet")
            return
        }
        guard current.currentMode != mode else { return }
        do {
            try displayService.setDisplayMode(mode, for: current.id)
            refresh()
        } catch {
            logger.warning("Could not restore display mode after enable: \(error.localizedDescription)")
        }
    }

    // MARK: - Resolution Change

    func changeResolution(of display: DisplayInfo, to mode: DisplayMode) {
        do {
            try displayService.setDisplayMode(mode, for: display.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Set Main Display

    func setAsMainDisplay(_ display: DisplayInfo) {
        guard display.isActive, !display.isMain, !isBusy else { return }
        isBusy = true
        busyMessage = t("setting_main")
        Task {
            defer { isBusy = false; busyMessage = nil }
            do {
                try displayService.setMainDisplay(display.id)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
            if let uuid = display.uuid {
                statePersistence.recordMain(uuid: uuid)
            }
            await settleAndRefresh()
        }
    }

    // MARK: - Enable / Disable Display

    var activeDisplays: [DisplayInfo] {
        displays.filter { $0.isActive }
    }

    func toggleDisplay(_ display: DisplayInfo) {
        guard !isBusy else { return }
        let wasEnabled = display.isActive
        let uuid = display.uuid
        // A ghost is a disabled display that has left the online list; its row
        // is synthesized from retained identity rather than live CG state.
        let wasGhost = !wasEnabled && uuid.map { disabledGhosts[$0] != nil } ?? false
        // When re-enabling, macOS brings the display back at a default mode that
        // can drop HiDPI. Remember the mode it had so we can restore it.
        let modeToRestore: DisplayMode? = (!wasEnabled && !display.isPlaceholder) ? display.currentMode : nil
        isBusy = true
        busyMessage = wasEnabled
            ? t("disabling_format", display.name)
            : t("enabling_format", display.name)
        Task {
            defer { isBusy = false; busyMessage = nil }

            if wasEnabled {
                do { try displayService.disableDisplay(display.id, allDisplays: displays) } catch {
                    errorMessage = error.localizedDescription
                    return
                }
                // Retain identity so the row survives the display leaving the
                // online list (both in-session and across an app restart).
                if let uuid {
                    disabledGhosts[uuid] = display.asDisabledGhost()
                    statePersistence.recordDisabled(uuid: uuid, id: display.id, name: display.name)
                }
            } else {
                // Prefer the ID macOS assigns the UUID right now; the retained one
                // is the fallback for when the UUID does not resolve while disabled.
                let targetID = uuid.flatMap { displayService.displayID(forUUID: $0) } ?? display.id
                do { try displayService.enableDisplay(targetID) } catch {
                    if wasGhost, let uuid, displayService.displayID(forUUID: uuid) == nil {
                        // The window server does not know this display any more
                        // (unplugged and never returned). Its toggle could only
                        // ever fail, so forget it instead of leaving a dead row.
                        disabledGhosts[uuid] = nil
                        statePersistence.recordEnabled(uuid: uuid)
                        refresh()
                        errorMessage = t("display_unreachable_forgotten_format", display.name)
                    } else {
                        errorMessage = error.localizedDescription
                    }
                    return
                }
                // Record the user's intent right away, but leave the ghost row in
                // place: refresh() drops it once the display is actually back in
                // the online list, so the row cannot vanish if the display takes
                // longer than the settle window to reappear.
                if let uuid {
                    statePersistence.recordEnabled(uuid: uuid)
                }
            }

            await settleAndRefresh()

            // Restore the pre-disable mode if re-enabling reset it (e.g. HiDPI → non-HiDPI).
            if let modeToRestore, let uuid {
                restoreMode(modeToRestore, forUUID: uuid)
            }

            // Safety: re-enable a display if all got disabled
            if wasEnabled {
                let active = displays.filter { $0.isActive }
                if active.isEmpty {
                    let fallback = displays.first(where: { $0.isBuiltIn }) ?? displays.first
                    if let target = fallback {
                        busyMessage = t("re_enabling_format", target.name)
                        do {
                            try displayService.enableDisplay(target.id)
                            if let uuid = target.uuid {
                                statePersistence.recordEnabled(uuid: uuid)
                            }
                            await settleAndRefresh()
                        } catch {
                            errorMessage = t("all_disabled_error", error.localizedDescription)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Virtual Display Management

    func createVirtualDisplay() {
        guard !isBusy else { return }
        isBusy = true
        busyMessage = t("creating_virtual")
        Task {
            defer { isBusy = false; busyMessage = nil }
            do {
                let id = try virtualService.createVirtualDisplay(config: newDisplayConfig)
                virtualDisplayIDs.insert(id)
                virtualDisplayNames[id] = newDisplayConfig.name
                newDisplayConfig = VirtualDisplayService.VirtualDisplayConfig()
                navigationState = .displayList
            } catch {
                errorMessage = error.localizedDescription
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
            refresh()
        }
    }

    func removeVirtualDisplay(_ display: DisplayInfo) {
        guard !isBusy else { return }
        isBusy = true
        busyMessage = t("removing_format", display.name)
        Task {
            defer { isBusy = false; busyMessage = nil }
            await forgetDisabledState(of: display)
            virtualService.removeVirtualDisplay(id: display.id)
            virtualDisplayIDs.remove(display.id)
            virtualDisplayNames.removeValue(forKey: display.id)
            refresh()
        }
    }

    /// A virtual display about to be destroyed must not leave a disabled
    /// footprint behind. Destroying a `CGVirtualDisplay` while it is disabled
    /// leaves a phantom in the window server that the next display created with
    /// the same serial inherits, mode included (seen on macOS 26: a 1600x900
    /// HiDPI display came back as the destroyed one's 1280x720). So: re-enable
    /// it first and wait for the topology to settle, drop its ghost row, and
    /// forget its persisted flags, since its UUID derives from a reusable serial
    /// slot and stale flags would apply to whichever display inherits the slot.
    private func forgetDisabledState(of display: DisplayInfo) async {
        if !display.isActive {
            let targetID = display.uuid.flatMap { displayService.displayID(forUUID: $0) } ?? display.id
            do {
                try displayService.enableDisplay(targetID)
                await settleAndRefresh()
            } catch {
                logger.warning("Could not re-enable '\(display.name)' before removing it: \(error.localizedDescription)")
            }
        }
        if let uuid = display.uuid {
            disabledGhosts[uuid] = nil
            statePersistence.forget(uuid: uuid)
        }
    }

    /// Reconfigure a virtual display by recreating it with new settings.
    func reconfigureVirtualDisplay(_ display: DisplayInfo, width: Int, height: Int, refreshRate: Double = 60, hiDPI: Bool = false, name: String? = nil) {
        guard !isBusy else { return }
        isBusy = true
        busyMessage = t("reconfiguring")
        Task {
            defer { isBusy = false; busyMessage = nil }
            let displayName = name ?? display.name
            await forgetDisabledState(of: display)
            virtualService.removeVirtualDisplay(id: display.id)
            virtualDisplayIDs.remove(display.id)
            virtualDisplayNames.removeValue(forKey: display.id)

            let config = VirtualDisplayService.VirtualDisplayConfig(
                name: displayName,
                width: width, height: height,
                refreshRate: refreshRate, hiDPI: hiDPI
            )
            do {
                let newID = try virtualService.createVirtualDisplay(config: config)
                virtualDisplayIDs.insert(newID)
                virtualDisplayNames[newID] = displayName
            } catch {
                errorMessage = error.localizedDescription
                return
            }

            navigationState = .displayList
            try? await Task.sleep(for: .milliseconds(500))
            refresh()
        }
    }

    // MARK: - URL Scheme

    /// Dispatches a parsed `simpledisplay://` command to the appropriate
    /// existing public method. Side-effects (toast, refresh, nav) are
    /// intentionally identical to what happens when the user clicks the
    /// equivalent button — this is just another entry point, not a shadow
    /// execution path.
    func execute(urlCommand command: URLCommand) {
        // ColorSyncUnregisterDevice -> AuthorizationCreate hace XPC sincronico que se
        // deadlockea dentro del handler de Apple Events (GURL). Diferir el comando al
        // siguiente ciclo del runloop para ejecutarlo fuera de ese contexto.
        DispatchQueue.main.async { self.executeNow(urlCommand: command) }
    }

    private func executeNow(urlCommand command: URLCommand) {
        switch command {
        case .open:
            navigate(to: .displayList)
            NSApp.activate(ignoringOtherApps: true)

        case .create(let request):
            newDisplayConfig = VirtualDisplayService.VirtualDisplayConfig(
                name: request.name,
                width: request.width,
                height: request.height,
                refreshRate: request.refreshRate,
                hiDPI: request.hiDPI
            )
            createVirtualDisplay()

        case .remove(.id(let rawID)):
            let id = CGDirectDisplayID(rawID)
            guard let display = displays.first(where: { $0.id == id && $0.isVirtual }) else {
                errorMessage = t("unknown_virtual_display_id", rawID as CVarArg)
                return
            }
            removeVirtualDisplay(display)

        case .remove(.name(let name)):
            // remotedesk: matching robusto — por displays activos O por el mapa de nombres
            if let display = displays.first(where: { $0.isVirtual && $0.name == name }) {
                removeVirtualDisplay(display)
            } else {
                let ids = virtualDisplayNames.filter { $0.value == name }.map { $0.key }
                if ids.isEmpty {
                    errorMessage = t("unknown_virtual_display_name", name as CVarArg)
                    return
                }
                for id in ids {
                    virtualService.removeVirtualDisplay(id: id)
                    virtualDisplayIDs.remove(id)
                    virtualDisplayNames.removeValue(forKey: id)
                }
                refresh()
            }

        case .setEnabled(let target, let enabled):
            refresh()
            let match: DisplayInfo?
            switch target {
            case .id(let rawID): match = displays.first { $0.id == CGDirectDisplayID(rawID) }
            case .name(let name): match = displays.first { $0.name == name }
            }
            guard let display = match else {
                errorMessage = "No display matches \(String(describing: target))"
                return
            }
            if display.isActive != enabled {
                toggleDisplay(display)
            }

        case .status:
            writeStatusSnapshot()

        case .reconfigure(let rawID, let request):
            let id = CGDirectDisplayID(rawID)
            guard let display = displays.first(where: { $0.id == id && $0.isVirtual }) else {
                errorMessage = t("unknown_virtual_display_id", rawID as CVarArg)
                return
            }
            // Only propagate a rename if the caller actually passed one.
            let explicitName = request.name == VirtualDisplayRequest().name ? nil : request.name
            reconfigureVirtualDisplay(
                display,
                width: request.width,
                height: request.height,
                refreshRate: request.refreshRate,
                hiDPI: request.hiDPI,
                name: explicitName
            )
        }
    }

    /// Snapshot of every display for remote controllers. Written to a fixed
    /// path so an SSH caller can `open simpledisplay://status` and read it.
    private func writeStatusSnapshot() {
        refresh()
        let items: [[String: Any]] = displays.map { d in
            [
                "id": Int(d.id),
                "name": d.name,
                "virtual": d.isVirtual,
                "on": d.isActive,
                "main": d.isMain,
                "builtin": d.isBuiltIn,
                "width": d.currentMode.width,
                "height": d.currentMode.height,
                "hidpi": d.currentMode.isHiDPI,
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: items, options: [.sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/simpledisplay-status.json"))
        }
    }

    // MARK: - Color Profile Fix

    /// Re-applies sRGB profiles to all displays to prevent ColorSync CPU loop.
    /// Called after cleaning the display cache.
    func fixColorProfiles() {
        refresh()
        displayService.fixDuplicateDisplayProfiles(displays: displays)
    }

    // MARK: - Display Change Monitoring

    private func registerForDisplayChanges() {
        changeToken = displayService.registerDisplayChangeCallback { [weak self] _, flags in
            guard !flags.contains(.beginConfigurationFlag) else { return }
            Task { @MainActor in
                self?.debouncedRefresh()
            }
        }
        // Fallback: NSNotification (CGDisplayReconfigurationCallback may not fire on macOS Tahoe+)
        screenChangeObserver = displayService.registerScreenChangeNotification { [weak self] in
            self?.debouncedRefresh()
        }
    }

    // MARK: - Sleep / Wake Handling

    private func registerForSleepWake() {
        let ws = NSWorkspace.shared.notificationCenter

        sleepObserver = ws.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleSleep()
            }
        }

        wakeObserver = ws.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // Delay to let macOS settle display state after wake
                try? await Task.sleep(for: .seconds(3))
                self?.handleWake()
            }
        }
    }

    /// Before sleep: just clear any in-flight busy state. Unlike the old
    /// mirror-based disable, a display disabled via CGSConfigureDisplayEnabled
    /// survives sleep cleanly, so no pre-sleep teardown is required.
    private func handleSleep() {
        isBusy = false
        busyMessage = nil
    }

    /// After wake: refresh, then re-apply persisted state in case macOS
    /// re-activated a display that the user had disabled.
    private func handleWake() {
        refresh()
        Task { await applyPersistedState() }
    }

    // MARK: - Persisted State Restore

    /// Re-apply previously-saved disable/main flags to whatever physical displays
    /// are currently online. Runs once at startup, in an async Task so it can
    /// pause between CG operations — `disableDisplay` reconfigures the
    /// display tree and the system needs a moment to settle before the next
    /// call uses fresh CG state.
    ///
    /// Mirroring still uses `.forSession` as a crash-recovery safety net; this
    /// async re-application is what makes the user's choice survive logout/reboot.
    private func applyPersistedState() async {
        let saved = statePersistence.loadAll()
        guard !saved.isEmpty else { return }

        // Virtual displays restored at launch, and displays re-attached on wake,
        // can take a moment to show up in the online list. Deciding on a partial
        // snapshot would silently skip them, so wait for the topology to settle.
        await settleAndRefresh()

        let savedByUUID = Dictionary(uniqueKeysWithValues: saved.map { ($0.uuid, $0) })

        // Step 1: restore the saved main display first. Doing this before the
        // disables avoids a chain reaction where `disableDisplay` of the current
        // main forces an arbitrary main-transfer that we'd then have to undo.
        if let savedMain = saved.first(where: { $0.isMain }),
           let target = displays.first(where: { $0.uuid == savedMain.uuid }),
           target.isActive,
           !target.isMain {
            do {
                try displayService.setMainDisplay(target.id)
                logger.info("Restored main display '\(target.name)'")
                await settleAndRefresh()
            } catch {
                logger.warning("Could not restore main display: \(error.localizedDescription)")
            }
        }

        // Step 2: disable each saved-disabled display, one at a time, refreshing
        // between calls so each `disableDisplay` sees live state. Skip if the
        // operation would leave zero active displays.
        let toDisableUUIDs: [String] = displays.compactMap { display in
            guard
                let uuid = display.uuid,
                let entry = savedByUUID[uuid],
                entry.isDisabled,
                display.isActive
            else { return nil }
            return uuid
        }

        for uuid in toDisableUUIDs {
            guard let display = displays.first(where: { $0.uuid == uuid }), display.isActive else {
                continue
            }
            let activeCount = displays.filter { $0.isActive }.count
            guard activeCount > 1 else {
                logger.info("Skipping persisted disable of '\(display.name)' — would leave zero active")
                continue
            }
            do {
                try displayService.disableDisplay(display.id, allDisplays: displays)
                // Capture identity before the display leaves the online list, and
                // refresh persisted id/name in case they were missing.
                disabledGhosts[uuid] = display.asDisabledGhost()
                statePersistence.recordDisabled(uuid: uuid, id: display.id, name: display.name)
                logger.info("Restored disabled state on '\(display.name)'")
                await settleAndRefresh()
            } catch {
                logger.warning("Could not restore disabled state on '\(display.name)': \(error.localizedDescription)")
            }
        }
    }

}
