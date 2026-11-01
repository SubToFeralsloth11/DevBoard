import SwiftUI

enum IslandButton: String, CaseIterable, Identifiable {
    case agents, monitor, clips, screenshot, record, replay, settings
    var id: String { rawValue }
}

struct IslandView: View {
    let model: AppModel
    @Namespace private var ns
    @State private var hovered: IslandButton?

    private var size: CGSize {
        switch model.islandMode {
        case .compact: IslandMetrics.compact
        case .expanded: IslandMetrics.expanded
        case .toast: IslandMetrics.toast
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
                    }
                }
                .frame(width: size.width, height: size.height)
                .glass(Capsule(), tint: .black.opacity(0.18), interactive: true)
                .glassEffectID("island", in: ns)
                .contextMenu { IslandMenu(model: model) }

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
        .padding(IslandMetrics.pad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: model.islandMode) { _, mode in if mode != .expanded { hovered = nil } }
        .environment(\.colorScheme, .dark)
    }

    private func label(for b: IslandButton) -> String {
        let s = model.settings
        switch b {
        case .agents: return "Agents  ⌥⇧A"
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
            } else {
                Text("DevBoard").foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            RamRing(fraction: model.monitor.sample.memFraction, pressure: model.monitor.sample.pressure)
                .frame(minWidth: 34, alignment: .trailing)
        }
        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
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

// MARK: Menu

struct IslandMenu: View {
    let model: AppModel
    var body: some View {
        Button("Agents", systemImage: "sparkles.rectangle.stack") { model.perform(.openAgents) }
        Button("Monitor", systemImage: "gauge.with.dots.needle.67percent") { model.perform(.openMonitor) }
        Button("Clips", systemImage: "film.stack") { model.perform(.openClips) }
        Divider()
        Button(model.settings.replayEnabled ? "Turn instant replay off" : "Turn instant replay on") { model.perform(.toggleReplay) }
        Button("Hide island (⌥⇧H to bring back)") { model.perform(.toggleIsland) }
        Button("Settings…") { model.perform(.openSettings) }
        Divider()
        Button("Quit DevBoard") { model.perform(.quit) }
    }
}
