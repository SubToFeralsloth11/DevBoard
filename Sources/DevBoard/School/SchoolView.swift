import SwiftUI

/// School tab: your classes for the day and every DayMap task, synced automatically.
struct SchoolView: View {
    let model: AppModel

    var body: some View {
        let dm = model.daymap
        VStack(spacing: 12) {
            header(dm)
            if dm.status == .signedOut && dm.tasks.isEmpty && dm.lessons.isEmpty {
                signIn(dm)
            } else {
                HStack(alignment: .top, spacing: 14) {
                    DayColumn(model: model).frame(width: 340)
                    TaskColumn(model: model)
                }
            }
        }
        .onAppear {
            if Date.now.timeIntervalSince(dm.lastSync ?? .distantPast) > 300 { dm.syncNow() }
        }
    }

    private func header(_ dm: DayMapService) -> some View {
        HStack(spacing: 10) {
            switch dm.status {
            case .syncing: Chip(text: "Syncing", symbol: "arrow.triangle.2.circlepath", tint: DB.accent)
            case .ok: Chip(text: "Synced", symbol: "checkmark", tint: DB.mint)
            case .signedOut: Chip(text: "Signed out", symbol: "person.crop.circle.badge.exclamationmark", tint: DB.amber)
            case .failed: Chip(text: "Sync problem", symbol: "exclamationmark.triangle", tint: DB.rec)
            case .idle: Chip(text: "Waiting", symbol: "hourglass")
            }
            if let last = dm.lastSync {
                Text("Last checked \(Fmt.ago(last, now: dm.now))").font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary)
            }
            if let p = dm.lastProblem {
                Text(p).font(.system(size: 11, design: .rounded)).foregroundStyle(.tertiary).lineLimit(1).help(p)
            }
            Spacer()
            if dm.status == .signedOut {
                Button("Sign in to DayMap") { dm.signIn() }.controlSize(.small)
            }
            BubbleButton(symbol: "arrow.clockwise", help: "Sync now", size: 28) { dm.syncNow() }
                .disabled(dm.status == .syncing)
            BubbleButton(symbol: "safari", help: "Open DayMap in DevBoard", size: 28) { dm.openInDevBoard(dm.timetableURL) }
        }
    }

    private func signIn(_ dm: DayMapService) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "graduationcap.fill").font(.system(size: 40, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: [DB.violet, DB.accent], startPoint: .topLeading, endPoint: .bottomTrailing))
            Text("Connect DayMap").font(.system(size: 18, weight: .bold, design: .rounded))
            Text("Sign in once with your school account. DevBoard then checks DayMap every 20 minutes for\nyour classes and tasks, and reminds you in the island before things are due.")
                .font(.system(size: 12.5, design: .rounded)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Sign in to DayMap") { dm.signIn() }.buttonStyle(.borderedProminent).tint(DB.violet)
            Text(dm.base?.host() ?? "Set your DayMap address in Settings")
                .font(.system(size: 11, design: .rounded)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .card(radius: 22)
    }
}

private struct DayColumn: View {
    let model: AppModel

    /// Today, or the next day that has classes once today's are over.
    private var shown: (title: String, items: [SchoolLesson]) {
        let dm = model.daymap
        let cal = Calendar.current
        let byDay = Dictionary(grouping: dm.lessons.filter { $0.end > dm.now || cal.isDate($0.start, inSameDayAs: dm.now) }) { cal.startOfDay(for: $0.start) }
        let today = cal.startOfDay(for: dm.now)
        if let items = byDay[today], items.contains(where: { $0.end > dm.now }) { return ("Today", items) }
        guard let next = byDay.keys.filter({ $0 > today }).min() else { return ("Today", byDay[today] ?? []) }
        let label = cal.isDateInTomorrow(next) ? "Tomorrow" : next.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
        return (label, byDay[next] ?? [])
    }

    var body: some View {
        let s = shown
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: s.title, symbol: "calendar", trailing: s.items.isEmpty ? nil : "\(s.items.filter { $0.kind == "Lesson" }.count) classes")
            if s.items.isEmpty {
                Text("No classes found").font(.system(size: 12, design: .rounded)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(s.items) { LessonRow(lesson: $0, now: model.daymap.now) }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity)
        .card(radius: 22)
    }
}

private struct LessonRow: View {
    let lesson: SchoolLesson
    let now: Date

    var body: some View {
        let live = lesson.start <= now && now < lesson.end
        let past = lesson.end <= now
        HStack(spacing: 10) {
            VStack(alignment: .trailing, spacing: 0) {
                Text(DayMapService.time(lesson.start)).font(.system(size: 11.5, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(DayMapService.time(lesson.end)).font(.system(size: 10, design: .rounded)).foregroundStyle(.secondary).monospacedDigit()
            }
            .frame(width: 58, alignment: .trailing)
            Capsule().fill(live ? DB.mint : lesson.kind == "Lesson" ? DB.accent : DB.violet).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(lesson.subject).font(.system(size: 12.5, weight: .semibold, design: .rounded)).lineLimit(1)
                    if let room = lesson.room {
                        Text(room).font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(.white.opacity(0.1)))
                    }
                }
                if !lesson.notice.isEmpty {
                    Text(lesson.notice).font(.system(size: 10.5, design: .rounded)).foregroundStyle(DB.amber).lineLimit(2)
                } else if lesson.kind != "Lesson" {
                    Text(lesson.kind).font(.system(size: 10.5, design: .rounded)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if live { PulseDot(color: DB.mint, size: 6) }
        }
        .padding(.vertical, 7).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(live ? 0.1 : 0.03)))
        .opacity(past ? 0.45 : 1)
    }
}

