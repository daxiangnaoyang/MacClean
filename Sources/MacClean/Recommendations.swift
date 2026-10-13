import Foundation
import AppKit

enum AdviceDecision: String, Codable, Sendable, CaseIterable {
    case delete = "建议删除", keep = "建议保留", required = "必须保留"
}

struct Advice: Codable, Sendable {
    let decision: AdviceDecision
    let reason: String
    let rule: String
}

enum FileChoice: String, CaseIterable { case automatic = "按建议", keep = "保留", delete = "删除" }

struct ActivitySnapshot: Sendable {
    let known: Bool
    let processNames: Set<String>
    var applicationIDs: Set<String> = []
    static func processes() -> ActivitySnapshot {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "comm="]
        let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { return ActivitySnapshot(known: false, processNames: []) }
            let names = String(decoding: data, as: UTF8.self).split(separator: "\n").map {
                String($0.trimmingCharacters(in: .whitespaces).split(separator: "/").last ?? "").lowercased()
            }
            return ActivitySnapshot(known: true, processNames: Set(names))
        } catch { return ActivitySnapshot(known: false, processNames: []) }
    }
    @MainActor static func capture() -> ActivitySnapshot {
        var result = processes()
        result.applicationIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier).map { $0.lowercased() })
        return result
    }
    func contains(_ names: [String]) -> Bool {
        processNames.contains { process in names.contains { process == $0 || process.hasPrefix($0 + " ") || process.hasPrefix($0 + "-") || process.hasPrefix($0 + "3") } }
    }
}

struct KeepStore: Sendable {
    let url: URL
    init(url: URL? = nil) { self.url = url ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MacClean/keep.json") }
    func load() throws -> Set<String> {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return Set(try JSONDecoder().decode([String].self, from: Data(contentsOf: url)))
    }
    func save(_ paths: Set<String>) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(paths.sorted()).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func retains(_ path: String, paths: Set<String>) -> Bool {
        if paths.contains(path) { return true }
        var parent = parentPath(path)
        while parent != "/" {
            if paths.contains(parent) { return true }
            parent = parentPath(parent)
        }
        return false
    }
}

struct RecommendationEngine: Sendable {
    let home: String
    init(home: String = FileManager.default.homeDirectoryForCurrentUser.path) { self.home = home }
    static let policyVersion = "conservative-v1"

