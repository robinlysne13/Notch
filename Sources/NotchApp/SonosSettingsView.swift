import SwiftUI

/// Sonos section of the settings window: a switch, and the groups the last scan found.
struct SonosSettingsView: View {
    @ObservedObject var sonos: SonosController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sonos")
                    .font(.headline)
                Spacer()
                Toggle("", isOn: $sonos.isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            if sonos.isEnabled {
                if sonos.groups.isEmpty {
                    Text(sonos.isScanning ? "Looking for speakers…" : "No speakers found yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(sonos.groups) { group in
                            HStack(spacing: 6) {
                                Image(systemName: "hifispeaker.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(group.label).font(.callout)
                                Spacer()
                                Text(group.coordinatorIP)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor))
                    )
                }

                HStack(spacing: 10) {
                    Button(sonos.isScanning ? "Scanning…" : "Scan Again") { sonos.scan() }
                        .disabled(sonos.isScanning)
                    if sonos.isScanning {
                        ProgressView().controlSize(.small)
                    }
                }

                if let message = sonos.scanMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text("""
            Shows music started from the Sonos app, which Spotify's own account can't see. Speakers \
            are found over the local network; nothing leaves it. Spotify Connect sessions on Sonos \
            come through the Spotify connection above instead.
            """)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
