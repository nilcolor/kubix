import KubixCore
import SwiftUI

struct LogView: View {
    let session: LogSession
    let actions: AppActions

    private var following: Bool { session.state == .following || session.state == .connecting }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if session.target.context.cluster.insecureSkipTLSVerify == true {
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
            Text("Bounded to 2,000 lines / 2 MiB; \(session.buffer.evicted) evicted. Long lines are truncated; invalid UTF-8 is replaced.")
                .font(.caption2).foregroundStyle(.secondary)
            NativeLogList(session: session, actions: actions)
        }.padding(8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
