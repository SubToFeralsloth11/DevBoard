import SwiftUI

/// Shared look: springs, palette and the small building blocks every screen uses.
enum DB {
    static let spring = Animation.spring(response: 0.44, dampingFraction: 0.78)
    static let snappy = Animation.spring(response: 0.3, dampingFraction: 0.86)
    static let soft = Animation.smooth(duration: 0.35)

    static let accent = Color(red: 0.42, green: 0.62, blue: 1.0)
    static let mint = Color(red: 0.30, green: 0.92, blue: 0.70)
    static let rec = Color(red: 1.0, green: 0.27, blue: 0.35)
    static let amber = Color(red: 1.0, green: 0.72, blue: 0.26)
    static let violet = Color(red: 0.68, green: 0.52, blue: 1.0)
    static let pink = Color(red: 1.0, green: 0.45, blue: 0.75)

    static func load(_ fraction: Double) -> Color {
        switch fraction {
        case ..<0.6: mint
        case ..<0.8: amber
        default: rec
        }
    }
}

/// Soft inner card used inside the glass board (glass on glass is avoided on purpose).
struct CardBackground: ViewModifier {
    var radius: CGFloat = 20
    var highlighted = false
    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.white.opacity(highlighted ? 0.12 : 0.06))
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(highlighted ? 0.35 : 0.18), .white.opacity(0.03)],
                            startPoint: .top, endPoint: .bottom),
                        lineWidth: 1)
            }
    }
}

extension View {
    func card(radius: CGFloat = 20, highlighted: Bool = false) -> some View {
        modifier(CardBackground(radius: radius, highlighted: highlighted))
    }
}

/// Small glowing dot that breathes while `active`.
struct PulseDot: View {
    var color: Color
    var active: Bool = true
    var size: CGFloat = 8

    var body: some View {
        ZStack {
            if active {
                Circle()
                    .fill(color.opacity(0.45))
                    .frame(width: size, height: size)
                    .phaseAnimator([false, true]) { view, phase in
                        view.scaleEffect(phase ? 2.4 : 1).opacity(phase ? 0 : 0.9)
                    } animation: { _ in .easeOut(duration: 1.4) }
            }
            Circle()
                .fill(color.gradient)
                .frame(width: size, height: size)
                .shadow(color: color.opacity(0.8), radius: active ? 4 : 0)
        }
        .frame(width: size * 2.4, height: size * 2.4)
    }
}

/// Moving highlight sweep for "working" text.
struct Shimmer: ViewModifier {
    var active: Bool
    func body(content: Content) -> some View {
        if active {
            content.overlay {
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, .white.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.5)
                        .phaseAnimator([false, true]) { view, phase in
                            view.offset(x: phase ? geo.size.width * 1.2 : -geo.size.width * 0.6)
                        } animation: { _ in .linear(duration: 1.6).delay(0.3) }
                }
                .mask(content)
                .allowsHitTesting(false)
            }
        } else {
            content
        }
    }
}

extension View {
    func shimmer(_ active: Bool) -> some View { modifier(Shimmer(active: active)) }
}

/// Rounded pill label: "● Live", "2 agents", etc.
struct Chip: View {
    var text: String
    var symbol: String? = nil
    var tint: Color = .secondary
    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }
            Text(text).font(.system(size: 10.5, weight: .semibold, design: .rounded))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(tint)
        .background(Capsule().fill(tint.opacity(0.14)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.22), lineWidth: 0.5))
    }
}

/// Section title used across the board.
struct SectionHeader: View {
    var title: String
    var symbol: String
    var trailing: String? = nil
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 13, weight: .semibold, design: .rounded))
            Spacer()
            if let trailing {
                Text(trailing).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
            }
        }
    }
}

/// Icon button with a soft hover bubble; used inside cards and toolbars.
struct BubbleButton: View {
    var symbol: String
    var help: String
    var tint: Color = .primary
    var size: CGFloat = 30
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(Circle().fill(.white.opacity(hover ? 0.16 : 0.0)))
                .contentShape(Circle())
                .scaleEffect(hover ? 1.08 : 1)
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { h in withAnimation(DB.snappy) { hover = h } }
    }
}

enum Fmt {
    static func bytes(_ v: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(v), countStyle: .memory)
    }

    static func rate(_ bytesPerSec: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesPerSec), countStyle: .file) + "/s"
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func ago(_ date: Date, now: Date = .now) -> String {
        let s = Int(now.timeIntervalSince(date))
        switch s {
        case ..<5: return "now"
        case ..<60: return "\(s)s ago"
        case ..<3600: return "\(s / 60)m ago"
        case ..<86400: return "\(s / 3600)h ago"
        default: return "\(s / 86400)d ago"
        }
    }

    static func cost(_ v: Double) -> String {
        v < 0.01 ? "<$0.01" : String(format: "$%.2f", v)
    }

    static func tokens(_ v: Int) -> String {
        switch v {
        case ..<1000: "\(v)"
        case ..<1_000_000: String(format: "%.1fk", Double(v) / 1000)
        default: String(format: "%.2fM", Double(v) / 1_000_000)
        }
    }
}
