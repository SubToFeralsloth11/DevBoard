import SwiftUI

enum IslandButton: String, CaseIterable, Identifiable {
    case agents, school, files, monitor, clips, screenshot, record, replay, settings
    var id: String { rawValue }
}

struct IslandView: View {
    let model: AppModel
    @Namespace private var ns
    @State private var hovered: IslandButton?
    @State private var dropTargeted = false

    private var size: CGSize {
        switch model.islandMode {
        case .compact: IslandMetrics.compact(barHeight: model.barHeight)
        case .expanded: IslandMetrics.expanded
        case .toast: IslandMetrics.toast
        case .drop: IslandMetrics.drop
        }
    }

    var body: some View {
        GlassContainer(spacing: 12) {
            VStack(spacing: 8) {
                ZStack {
                    switch model.islandMode {
                    case .compact:
                        CompactContent(model: model)
                            .transition(.blurReplace.combined(with: .scale(0.9)))
                    case .expanded:
                        ExpandedContent(model: model, hovered: $hovered)
                            .transition(.blurReplace.combined(with: .scale(0.85)))
                    case .toast:
                        if let toast = model.toast {
                            ToastContent(toast: toast) { if let a = toast.action { model.runToastAction(a) } else { model.dismissToast() } }
                                .transition(.blurReplace.combined(with: .scale(0.9)))
                        }
                    case .drop:
                        DropContent(targeted: dropTargeted, count: model.shelf.items.count)
                            .transition(.blurReplace.combined(with: .scale(0.9)))
                    }
                }
                .frame(width: size.width, height: size.height)
                .glass(RoundedRectangle(cornerRadius: model.islandMode == .drop ? 26 : size.height / 2, style: .continuous),
                       tint: dropTargeted ? DB.mint.opacity(0.3) : .black.opacity(0.18), interactive: true)
                .glassEffectID("island", in: ns)
                .contextMenu { IslandMenu(model: model) }

                if model.islandMode == .expanded, !model.shelf.isEmpty {
                    ShelfStrip(model: model)
                        .glass(Capsule(), tint: .black.opacity(0.18), interactive: true)
                        .glassEffectID("shelf", in: ns)
                        .transition(.blurReplace)
                }

                if model.islandMode == .expanded, let hovered {
                    Text(label(for: hovered))
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .glass(Capsule(), tint: .black.opacity(0.18))
                        .glassEffectID("label", in: ns)
                        .transition(.opacity)
                        .id(hovered)
                }
            }
        }
        .animation(DB.snappy, value: hovered)
        .animation(DB.snappy, value: dropTargeted)
        .padding(IslandMetrics.pad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Files dropped anywhere on the island land on the shelf, whatever it is showing.
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Shelf.load(providers) { model.dropOnShelf($0) }
            return true
        }
        .onChange(of: model.islandMode) { _, mode in if mode != .expanded { hovered = nil } }
        .environment(\.colorScheme, .dark)
    }

    private func label(for b: IslandButton) -> String {
        let s = model.settings
        switch b {
        case .agents: return "Agents  ⌥⇧A"
        case .school:
            if model.daymap.status == .signedOut { return "School  ⌥⇧L  ·  sign in to DayMap" }
            return "School: classes & DayMap tasks  ⌥⇧L"
        case .files: return "Shelf & file search  ⌥⇧F"
        case .monitor: return "Monitor  ⌥⇧M"
        case .clips: return "Clips & screenshots  ⌥⇧C"
        case .screenshot: return "Screenshot  ⌥⇧S  ·  right-click for more"
        case .record: return model.capture.isRecording ? "Stop recording  ⌥⇧R" : "Record screen  ⌥⇧R"
        case .replay:
            if model.capture.replayArmed { return "Save last \(s.replaySeconds)s  ⌥⇧X  ·  right-click to turn off" }
            return s.replayEnabled ? "Instant replay isn't running  ·  click to retry" : "Instant replay is off  ·  click to turn on"
        case .settings: return "Settings"
        }
    }
}

// MARK: Compact

private struct CompactContent: View {
    let model: AppModel

    var body: some View {
        let agents = model.agents
        let capture = model.capture
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                if agents.workingCount > 0 {
                    PulseDot(color: DB.mint, size: 6)
                    Text("\(agents.workingCount)").contentTransition(.numericText())
                } else if agents.waitingCount > 0 {
                    PulseDot(color: DB.amber, active: false, size: 6)
                    Text("\(agents.waitingCount)").contentTransition(.numericText())
                } else {
                    Image(systemName: "sparkles").foregroundStyle(.secondary)
                        .frame(width: 14)
                }
            }
            .frame(minWidth: 34, alignment: .leading)

            Spacer(minLength: 0)

