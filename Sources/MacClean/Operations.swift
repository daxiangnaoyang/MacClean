import Foundation
import AppKit

struct AppInfo: Identifiable, Codable, Sendable {
    var id: String { path }
    let name: String
    let path: String
    let bundleID: String
    let version: String
    let size: Int64
    let complete: Bool
    let protected: Bool
}

struct AppInventory: Codable, Sendable {
    let apps: [AppInfo]
    let issues: [ScanIssue]
    let cancelled: Bool
}

enum AppScanner {
    static func inventory(control: ScanControl) -> AppInventory {
        let fm = FileManager.default
        let directories = [URL(fileURLWithPath: "/Applications"), fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        var apps: [AppInfo] = []
        var issues: [ScanIssue] = []
        func visit(_ directory: URL, level: Int) {
            guard !control.cancelled, fm.fileExists(atPath: directory.path) else { return }
            let list: [URL]
            do { list = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey]) }
            catch { issues.append(ScanIssue(path: directory.path, message: error.localizedDescription)); return }
            for url in list {
                guard !control.cancelled else { break }
                let v = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                guard v?.isSymbolicLink != true else { continue }
                if url.pathExtension == "app" {
                    let bundle = Bundle(url: url)
                    let id = bundle?.bundleIdentifier ?? ""
                    let report = ScanEngine.scan(roots: [url], options: ScanOptions(), control: control) { _ in }
                    issues.append(contentsOf: report.issues.prefix(max(0, 250 - issues.count)))
                    apps.append(AppInfo(name: bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? url.deletingPathExtension().lastPathComponent,
                                        path: url.path, bundleID: id, version: bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—",
                                        size: report.measuredSize, complete: report.isComplete, protected: id.isEmpty || id.hasPrefix("com.apple.") || id == "com.daxiang.macclean" || url.path == Bundle.main.bundlePath))
                } else if v?.isDirectory == true { visit(url, level: level + 1) }
            }
        }
        for root in directories { visit(root, level: 0) }
        return AppInventory(apps: apps.sorted { $0.size > $1.size }, issues: issues, cancelled: control.cancelled)
    }
    static func related(to app: AppInfo, home: URL = FileManager.default.homeDirectoryForCurrentUser, control: ScanControl) -> (items: [Candidate], issues: [ScanIssue]) {
        guard !app.bundleID.isEmpty else { return ([], []) }
        let id = app.bundleID
        let paths = ["Library/Caches/\(id)", "Library/Logs/\(id)", "Library/Preferences/\(id).plist", "Library/Application Support/\(id)", "Library/Saved Application State/\(id).savedState", "Library/Containers/\(id)", "Library/HTTPStorages/\(id)", "Library/WebKit/\(id)"]
        let roots = paths.map { home.appendingPathComponent($0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        let report = ScanEngine.scan(roots: roots, options: ScanOptions(), control: control) { _ in }
        let items = report.topItems.map { item in
            Candidate(item: item, category: "应用关联文件", reason: "路径名称与 Bundle ID \(id) 精确匹配；可能包含设置、登录状态和个人数据。共享组容器不参与自动匹配。", risk: .review)
        }
        return (items, report.issues)
    }
    @MainActor static func running(_ app: AppInfo) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == app.bundleID || $0.bundleURL?.path == app.path }
    }
}