private enum TaskGrouping: String, CaseIterable {
    case due = "By due date"
    case subject = "By subject"
}

/// Upcoming work first (today, next 7 days, next 2 weeks, later). Overdue and handed-in tasks
/// are folded away at the bottom: there's usually nothing left to do about them.
private struct TaskColumn: View {
    let model: AppModel
    @State private var showDone = false
    @State private var showOverdue = false
    @AppStorage("schoolTaskView") private var grouping: TaskGrouping = .due

    var body: some View {
        let dm = model.daymap
        let today = Calendar.current.startOfDay(for: dm.now)
        let open = dm.tasks.filter { !$0.submitted }
        let upcoming = open.filter { $0.due >= today }
        let overdue = open.filter { $0.due < today }.sorted { $0.due > $1.due }
        let week = upcoming.filter { $0.due < today.addingTimeInterval(8 * 86400) }
        let done = dm.tasks.filter(\.submitted).sorted { $0.due > $1.due }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SectionHeader(title: "Tasks", symbol: "checklist")
                Chip(text: "\(week.count) due in 7 days", tint: week.isEmpty ? .secondary : DB.amber)
                Chip(text: "\(upcoming.count) coming up", tint: DB.accent)
                Picker("", selection: $grouping) {
                    ForEach(TaskGrouping.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if upcoming.isEmpty && !dm.tasks.isEmpty {
                        Text("Nothing due coming up.")
                            .font(.system(size: 12, design: .rounded)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 20)
                    }
                    switch grouping {
                    case .subject: bySubject(upcoming, today: today)
                    case .due: byDue(upcoming, today: today)
                    }
                    folded("\(overdue.count) overdue", tint: DB.rec, items: overdue, open: $showOverdue)
                    folded("\(done.count) handed in", tint: DB.mint, items: done, open: $showDone)
                    if dm.tasks.isEmpty {
                        Text(dm.status == .syncing ? "Fetching your tasks…" : "No tasks found")
                            .font(.system(size: 12, design: .rounded)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.top, 40)
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .card(radius: 22)
    }

    @ViewBuilder
    private func folded(_ title: String, tint: Color, items: [SchoolTask], open: Binding<Bool>) -> some View {
        if !items.isEmpty {
            Button {
                withAnimation(DB.spring) { open.wrappedValue.toggle() }
            } label: {
                Label(title, systemImage: open.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
            if open.wrappedValue {
                ForEach(items) { TaskRow(model: model, task: $0, tint: tint, showSubject: true).opacity(0.75) }
            }
        }
    }

    /// One block per class, the class with the most urgent task first.
    @ViewBuilder
    private func bySubject(_ open: [SchoolTask], today: Date) -> some View {
        let groups = Dictionary(grouping: open, by: \.subject)
            .map { (code: $0.key, tasks: $0.value.sorted { $0.due < $1.due }) }
            .sorted { $0.tasks[0].due < $1.tasks[0].due }
        ForEach(groups, id: \.code) { g in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(SchoolNames.subject(g.code)).font(.system(size: 12, weight: .bold, design: .rounded))
                    Text(g.code).font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.tertiary)
                    Spacer()
                    Text("\(g.tasks.count)").font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
                ForEach(g.tasks) { TaskRow(model: model, task: $0, tint: urgency($0, today: today), showSubject: false) }
            }
        }
    }

    @ViewBuilder
    private func byDue(_ upcoming: [SchoolTask], today: Date) -> some View {
        let tomorrow = today.addingTimeInterval(86400)
        let week = today.addingTimeInterval(8 * 86400)
        let fortnight = today.addingTimeInterval(15 * 86400)
        group("Due today", upcoming.filter { $0.due < tomorrow }, tint: DB.rec)
        group("Next 7 days", upcoming.filter { $0.due >= tomorrow && $0.due < week }, tint: DB.amber)
        group("Next 2 weeks", upcoming.filter { $0.due >= week && $0.due < fortnight }, tint: DB.accent)
        group("Later", upcoming.filter { $0.due >= fortnight }, tint: DB.violet)
    }

    private func urgency(_ t: SchoolTask, today: Date) -> Color {
        t.due < today.addingTimeInterval(86400) ? DB.rec : t.due < today.addingTimeInterval(8 * 86400) ? DB.amber : DB.accent
    }

    @ViewBuilder
    private func group(_ title: String, _ items: [SchoolTask], tint: Color) -> some View {
        if !items.isEmpty {
            Text(title.uppercased()).font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(tint).padding(.leading, 4)
            ForEach(items) { TaskRow(model: model, task: $0, tint: tint, showSubject: true) }
        }
    }
}

private struct TaskRow: View {
    let model: AppModel
    let task: SchoolTask
    let tint: Color
    let showSubject: Bool
    @State private var hover = false

    var body: some View {
        let focused = model.focusedTaskID == task.id
        HStack(spacing: 10) {
            Image(systemName: task.graded ? "rosette" : task.submitted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(task.name).font(.system(size: 12.5, weight: .semibold, design: .rounded)).lineLimit(1)
                Text([showSubject ? task.subjectName : "", task.kind, task.teacher ?? "", task.status].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 10.5, design: .rounded)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(DayMapService.dueText(task.due, now: model.daymap.now))
                .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(task.submitted ? .secondary : tint)
        }
        .padding(.vertical, 8).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(focused ? 0.14 : hover ? 0.08 : 0.03)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(focused ? tint.opacity(0.6) : .clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { model.daymap.openInDevBoard(model.daymap.taskURL(task)) }
        .help("Open in DayMap")
    }
}
