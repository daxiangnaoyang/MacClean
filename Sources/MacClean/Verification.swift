import Foundation

enum Verification {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw cleanError(message) }
    }
    static func run() throws {
        let fm = FileManager.default
        try expect(PathPolicy.runtimeProtectedTrees.contains(Bundle.main.bundlePath), "Running bundle protection missing")
        do {
            try PathPolicy(allowedRoots: ["/"]).validate(Bundle.main.bundlePath)
            throw cleanError("Running bundle accepted for cleanup")
        } catch { try expect((error as NSError).localizedDescription != "Running bundle accepted for cleanup", "Running bundle protection failed") }
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("MacClean-test-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) } // This exact directory is created exclusively by this test.
        let deep = root.appendingPathComponent("scan/one/two/three/four/five")
        try fm.createDirectory(at: deep, withIntermediateDirectories: true)
        for n in 0..<80 { try Data(repeating: 1, count: 1024).write(to: deep.appendingPathComponent("\(n).txt")) }
        try Data(repeating: 2, count: 2048).write(to: deep.appendingPathComponent(".hidden"))
        let scanRoot = root.appendingPathComponent("scan")
        try fm.createSymbolicLink(at: scanRoot.appendingPathComponent("cycle"), withDestinationURL: scanRoot)
        let report = ScanEngine.scan(roots: [scanRoot, deep], options: ScanOptions(), control: ScanControl()) { _ in }
        try expect(report.measuredSize == 80 * 1024 + 2048, "Deep recursive aggregate is wrong")
        try expect(report.roots.count == 1, "Overlapping roots were counted twice")
        try expect(report.skippedLinks == 1, "Symbolic-link loop was not skipped")
        try expect(report.topItems.first?.fileCount == 81, "Files beyond first 40 / hidden files not measured")
        let shallow = ScanEngine.scan(roots: [scanRoot], options: ScanOptions(maxDepth: 2), control: ScanControl()) { _ in }
        try expect(shallow.limited && !shallow.isComplete, "Depth cap presented as full coverage")
        let limited = ScanEngine.scan(roots: [scanRoot], options: ScanOptions(entryLimit: 8), control: ScanControl()) { _ in }
        try expect(limited.limited && limited.visited <= 8, "Entry budget not respected")
        let stop = ScanControl(); stop.cancel()
        let cancelled = ScanEngine.scan(roots: [scanRoot], options: ScanOptions(), control: stop) { _ in }
        try expect(cancelled.cancelled && cancelled.visited == 0, "Cancellation not respected")
        let missing = ScanEngine.scan(roots: [root.appendingPathComponent("missing")], options: ScanOptions(), control: ScanControl()) { _ in }
        try expect(!missing.issues.isEmpty && !missing.isComplete, "Missing path silently presented as empty")
        try expect(ScanEngine.type(for: URL(fileURLWithPath: "video.MP4"), directory: false) == "视频", "Video type recognition failed")
        try expect(ScanEngine.type(for: URL(fileURLWithPath: "Installer.dmg"), directory: false) == "安装包", "Installer type recognition failed")
        try expect(ScanEngine.type(for: URL(fileURLWithPath: "data.img"), directory: false) == "虚拟磁盘", "Virtual disk type recognition failed")
        try expect(ScanEngine.type(for: fm.homeDirectoryForCurrentUser.appendingPathComponent(".ollama/models/blobs/sha256-fixture"), directory: false) == "本地模型", "Extensionless model blob type recognition failed")
        print("PASS: deep recursion, >40 files, hidden files, root deduplication, symlink loop, depth/entry caps, cancellation, coverage errors, file types")

        let home = fm.homeDirectoryForCurrentUser.path
        let now = Date()
        func virtual(_ path: String, age: Int, directory: Bool = false, size: Int64 = 200 * 1024 * 1024, complete: Bool = true) -> ScanItem {
            let url = URL(fileURLWithPath: path)
            return ScanItem(path: path, name: url.lastPathComponent, isDirectory: directory, logicalSize: size, allocatedSize: size, fileCount: 1,
                            modified: now.addingTimeInterval(-Double(age) * 86400), type: ScanEngine.type(for: url, directory: directory), complete: complete)
        }
        // Classification is pure except for deletion eligibility; nonexistent virtual files receive protected status.
        let inputs = [virtual(home + "/Downloads/old.dmg", age: 15), virtual(home + "/Downloads/fresh.dmg", age: 1, size: 100),
                      virtual(home + "/Downloads/personal.pdf", age: 100), virtual(home + "/Library/Logs/old.log", age: 31),
                      virtual(home + "/Movies/big.mp4", age: 2), virtual(home + "/Library/Caches/example.app", age: 1, directory: true),
                      virtual(home + "/Library/Caches/example.app/a.dat", age: 1), virtual(home + "/Library/Caches/incomplete", age: 1, directory: true, complete: false)]
        let rules = ScanEngine.classify(inputs, roots: [], options: ScanOptions(), now: now)
        try expect(rules.contains { $0.category == "旧安装包" && $0.item.name == "old.dmg" }, "Old installer rule failed")
        try expect(!rules.contains { $0.item.name == "fresh.dmg" }, "Recent small download classified as junk")
        try expect(rules.contains { $0.category == "陈旧下载" }, "Old download rule failed")
        try expect(rules.contains { $0.category == "旧日志" }, "Log age rule failed")
        try expect(rules.contains { $0.category == "大文件" && $0.item.type == "视频" }, "Large video rule failed")
        try expect(!rules.contains { $0.item.name == "a.dat" }, "Parent/child cleaning candidates duplicated")
        try expect(!rules.contains { $0.item.name == "incomplete" }, "Incomplete directory eligible for clearing")
        print("PASS: rule ages, fresh-download exclusion, video classification, non-overlapping candidates, partial directory exclusion")

        let fakeHome = root.appendingPathComponent("fake-home")
        let id = "com.macclean.fixture.editor"
        for relative in ["Library/Preferences/\(id).plist", "Library/Preferences/\(id)Pro.plist", "Library/Caches/\(id)/cache.bin", "Library/Group Containers/shared.fixture/state.bin"] {
            let url = fakeHome.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: 4096).write(to: url)
        }
        let app = AppInfo(name: "Editor", path: "/Applications/Fixture.app", bundleID: id, version: "1", size: 1, complete: true, protected: false)
        let related = AppScanner.related(to: app, home: fakeHome, control: ScanControl())
        try expect(related.items.count == 2 && related.items.allSatisfy { !$0.item.path.contains("Group Containers") && !$0.item.path.contains("Pro.plist") }, "App associations included a shared or similarly-named item")
        try expect(related.items.allSatisfy { $0.risk == .review }, "App data was treated as disposable cache")
        print("PASS: exact Bundle ID matching, similar-name exclusion, shared-container exclusion, personal app-data review")
        try verifyAdvice(root: root)

        let targetDir = root.appendingPathComponent("actions")
        try fm.createDirectory(at: targetDir, withIntermediateDirectories: false)
        let target = targetDir.appendingPathComponent("fixture.txt")
        let fixture = Data("MacClean recoverable fixture".utf8)
        try fixture.write(to: target)
        let policy = PathPolicy(allowedRoots: [root.path])
        let store = TrashStore(journalURL: root.appendingPathComponent("journal/history.json"), policy: policy)
        let first = try store.trash([ActionTarget(path: target.path, size: Int64(fixture.count))])
        guard let record = first.first else { throw cleanError("Missing trash record") }
        try expect(record.status == "已移入废纸篓" && record.trashPath != nil && !fm.fileExists(atPath: target.path), "Fixture was not trashed with actual result URL")
        try Data("conflict".utf8).write(to: target)
        var rejected = false
        do { _ = try store.restore(record.id) } catch { rejected = true }
        try expect(rejected, "Restore overwrote existing file")
        try fm.removeItem(at: target) // Only the conflicting test file created directly above.
        let restored = try store.restore(record.id)
        try expect(restored.first?.status == "已恢复", "Restore status not persisted")
        let recovered = try Data(contentsOf: target)
        try expect(recovered == fixture, "Restored contents differ")
        let failed = try store.trash([ActionTarget(path: root.appendingPathComponent("does-not-exist").path, size: 0)])
        try expect(failed.first?.status == "失败" && failed.first?.error != nil, "Failure silently reported as success")
        let changed = targetDir.appendingPathComponent("changed.txt")
        try fixture.write(to: changed)
        let stale = ActionTarget(path: changed.path, size: 10)
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(300)], ofItemAtPath: changed.path)
        let rejectedChange = try store.trash([stale])
        try expect(rejectedChange.first?.status == "失败" && fm.fileExists(atPath: changed.path), "Stale target was removed")
        do { try PathPolicy().validate(home + "/Documents"); throw cleanError("Protected root accepted") }
        catch { try expect(error.localizedDescription != "Protected root accepted", "Protected root accepted") }
        try expect(TrashStore.nonOverlapping([ActionTarget(path: targetDir.path, size: 10), ActionTarget(path: target.path, size: 1)]).count == 1, "Overlapping operations not deduplicated")
        try Data("not json".utf8).write(to: store.journalURL)
        var corruptRejected = false
        do { _ = try store.trash([ActionTarget(path: changed.path, size: 10)]) } catch { corruptRejected = true }
        try expect(corruptRejected && fm.fileExists(atPath: changed.path), "Corrupt journal ignored before deletion")
        print("PASS: real test-file trash/restore, persisted journal, conflict preservation, failure reporting, stale-target guard, protected roots, operation deduplication, corrupt-journal abort")
        print("ALL CHECKS PASSED (only generated fixtures were moved or removed)")
    }

    static func verifyAdvice(root: URL) throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let engine = RecommendationEngine(); let now = Date()
        let idle = ActivitySnapshot(known: true, processNames: [])
        func item(_ path: String, type: String, directory: Bool = false, age: Int = 45, latestAge: Int? = 45, complete: Bool = true) -> ScanItem {
            var result = ScanItem(path: path, name: String(path.split(separator: "/").last ?? ""), isDirectory: directory, logicalSize: 100,
                                  allocatedSize: 100, fileCount: 1, modified: now.addingTimeInterval(-Double(age) * 86400), type: type, complete: complete)
            result.latestModified = latestAge.map { now.addingTimeInterval(-Double($0) * 86400) }; return result
        }
        let chrome = Candidate(item: item(home + "/Library/Caches/com.google.Chrome", type: "文件夹", directory: true), category: "应用缓存", reason: "fixture", risk: .regenerable)
        try expect(engine.advice(for: chrome, activity: idle).decision == .delete, "Idle old known cache not recommended")
        try expect(engine.advice(for: chrome, activity: ActivitySnapshot(known: true, processNames: ["google chrome helper (renderer)"])).decision == .required, "Running browser helper not protected")
        try expect(engine.advice(for: chrome, activity: ActivitySnapshot(known: false, processNames: [])).decision == .keep, "Unknown activity treated as unused")
        var recent = chrome
        recent = Candidate(item: item(chrome.id, type: "文件夹", directory: true, age: 90, latestAge: 1), category: chrome.category, reason: "fixture", risk: .regenerable)
        try expect(engine.advice(for: recent, activity: idle).decision == .keep, "Recently changed child hidden by old directory timestamp")
        let missingDate = Candidate(item: item(chrome.id, type: "文件夹", directory: true, latestAge: nil), category: chrome.category, reason: "fixture", risk: .regenerable)
        try expect(engine.advice(for: missingDate, activity: idle).decision == .keep, "Old receipt without child dates was recommended")
        let partial = Candidate(item: item(chrome.id, type: "文件夹", directory: true, complete: false), category: chrome.category, reason: "fixture", risk: .regenerable)
        try expect(engine.advice(for: partial, activity: idle).decision == .keep, "Partial directory recommended")
        let npm = Candidate(item: item(home + "/.npm/_cacache/content-v2", type: "文件夹", directory: true), category: "开发缓存", reason: "fixture", risk: .regenerable)
        try expect(engine.advice(for: npm, activity: ActivitySnapshot(known: true, processNames: ["node"])).decision == .required, "Active npm/Node cache recommended")
        try expect(engine.advice(for: npm, activity: idle).decision == .delete, "Idle old npm cache not recognized")
        let unknown = Candidate(item: item(home + "/Library/Caches/unknown", type: "文件夹", directory: true), category: "应用缓存", reason: "fixture", risk: .regenerable)
        try expect(engine.advice(for: unknown, activity: idle).decision == .keep, "Unknown cache assumed disposable")
        for (path, type) in [(home + "/Library/Application Support/Test/data.img", "虚拟磁盘"), (home + "/.ollama/models/blobs/sha256-test", "本地模型"), (home + "/Downloads/data.sqlite", "数据库"), (home + "/Documents/app/node_modules/a.js", "代码"), ("/System/Library/a.dylib", "其他")] {
            let c = Candidate(item: item(path, type: type), category: "大文件", reason: "fixture", risk: .personal)
            try expect(engine.advice(for: c, activity: idle).decision == .required, "Essential or managed file was removable: " + path)
        }
        let installer = Candidate(item: item(home + "/Downloads/installer.dmg", type: "安装包"), category: "旧安装包", reason: "fixture", risk: .review)
        try expect(engine.advice(for: installer, activity: idle).decision == .keep, "Installer automatically recommended")
        let log = Candidate(item: item(home + "/Library/Logs/test.log", type: "日志"), category: "旧日志", reason: "fixture", risk: .review)
        try expect(engine.advice(for: log, activity: idle).decision == .delete, "Old log not recommended")
        try expect(engine.advice(for: log, activity: idle, kept: [home + "/Library/Logs"]).decision == .keep, "User-kept parent not respected")
        let keep = KeepStore(url: root.appendingPathComponent("preferences/keep.json"))
        try keep.save([log.id]); let roundTrip = try keep.load()
        try expect(roundTrip == Set([log.id]), "Keep preferences not persisted")
        let fm = FileManager.default
        let fakeHome = root.appendingPathComponent("preflight-home")
        let cache = fakeHome.appendingPathComponent("Library/Caches/com.google.Chrome")
        let child = cache.appendingPathComponent("deep/cache.bin")
        try fm.createDirectory(at: child.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 128).write(to: child)
        let old = now.addingTimeInterval(-45 * 86400)
        for url in [child, child.deletingLastPathComponent(), cache] { try fm.setAttributes([.modificationDate: old], ofItemAtPath: url.path) }
        let baseline = ScanEngine.scan(roots: [cache], options: ScanOptions(), control: ScanControl()) { _ in }
        guard let scanned = baseline.topItems.first else { throw cleanError("Missing preflight cache") }
        let c = Candidate(item: scanned, category: "应用缓存", reason: "fixture", risk: .regenerable)
        let fakeEngine = RecommendationEngine(home: fakeHome.path)
        let fakePolicy = PathPolicy(allowedRoots: [fakeHome.path])
        try expect(fakeEngine.prepare([c], activity: idle, kept: [], policy: fakePolicy).ready.count == 1, "Unchanged cache rejected by preflight")
        try Data(repeating: 2, count: 128).write(to: child)
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: cache.path)
        let changed = fakeEngine.prepare([c], activity: idle, kept: [], policy: fakePolicy)
        try expect(changed.ready.isEmpty && changed.skipped.count == 1 && fm.fileExists(atPath: child.path), "Nested same-size modification did not stop clearing")
        print("PASS: delete/keep/required decisions, known/unknown cache ownership, recent descendants, unknown activity, active tool/browser protection, managed data, personal files, persistent parent keeps")
    }

    @MainActor static func verifyOneClick() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("MacClean-advice-test-" + UUID().uuidString)
        let fakeHome = root.appendingPathComponent("home")
        let logs = fakeHome.appendingPathComponent("Library/Logs")
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var candidates: [Candidate] = []
        for name in ["delete.log", "keep.log", "opened.log"] {
            let url = logs.appendingPathComponent(name)
            try Data("recoverable-advice-fixture".utf8).write(to: url)
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-45 * 86400)], ofItemAtPath: url.path)
            let scan = ScanEngine.scan(roots: [url], options: ScanOptions(), control: ScanControl()) { _ in }
            guard let item = scan.topItems.first else { throw cleanError("Fixture scan missing") }
            candidates.append(Candidate(item: item, category: "旧日志", reason: "fixture", risk: .review))
        }
        let manual = logs.appendingPathComponent("manual.pdf")
        try Data("manual personal fixture".utf8).write(to: manual)
        let manualScan = ScanEngine.scan(roots: [manual], options: ScanOptions(), control: ScanControl()) { _ in }
        guard let manualItem = manualScan.topItems.first else { throw cleanError("Missing manual fixture") }
        candidates.append(Candidate(item: manualItem, category: "大文件", reason: "fixture", risk: .personal))
        let policy = PathPolicy(allowedRoots: [fakeHome.path])
        let journal = TrashStore(journalURL: root.appendingPathComponent("state/history.json"), policy: policy)
        let keepStore = KeepStore(url: root.appendingPathComponent("state/keep.json"))
        let model = CleanerModel(store: journal, keepStore: keepStore, advisor: RecommendationEngine(home: fakeHome.path))
        model.report = ScanReport(roots: [logs.path], items: candidates.map(\.item), candidates: candidates)
        model.refreshRecommendations()
        model.setChoice(.keep, for: candidates[1])
        model.setChoice(.delete, for: candidates[3])
        try expect(model.recommended.count == 2, "Kept item entered one-click suggestions")
        let opened = try FileHandle(forReadingFrom: logs.appendingPathComponent("opened.log"))
        defer { try? opened.close() }
        model.deleteRecommended()
        for _ in 0..<1500 { if !model.busy { break }; try await Task.sleep(for: .milliseconds(20)) }
        try expect(!model.busy, "One-click operation timed out")
        try expect(!fm.fileExists(atPath: candidates[0].id), "Eligible old log was not trashed: " + (model.notice ?? ""))
        try expect(fm.fileExists(atPath: candidates[1].id), "User-kept item was deleted")
        try expect(fm.fileExists(atPath: candidates[2].id), "Open file was deleted")
        try expect(fm.fileExists(atPath: candidates[3].id), "Manual personal choice entered automatic recommendations")
        try expect(model.recommendation(candidates[2]).decision == .required, "Open-file failure did not become keep advice")
        guard let record = model.history.first(where: { $0.original == candidates[0].id && $0.status == "已移入废纸篓" }) else { throw cleanError("Missing one-click restore record") }
        _ = try journal.restore(record.id)
        try expect(fm.fileExists(atPath: candidates[0].id), "One-click result could not be restored")
        let restarted = CleanerModel(store: journal, keepStore: keepStore, advisor: RecommendationEngine(home: fakeHome.path))
        try expect(restarted.keptPaths.contains(candidates[1].id), "Keep setting lost on restart")
        try Data("broken".utf8).write(to: keepStore.url)
        let corrupt = CleanerModel(store: journal, keepStore: keepStore, advisor: RecommendationEngine(home: fakeHome.path))
        corrupt.report = model.report; corrupt.deleteRecommended()
        try expect(!corrupt.keepReady && !corrupt.busy, "Corrupt keeps allowed one-click deletion")
        corrupt.setChoice(.keep, for: candidates[3])
        let unchanged = try Data(contentsOf: keepStore.url)
        try expect(unchanged == Data("broken".utf8), "Corrupt preference was silently overwritten")
        print("PASS: actual one-click model execution, persistent keep exclusion, open-file interception, per-item journal, restore, restart persistence, corrupt-preference block")
    }
}
