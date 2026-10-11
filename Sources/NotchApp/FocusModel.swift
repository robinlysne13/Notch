import AppKit
import Combine
import Foundation

/// The notch's end of the Focus page: a clock you point at one thing, and the hours it has added
/// up to.
///
/// The clock is this Mac's own — it is not mirrored anywhere, so nothing ticks on the phone
/// because the laptop is working. What travels is the finished stretch: each one is appended to
/// the dashboard's one list of sessions (`ld.focus.sessions`), which is the same list the
/// Pomodoro blocks on the Routines page write to, so "how long have I focused today" has a single
/// answer wherever it's asked.
@MainActor
final class FocusModel: ObservableObject {
    @Published private(set) var clock: FocusClock
    /// Every session the dashboard knows about, as of the last pull, trimmed to the stretch the
    /// notch can actually show.
    @Published private(set) var sessions: [FocusSession] = []
    @Published private(set) var settings: FocusSettings = .defaults
    /// Stretches finished here that the dashboard hasn't taken yet. They still count towards
    /// today's total — the minutes were focused whether or not the network agreed.
    @Published private(set) var pending: [FocusSession] = []

    @Published private(set) var isSyncing = false
    @Published private(set) var lastPull: Date?
    @Published private(set) var lastError: String?
    /// Set when a countdown rings out while the notch is shut, so the collapsed chrome can say so.
    @Published var hasUnseenFinish = false

    /// Called on the main actor when a countdown reaches zero.
    var onRingOut: ((FocusSession) -> Void)?

    private static let clockKey = "focus.clock"
    private static let pendingKey = "focus.pendingSessions"
    private static let cacheKey = "focus.sessionsCache"
    private static let sessionsRow = "ld.focus.sessions"
    private static let settingsRow = "ld.focus.settings"
    /// The dashboard shows thirty days; keeping a little more than that locally means the
    /// sparkline is right the moment the panel opens, before any pull has landed.
    private static let cacheDays = 45
    /// How often to ask the dashboard for the list again. The web app polls at the same cadence.
    private static let pullInterval: TimeInterval = 180
    /// A stretch is only worth keeping once it reaches a minute — the same floor the web uses.
    private static let keepFloor: TimeInterval = 60

    private let account: DashboardAccount
    private let store: DashboardStore
    private var tick: Timer?
    private var pullTimer: Timer?
    /// The anchor already rung for, so one ending is never counted twice.
    private var rang: Date?
    private var pushTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var signInWatch: AnyCancellable?

    init(account: DashboardAccount) {
        self.account = account
        self.store = DashboardStore(account: account)
        self.clock = Self.readClock()
        self.pending = Self.read([FocusSession].self, forKey: Self.pendingKey) ?? []
        self.sessions = Self.read([FocusSession].self, forKey: Self.cacheKey) ?? []
    }

    // MARK: Lifecycle

