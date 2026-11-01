import AppKit
import SwiftUI

struct AgentsView: View {
    let model: AppModel

    var body: some View {
        let scanner = model.agents
        ZStack {
            if let id = model.focusedAgentID, let agent = scanner.agents[id] {
                AgentDetail(model: model, agent: agent)
                    .transition(.asymmetric(insertion: .scale(scale: 0.96).combined(with: .opacity), removal: .opacity))
            } else {
                overview(scanner)
                    .transition(.opacity)
            }
        }
        .animation(DB.spring, value: model.focusedAgentID)
    }

    @ViewBuilder
    private func overview(_ scanner: AgentScanner) -> some View {
        let mains = scanner.mains
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Chip(text: "\(scanner.workingCount) working", symbol: "bolt.fill", tint: DB.mint)
                Chip(text: "\(scanner.waitingCount) waiting", symbol: "hourglass", tint: DB.amber)
                Chip(text: Fmt.cost(scanner.agents.values.reduce(0) { $0 + $1.cost }) + " in view", symbol: "dollarsign", tint: DB.accent)
                Spacer()
                Text("Last \(model.settings.agentWindowMinutes) min · omp")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            if mains.isEmpty {
                EmptyAgents()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                        ForEach(mains) { agent in
                            AgentScreenCard(agent: agent, children: scanner.children(of: agent.id)) { id in
                                withAnimation(DB.spring) { model.focusedAgentID = id }
                            }
                        }
                    }
                    .padding(.bottom, 6)
                }
                .scrollIndicators(.never)
            }
        }
    }
}

private struct EmptyAgents: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(LinearGradient(colors: [DB.accent, DB.violet], startPoint: .top, endPoint: .bottom))
                .symbolEffect(.breathe)
            Text("No agents right now").font(.system(size: 17, weight: .semibold, design: .rounded))
            Text("Start omp in a terminal and its screen shows up here live.")
                .font(.system(size: 12.5, design: .rounded)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Card

struct AgentScreenCard: View {
    let agent: AgentSnapshot
    let children: [AgentSnapshot]
    let open: (String) -> Void
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AgentTitleBar(agent: agent)
            MiniScreen(agent: agent, lines: 7)
                .frame(height: 168)
            HStack(spacing: 10) {
                ActivityStrip(events: agent.recentEvents, color: agent.status.color)
                    .frame(width: 90, height: 18)
                StatLabel(symbol: "wrench.and.screwdriver", text: "\(agent.toolCalls)")
                StatLabel(symbol: "text.word.spacing", text: Fmt.tokens(agent.tokens))
                StatLabel(symbol: "dollarsign.circle", text: Fmt.cost(agent.cost) + (agent.partial ? "+" : ""))
                Spacer()
                Text(Fmt.ago(agent.lastEvent)).font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
            }
            if !children.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(children) { child in
                            Button { open(child.id) } label: {
                                HStack(spacing: 5) {
                                    Circle().fill(child.status.color).frame(width: 6, height: 6)
                                    Text(child.name).lineLimit(1)
                                }
                                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Capsule().fill(child.status.color.opacity(0.14)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .padding(14)
        .card(radius: 24, highlighted: hover)
        .scaleEffect(hover ? 1.012 : 1)
        .shadow(color: agent.status.isWorking ? agent.status.color.opacity(hover ? 0.35 : 0.18) : .clear, radius: 18)
        .contentShape(RoundedRectangle(cornerRadius: 24))
        .onTapGesture { open(agent.id) }
        .onHover { h in withAnimation(DB.snappy) { hover = h } }
    }
}

struct AgentTitleBar: View {
    let agent: AgentSnapshot
    var large = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: large ? 12 : 9, style: .continuous)
                    .fill(agent.status.color.opacity(0.18))
                Image(systemName: agent.isSubagent ? "person.2.fill" : "sparkle")
                    .font(.system(size: large ? 17 : 13, weight: .bold))
                    .foregroundStyle(agent.status.color.gradient)
                    .symbolEffect(.rotate, isActive: agent.status == .thinking && !agent.isSubagent)
            }
            .frame(width: large ? 40 : 30, height: large ? 40 : 30)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(agent.displayName)
                        .font(.system(size: large ? 17 : 13.5, weight: .bold, design: .rounded))
                        .lineLimit(1)
                    if agent.live { Chip(text: "LIVE", tint: DB.mint) }
                }
                Text(agent.title.isEmpty ? (agent.model.isEmpty ? "omp session" : agent.model) : agent.title)
                    .font(.system(size: large ? 12.5 : 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            StatusPill(status: agent.status)
        }
    }
}

