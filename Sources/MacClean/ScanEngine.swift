import Foundation
import UniformTypeIdentifiers

func bytes(_ size: Int64) -> String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
func under(_ path: String, _ root: String) -> Bool { path == root || path.hasPrefix(root + "/") }
func parentPath(_ path: String) -> String {
    guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
    return String(path[..<slash])
}

enum Risk: String, Codable, Sendable, CaseIterable {
    case regenerable = "可再生成", review = "需确认", personal = "个人文件", protected = "受保护"
}

struct ScanItem: Identifiable, Codable, Hashable, Sendable {
    var id: String { path }
    let path: String
    let name: String
    let isDirectory: Bool
    let logicalSize: Int64
    let allocatedSize: Int64
    let fileCount: Int
    let modified: Date?
    let type: String
    let complete: Bool
    var latestModified: Date? = nil
    var icon: String {
        if isDirectory { return "folder.fill" }
        switch type {
        case "视频": return "film.fill"
        case "图片": return "photo.fill"
        case "音频": return "waveform"
        case "安装包": return "shippingbox.fill"
        case "压缩包": return "doc.zipper"
        case "代码": return "chevron.left.forwardslash.chevron.right"
        case "本地模型": return "cpu.fill"
        case "数据库": return "cylinder.split.1x2.fill"
        case "虚拟磁盘": return "externaldrive.fill"
        default: return "doc.fill"
        }
    }
}

struct Candidate: Identifiable, Codable, Sendable {
    var id: String { item.path }
    let item: ScanItem
    let category: String
    let reason: String
    let risk: Risk
    var advice: Advice? = nil
}

struct ScanIssue: Identifiable, Codable, Sendable {
    var id: String { path + message }
    let path: String
    let message: String
}

struct ScanReport: Codable, Sendable {
    var roots: [String] = []
    var options = ScanOptions()
    var items: [ScanItem] = []
    var candidates: [Candidate] = []
    var issues: [ScanIssue] = []
    var visited = 0
    var skippedLinks = 0
    var skippedCloud = 0
    var limited = false
    var cancelled = false
    var elapsed: TimeInterval = 0
    var traversalElapsed: TimeInterval = 0
    var classificationElapsed: TimeInterval = 0
    var date = Date()
    var advicePolicy: String? = nil
    var adviceDate: Date? = nil
    var entryLimitReached: Bool? = nil
    var depthLimitReached: Bool? = nil
    var accessErrorCount: Int? = nil
    var excludedPaths: [String]? = nil
    var topItems: [ScanItem] { items.filter { roots.contains($0.path) } }
    var measuredSize: Int64 { topItems.reduce(0) { $0 + $1.logicalSize } }
    var isComplete: Bool { !limited && !cancelled && issues.isEmpty && skippedCloud == 0 }
}

struct ScanOptions: Codable, Sendable, Equatable {
    var maxDepth = 0
    var entryLimit = 0 // Zero means unlimited; cancellation remains available.
    var largeThreshold: Int64 = 100 * 1024 * 1024
    var oldDays = 90
}

struct ScanProgress: Sendable {
    let path: String
    let visited: Int
    let measured: Int64
}

final class ScanControl: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}

