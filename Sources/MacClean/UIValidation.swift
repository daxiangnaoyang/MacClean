import AppKit
import SwiftUI

enum UIValidation {
    // Deterministic publication fixtures: never read real scans, app inventory or history.
    @MainActor static func renderPublic(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.prohibited)
        let home = "/Users/demo"
        let now = Date()
        let old = now.addingTimeInterval(-45 * 86400)
        func item(_ path: String, _ size: Int64, type: String = "文件夹", count: Int = 1) -> ScanItem {
            ScanItem(path: path, name: URL(fileURLWithPath: path).lastPathComponent, isDirectory: type == "文件夹", logicalSize: size, allocatedSize: size, fileCount: count, modified: old, type: type, complete: true, latestModified: old)
        }
        let npm = item(home + "/.npm/_cacache/content-v2", 1_200_000_000, count: 3200)
        let log = item(home + "/Library/Logs/ExampleApp/previous.log", 42_000_000, type: "日志")
        let installer = item(home + "/Downloads/ExampleEditor.dmg", 380_000_000, type: "安装包")
        let document = item(home + "/Documents/示例项目说明.pdf", 128_000_000, type: "文档")
        let database = item(home + "/Library/Application Support/ExampleApp/data.sqlite", 640_000_000, type: "数据库")
        let modelFile = item(home + "/.ollama/models/blobs/example-model", 4_800_000_000, type: "本地模型")
        let roots = [item(home + "/Downloads", 6_800_000_000, count: 120), item(home + "/Documents", 12_000_000_000, count: 1800), item(home + "/.npm/_cacache", npm.logicalSize, count: 3200), item(home + "/Library/Logs", log.logicalSize, count: 8), item(home + "/Library/Application Support", database.logicalSize, count: 32), item(home + "/.ollama/models", modelFile.logicalSize, count: 4)]
        var report = ScanReport()
        report.roots = roots.map(\.path)
        report.items = roots + [npm, log, installer, document, database, modelFile,
            item(home + "/Downloads/演示录屏.mov", 3_200_000_000, type: "视频"),
            item(home + "/Documents/示例照片.png", 24_000_000, type: "图片")]
        report.candidates = [Candidate(item: npm, category: "开发缓存", reason: "已知 npm 缓存位置；示例完整扫描。", risk: .regenerable), Candidate(item: log, category: "旧日志", reason: "示例用户日志，45 天未修改。", risk: .review), Candidate(item: installer, category: "旧安装包", reason: "示例下载的安装包，45 天未修改。", risk: .review), Candidate(item: document, category: "大文件", reason: "个人文档，体积大不等于无用。", risk: .personal), Candidate(item: database, category: "大文件", reason: "程序持久数据，请在所属应用中管理。", risk: .protected), Candidate(item: modelFile, category: "大文件", reason: "模型共享存储，请使用模型管理工具。", risk: .protected)]
        report.visited = 5164; report.elapsed = 8.2
        let model = CleanerModel(store: TrashStore(journalURL: directory.appendingPathComponent("unused-demo-history.json")), keepStore: KeepStore(url: directory.appendingPathComponent("unused-demo-keep.json")), advisor: RecommendationEngine(home: home))
        model.configureDocumentationDemo(report: report)
        for page in [Page.overview, .space, .rules] {
            model.page = page
            try snapshot(ContentView(model: model), named: [Page.overview: "overview", .space: "space", .rules: "rules"][page]!, in: directory)
        }
        model.riskFilter = AdviceDecision.required.rawValue
        try snapshot(ContentView(model: model), named: "protected", in: directory)
        model.riskFilter = "全部"
        let app = AppInfo(name: "Example Editor", path: "/Applications/Example Editor.app", bundleID: "org.example.editor", version: "1.0", size: 850_000_000, complete: true, protected: false)
        model.apps = [app, AppInfo(name: "Example Notes", path: "/Applications/Example Notes.app", bundleID: "org.example.notes", version: "2.0", size: 240_000_000, complete: true, protected: false)]
        model.focusedApp = app; model.appSelected = [app.path]
        model.related = [Candidate(item: item(home + "/Library/Caches/org.example.editor", 90_000_000), category: "应用关联文件", reason: "Bundle ID 精确匹配。", risk: .review), Candidate(item: item(home + "/Library/Application Support/org.example.editor", 160_000_000), category: "应用关联文件", reason: "可能包含个人数据；默认不勾选。", risk: .review)]
        model.page = .apps
        try snapshot(ContentView(model: model), named: "apps", in: directory)
        model.history = [TrashRecord(id: UUID(), original: log.path, trashPath: home + "/.Trash/previous.log", size: log.logicalSize, date: now, status: "已移入废纸篓"), TrashRecord(id: UUID(), original: home + "/Library/Logs/ExampleApp/restored.log", trashPath: nil, size: 12_000_000, date: now, status: "已恢复"), TrashRecord(id: UUID(), original: home + "/Library/Logs/ExampleApp/in-use.log", trashPath: nil, size: 8_000_000, date: now, status: "失败", error: "示例：文件仍被程序占用，本次保留。")]
        model.page = .history
        try snapshot(ContentView(model: model), named: "recovery", in: directory)
        try snapshot(ScanSettings(model: model).preferredColorScheme(.dark), named: "settings", in: directory, size: NSSize(width: 820, height: 640))
        model.pending = [ActionTarget(log), ActionTarget(installer)]
        try snapshot(ConfirmSheet(model: model).preferredColorScheme(.dark), named: "preview", in: directory, size: NSSize(width: 820, height: 560))
        print("PUBLIC DEMO RENDER PASSED: 8 images, synthetic data only")
    }
    @MainActor private static func snapshot<V: View>(_ view: V, named: String, in directory: URL, size: NSSize = NSSize(width: 1240, height: 980)) throws {
        let labelled = view.overlay(alignment: .top) {
            Text("演示界面 · 虚构数据").font(.system(size: 11)).foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 12).padding(.vertical, 5).background(Color.black.opacity(0.75))
                .clipShape(Capsule()).padding(.top, 6)
        }
        let hosting = NSHostingView(rootView: labelled)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting; hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw cleanError("无法生成界面图") }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw cleanError("无法编码界面图") }
        try png.write(to: directory.appendingPathComponent(named + ".png"), options: .atomic)
        window.contentView = nil
    }
    // Render our own native views to artifacts without capturing or controlling the user's desktop.
    @MainActor static func render(directory: URL, root: URL, savedReport: URL? = nil) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.prohibited)
        let model = CleanerModel()
        let scope = root.lastPathComponent == "default-scope" ? ScanEngine.defaultRoots() : [root]
        model.roots = scope
        if let savedReport { model.report = try JSONDecoder().decode(ScanReport.self, from: Data(contentsOf: savedReport)) }
        else { model.report = ScanEngine.scan(roots: scope, options: ScanOptions(), control: ScanControl()) { _ in } }
        model.refreshRecommendations()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(model.report).write(to: directory.appendingPathComponent("scan-report.json"), options: .atomic)
        for page in [Page.overview, .space, .rules, .history] {
            model.page = page
            let hosting = NSHostingView(rootView: ContentView(model: model))
            hosting.frame = NSRect(x: 0, y: 0, width: 1240, height: 820)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw cleanError("无法生成原生界面图") }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { throw cleanError("无法编码界面图") }
            let path = directory.appendingPathComponent(page.rawValue + ".png")
            try png.write(to: path, options: .atomic)
            print("RENDERED: \(path.path) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
            window.contentView = nil
        }
        print("NATIVE UI RENDER PASSED")
    }
}
