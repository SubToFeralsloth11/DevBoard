import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// One finished, playable chunk of the rolling capture. Times are host-clock (`CMClockGetHostTimeClock`).
struct Segment: Sendable {
    let url: URL
    let start: CMTime
    let end: CMTime
}

struct EncoderSettings: Sendable, Equatable {
    var width: Int
    var height: Int
    var fps: Int
    var bitrate: Int
    var systemAudio: Bool
    var microphone: Bool
}

/// Receives ScreenCaptureKit buffers and writes them, hardware-encoded, into short rolling files on disk.
/// Nothing but the encoder's own working set lives in memory: the replay buffer *is* the files.
/// All state is confined to `queue`.
final class SegmentPipeline: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "devboard.capture", qos: .userInitiated)
    private let dir: URL
    private let segmentLength = CMTime(seconds: 5, preferredTimescale: 600)

    private struct Writer {
        let url: URL
        let writer: AVAssetWriter
        let video: AVAssetWriterInput
        let audio: AVAssetWriterInput?
        let mic: AVAssetWriterInput?
        let start: CMTime
        var last: CMTime
    }

    private var settings: EncoderSettings?
    private var current: Writer?
    private var finished: [Segment] = []
    private var pendingFinishes = 0
    private var waiters: [([Segment]) -> Void] = []
    private var keepSeconds: Double = 30
    private var retainFrom: CMTime?
    private var holds = 0
    private var counter = 0

    var onStop: ((Error?) -> Void)?

    override init() {
        dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DevBoard/replay", isDirectory: true)
        super.init()
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    static var hostNow: CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }

    // MARK: Control (call from any thread)

    func configure(_ s: EncoderSettings, keepSeconds: Double) {
        queue.async {
            if s != self.settings, let cur = self.current {
                self.finish(cur, at: max(Self.hostNow, cur.last))
                self.current = nil
            }
            self.settings = s
            self.keepSeconds = keepSeconds
        }
    }

    func setKeepSeconds(_ v: Double) { queue.async { self.keepSeconds = v; self.prune() } }

    /// Starts protecting segments from pruning (manual recording).
    func retain(from t: CMTime?) { queue.async { self.retainFrom = t; self.prune() } }

    /// Closes the open segment and hands back every finished segment once all writers are done.
    /// The returned files are protected from pruning until `release()` is called.
    func flush(_ done: @escaping ([Segment]) -> Void) {
        queue.async {
            self.holds += 1
            if let cur = self.current {
                self.finish(cur, at: max(Self.hostNow, cur.last))
                self.current = nil
            }
            self.waiters.append(done)
            self.drainWaiters()
        }
    }

    func release() { queue.async { self.holds = max(0, self.holds - 1); self.prune() } }

    /// Stops writing and deletes everything (stream stopped).
    func reset() {
        queue.async {
            if let cur = self.current {
                cur.writer.cancelWriting()
                try? FileManager.default.removeItem(at: cur.url)
                self.current = nil
            }
            for s in self.finished { try? FileManager.default.removeItem(at: s.url) }
            self.finished.removeAll()
        }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid else { return }
        switch type {
        case .screen: handleVideo(sb)
        case .audio: handleAudio(sb, mic: false)
        case .microphone: handleAudio(sb, mic: true)
        @unknown default: break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async {
            if let cur = self.current {
                self.finish(cur, at: cur.last)
                self.current = nil
            }
        }
        onStop?(error)
    }

    // MARK: Writing (queue)

    private func handleVideo(_ sb: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let settings else { return }
        let pts = sb.presentationTimeStamp
        if let cur = current, CMTimeSubtract(pts, cur.start) >= segmentLength {
            finish(cur, at: pts)
            current = nil
        }
        if current == nil {
            current = makeWriter(at: pts, settings: settings)
        }
        guard var cur = current, pts >= cur.last else { return }
        if cur.video.isReadyForMoreMediaData, cur.video.append(sb) {
            cur.last = pts
            current = cur
        } else if cur.writer.status == .failed {
            cur.writer.cancelWriting()
            current = nil
        }
    }

    private func handleAudio(_ sb: CMSampleBuffer, mic: Bool) {
        guard let cur = current, let input = mic ? cur.mic : cur.audio else { return }
        guard sb.presentationTimeStamp >= cur.start, input.isReadyForMoreMediaData else { return }
        input.append(sb)
    }

    private func makeWriter(at pts: CMTime, settings s: EncoderSettings) -> Writer? {
        counter += 1
        let url = dir.appendingPathComponent(String(format: "seg-%06d.mp4", counter))
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return nil }
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: s.width,
            AVVideoHeightKey: s.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: s.bitrate,
                AVVideoExpectedSourceFrameRateKey: s.fps,
                AVVideoMaxKeyFrameIntervalDurationKey: 1.0,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { return nil }
        writer.add(video)

        func audioInput(channels: Int) -> AVAssetWriterInput? {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: channels == 2 ? 160_000 : 96_000,
            ])
            a.expectsMediaDataInRealTime = true
            guard writer.canAdd(a) else { return nil }
            writer.add(a)
            return a
        }
        let audio = s.systemAudio ? audioInput(channels: 2) : nil
        let mic = s.microphone ? audioInput(channels: 1) : nil

        guard writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: pts)
        return Writer(url: url, writer: writer, video: video, audio: audio, mic: mic, start: pts, last: pts)
    }

    private func finish(_ w: Writer, at end: CMTime) {
        guard w.writer.status == .writing else {
            w.writer.cancelWriting()
            try? FileManager.default.removeItem(at: w.url)
            return
        }
        w.writer.endSession(atSourceTime: max(end, w.last))
        w.video.markAsFinished()
        w.audio?.markAsFinished()
        w.mic?.markAsFinished()
        pendingFinishes += 1
        let seg = Segment(url: w.url, start: w.start, end: max(end, w.last))
        w.writer.finishWriting { [self] in
            queue.async {
                self.pendingFinishes -= 1
                if w.writer.status == .completed {
                    self.finished.append(seg)
                } else {
                    try? FileManager.default.removeItem(at: seg.url)
                }
                self.prune()
                self.drainWaiters()
            }
        }
    }

    private func drainWaiters() {
        guard pendingFinishes == 0, !waiters.isEmpty else { return }
        let snapshot = finished.sorted { $0.start < $1.start }
        let w = waiters
        waiters.removeAll()
        for done in w { done(snapshot) }
    }

    /// Drops segments older than the replay window unless a recording still needs them.
    private func prune() {
        guard holds == 0 else { return }
        let cutoff = CMTimeSubtract(Self.hostNow, CMTime(seconds: keepSeconds + 6, preferredTimescale: 600))
        finished.removeAll { seg in
            let needed = seg.end >= cutoff || (retainFrom.map { seg.end >= $0 } ?? false)
            if !needed { try? FileManager.default.removeItem(at: seg.url) }
            return !needed
        }
    }
}
