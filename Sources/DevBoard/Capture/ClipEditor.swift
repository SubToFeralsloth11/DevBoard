import AVFoundation
import AVKit
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum FilterPreset: String, CaseIterable, Identifiable, Sendable {
    case none = "Original", vivid = "Vivid", cinematic = "Cinematic", warm = "Warm", cool = "Cool"
    case dream = "Dream", noir = "Noir", mono = "Mono", chrome = "Chrome", fade = "Fade", instant = "Instant"
    var id: String { rawValue }
}

/// Everything the editor can change about the picture. A value type so it can cross into the
/// video compositor's render thread.
struct ClipLook: Equatable, Sendable {
    var preset: FilterPreset = .none
    var exposure: Double = 0       // EV, -1...1
    var contrast: Double = 1       // 0.7...1.4
    var saturation: Double = 1     // 0...2
    var warmth: Double = 0         // -1...1

    var isIdentity: Bool { self == ClipLook() }

    func apply(_ input: CIImage) -> CIImage {
        var img = input
        switch preset {
        case .none: break
        case .vivid: img = colorControls(img, sat: 1.35, con: 1.08)
        case .cinematic:
            img = colorControls(img, sat: 0.88, con: 1.14)
            img = temperature(img, amount: 0.25)
            let v = CIFilter.vignette()
            v.inputImage = img; v.intensity = 0.9; v.radius = 2.2
            img = v.outputImage ?? img
        case .warm: img = temperature(img, amount: 0.6)
        case .cool: img = temperature(img, amount: -0.6)
        case .dream:
            let b = CIFilter.bloom()
            b.inputImage = img; b.intensity = 0.7; b.radius = 10
            img = (b.outputImage ?? img).cropped(to: input.extent)
            img = colorControls(img, sat: 1.1, con: 0.95)
        case .noir: img = effect(img, CIFilter.photoEffectNoir())
        case .mono: img = effect(img, CIFilter.photoEffectMono())
        case .chrome: img = effect(img, CIFilter.photoEffectChrome())
        case .fade: img = effect(img, CIFilter.photoEffectFade())
        case .instant: img = effect(img, CIFilter.photoEffectInstant())
        }
        if exposure != 0 {
            let e = CIFilter.exposureAdjust()
            e.inputImage = img; e.ev = Float(exposure)
            img = e.outputImage ?? img
        }
        if contrast != 1 || saturation != 1 { img = colorControls(img, sat: saturation, con: contrast) }
        if warmth != 0 { img = temperature(img, amount: warmth) }
        return img.cropped(to: input.extent)
    }

    private func colorControls(_ i: CIImage, sat: Double, con: Double) -> CIImage {
        let f = CIFilter.colorControls()
        f.inputImage = i; f.saturation = Float(sat); f.contrast = Float(con); f.brightness = 0
        return f.outputImage ?? i
    }

    private func temperature(_ i: CIImage, amount: Double) -> CIImage {
        let f = CIFilter.temperatureAndTint()
        f.inputImage = i
        f.neutral = CIVector(x: 6500, y: 0)
        f.targetNeutral = CIVector(x: 6500 - amount * 2200, y: 0)
        return f.outputImage ?? i
    }

    private func effect(_ i: CIImage, _ f: CIFilter & CIFilterProtocol) -> CIImage {
        f.setValue(i, forKey: kCIInputImageKey)
        return f.outputImage ?? i
    }

    func videoComposition(for asset: AVAsset) async throws -> AVVideoComposition {
        let look = self
        return try await AVVideoComposition.videoComposition(with: asset) { request in
            request.finish(with: look.apply(request.sourceImage.clampedToExtent()).cropped(to: request.sourceImage.extent), context: nil)
        }
    }
}

// MARK: Editor

struct ClipEditor: View {
    let model: AppModel
    let item: ClipItem

