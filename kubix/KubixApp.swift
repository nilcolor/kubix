import SwiftUI

struct KubixApp: App {
    @NSApplicationDelegateAdaptor(TerminalAppDelegate.self) private var delegate

    var body: some Scene {
        Window("Kubix", id: "main") {
            #if DEBUG
            if TerminalSmokeTest.isEnabled {
                TerminalSmokeView()
            } else {
                ContentView(composition: .shared)
            }
            #else
            ContentView(composition: .shared)
            #endif
        }
        .defaultSize(width: 1050, height: 800)
    }
}