struct ActionTarget: Identifiable, Sendable {
    var id: String { path }
    let path: String
    let size: Int64
    let expectedModified: Date?
    init(_ item: ScanItem) { path = item.path; size = item.logicalSize; expectedModified = item.modified }
    init(path: String, size: Int64) {
        self.path = path; self.size = size
        expectedModified = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}

struct PathPolicy: Sendable {
    var allowedRoots: [String] = [FileManager.default.homeDirectoryForCurrentUser.path, "/Applications"]
    // Protect the running bundle and, for local development, the checkout that contains it.
    // Never embed a build machine's absolute source path in distributed executables.
    static var runtimeProtectedTrees: [String] {
        let fm = FileManager.default
        var result = [Bundle.main.bundlePath]
        var directory = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent()
        for _ in 0..<7 {
            if fm.fileExists(atPath: directory.appendingPathComponent("Package.swift").path),
               fm.fileExists(atPath: directory.appendingPathComponent("Sources/MacClean/main.swift").path) {
                result.append(directory.path); break
            }
            if directory.path == "/" { break }
            directory.deleteLastPathComponent()
        }
        return result
    }
    func validate(_ path: String) throws {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let protected = ["/", "/System", "/Library", "/Applications", home, home + "/Library", home + "/Desktop", home + "/Documents", home + "/Downloads", home + "/Movies", home + "/Pictures", home + "/Music", home + "/Applications", home + "/Library/Caches", home + "/Library/Logs", home + "/Library/Application Support", home + "/Library/Developer", home + "/Library/Developer/Xcode", home + "/Library/Developer/Xcode/DerivedData", home + "/.npm", home + "/.npm/_cacache"]
        let protectedTrees = [home + "/.Trash", home + "/.ssh", home + "/.gnupg", home + "/.config", home + "/Library/Keychains", home + "/Library/Mail", home + "/Library/Messages", home + "/Library/Group Containers", home + "/Library/Application Support/MobileSync", home + "/Library/Application Support/MacClean", home + "/.ollama/models", home + "/.cache/huggingface", home + "/Library/Developer/CoreSimulator"] + Self.runtimeProtectedTrees
        guard allowedRoots.contains(where: { under(url.path, $0) && url.path != $0 }), !protected.contains(url.path), !protectedTrees.contains(where: { under(url.path, $0) }) else { throw cleanError("此位置受保护，无法在这里清理。") }
        if url.pathComponents.contains(where: { $0 == ".git" || $0.hasSuffix(".photoslibrary") }) { throw cleanError("版本库或照片资料库受保护。") }
        let canonicalParent = url.deletingLastPathComponent().resolvingSymlinksInPath()
        guard canonicalParent.path == url.deletingLastPathComponent().path else { throw cleanError("路径含符号链接，请从真实位置重新扫描。") }
        let v = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard v.isSymbolicLink != true else { throw cleanError("不处理符号链接。") }
        if url.pathExtension == "app" {
            let id = Bundle(url: url)?.bundleIdentifier ?? ""
            guard !id.isEmpty, !id.hasPrefix("com.apple."), id != "com.daxiang.macclean" else { throw cleanError("此应用受保护。") }
        }
    }
}

func cleanError(_ message: String) -> NSError { NSError(domain: "MacClean", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }

struct TrashRecord: Identifiable, Codable, Sendable {
    let id: UUID
    let original: String
    var trashPath: String?
    let size: Int64
    let date: Date
    var status: String
    var error: String?
}

// Persist the intent before moving any file; the returned trash URL is the restore source.
struct TrashStore: Sendable {
    let journalURL: URL
    var policy = PathPolicy()
    init(journalURL: URL? = nil, policy: PathPolicy = PathPolicy()) {
        self.journalURL = journalURL ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MacClean/history.json")
        self.policy = policy
    }
    func load() throws -> [TrashRecord] {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return [] }
        return try JSONDecoder().decode([TrashRecord].self, from: Data(contentsOf: journalURL))
    }
    func save(_ entries: [TrashRecord]) throws {
        let directory = journalURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(entries)
        try data.write(to: journalURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
    }
    static func nonOverlapping(_ targets: [ActionTarget]) -> [ActionTarget] {
        var result: [ActionTarget] = []
        for t in targets.sorted(by: { $0.path.count < $1.path.count }) {
            if !result.contains(where: { under(t.path, $0.path) }) { result.append(t) }
        }
        return result
    }
    func trash(_ targets: [ActionTarget], beforeTrash: (@Sendable (ActionTarget) throws -> Void)? = nil) throws -> [TrashRecord] {
        var records = try load()
        for target in Self.nonOverlapping(targets) {
            var record = TrashRecord(id: UUID(), original: target.path, size: target.size, date: Date(), status: "待执行")
            records.insert(record, at: 0); try save(records)
            do {
                try policy.validate(target.path)
                try beforeTrash?(target)
                let url = URL(fileURLWithPath: target.path)
                let current = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                if let expected = target.expectedModified, let current, abs(current.timeIntervalSince(expected)) > 1 { throw cleanError("文件在扫描后有变化，请重新扫描。") }
                var result: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &result)
                record.trashPath = result?.path
                record.status = result == nil ? "已移入（请在 Finder 恢复）" : "已移入废纸篓"
            } catch { record.status = "失败"; record.error = error.localizedDescription }
            records[0] = record; try save(records)
        }
        return records
    }
    func restore(_ id: UUID) throws -> [TrashRecord] {
        var records = try load()
        guard let index = records.firstIndex(where: { $0.id == id }), let source = records[index].trashPath,
              records[index].status == "已移入废纸篓" else { throw cleanError("此记录没有可恢复的废纸篓路径。") }
        let destination = URL(fileURLWithPath: records[index].original)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw cleanError("原位置已有同名文件，恢复不会覆盖它。请先在 Finder 中处理冲突。") }
        guard FileManager.default.fileExists(atPath: source) else { throw cleanError("废纸篓中的文件已不存在，无法恢复。") }
        guard FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().path) else { throw cleanError("原来的父文件夹已不存在，请在 Finder 中手动恢复。") }
        let parent = destination.deletingLastPathComponent()
        guard parent.resolvingSymlinksInPath().path == parent.path else { throw cleanError("原位置的父路径已改变，无法自动恢复。") }
        try FileManager.default.moveItem(at: URL(fileURLWithPath: source), to: destination)
        records[index].status = "已恢复"
        try save(records)
        return records
    }
}