    @State private var player = AVPlayer()
    @State private var playerView: AVPlayerView?
    @State private var look = ClipLook()
    @State private var muted = false
    @State private var trim: CMTimeRange?
    @State private var duration: Double = 0
    @State private var previews: [FilterPreset: NSImage] = [:]
    @State private var exporting: String?
    @State private var progress: Double = 0
    @State private var lookTask: Task<Void, Never>?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 12) {
                EditorHeader(model: model, item: item)
                PlayerSurface(player: player) { playerView = $0 }
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.1)))
                filterStrip
            }
            sidebar.frame(width: 260)
        }
        .task(id: item.url) { await load() }
        .onDisappear {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        .onChange(of: look) { _, new in scheduleLook(new) }
        .onChange(of: muted) { _, m in player.isMuted = m }
    }

    private var filterStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(FilterPreset.allCases) { p in
                    Button { withAnimation(DB.snappy) { look.preset = p } } label: {
                        VStack(spacing: 5) {
                            ZStack {
                                if let img = previews[p] {
                                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                                } else {
                                    Rectangle().fill(.white.opacity(0.06))
                                }
                            }
                            .frame(width: 78, height: 50)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(look.preset == p ? DB.accent : .white.opacity(0.12), lineWidth: look.preset == p ? 2 : 0.5))
                            .scaleEffect(look.preset == p ? 1.05 : 1)
                            Text(p.rawValue)
                                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(look.preset == p ? .primary : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4).padding(.horizontal, 2)
        }
        .scrollIndicators(.never)
        .frame(height: 78)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Trim", symbol: "timeline.selection", trailing: trimLabel)
                HStack(spacing: 8) {
                    PillButton(title: "Trim…", symbol: "scissors") { beginTrim() }
                    if trim != nil {
                        PillButton(title: "Reset", symbol: "arrow.uturn.backward") { resetTrim() }
                    }
                }
                Toggle(isOn: $muted) {
                    Label("Mute audio", systemImage: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .toggleStyle(.switch).controlSize(.small)
            }
            .padding(14).card()

            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Adjust", symbol: "dial.medium", trailing: look.isIdentity ? nil : "edited")
                AdjustSlider(label: "Exposure", symbol: "sun.max", value: $look.exposure, range: -1...1, neutral: 0)
                AdjustSlider(label: "Contrast", symbol: "circle.lefthalf.filled", value: $look.contrast, range: 0.7...1.4, neutral: 1)
                AdjustSlider(label: "Saturation", symbol: "drop.halffull", value: $look.saturation, range: 0...2, neutral: 1)
                AdjustSlider(label: "Warmth", symbol: "thermometer.sun", value: $look.warmth, range: -1...1, neutral: 0)
                if !look.isIdentity {
                    Button("Reset look") { withAnimation(DB.snappy) { look = ClipLook() } }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(DB.accent)
                }
            }
            .padding(14).card()

            if let exporting {
                VStack(alignment: .leading, spacing: 6) {
                    Text(exporting).font(.system(size: 12, weight: .semibold, design: .rounded))
                    ProgressView(value: progress).tint(DB.accent)
                }
                .padding(14).card()
                .transition(.scale.combined(with: .opacity))
            } else {
                VStack(spacing: 6) {
                    PrimaryButton(title: needsRender ? "Export edited clip" : "Save copy", symbol: "square.and.arrow.down.fill") {
                        Task { await export(gif: false) }
                    }
                    HStack(spacing: 6) {
                        ActionRow(symbol: "photo.on.rectangle", title: "GIF") { Task { await export(gif: true) } }
                        ActionRow(symbol: "doc.on.doc", title: "Copy") {
                            ClipLibrary.copyToPasteboard(item.url)
                            model.showToast(Toast(symbol: "doc.on.doc.fill", title: "Clip copied", subtitle: "Paste it into Discord, Messages…", tint: DB.accent), seconds: 1.8)
                        }
                    }
                    ShareRow(url: item.url)
                    HStack(spacing: 6) {
                        ActionRow(symbol: "folder", title: "Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                        ActionRow(symbol: "trash", title: "Delete") {
                            player.pause()
                            model.library.trash(item)
                            withAnimation(DB.spring) { model.editingClip = nil }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 46)
        .animation(DB.spring, value: exporting)
    }

    private var needsRender: Bool { !look.isIdentity || muted || trim != nil }

    private var trimLabel: String {
        guard let trim else { return duration > 0 ? Fmt.clock(duration) : "" }
        return "\(Fmt.clock(trim.start.seconds)) – \(Fmt.clock(trim.end.seconds))"
    }

    // MARK: Loading

    private func load() async {
        let asset = AVURLAsset(url: item.url)
        duration = (try? await asset.load(.duration).seconds) ?? 0
        let playerItem = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: playerItem)
        player.isMuted = muted
        player.play()
        await makePreviews(asset)
    }

    /// One frame, rendered small once per preset.
    private func makePreviews(_ asset: AVAsset) async {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 200, height: 200)
        guard let cg = try? await gen.image(at: CMTime(seconds: min(1, duration / 2), preferredTimescale: 600)).image else { return }
        let base = CIImage(cgImage: cg)
        let rendered = await Task.detached(priority: .utility) { () -> [(FilterPreset, CGImage)] in
            let ctx = CIContext(options: [.cacheIntermediates: false])
            return FilterPreset.allCases.compactMap { p in
                var l = ClipLook(); l.preset = p
                return ctx.createCGImage(l.apply(base), from: base.extent).map { (p, $0) }
            }
        }.value
        for (p, img) in rendered { previews[p] = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height)) }
    }

    private func scheduleLook(_ new: ClipLook) {
        lookTask?.cancel()
        lookTask = Task {
            try? await Task.sleep(for: .milliseconds(90))   // coalesce slider drags
            guard !Task.isCancelled, let item = player.currentItem else { return }
            if new.isIdentity {
                item.videoComposition = nil
            } else if let comp = try? await new.videoComposition(for: item.asset), !Task.isCancelled {
                item.videoComposition = comp
            }
        }
    }

    // MARK: Trim

    private func beginTrim() {
        guard let pv = playerView, pv.canBeginTrimming else { return }
        pv.beginTrimming { result in
            guard result == .okButton, let item = player.currentItem else { return }
            let start = item.reversePlaybackEndTime.isValid ? item.reversePlaybackEndTime : .zero
            let end = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime : CMTime(seconds: duration, preferredTimescale: 600)
            withAnimation(DB.snappy) {
                trim = (start.seconds > 0.05 || end.seconds < duration - 0.05) ? CMTimeRange(start: start, end: end) : nil
            }
        }
    }

    private func resetTrim() {
        player.currentItem?.reversePlaybackEndTime = .invalid
        player.currentItem?.forwardPlaybackEndTime = .invalid
        withAnimation(DB.snappy) { trim = nil }
    }

    // MARK: Export

    private func export(gif: Bool) async {
        player.pause()
        exporting = gif ? "Making GIF…" : "Exporting…"
        progress = 0
        defer { exporting = nil }
        let suffix = gif ? "gif" : "mp4"
        let out = model.library.newURL(prefix: item.name + (gif ? "" : " edit"), ext: suffix)
        do {
            if gif {
                try await ClipRenderer.gif(source: item.url, range: trim, look: look, to: out) { p in
                    Task { @MainActor in progress = p }
                }
            } else {
                try await ClipRenderer.video(source: item.url, range: trim, look: look, mute: muted, to: out) { p in
                    Task { @MainActor in progress = p }
                }
            }
            model.library.add(out)
            let thumb = await model.library.thumbnail(ClipItem(url: out))
            model.showToast(Toast(symbol: "checkmark.circle.fill", title: gif ? "GIF ready" : "Clip exported", subtitle: out.lastPathComponent,
                                  tint: DB.mint, thumbnail: thumb, action: .openClip(out)))
        } catch {
            model.showToast(Toast(symbol: "exclamationmark.triangle.fill", title: "Export failed", subtitle: error.localizedDescription, tint: DB.rec), seconds: 5)
        }
    }
}

