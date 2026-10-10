import SwiftUI

/// Spotify account section of the settings window. Connecting switches Now Playing from
/// scripting the local Spotify app to the Web API, which sees every Spotify Connect device.
struct SpotifySettingsView: View {
    @ObservedObject var auth: SpotifyAuth

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Spotify")
                .font(.headline)

            if auth.isConnected {
                connected
            } else {
                setup
            }

            if let error = auth.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var connected: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text("Connected").font(.callout)
                Text("Now Playing follows this account on any device, Sonos included.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Disconnect") { auth.disconnect() }
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Client ID from your Spotify app", text: $auth.clientID)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
                .disabled(auth.isConnecting)

            HStack(spacing: 10) {
                if auth.isConnecting {
                    Button("Cancel") { auth.cancelConnect() }
                    ProgressView().controlSize(.small)
                    Text("Finish signing in in your browser…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Connect Spotify") { auth.connect() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(auth.clientID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Spacer()
                Link("Developer Dashboard", destination: URL(string: "https://developer.spotify.com/dashboard")!)
                    .font(.caption)
            }

            Text("""
            Needed when Spotify plays somewhere other than this Mac, such as Sonos. Create an app \
            in the dashboard, add \(SpotifyAuth.registeredRedirectURI) as a Redirect URI, tick \
            Web API, and paste its Client ID here. Signing in rotates through your browser; only \
            a refresh token is kept, in your Keychain.
            """)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
