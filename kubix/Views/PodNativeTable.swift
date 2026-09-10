import AppKit

/// Return dispatches only with the table focused. Menus bind to the right-clicked row.
final class PodNativeTable: NSTableView {
    var openShell: ((Int, Bool) -> (@MainActor () -> Void)?)?
    var openLogs: ((Int) -> (@MainActor () -> Void)?)?
    private var menuShell: (@MainActor () -> Void)?
    private var menuLogs: (@MainActor () -> Void)?

    override func keyDown(with event: NSEvent) {
        if [36, 76].contains(event.keyCode), event.modifierFlags.isDisjoint(with: [.command, .control, .option, .shift]) {
            openShell?(selectedRow, false)?()
        } else { super.keyDown(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let clicked = row(at: convert(event.locationInWindow, from: nil))
        guard let action = openShell?(clicked, true) else { return nil }
        menuShell = action
        menuLogs = openLogs?(clicked)
        let menu = NSMenu()
        let item = NSMenuItem(title: "Shell", action: #selector(shellFromMenu), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        let logs = NSMenuItem(title: "Logs", action: #selector(logsFromMenu), keyEquivalent: "")
        logs.target = self
        menu.addItem(logs)
        return menu
    }

    @objc private func shellFromMenu() {
        let action = menuShell
        menuShell = nil
        action?()
    }

    @objc private func logsFromMenu() {
        let action = menuLogs
        menuLogs = nil
        action?()
    }
}
