import AVFoundation
import AppKit
import Observation
import ScreenCaptureKit

enum ScreenshotKind { case region, window, screen }

/// Owns the single ScreenCaptureKit stream. Manual recordings and instant replay share it:
/// a recording just pins the rolling segments from its start time, so nothing is encoded twice.
@MainActor @Observable
final class CaptureEngine {
    enum StreamState: Equatable { case off, starting, running, failed(String) }

    private(set) var streamState: StreamState = .off
    private(set) var recordingSince: Date?
    private(set) var busy = false                 // exporting a clip
    private(set) var streamStartedAt: Date?
    var isRecording: Bool { recordingSince != nil }
    var replayArmed: Bool { streamState == .running && model.settings.replayEnabled }

    @ObservationIgnored private unowned let model: AppModel
    @ObservationIgnored private let pipeline = SegmentPipeline()
    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var recordingHostStart: CMTime?
    @ObservationIgnored private var restartTask: Task<Void, Never>?
    @ObservationIgnored private var activeKey: StreamKey?
    @ObservationIgnored private var syncChain: Task<Void, Never>?
    @ObservationIgnored private var permissionTask: Task<Void, Never>?

    /// Settings that require restarting the stream when they change.
    private struct StreamKey: Equatable {
        var display: UInt32, cursor: Bool, hideSelf: Bool, fps: Int, quality: ReplayQuality, audio: Bool, mic: Bool
    }

    private var wantedKey: StreamKey {
        StreamKey(display: settings.displayID, cursor: settings.showCursor, hideSelf: settings.hideSelfInCaptures,
                  fps: settings.fps, quality: settings.quality, audio: settings.systemAudio, mic: settings.microphone)
    }

    init(model: AppModel) {
        self.model = model
        pipeline.onStop = { [weak self] source, error in
            Task { @MainActor in self?.streamStopped(source, error) }
        }
    }

    private var settings: SettingsStore { model.settings }
    private var needsStream: Bool { settings.replayEnabled || isRecording }

    // MARK: Stream lifecycle

    /// Starts, restarts or stops the stream to match settings. Calls are serialised, so
    /// overlapping requests (settings toggles, wake, record) never start two streams.
    func syncStream(forceOff: Bool = false) async {
        let previous = syncChain
        let task = Task { @MainActor [weak self] in
            await previous?.value
            await self?.syncNow(forceOff: forceOff)
        }
        syncChain = task
        await task.value
    }

    private func syncNow(forceOff: Bool) async {
        pipeline.setKeepSeconds(Double(settings.replaySeconds))
        if forceOff || !needsStream {
            await stopStream()
            return
        }
        if stream != nil, activeKey == wantedKey { return }
        await stopStream(keepFiles: true)
        await startStream()
    }

