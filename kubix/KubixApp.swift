import SwiftUI

struct KubixApp: App {
    @NSApplicationDelegateAdaptor(TerminalAppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Kubix") {
            ContentView()
        }
        .defaultSize(width: 900, height: 600)
    }
}