    func mandatoryReason(_ item: ScanItem, risk: Risk) -> String? {
        if risk == .protected { return "受保护位置或访问状态无法确认，禁止通过规则清理。" }
        let system = ["/System", "/Library", "/usr", "/bin", "/sbin", "/private", "/opt", "/Applications"]
        if !under(item.path, home), system.contains(where: { under(item.path, $0) }) { return "系统、程序或工具运行位置；应用请通过应用卸载入口处理。" }
        let data = ["Library/Application Support", "Library/Containers", "Library/Group Containers", "Library/Preferences", "Library/Saved Application State", "Library/HTTPStorages", "Library/WebKit", "Library/LaunchAgents", "Library/Keychains", "Library/Mail", "Library/Messages", "Library/Developer/CoreSimulator", ".ollama/models", ".cache/huggingface", ".ssh", ".gnupg", ".config"]
        if data.contains(where: { under(item.path, home + "/" + $0) }) { return "程序运行数据、配置、模型或个人关键数据，不能按体积或时间判断为垃圾。" }
        let components = item.path.split(separator: "/")
        if components.contains(where: { $0 == ".git" || $0 == "node_modules" || $0 == ".venv" || $0 == "venv" || $0.hasSuffix(".app") || $0.hasSuffix(".framework") || $0.hasSuffix(".bundle") || $0.hasSuffix(".photoslibrary") || $0.hasSuffix(".xcarchive") }) {
            return "应用组件、依赖、版本库或资料库，删除可能破坏程序或项目。"
        }
        if ["数据库", "虚拟磁盘", "本地模型", "应用"].contains(item.type) { return "\(item.type)可能承载运行环境或持久数据，请在所属应用中管理。" }
        if item.path.hasPrefix(home + "/Library/Caches/com.apple.") { return "Apple 系统服务缓存由系统管理，本工具将其保留。" }
        return nil
    }
    private func cacheOwner(_ path: String) -> (tools: [String], ids: [String], label: String)? {
        if under(path, home + "/.npm/_cacache") { return (["node", "nodejs", "npm", "npx", "node_repl", "bun", "deno"], [], "Node/npm") }
        if under(path, home + "/.cache/pip") { return (["python", "python3", "pip", "pip3", "uv"], [], "Python/pip") }
        if under(path, home + "/Library/Developer/Xcode/DerivedData") { return (["xcode", "xcodebuild", "swift", "swift-build", "swift-frontend", "clang", "clang++", "sourcekit-lsp"], ["com.apple.dt.xcode"], "Xcode/Swift") }
        let mapping: [(String, [String], [String], String)] = [
            ("Google", ["google chrome", "chrome", "chrome-headless-shell"], ["com.google.chrome"], "Google/Chrome"),
            ("com.google.Chrome", ["google chrome", "chrome", "chrome-headless-shell"], ["com.google.chrome"], "Chrome"),
            ("com.microsoft.edgemac", ["microsoft edge"], ["com.microsoft.edgemac"], "Edge"),
            ("com.brave.Browser", ["brave browser"], ["com.brave.browser"], "Brave"),
            ("org.mozilla.firefox", ["firefox"], ["org.mozilla.firefox"], "Firefox")
        ]
        for (name, tools, ids, label) in mapping where under(path, home + "/Library/Caches/" + name) { return (tools, ids, label) }
        return nil
    }
    func advice(for candidate: Candidate, activity: ActivitySnapshot, now: Date = Date(), kept: Set<String> = []) -> Advice {
        let item = candidate.item
        if let reason = mandatoryReason(item, risk: candidate.risk) { return Advice(decision: .required, reason: reason, rule: "protected-data") }
        if KeepStore.retains(item.path, paths: kept) { return Advice(decision: .keep, reason: "你已标记保留，后续扫描继续排除。", rule: "user-keep") }
        guard item.complete else { return Advice(decision: .keep, reason: "此项目未完整扫描，暂不推荐删除。", rule: "incomplete") }
        guard activity.known else { return Advice(decision: .keep, reason: "未取得当前运行状态，无法确认是否在用。", rule: "activity-unknown") }
        if candidate.risk == .regenerable {
            guard let owner = cacheOwner(item.path) else { return Advice(decision: .keep, reason: "位于缓存目录，但归属和再生成方式未确认；不进入一键建议。", rule: "cache-owner-unknown") }
            if activity.contains(owner.tools) || !activity.applicationIDs.isDisjoint(with: owner.ids) {
                return Advice(decision: .required, reason: "检测到 \(owner.label) 或相关任务正在运行，本次保留；退出后重新扫描。", rule: "owner-running")
            }
            guard let modified = item.latestModified ?? (item.isDirectory ? nil : item.modified) else {
                return Advice(decision: .keep, reason: "缺少目录内最新写入时间，不能仅按文件夹日期推荐删除。", rule: "freshness-unknown")
            }
            let days = Int(now.timeIntervalSince(modified) / 86400)
            guard days >= 14 else { return Advice(decision: .keep, reason: "最近 \(max(0, days)) 天内仍有写入；暂保留近期使用的缓存。", rule: "recent-cache") }
            return Advice(decision: .delete, reason: "已确认 \(owner.label) 可再生成缓存；目录内最新写入距今 \(days) 天，当前未检测到相关运行任务。清理后可能需要重新下载或构建。", rule: "idle-old-cache")
        }
        if candidate.category == "旧日志", !item.isDirectory, under(item.path, home + "/Library/Logs"), item.type == "日志", let modified = item.modified, now.timeIntervalSince(modified) >= 30 * 86400 {
            return Advice(decision: .delete, reason: "用户日志目录中至少 30 天未修改的日志，不属于程序组件。若需历史排错记录，可标记保留。", rule: "old-log")
        }
        return Advice(decision: .keep, reason: candidate.category == "旧安装包" ? "安装包是否仍需要无法自动确认，默认保留；确认安装完成后可手动选择删除。" : "个人文件或用途未确认，大小和修改时间不足以证明无用。", rule: "personal-or-unknown")
    }
    func apply(to report: ScanReport, activity: ActivitySnapshot, kept: Set<String> = []) -> ScanReport {
        var result = report
        result.candidates = report.candidates.map { candidate in
            var c = candidate; c.advice = advice(for: candidate, activity: activity, kept: kept); return c
        }
        result.advicePolicy = Self.policyVersion; result.adviceDate = Date()
        return result
    }
    // Called for one-click items, not for arbitrary manual selections.
    func prepare(_ candidates: [Candidate], activity: ActivitySnapshot, kept: Set<String>, policy: PathPolicy = PathPolicy()) -> (ready: [Candidate], skipped: [String]) {
        var ready: [Candidate] = []; var skipped: [String] = []
        for candidate in candidates {
            do {
                try policy.validate(candidate.item.path)
                guard advice(for: candidate, activity: activity, kept: kept).decision == .delete else { throw cleanError("建议已变为保留。") }
                var current = candidate
                if candidate.item.isDirectory {
                    let verification = ScanEngine.scan(roots: [URL(fileURLWithPath: candidate.item.path)], options: ScanOptions(entryLimit: 300_000), control: ScanControl()) { _ in }
                    guard let item = verification.topItems.first, item.complete else { throw cleanError("目录重检不完整，本次保留。") }
                    guard item.logicalSize == candidate.item.logicalSize, item.fileCount == candidate.item.fileCount,
                          item.latestModified == candidate.item.latestModified else { throw cleanError("目录内容在扫描后变化，本次保留。") }
                    current = Candidate(item: item, category: candidate.category, reason: candidate.reason, risk: candidate.risk)
                } else {
                    let values = try URL(fileURLWithPath: candidate.item.path).resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                    guard values.contentModificationDate == candidate.item.modified, Int64(values.fileSize ?? -1) == candidate.item.logicalSize else { throw cleanError("文件在扫描后变化，本次保留。") }
                }
                guard advice(for: current, activity: activity, kept: kept).decision == .delete else { throw cleanError("重检后不再符合删除建议。") }
                ready.append(current)
            } catch { skipped.append(candidate.item.name + "：" + error.localizedDescription) }
        }
        return (ready, skipped)
    }
}

enum FileUseGuard {
    static func assertUnused(_ item: ScanItem) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = item.isDirectory ? ["-n", "-P", "-t", "+D", item.path] : ["-n", "-P", "-t", "--", item.path]
        let output = Pipe(); let errors = Pipe(); process.standardOutput = output; process.standardError = errors
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let diagnostics = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); timeout.cancel()
        if !data.isEmpty { throw cleanError("检测到程序正在打开此文件或目录内文件，本次保留。") }
        guard process.terminationStatus == 1, diagnostics.isEmpty else { throw cleanError("未能确认文件占用状态，本次保留。") }
    }
}
