import AppKit
import SwiftUI

/// `DevBoard --render-icon <dir>` writes the .iconset PNGs used by scripts/build-app.sh.
enum IconRenderer {
    @MainActor
    static func renderIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--render-icon"), i + 1 < args.count else { return false }
        let dir = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = base * scale
                let renderer = ImageRenderer(content: AppIconArt().frame(width: 1024, height: 1024))
                renderer.scale = CGFloat(px) / 1024
                guard let cg = renderer.cgImage else { continue }
                let rep = NSBitmapImageRep(cgImage: cg)
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
            }
        }
        return true
    }
}

private struct AppIconArt: View {
    var body: some View {
        ZStack {
            // macOS icon grid: 824pt squircle centred in 1024.
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.10, green: 0.12, blue: 0.32),
                                              Color(red: 0.30, green: 0.16, blue: 0.62),
                                              Color(red: 0.86, green: 0.30, blue: 0.62)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    RadialGradient(colors: [.white.opacity(0.35), .clear], center: .init(x: 0.3, y: 0.15), startRadius: 0, endRadius: 520)
                        .clipShape(RoundedRectangle(cornerRadius: 185, style: .continuous))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 185, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 6)
                }
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 30, y: 18)

            VStack(spacing: 46) {
                // The island
                Capsule()
                    .fill(.white.opacity(0.22))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.7), lineWidth: 5))
                    .overlay {
                        HStack(spacing: 34) {
                            Circle().fill(Color(red: 0.30, green: 0.95, blue: 0.72)).frame(width: 40, height: 40)
                            Capsule().fill(.white.opacity(0.85)).frame(width: 120, height: 18)
                            Circle().fill(Color(red: 1.0, green: 0.32, blue: 0.4)).frame(width: 40, height: 40)
                        }
                    }
                    .frame(width: 440, height: 110)

                // Board tiles
                HStack(spacing: 34) {
                    tile(Color(red: 0.42, green: 0.62, blue: 1.0), height: 230)
                    VStack(spacing: 34) {
                        tile(Color(red: 1.0, green: 0.72, blue: 0.26), height: 98)
                        tile(Color(red: 0.30, green: 0.92, blue: 0.70), height: 98)
                    }
                }
                .frame(width: 520)
            }
            .offset(y: 10)
        }
        .frame(width: 1024, height: 1024)
    }

    private func tile(_ color: Color, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 34, style: .continuous)
            .fill(LinearGradient(colors: [color.opacity(0.95), color.opacity(0.55)], startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: 34, style: .continuous).strokeBorder(.white.opacity(0.55), lineWidth: 4))
            .frame(height: height)
    }
}
