import AppKit
import Charts
import SwiftUI

struct MonitorView: View {
    let model: AppModel

    var body: some View {
        let m = model.monitor
        let s = m.sample
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                GaugeCard(title: "CPU", symbol: "cpu", value: s.cpu, detail: "\(m.cores) cores",
                          big: "\(Int((s.cpu * 100).rounded()))%", history: m.cpuHistory, color: DB.load(s.cpu))
                GaugeCard(title: "Memory", symbol: "memorychip", value: s.memFraction,
                          detail: "\(Fmt.bytes(s.memUsed)) of \(Fmt.bytes(s.memTotal))",
                          big: "\(Int((s.memFraction * 100).rounded()))%", history: m.memHistory, color: DB.load(s.memFraction * 0.85))
                GaugeCard(title: "Pressure", symbol: "waveform.path.ecg", value: s.pressure,
                          detail: s.swapUsed > 0 ? "Swap \(Fmt.bytes(s.swapUsed))" : "No swap",
                          big: pressureLabel(s), history: nil, color: DB.load(s.pressure * 1.1))
                NetCard(sample: s, inHistory: m.netInHistory, outHistory: m.netOutHistory)
            }
            .frame(height: 150)

            HStack(alignment: .top, spacing: 14) {
                AppsCard(model: model)
                VStack(spacing: 14) {
                    SystemCard(sample: s)
                    TipCard(sample: s)
                    Spacer(minLength: 0)
                }
                .frame(width: 270)
            }
        }
    }

    private func pressureLabel(_ s: SystemSample) -> String {
        switch s.freePercent {
        case ..<15: "Critical"
        case ..<35: "High"
        case ..<60: "Fair"
        default: "Low"
        }
    }
}

private struct GaugeCard: View {
    let title: String
    let symbol: String
    let value: Double
    let detail: String
    let big: String
    let history: [Double]?
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .semibold, design: .rounded))
                Spacer()
            }
            .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline) {
                Text(big)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(color.gradient)
                Spacer()
            }
            Text(detail).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
            if let history {
                Sparkline(values: history, color: color, maxValue: 1)
                    .frame(height: 34)
            } else {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.08))
                        Capsule().fill(LinearGradient(colors: [DB.mint, DB.amber, DB.rec], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(8, geo.size.width * value))
                            .mask(Capsule())
                    }
                }
                .frame(height: 8)
                .padding(.bottom, 4)
            }
        }
        .padding(14)
        .card()
        .animation(DB.soft, value: value)
    }
}

struct Sparkline: View {
    let values: [Double]
    let color: Color
    var maxValue: Double? = nil

    var body: some View {
        Chart(Array(values.enumerated()), id: \.offset) { i, v in
            AreaMark(x: .value("t", i), y: .value("v", v))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(LinearGradient(colors: [color.opacity(0.45), color.opacity(0.0)], startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("t", i), y: .value("v", v))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartXScale(domain: 0...max(1, 89))
        .chartYScale(domain: 0...(maxValue ?? max(values.max() ?? 1, 1)))
        .chartLegend(.hidden)
    }
}

private struct NetCard: View {
    let sample: SystemSample
    let inHistory: [Double]
    let outHistory: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "network").font(.system(size: 11, weight: .semibold))
                Text("Network").font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(.secondary)
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 0) {
                    Label(Fmt.rate(sample.netIn), systemImage: "arrow.down").foregroundStyle(DB.accent)
                    Label(Fmt.rate(sample.netOut), systemImage: "arrow.up").foregroundStyle(DB.pink)
                }
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .monospacedDigit()
            }
            Spacer(minLength: 0)
            let peak = max(inHistory.max() ?? 1, outHistory.max() ?? 1, 1)
            ZStack {
                Sparkline(values: inHistory, color: DB.accent, maxValue: peak)
                Sparkline(values: outHistory, color: DB.pink, maxValue: peak)
            }
            .frame(height: 50)
        }
        .padding(14)
        .card()
    }
}

