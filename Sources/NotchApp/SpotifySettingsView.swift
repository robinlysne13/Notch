import AppKit
import SwiftUI

/// Spotify sign-in, for the heart button on the Now Playing tab.
///
/// Liking a track writes to the account rather than to the local player, which is why this needs
/// a sign-in at all — AppleScript can drive Spotify but cannot touch the library.
struct SpotifySettingsView: View {
    @ObservedObject var auth: SpotifyAuth

    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Spotify")
                .font(.headline)

            if auth.isConnected {
                connected
            } else {
                setup
            }

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
            footer
        }
        .padding(18)
        .frame(width: 420)
    }

    private var connected: some View {
        HStack {
            Label("Signed in", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
            Spacer()
            Button("Disconnect") {
                auth.disconnect()
                error = nil
            }
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 10) {
            steps

            VStack(alignment: .leading, spacing: 4) {
                Text("Client ID").font(.caption).foregroundStyle(.secondary)
                TextField("", text: $auth.clientID)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            HStack {
                Button(auth.isConnecting ? "Waiting for Spotify…" : "Connect") {
                    connect()
                }
                .disabled(auth.clientID.trimmingCharacters(in: .whitespaces).isEmpty || auth.isConnecting)
                if auth.isConnecting {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 7) {
            step(1) {
                HStack(spacing: 4) {
                    Text("Create a free app at")
                    Link("developer.spotify.com", destination: URL(string: "https://developer.spotify.com/dashboard")!)
                        .font(.caption)
                }
            }
            step(2) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Set its Redirect URI to exactly:")
                    HStack(spacing: 6) {
                        Text(SpotifyAuth.redirectURI)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                            )
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(SpotifyAuth.redirectURI, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy")
                    }
                }
            }
            step(3) { Text("Paste the app's Client ID below and connect.") }
        }
        .font(.caption)
    }

    private func step<Content: View>(_ number: Int, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text("\(number).")
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .trailing)
            content()
        }
    }

    private var footer: some View {
        Text("""
        Sign-in uses PKCE, so there's no client secret to keep. Only the refresh token is saved, \
        in your Keychain, and the only permissions requested are reading and changing your Liked \
        Songs.
        """)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func connect() {
        error = nil
        Task {
            do {
                try await auth.connect()
            } catch is CancellationError {
                // Closing the browser tab is a normal way to back out.
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
