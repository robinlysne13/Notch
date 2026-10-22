import SwiftUI

/// The Focus tab — the dashboard's Focus page in the room there is above the keyboard.
///
/// The web page can afford a 260pt clock face and a thirty-day chart side by side; the notch has
/// roughly 404×114. So the same things are here in a different arrangement: the face on the left
/// at the size it fits, what the clock is for and how to work it on the right, and the day's total
/// against the goal along the bottom with the thirty days as a sparkline beside it.
///
/// What isn't here is anything that belongs to a keyboard and a full window — the lengths other
/// than the presets, the goal itself, the session list. Those stay on the Focus page, which is a
/// click away in the settings window.
struct FocusView: View {
    @ObservedObject var model: FocusModel
    /// Opens the separate settings window. Signing in can't happen in the notch: the panel
    /// collapses as soon as the pointer leaves the chrome, which would throw away a half-typed
    /// password.
    let openSettings: () -> Void

    /// The label as the field has it. See `label`.
    @State private var typed = ""

    private static let green = Color(red: 0.09, green: 0.64, blue: 0.29)

    var body: some View {
        Group {
            if model.isConfigured {
                clock
            } else {
                setupPrompt
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Not connected yet

    private var setupPrompt: some View {
        VStack(spacing: 8) {
            Image(systemName: "timer")
                .font(.system(size: 20))
                .foregroundStyle(.white.opacity(0.5))
            Text("Sign in to your dashboard to time a stretch of focus here")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
            Button("Connect the Dashboard", action: openSettings)
                .buttonStyle(NotchButtonStyle(prominent: true))
        }
        .padding(.horizontal, 20)
        .frame(maxHeight: .infinity)
    }

    // MARK: The clock

    private var clock: some View {
        // One tick drives the face, the ring and the ✓ Done label. It runs whether or not the
        // clock does, because the panel is only rendered while someone is looking at it.
        TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
            let now = timeline.date
            VStack(spacing: 8) {
                HStack(alignment: .center, spacing: 14) {
                    face(at: now)
                    controls(at: now)
                }
                footer
            }
        }
    }

    private func face(at now: Date) -> some View {
        let clock = model.clock
        let done = clock.isDone(at: now) && !clock.running
        let ring: Color = clock.dir == .down
            ? (done ? Self.green : .white)
            : .white.opacity(0.5)
        // A thin line kept inside the frame reads as a sharp edge; a thick one centred on the
        // frame's edge spills half a stroke over it and goes soft.
        let line: CGFloat = 4

        return ZStack {
            Circle()
                .inset(by: line / 2)
                .stroke(Color.white.opacity(0.16), lineWidth: line)
            // Nothing left to draw is drawn as nothing: a rounded cap on a zero-length arc
            // leaves a stub floating at twelve o'clock.
            let fraction = clock.fraction(at: now)
            if fraction > 0.002 {
                Circle()
                    .inset(by: line / 2)
                    .trim(from: 0, to: fraction)
                    .stroke(ring, style: StrokeStyle(lineWidth: line, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 1) {
                Text(FocusMaths.mmss(clock.shown(at: now)))
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Text(status(at: now))
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(done ? Self.green : .white.opacity(0.45))
                    .lineLimit(1)
            }
        }
        .frame(width: 84, height: 84)
    }

    private func status(at now: Date) -> String {
        let clock = model.clock
        if clock.isDone(at: now) && !clock.running { return "Kept" }
        if clock.running { return clock.dir == .down ? "Counting down" : "Counting up" }
        let started = clock.dir == .down ? clock.shown(at: now) < clock.length : clock.shown(at: now) > 0
        return started ? "Paused" : "Ready"
    }

    private func controls(at now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            label
            buttons(at: now)
            if model.clock.dir == .down { presets }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What the stretch is for. Typed here rather than picked, because the notch is already open
    /// and the pointer is already on it — the panel holds as long as the pointer rests on the
    /// chrome, so there is time to type.
    ///
    /// The field holds its own text and hands it to the model after, rather than binding
    /// straight through it. A binding whose setter republishes the value it was just given feeds
    /// the field back its own keystrokes a beat late, and fast typing comes out transposed.
    private var label: some View {
        TextField(
            "",
            text: $typed,
            prompt: Text("What are you focusing on?")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.35))
        )
        .onChange(of: typed) { _, now in model.setLabel(now) }
        .onAppear { typed = model.clock.label }
        .textFieldStyle(.plain)
        .font(.system(size: 11))
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.09))
        )
    }

    private func buttons(at now: Date) -> some View {
        let clock = model.clock
        let minutes = Int(model.keepable(at: now) / 60)
        let shown = clock.shown(at: now)
        let resumable = clock.dir == .down ? (shown < clock.length && shown > 0) : shown > 0

        return HStack(spacing: 6) {
            Button { model.reset() } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(NotchButtonStyle())
            .help("Back to the top, keeping nothing")

            Button { model.toggle() } label: {
                Text(clock.running ? "Pause" : resumable ? "Resume" : "Start")
                    .frame(width: 54)
            }
            .buttonStyle(NotchButtonStyle(prominent: true, outlined: true))

            Button { model.finish() } label: {
                Text("✓ Done")
            }
            .buttonStyle(NotchButtonStyle())
            .disabled(minutes < 1)
            .help(minutes >= 1
                  ? "Stop and keep \(FocusMaths.hm(minutes))"
                  : "A stretch is kept once it reaches a minute")

            Spacer(minLength: 0)
            direction
        }
    }

