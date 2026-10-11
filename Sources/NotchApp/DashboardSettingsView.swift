import SwiftUI

/// Dashboard sign-in, in a normal window rather than in the notch — it needs the keyboard, and
/// the notch collapses the moment the pointer leaves it.
struct DashboardSettingsView: View {
    @ObservedObject var account: DashboardAccount
    @ObservedObject var focus: FocusModel

    @State private var email = ""
    @State private var password = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Life Dashboard")
                .font(.headline)

            if account.isSignedIn {
                connected
            } else {
                Text("The same email and password you sign in to the dashboard with. Focus "
                     + "stretches timed at the notch are added to the one list of sessions, so "
                     + "the Focus page counts them alongside the Pomodoro blocks.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                signInForm
            }

            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(width: 420)
    }

    // MARK: Signed in

    private var connected: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.email.isEmpty ? "Connected" : account.email)
                        .font(.callout)
                    Text(syncLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Sign Out") { account.signOut() }
                    .controlSize(.small)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor))
            )

            HStack(spacing: 8) {
                Button("Check Now") { focus.refresh() }
                    .controlSize(.small)
                    .disabled(focus.isSyncing)
                if !focus.pending.isEmpty {
                    Text("\(focus.pending.count) still to send")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Text("Your daily goal and the block lengths are read from the dashboard — set them "
                 + "on the Focus page and the notch follows.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let error = focus.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var syncLabel: String {
        guard let last = focus.lastPull else { return "Not synced yet" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "Synced \(formatter.localizedString(for: last, relativeTo: Date()))"
    }

    // MARK: Signing in

    private var signInForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Form {
                TextField("Email", text: $email)
                    .textContentType(.username)
                SecureField("Password", text: $password)
                    .textContentType(.password)
            }
            .formStyle(.grouped)
            .padding(.horizontal, -18)

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(account.isSigningIn ? "Signing In…" : "Sign In") { signIn() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(account.isSigningIn || email.isEmpty || password.isEmpty)
            }
        }
    }

    private func signIn() {
        error = nil
        Task {
            do {
                try await account.signIn(email: email, password: password)
                // The password has done its job; nothing keeps it after this.
                password = ""
                focus.refresh()
                focus.push()
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }
}
