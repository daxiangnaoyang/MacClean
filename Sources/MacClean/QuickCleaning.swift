import Foundation

struct DisposableCacheRule: Sendable {
    let label: String
    let tools: [String]
    var ids: [String] = []
}

enum QuickCleaning {
    // Exact semantic subtrees only; never an entire application profile or partition.
    static func cacheRule(_ path: String, home: String) -> DisposableCacheRule? {
        guard under(path, home), !path.split(separator: "/").contains("..") else { return nil }
        if isBrowserCache(path, home: home) {
            if path.contains("/Google/Chrome/") { return DisposableCacheRule(label: "Chrome · 网页缓存", tools: ["google chrome", "chrome"], ids: ["com.google.chrome"]) }
            if path.contains("/Microsoft Edge/") { return DisposableCacheRule(label: "Edge · 网页缓存", tools: ["microsoft edge"], ids: ["com.microsoft.edgemac"]) }
            return DisposableCacheRule(label: "Brave · 网页缓存", tools: ["brave browser"], ids: ["com.brave.browser"])
        }
        for name in ["Codex", "Doubao"] {
            let root = home + "/Library/Caches/" + name + "/Default/"
            guard path.hasPrefix(root) else { continue }
            let parts = path.dropFirst(root.count).split(separator: "/").map(String.init)
            let direct = parts.count == 1
            let partition = parts.count == 3 && parts.first == "Partitions"
            if (direct || partition), ["Cache", "Code Cache", "GPUCache"].contains(parts.last ?? "") {
                return DisposableCacheRule(label: (name == "Codex" ? "Codex" : "豆包") + " · 网页与代码缓存", tools: [name.lowercased()], ids: name == "Codex" ? ["com.openai.codex"] : ["com.bot.pc.doubao"])
            }
        }
        for base in [".cache/pip", "Library/Caches/pip"] {
            if ["http", "http-v2", "wheels", "selfcheck"].contains(where: { path == home + "/" + base + "/" + $0 }) {
                return DisposableCacheRule(label: "pip · 下载缓存", tools: ["pip", "pip3", "uv"])
            }
        }
        for app in ["Trae CN", "TRAE SOLO CN"] {
            if ["Cache", "Code Cache", "GPUCache", "CachedData"].contains(where: { path == home + "/Library/Application Support/" + app + "/" + $0 }) {
                return DisposableCacheRule(label: app + " · 网页与代码缓存", tools: ["trae", "trae cn", "trae solo cn"], ids: ["cn.trae.app", "cn.trae.solo.app"])
            }
        }
        if ["content-v2", "index-v5", "tmp"].contains(where: { path == home + "/.npm/_cacache/" + $0 }) {
            return DisposableCacheRule(label: "npm · 下载缓存", tools: ["npm", "npx", "pnpm", "yarn"])
        }
        let headers = home + "/Library/Caches/node-gyp/"
        if path.hasPrefix(headers), String(path.dropFirst(headers.count)).range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil {
            return DisposableCacheRule(label: "node-gyp · 可重新下载的头文件", tools: ["node-gyp", "make", "clang", "clang++"])
        }
        return nil
    }
    static func isLog(_ item: ScanItem, home: String) -> Bool {
        guard !item.isDirectory, under(item.path, home + "/Library/Logs") || under(item.path, "/Library/Logs") else { return false }
        return item.type == "日志" || item.name.range(of: "\\.log(?:\\.[0-9]+)?(?:\\.gz)?$", options: [.regularExpression, .caseInsensitive]) != nil
    }
    static func isUpdateArchive(_ item: ScanItem, home: String) -> Bool {
        guard !item.isDirectory, ["zip", "dmg", "pkg"].contains(URL(fileURLWithPath: item.path).pathExtension.lowercased()) else { return false }
        for app in ["Trae CN", "TRAE SOLO CN"] {
            let root = home + "/Library/Caches/" + app
            if parentPath(item.path) == root || parentPath(item.path) == root + "/pending" { return true }
        }
        return false
    }
    static func browserCaches(home: String, onIssue: ((ScanIssue) -> Void)? = nil) -> [String] {
        var result: [String] = []
        for app in ["Google/Chrome", "Microsoft Edge", "BraveSoftware/Brave-Browser"] {
            let root = URL(fileURLWithPath: home + "/Library/Application Support/" + app)
            let profiles: [URL]
            do { profiles = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) }
            catch {
                let code = (error as NSError).code
                if code != NSFileReadNoSuchFileError && code != NSFileNoSuchFileError { onIssue?(ScanIssue(path: root.path, message: error.localizedDescription)) }
                continue
            }
            for profile in profiles where profile.lastPathComponent == "Default" || profile.lastPathComponent.range(of: "^Profile [0-9]+$", options: .regularExpression) != nil {
                guard (try? profile.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { continue }
                for leaf in ["Cache", "Code Cache", "GPUCache"] { result.append(profile.appendingPathComponent(leaf).path) }
            }
        }
        return result
    }
    // Exact cache subtrees only. Profiles, passwords, cookies and history are never eligible.
    static func isBrowserCache(_ path: String, home: String) -> Bool {
        let prefixes = [home + "/Library/Application Support/", home + "/Library/Caches/"]
        guard let prefix = prefixes.first(where: { path.hasPrefix($0) }) else { return false }
        let relative = String(path.dropFirst(prefix.count))
        for app in ["Google/Chrome", "Microsoft Edge", "BraveSoftware/Brave-Browser"] {
            guard relative.hasPrefix(app + "/") else { continue }
            let parts = relative.dropFirst(app.count + 1).split(separator: "/").map(String.init)
            guard parts.count == 2, parts[0] == "Default" || parts[0].range(of: "^Profile [0-9]+$", options: .regularExpression) != nil else { continue }
            return ["Cache", "Code Cache", "GPUCache"].contains(parts[1]) && !parts.contains("..")
        }
        return false
    }
    static func roots(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [URL] {
        let paths = ["Library/Caches", "Library/Logs", ".npm/_cacache", ".cache/pip", "Library/Developer/Xcode/DerivedData"]
        let editorCaches = ["Trae CN", "TRAE SOLO CN"].flatMap { app in ["Cache", "Code Cache", "GPUCache", "CachedData"].map { home + "/Library/Application Support/" + app + "/" + $0 } }
        let systemLogs = home == FileManager.default.homeDirectoryForCurrentUser.path ? ["/Library/Logs"] : []
        return ScanEngine.normalizedRoots((paths.map { home + "/" + $0 } + browserCaches(home: home) + editorCaches + systemLogs).map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) })
    }
    static func scan(home: String, control: ScanControl, progress: @Sendable (ScanProgress) -> Void) -> ScanReport {
        var result = ScanEngine.scan(roots: roots(home: home), options: ScanOptions(), control: control, progress: progress)
        _ = browserCaches(home: home) { issue in
            result.accessErrorCount = (result.accessErrorCount ?? 0) + 1
            if result.issues.count < 250 { result.issues.append(issue) }
        }
        for item in result.items where item.logicalSize > 0 {
            if item.isDirectory, let rule = cacheRule(item.path, home: home) {
                result.candidates.removeAll { under($0.item.path, item.path) || under(item.path, $0.item.path) }
                result.candidates.append(Candidate(item: item, category: "应用缓存", reason: rule.label + "；用途明确、可再生成，清理后可能需要重新下载或编译。", risk: .regenerable))
            } else if isLog(item, home: home) {
                result.candidates.removeAll { $0.id == item.path }
                result.candidates.append(Candidate(item: item, category: "日志", reason: "运行日志或诊断报告；历史与近期日志分开判断，系统日志只读展示。", risk: .review))
            } else if isUpdateArchive(item, home: home) {
                result.candidates.removeAll { under(item.path, $0.item.path) }
                result.candidates.append(Candidate(item: item, category: "更新安装包", reason: "应用下载的更新安装文件；可能正在等待安装，需确认更新完成，不能自动清理。", risk: .review))
            }
        }
        result.candidates.sort { $0.item.logicalSize > $1.item.logicalSize }
        return result
    }
    static func owner(_ candidate: Candidate, home: String) -> String {
        let path = candidate.item.path
        if let rule = cacheRule(path, home: home) { return rule.label }
        if candidate.category == "更新安装包" { return path.contains("TRAE SOLO CN") ? "Trae SOLO · 更新安装包（需确认）" : "Trae · 更新安装包（需确认）" }
        if isLog(candidate.item, home: home) {
            if under(path, "/Library/Logs") { return "系统日志 · 只读" }
            let prefix = home + "/Library/Logs/"
            let components = path.dropFirst(prefix.count).split(separator: "/")
            let app = components.count > 1 ? String(components[0]) : "其他用户日志"
            return "应用日志 · " + app
        }
        if under(path, home + "/.npm") { return "npm · 包下载缓存" }
        if under(path, home + "/.cache/pip") { return "pip · 包下载缓存" }
        if under(path, home + "/Library/Developer/Xcode") { return "Xcode · 构建缓存" }
        if path.contains("Google/Chrome") || path.contains("com.google.Chrome") || under(path, home + "/Library/Caches/Google") { return "Chrome · 浏览器缓存" }
        if path.contains("Microsoft Edge") || path.contains("com.microsoft.edgemac") { return "Edge · 浏览器缓存" }
        if path.contains("Brave") { return "Brave · 浏览器缓存" }
        if path.contains("org.mozilla.firefox") { return "Firefox · 浏览器缓存" }
        if candidate.category == "旧日志" { return "日志 · " + URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent }
        return candidate.risk == .regenerable ? "其他应用缓存 · 需核对用途" : "个人文件 · 需确认"
    }
}
