import SwiftUI
import AppKit

@main
struct MacCleanApp: App {
    init() {
        if let index = CommandLine.arguments.firstIndex(of: "--render-public-docs"), CommandLine.arguments.count > index + 1 {
            do { try UIValidation.renderPublic(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1])); exit(0) }
            catch { print("PUBLIC UI RENDER FAILED: \(error)"); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-saved"), CommandLine.arguments.count > index + 2 {
            do {
                try UIValidation.render(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1]), root: URL(fileURLWithPath: "."), savedReport: URL(fileURLWithPath: CommandLine.arguments[index + 2]))
                exit(0)
            } catch { print("UI RENDER FAILED: \(error)"); exit(1) }
        }
        if CommandLine.arguments.contains("--apps-json") {
            let result = AppScanner.inventory(control: ScanControl())
            do { print(String(decoding: try JSONEncoder().encode(result), as: UTF8.self)); exit(0) }
            catch { print("\(error)"); exit(1) }
        }
        if CommandLine.arguments.contains("--quick-scan-summary") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let activity = ActivitySnapshot.capture()
            let advisor = RecommendationEngine(home: home)
            let scanned = QuickCleaning.scan(home: home, control: ScanControl()) { _ in }
            do {
                let report = advisor.apply(to: scanned, activity: activity, kept: try KeepStore().load())
                let groups = Dictionary(grouping: report.candidates, by: { QuickCleaning.owner($0, home: home) })
                let rows = groups.keys.sorted().map { name in
                    let items = groups[name] ?? []
                    return ["group": name, "bytes": items.reduce(Int64(0)) { $0 + $1.item.logicalSize }, "decisions": Dictionary(grouping: items, by: { $0.advice?.rule ?? "unknown" }).mapValues { $0.reduce(Int64(0)) { $0 + $1.item.logicalSize } }] as [String: Any]
                }
                let summary: [String: Any] = ["visited": report.visited, "elapsed": report.elapsed, "errors": report.accessErrorCount ?? report.issues.count, "recommendedBytes": report.candidates.filter { $0.advice?.decision == .delete }.reduce(Int64(0)) { $0 + $1.item.logicalSize }, "groups": rows]
                print(String(decoding: try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)); exit(0)
            } catch { print("SCAN SUMMARY FAILED: \(error)"); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-preview"), CommandLine.arguments.count > index + 2 {
            do {
                try UIValidation.render(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1]), root: URL(fileURLWithPath: CommandLine.arguments[index + 2]))
                exit(0)
            } catch { print("UI RENDER FAILED: \(error)"); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--make-icon"), CommandLine.arguments.count > index + 1 {
            do { try IconMaker.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])); exit(0) }
            catch { print("\(error)"); exit(1) }
        }
        if CommandLine.arguments.contains("--self-test") {
            do { try Verification.run() }
            catch { print("SELF TEST FAILED: \(error)"); exit(1) }
            NSApplication.shared.setActivationPolicy(.prohibited)
            Task { @MainActor in
                do { try await Verification.verifyOneClick(); print("ALL INTEGRATION CHECKS PASSED"); exit(0) }
                catch { print("ONE CLICK TEST FAILED: \(error)"); exit(1) }
            }
            NSApplication.shared.run()
        }
        if let index = CommandLine.arguments.firstIndex(of: "--scan-json"), CommandLine.arguments.count > index + 1 {
            let root = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            let result = ScanEngine.scan(roots: [root], options: ScanOptions(), control: ScanControl()) { _ in }
            do {
                let report = RecommendationEngine().apply(to: result, activity: ActivitySnapshot.capture(), kept: try KeepStore().load())
                let data = try JSONEncoder().encode(report); print(String(decoding: data, as: UTF8.self)); exit(0)
            }
            catch { print("\(error)"); exit(1) }
        }
        NSApplication.shared.setActivationPolicy(.regular)
    }
    var body: some Scene {
        WindowGroup("MacClean") { ContentView() }
            .defaultSize(width: 1240, height: 820)
            .windowStyle(.hiddenTitleBar)
        Settings { Text("扫描深度、阈值和范围在主窗口右上角的扫描设置中调整。").padding(30) }
    }
}