    /// Which way it runs — a countdown for a stretch whose length you have decided, a stopwatch
    /// for the one you can't call in advance.
    private var direction: some View {
        HStack(spacing: 2) {
            ForEach([FocusClock.Direction.down, .up], id: \.rawValue) { dir in
                let on = model.clock.dir == dir
                Button { model.setDirection(dir) } label: {
                    Image(systemName: dir == .down ? "arrow.down.to.line" : "arrow.up.to.line")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(on ? .white : .white.opacity(0.4))
                        .frame(width: 20, height: 18)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.white.opacity(on ? 0.18 : 0.0))
                        )
                }
                .buttonStyle(.plain)
                .help(dir == .down
                      ? "Count down a stretch of a length you decide"
                      : "Count up — stop it when you're done")
            }
        }
    }

    /// The common lengths, one click each. Any other length is set on the Focus page — a field
    /// here would want the keyboard for the sake of a number you rarely change.
    private var presets: some View {
        HStack(spacing: 4) {
            ForEach(FocusClock.presets, id: \.self) { minutes in
                let on = Int(model.clock.length / 60) == minutes
                Button { model.setLength(minutes: minutes) } label: {
                    Text("\(minutes)m")
                        .font(.system(size: 9, weight: on ? .semibold : .medium))
                        .foregroundStyle(on ? .white : .white.opacity(0.45))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(on ? Color.black : Color.white.opacity(0.06))
                        )
                        .overlay {
                            if on { Capsule().strokeBorder(.white, lineWidth: 1) }
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: What it has added up to

    private var footer: some View {
        HStack(spacing: 8) {
            Text(todayLabel)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)

            if model.streak >= 2 {
                Text("🔥 \(model.streak)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .help("\(model.streak) days running at or over your goal")
            }

            Spacer(minLength: 0)
            sparkline
            syncDot
        }
        .frame(height: 16)
    }

    private var todayLabel: String {
        let today = FocusMaths.hm(model.todayMinutes)
        guard model.goal > 0 else { return "\(today) focused today" }
        return "\(today) of \(FocusMaths.hm(model.goal)) today"
    }

    /// The thirty days behind you, each bar against the goal. Days you did nothing on are present
    /// as empty columns — leaving them out would space the rest evenly and quietly turn a
    /// fortnight off into a flat week.
    private var sparkline: some View {
        let days = model.recentDays
        let ceiling = max(model.goal, days.map(\.minutes).max() ?? 0, 1)
        return HStack(alignment: .bottom, spacing: 1) {
            ForEach(days, id: \.key) { day in
                let height = max(1, CGFloat(day.minutes) / CGFloat(ceiling) * 14)
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(day.minutes >= model.goal && model.goal > 0
                          ? Color.white.opacity(0.9)
                          : Color.white.opacity(day.minutes > 0 ? 0.35 : 0.12))
                    .frame(width: 3, height: height)
            }
        }
        .frame(height: 14, alignment: .bottom)
        .help("The last 30 days")
    }

    /// Whether the dashboard has everything. Silent when it has — the only thing worth a mark is
    /// minutes that haven't travelled yet.
    @ViewBuilder
    private var syncDot: some View {
        if !model.pending.isEmpty {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 8))
                .foregroundStyle(.orange.opacity(0.8))
                .help(pendingHelp)
        } else if let error = model.lastError {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 8))
                .foregroundStyle(.orange.opacity(0.8))
                .help(error)
        } else if model.isSyncing {
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.5)
                .frame(width: 10, height: 10)
                .tint(.white.opacity(0.5))
        }
    }

    private var pendingHelp: String {
        let count = model.pending.count
        let stretch = count == 1 ? "stretch" : "stretches"
        let why = model.lastError.map { " — \($0)" } ?? ""
        return "\(count) \(stretch) still to reach the dashboard\(why)"
    }
}

/// Small translucent control that reads correctly on the notch's solid black.
struct NotchButtonStyle: ButtonStyle {
    var prominent = false
    /// A prominent button can take a solid colour, so the one thing you came to press stands out.
    var tint: Color?
    /// Black with a white rim and white text, for a button that should stand out without colour.
    var outlined = false

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let fill = outlined ? Color.black
            : tint.map { $0.opacity(configuration.isPressed ? 0.7 : 1) }
            ?? Color.white.opacity(prominent ? 0.22 : 0.12)
        return configuration.label
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white.opacity(
                !isEnabled ? 0.3 : configuration.isPressed ? 0.6 : outlined ? 1 : 0.9
            ))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(isEnabled ? fill : Color.white.opacity(0.06)))
            .overlay {
                if outlined {
                    Capsule().strokeBorder(.white.opacity(configuration.isPressed ? 0.6 : 1), lineWidth: 1)
                }
            }
    }
}
