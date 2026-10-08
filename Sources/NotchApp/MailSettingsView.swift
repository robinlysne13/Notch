import SwiftUI

/// Account setup, in a normal window rather than in the notch — it needs the keyboard, and the
/// notch collapses the moment the pointer leaves it.
struct MailSettingsView: View {
    @ObservedObject var accounts: MailAccountStore
    @ObservedObject var watcher: CodeWatcher

    @State private var provider: MailProvider = .icloud
    @State private var address = ""
    @State private var password = ""
    @State private var isVerifying = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Mail Accounts")
                .font(.headline)

            if accounts.accounts.isEmpty {
                Text("No mailboxes connected yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(accounts.accounts) { account in
                        accountRow(account)
                        if account.id != accounts.accounts.last?.id { Divider() }
                    }
                }
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor))
                )
            }

            Divider()
            addForm
            Spacer(minLength: 0)
            footer
        }
        .padding(18)
        .frame(width: 420)
    }

    private func accountRow(_ account: MailAccount) -> some View {
        HStack(spacing: 8) {
            Image(systemName: accounts.isUsable(account)
                  ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(accounts.isUsable(account) ? .green : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(account.address).font(.callout)
                Text(account.provider.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Remove") { accounts.remove(account) }
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Provider", selection: $provider) {
                ForEach(MailProvider.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            TextField("you@\(provider == .icloud ? "icloud.com" : "gmail.com")", text: $address)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)

            SecureField("App-specific password", text: $password)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 10) {
                Button(isVerifying ? "Checking…" : "Add Account") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isVerifying || address.isEmpty || password.isEmpty)
                if isVerifying {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Link("Get an app password", destination: URL(string: provider.appPasswordURL)!)
                    .font(.caption)
            }

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Copy each new code to the clipboard automatically", isOn: $watcher.autoCopy)
                .font(.caption)
            Text("""
            Both providers reject your normal account password over IMAP when two-factor \
            authentication is on, so an app-specific password is required. It's stored in your \
            Keychain, and only the inbox is read — nothing is sent anywhere.
            """)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Verifies the credentials before saving, so a typo surfaces here instead of as silence.
    private func add() {
        let provider = provider
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        // App passwords are usually shown in groups; both providers accept them without the spaces.
        let password = password.replacingOccurrences(of: " ", with: "")
        error = nil
        isVerifying = true

        Task {
            let failure = await Task.detached(priority: .userInitiated) {
                IMAPMailReader.verify(provider: provider, address: address, password: password)
            }.value

            isVerifying = false
            if let failure {
                error = failure
                return
            }
            accounts.add(provider: provider, address: address, password: password)
            self.address = ""
            self.password = ""
            watcher.beginHotWindow()
        }
    }
}