    private func startStream() async {
        streamState = .starting
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let wanted = settings.displayID == 0 ? CGMainDisplayID() : settings.displayID
            guard let display = content.displays.first(where: { $0.displayID == wanted }) ?? content.displays.first else {
                throw NSError(domain: "DevBoard", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display found"])
            }
            let me = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: settings.hideSelfInCaptures ? me : [], exceptingWindows: [])

            let scale = Double(filter.pointPixelScale)
            let nativeW = Double(display.width) * scale, nativeH = Double(display.height) * scale
            let targetH = min(Double(settings.quality.rawValue), nativeH)
            let h = Int(targetH) & ~1
            let w = Int((targetH * nativeW / nativeH).rounded()) & ~1

            let cfg = SCStreamConfiguration()
            cfg.width = w
            cfg.height = h
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.fps))
            cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange   // half the memory of BGRA
            cfg.queueDepth = 5                                                    // small pool; one surface is held for idle repeats
            cfg.showsCursor = settings.showCursor
            cfg.colorSpaceName = CGColorSpace.sRGB
            cfg.capturesAudio = settings.systemAudio
            cfg.excludesCurrentProcessAudio = true
            cfg.sampleRate = 48_000
            cfg.channelCount = 2
            cfg.captureMicrophone = settings.microphone

            let enc = EncoderSettings(width: w, height: h, fps: settings.fps, bitrate: settings.bitrate,
                                      systemAudio: settings.systemAudio, microphone: settings.microphone)
            pipeline.configure(enc, keepSeconds: Double(settings.replaySeconds))

            let s = SCStream(filter: filter, configuration: cfg, delegate: pipeline)
            try s.addStreamOutput(pipeline, type: .screen, sampleHandlerQueue: pipeline.queue)
            if settings.systemAudio { try s.addStreamOutput(pipeline, type: .audio, sampleHandlerQueue: pipeline.queue) }
            if settings.microphone { try s.addStreamOutput(pipeline, type: .microphone, sampleHandlerQueue: pipeline.queue) }
            try await s.startCapture()
            stream = s
            activeKey = wantedKey
            streamState = .running
            streamStartedAt = .now
            permissionTask?.cancel()
            permissionTask = nil
        } catch {
            stream = nil
            activeKey = nil
            streamState = .failed(error.localizedDescription)
            reportPermissionOrError(error)
        }
    }

    private func stopStream(keepFiles: Bool = false) async {
        restartTask?.cancel()
        guard let s = stream else {
            if !keepFiles { pipeline.reset() }   // e.g. after a stream error: drop leftover footage
            if streamState != .off { streamState = .off }
            return
        }
        stream = nil
        activeKey = nil
        try? await s.stopCapture()
        if keepFiles { pipeline.streamEnded() } else { pipeline.reset() }
        streamState = .off
        streamStartedAt = nil
    }

    private func streamStopped(_ source: ObjectIdentifier, _ error: Error?) {
        // Ignore late callbacks from a stream we already replaced or stopped.
        guard let s = stream, ObjectIdentifier(s) == source else { return }
        stream = nil
        activeKey = nil
        streamStartedAt = nil
        let ns = error as NSError?
        if ns?.domain == SCStreamErrorDomain, ns?.code == SCStreamError.userStopped.rawValue {
            // Stopped from the system's menu-bar capture control: respect it.
            streamState = .off
            settings.replayEnabled = false
            Task { if isRecording { await stopRecording() } }
            model.showToast(Toast(symbol: "pause.circle", title: "Capture stopped", subtitle: "Instant replay is off until you turn it back on",
                                  tint: .secondary, action: .openSettings))
            return
        }
        streamState = .failed(ns?.localizedDescription ?? "Stream stopped")
        // Display sleep, resolution change, etc. Try again shortly while still wanted.
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, self.needsStream else { return }
            await self.syncStream()
        }
    }

    func shutdown() async {
        if isRecording { await stopRecording() }
        await syncStream(forceOff: true)
    }

    private func reportPermissionOrError(_ error: Error) {
        let ns = error as NSError
        let declined = ns.domain == SCStreamErrorDomain && ns.code == SCStreamError.userDeclined.rawValue
        if declined || !CGPreflightScreenCaptureAccess() {
            model.showToast(Toast(symbol: "lock.shield", title: "Screen Recording permission needed",
                                  subtitle: "Enable DevBoard in Privacy settings, then relaunch if it doesn't start",
                                  tint: DB.amber, action: .openPrivacySettings), seconds: 6)
            waitForPermission()
        } else {
            model.showToast(Toast(symbol: "exclamationmark.triangle.fill", title: "Capture failed",
                                  subtitle: ns.localizedDescription, tint: DB.rec), seconds: 5)
        }
    }

    /// Cheap 3 s poll; starts capture as soon as the permission is granted.
    private func waitForPermission() {
        guard permissionTask == nil else { return }
        permissionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                if CGPreflightScreenCaptureAccess() {
                    self.permissionTask = nil
                    if self.needsStream { await self.syncStream() }
                    return
                }
            }
        }
    }

    // MARK: Recording

    func toggleRecording() async {
        if isRecording { await stopRecording() } else { await startRecording() }
    }

    func startRecording() async {
        guard !isRecording else { return }
        recordingSince = .now   // set first so syncStream keeps the stream alive
        await syncStream()
        guard streamState == .running else {
            recordingSince = nil
            return
        }
        let start = SegmentPipeline.hostNow
        recordingHostStart = start
        pipeline.retain(from: start)
        model.showToast(Toast(symbol: "record.circle", title: "Recording", subtitle: "⌥⇧R or click the island to stop", tint: DB.rec), seconds: 1.8)
    }

    func stopRecording() async {
        guard let start = recordingHostStart, isRecording else { return }
        recordingSince = nil
        recordingHostStart = nil
        let url = model.library.newURL(prefix: "Recording", ext: "mp4")
        await exportClip(from: start, to: url, title: "Recording saved")
        pipeline.retain(from: nil)
        if !settings.replayEnabled { await syncStream() }
    }

    // MARK: Replay

    func saveReplay() async {
        if !settings.replayEnabled {
            model.showToast(Toast(symbol: "memories", title: "Instant replay is off",
                                  subtitle: "Turn it on in Settings or right-click the replay button", tint: DB.amber,
                                  action: .openSettings))
            return
        }
        if streamState != .running { await syncStream() }
        guard replayArmed, let started = streamStartedAt else {
            if case .failed(let reason) = streamState {
                model.showToast(Toast(symbol: "exclamationmark.triangle.fill", title: "Replay unavailable", subtitle: reason,
                                      tint: DB.amber, action: .openPrivacySettings), seconds: 5)
            }
            return
        }
        if Date().timeIntervalSince(started) < 1 {
            model.showToast(Toast(symbol: "hourglass", title: "Replay just started", subtitle: "Nothing buffered yet — try again in a moment", tint: DB.amber))
            return
        }
        let seconds = Double(settings.replaySeconds)
        let from = CMTimeSubtract(SegmentPipeline.hostNow, CMTime(seconds: seconds, preferredTimescale: 600))
        let url = model.library.newURL(prefix: "Replay", ext: "mp4")
        await exportClip(from: from, to: url, title: "Saved last \(Int(seconds))s")
    }

    private func exportClip(from start: CMTime, to url: URL, title: String) async {
        busy = true
        defer { busy = false }
        let segments = await withCheckedContinuation { (c: CheckedContinuation<[Segment], Never>) in
            pipeline.flush { c.resume(returning: $0) }
        }
        defer { pipeline.release() }
        do {
            try await Self.stitch(segments, from: start, to: url)
            model.library.add(url)
            let item = ClipItem(url: url)
            let thumb = await model.library.thumbnail(item)
            model.showToast(Toast(symbol: "checkmark.circle.fill", title: title, subtitle: "Click to trim, filter or share",
                                  tint: DB.mint, thumbnail: thumb, action: .openClip(url)), seconds: 4)
            NSSound(named: "Pop")?.play()
        } catch {
            model.showToast(Toast(symbol: "exclamationmark.triangle.fill", title: "Couldn't save clip",
                                  subtitle: error.localizedDescription, tint: DB.rec), seconds: 5)
        }
    }

    /// Concatenates the segments overlapping `[start, end]` without re-encoding.
    nonisolated static func stitch(_ segments: [Segment], from start: CMTime, to url: URL) async throws {
        let comp = AVMutableComposition()
        var tracks: [String: AVMutableCompositionTrack] = [:]
        var cursor = CMTime.zero
        for seg in segments where seg.end > start {
            let asset = AVURLAsset(url: seg.url)
            let assetTracks = try await asset.load(.tracks)
            guard let video = assetTracks.first(where: { $0.mediaType == .video }) else { continue }
            let vRange = try await video.load(.timeRange)
            let skip = max(.zero, CMTimeSubtract(start, seg.start))
            let local = CMTimeRange(start: CMTimeAdd(vRange.start, min(skip, vRange.duration)), end: vRange.end)
            guard local.duration > .zero else { continue }
            var audioIndex = 0
            for track in assetTracks {
                let key: String
                if track.mediaType == .video { key = "v" } else if track.mediaType == .audio { key = "a\(audioIndex)"; audioIndex += 1 } else { continue }
                if tracks[key] == nil {
                    tracks[key] = comp.addMutableTrack(withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid)
                }
                let tr = try await track.load(.timeRange)
                let clipped = CMTimeRangeGetIntersection(local, otherRange: tr)
                guard clipped.duration > .zero else { continue }
                try tracks[key]?.insertTimeRange(clipped, of: track, at: CMTimeAdd(cursor, CMTimeSubtract(clipped.start, local.start)))
            }
            cursor = CMTimeAdd(cursor, local.duration)
        }
        guard cursor > .zero else {
            throw NSError(domain: "DevBoard", code: 2, userInfo: [NSLocalizedDescriptionKey: "Nothing captured yet — wait a second and try again"])
        }
        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else {
            throw NSError(domain: "DevBoard", code: 3, userInfo: [NSLocalizedDescriptionKey: "Export unavailable"])
        }
        try await export.export(to: url, as: .mp4)
    }

    // MARK: Screenshots

    func screenshot(_ kind: ScreenshotKind) {
        let url = model.library.newURL(prefix: "Screenshot", ext: "png", screenshot: true)
        var args: [String]
        switch kind {
        case .region: args = ["-i"]
        case .window: args = ["-iW"]
        case .screen: args = ["-m"]
        }
        args.append(url.path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = args
        p.terminationHandler = { _ in
            Task { @MainActor [weak self] in self?.screenshotFinished(url) }
        }
        // Give the board time to animate away so it isn't in the shot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            do { try p.run() } catch {
                Task { @MainActor [weak self] in
                    self?.model.showToast(Toast(symbol: "exclamationmark.triangle.fill", title: "Screenshot failed",
                                                subtitle: error.localizedDescription, tint: DB.rec))
                }
            }
        }
    }

    private func screenshotFinished(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }   // user pressed Esc
        model.library.add(url)
        if settings.copyScreenshots { ClipLibrary.copyToPasteboard(url) }
        Task {
            let thumb = await model.library.thumbnail(ClipItem(url: url))
            model.showToast(Toast(symbol: "camera.fill", title: "Screenshot saved",
                                  subtitle: settings.copyScreenshots ? "Copied to clipboard" : url.lastPathComponent,
                                  tint: DB.accent, thumbnail: thumb, action: .openClip(url)))
        }
    }
}