            if capture.isRecording, let since = capture.recordingSince {
                HStack(spacing: 5) {
                    PulseDot(color: DB.rec, size: 6)
                    TimelineView(.periodic(from: since, by: 1)) { ctx in
                        Text(Fmt.clock(ctx.date.timeIntervalSince(since)))
                            .monospacedDigit()
                    }
                }
                .foregroundStyle(DB.rec)
            } else if capture.busy {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("Saving")
                }
            } else if capture.replayArmed {
                HStack(spacing: 4) {
                    Image(systemName: "memories").foregroundStyle(DB.amber)
                    Text("\(model.settings.replaySeconds)s").foregroundStyle(.secondary)
                }
            } else if let h = model.daymap.headline {
                HStack(spacing: 5) {
                    Image(systemName: h.symbol).foregroundStyle(h.tint)
                    Text(h.text).lineLimit(1).truncationMode(.tail)
                }
                .help("From DayMap")
            } else {
                Text("DevBoard").foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            HStack(spacing: 7) {
                if !model.shelf.isEmpty {
                    HStack(spacing: 2) {
                        Image(systemName: "tray.full.fill").font(.system(size: 9.5, weight: .bold))
                        Text("\(model.shelf.items.count)").contentTransition(.numericText())
                    }
                    .foregroundStyle(DB.mint)
                    .help("Files on the shelf; hover to drag them out")
                }
                RamRing(fraction: model.monitor.sample.memFraction, pressure: model.monitor.sample.pressure)
            }
            .frame(minWidth: 34, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .padding(.horizontal, 12)
        .contentShape(Capsule())
        .onTapGesture {
            if model.capture.isRecording { model.perform(.toggleRecording) } else { model.perform(.toggleBoard) }
        }
    }
}

struct RamRing: View {
    var fraction: Double
    var pressure: Double
    var body: some View {
        HStack(spacing: 4) {
            ZStack {
                Circle().stroke(.white.opacity(0.15), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: max(0.02, fraction))
                    .stroke(DB.load(max(fraction * 0.8, pressure)).gradient, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 13, height: 13)
            Text("\(Int((fraction * 100).rounded()))%")
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .animation(DB.soft, value: fraction)
        .help("Memory used")
    }
}

// MARK: Expanded

private struct ExpandedContent: View {
    let model: AppModel
    @Binding var hovered: IslandButton?

    var body: some View {
        HStack(spacing: 4) {
            button(.agents, "sparkles.rectangle.stack", badge: model.agents.workingCount) { model.perform(.openAgents) }
            button(.school, "graduationcap", badge: dueSoon) { model.perform(.openSchool) }
            button(.files, "tray.full", active: !model.shelf.isEmpty) { model.perform(.openFiles) }
            button(.monitor, "gauge.with.dots.needle.67percent") { model.perform(.openMonitor) }
            button(.clips, "film.stack") { model.perform(.openClips) }
            divider
            button(.screenshot, "camera.viewfinder") { model.perform(.screenshotRegion) }
                .contextMenu {
                    Button("Region…", systemImage: "rectangle.dashed") { model.perform(.screenshotRegion) }
                    Button("Window…", systemImage: "macwindow") { model.perform(.screenshotWindow) }
                    Button("Whole screen", systemImage: "display") { model.perform(.screenshotScreen) }
                }
            button(.record, model.capture.isRecording ? "stop.fill" : "record.circle",
                   tint: DB.rec, active: model.capture.isRecording) { model.perform(.toggleRecording) }
            button(.replay, "memories", tint: DB.amber, active: model.capture.replayArmed, dimmed: !model.capture.replayArmed) {
                model.perform(model.settings.replayEnabled ? .saveReplay : .toggleReplay)
            }
            .contextMenu {
                Button(model.settings.replayEnabled ? "Turn instant replay off" : "Turn instant replay on") { model.perform(.toggleReplay) }
            }
            divider
            button(.settings, "slider.horizontal.3") { model.perform(.openSettings) }
        }
        .padding(.horizontal, 9)
    }

    /// Unsubmitted DayMap tasks due today or tomorrow.
    private var dueSoon: Int {
        let cal = Calendar.current
        let limit = cal.date(byAdding: .day, value: 2, to: cal.startOfDay(for: model.daymap.now))!
        return model.daymap.tasks.filter { !$0.submitted && $0.due < limit && $0.due >= cal.startOfDay(for: model.daymap.now) }.count
    }

    private var divider: some View {
        Capsule().fill(.white.opacity(0.18)).frame(width: 1, height: 22).padding(.horizontal, 3)
    }

    private func button(_ id: IslandButton, _ symbol: String, tint: Color = .primary, active: Bool = false,
                        dimmed: Bool = false, badge: Int = 0, action: @escaping () -> Void) -> some View {
        IslandIcon(symbol: symbol, tint: tint, active: active, dimmed: dimmed, badge: badge, isHovered: hovered == id, action: action)
            .onHover { inside in
                if inside { hovered = id } else if hovered == id { hovered = nil }
            }
    }
}

private struct IslandIcon: View {
    var symbol: String
    var tint: Color
    var active: Bool
    var dimmed: Bool
    var badge: Int
    var isHovered: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(active ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(.primary))
                    .opacity(dimmed ? 0.55 : 1)
                    .symbolEffect(.pulse, isActive: active && symbol == "stop.fill")
                    .frame(width: 42, height: 42)
                    .background {
                        Circle()
                            .fill(active ? tint.opacity(0.22) : .white.opacity(isHovered ? 0.16 : 0))
                    }
                    .scaleEffect(isHovered ? 1.1 : 1)
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 15, minHeight: 15)
                        .background(Capsule().fill(DB.mint))
                        .offset(x: 2, y: 2)
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(PressScale())
        .animation(DB.snappy, value: isHovered)
    }
}

struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(DB.snappy, value: configuration.isPressed)
    }
}

// MARK: Toast

private struct ToastContent: View {
    let toast: Toast
    let tap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let thumb = toast.thumbnail {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 58, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
            } else {
                Image(systemName: toast.symbol)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(toast.tint.gradient)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(toast.tint.opacity(0.18)))
                    .symbolEffect(.bounce, value: toast.id)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(toast.title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                if let sub = toast.subtitle {
                    Text(sub)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if toast.action != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, 11)
        .padding(.trailing, 18)
        .contentShape(Capsule())
        .onTapGesture(perform: tap)
    }
}

// MARK: Drop zone

private struct DropContent: View {
    var targeted: Bool
    var count: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: targeted ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(DB.mint.gradient)
                .frame(width: 44, height: 44)
                .background(Circle().fill(DB.mint.opacity(targeted ? 0.3 : 0.16)))
                .symbolEffect(.bounce, value: targeted)
                .scaleEffect(targeted ? 1.08 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(targeted ? "Let go to keep it here" : "Drop on DevBoard")
                    .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                Text(count == 0 ? "Then switch apps and drag it back out" : "Joins \(count) on the shelf")
                    .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
    }
}

// MARK: Shelf strip

/// Shelf items under the expanded bar; drag one out to drop it into any app.
private struct ShelfStrip: View {
    let model: AppModel
    private let maxShown = 7

    var body: some View {
        let items = model.shelf.items
        HStack(spacing: 4) {
            ForEach(items.suffix(maxShown), id: \.self) { url in
                ShelfChip(model: model, url: url)
            }
            if items.count > maxShown {
                Button { model.perform(.openFiles) } label: {
                    Text("+\(items.count - maxShown)")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .frame(width: 42, height: 46)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressScale())
                .help("Show the whole shelf")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 62)
    }
}

private struct ShelfChip: View {
    let model: AppModel
    let url: URL
    @State private var hover = false

    var body: some View {
        VStack(spacing: 2) {
            Image(nsImage: FileKind.icon(url)).resizable().frame(width: 32, height: 32)
            Text(url.lastPathComponent).font(.system(size: 9, weight: .medium, design: .rounded))
                .lineLimit(1).truncationMode(.middle).frame(width: 52)
        }
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(hover ? 0.14 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { model.openFile(url) }
        .onDrag {
            model.beginShelfDrag()
            return FileKind.dragProvider(url)
        }
        .help("\(url.lastPathComponent): drag out to use, double-click to open")
        .contextMenu { FileMenu(model: model, url: url, onShelf: true) }
    }
}

// MARK: Menu

struct IslandMenu: View {
    let model: AppModel
    var body: some View {
        Button("Agents", systemImage: "sparkles.rectangle.stack") { model.perform(.openAgents) }
        Button("School", systemImage: "graduationcap") { model.perform(.openSchool) }
        Button("Files", systemImage: "tray.full") { model.perform(.openFiles) }
        Button("Monitor", systemImage: "gauge.with.dots.needle.67percent") { model.perform(.openMonitor) }
        Button("Clips", systemImage: "film.stack") { model.perform(.openClips) }
        Button("Activity", systemImage: "chart.bar.xaxis") { model.perform(.openActivity) }
        Button("Sync DayMap now", systemImage: "arrow.triangle.2.circlepath") { model.daymap.syncNow() }
        Divider()
        Button(model.settings.replayEnabled ? "Turn instant replay off" : "Turn instant replay on") { model.perform(.toggleReplay) }
        Picker("Screen filter", selection: Binding(get: { model.settings.screenTint },
                                                   set: { model.settings.screenTint = $0; model.screenFilter.apply() })) {
            ForEach(ScreenTint.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
        }
        Button("Hide island (⌥⇧H to bring back)") { model.perform(.toggleIsland) }
        Button("Settings…") { model.perform(.openSettings) }
        Divider()
        Button("Quit DevBoard") { model.perform(.quit) }
    }
}
