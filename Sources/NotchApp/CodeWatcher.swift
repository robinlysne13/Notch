import AppKit
import Combine

struct DetectedCode: Identifiable, Equatable {
    let id = UUID()
    let code: String
    let sender: String
    let subject: String
    let account: String
    let receivedAt: Date
}

/// Polls the configured mailboxes for new messages and surfaces any verification code it finds.
///
/// Polling rather than IMAP IDLE: a code is only interesting for a minute or two, and the user is
/// almost always staring at the notch waiting for it — so the cadence runs hot right after the
/// Codes tab is opened and backs off when nobody is looking, which is both simpler and cheaper
/// than holding two idle TLS connections open for the life of the app.
@MainActor
final class CodeWatcher: ObservableObject {
    @Published private(set) var codes: [DetectedCode] = []
    @Published private(set) var isChecking = false
    /// Set when a code arrives while the notch is closed, so the collapsed chrome can hint at it.
    @Published var hasUnseenCode = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastCheck: Date?
    @Published var copiedCode: String?

    @Published var autoCopy: Bool {
        didSet { UserDefaults.standard.set(autoCopy, forKey: Self.autoCopyKey) }
    }

    /// Called on the main actor when a code the user hasn't seen yet arrives.
    var onNewCode: ((DetectedCode) -> Void)?

    private static let autoCopyKey = "autoCopyVerificationCodes"
    private static let lastSeenKey = "lastSeenMailUIDs"
    /// How many codes to keep around; more than a couple is only ever useful for "the first one
    /// didn't work, resend" flows.
    private static let historyLimit = 4
    private static let idleInterval: TimeInterval = 30
    private static let hotInterval: TimeInterval = 5
    /// How long to stay on the fast cadence after the user shows interest.
    private static let hotWindow: TimeInterval = 120
    /// Never fetch more than this many new messages in one poll.
    private nonisolated static let fetchLimit = 5

    private let store: MailAccountStore
    private let queue = DispatchQueue(label: "notch.mail", qos: .userInitiated)
    private var timer: Timer?
    private var currentInterval: TimeInterval = 0
    private var hotUntil: Date?
    private var isPolling = false
    private var lastSeenUIDs: [String: Int]
    private var copyResetTask: Task<Void, Never>?

    init(store: MailAccountStore) {
        self.store = store
        self.autoCopy = UserDefaults.standard.bool(forKey: Self.autoCopyKey)
        self.lastSeenUIDs =
            UserDefaults.standard.dictionary(forKey: Self.lastSeenKey) as? [String: Int] ?? [:]
    }

    var isConfigured: Bool { !store.accounts.isEmpty }

    var latest: DetectedCode? { codes.first }

    // MARK: Scheduling

    func start() {
        schedule(interval: Self.idleInterval)
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        copyResetTask?.cancel()
    }

    /// Call when the user opens the Codes tab or adds an account: they are waiting for a code
    /// right now, so check immediately and keep checking often for a while.
    func beginHotWindow() {
        hotUntil = Date().addingTimeInterval(Self.hotWindow)
        schedule(interval: Self.hotInterval)
        poll()
    }

    func refreshNow() {
        beginHotWindow()
    }

    /// The user opened the Codes tab: they've now seen whatever was waiting, and they're very
    /// likely waiting on the next one.
    func enterTab() {
        hasUnseenCode = false
        beginHotWindow()
    }

    private func schedule(interval: TimeInterval) {
        guard interval != currentInterval else { return }
        currentInterval = interval
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        // .common so polling continues during menu tracking and drags.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func settleCadence() {
        if let hotUntil, Date() < hotUntil { return }
        hotUntil = nil
        schedule(interval: Self.idleInterval)
    }

    // MARK: Polling

    private func poll() {
        settleCadence()
        guard !isPolling, !store.accounts.isEmpty else { return }

        // Snapshot credentials on the main actor; the Keychain read and the network work then run
        // off the main thread.
        let jobs: [(account: MailAccount, password: String, lastSeen: Int?)] =
            store.accounts.compactMap { account in
                guard let password = store.password(for: account) else { return nil }
                return (account, password, lastSeenUIDs[account.id.uuidString])
            }
        guard !jobs.isEmpty else {
            lastError = "Add an app-specific password for your account."
            return
        }

        isPolling = true
        isChecking = true

        queue.async { [weak self] in
            var found: [DetectedCode] = []
            var newest: [String: Int] = [:]
            var failure: String?

            for job in jobs {
                do {
                    let uids = try IMAPMailReader.recentUIDs(
                        account: job.account, password: job.password
                    )
                    guard let highest = uids.last else { continue }
                    newest[job.account.id.uuidString] = highest

                    // First sight of this account: don't replay the whole day, but do look at the
                    // last couple of messages so a code that landed moments ago still shows up.
                    let unseen = job.lastSeen.map { seen in uids.filter { $0 > seen } }
                        ?? Array(uids.suffix(2))

                    for uid in unseen.suffix(Self.fetchLimit) {
                        guard let message = try IMAPMailReader.message(
                            uid: uid, account: job.account, password: job.password
                        ) else { continue }
                        guard let code = VerificationCodeFinder.find(
                            subject: message.subject, body: message.body
                        ) else { continue }
                        found.append(
                            DetectedCode(
                                code: code,
                                sender: Self.displayName(from: message.from),
                                subject: message.subject,
                                account: job.account.address,
                                receivedAt: Date()
                            )
                        )
                    }
                } catch {
                    // Report the failure but let the other account still be checked.
                    let description = (error as? IMAPMailReader.Failure)?.errorDescription
                        ?? error.localizedDescription
                    failure = "\(job.account.provider.label): \(description)"
                }
            }

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.finishPoll(found: found, newestUIDs: newest, failure: failure)
                }
            }
        }
    }

    private func finishPoll(found: [DetectedCode], newestUIDs: [String: Int], failure: String?) {
        isPolling = false
        isChecking = false
        lastCheck = Date()
        lastError = failure

        for (key, uid) in newestUIDs {
            lastSeenUIDs[key] = uid
        }
        if !newestUIDs.isEmpty {
            UserDefaults.standard.set(lastSeenUIDs, forKey: Self.lastSeenKey)
        }
        guard !found.isEmpty else { return }

        // Newest first, and never show the same code twice in a row (senders often send a
        // plain-text and an HTML copy, or resend the same code).
        for code in found where codes.first?.code != code.code {
            codes.insert(code, at: 0)
        }
        if codes.count > Self.historyLimit {
            codes.removeLast(codes.count - Self.historyLimit)
        }
        guard let newest = codes.first else { return }
        hasUnseenCode = true
        if autoCopy {
            copy(newest)
        }
        onNewCode?(newest)
    }

    // MARK: Actions

    func copy(_ code: DetectedCode) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(code.code, forType: .string)
        copiedCode = code.code

        copyResetTask?.cancel()
        copyResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.copiedCode = nil }
        }
    }

    func clear() {
        codes.removeAll()
        hasUnseenCode = false
        copiedCode = nil
    }

    /// "Apple <no-reply@apple.com>" reads better as just "Apple".
    private nonisolated static func displayName(from header: String) -> String {
        let header = header.trimmingCharacters(in: .whitespaces)
        if let bracket = header.firstIndex(of: "<") {
            let name = header[header.startIndex..<bracket]
                .trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            if !name.isEmpty { return name }
            let address = header[header.index(after: bracket)...].drop(while: { $0 == " " })
            return String(address.prefix { $0 != ">" })
        }
        return header
    }
}