    func start() {
        // A clock that was running when the app was last quit is still running: it was anchored
        // to a moment, not to a tick, so it simply catches up.
        resyncTick()
        pullTimer = Timer.scheduledTimer(withTimeInterval: Self.pullInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // Nothing can be pulled or pushed until there's a session; once there is, do both.
        signInWatch = account.$isSignedIn
            .removeDuplicates()
            .sink { [weak self] signedIn in
                guard signedIn else { return }
                MainActor.assumeIsolated {
                    self?.refresh()
                    self?.push()
                }
            }
    }

    func stop() {
        tick?.invalidate()
        tick = nil
        pullTimer?.invalidate()
        pullTimer = nil
        signInWatch = nil
        retryTask?.cancel()
        // The clock is already on disk; what might not be is a stretch just finished.
        pushTask?.cancel()
    }

    /// The user has looked at the Focus tab: the finish has been seen, and the totals are worth
    /// freshening while they're being read.
    func enterTab() {
        hasUnseenFinish = false
        if lastPull == nil || Date().timeIntervalSince(lastPull ?? .distantPast) > 20 {
            refresh()
        }
    }

    // MARK: The clock

    var isRunning: Bool { clock.running }

    func shown(at now: Date = Date()) -> TimeInterval { clock.shown(at: now) }

    func toggle() {
        clock.running ? pause() : begin()
    }

    func begin() {
        apply(clock.started(at: Date()))
    }

    func pause() {
        apply(clock.paused(at: Date()))
    }

    func reset() {
        apply(clock.reset())
    }

    func setDirection(_ dir: FocusClock.Direction) {
        apply(clock.switched(to: dir))
    }

    func setLength(minutes: Int) {
        apply(clock.withLength(minutes: minutes))
    }

    func setLabel(_ label: String) {
        var next = clock
        next.label = label
        apply(next, retick: false)
    }

    /// A countdown that has rung has already been kept, and the face still reads zero so you can
    /// see that it has. There is nothing left to keep until the clock moves again — without this,
    /// ✓ Done sitting there live would write the same stretch down a second time.
    func keepable(at now: Date = Date()) -> TimeInterval {
        let kept = clock.isDone(at: now) && !clock.running
        return kept ? 0 : max(0, clock.elapsed(at: now))
    }

    /// Stop here and keep the minutes — what finishes a count-up stretch, and a way out of a
    /// countdown you finished early.
    func finish() {
        let now = Date()
        let keep = keepable(at: now)
        let label = clock.label
        // Stopped first, then kept — see `ringOut`.
        apply(clock.reset())
        log(seconds: keep, endedAt: now, label: label)
        if settings.sound, keep >= Self.keepFloor { chime() }
    }

    private func apply(_ next: FocusClock, retick: Bool = true) {
        clock = next
        Self.write(next, forKey: Self.clockKey)
        if retick { resyncTick() }
    }

    /// The tick runs only while something is actually moving — and it is the tick that notices a
    /// countdown has run out, not a watcher on the clock: the clock doesn't change as the seconds
    /// pass, so nothing else would. One that ran out while the Mac was asleep is caught on the
    /// way back.
    private func resyncTick() {
        tick?.invalidate()
        tick = nil
        guard clock.running else { return }
        if clock.isDone(at: Date()) {
            ringOut()
            return
        }
        tick = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.clock.isDone(at: Date()) else { return }
                self.ringOut()
            }
        }
    }

    /// The countdown reaching zero: the stretch is kept, and the clock stops.
    private func ringOut() {
        guard let anchor = clock.anchor, rang != anchor else { return }
        rang = anchor

        let length = clock.length
        let label = clock.label

        // Stop the clock on disk *before* keeping the minutes. The other order leaves a window
        // where a quit would lose the stopping but not the keeping: the next launch would find a
        // clock still running past its anchor, ring it out again, and file the stretch twice.
        var next = clock
        next.running = false
        next.anchor = nil
        next.held = 0
        apply(next, retick: false)
        tick?.invalidate()
        tick = nil

        let session = log(seconds: length, endedAt: anchor, label: label)

        if settings.sound { chime() }
        hasUnseenFinish = true
        if let session { onRingOut?(session) }
    }

    /// Three soft notes — noticeable, not an alarm.
    private func chime() {
        NSSound(named: "Glass")?.play()
    }

    // MARK: Keeping the minutes

    @discardableResult
    private func log(seconds: TimeInterval, endedAt: Date, label: String) -> FocusSession? {
        let minutes = Int((seconds / 60).rounded())
        guard minutes >= 1 else { return nil }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let session = FocusSession(
            label: trimmed.isEmpty ? "Unlabelled" : trimmed,
            minutes: minutes,
            endedAt: endedAt
        )
        pending.append(session)
        Self.write(pending, forKey: Self.pendingKey)
        push()
        return session
    }

    // MARK: What it has added up to

    /// Today's minutes, counting what hasn't reached the dashboard yet.
    var todayMinutes: Int {
        let today = FocusSession.day(of: Date())
        return FocusMaths.minutes(sessions + pending, on: today)
    }

    var goal: Int { settings.goal }

    /// The thirty days behind you, oldest first.
    var recentDays: [FocusDay] {
        FocusMaths.lastDays(sessions + pending, 30)
    }

    var streak: Int {
        FocusMaths.goalStreak(recentDays, goal: goal)
    }

    var isConfigured: Bool { account.isSignedIn }

    // MARK: Talking to the dashboard

    func refresh() {
        guard account.isSignedIn, !isSyncing else { return }
        Task { await pull() }
    }

    private func pull() async {
        isSyncing = true
        defer { isSyncing = false }
        do {
            if let row = try await store.read(Self.sessionsRow), !row.isDeleted,
               let data = row.value.data(using: .utf8) {
                let decoded = (try? JSONDecoder().decode([FocusSession].self, from: data)) ?? []
                adopt(decoded)
            }
            if let row = try await store.read(Self.settingsRow), !row.isDeleted,
               let data = row.value.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(FocusSettings.self, from: data) {
                settings = decoded
            }
            lastPull = Date()
            lastError = nil
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Take the dashboard's list as the truth, and drop from `pending` anything it now holds —
    /// a stretch that reached the server during a push whose answer we never saw is already
    /// there, and leaving it queued would file it a second time.
    private func adopt(_ list: [FocusSession]) {
        let known = Set(list.map(\.id))
        if pending.contains(where: { known.contains($0.id) }) {
            pending.removeAll { known.contains($0.id) }
            Self.write(pending, forKey: Self.pendingKey)
        }
        sessions = Self.trimmed(list)
        Self.write(sessions, forKey: Self.cacheKey)
    }

    /// Only the recent stretch is worth keeping on this side: the notch shows thirty days, and
    /// the push always re-reads the server's whole list rather than sending this one back.
    private static func trimmed(_ list: [FocusSession]) -> [FocusSession] {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -cacheDays, to: Date()) else {
            return list
        }
        let key = FocusSession.day(of: cutoff)
        return list.filter { $0.date >= key }
    }

    func push() {
        guard account.isSignedIn, !pending.isEmpty, pushTask == nil else { return }
        pushTask = Task { [weak self] in
            await self?.append()
            self?.pushTask = nil
        }
    }

    /// Append what's queued to the dashboard's list. Read, add, compare-and-swap: on a miss the
    /// row moved under us, so read it again rather than pushing a list built on a stale one.
    private func append() async {
        let queued = pending
        guard !queued.isEmpty else { return }

        for _ in 0..<3 {
            do {
                let now = DashboardStore.now()
                guard let row = try await store.read(Self.sessionsRow) else {
                    // Nothing there yet — the first stretch this account has ever kept.
                    let body = try Self.encode(queued)
                    if try await store.insert(Self.sessionsRow, value: body, updatedAt: now) {
                        settle(queued)
                        return
                    }
                    continue // somebody created it first; read it and add to it
                }

                var list: [FocusSession] = []
                if !row.isDeleted, let data = row.value.data(using: .utf8) {
                    list = (try? JSONDecoder().decode([FocusSession].self, from: data)) ?? []
                }
                let known = Set(list.map(\.id))
                let adding = queued.filter { !known.contains($0.id) }
                guard !adding.isEmpty else {
                    settle(queued) // already landed — nothing to do but stop queueing it
                    return
                }
                list.append(contentsOf: adding)

                let landed = try await store.update(
                    Self.sessionsRow,
                    value: try Self.encode(list),
                    updatedAt: now,
                    ifUpdatedAt: row.updatedAt
                )
                if landed {
                    adopt(list)
                    settle(queued)
                    lastError = nil
                    return
                }
            } catch {
                lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                retryLater()
                return
            }
        }
        // The row is moving under us faster than we can read it. The minutes are safe on disk;
        // try again shortly.
        lastError = DashboardError.contended.errorDescription
        retryLater()
    }

    /// These stretches are the dashboard's problem now. Anything finished while the push was in
    /// flight stays queued.
    private func settle(_ pushed: [FocusSession]) {
        let done = Set(pushed.map(\.id))
        pending.removeAll { done.contains($0.id) }
        Self.write(pending, forKey: Self.pendingKey)
    }

    private func retryLater() {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            self?.push()
        }
    }

    private static func encode(_ sessions: [FocusSession]) throws -> String {
        let data = try JSONEncoder().encode(sessions)
        guard let text = String(data: data, encoding: .utf8) else {
            throw DashboardError.requestFailed("could not encode the sessions")
        }
        return text
    }

    // MARK: Disk

    private static func readClock() -> FocusClock {
        // A clock written by an older build still has to run, so a value that won't decode is
        // simply a fresh clock rather than a crash.
        read(FocusClock.self, forKey: clockKey) ?? FocusClock()
    }

    private static func read<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func write<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
