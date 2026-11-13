import AppKit
import Charts
import CoreLocation
import MapKit
import SwiftUI

/// Daily report: keys and clicks, screen time per app, and the route the Mac travelled.
struct ActivityView: View {
    let model: AppModel
    @State private var day = ActivityTracker.key(for: .now)
    @State private var days: [String] = []

    var body: some View {
        let tracker = model.activity
        let a = tracker.activity(for: day)
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                dayPicker
                StatTile(title: "Screen time", symbol: "hourglass", value: Self.duration(a.screenSeconds),
                         detail: a.apps.isEmpty ? "No apps yet" : "\(a.apps.count) apps", color: DB.accent)
                StatTile(title: "Keys pressed", symbol: "keyboard", value: a.totalKeys.formatted(),
                         detail: tracker.keyboardAllowed ? topKeyLine(a) : "Needs Input Monitoring", color: DB.violet)
                StatTile(title: "Clicks", symbol: "computermouse", value: a.totalClicks.formatted(),
                         detail: a.clicks["Right click"].map { "\($0.formatted()) right clicks" } ?? "Mouse & trackpad", color: DB.pink)
                StatTile(title: "Travelled", symbol: "point.topleft.down.to.point.bottomright.curvepath", value: Self.distance(a.distanceMeters),
                         detail: a.points.isEmpty ? "No route yet" : "\(a.points.count) places", color: DB.mint)
            }
            .frame(height: 92)

            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 14) {
                    AppsCard(activity: a)
                    HoursCard(activity: a)
                }
                .frame(width: 300)
                KeysCard(activity: a, allowed: tracker.keyboardAllowed) { tracker.requestKeyboard() }
                    .frame(width: 260)
                RouteCard(activity: a, status: tracker.locationStatus, isToday: day == ActivityTracker.key(for: .now)) {
                    tracker.requestLocation()
                }
            }
        }
        .onAppear { days = tracker.savedDays() }
    }

    private var dayPicker: some View {
        let index = days.firstIndex(of: day)
        return VStack(spacing: 8) {
            Text(Self.dayTitle(day))
                .font(.system(size: 15, weight: .bold, design: .rounded))
            Text(Self.dayDate(day)).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                BubbleButton(symbol: "chevron.left", help: "Previous day", tint: index.map { $0 + 1 < days.count } == true ? .primary : .secondary, size: 26) {
                    if let i = index, i + 1 < days.count { withAnimation(DB.snappy) { day = days[i + 1] } }
                }
                BubbleButton(symbol: "calendar", help: "Today", tint: .secondary, size: 26) {
                    withAnimation(DB.snappy) { day = ActivityTracker.key(for: .now) }
                }
                BubbleButton(symbol: "chevron.right", help: "Next day", tint: (index ?? 0) > 0 ? .primary : .secondary, size: 26) {
                    if let i = index, i > 0 { withAnimation(DB.snappy) { day = days[i - 1] } }
                }
            }
        }
        .frame(width: 150)
        .frame(maxHeight: .infinity)
        .card()
    }

    private func topKeyLine(_ a: DayActivity) -> String {
        guard let top = a.keys.max(by: { $0.value < $1.value }) else { return "Start typing" }
        return "Most: \(top.key) ×\(top.value.formatted())"
    }

    static func duration(_ s: Double) -> String {
        let m = Int(s / 60)
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }

    static func distance(_ m: Double) -> String {
        m >= 1000 ? String(format: "%.1f km", m / 1000) : "\(Int(m)) m"
    }

    private static func dayTitle(_ key: String) -> String {
        guard let d = ActivityTracker.date(for: key) else { return key }
        if Calendar.current.isDateInToday(d) { return "Today" }
        if Calendar.current.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(.dateTime.weekday(.wide))
    }

    private static func dayDate(_ key: String) -> String {
        ActivityTracker.date(for: key)?.formatted(.dateTime.day().month(.abbreviated).year()) ?? ""
    }
}

private struct StatTile: View {
    let title: String
    let symbol: String
    let value: String
    let detail: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .semibold, design: .rounded))
                Spacer()
            }
            .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(color.gradient)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(detail).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
    }
}

// MARK: Apps

private struct AppsCard: View {
    let activity: DayActivity

    var body: some View {
        let apps = activity.apps.sorted { $0.value.seconds > $1.value.seconds }
        let top = apps.first?.value.seconds ?? 1
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Apps", symbol: "square.stack.3d.up", trailing: ActivityView.duration(activity.screenSeconds))
            if apps.isEmpty {
                Text("Screen time adds up while you use the Mac; it pauses after 5 minutes without input or when the screen locks.")
                    .font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(apps, id: \.key) { id, app in
                            HStack(spacing: 9) {
                                Image(nsImage: AppIcons.icon(id))
                                    .resizable().frame(width: 22, height: 22)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(app.name).font(.system(size: 12, weight: .semibold, design: .rounded)).lineLimit(1)
                                        Spacer()
                                        Text(ActivityView.duration(app.seconds))
                                            .font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(.secondary)
                                    }
                                    Bar(fraction: app.seconds / top, color: DB.accent)
                                }
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
    }
}

private struct HoursCard: View {
    let activity: DayActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "By hour", symbol: "clock", trailing: "minutes on screen")
            Chart(0..<24, id: \.self) { h in
                BarMark(x: .value("Hour", h), y: .value("Minutes", activity.hourlySeconds[h] / 60))
                    .foregroundStyle(DB.accent.gradient)
                    .cornerRadius(2)
            }
            .chartXScale(domain: -0.5...23.5)
            .chartXAxis {
                AxisMarks(values: [0, 6, 12, 18]) { v in
                    AxisValueLabel { if let h = v.as(Int.self) { Text(h == 0 ? "12am" : h == 12 ? "12pm" : h < 12 ? "\(h)am" : "\(h - 12)pm") } }
                }
            }
            .chartYAxis(.hidden)
            .chartYScale(domain: 0...60)
        }
        .padding(14)
        .frame(height: 150)
        .card()
    }
}

