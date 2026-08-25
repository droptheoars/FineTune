// FineTune/Views/AUPluginWindowController.swift
import AppKit
import AudioToolbox
import CoreAudioKit
import os

/// Owns the floating windows that host third-party Audio Unit UIs — one window
/// per plugin slot, keyed by the slot's `UUID` (spec §5.4).
///
/// Lifetime rules (§2.5, §6 E5/E6/E10):
/// - Closing a window never removes the plugin or touches its bypass state; it
///   fires `onCaptureState` so the owner can snapshot `fullState` (§4).
/// - Windows survive device switches and sample-rate rebuilds — the rebuild keeps
///   the same `AUAudioUnit` instance, so there is nothing to tear down here.
/// - `close(slotID:)` / `closeAll()` are the owner's force-close routes (slot
///   removed, chain reset to default, app left the list). They are deliberately
///   *silent*: the owner captures state before releasing instances, and firing a
///   capture from a teardown path risks capturing after dealloc (E10).
@MainActor
final class AUPluginWindowController {
    static let shared = AUPluginWindowController()

    private struct Hosted {
        let panel: NSPanel
        let onCaptureState: @MainActor () -> Void
        let closeObserver: NSObjectProtocol
    }

    private var hosted: [UUID: Hosted] = [:]
    private let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "AUPluginWindow")

    /// Open slot IDs — polled for the 60s `fullState` capture timer (§4).
    var openSlotIDs: [UUID] { Array(hosted.keys) }

    func isOpen(slotID: UUID) -> Bool { hosted[slotID] != nil }

    // MARK: - Open

    /// Opens (or focuses) the window for `slotID`. `onCaptureState` fires when the
    /// user closes it; a forced `close(slotID:)` does not fire it.
    func open(
        slotID: UUID,
        audioUnit: AUAudioUnit,
        pluginName: String,
        appName: String,
        onCaptureState: @escaping @MainActor () -> Void
    ) {
        if let existing = hosted[slotID] {
            NSApp.activate(ignoringOtherApps: true)
            existing.panel.makeKeyAndOrderFront(nil)
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "\(pluginName) — \(appName)"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        // Restore before registering the autosave name: setFrameAutosaveName saves
        // the *current* frame, which would clobber the stored one.
        let autosaveName = "AUWindow-\(slotID.uuidString)"
        let restoredFrame = panel.setFrameUsingName(autosaveName)
        panel.setFrameAutosaveName(autosaveName)

        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleUserClose(slotID: slotID, panel: panel)
            }
        }

        hosted[slotID] = Hosted(panel: panel, onCaptureState: onCaptureState, closeObserver: observer)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        // The completion handler runs on a queue internal to the AU implementation
        // (see AUViewController.h), and may arrive long after the user closed the
        // window — hence the hop to the main actor plus the identity check in embed().
        nonisolated(unsafe) let au = audioUnit
        audioUnit.requestViewController { [weak self] viewController in
            Task { @MainActor in
                self?.embed(viewController, au: au, slotID: slotID, panel: panel, restoredFrame: restoredFrame)
            }
        }
    }

    // MARK: - Close

    func close(slotID: UUID) {
        guard let entry = hosted.removeValue(forKey: slotID) else { return }
        NotificationCenter.default.removeObserver(entry.closeObserver)
        entry.panel.contentViewController = nil
        entry.panel.close()
    }

    func closeAll() {
        for slotID in Array(hosted.keys) { close(slotID: slotID) }
    }

    // MARK: - Private

    private func handleUserClose(slotID: UUID, panel: NSPanel) {
        // Ignore a stale notification from a panel that is no longer the slot's.
        guard let entry = hosted[slotID], entry.panel === panel else { return }
        hosted.removeValue(forKey: slotID)
        NotificationCenter.default.removeObserver(entry.closeObserver)
        // Drop the view controller (and with it the plugin's reference from the UI
        // side) before the capture, so nothing outlives the window.
        panel.contentViewController = nil
        entry.onCaptureState()
    }

    private func embed(
        _ viewController: NSViewController?,
        au: AUAudioUnit,
        slotID: UUID,
        panel: NSPanel,
        restoredFrame: Bool
    ) {
        // The window may have been closed (or reopened as a different panel) while
        // the AU was building its view. Drop the late arrival on the floor.
        guard let entry = hosted[slotID], entry.panel === panel else {
            logger.debug("Discarding late view controller for closed plugin window")
            return
        }

        let content: NSViewController
        if let viewController {
            content = viewController
        } else if let generic = makeGenericViewController(for: au) {
            content = generic
        } else {
            content = placeholderViewController()
        }

        let savedFrame = panel.frame
        panel.contentViewController = content
        if restoredFrame {
            // An autosaved frame wins over the plugin's preferred size.
            panel.setFrame(savedFrame, display: true)
        } else {
            let preferred = preferredSize(of: content)
            panel.setContentSize(preferred)
            panel.center()
        }
    }

    private func makeGenericViewController(for au: AUAudioUnit) -> NSViewController? {
        let generic = AUGenericViewController()
        generic.auAudioUnit = au
        // A generic view that cannot lay itself out against this AU is the
        // "both paths failed" case; fall through to the placeholder.
        guard generic.view.fittingSize.width > 0 || generic.view.frame.width > 0 else { return nil }
        return generic
    }

    private func placeholderViewController() -> NSViewController {
        let icon = NSImageView(
            image: NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
                ?? NSImage()
        )
        icon.contentTintColor = .secondaryLabelColor
        let label = NSTextField(labelWithString: "This plugin has no interface FineTune can display.")
        label.alignment = .center
        label.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [icon, label])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 32, left: 32, bottom: 32, right: 32)

        let vc = NSViewController()
        vc.view = stack
        return vc
    }

    private func preferredSize(of viewController: NSViewController) -> NSSize {
        let preferred = viewController.preferredContentSize
        if preferred.width > 0, preferred.height > 0 { return preferred }
        let frame = viewController.view.frame.size
        if frame.width > 0, frame.height > 0 { return frame }
        let fitting = viewController.view.fittingSize
        if fitting.width > 0, fitting.height > 0 { return fitting }
        return NSSize(width: 480, height: 320)
    }
}