private struct AppsCard: View {
    let model: AppModel
    var body: some View {
        let apps = model.monitor.apps
        let total = Double(model.monitor.sample.memTotal)
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "What's using memory", symbol: "square.stack.3d.up", trailing: "grouped by app")
            if apps.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(apps) { app in
                            AppRow(app: app, total: total) { model.monitor.terminate(app, force: false) }
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .padding(14)
        .card()
        .animation(DB.soft, value: apps.map(\.key))
    }
}

private struct AppRow: View {
    let app: AppUsage
    let total: Double
    let quit: () -> Void
    @State private var hover = false
    @State private var armed = false

    var body: some View {
        HStack(spacing: 10) {
            AppIcon(path: app.path).frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(app.name).font(.system(size: 12.5, weight: .semibold, design: .rounded)).lineLimit(1)
                    if app.paused { Chip(text: "paused by ram-guard", symbol: "pause.fill", tint: DB.amber) }
                    if app.isDev { Chip(text: "dev", tint: DB.violet) }
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.07))
                        Capsule().fill(DB.load(Double(app.memory) / total * 4).gradient)
                            .frame(width: max(4, geo.size.width * min(1, Double(app.memory) / total * 3)))
                    }
                }
                .frame(height: 4)
            }
            Text(Fmt.bytes(app.memory))
                .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                .frame(width: 74, alignment: .trailing)
            Text(String(format: "%.0f%%", app.cpu))
                .font(.system(size: 11.5, weight: .medium, design: .rounded)).monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            if armed {
                Button("Quit?") { quit() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9).frame(height: 22)
                    .background(Capsule().fill(DB.rec.gradient))
                    .transition(.scale.combined(with: .opacity))
                    .help("Sends quit to \(app.pids.count) process\(app.pids.count == 1 ? "" : "es")")
            } else {
                BubbleButton(symbol: "xmark.circle.fill", help: "Quit \(app.name)", tint: hover ? DB.rec : .secondary.opacity(0.4), size: 24) {
                    withAnimation(DB.snappy) { armed = true }
                }
                .disabled(app.pids.contains(getpid()))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(hover ? 0.07 : 0)))
        .onHover { h in
            withAnimation(DB.snappy) {
                hover = h
                if !h { armed = false }
            }
        }
    }
}

private struct AppIcon: View {
    let path: String?
    var body: some View {
        if let path {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
        } else {
            Image(systemName: "gearshape.2.fill")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.08)))
        }
    }
}

private struct SystemCard: View {
    let sample: SystemSample
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionHeader(title: "System", symbol: "laptopcomputer")
            row("internaldrive", "Disk free", Fmt.bytes(sample.diskFree))
            if let b = sample.battery {
                row(sample.charging ? "battery.100percent.bolt" : "battery.75percent", "Battery", "\(b)%\(sample.charging ? " · charging" : "")")
            }
            row("thermometer.medium", "Thermals", thermal)
            row("arrow.triangle.swap", "Swap used", Fmt.bytes(sample.swapUsed))
            row("drop", "Free (kernel)", "\(sample.freePercent)%")
        }
        .padding(14)
        .card()
    }

    private var thermal: String {
        switch sample.thermal {
        case .nominal: "Cool"
        case .fair: "Warm"
        case .serious: "Hot"
        case .critical: "Critical"
        @unknown default: "—"
        }
    }

    private func row(_ symbol: String, _ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).frame(width: 16)
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
    }
}

private struct TipCard: View {
    let sample: SystemSample
    var body: some View {
        let (symbol, color, text) = tip
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(color.gradient)
            Text(text).font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var tip: (String, Color, String) {
        if sample.freePercent < 15 {
            return ("exclamationmark.octagon.fill", DB.rec, "Memory is critical. Quit a browser or game before starting Godot, Blender or another agent.")
        }
        if sample.freePercent < 35 || sample.swapUsed > 2 << 30 {
            return ("exclamationmark.triangle.fill", DB.amber, "Memory is getting tight. One heavy app at a time keeps this Mac happy.")
        }
        return ("checkmark.seal.fill", DB.mint, "Plenty of headroom. Safe to launch a heavy app.")
    }
}