/// Offline rendering for the editor. Streams frames; never holds the whole clip in memory.
enum ClipRenderer {
    static func video(source: URL, range: CMTimeRange?, look: ClipLook, mute: Bool, to out: URL,
                      progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: source)
        let full = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
        let span = range ?? full
        let comp = AVMutableComposition()
        for track in try await asset.load(.tracks) where track.mediaType == .video || (!mute && track.mediaType == .audio) {
            let t = comp.addMutableTrack(withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid)
            let tr = CMTimeRangeGetIntersection(span, otherRange: try await track.load(.timeRange))
            if tr.duration > .zero { try t?.insertTimeRange(tr, of: track, at: CMTimeSubtract(tr.start, span.start)) }
        }
        let preset = look.isIdentity ? AVAssetExportPresetPassthrough : AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: comp, presetName: preset) else {
            throw NSError(domain: "DevBoard", code: 10, userInfo: [NSLocalizedDescriptionKey: "Export unavailable"])
        }
        if !look.isIdentity { session.videoComposition = try await look.videoComposition(for: comp) }
        let watcher = Task {
            for await state in session.states(updateInterval: 0.1) {
                if case .exporting(let p) = state { progress(p.fractionCompleted) }
            }
        }
        defer { watcher.cancel() }
        try await session.export(to: out, as: .mp4)
    }

    /// 12 fps, 540 px wide GIF; frames are generated and written one at a time.
    static func gif(source: URL, range: CMTimeRange?, look: ClipLook, to out: URL,
                    progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: source)
        let dur = try await asset.load(.duration)
        let span = range ?? CMTimeRange(start: .zero, duration: dur)
        let fps = 12.0
        let count = max(1, min(Int(span.duration.seconds * fps), 12 * 60))
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 540, height: 540)
        gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 24)
        gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 24)
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw NSError(domain: "DevBoard", code: 11, userInfo: [NSLocalizedDescriptionKey: "Couldn't create GIF"])
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
        let ctx = CIContext(options: [.cacheIntermediates: false])
        for i in 0..<count {
            try Task.checkCancellation()
            let t = CMTimeAdd(span.start, CMTime(seconds: Double(i) / fps, preferredTimescale: 600))
            guard var cg = try? await gen.image(at: t).image else { continue }
            if !look.isIdentity {
                let ci = CIImage(cgImage: cg)
                if let r = ctx.createCGImage(look.apply(ci), from: ci.extent) { cg = r }
            }
            CGImageDestinationAddImage(dest, cg, frameProps)
            progress(Double(i + 1) / Double(count))
        }
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "DevBoard", code: 12, userInfo: [NSLocalizedDescriptionKey: "Couldn't write GIF"])
        }
    }
}

