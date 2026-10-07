import AppKit

/// Return dispatches only with the table focused. Menus bind to the right-clicked row.
///
/// Both actions are optional and are offered independently: a deployment row has logs but nothing to
/// exec into, and a menu that appeared only when a shell was available would have taken Logs with it.
final class ResourceNSTableView: NSTableView {
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
        menuShell = openShell?(clicked, true)
        menuLogs = openLogs?(clicked)
        let items = [
            menuShell.map { _ in ("Shell", #selector(shellFromMenu)) },
            menuLogs.map { _ in ("Logs", #selector(logsFromMenu)) },
        ].compactMap { $0 }
        guard !items.isEmpty else { return nil }
        let menu = NSMenu()
        for (title, selector) in items {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
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
