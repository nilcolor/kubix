import AppKit
import KubixCore

struct BrowserLauncher: BrowserOpening {
    func open(_ url: URL) async -> Bool {
        guard url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil else { return false }
        return NSWorkspace.shared.open(url)
    }
}
