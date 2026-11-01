import AVFoundation
import AppKit
import ImageIO
import Observation
import UniformTypeIdentifiers

struct ClipItem: Identifiable, Hashable {
    enum Kind { case video, image }
    let url: URL
    let kind: Kind
    let date: Date
    let size: Int64
    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }

    init(url: URL) {
        self.url = url
        let ext = url.pathExtension.lowercased()
        kind = ["png", "jpg", "jpeg", "heic", "tiff", "gif"].contains(ext) ? .image : .video
        let v = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
        date = v?.creationDate ?? .distantPast
        size = Int64(v?.fileSize ?? 0)
    }
}

/// Files under ~/Movies/DevBoard. Thumbnails are small, generated on demand and kept in a bounded cache.
@MainActor @Observable
final class ClipLibrary {
    let root: URL
    let clipsDir: URL
    let shotsDir: URL
    private(set) var items: [ClipItem] = []

    @ObservationIgnored private let thumbs = NSCache<NSURL, NSImage>()
    @ObservationIgnored private var durations: [URL: Double] = [:]

    init() {
        root = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("DevBoard")
        clipsDir = root.appendingPathComponent("Clips")
        shotsDir = root.appendingPathComponent("Screenshots")
        for dir in [clipsDir, shotsDir] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        thumbs.countLimit = 150
        thumbs.totalCostLimit = 24 * 1024 * 1024
    }

    func reload() {
        let fm = FileManager.default
        var found: [ClipItem] = []
        for dir in [clipsDir, shotsDir] {
            let urls = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
                                                     options: [.skipsHiddenFiles])) ?? []
            found += urls.filter { ["mp4", "mov", "m4v", "png", "jpg", "jpeg", "heic", "gif"].contains($0.pathExtension.lowercased()) }
                .map(ClipItem.init(url:))
        }
        items = found.sorted { $0.date > $1.date }
    }

    func add(_ url: URL) {
        items.removeAll { $0.url == url }
        items.insert(ClipItem(url: url), at: 0)
    }

    func trash(_ item: ClipItem) {
        try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
        items.removeAll { $0.url == item.url }
        thumbs.removeObject(forKey: item.url as NSURL)
    }

    func newURL(prefix: String, ext: String, screenshot: Bool = false) -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = "\(prefix) \(f.string(from: .now))"
        let dir = screenshot ? shotsDir : clipsDir
        var url = dir.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }

    func cachedThumbnail(_ item: ClipItem) -> NSImage? { thumbs.object(forKey: item.url as NSURL) }
    func duration(_ item: ClipItem) -> Double? { durations[item.url] }

    func thumbnail(_ item: ClipItem, maxPixel: CGFloat = 480) async -> NSImage? {
        if let t = thumbs.object(forKey: item.url as NSURL) { return t }
        let url = item.url
        let result: (CGImage, Double?)?
        switch item.kind {
        case .image:
            result = await Task.detached(priority: .utility) {
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                          kCGImageSourceCreateThumbnailFromImageAlways: true,
                          kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                          kCGImageSourceCreateThumbnailWithTransform: true,
                      ] as CFDictionary) else { return nil }
                return (img, nil)
            }.value
        case .video:
            let asset = AVURLAsset(url: url)
            let dur = try? await asset.load(.duration).seconds
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: maxPixel, height: maxPixel)
            let at = CMTime(seconds: min(0.5, (dur ?? 1) / 2), preferredTimescale: 600)
            if let img = try? await gen.image(at: at).image { result = (img, dur) } else { result = nil }
        }
        guard let (cg, dur) = result else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        thumbs.setObject(image, forKey: url as NSURL, cost: cg.width * cg.height * 4)
        if let dur { durations[url] = dur }
        return image
    }

    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }

    /// File URL plus, for images, the raw bytes (no decoded copy is made).
    static func copyToPasteboard(_ url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
           let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
            item.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
        }
        pb.writeObjects([item])
    }

    /// Decodes an image no larger than `maxPixel` on its long edge.
    nonisolated static func downsampled(_ url: URL, maxPixel: Int) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
