import SwiftUI

struct BoardView: View {
    let model: AppModel
    @Namespace private var tabs

    var body: some View {
        VStack(spacing: 14) {
            header
            ZStack {
                switch model.boardTab {
                case .agents: AgentsView(model: model).transition(.boardSwap)
                case .school: SchoolView(model: model).transition(.boardSwap)
                case .files: FilesView(model: model).transition(.boardSwap)
                case .monitor: MonitorView(model: model).transition(.boardSwap)
                case .clips: ClipsView(model: model).transition(.boardSwap)
                case .activity: ActivityView(model: model).transition(.boardSwap)
                case .settings: SettingsView(model: model).transition(.boardSwap)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(DB.spring, value: model.boardTab)
        }
        .padding(18)
        .frame(width: BoardMetrics.size.width, height: BoardMetrics.size.height)
        .glass(RoundedRectangle(cornerRadius: 34, style: .continuous), tint: .black.opacity(0.32))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
        .scaleEffect(model.boardShown ? 1 : 0.9, anchor: .top)
        .opacity(model.boardShown ? 1 : 0)
        .blur(radius: model.boardShown ? 0 : 14)
        .offset(y: model.boardShown ? 0 : -18)
        .padding(BoardMetrics.shadowPad)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "square.grid.3x3.topleft.filled")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(LinearGradient(colors: [DB.accent, DB.violet], startPoint: .topLeading, endPoint: .bottomTrailing))
                Text("DevBoard")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
            }
            .padding(.leading, 6)

            Spacer()

            HStack(spacing: 2) {
                ForEach(BoardTab.allCases) { tab in
                    TabPill(tab: tab, selected: model.boardTab == tab, ns: tabs) {
                        withAnimation(DB.spring) { model.boardTab = tab }
                    }
                }
            }
            .padding(4)
            .background(Capsule().fill(.white.opacity(0.06)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 0.5))

            Spacer()

            HStack(spacing: 4) {
                BubbleButton(symbol: model.boardPinned ? "pin.fill" : "pin", help: model.boardPinned ? "Unpin (closes when you click away)" : "Pin open",
                             tint: model.boardPinned ? DB.amber : .secondary) {
                    model.boardPinned.toggle()
                }
                BubbleButton(symbol: "xmark", help: "Close (Esc)", tint: .secondary) { model.closeBoard() }
            }
        }
    }
}

private struct TabPill: View {
    let tab: BoardTab
    let selected: Bool
    let ns: Namespace.ID
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: tab.symbol).font(.system(size: 12, weight: .semibold))
                Text(tab.title).font(.system(size: 12.5, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(selected ? .primary : .secondary)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background {
                if selected {
                    Capsule()
                        .fill(.white.opacity(0.16))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
                        .matchedGeometryEffect(id: "tab", in: ns)
                } else if hover {
                    Capsule().fill(.white.opacity(0.06))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(DB.snappy) { hover = h } }
    }
}

extension AnyTransition {
    static var boardSwap: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.98)).combined(with: .offset(y: 8)),
                    removal: .opacity)
    }
}
