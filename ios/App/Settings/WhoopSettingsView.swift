import AuthenticationServices
import DesignSystem
import Networking
import SwiftUI

struct WhoopSettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.webAuthenticationSession) private var webAuthentication
    @State private var status: NudgeAPI.WhoopStatus?
    @State private var working = false
    @State private var error: String?

    var body: some View {
        SettingsPage(title: "WHOOP") {
            Text("Give your downtime some space.").font(.title2.weight(.semibold))
            Text("Use your recent sleep pattern to avoid nudges during your usual sleep hours, and pause nudges for 30 minutes after a recorded workout.")
                .foregroundStyle(Palette.inkSecondary)
            Text("WHOOP records can arrive late. This estimates good times to reach you; it doesn't detect live sleep or exercise.")
                .font(.footnote).foregroundStyle(Palette.inkSecondary)
            if let status, status.connected {
                CardList {
                    ToggleRow(title: "Protect my sleep window", detail: "Estimated from at least three nights in the past week.",
                        isOn: Binding(get: { status.sleepEnabled }, set: { value in
                            run { self.status = try await app.api.updateWhoop(sleep: value, workout: status.workoutEnabled) }
                        }))
                    RowDivider()
                    ToggleRow(title: "Time after workouts", detail: "A 30-minute buffer after the workout ends, when the record is available.",
                        isOn: Binding(get: { status.workoutEnabled }, set: { value in
                            run { self.status = try await app.api.updateWhoop(sleep: status.sleepEnabled, workout: value) }
                        }))
                }.disabled(working)
                if let start = status.sleepStart, let end = status.sleepEnd {
                    Text("Estimated sleep window: \(start)–\(end)").font(.subheadline)
                } else { Text("Waiting for enough recent sleep records to estimate a window.").font(.footnote) }
                if let synced = status.syncedAt {
                    Text("Last synced \(synced.formatted(.relative(presentation: .named)))").font(.footnote)
                }
                if status.syncFailed {
                    Text("WHOOP couldn't sync. Its estimates won't block nudges until syncing resumes. Reconnect if this continues.")
                        .font(.footnote).foregroundStyle(Palette.roseStrong)
                }
                NudgeButton("Disconnect WHOOP", kind: .secondary, isLoading: working) {
                    run { try await app.api.disconnectWhoop(); self.status = try await app.api.whoopStatus() }
                }
            } else {
                NudgeButton("Connect WHOOP", kind: .primary, isLoading: working) { connect() }
            }
            if let error { Text(error).font(.footnote).foregroundStyle(Palette.roseStrong) }
            Text("Optional. Your friends never see your WHOOP records. Disconnecting removes this integration's saved data from Nudge.")
                .font(.footnote).foregroundStyle(Palette.inkSecondary)
        }
        .task { run { status = try await app.api.whoopStatus() } }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !working else { return }
        working = true
        error = nil
        Task { @MainActor in
            defer { working = false }
            do { try await action() }
            catch { self.error = "Couldn't complete the WHOOP connection. Try again shortly." }
        }
    }

    private func connect() {
        run {
            let authorization = try await app.api.connectWhoop()
            let callback = try await webAuthentication.authenticate(using: authorization.url, callbackURLScheme: "app.nudge.whoop")
            let params = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard callback.host == "oauth", let code = params.first(where: { $0.name == "code" })?.value,
                  let state = params.first(where: { $0.name == "state" })?.value else { throw URLError(.userAuthenticationRequired) }
            status = try await app.api.finishWhoop(code: code, state: state)
        }
    }
}
