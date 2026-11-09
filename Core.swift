// Core.swift — settings, link detection, and the download manager (queue + yt-dlp).

import AppKit
import Combine

// MARK: - Settings

enum Quality: String, CaseIterable, Identifiable {
    case best, p2160, p1440, p1080, p720, p480, compatible
    var id: String { rawValue }

    var label: String {
        switch self {
        case .best: "Best available"
        case .p2160: "Up to 4K (2160p)"
        case .p1440: "Up to 1440p"
        case .p1080: "Up to 1080p"
        case .p720: "Up to 720p"
        case .p480: "Up to 480p"
        case .compatible: "Most compatible (H.264, ≤1080p)"
        }
    }

    var shortLabel: String {
        switch self {
        case .best: "Best"
        case .compatible: "H.264"
        default: "≤\(height!)p"
        }
    }

    var height: Int? {
        switch self {
        case .p2160: 2160
        case .p1440: 1440
        case .p1080: 1080
        case .p720: 720
        case .p480: 480
        case .compatible: 1080
        case .best: nil
        }
    }

    /// yt-dlp format selector. Prefers mp4/m4a so the merge needs no re-encode.
    var selector: String {
        switch self {
        case .best:
            return "bv*[ext=mp4]+ba[ext=m4a]/bv*+ba/b"
        case .compatible:
            return "bv*[vcodec^=avc1][height<=1080]+ba[ext=m4a]/b[vcodec^=avc1][height<=1080]/bv*[height<=1080]+ba/b"
        default:
            let h = height!
            return "bv*[height<=\(h)][ext=mp4]+ba[ext=m4a]/bv*[height<=\(h)]+ba/b[height<=\(h)]/b"
        }
    }
}

let audioSelector = "ba[ext=m4a]/ba"

enum AskQuality: String, CaseIterable, Identifiable {
    case never, streams, always
    var id: String { rawValue }
    var label: String {
        switch self {
        case .never: "Never (use default quality)"
        case .streams: "For streams (HLS/DASH)"
        case .always: "For every download"
        }
    }
}

enum ClipMode: String, CaseIterable, Identifiable {
    case ask, auto, off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .ask: "Ask before downloading"
        case .auto: "Download automatically"
        case .off: "Do nothing"
        }
    }
}

final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    @Published var quality: Quality { didSet { d.set(quality.rawValue, forKey: "quality") } }
    @Published var askQuality: AskQuality { didSet { d.set(askQuality.rawValue, forKey: "askQuality") } }
    @Published var clipMode: ClipMode { didSet { d.set(clipMode.rawValue, forKey: "clipMode") } }
    @Published var anyLink: Bool { didSet { d.set(anyLink, forKey: "anyLink") } }
    @Published var maxConcurrent: Int { didSet { d.set(maxConcurrent, forKey: "maxConcurrent") } }
    @Published var folder: String { didSet { d.set(folder, forKey: "folder") } }

    /// Shared secret for clipload:// links. The Stream Grabber userscript knows it, so its
    /// requests skip the confirmation; links from anywhere else are confirmed first.
    let token: String

    private init() {
        quality = Quality(rawValue: d.string(forKey: "quality") ?? "") ?? .best
        askQuality = AskQuality(rawValue: d.string(forKey: "askQuality") ?? "") ?? .streams
        // Carry over the settings from Clipload 1.x.
        let legacyMode: ClipMode = d.bool(forKey: "paused") ? .off : (d.bool(forKey: "auto") ? .auto : .ask)
        clipMode = ClipMode(rawValue: d.string(forKey: "clipMode") ?? "") ?? legacyMode
        anyLink = d.bool(forKey: "anyLink")
        let n = d.integer(forKey: "maxConcurrent")
        maxConcurrent = n > 0 ? n : 3
        folder = d.string(forKey: "folder")
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/Videos").path
        if let t = d.string(forKey: "token"), !t.isEmpty {
            token = t
        } else {
            token = UUID().uuidString
            d.set(token, forKey: "token")
        }
    }
}

// MARK: - Tools and links

let toolPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
let ytdlpPath = ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp"]
    .first { FileManager.default.isExecutableFile(atPath: $0) }