enum ScanEngine {
    private static let homePath = FileManager.default.homeDirectoryForCurrentUser.path
    static let categories = ["应用缓存", "开发缓存", "旧日志", "旧安装包", "陈旧下载", "大文件"]
    static func defaultRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        // Complete home includes hidden folders; the other roots cover shared and system data.
        let system = ["/Applications", "/Library", "/Users/Shared", "/usr", "/opt", "/private", "/System"]
        return [home] + system.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
    static func normalizedRoots(_ roots: [URL]) -> [URL] {
        var result: [URL] = []
        for url in roots.map(\.standardizedFileURL).sorted(by: { $0.path.count < $1.path.count }) {
            if !result.contains(where: { under(url.path, $0.path) }) { result.append(url) }
        }
        let minimal = Set(result.map(\.path))
        var seen = Set<String>()
        return roots.map(\.standardizedFileURL).filter { minimal.contains($0.path) && seen.insert($0.path).inserted }
    }
    static func type(for url: URL, directory: Bool) -> String {
        if directory { return url.pathExtension == "app" ? "应用" : "文件夹" }
        let ext = url.pathExtension.lowercased()
        let home = homePath
        if under(url.path, home + "/.ollama/models/blobs") { return "本地模型" }
        if ["dmg", "pkg", "iso"].contains(ext) { return "安装包" }
        if ["img", "qcow2", "vmdk", "vdi", "vhd", "vhdx", "sparseimage", "squashfs"].contains(ext) { return "虚拟磁盘" }
        if ["zip", "7z", "rar", "gz", "tar", "xz"].contains(ext) { return "压缩包" }
        if ["log", "crash", "ips"].contains(ext) { return "日志" }
        if ["doc", "docx", "xls", "xlsx", "ppt", "pptx", "key", "numbers", "pages", "md", "txt", "epub", "pdf"].contains(ext) { return "文档" }
        if ["gguf", "safetensors", "ckpt", "onnx", "pt", "pth"].contains(ext) { return "本地模型" }
        if ["sqlite", "sqlite3", "db"].contains(ext) { return "数据库" }
        if ["swift", "js", "ts", "tsx", "py", "go", "rs", "c", "h", "cpp", "json", "html", "css", "sh"].contains(ext) { return "代码" }
        if let t = UTType(filenameExtension: ext) {
            if t.conforms(to: .movie) { return "视频" }
            if t.conforms(to: .image) { return "图片" }
            if t.conforms(to: .audio) { return "音频" }
            if t.conforms(to: .text) || t.conforms(to: .pdf) { return "文档" }
        }
        return "其他"
    }
    static func scan(roots input: [URL], options: ScanOptions, control: ScanControl,
                     progress: @Sendable (ScanProgress) -> Void) -> ScanReport {
        let started = Date()
        let roots = normalizedRoots(input)
        var report = ScanReport(roots: roots.map(\.path), options: options)
        let fm = FileManager.default
        var lastProgress = Date.distantPast
        var measured: Int64 = 0
        report.accessErrorCount = 0
        report.excludedPaths = []
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .isPackageKey, .fileSizeKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .contentModificationDateKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        func issue(_ path: String, _ message: String) {
            report.accessErrorCount = (report.accessErrorCount ?? 0) + 1
            if report.issues.count < 250 { report.issues.append(ScanIssue(path: path, message: message)) }
        }
        func walk(_ inputURL: URL, depth: Int, insidePackage: Bool) -> ScanItem? {
            // Directory enumeration may return /private/var for a /var root.
            // Keep root and descendant identifiers in the same lexical form.
            let url = inputURL.standardizedFileURL
            if control.cancelled { report.cancelled = true; return nil }
            if under(url.path, "/System/Volumes") {
                if !(report.excludedPaths ?? []).contains(url.path) { report.excludedPaths?.append(url.path) }
                return nil // Do not double-count Data/Preboot/VM mirrors of startup volumes.
            }
            if options.entryLimit > 0 && report.visited >= options.entryLimit { report.limited = true; report.entryLimitReached = true; return nil }
            report.visited += 1
            if Date().timeIntervalSince(lastProgress) > 0.12 {
                progress(ScanProgress(path: url.path, visited: report.visited, measured: measured))
                lastProgress = Date()
            }
            let v: URLResourceValues
            do { v = try url.resourceValues(forKeys: keys) }
            catch { issue(url.path, error.localizedDescription); return nil }
            if v.isSymbolicLink == true { report.skippedLinks += 1; return nil }
            if v.isUbiquitousItem == true && v.ubiquitousItemDownloadingStatus == .notDownloaded {
                report.skippedCloud += 1; return nil
            }
            let directory = v.isDirectory == true
            var logical: Int64 = 0; var allocated: Int64 = 0; var count = 0; var complete = true
            var latest = v.contentModificationDate
            let package = insidePackage || v.isPackage == true || url.pathExtension == "app"
            if directory {
                if options.maxDepth > 0 && depth >= options.maxDepth { complete = false; report.limited = true; report.depthLimitReached = true }
                else {
                    do {
                        let children = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys)).sorted { $0.path < $1.path }
                        for child in children {
                            if control.cancelled || (options.entryLimit > 0 && report.visited >= options.entryLimit) { complete = false; report.cancelled = control.cancelled; if !control.cancelled { report.limited = true; report.entryLimitReached = true }; break }
                            if let sub = walk(child, depth: depth + 1, insidePackage: package) {
                                logical += sub.logicalSize; allocated += sub.allocatedSize; count += sub.fileCount
                                if !sub.complete { complete = false }
                                if let modified = sub.latestModified, latest == nil || modified > latest! { latest = modified }
                            } else { complete = false }
                        }
                    } catch { complete = false; issue(url.path, error.localizedDescription) }
                }
            } else if v.isRegularFile == true {
                logical = Int64(v.fileSize ?? 0); allocated = Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? v.fileSize ?? 0)
                count = 1; measured += logical
            } else { return nil }
            var item = ScanItem(path: url.path, name: url.lastPathComponent, isDirectory: directory, logicalSize: logical, allocatedSize: allocated,
                                fileCount: count, modified: v.contentModificationDate, type: type(for: url, directory: directory), complete: complete)
            item.latestModified = latest
            if !insidePackage { report.items.append(item) }
            return item
        }
        for root in roots { _ = walk(root, depth: 0, insidePackage: false) }
        report.items.sort { $0.logicalSize > $1.logicalSize }
        report.traversalElapsed = Date().timeIntervalSince(started)
        progress(ScanProgress(path: "正在判断规则并整理候选…", visited: report.visited, measured: measured))
        let classificationStarted = Date()
        report.cancelled = control.cancelled
        report.candidates = classify(report.items, roots: roots, options: options, now: started, control: control)
        report.classificationElapsed = Date().timeIntervalSince(classificationStarted)
        report.cancelled = control.cancelled
        report.elapsed = Date().timeIntervalSince(started)
        progress(ScanProgress(path: "扫描结束", visited: report.visited, measured: measured))
        return report
    }
    static func classify(_ items: [ScanItem], roots: [URL], options: ScanOptions, now: Date, control: ScanControl? = nil) -> [Candidate] {
        let home = homePath
        let cacheRoots = [home + "/Library/Caches"]
        let devRoots = [home + "/Library/Developer/Xcode/DerivedData", home + "/.npm/_cacache", home + "/.cache/pip"]
        let logRoot = home + "/Library/Logs"
        let downloadRoot = home + "/Downloads"
        var result: [Candidate] = []
        var covered = Set<String>()
        let cacheDomains = cacheRoots + devRoots
        for item in items.sorted(by: { $0.path.utf8.count < $1.path.utf8.count }) {
            if control?.cancelled == true { break }
            guard item.logicalSize > 0 else { continue }
            // All aggregate candidates are direct children of a known cache root.
            // Derive their top child once instead of comparing every file against every candidate.
            if let domain = cacheDomains.first(where: { under(item.path, $0) }), item.path != domain {
                let suffix = item.path.dropFirst(domain.count + 1)
                if let first = suffix.split(separator: "/", maxSplits: 1).first, covered.contains(domain + "/" + first) { continue }
            }
            let parent = parentPath(item.path)
            let age = item.modified.map { max(0, Int(now.timeIntervalSince($0) / 86400)) } ?? 0
            var candidate: Candidate?
            if item.complete && (cacheRoots + devRoots).contains(parent) {
                let dev = devRoots.contains(parent)
                candidate = Candidate(item: item, category: dev ? "开发缓存" : "应用缓存", reason: dev ? "已知构建/包管理缓存目录；重新构建或下载可再生成。请先停止相关任务。" : "用户级缓存目录，\(item.fileCount) 个文件；不保证内容无用，请先退出对应应用。", risk: .regenerable)
            } else if !item.isDirectory {
                if under(item.path, logRoot), item.type == "日志", age >= 30 {
                    candidate = Candidate(item: item, category: "旧日志", reason: "日志文件，距最后修改 \(age) 天（规则 ≥30 天）；确认不再用于排错。", risk: .review)
                } else if under(item.path, downloadRoot), item.type == "安装包", age >= 14 {
                    candidate = Candidate(item: item, category: "旧安装包", reason: "下载目录中的安装包，距最后修改 \(age) 天（规则 ≥14 天）；确认安装完成。", risk: .review)
                } else if under(item.path, downloadRoot), age >= options.oldDays {
                    candidate = Candidate(item: item, category: "陈旧下载", reason: "下载目录文件，距最后修改 \(age) 天（规则 ≥\(options.oldDays) 天）；修改时间不等于使用时间。", risk: .personal)
                } else if item.logicalSize >= options.largeThreshold {
                    let context = item.type == "虚拟磁盘" ? "可能承载整个虚拟环境与项目，请先用所属应用核对。" : item.type == "数据库" ? "可能包含应用数据，应先退出所属应用并确认用途。" : "大小仅供排查，不能证明文件无用。"
                    candidate = Candidate(item: item, category: "大文件", reason: "\(item.type) · 大于 \(bytes(options.largeThreshold))；" + context, risk: .personal)
                }
            }
            if let candidate {
                do { try PathPolicy().validate(item.path); result.append(candidate) }
                catch {
                    let managed = under(item.path, home + "/.ollama/models") || under(item.path, home + "/.cache/huggingface")
                    result.append(Candidate(item: item, category: candidate.category, reason: candidate.reason + (managed ? " 模型缓存包含共享文件或引用，请通过模型管理工具移除整个模型。" : " 此位置不允许自动清理。"), risk: .protected))
                }
                if item.isDirectory { covered.insert(item.path) }
            }
        }
        return result.sorted { $0.item.logicalSize > $1.item.logicalSize }
    }
}
