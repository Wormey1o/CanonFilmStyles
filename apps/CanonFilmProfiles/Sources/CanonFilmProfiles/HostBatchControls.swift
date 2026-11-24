import SwiftUI

struct HostBatchControls: View {
    @ObservedObject var session: HostBatchSession
    let exporting: Bool

    var body: some View {
        if let request = session.request {
            LabeledContent("Pinned manifest", value: request.manifest.lastPathComponent)
                .font(.caption)
                .textSelection(.enabled)
            if session.readyToRun {
                Button("Run exported batch on this Mac", action: session.run)
                    .disabled(exporting)
            }

            if session.isActive, let report = session.report {
                ProgressView(value: Double(report.jobs.count), total: Double(report.jobCount)) {
                    Text(progressLabel(report))
                } currentValueLabel: {
                    Text("\(report.jobs.count) of \(report.jobCount) jobs accounted for")
                }
                .controlSize(.small)
                Button("Cancel host batch", action: session.cancel)
                    .disabled(session.cancelRequested || report.terminal != nil)
            }

            if let message = session.message {
                Text(message).font(.caption).textSelection(.enabled)
            }
            if let report = session.report, !session.isActive, !report.jobs.isEmpty {
                let counts = HostBatchProtocol.JobState.allCases.compactMap { state -> String? in
                    let count = report.jobs.count { $0 == state }
                    return count > 0 ? "\(state.label) \(count)" : nil
                }
                Text(counts.joined(separator: " · ")).font(.caption)
            }
            if let path = session.scratchPath {
                LabeledContent("Temporary local result folder", value: path)
                    .font(.caption)
                    .textSelection(.enabled)
            }
            if session.readyToRestart {
                Button("Verify & restart", action: session.restart)
                    .disabled(exporting)
                Text("Recheck this manifest, its sources and the existing temporary results.")
                    .font(.caption)
                    .fpSecondaryText()
            }
            if let diagnostic = session.diagnostic {
                DisclosureGroup("Helper diagnostics") {
                    ScrollView {
                        Text(diagnostic)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 140)
                }
                .font(.caption)
            }
        }
    }

    private func progressLabel(_ report: HostBatchProtocol) -> String {
        if session.cancelRequested { return "Cancellation requested…" }
        if report.terminal != nil { return "Checking helper exit…" }
        guard let progress = report.progress else { return "Preparing host batch…" }
        let stage: String
        switch progress.phase {
        case "preflight-source", "source-pin": stage = "Checking source"
        case "preflight-resume", "namespace", "resume-proof": stage = "Verifying temporary results"
        case "space", "reserve": stage = "Preparing output"
        case "codec": stage = "Applying grain"
        case "readback", "receipt", "commit": stage = "Checking and publishing output"
        default: stage = "Preparing job"
        }
        return "\(stage) · JPEG \(progress.job) of \(report.jobCount)"
    }
}