func toolEnvironment() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = toolPath + (env["PATH"].map { ":" + $0 } ?? "")
    return env
}

let videoHosts = [
    "youtube.com", "youtu.be", "vimeo.com", "x.com", "twitter.com", "tiktok.com",
    "instagram.com", "facebook.com", "fb.watch", "reddit.com", "redd.it", "twitch.tv",
    "dailymotion.com", "streamable.com", "bilibili.com", "bilibili.tv", "soundcloud.com",
    "bsky.app", "threads.net", "threads.com", "kick.com", "rumble.com", "9gag.com",
    "imgur.com", "vk.com", "ok.ru", "nicovideo.jp", "bandcamp.com", "loom.com",
    "pinterest.com", "tumblr.com", "archive.org", "ted.com", "odysee.com", "bitchute.com",
]
let mediaExtensions: Set<String> = ["mp4", "m4v", "mov", "webm", "mkv", "m3u8", "mpd", "mp3", "m4a"]

func isVideoLink(_ url: URL) -> Bool {
    if mediaExtensions.contains(url.pathExtension.lowercased()) { return true }
    guard let host = url.host?.lowercased() else { return false }
    // A bare homepage ("youtube.com/") is not a video.
    guard url.path.count > 1 || url.query != nil else { return false }
    return videoHosts.contains { host == $0 || host.hasSuffix("." + $0) }
}

func isStreamLink(_ url: URL) -> Bool {
    let s = url.absoluteString.lowercased()
    return ["m3u8", "mpd"].contains(url.pathExtension.lowercased()) ||
        s.contains(".m3u8") || s.contains(".mpd") || s.contains("format=m3u8") || s.contains("format=mpd")
}

func linkFrom(_ text: String) -> URL? {
    let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !s.isEmpty, s.count < 2000, !s.contains(where: \.isWhitespace),
          let url = URL(string: s), let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https", url.host != nil else { return nil }
    return url
}

/// Turns a page title into something safe for a yt-dlp output template.
func fileSafe(_ s: String) -> String {
    var t = s
    for (bad, good) in [("/", "-"), (":", " -"), ("\\", "-"), ("\n", " "), ("%", "%%")] {
        t = t.replacingOccurrences(of: bad, with: good)
    }
    t = t.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
    return t.isEmpty ? "video" : String(t.prefix(120))
}

func formatBytes(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}

// MARK: - Requests, formats, jobs

/// What to download. Streams sent from the browser also carry the page they played on
/// (many HLS servers reject requests without the right Referer) and the page title.
struct Request {
    let url: URL
    var referer: URL? = nil
    var title: String? = nil

    var refererArgs: [String] {
        guard let ref = referer else { return [] }
        var args = ["--referer", ref.absoluteString]
        if let scheme = ref.scheme, let host = ref.host {
            let port = ref.port.map { ":\($0)" } ?? ""
            args += ["--add-headers", "Origin:\(scheme)://\(host)\(port)"]
        }
        return args
    }
}

/// One selectable quality, found by asking yt-dlp what the stream/page offers.
struct StreamFormat: Identifiable, Hashable {
    let id: String          // yt-dlp format_id
    let height: Int
    let fps: Double?
    let tbr: Double?        // kbit/s
    let vcodec: String?
    let hasAudio: Bool
    let size: Int64?

    var codecName: String? {
        guard let c = vcodec?.lowercased() else { return nil }
        if c.hasPrefix("avc") || c.hasPrefix("h264") { return "H.264" }
        if c.hasPrefix("av01") { return "AV1" }
        if c.hasPrefix("hvc") || c.hasPrefix("hev") || c.hasPrefix("h265") { return "HEVC" }
        if c.hasPrefix("vp9") || c.hasPrefix("vp09") { return "VP9" }
        return nil
    }

    var resolution: String {
        let f = fps.map { $0 > 31 ? "\(Int($0.rounded()))" : "" } ?? ""
        return "\(height)p\(f)"
    }

    var label: String {
        var parts = [resolution]
        if let c = codecName { parts.append(c) }
        if let size { parts.append("~" + formatBytes(size)) }
        else if let tbr { parts.append(String(format: "%.1f Mbps", tbr / 1000)) }
        return parts.joined(separator: " · ")
    }