struct StatusPill: View {
    let status: AgentStatus
    var body: some View {
        HStack(spacing: 4) {
            PulseDot(color: status.color, active: status.isWorking, size: 6)
                .frame(width: 10, height: 10)
            Text(status.label)
                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                .shimmer(status.isWorking)
        }
        .foregroundStyle(status.color)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(status.color.opacity(0.14)))
        .overlay(Capsule().strokeBorder(status.color.opacity(0.25), lineWidth: 0.5))
        .fixedSize()
    }
}

private struct StatLabel: View {
    let symbol: String
    let text: String
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold))
            Text(text).monospacedDigit()
        }
        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
        .foregroundStyle(.secondary)
    }
}

/// Bars for event counts in 30 s buckets over the last 10 minutes.
struct ActivityStrip: View {
    let events: [Date]
    let color: Color

    var body: some View {
        let now = Date()
        var buckets = [Int](repeating: 0, count: 20)
        for e in events {
            let i = 19 - Int(now.timeIntervalSince(e) / 30)
            if (0..<20).contains(i) { buckets[i] += 1 }
        }
        let peak = max(buckets.max() ?? 1, 1)
        return HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(0..<20, id: \.self) { i in
                Capsule()
                    .fill(buckets[i] > 0 ? AnyShapeStyle(color.gradient) : AnyShapeStyle(.white.opacity(0.1)))
                    .frame(height: max(2.5, CGFloat(buckets[i]) / CGFloat(peak) * 18))
            }
        }
        .animation(DB.soft, value: buckets)
        .help("Activity, last 10 minutes")
    }
}

// MARK: Screen

/// The agent's "screen": a dark terminal-like pane showing what it is doing right now.
struct MiniScreen: View {
    let agent: AgentSnapshot
    var lines: Int

    var body: some View {
        let shown = Array(agent.lines.suffix(lines))
        VStack(alignment: .leading, spacing: 5) {
            ForEach(shown) { line in
                FeedRow(line: line, compact: true)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
            }
            Spacer(minLength: 0)
            if agent.status.isWorking {
                HStack(spacing: 6) {
                    Image(systemName: agent.status == .running ? FeedSymbols.forTool(agent.toolName) : "brain")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(agent.status.color)
                    Text(agent.status == .running ? (agent.toolIntent ?? agent.toolName ?? "Working") : "Thinking")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .shimmer(true)
                        .lineLimit(1)
                    BlinkingCursor(color: agent.status.color)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.black.opacity(0.42))
                .overlay(alignment: .top) {
                    LinearGradient(colors: [agent.status.color.opacity(agent.status.isWorking ? 0.16 : 0.05), .clear], startPoint: .top, endPoint: .center)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
        }
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1))
        .mask(
            LinearGradient(stops: [.init(color: .black.opacity(0.25), location: 0), .init(color: .black, location: 0.22), .init(color: .black, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .animation(DB.spring, value: agent.lines.last?.id)
    }
}

enum FeedSymbols {
    static func forTool(_ name: String?) -> String {
        switch name {
        case "bash": "terminal.fill"
        case "read": "doc.text.fill"
        case "edit", "ast_edit": "pencil.line"
        case "write": "square.and.pencil"
        case "grep", "find", "glob": "magnifyingglass"
        case "task": "person.2.fill"
        case "eval": "chevron.left.forwardslash.chevron.right"
        case "web_search": "globe"
        default: "wrench.and.screwdriver.fill"
        }
    }
}

struct BlinkingCursor: View {
    let color: Color
    var body: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(color)
            .frame(width: 7, height: 12)
            .phaseAnimator([1.0, 0.15]) { v, o in v.opacity(o) } animation: { _ in .easeInOut(duration: 0.55) }
    }
}

struct FeedRow: View {
    let line: FeedLine
    var compact: Bool

    private var tint: Color {
        if line.isError { return DB.rec }
        switch line.kind {
        case .user: return DB.amber
        case .thinking: return DB.violet
        case .text: return .white
        case .tool: return DB.mint
        case .result: return .gray
        case .system: return DB.rec
        }
    }

    var body: some View {
        if compact {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: line.symbol)
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 13)
                Text(line.title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(tint.opacity(0.95))
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(compactDetail)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(line.kind == .result ? 0.45 : 0.7))
                    .lineLimit(1)
            }
        } else {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: line.symbol)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(tint.opacity(0.14)))
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(line.title).font(.system(size: 12.5, weight: .semibold, design: .rounded)).foregroundStyle(tint)
                        Spacer()
                        if let t = line.time {
                            Text(t, format: .dateTime.hour().minute().second())
                                .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.tertiary)
                        }
                    }
                    if !line.detail.isEmpty {
                        Text(line.detail)
                            .font(line.kind == .tool || line.kind == .result
                                  ? .system(size: 11.5, design: .monospaced)
                                  : .system(size: 12.5, design: .rounded))
                            .foregroundStyle(.white.opacity(line.kind == .result ? 0.55 : 0.85))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var compactDetail: String {
        line.detail.split(separator: "\n").last.map(String.init) ?? ""
    }
}