enum AppIcons {
    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor static func icon(_ bundleID: String) -> NSImage {
        if let hit = cache[bundleID] { return hit }
        let img = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)!
        if cache.count > 200 { cache.removeAll() }
        cache[bundleID] = img
        return img
    }
}

// MARK: Keys

private struct KeysCard: View {
    let activity: DayActivity
    let allowed: Bool
    let request: () -> Void

    var body: some View {
        let keys = activity.keys.sorted { $0.value > $1.value }
        let top = Double(keys.first?.value ?? 1)
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Keys & buttons", symbol: "keyboard", trailing: (activity.totalKeys + activity.totalClicks).formatted())
            if !allowed {
                VStack(alignment: .leading, spacing: 8) {
                    Text("To count key presses, turn on DevBoard in Input Monitoring. Only how many times each key is pressed is saved, never what you type.")
                        .font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Allow key counting", action: request).controlSize(.small)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DB.violet.opacity(0.12)))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !activity.clicks.isEmpty {
                        group("Mouse", activity.clicks.sorted { $0.value > $1.value }, top: Double(activity.clicks.values.max() ?? 1), color: DB.pink)
                    }
                    if !keys.isEmpty {
                        group("Keys", keys, top: top, color: DB.violet)
                    }
                    if !activity.shortcuts.isEmpty {
                        let s = activity.shortcuts.sorted { $0.value > $1.value }.prefix(12)
                        group("Shortcuts", Array(s), top: Double(s.first?.value ?? 1), color: DB.amber)
                    }
                    if keys.isEmpty && activity.clicks.isEmpty {
                        Text("Nothing pressed yet.").font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary)
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
    }

    private func group(_ title: String, _ rows: [(key: String, value: Int)], top: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(.tertiary)
            ForEach(rows, id: \.key) { name, count in
                HStack(spacing: 8) {
                    Text(name)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 26, minHeight: 20)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.white.opacity(0.1)))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
                        .frame(width: 92, alignment: .leading)
                    Bar(fraction: Double(count) / top, color: color)
                    Text(count.formatted())
                        .font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 46, alignment: .trailing)
                }
            }
        }
    }
}

private struct Bar: View {
    let fraction: Double
    let color: Color
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.07))
                Capsule().fill(color.gradient).frame(width: max(4, geo.size.width * min(1, fraction)))
            }
        }
        .frame(height: 5)
    }
}

// MARK: Route

private struct RouteCard: View {
    let activity: DayActivity
    let status: CLAuthorizationStatus
    let isToday: Bool
    let request: () -> Void

    var body: some View {
        let coords = activity.points.map(\.coordinate)
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Where you went", symbol: "map",
                          trailing: activity.points.first.map { "\($0.t.formatted(date: .omitted, time: .shortened)) – \(activity.points.last!.t.formatted(date: .omitted, time: .shortened))" })
            ZStack {
                Map(initialPosition: .automatic) {
                    if coords.count > 1 {
                        MapPolyline(coordinates: coords)
                            .stroke(LinearGradient(colors: [DB.mint, DB.accent, DB.violet], startPoint: .leading, endPoint: .trailing),
                                    style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                    }
                    if let first = coords.first {
                        Annotation("Start", coordinate: first) { dot(DB.mint) }
                    }
                    if coords.count > 1, let last = coords.last {
                        Annotation(isToday ? "Now" : "End", coordinate: last) { dot(DB.violet) }
                    }
                }
                .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
                .id(activity.day + "\(coords.count)")
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                if isToday && !(status == .authorized || status == .authorizedAlways) {
                    overlay("Turn on Location so DevBoard can draw where your Mac travels today. Points stay on this Mac.",
                            button: status == .notDetermined ? "Allow location" : "Open Location settings")
                } else if coords.isEmpty {
                    overlay(isToday ? "Your route appears once the Mac has moved somewhere." : "No route was recorded this day.", button: nil)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
    }

    private func dot(_ color: Color) -> some View {
        Circle().fill(color.gradient).frame(width: 12, height: 12)
            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
            .shadow(color: color, radius: 4)
    }

    private func overlay(_ text: String, button: String?) -> some View {
        VStack(spacing: 8) {
            Text(text).font(.system(size: 11.5, weight: .medium, design: .rounded)).multilineTextAlignment(.center)
            if let button { Button(button, action: request).controlSize(.small) }
        }
        .padding(12)
        .frame(maxWidth: 260)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black.opacity(0.6)))
    }
}