    var selector: String { hasAudio ? id : "\(id)+ba/\(id)" }

    /// Prefer codecs QuickTime plays natively when two formats share a resolution.
    var codecRank: Int {
        switch codecName {
        case "AV1", "HEVC": 3
        case "H.264", nil: 2
        default: 1
        }
    }
}

func parseFormats(_ json: [String: Any]) -> [StreamFormat] {
    guard let list = json["formats"] as? [[String: Any]] else { return [] }
    let duration = (json["duration"] as? NSNumber)?.doubleValue
    var byHeight: [Int: StreamFormat] = [:]
    for f in list {
        let vcodec = f["vcodec"] as? String
        guard vcodec != "none", let h = (f["height"] as? NSNumber)?.intValue, h > 0,
              let id = f["format_id"] as? String else { continue }
        let acodec = f["acodec"] as? String
        let tbr = (f["tbr"] as? NSNumber)?.doubleValue
        var size = (f["filesize"] as? NSNumber)?.int64Value ?? (f["filesize_approx"] as? NSNumber)?.int64Value
        if size == nil, let tbr, let duration { size = Int64(tbr * 1000 / 8 * duration) }
        let fmt = StreamFormat(id: id, height: h, fps: (f["fps"] as? NSNumber)?.doubleValue, tbr: tbr,
                               vcodec: vcodec, hasAudio: acodec != nil && acodec != "none", size: size)
        if let cur = byHeight[h],
           (cur.codecRank, cur.tbr ?? 0) >= (fmt.codecRank, fmt.tbr ?? 0) { continue }
        byHeight[h] = fmt
    }
    return byHeight.values.sorted { $0.height > $1.height }
}

enum JobState: Equatable {
    case probing    // asking yt-dlp which qualities exist
    case choosing   // waiting for the user to pick a quality
    case queued
    case running
    case done
    case failed
    case cancelled

    var isFinished: Bool { self == .done || self == .failed || self == .cancelled }
}

final class Job: ObservableObject, Identifiable {
    let id = UUID()
    let req: Request
    let audio: Bool
    @Published var title: String
    @Published var state: JobState
    @Published var percent: Double = 0
    @Published var detail = ""
    @Published var file: String?
    @Published var error = ""
    @Published var formats: [StreamFormat] = []
    @Published var chosen = ""
    @Published var qualityLabel: String
    var selector: String
    var process: Process?
    var outBuffer = ""
    var cancelled = false
    var date = Date()

    init(_ req: Request, audio: Bool, quality: Quality, state: JobState = .queued) {
        self.req = req
        self.audio = audio
        self.title = req.title ?? req.url.host ?? req.url.absoluteString
        self.state = state
        self.selector = audio ? audioSelector : quality.selector
        self.qualityLabel = audio ? "Audio" : quality.shortLabel
    }

    var host: String { req.url.host ?? "" }
}

/// Finished downloads are remembered between launches.
struct SavedJob: Codable {
    let title: String
    let file: String
    let url: String
    let date: Date
}

// MARK: - Download manager

final class Manager: ObservableObject {
    static let shared = Manager()

    @Published private(set) var jobs: [Job] = []   // newest first
    let settings = Settings.shared

    var onNeedsAttention: () -> Void = {}       // a job wants a quality choice
    var onFinished: (Job) -> Void = { _ in }
    var onActivity: () -> Void = {}            // progress / counts changed

    private var bag: Set<AnyCancellable> = []

