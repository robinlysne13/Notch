import Foundation

struct MailMessage {
    let uid: Int
    let from: String
    let subject: String
    /// Best-effort plain text of the message body, HTML stripped and transfer-encoding decoded.
    let body: String
}

/// Reads recent INBOX messages over IMAPS by driving `/usr/bin/curl`, which ships with macOS and
/// speaks `imaps` natively. That keeps the package dependency-free and avoids hand-rolling TLS and
/// IMAP literal parsing — the same reasoning that has `MediaController` shell out to `osascript`.
enum IMAPMailReader {
    enum Failure: Error, LocalizedError {
        case launchFailed
        case authenticationFailed
        case connectionFailed(String)

        var errorDescription: String? {
            switch self {
            case .launchFailed:
                return "Couldn't run curl."
            case .authenticationFailed:
                return "Sign-in was rejected. Use an app-specific password, not your account password."
            case .connectionFailed(let detail):
                return detail.isEmpty ? "Couldn't reach the mail server." : detail
            }
        }
    }

    /// UIDs in INBOX from the last day or two, oldest first. IMAP's `SINCE` is date-granular, so
    /// the window starts yesterday — starting it today would drop a code that arrived just before
    /// midnight. The caller narrows this to UIDs above the last one it saw anyway.
    static func recentUIDs(account: MailAccount, password: String) throws -> [Int] {
        let output = try run(
            account: account,
            password: password,
            url: "imaps://\(account.provider.host)/INBOX",
            request: "UID SEARCH SINCE \(imapDate(Date().addingTimeInterval(-86_400)))"
        )
        // Response line looks like: * SEARCH 4201 4202 4203
        guard let line = output
            .components(separatedBy: .newlines)
            .first(where: { $0.uppercased().contains("SEARCH") })
        else { return [] }
        return line
            .components(separatedBy: .whitespaces)
            .compactMap(Int.init)
            .sorted()
    }

    static func message(uid: Int, account: MailAccount, password: String) throws -> MailMessage? {
        let raw = try run(
            account: account,
            password: password,
            url: "imaps://\(account.provider.host)/INBOX;UID=\(uid)",
            request: nil
        )
        guard !raw.isEmpty else { return nil }
        return MIME.parse(raw: raw, uid: uid)
    }

    /// Round-trips a login so the settings UI can confirm credentials the moment they're entered,
    /// rather than leaving the user to guess why no codes ever appear.
    static func verify(provider: MailProvider, address: String, password: String) -> String? {
        let probe = MailAccount(provider: provider, address: address)
        do {
            _ = try run(
                account: probe,
                password: password,
                url: "imaps://\(provider.host)/INBOX",
                request: "NOOP"
            )
            return nil
        } catch {
            return (error as? Failure)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: curl

    private static func run(
        account: MailAccount, password: String, url: String, request: String?
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        // `-K -` reads options from stdin, which keeps the password out of the argument list where
        // any other process could read it out of `ps`.
        process.arguments = ["-K", "-"]

        var config = """
        url = "\(escape(url))"
        user = "\(escape(account.address)):\(escape(password))"
        silent
        show-error
        max-time = 25
        """
        if let request {
            config += "\nrequest = \"\(escape(request))\""
        }

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw Failure.launchFailed
        }
        inPipe.fileHandleForWriting.write(Data((config + "\n").utf8))
        inPipe.fileHandleForWriting.closeFile()

        // Read both pipes before waiting: a message larger than the pipe buffer would otherwise
        // block curl on write while we block on exit.
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let detail = String(decoding: errData).trimmingCharacters(in: .whitespacesAndNewlines)
            // curl reports a rejected IMAP login as exit 67 (FTP_WEIRD_PASS_REPLY) or as a login
            // denial in stderr, depending on where in the handshake it gave up.
            if process.terminationStatus == 67 || detail.lowercased().contains("login denied")
                || detail.lowercased().contains("authenticationfailed") {
                throw Failure.authenticationFailed
            }
            throw Failure.connectionFailed(detail)
        }
        return String(decoding: outData)
    }

    /// curl config values are quoted, so backslashes and quotes inside them need escaping.
    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static let imapDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        // IMAP dates are always English-month, regardless of the user's locale.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd-MMM-yyyy"
        return formatter
    }()

    private static func imapDate(_ date: Date) -> String {
        imapDateFormatter.string(from: date)
    }
}

extension String {
    /// Mail is frequently not valid UTF-8; fall back rather than dropping the message entirely.
    init(decoding data: Data) {
        self = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
    }
}
