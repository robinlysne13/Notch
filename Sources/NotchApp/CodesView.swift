import SwiftUI

struct CodesView: View {
    @ObservedObject var watcher: CodeWatcher
    @ObservedObject var accounts: MailAccountStore
    /// Opens the separate settings window. The form can't live in the notch: the panel collapses as
    /// soon as the pointer leaves the chrome, which would throw away a half-typed password.
    let openSettings: () -> Void

    var body: some View {
        Group {
            if !watcher.isConfigured {
                setupPrompt
            } else if let latest = watcher.latest {
                codeDisplay(latest)
            } else {
                waiting
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: States

    private var setupPrompt: some View {
        VStack(spacing: 8) {
            Image(systemName: "envelope.badge.shield.half.filled")
                .font(.system(size: 20))
                .foregroundStyle(.white.opacity(0.5))
            Text("Connect iCloud or Gmail to catch verification codes")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
            Button("Connect a Mailbox", action: openSettings)
                .buttonStyle(NotchButtonStyle(prominent: true))
        }
        .padding(.horizontal, 20)
    }

    private var waiting: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                if watcher.isChecking {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white.opacity(0.6))
                }
                Text(watcher.isChecking ? "Checking mail…" : "Waiting for a code")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
            if let error = watcher.lastError {
                Text(error)
                    .font(.system(size: 9))
                    .foregroundStyle(.orange.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 16)
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(checkedLabel)
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
            controls
        }
    }

    private func codeDisplay(_ code: DetectedCode) -> some View {
        VStack(spacing: 3) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text("\(code.sender) · \(Self.age(of: code.receivedAt))")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }

            Button {
                watcher.copy(code)
            } label: {
                HStack(spacing: 10) {
                    Text(Self.grouped(code.code))
                        .font(.system(size: 27, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                    Image(systemName: watcher.copiedCode == code.code
                          ? "checkmark.circle.fill" : "doc.on.doc")
                        .font(.system(size: 14))
                        .foregroundStyle(watcher.copiedCode == code.code
                                         ? .green : .white.opacity(0.5))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.10))
                )
            }
            .buttonStyle(.plain)
            .help("Click to copy")

            Text(watcher.copiedCode == code.code ? "Copied to clipboard" : code.subject)
                .font(.system(size: 9))
                .foregroundStyle(watcher.copiedCode == code.code
                                 ? .green.opacity(0.9) : .white.opacity(0.4))
                .lineLimit(1)
                .padding(.horizontal, 12)

            if watcher.codes.count > 1 {
                previousCodes
            }
            controls
        }
    }

    private var previousCodes: some View {
        HStack(spacing: 6) {
            ForEach(watcher.codes.dropFirst()) { code in
                Button {
                    watcher.copy(code)
                } label: {
                    Text(code.code)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help("\(code.sender) — click to copy")
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button("Check Now") { watcher.refreshNow() }
                .buttonStyle(NotchButtonStyle())
                .disabled(watcher.isChecking)
            Toggle("Auto-copy", isOn: $watcher.autoCopy)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.5))
                .help("Copy each new code to the clipboard as it arrives")
            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 10))
            }
            .buttonStyle(NotchButtonStyle())
            .help("Mail accounts")
        }
    }

    private var checkedLabel: String {
        guard let lastCheck = watcher.lastCheck else { return "Not checked yet" }
        return "Checked \(Self.age(of: lastCheck))"
    }

    // MARK: Formatting

    /// Six- and eight-digit codes are far easier to read back in pairs or triples.
    static func grouped(_ code: String) -> String {
        guard code.allSatisfy(\.isNumber) else { return code }
        let size: Int
        switch code.count {
        case 6: size = 3
        case 8: size = 4
        default: return code
        }
        return stride(from: 0, to: code.count, by: size)
            .map { offset in
                let start = code.index(code.startIndex, offsetBy: offset)
                let end = code.index(start, offsetBy: size, limitedBy: code.endIndex) ?? code.endIndex
                return String(code[start..<end])
            }
            .joined(separator: " ")
    }

    static func age(of date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
    }
}

/// Small translucent control that reads correctly on the notch's solid black.
struct NotchButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.6 : 0.9))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(Color.white.opacity(prominent ? 0.22 : 0.12))
            )
    }
}
