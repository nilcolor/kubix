import SwiftUI

struct ContentView: View {
    @State private var session: LocalTerminalSession?

    var body: some View {
        Group {
            if let failure = session?.failure {
                ContentUnavailableView("Terminal unavailable", systemImage: "exclamationmark.triangle", description: Text(failure))
            } else if session?.isClosed == true {
                ContentUnavailableView("Shell exited", systemImage: "terminal")
            } else if let surface = session?.view {
                TerminalView(surface: surface)
            } else {
                ProgressView("Starting terminal")
            }
        }
        .frame(minWidth: 480, maxWidth: .infinity, minHeight: 320, maxHeight: .infinity)
        .task {
            // SwiftUI may reconstruct ContentView freely; create the owned session only after mounting.
            if session == nil {
                #if DEBUG
                session = LocalTerminalSession(configuration: TerminalSmokeTest.configuration)
                #else
                session = LocalTerminalSession()
                #endif
            }
            #if DEBUG
            if let session { await TerminalSmokeTest.run(session) }
            #endif
        }
    }
}
