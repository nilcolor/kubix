import KubixCore
import SwiftUI

struct LogView: View {
    let session: LogSession
    let actions: AppActions

    private var following: Bool { session.state == .following || session.state == .connecting }

    /// The ring grows with the number of streams sharing it, so the figure is read rather than
    /// written: a tab following forty pods is not bounded to the same 2,000 lines as one pod's.
    private var bounds: String {
        let lines = session.buffer.maximumLines.formatted(.number.grouping(.automatic))
        let bytes = (session.buffer.maximumBytes / 1_048_576)
        return "Bounded to \(lines) lines / \(bytes) MiB; \(session.buffer.evicted) evicted. "
            + "Long lines are truncated; invalid UTF-8 is replaced."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if session.scope.context.cluster.insecureSkipTLSVerify == true {
                Text("WARNING: TLS certificate verification disabled.").foregroundStyle(.red)
            }
            HStack {
                Toggle("Follow", isOn: Binding(get: { following }, set: {
                    if $0 { actions.resumeLog(session.id) } else { actions.pauseLog(session.id) }
                })).toggleStyle(.checkbox)
                if !following { Button("Resume") { actions.resumeLog(session.id) } }
                TextField("Filter log lines", text: Binding(get: { session.filter }, set: { actions.setLogFilter(session.id, $0) }))
                Button("Latest") { actions.setLogAutoscroll(session.id, true) }
                    .disabled(session.autoscroll)
            }
            Text(session.status).font(.caption).textSelection(.enabled)
            Text("Segment \(session.segment). " + LogSession.replayNotice).font(.caption2).foregroundStyle(.secondary)
            Text(bounds).font(.caption2).foregroundStyle(.secondary)
            NativeLogList(session: session, actions: actions)
        }.padding(8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
