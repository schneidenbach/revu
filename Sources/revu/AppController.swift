import AppKit
import SwiftUI

/// Owns the window, menu bar and the close/quit confirmation flow.
@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    let state: AppState
    private var window: NSWindow?
    private var keyMonitor: Any?

    init(state: AppState) {
        self.state = state
    }

    func start() {
        buildMenu()
        state.startWatching()
        let hosting = NSHostingController(rootView: RootView().environment(state))
        hosting.sceneBridgingOptions = .all
        hosting.sizingOptions = []   // the window, not the SwiftUI content, decides its size
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 1440, height: 900))
        window.title = state.windowTitle
        window.center()
        window.minSize = NSSize(width: 900, height: 500)
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        self.window = window

        // Local monitors run on the main thread; NSEvent just isn't marked Sendable.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            nonisolated(unsafe) let unsafeEvent = event
            let handled = MainActor.assumeIsolated { self?.handleKey(unsafeEvent) ?? false }
            return handled ? nil : event
        }
    }

    // MARK: Closing

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        confirmClose()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        confirmClose()
        return .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Exits with status 2 unless the user cancels or chooses to submit.
    private func confirmClose() {
        state.flushDraft()
        guard state.hasContent else { state.discard() }
        let alert = NSAlert()
        alert.messageText = "Submit your review?"
        alert.informativeText = "You have unsent comments. Closing without submitting discards them and tells the agent the review was abandoned."
        alert.addButton(withTitle: "Submit Review")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: state.openFinish()
        case .alertSecondButtonReturn: state.discard()
        default: break
        }
    }

    // MARK: Keys

    /// j/k next/previous file, n/p next/previous change, space toggles Viewed. Never while typing.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, window.attachedSheet == nil,
              !(window.firstResponder is NSText),
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let key = event.charactersIgnoringModifiers else { return false }
        switch key {
        case "j": state.moveFile(1)
        case "k": state.moveFile(-1)
        case "n": state.moveChange(1)
        case "p": state.moveChange(-1)
        case " ": state.toggleViewedAndAdvance()
        default: return false
        }
        return true
    }

    // MARK: Menu

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action == #selector(openInEditor) ? state.canOpenInEditor(state.selection) : true
    }

    @objc private func showChanges() { state.mode = .changes }
    @objc private func showFile() { state.mode = .file }
    @objc private func toggleWrap() { state.wrap.toggle() }
    @objc private func biggerFont() { state.adjustFont(1) }
    @objc private func smallerFont() { state.adjustFont(-1) }
    @objc private func resetFont() { state.resetFont() }
    @objc private func refresh() { state.refresh() }
    @objc private func finishReview() { state.openFinish() }
    @objc private func openInEditor() { state.openSelectedInEditor() }
    @objc private func nextFile() { state.moveFile(1) }
    @objc private func previousFile() { state.moveFile(-1) }
    @objc private func nextChange() { state.moveChange(1) }
    @objc private func previousChange() { state.moveChange(-1) }

    private func buildMenu() {
        let main = NSMenu()
        func add(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "",
                 _ flags: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = flags
            if let target { item.target = target }
        }
        func submenu(_ title: String) -> NSMenu {
            let menu = NSMenu(title: title)
            main.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = menu
            return menu
        }

        let app = submenu("Revu")
        add(app, "Hide Revu", #selector(NSApplication.hide(_:)), "h")
        add(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        app.addItem(.separator())
        add(app, "Quit Revu", #selector(NSApplication.terminate(_:)), "q")

        let edit = submenu("Edit")
        add(edit, "Undo", Selector(("undo:")), "z")
        add(edit, "Redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        add(edit, "Cut", #selector(NSText.cut(_:)), "x")
        add(edit, "Copy", #selector(NSText.copy(_:)), "c")
        add(edit, "Paste", #selector(NSText.paste(_:)), "v")
        add(edit, "Select All", #selector(NSText.selectAll(_:)), "a")

        let view = submenu("View")
        add(view, "Changes", #selector(showChanges), "1", target: self)
        add(view, "File", #selector(showFile), "2", target: self)
        view.addItem(.separator())
        add(view, "Wrap Lines", #selector(toggleWrap), "", target: self)
        add(view, "Bigger Text", #selector(biggerFont), "+", target: self)
        add(view, "Smaller Text", #selector(smallerFont), "-", target: self)
        add(view, "Actual Size", #selector(resetFont), "0", target: self)
        let altBigger = view.addItem(withTitle: "Bigger Text", action: #selector(biggerFont), keyEquivalent: "=")
        altBigger.target = self
        altBigger.isHidden = true
        altBigger.allowsKeyEquivalentWhenHidden = true
        view.addItem(.separator())
        add(view, "Refresh", #selector(refresh), "r", target: self)

        let review = submenu("Review")
        add(review, "Finish Review…", #selector(finishReview), "\r", [.command, .shift], target: self)
        add(review, "Open in \(state.externalEditor.name)", #selector(openInEditor), "o", [.command, .shift], target: self)
        review.addItem(.separator())
        add(review, "Next File", #selector(nextFile), "", target: self)
        add(review, "Previous File", #selector(previousFile), "", target: self)
        add(review, "Next Change", #selector(nextChange), "", target: self)
        add(review, "Previous Change", #selector(previousChange), "", target: self)

        let windowMenu = submenu("Window")
        add(windowMenu, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(windowMenu, "Zoom", #selector(NSWindow.performZoom(_:)))
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }
}