    private init() {
        loadHistory()
        settings.$maxConcurrent.dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.pump() } }
            .store(in: &bag)
    }

    /// Job properties change on their own objects, so tell list-level views to refresh too.
    private func changed() {
        objectWillChange.send()
        onActivity()
    }

    var running: [Job] { jobs.filter { $0.state == .running } }
    var queuedCount: Int { jobs.filter { $0.state == .queued }.count }

    // MARK: Adding

    func add(_ req: Request, audio: Bool = false, quality: Quality? = nil) {
        guard ytdlpPath != nil else {
            toast.show("yt-dlp isn't installed", "Install it with: brew install yt-dlp ffmpeg")
            return
        }
        let q = quality ?? settings.quality
        let job = Job(req, audio: audio, quality: q)
        jobs.insert(job, at: 0)

        let ask: Bool
        switch settings.askQuality {
        case .never: ask = false
        case .streams: ask = isStreamLink(req.url)
        case .always: ask = true
        }
        if ask && !audio {
            probe(job, preferred: q)
        } else {
            pump()
        }
    }

    // MARK: Quality probing

    private func probe(_ job: Job, preferred: Quality) {
        job.state = .probing
        changed()

        let p = Process()
        p.executableURL = URL(fileURLWithPath: ytdlpPath!)
        p.arguments = ["-J", "--no-playlist", "--no-warnings"] + job.req.refererArgs + [job.req.url.absoluteString]
        p.environment = toolEnvironment()
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        job.process = p

        var errText = ""
        err.fileHandleForReading.readabilityHandler = { h in
            if let s = String(data: h.availableData, encoding: .utf8) { errText += s }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do { try p.run() } catch {
                DispatchQueue.main.async { self.fail(job, error.localizedDescription) }
                return
            }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            err.fileHandleForReading.readabilityHandler = nil
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let formats = json.map(parseFormats) ?? []
            let title = json?["title"] as? String

            DispatchQueue.main.async {
                job.process = nil
                if job.cancelled { return }
                guard p.terminationStatus == 0, json != nil else {
                    self.fail(job, Self.errorLine(errText) ?? "No downloadable video found.")
                    return
                }
                if job.req.title == nil, let title, !title.isEmpty { job.title = title }
                if formats.count <= 1 {
                    // Nothing to choose between; go straight to the queue.
                    job.state = .queued
                    self.pump()
                    return
                }
                job.formats = formats
                let target = preferred.height ?? Int.max
                job.chosen = (formats.first { $0.height <= target } ?? formats[0]).id
                job.state = .choosing
                self.changed()
                self.onNeedsAttention()
            }
        }
    }

    func confirm(_ job: Job) {
        guard job.state == .choosing, let f = job.formats.first(where: { $0.id == job.chosen }) else { return }
        job.selector = f.selector
        job.qualityLabel = f.resolution
        job.state = .queued
        pump()
    }

    // MARK: Queue

    func pump() {
        var slots = settings.maxConcurrent - running.count
        for job in jobs.reversed() where job.state == .queued {   // oldest first
            guard slots > 0 else { break }
            run(job)
            slots -= 1
        }
        changed()
    }

    private func run(_ job: Job) {
        let folder = URL(fileURLWithPath: settings.folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // Raw stream manifests have useless names ("master.m3u8"), so prefer the page title.
        let name = job.req.title.map { "\(fileSafe($0)).%(ext)s" } ?? "%(title).150B [%(id)s].%(ext)s"
        var args = [
            "-P", folder.path,
            "-o", name,
            "--no-playlist", "--embed-metadata",
            "--concurrent-fragments", "8",
            "--newline", "--progress", "--color", "never",
            "--progress-template", "download:PROG %(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s",
            "--print", "before_dl:TITLE %(title)s",
            "--print", "after_move:FILE %(filepath)s",
            "-f", job.selector,
        ]
        args += job.audio ? ["-x", "--audio-format", "m4a"] : ["--merge-output-format", "mp4"]
        args += job.req.refererArgs
        args.append(job.req.url.absoluteString)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: ytdlpPath!)
        p.arguments = args
        p.environment = toolEnvironment()
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err

        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.handleOutput(s, job) }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { if let line = Self.errorLine(s) { job.error = line } }
        }
        p.terminationHandler = { [weak self] proc in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async { self?.finished(job, status: proc.terminationStatus) }
        }

        job.process = p
        job.state = .running
        job.percent = 0
        job.detail = "Starting…"
        job.error = ""
        do {
            try p.run()
        } catch {
            fail(job, "Couldn't start yt-dlp: \(error.localizedDescription)")
        }
    }

    private func handleOutput(_ chunk: String, _ job: Job) {
        job.outBuffer += chunk
        var lines = job.outBuffer.components(separatedBy: "\n")
        job.outBuffer = lines.removeLast()
        for line in lines {
            if line.hasPrefix("PROG") {
                let parts = line.dropFirst(4).split(separator: "|", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                if let v = Double(parts[0].replacingOccurrences(of: "%", with: "")) { job.percent = v }
                let speed = parts.count > 1 ? parts[1] : ""
                let eta = parts.count > 2 ? parts[2] : ""
                var bits: [String] = []
                if !speed.isEmpty, !speed.contains("Unknown"), speed != "N/A" { bits.append(speed) }
                if !eta.isEmpty, !eta.contains("Unknown"), eta != "N/A" { bits.append("\(eta) left") }
                job.detail = bits.joined(separator: " · ")
            } else if line.hasPrefix("TITLE "), job.req.title == nil {
                job.title = String(line.dropFirst(6))
            } else if line.hasPrefix("FILE ") {
                job.file = String(line.dropFirst(5))
            }
        }
        changed()
    }

    private func finished(_ job: Job, status: Int32) {
        job.process = nil
        if job.cancelled {
            job.state = .cancelled
        } else if status == 0, job.file != nil {
            job.state = .done
            job.percent = 100
            job.date = Date()
            saveHistory()
            onFinished(job)
        } else {
            fail(job, job.error.isEmpty ? "No downloadable video found on that page." : job.error)
        }
        pump()
    }

    private func fail(_ job: Job, _ message: String) {
        job.process = nil
        job.state = .failed
        job.error = message
        onFinished(job)
        pump()
    }

    static func errorLine(_ s: String) -> String? {
        s.split(separator: "\n").last { $0.contains("ERROR") }
            .map { $0.replacingOccurrences(of: "ERROR: ", with: "") }
    }

    // MARK: User actions

    func cancel(_ job: Job) {
        switch job.state {
        case .running, .probing:
            job.cancelled = true
            job.process?.terminate()
            if job.state == .probing { job.state = .cancelled }
        case .queued, .choosing:
            job.state = .cancelled
        default:
            break
        }
        pump()
    }

    func cancelAll() {
        jobs.filter { !$0.state.isFinished }.forEach(cancel)
    }

    func retry(_ job: Job) {
        guard job.state == .failed || job.state == .cancelled else { return }
        job.cancelled = false
        job.error = ""
        job.percent = 0
        job.state = .queued
        pump()
    }

    func remove(_ job: Job) {
        if !job.state.isFinished { cancel(job) }
        jobs.removeAll { $0 === job }
        saveHistory()
        changed()
    }

    func clearFinished() {
        jobs.removeAll { $0.state.isFinished }
        saveHistory()
        changed()
    }

    // MARK: History

    private func saveHistory() {
        let saved = jobs.filter { $0.state == .done }.prefix(100).compactMap { j in
            j.file.map { SavedJob(title: j.title, file: $0, url: j.req.url.absoluteString, date: j.date) }
        }
        if let data = try? JSONEncoder().encode(Array(saved)) {
            UserDefaults.standard.set(data, forKey: "history")
        }
    }

    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: "history"),
              let saved = try? JSONDecoder().decode([SavedJob].self, from: data) else { return }
        jobs = saved.compactMap { s in
            guard let url = URL(string: s.url) else { return nil }
            let j = Job(Request(url: url, title: s.title), audio: false, quality: .best, state: .done)
            j.file = s.file
            j.date = s.date
            j.percent = 100
            return j
        }
    }

    // MARK: Maintenance

    /// Sites change their players often; a fresh yt-dlp fixes most failures.
    func updateYtdlp() {
        guard let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            toast.show("Homebrew not found", "Update yt-dlp however you installed it.")
            return
        }
        toast.show("Updating yt-dlp…", "This can take a minute.", timeout: 0)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: brew)
        p.arguments = ["upgrade", "yt-dlp"]
        p.environment = toolEnvironment()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { proc in
            DispatchQueue.main.async {
                if proc.terminationStatus == 0 {
                    toast.show("yt-dlp is up to date", "Try the download again.")
                } else {
                    toast.show("Update failed", "Run `brew upgrade yt-dlp` in Terminal to see why.")
                }
            }
        }
        try? p.run()
    }
}