// MARK: Detail

private struct AgentDetail: View {
    let model: AppModel
    let agent: AgentSnapshot

    var body: some View {
        let children = model.agents.children(of: agent.id)
        let parent = agent.parentID.flatMap { model.agents.agents[$0] }
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    BubbleButton(symbol: "chevron.left", help: "Back (Esc)", size: 32) {
                        withAnimation(DB.spring) { model.focusedAgentID = agent.parentID.flatMap { model.agents.agents[$0] != nil ? $0 : nil } }
                    }
                    AgentTitleBar(agent: agent, large: true)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(agent.lines) { FeedRow(line: $0, compact: false).id($0.id) }
                            if agent.status.isWorking {
                                HStack(spacing: 8) {
                                    Text(agent.status == .running ? (agent.toolIntent ?? agent.toolName ?? "Working") : "Thinking")
                                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                                        .foregroundStyle(agent.status.color)
                                        .shimmer(true)
                                    BlinkingCursor(color: agent.status.color)
                                }
                                .padding(.leading, 34)
                                .id(-1)
                            }
                        }
                        .padding(16)
                    }
                    .defaultScrollAnchor(.bottom)
                    .scrollIndicators(.never)
                    .onChange(of: agent.lines.last?.id) { _, _ in
                        withAnimation(DB.soft) { proxy.scrollTo(agent.status.isWorking ? -1 : agent.lines.last?.id, anchor: .bottom) }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.black.opacity(0.42)))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.08)))
            }

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 9) {
                    SectionHeader(title: "Session", symbol: "info.circle")
                    InfoRow(label: "Model", value: agent.model.isEmpty ? "—" : agent.model)
                    InfoRow(label: "Thinking", value: agent.thinkingLevel.isEmpty ? "—" : agent.thinkingLevel)
                    InfoRow(label: "Project", value: agent.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    if let s = agent.started {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            InfoRow(label: "Running", value: Fmt.clock(ctx.date.timeIntervalSince(s)))
                        }
                    }
                    InfoRow(label: "Tool calls", value: "\(agent.toolCalls)")
                    InfoRow(label: "Tokens", value: Fmt.tokens(agent.tokens))
                    InfoRow(label: "Cost", value: Fmt.cost(agent.cost) + (agent.partial ? "+" : ""))
                    ActivityStrip(events: agent.recentEvents, color: agent.status.color).frame(height: 22)
                }
                .padding(14)
                .card()

                if let parent {
                    Button { withAnimation(DB.spring) { model.focusedAgentID = parent.id } } label: {
                        Label("Parent: \(parent.displayName)", systemImage: "arrow.up.left")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .card(radius: 16)
                    }
                    .buttonStyle(.plain)
                }

                if !children.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "Subagents", symbol: "person.2", trailing: "\(children.count)")
                        ScrollView {
                            VStack(spacing: 6) {
                                ForEach(children) { child in
                                    Button { withAnimation(DB.spring) { model.focusedAgentID = child.id } } label: {
                                        HStack(spacing: 8) {
                                            PulseDot(color: child.status.color, active: child.status.isWorking, size: 6).frame(width: 12, height: 12)
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(child.name).font(.system(size: 12, weight: .semibold, design: .rounded)).lineLimit(1)
                                                Text(child.toolIntent ?? child.status.label).font(.system(size: 10.5, design: .rounded))
                                                    .foregroundStyle(.secondary).lineLimit(1)
                                            }
                                            Spacer()
                                        }
                                        .padding(8)
                                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.05)))
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .frame(maxHeight: 180)
                        .scrollIndicators(.never)
                    }
                    .padding(14)
                    .card()
                }

                VStack(spacing: 6) {
                    ActionRow(symbol: "chevron.left.forwardslash.chevron.right", title: "Open project in VS Code") {
                        let url = URL(fileURLWithPath: agent.cwd)
                        if let vs = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") {
                            NSWorkspace.shared.open([url], withApplicationAt: vs, configuration: NSWorkspace.OpenConfiguration())
                        } else {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    ActionRow(symbol: "folder", title: "Show project in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: agent.cwd)])
                    }
                    ActionRow(symbol: "doc.text.magnifyingglass", title: "Reveal transcript") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: agent.id)])
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(width: 270)
        }
    }
}

private struct InfoRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).lineLimit(1).truncationMode(.middle).monospacedDigit()
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
    }
}

struct ActionRow: View {
    let symbol: String
    let title: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).frame(width: 18)
                Text(title).font(.system(size: 12, weight: .semibold, design: .rounded))
                Spacer()
                Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).frame(height: 34)
            .card(radius: 14, highlighted: hover)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(DB.snappy) { hover = h } }
    }
}
