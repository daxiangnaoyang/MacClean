import SwiftUI
import AppKit

enum Page: String, CaseIterable {
    case overview = "清理首页", space = "空间分析", rules = "清理结果", apps = "应用卸载", history = "恢复中心"
    var icon: String {
        switch self { case .overview: "square.grid.2x2.fill"; case .space: "chart.pie.fill"; case .rules: "slider.horizontal.3"; case .apps: "square.stack.3d.up.fill"; case .history: "clock.arrow.circlepath" }
    }
    var subtitle: String {
        switch self {
        case .overview: "检查常见缓存和旧日志，确认后再清理。"
        case .space: "递归统计真实文件大小，逐层深入占用最多的目录。"
        case .rules: "按应用查看建议；需要确认的项目单独处理。"
        case .apps: "预览应用本体和按 Bundle ID 匹配的关联文件。"
        case .history: "记录每次操作，并从系统废纸篓恢复到原位置。"
        }
    }
}

@MainActor final class CleanerModel: ObservableObject {
    @Published var page: Page = .overview
    @Published var report: ScanReport?
    @Published var analysisReport: ScanReport?
    @Published var analysisStale = false
    @Published var scanIsAnalysis = false
    @Published var scanning = false
    @Published var appLoading = false
    @Published var busy = false
    @Published var progress = ScanProgress(path: "", visited: 0, measured: 0)
    @Published var roots = ScanEngine.defaultRoots() { didSet { persistScanPreferences() } }
    @Published var options = ScanOptions() { didSet { persistScanPreferences() } }
    @Published var apps: [AppInfo] = []
    @Published var appIssues: [ScanIssue] = []
    @Published var related: [Candidate] = []
    @Published var relatedIssues: [ScanIssue] = []
    @Published var focusedApp: AppInfo?
    @Published var relatedLoading = false
    @Published var appSelected = Set<String>()
    @Published var selected = Set<String>()
    @Published var history: [TrashRecord] = []
    @Published var notice: String?
    @Published var pending: [ActionTarget] = []
    @Published var confirm = false
    @Published var folder: String?
    @Published var spaceType = "全部"
    @Published var query = ""
    @Published var category = "全部"
    @Published var riskFilter = "全部"
    @Published private(set) var keptPaths = Set<String>()
    @Published private(set) var keepReady = true
    @Published private(set) var activity = ActivitySnapshot(known: false, processNames: [])
    @Published var stale = false
    var documentationDemo = false
    @Published private(set) var runtimeBlocks: [String: String] = [:]
    private var pendingApp = false
    private var pendingRecommended = false
    private var control: ScanControl?
    private var appControl: ScanControl?
    private var relatedControl: ScanControl?
    let store: TrashStore
    let keepStore: KeepStore
    let advisor: RecommendationEngine
    private let preferencesStore: ScanPreferencesStore
    private var preferencesReady = false
    private var bookmarks: [String: Data] = [:]
    private var directoryGrants: [String: DirectoryGrant] = [:]
    var candidates: [Candidate] { report?.candidates ?? [] }
    func cleanupGroup(_ candidate: Candidate) -> String { QuickCleaning.owner(candidate, home: advisor.home) }
    var filtered: [Candidate] {
        candidates.filter { (category == "全部" || $0.category == category) && (riskFilter == "全部" || recommendation($0).decision.rawValue == riskFilter) && (query.isEmpty || $0.item.path.localizedCaseInsensitiveContains(query) || $0.item.type.contains(query)) }
    }
    var selectedSize: Int64 { candidates.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.item.logicalSize } }
    var cacheSize: Int64 { candidates.filter { $0.risk == .regenerable }.reduce(0) { $0 + $1.item.logicalSize } }
    var recognizedCacheSize: Int64 { candidates.filter { $0.risk == .regenerable && QuickCleaning.cacheRule($0.id, home: advisor.home) != nil }.reduce(0) { $0 + $1.item.logicalSize } }
    var deferredCacheSize: Int64 { candidates.filter { recommendation($0).rule == "owner-running" }.reduce(0) { $0 + $1.item.logicalSize } }
    var detectedLogSize: Int64 { candidates.filter { QuickCleaning.isLog($0.item, home: advisor.home) }.reduce(0) { $0 + $1.item.logicalSize } }
    var recommended: [Candidate] { candidates.filter { recommendation($0).decision == .delete } }
    var recommendedSize: Int64 { recommended.reduce(0) { $0 + $1.item.logicalSize } }
    func recommendation(_ candidate: Candidate) -> Advice {
        if let reason = runtimeBlocks[candidate.id] { return Advice(decision: .required, reason: "本次重检保留：" + reason, rule: "preflight-block") }
        let advice = advisor.advice(for: candidate, activity: activity, kept: keptPaths)
        if !keepReady, advice.decision != .required { return Advice(decision: .keep, reason: "保留设置未读取，暂停自动删除建议。", rule: "keep-settings-unknown") }
        return advice
    }
    func choice(_ candidate: Candidate) -> FileChoice {
        if KeepStore.retains(candidate.id, paths: keptPaths) { return .keep }
        return selected.contains(candidate.id) ? .delete : .automatic
    }
    func setChoice(_ choice: FileChoice, for candidate: Candidate) {
        guard !busy, !scanning, keepReady, choice != .delete || recommendation(candidate).decision != .required else { return }
        if choice == .delete, KeepStore.retains(candidate.id, paths: keptPaths), !keptPaths.contains(candidate.id) {
            notice = "父目录已标记保留，请先取消父目录的保留设置。"; return
        }
        var updated = keptPaths
        if choice == .keep { updated.insert(candidate.id) } else { updated.remove(candidate.id) }
        do { try keepStore.save(updated); keptPaths = updated; keepReady = true }
        catch { notice = "保留设置未能保存：\(error.localizedDescription)"; return }
        if choice == .delete { selected.insert(candidate.id) }
        else { selected = selected.filter { !under($0, candidate.id) } }
        if var r = report { r = advisor.apply(to: r, activity: activity, kept: keptPaths); report = r }
    }
    func refreshRecommendations() {
        runtimeBlocks.removeAll()
        activity = ActivitySnapshot.capture()
        if let r = report { report = advisor.apply(to: r, activity: activity, kept: keptPaths) }
        selected = selected.filter { path in candidates.contains { $0.id == path && recommendation($0).decision != .required } }
    }
    var spaceItems: [ScanItem] {
        guard let report = analysisReport else { return [] }
        return report.items.filter { item in
            let atLevel = spaceType == "全部" ? (folder.map { parentPath(item.path) == $0 } ?? report.roots.contains(item.path)) : (!item.isDirectory && item.type == spaceType)
            return atLevel && (query.isEmpty || item.name.localizedCaseInsensitiveContains(query))
        }
    }
    var disk: (total: Int64, free: Int64) {
        if documentationDemo { return (512_000_000_000, 192_000_000_000) }
        let values = try? FileManager.default.homeDirectoryForCurrentUser.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        return (Int64(values?.volumeTotalCapacity ?? 0), values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }
    init(store: TrashStore = TrashStore(), keepStore: KeepStore = KeepStore(), advisor: RecommendationEngine = RecommendationEngine()) {
        self.store = store; self.keepStore = keepStore; self.advisor = advisor
        preferencesStore = ScanPreferencesStore(url: keepStore.url.deletingLastPathComponent().appendingPathComponent("scan-settings.json"))
        do {
            if let saved = try preferencesStore.load() {
                roots = saved.roots.map { URL(fileURLWithPath: $0) }; options = saved.options; bookmarks = saved.bookmarks
                for (path, data) in saved.bookmarks {
                    do {
                        let restored = try DirectoryGrant.restore(data)
                        directoryGrants[path] = restored.grant
                        if let renewed = restored.refreshed { bookmarks[path] = renewed }
                        if restored.grant.url.path != path {
                            roots = roots.map { $0.path == path ? restored.grant.url : $0 }
                        }
                    } catch { notice = "目录授权已失效：\(path)。请在扫描设置中重新授权；其他目录仍可扫描。" }
                }
            }
            preferencesReady = true
        } catch { notice = "扫描设置读取失败，保留原文件且不覆盖：\(error.localizedDescription)" }
        do { keptPaths = try keepStore.load() } catch { keepReady = false; notice = "保留设置读取失败，一键清理已停用：\(error.localizedDescription)" }
        refreshHistory()
    }
    func configureDocumentationDemo(report: ScanReport) {
        documentationDemo = true
        roots = report.roots.map { URL(fileURLWithPath: $0) }
        activity = ActivitySnapshot(known: true, processNames: [])
        self.report = advisor.apply(to: report, activity: activity)
        analysisReport = report
        riskFilter = AdviceDecision.delete.rawValue
        selected = Set(recommended.map(\.id))
        notice = "演示数据 · 路径、应用和容量均为虚构示例，不代表实际扫描结果。"
    }
    func refreshHistory() { do { history = try store.load() } catch { notice = "恢复记录读取失败：\(error.localizedDescription)" } }
    private func persistScanPreferences() {
        guard preferencesReady, !documentationDemo else { return }
        analysisStale = analysisReport != nil
        do { try preferencesStore.save(ScanPreferences(roots: roots.map(\.path), options: options, bookmarks: bookmarks)) }
        catch { notice = "扫描设置未保存：\(error.localizedDescription)" }
    }
    func authorizeHome() { pickFolder(homeOnly: true) }
    func scan(fullDisk: Bool = false) {
        guard !scanning, !busy else { return }
        let analyzing = fullDisk || page == .space
        scanIsAnalysis = analyzing
        let token = ScanControl(); control = token
        scanning = true; selected.removeAll(); folder = nil; spaceType = "全部"; query = ""; notice = nil
        let scanRoots = roots; let settings = options; let home = advisor.home
        Task { [self] in
            let result = await Task.detached(priority: .userInitiated) {
                let updateProgress: @Sendable (ScanProgress) -> Void = { update in
                    Task { @MainActor [weak self] in
                        guard let self, self.control === token else { return }
                        self.progress = update
                    }
                }
                return analyzing ? ScanEngine.scan(roots: scanRoots, options: settings, control: token, progress: updateProgress) : QuickCleaning.scan(home: home, control: token, progress: updateProgress)
            }.value
            activity = ActivitySnapshot.capture()
            if analyzing { analysisReport = result; analysisStale = false; page = .space }
            else {
                report = advisor.apply(to: result, activity: activity, kept: keptPaths)
                runtimeBlocks.removeAll(); stale = false; selected = Set(recommended.map(\.id)); page = .rules
                category = "全部"; riskFilter = recommended.isEmpty ? (candidates.contains { recommendation($0).decision == .keep } ? AdviceDecision.keep.rawValue : AdviceDecision.required.rawValue) : AdviceDecision.delete.rawValue
            }
            scanning = false
        }
    }
    func cancel() { control?.cancel() }
    func pickFolder(homeOnly: Bool = false) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        if homeOnly { panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser; panel.allowsMultipleSelection = false }
        panel.message = "选择目录并记住授权。以后扫描直接复用；系统受保护数据仍需完全磁盘访问。"
        panel.prompt = "授权并记住"
        if panel.runModal() == .OK {
            var granted: [URL] = []
            for url in panel.urls {
                do {
                    let grant = DirectoryGrant(url)
                    bookmarks[url.path] = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                    directoryGrants[url.path] = grant; granted.append(url)
                } catch { notice = "目录授权无法保存：\(error.localizedDescription)" }
            }
            roots = ScanEngine.normalizedRoots(roots + granted)
        }
    }
    func loadApps() {
        guard !appLoading, !busy else { return }
        let token = ScanControl(); appControl = token; appLoading = true
        Task {
            let result = await Task.detached(priority: .utility) { AppScanner.inventory(control: token) }.value
            apps = result.apps; appIssues = result.issues; appLoading = false
            if result.cancelled { notice = "应用扫描已停止，保留已取得的结果。" }
        }
    }
    func cancelApps() { appControl?.cancel() }
    func focus(_ app: AppInfo) {
        relatedControl?.cancel(); let token = ScanControl(); relatedControl = token
        focusedApp = app; related = []; relatedIssues = []; appSelected = []; relatedLoading = true
        if !app.protected && !AppScanner.running(app) { appSelected.insert(app.path) }
        Task {
            let result = await Task.detached(priority: .utility) { AppScanner.related(to: app, control: token) }.value
            guard !token.cancelled, focusedApp?.path == app.path else { return }
            related = result.items; relatedIssues = result.issues; relatedLoading = false
        }
    }
    func planRecommended() {
        guard !scanning, !busy, !stale, keepReady, report?.cancelled != true else { return }
        refreshRecommendations(); pendingApp = false; pendingRecommended = true
        pending = recommended.map { ActionTarget($0.item) }
        confirm = !pending.isEmpty
        if pending.isEmpty { notice = "当前没有通过检查的建议项。" }
    }
    func planRules() {
        refreshRecommendations(); pendingApp = false; pendingRecommended = false
        pending = candidates.filter { selected.contains($0.id) && recommendation($0).decision != .required }.map { ActionTarget($0.item) }
        confirm = !pending.isEmpty
    }
    func planApp() {
        pendingRecommended = false
        guard let app = focusedApp, !app.protected, !AppScanner.running(app) else { notice = "请先退出此应用；系统应用和 MacClean 受保护。"; return }
        pendingApp = true
        pending = related.filter { appSelected.contains($0.id) && $0.item.complete }.map { ActionTarget($0.item) }
        if appSelected.contains(app.path) { pending.append(ActionTarget(path: app.path, size: app.size)) }
        confirm = !pending.isEmpty
    }
    func execute() {
        guard !busy else { return }
        if pendingRecommended { pendingRecommended = false; confirm = false; deleteRecommended(); return }
        if let app = focusedApp, pendingApp, AppScanner.running(app) { notice = "应用仍在运行，请退出后重试。"; return }
        let targets = pending; let trashStore = store; busy = true; confirm = false
        let isApp = pendingApp; let adviceEngine = advisor
        let ruleItems = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        Task {
            do {
                let result = try await Task.detached {
                    try trashStore.trash(targets) { target in
                        if !isApp, let c = ruleItems[target.path] {
                            if adviceEngine.advice(for: c, activity: ActivitySnapshot.processes()).decision == .required { throw cleanError("此项目当前必须保留，已拦截清理。") }
                            try FileUseGuard.assertUnused(c.item)
                        }
                    }
                }.value
                accept(result, targets: targets, skipped: [])
            } catch { notice = "操作未完成：\(error.localizedDescription)。请查看恢复中心或系统废纸篓。"; refreshHistory() }
            busy = false
        }
    }
    func deleteRecommended() {
        guard !busy, !scanning, keepReady, let report, !report.cancelled, !stale else { return }
        refreshRecommendations()
        let items = recommended; guard !items.isEmpty else { notice = "当前没有符合保守规则的删除建议。"; return }
        let engine = advisor; let snapshot = activity; let keeps = keptPaths; let trashStore = store
        busy = true; notice = "正在重检建议项的文件变化和运行状态…"
        Task {
            let prepared = await Task.detached { engine.prepare(items, activity: snapshot, kept: keeps, policy: trashStore.policy) }.value
            let currentActivity = ActivitySnapshot.capture()
            let ready = prepared.ready.filter { engine.advice(for: $0, activity: currentActivity, kept: keeps).decision == .delete }
            let changed = prepared.ready.filter { engine.advice(for: $0, activity: currentActivity, kept: keeps).decision != .delete }.map { $0.item.name + "：运行状态改变，本次保留。" }
            let targets = ready.map { ActionTarget($0.item) }
            let readyPaths = Set(ready.map(\.id))
            for item in items where !readyPaths.contains(item.id) { runtimeBlocks[item.id] = "文件变化或运行状态改变，请重新扫描。" }
            let lookup = Dictionary(uniqueKeysWithValues: ready.map { ($0.id, $0) })
            do {
                let result = try await Task.detached {
                    try trashStore.trash(targets) { target in
                        guard let c = lookup[target.path], engine.advice(for: c, activity: ActivitySnapshot.processes(), kept: keeps).decision == .delete else {
                            throw cleanError("运行状态改变或不再符合建议，本次保留。")
                        }
                        try FileUseGuard.assertUnused(c.item)
                    }
                }.value
                accept(result, targets: targets, skipped: prepared.skipped + changed)
            } catch { notice = "建议清理未完成：\(error.localizedDescription)"; refreshHistory() }
            activity = currentActivity; busy = false
        }
    }
    private func accept(_ result: [TrashRecord], targets: [ActionTarget], skipped: [String]) {
        history = result
        let recent = result.prefix(TrashStore.nonOverlapping(targets).count)
        let moved = Set(recent.filter { $0.status.hasPrefix("已移入") }.map(\.original))
        for record in recent where record.status == "失败" { runtimeBlocks[record.original] = record.error ?? "校验或移动失败" }
        if var r = report { r.candidates.removeAll { moved.contains($0.item.path) }; report = r }
        apps.removeAll { moved.contains($0.path) }; related.removeAll { moved.contains($0.item.path) }
        if let app = focusedApp, moved.contains(app.path) { focusedApp = nil }
        selected.removeAll(); appSelected.removeAll(); stale = !moved.isEmpty
        let failures = recent.filter { $0.status == "失败" }.count
        notice = "已移入 \(moved.count) 项，失败 \(failures) 项，重检保留 \(skipped.count) 项。可在恢复中心撤回；清理后请重新扫描。" + (skipped.isEmpty ? "" : " " + skipped.prefix(3).joined(separator: "；"))
    }
    func restore(_ record: TrashRecord) {
        guard !busy else { return }; busy = true; let trashStore = store
        Task {
            do { history = try await Task.detached { try trashStore.restore(record.id) }.value; stale = true; notice = "已恢复到原位置：\(URL(fileURLWithPath: record.original).lastPathComponent)；请重新扫描更新建议。" }
            catch { notice = error.localizedDescription }
            busy = false
        }
    }
    func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    func exportReport() {
        guard let report = page == .space ? analysisReport : report else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "MacClean-扫描报告.json"; panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            do { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; try encoder.encode(report).write(to: url, options: .atomic); notice = "扫描报告已导出。" }
            catch { notice = error.localizedDescription }
        }
    }
}