// MARK: Pieces

private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    let onMake: (AVPlayerView) -> Void

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .floating
        v.showsFullScreenToggleButton = false
        v.allowsPictureInPicturePlayback = false
        v.videoGravity = .resizeAspect
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        DispatchQueue.main.async { onMake(v) }
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) {
        if v.player !== player { v.player = player }
    }
}

private struct AdjustSlider: View {
    let label: String
    let symbol: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let neutral: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Label(label, systemImage: symbol).font(.system(size: 11.5, weight: .semibold, design: .rounded))
                Spacer()
                Text(String(format: "%+.2f", value - neutral)).font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .monospacedDigit().foregroundStyle(value == neutral ? .tertiary : .secondary)
            }
            Slider(value: $value, in: range).controlSize(.mini).tint(DB.accent)
                .onTapGesture(count: 2) { value = neutral }
        }
    }
}

struct PillButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .padding(.horizontal, 12).frame(height: 28)
                .background(Capsule().fill(.white.opacity(hover ? 0.16 : 0.08)))
                .contentShape(Capsule())
        }
        .buttonStyle(PressScale())
        .onHover { h in withAnimation(DB.snappy) { hover = h } }
    }
}

struct PrimaryButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 38)
                .background(Capsule().fill(LinearGradient(colors: [DB.accent, DB.violet], startPoint: .leading, endPoint: .trailing)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
                .shadow(color: DB.accent.opacity(hover ? 0.5 : 0.25), radius: hover ? 12 : 6)
                .contentShape(Capsule())
        }
        .buttonStyle(PressScale())
        .onHover { h in withAnimation(DB.snappy) { hover = h } }
    }
}
