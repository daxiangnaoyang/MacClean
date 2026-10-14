import SwiftUI
import AppKit

// The installed preview SDK also exposes a State macro whose plugin is absent from CLT.
// A type alias selects the stable property wrapper used on macOS 14 and later.
private typealias ViewState<Value> = SwiftUI.State<Value>

private let accent = Color(red: 0.24, green: 0.85, blue: 0.73)
private let canvas = Color(red: 0.055, green: 0.07, blue: 0.095)
private let panelColor = Color(red: 0.09, green: 0.11, blue: 0.145)
private let chartColors: [Color] = [accent, .blue, .purple, .orange, .pink, .cyan, .indigo, .gray]

struct ContentView: View {
    @StateObject private var model = CleanerModel()
    @ViewState private var settings = false
    init(model: CleanerModel = CleanerModel()) { _model = StateObject(wrappedValue: model) }
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(alignment: .leading, spacing: 0) {
                toolbar
                if model.scanning { scanProgress }
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        switch model.page {
                        case .overview: overview
                        case .space: SpaceView(model: model)
                        case .rules: RulesView(model: model)
                        case .apps: ApplicationsView(model: model)
                        case .history: RecoveryView(model: model)
                        }
                    }.padding(28)
                }
                if let notice = model.notice {
                    HStack { Image(systemName: "info.circle"); Text(notice).font(.callout); Spacer(); Button { model.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
                        .padding(14).background(accent.opacity(0.08))
                }
            }.background(canvas)
        }
        .frame(minWidth: 1100, minHeight: 760)
        .preferredColorScheme(.dark).tint(accent)
        .sheet(isPresented: $settings) { ScanSettings(model: model) }
        .sheet(isPresented: $model.confirm) { ConfirmSheet(model: model) }
        .onChange(of: model.page) { _, page in
            model.query = ""
            if page == .apps && model.apps.isEmpty { model.loadApps() }
            if page == .history { model.refreshHistory() }
        }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.fill.badge.checkmark").font(.system(size: 29)).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 1) { Text("MacClean").font(.system(size: 21, weight: .bold)); Text("SPACE, WITH CLARITY").font(.system(size: 8, weight: .medium, design: .rounded)).tracking(1.3).foregroundStyle(.secondary) }
            }.padding(.top, 35).padding(.bottom, 34)
            Text("工作空间").font(.caption).foregroundStyle(.secondary).padding(.bottom, 7)
            ForEach(Page.allCases, id: \.self) { page in
                Button { model.page = page } label: {
                    HStack(spacing: 13) {
                        Image(systemName: page.icon).frame(width: 20)
                        Text(page.rawValue).font(.system(size: 14, weight: .medium)); Spacer()
                        if page == .rules, !model.candidates.isEmpty { Text("\(model.candidates.count)").font(.caption2).padding(.horizontal, 6).padding(.vertical, 3).background(.white.opacity(0.07)).clipShape(Capsule()) }
                    }.foregroundStyle(model.page == page ? accent : .white.opacity(0.7)).padding(.horizontal, 12).padding(.vertical, 13)
                        .background(model.page == page ? accent.opacity(0.1) : .clear).clipShape(RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 9) {
                Label("可恢复操作", systemImage: "shield.lefthalf.filled").foregroundStyle(accent).font(.callout.weight(.medium))
                Text("选中后预览确认\n移入系统废纸篓\n恢复记录保存在本机").font(.caption).foregroundStyle(.secondary).lineSpacing(5)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius: 12))
            Text("LOCAL · v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.3.1")").font(.system(size: 10, weight: .medium)).tracking(1).foregroundStyle(.tertiary).padding(.top, 12)
        }.padding(.horizontal, 20).padding(.bottom, 22).frame(width: 224).background(Color(red: 0.075, green: 0.09, blue: 0.12))
    }
    private var toolbar: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) { Text(model.page.rawValue).font(.system(size: 27, weight: .bold)); Text(model.page.subtitle).font(.callout).foregroundStyle(.secondary) }
            Spacer(minLength: 10)
            Button { settings = true } label: { Image(systemName: "gearshape").font(.title3) }.buttonStyle(.plain).help("扫描设置与目录范围")
            Button { model.exportReport() } label: { Image(systemName: "square.and.arrow.up").font(.title3) }.buttonStyle(.plain).disabled((model.page == .space ? model.analysisReport : model.report) == nil).help("导出当前页面的 JSON 扫描报告")
            if model.page == .apps {
                if model.appLoading { Button("停止应用扫描", systemImage: "stop.fill") { model.cancelApps() }.buttonStyle(.bordered) }
                else { Button("刷新应用", systemImage: "arrow.clockwise") { model.loadApps() }.buttonStyle(.borderedProminent).disabled(model.busy) }
            } else if model.page == .history {
                Button("刷新记录", systemImage: "arrow.clockwise") { model.refreshHistory() }.buttonStyle(.bordered)
            } else if model.scanning {
                Button("停止扫描", systemImage: "stop.fill") { model.cancel() }.buttonStyle(.bordered)
            } else {
                Button(model.page == .space ? "全盘空间分析" : "快速扫描", systemImage: "viewfinder") { model.scan() }.buttonStyle(.borderedProminent).foregroundStyle(canvas).controlSize(.large).disabled(model.busy || (model.page == .space && model.roots.isEmpty))
            }
        }.padding(.horizontal, 28).padding(.top, 30).padding(.bottom, 22)
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.07)).frame(height: 1) }
    }
    private var scanProgress: some View {
        HStack(spacing: 16) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 5) {
                Text("正在递归分析 · \(model.progress.visited.formatted()) 个项目 · \(bytes(model.progress.measured))").font(.callout.weight(.medium))
                Text(model.progress.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }; Spacer()
            Text(model.scanIsAnalysis ? "空间分析" : "快速清理 · 定向扫描").font(.caption).foregroundStyle(accent)
        }.padding(18).background(accent.opacity(0.08))
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 24) {
            let disk = model.disk
            HStack {
                VStack(alignment: .leading, spacing: 7) {
                    Text("先清理能确认用途的缓存。").font(.system(size: 30, weight: .bold))
                    Text("\(bytes(disk.free)) 可用 / \(bytes(disk.total)) 总容量").foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "sparkles").font(.system(size: 38)).foregroundStyle(accent)
            }
            VStack(alignment: .leading, spacing: 18) {
                Label("快速清理", systemImage: "sparkles").font(.title2.bold())
                Text("检查浏览器缓存、npm / pip 下载缓存、Xcode 构建缓存及旧日志。不先遍历整个硬盘，不扫描文档目录、照片资料库或聊天数据库。").foregroundStyle(.secondary)
                HStack {
                    Button(model.report == nil ? "开始快速扫描" : "重新快速扫描", systemImage: "magnifyingglass") { model.scan() }
                        .buttonStyle(.borderedProminent).controlSize(.large).foregroundStyle(canvas).disabled(model.scanning || model.busy)
                    if model.report != nil { Button("查看清理结果") { model.page = .rules }.controlSize(.large) }
                    Spacer()
                    Text("只扫描，不自动删除").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(28).card()
            if model.report != nil {
                HStack(spacing: 14) {
                    MetricCard(title: "已识别可再生成缓存", value: bytes(model.recognizedCacheSize), foot: "按用途识别，不等于现在都可删除", icon: "archivebox", color: .blue)
                    MetricCard(title: "建议清理", value: bytes(model.recommendedSize), foot: "\(model.recommended.count) 项通过保守判断", icon: "checkmark.seal", color: accent)
                    MetricCard(title: "退出相关应用后检查", value: bytes(model.deferredCacheSize), foot: "不会替你强制关闭程序", icon: "pause.circle", color: .orange)
                }
                RecommendationSummary(model: model)
            }
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("空间分析", systemImage: "chart.pie").font(.headline)
                    Text("找出大文件和空间去向。完整扫描单独进行，结果不会混入快速清理。").font(.callout).foregroundStyle(.secondary)
                    Button("打开空间分析") { model.page = .space }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading).card()
                VStack(alignment: .leading, spacing: 12) {
                    Label("应用卸载", systemImage: "square.stack.3d.up").font(.headline)
                    Text("查看应用本体和关联文件。关联数据单独确认，避免误删个人内容。").font(.callout).foregroundStyle(.secondary)
                    Button("管理已安装应用") { model.page = .apps }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading).card()
            }
            Text("首次访问受保护内容需系统授权；固定签名及已保存目录授权继续沿用。扫描失败的目录可以单独查看原因。").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private extension View {
    func card() -> some View { background(panelColor).clipShape(RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.06), lineWidth: 1)) }
}

private struct MetricCard: View {
    let title: String; let value: String; let foot: String; let icon: String; let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { HStack { Text(title).font(.callout).foregroundStyle(.secondary); Spacer(); Image(systemName: icon).foregroundStyle(color) }; Text(value).font(.system(size: 27, weight: .bold, design: .rounded)); Text(foot).font(.caption).foregroundStyle(.tertiary) }.padding(20).frame(maxWidth: .infinity, alignment: .leading).card()
    }
}

private struct SectionTitle: View {
    let title: String; let subtitle: String; var action: String? = nil; var perform: () -> Void = {}
    var body: some View { HStack { VStack(alignment: .leading, spacing: 5) { Text(title).font(.title3.bold()); Text(subtitle).font(.caption).foregroundStyle(.secondary) }; Spacer(); if let action { Button(action, action: perform).buttonStyle(.plain).foregroundStyle(accent).font(.callout) } } }
}

private struct CoverageCard: View {
    let report: ScanReport
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Image(systemName: report.isComplete ? "checkmark.circle.fill" : "exclamationmark.circle.fill").foregroundStyle(report.isComplete ? accent : .orange); Text(report.cancelled ? "扫描已停止 · 保留部分结果" : report.isComplete ? "所选范围扫描完成" : "扫描完成 · 存在未覆盖部分").font(.callout.weight(.medium)); Spacer(); Text("\(report.visited.formatted()) 项 · \(report.elapsed.formatted(.number.precision(.fractionLength(1)))) 秒").font(.caption).foregroundStyle(.secondary) }
            Text("统计是逻辑大小与已分配空间估算；APFS 克隆、硬链接、快照会影响真正可释放空间。").font(.caption).foregroundStyle(.secondary)
            Text("扫描时间：\(report.date.formatted())").font(.caption2).foregroundStyle(.tertiary)
            Text("取得 \(report.topItems.count) / \(report.roots.count) 个根目录的统计；范围内未读取的项目不会算作零占用。").font(.caption).foregroundStyle(.secondary)
            if report.entryLimitReached == true { Text("达到自选条目上限 \(report.options.entryLimit.formatted())；在设置中改为“不限”可继续深入。").font(.caption).foregroundStyle(.orange) }
            if report.depthLimitReached == true { Text("达到自选深度上限 \(report.options.maxDepth) 层；改为“全部层级”后重扫。").font(.caption).foregroundStyle(.orange) }
            if report.limited && report.entryLimitReached == nil && report.depthLimitReached == nil { Text("旧报告达到深度或条目上限，请用新版不限模式重扫。").font(.caption).foregroundStyle(.orange) }
            if let excluded = report.excludedPaths, !excluded.isEmpty { Text("主动排除 APFS 卷镜像（/System/Volumes），避免重复统计；不是条目不足。").font(.caption).foregroundStyle(.secondary) }
            Text("文件统计无法等同磁盘已用空间：系统快照、文件系统元数据、其他用户及访问受限内容可能未归属。未覆盖不代表垃圾，也不代表零占用。").font(.caption).foregroundStyle(.secondary)
            if report.skippedCloud > 0 { Text("\(report.skippedCloud) 个未下载的云端文件被跳过。").font(.caption).foregroundStyle(.orange) }
            if report.skippedLinks > 0 { Text("跳过 \(report.skippedLinks) 个符号链接，避免重复统计和越界。").font(.caption).foregroundStyle(.secondary) }
            if !report.issues.isEmpty {
                DisclosureGroup("\(report.accessErrorCount ?? report.issues.count) 处访问错误（展示前 250 处）") {
                    ForEach(report.issues) { issue in VStack(alignment: .leading, spacing: 3) { Text(issue.path).textSelection(.enabled); Text(issue.message).foregroundStyle(.secondary) }.font(.caption).padding(.vertical, 5) }
                    Button("打开完全磁盘访问设置") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!) }.font(.caption)
                }.font(.caption).foregroundStyle(.orange)
            }
        }.padding(18).card()
    }
}

private struct DistributionView: View {
    let items: [ScanItem]; var action: (String) -> Void
    var body: some View {
        let total = max(1, items.reduce(Int64(0)) { $0 + $1.logicalSize })
        VStack(spacing: 14) {
            ForEach(Array(items.prefix(8).enumerated()), id: \.element.id) { index, item in
                Button { action(item.path) } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "folder.fill").foregroundStyle(chartColors[index % chartColors.count]).frame(width: 24)
                        VStack(alignment: .leading, spacing: 5) { Text(item.name).font(.callout.weight(.medium)); Text(item.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }.frame(width: 220, alignment: .leading)
                        GeometryReader { g in ZStack(alignment: .leading) { Capsule().fill(.white.opacity(0.04)); Capsule().fill(chartColors[index % chartColors.count]).frame(width: max(2, g.size.width * Double(item.logicalSize) / Double(total))) } }.frame(height: 7)
                        Text((item.complete ? "" : "≥ ") + bytes(item.logicalSize)).font(.callout.monospacedDigit()).frame(width: 100, alignment: .trailing)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }.padding(22).card()
    }
}

private struct EmptyScan: View {
    @ObservedObject var model: CleanerModel
    var body: some View { ContentUnavailableView { Label(model.page == .space ? "分析空间去向" : "先检查常见缓存", systemImage: "viewfinder") } description: { Text(model.page == .space ? "按设置的完整范围递归统计。此操作可能较慢，不会自动删除，也不影响快速清理结果。" : "定向检查缓存与日志，完成后按应用查看建议。") } actions: { Button(model.page == .space ? "开始全盘分析" : "开始快速扫描") { model.scan() }.disabled(model.scanning).buttonStyle(.borderedProminent) }.padding(.vertical, 80) }
}

struct SpaceView: View {
    @ObservedObject var model: CleanerModel
    @ViewState private var limit = 300
    var body: some View {
        if let report = model.analysisReport {
            VStack(alignment: .leading, spacing: 18) {
                if model.analysisStale { Text("范围或文件已改变，这是上次分析结果；请重新分析更新占用。").font(.caption).foregroundStyle(.orange) }
                CoverageCard(report: report)
                let grouped = Dictionary(grouping: report.items.filter { !$0.isDirectory }, by: \.type)
                let kinds = grouped.keys.sorted { (grouped[$0] ?? []).reduce(Int64(0)) { $0 + $1.logicalSize } > (grouped[$1] ?? []).reduce(Int64(0)) { $0 + $1.logicalSize } }
                Text("文件类型 · 点击跨目录查看同类型文件（包内容仅计入目录聚合）").font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
                    Button { model.spaceType = "全部"; model.query = "" } label: { VStack(alignment: .leading, spacing: 6) { Text("按目录查看").font(.callout.weight(.medium)); Text("逐层展开").font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(model.spaceType == "全部" ? accent.opacity(0.1) : panelColor).clipShape(RoundedRectangle(cornerRadius: 9)) }.buttonStyle(.plain)
                    ForEach(kinds, id: \.self) { kind in
                        let files = grouped[kind] ?? []
                        Button { model.spaceType = kind; model.folder = nil; model.query = "" } label: { VStack(alignment: .leading, spacing: 6) { HStack { Text(kind).font(.callout.weight(.medium)); Spacer(); Text("\(files.count)").font(.caption2).foregroundStyle(.secondary) }; Text(bytes(files.reduce(0) { $0 + $1.logicalSize })).font(.caption).foregroundStyle(accent) }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(model.spaceType == kind ? accent.opacity(0.1) : panelColor).clipShape(RoundedRectangle(cornerRadius: 9)) }.buttonStyle(.plain)
                    }
                }
                HStack {
                    Button("扫描目录", systemImage: "house") { model.spaceType = "全部"; model.folder = nil; model.query = "" }
                    if model.spaceType != "全部" { Text("/ 全部已扫描目录中的" + model.spaceType).font(.caption).foregroundStyle(accent) }
                    if let folder = model.folder {
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        Text(folder).font(.callout).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Button { let parent = URL(fileURLWithPath: folder).deletingLastPathComponent().path; model.folder = report.items.contains(where: { $0.path == parent }) ? parent : nil; model.query = "" } label: { Image(systemName: "arrow.up") }
                    }; Spacer()
                    SearchField(text: $model.query)
                }
                HStack { Text("名称 / 类型"); Spacer(); Text("文件数").frame(width: 70, alignment: .trailing); Text("已分配空间").frame(width: 110, alignment: .trailing); Text("逻辑大小").frame(width: 110, alignment: .trailing) }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16)
                LazyVStack(spacing: 2) {
                    ForEach(model.spaceItems.prefix(limit)) { item in
                        HStack(spacing: 14) {
                            Image(systemName: item.icon).foregroundStyle(item.isDirectory ? accent : .blue).frame(width: 24)
                            VStack(alignment: .leading, spacing: 4) { Text(item.name).lineLimit(1); Text(item.type + (item.complete ? "" : " · 仅部分统计")).font(.caption).foregroundStyle(.secondary) }; Spacer()
                            Text(item.fileCount.formatted()).frame(width: 70, alignment: .trailing).foregroundStyle(.secondary)
                            Text(bytes(item.allocatedSize)).frame(width: 110, alignment: .trailing).foregroundStyle(.secondary)
                            Text((item.complete ? "" : "≥ ") + bytes(item.logicalSize)).frame(width: 110, alignment: .trailing).fontWeight(.medium)
                            Image(systemName: item.isDirectory ? "chevron.right" : "arrow.up.right").font(.caption).foregroundStyle(.secondary).frame(width: 12)
                        }.font(.callout).monospacedDigit().padding(16).background(panelColor).contentShape(Rectangle())
                            .onTapGesture { if item.isDirectory && item.type != "应用" { model.folder = item.path; model.query = ""; limit = 300 } else { model.reveal(item.path) } }
                            .contextMenu { Button("在 Finder 显示") { model.reveal(item.path) }; Button("复制路径") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.path, forType: .string) } }
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 12))
                if model.spaceItems.isEmpty { Text("此层没有已扫描的子项目；应用包内部只聚合大小，深度限制或权限不足时也可能没有结果。").font(.callout).foregroundStyle(.secondary) }
                if model.spaceItems.count > limit { Button("显示更多（共 \(model.spaceItems.count) 项）") { limit += 300 } }
            }
        } else { EmptyScan(model: model) }
    }
}

private struct SearchField: View {
    @Binding var text: String
    var body: some View { HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("搜索名称、路径或类型", text: $text).textFieldStyle(.plain) }.padding(9).background(.white.opacity(0.045)).clipShape(RoundedRectangle(cornerRadius: 8)).frame(width: 220) }
}

private struct RiskBadge: View {
    let risk: Risk
    var body: some View { Text(risk.rawValue).font(.system(size: 10, weight: .medium)).padding(.horizontal, 7).padding(.vertical, 4).foregroundStyle(risk == .regenerable ? accent : .orange).background((risk == .regenerable ? accent : .orange).opacity(0.09)).clipShape(Capsule()) }
}

private struct AdviceBadge: View {
    let advice: Advice
    var color: Color { advice.decision == .delete ? accent : advice.decision == .required ? .red : .orange }
    var body: some View { Text(advice.decision.rawValue).font(.system(size: 10, weight: .medium)).padding(.horizontal, 7).padding(.vertical, 4).foregroundStyle(color).background(color.opacity(0.1)).clipShape(Capsule()).help(advice.reason) }
}

private struct RecommendationSummary: View {
    @ObservedObject var model: CleanerModel
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("本次扫描的删除建议").font(.title3.bold())
                    Text("已识别缓存 \(bytes(model.recognizedCacheSize)) · 日志 \(bytes(model.detectedLogSize))").font(.callout).foregroundStyle(.secondary)
                    Text("建议删除 \(model.recommended.count) 项 · \(bytes(model.recommendedSize))（逻辑大小）").font(.callout).foregroundStyle(accent)
                    Text("退出相关应用后可重检的缓存：\(bytes(model.deferredCacheSize))").font(.caption).foregroundStyle(.orange)
                    let required = model.candidates.filter { model.recommendation($0).decision == .required }.count
                    Text("建议保留 \(model.candidates.count - required - model.recommended.count) 项 · 必须保留 \(required) 项").font(.caption).foregroundStyle(.secondary)
                }; Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("确认建议清理项", systemImage: "trash") { model.planRecommended() }.buttonStyle(.borderedProminent).foregroundStyle(canvas)
                    .disabled(model.recommended.isEmpty || model.scanning || model.busy || !model.keepReady || model.stale || model.report?.cancelled == true)
            }
            Text("确认后重检并移入废纸篓，清空前可恢复。忽略项、个人文件和必须保留项不参与建议清理。").font(.caption).foregroundStyle(.secondary)
            HStack {
                    Text("精确缓存按用途判断；历史日志保留最近7天。执行前仍重检变化与占用，未知用途保留。").font(.caption).foregroundStyle(.secondary)
                Spacer(); Button("刷新运行状态与建议") { model.refreshRecommendations() }.font(.caption).disabled(model.busy || model.scanning)
            }
            if model.stale { Text("文件已发生清理或恢复，请重新扫描后再使用一键建议。").font(.caption).foregroundStyle(.orange) }
            if !model.keepReady { Text("保留设置未能读取，一键清理暂停。请查看底部错误信息。").font(.caption).foregroundStyle(.orange) }
        }.padding(20).card()
    }
}

struct RulesView: View {
    @ObservedObject var model: CleanerModel
    @ViewState private var limit = 100
    var body: some View {
        if let report = model.report {
            VStack(alignment: .leading, spacing: 18) {
                RecommendationSummary(model: model)
                Picker("查看结果", selection: $model.riskFilter) {
                    Text("建议清理").tag(AdviceDecision.delete.rawValue)
                    Text("需要确认").tag(AdviceDecision.keep.rawValue)
                    Text("需退出应用 / 受保护").tag(AdviceDecision.required.rawValue)
                }.pickerStyle(.segmented)
                HStack {
                    Text("已选 \(model.selected.count) 项 · \(bytes(model.selectedSize))").foregroundStyle(accent)
                    Spacer()
                    SearchField(text: $model.query)
                    Button("确认清理所选", systemImage: "trash") { model.planRules() }
                        .buttonStyle(.borderedProminent).foregroundStyle(canvas)
                        .disabled(model.selected.isEmpty || model.busy || model.scanning || model.stale)
                }
                let visible = model.filtered
                let groups = Dictionary(grouping: visible, by: { model.cleanupGroup($0) })
                LazyVStack(spacing: 18) {
                    ForEach(groups.keys.sorted(), id: \.self) { name in
                        let items = groups[name] ?? []
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text(name).font(.headline)
                                Spacer()
                                Text("\(items.count) 项 · \(bytes(items.reduce(Int64(0)) { $0 + $1.item.logicalSize }))").font(.callout).foregroundStyle(.secondary)
                            }
                            ForEach(items.prefix(limit)) { candidate in CleanupRow(model: model, candidate: candidate) }
                            if items.count > limit { Button("显示更多") { limit += 100 } }
                        }.padding(20).card()
                    }
                }
                if visible.isEmpty {
                    ContentUnavailableView("这一类没有可处理项目", systemImage: "checkmark.seal",
                        description: Text(model.recommended.isEmpty ? "目前没有通过保守规则的清理建议。可检查“需要确认”，或退出相关应用后刷新状态。" : "可切换分类，查看其他结果。"))
                }
                DisclosureGroup("扫描详情 · \(report.visited.formatted()) 个项目 · \(report.elapsed.formatted(.number.precision(.fractionLength(1)))) 秒") {
                    CoverageCard(report: report)
                    Text("系统组件与关键数据不进入清理清单，可在空间分析中查看占用。").font(.caption).foregroundStyle(.secondary)
                }.font(.caption).foregroundStyle(.secondary)
            }
        } else { EmptyScan(model: model) }
    }
}

private struct CleanupRow: View {
    @ObservedObject var model: CleanerModel
    let candidate: Candidate
    @ViewState private var expanded = false
    var body: some View {
        let advice = model.recommendation(candidate)
        let kept = KeepStore.retains(candidate.id, paths: model.keptPaths)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Toggle("选择", isOn: Binding(get: { model.selected.contains(candidate.id) },
                    set: { model.setChoice($0 ? .delete : .automatic, for: candidate) }))
                    .toggleStyle(.checkbox).labelsHidden()
                    .disabled(advice.decision == .required || model.busy || model.scanning || model.stale)
                Image(systemName: candidate.item.icon).foregroundStyle(accent)
                Text(candidate.item.name).font(.callout.weight(.medium)).lineLimit(1)
                Spacer()
                Text(bytes(candidate.item.logicalSize)).font(.callout.monospacedDigit())
                Button(kept ? "取消忽略" : "忽略此项") { model.setChoice(kept ? .automatic : .keep, for: candidate) }
                    .font(.caption).disabled(model.busy || model.scanning)
                Button { expanded.toggle() } label: { Image(systemName: expanded ? "chevron.up" : "chevron.down") }.buttonStyle(.plain)
            }
            Text(advice.reason).font(.caption).foregroundStyle(.secondary)
            if advice.rule == "owner-running" {
                Button("已退出相关应用，重新检查") { model.refreshRecommendations() }.font(.caption).disabled(model.busy || model.scanning)
            }
            if expanded {
                Divider()
                Text(candidate.item.path).font(.caption).textSelection(.enabled)
                Text(candidate.reason).font(.caption).foregroundStyle(.secondary)
                Button("在 Finder 显示") { model.reveal(candidate.item.path) }.font(.caption)
            }
        }.padding(12).background(.white.opacity(0.025)).clipShape(RoundedRectangle(cornerRadius: 9))
    }
}
struct ApplicationsView: View {
    @ObservedObject var model: CleanerModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { SectionTitle(title: "已安装应用", subtitle: "/Applications 与用户 Applications · 递归计算应用包大小"); Spacer(); if model.appLoading { ProgressView().controlSize(.small) }; Button("刷新应用") { model.loadApps() }.disabled(model.appLoading || model.busy) }
            SearchField(text: $model.query)
            if !model.appIssues.isEmpty {
                DisclosureGroup("应用扫描存在 \(model.appIssues.count) 处访问错误") { ForEach(model.appIssues) { issue in Text(issue.path + "：" + issue.message).font(.caption).textSelection(.enabled) } }.font(.caption).foregroundStyle(.orange)
            }
            HStack(alignment: .top, spacing: 18) {
                ScrollView { LazyVStack(spacing: 7) {
                    ForEach(model.apps.filter { model.query.isEmpty || $0.name.localizedCaseInsensitiveContains(model.query) }) { app in
                        Button { model.focus(app) } label: {
                            HStack(spacing: 12) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 38, height: 38)
                                VStack(alignment: .leading, spacing: 4) { Text(app.name).lineLimit(1).font(.callout.weight(.medium)); Text("v\(app.version)" + (app.protected ? " · 受保护" : AppScanner.running(app) ? " · 运行中" : "")).font(.caption).foregroundStyle(.secondary) }; Spacer(); Text((app.complete ? "" : "≥ ") + bytes(app.size)).font(.caption.monospacedDigit())
                            }.padding(13).background(model.focusedApp?.id == app.id ? accent.opacity(0.1) : panelColor).clipShape(RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain)
                    }
                }}.frame(minWidth: 270, maxWidth: 350).frame(height: 570)
                ScrollView { VStack(alignment: .leading, spacing: 16) {
                    if let app = model.focusedApp {
                        HStack { Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 54, height: 54); VStack(alignment: .leading, spacing: 5) { Text(app.name).font(.title2.bold()); Text(app.bundleID).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) } }
                        Divider()
                        Text("应用本体").font(.headline)
                        targetRow(name: app.name + ".app", path: app.path, size: app.size, enabled: !app.protected && !AppScanner.running(app))
                        if app.protected || AppScanner.running(app) { Text(app.protected ? "此应用受保护。" : "应用运行中，请先退出再卸载。").font(.caption).foregroundStyle(.orange) }
                        HStack { Text("精确关联文件").font(.headline); Spacer(); if model.relatedLoading { ProgressView().controlSize(.small) } }
                        Text("关联文件默认不勾选。设置、登录状态和个人数据可能在其中；共享组容器不参与匹配。").font(.caption).foregroundStyle(.secondary).lineSpacing(3)
                        ForEach(model.related) { c in targetRow(name: c.item.name, path: c.item.path, size: c.item.logicalSize, enabled: c.item.complete && !app.protected && !AppScanner.running(app)) }
                        if !model.relatedLoading && model.related.isEmpty { Text("没有找到可访问的精确匹配文件。应用用自定义名称存放的数据需手动检查。").font(.caption).foregroundStyle(.secondary) }
                        ForEach(model.relatedIssues) { i in Text(i.path + "：" + i.message).font(.caption).foregroundStyle(.orange) }
                        Divider()
                        Button("预览卸载 \(model.appSelected.count) 项", systemImage: "trash") { model.planApp() }.buttonStyle(.borderedProminent).foregroundStyle(canvas).disabled(model.appSelected.isEmpty || model.busy || model.relatedLoading)
                    } else { ContentUnavailableView("选择一个应用", systemImage: "square.stack.3d.up", description: Text("查看应用包大小和相关文件，再决定是否卸载。")) }
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 570).card()
            }
            if model.apps.isEmpty && !model.appLoading { Text("未获取到应用列表，请刷新。系统 Applications 内的系统应用不纳入卸载。 ").foregroundStyle(.secondary) }
        }
    }
    private func targetRow(name: String, path: String, size: Int64, enabled: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: Binding(get: { model.appSelected.contains(path) }, set: { if $0 { model.appSelected.insert(path) } else { model.appSelected.remove(path) } })).toggleStyle(.checkbox).labelsHidden().disabled(!enabled)
            VStack(alignment: .leading, spacing: 5) { Text(name).font(.callout).lineLimit(1); Text(path).font(.caption2).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle) }; Spacer(); Text(bytes(size)).font(.caption.monospacedDigit())
        }.padding(.vertical, 7)
    }
}

struct RecoveryView: View {
    @ObservedObject var model: CleanerModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("系统废纸篓中的文件仍在，才可恢复。清空废纸篓后无法恢复。").font(.callout).foregroundStyle(.secondary); Spacer(); Button("打开废纸篓") { NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")) } }
            if model.history.isEmpty { ContentUnavailableView("还没有清理记录", systemImage: "clock.arrow.circlepath", description: Text("移入废纸篓后，这里会记录原路径、结果与恢复入口。")) }
            LazyVStack(spacing: 10) {
                ForEach(model.history) { record in
                    HStack(spacing: 14) {
                        Image(systemName: record.status == "已恢复" ? "checkmark.circle" : record.status == "失败" ? "exclamationmark.circle" : "trash").font(.title3).foregroundStyle(record.status == "失败" ? .orange : accent)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(URL(fileURLWithPath: record.original).lastPathComponent).font(.headline)
                            Text(record.original).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Text("\(record.date.formatted()) · \(bytes(record.size)) · \(record.status)").font(.caption).foregroundStyle(.secondary)
                            if let error = record.error { Text(error).font(.caption).foregroundStyle(.orange) }
                        }; Spacer()
                        if record.status == "已移入废纸篓" { Button("恢复原位", systemImage: "arrow.uturn.backward") { model.restore(record) }.disabled(model.busy) }
                    }.padding(18).card()
                }
            }
        }
    }
}

struct ScanSettings: View {
    @ObservedObject var model: CleanerModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("扫描设置").font(.title2.bold()); Spacer(); Button("完成") { dismiss() } }
            HStack {
                Picker("递归深度", selection: $model.options.maxDepth) { Text("全部层级").tag(0); Text("3 层").tag(3); Text("6 层").tag(6); Text("12 层").tag(12) }
                Picker("条目上限", selection: $model.options.entryLimit) { Text("不限（默认）").tag(0); Text("30 万").tag(300_000); Text("100 万").tag(1_000_000); Text("200 万").tag(2_000_000) }
            }
            HStack {
                Picker("大文件阈值", selection: $model.options.largeThreshold) { ForEach([100, 500, 1024], id: \.self) { n in Text("\(n) MB").tag(Int64(n) * 1024 * 1024) } }
                Picker("陈旧下载", selection: $model.options.oldDays) { ForEach([30, 90, 180], id: \.self) { n in Text("\(n) 天未修改").tag(n) } }
            }
            Text("默认不限深度和条目，可随时停止。自选上限会明确标注截断原因。扫描范围和设置自动保存，重新启动后复用。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("授权主目录（记住）") { model.authorizeHome() }
                Button("完全磁盘访问设置") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!) }
            }
            Text("首次授权或签名身份改变后，需要在系统设置中启用 MacClean 并重新打开。固定身份下无需每次扫描重复授权；系统撤销权限或目录授权失效时仍需重新确认。").font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack { Text("扫描目录（\(model.roots.count)）").font(.headline); Spacer(); Button("恢复默认") { model.roots = ScanEngine.defaultRoots(); model.options = ScanOptions() }; Button("添加目录") { model.pickFolder() } }
            ScrollView { VStack(alignment: .leading, spacing: 8) { ForEach(model.roots, id: \.path) { root in HStack { Image(systemName: "folder").foregroundStyle(accent); Text(root.path).font(.caption).textSelection(.enabled); Spacer(); Button { model.roots.removeAll { $0 == root } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain) }.padding(8).background(.white.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius: 6)) } } }
            Text("新增外置盘等范围可只读分析；清理仅允许用户目录和非系统应用，不会请求管理员权限。设置更改后需要重新扫描。").font(.caption).foregroundStyle(.secondary)
        }.padding(28).frame(width: 720, height: 690).background(canvas).preferredColorScheme(.dark)
    }
}

struct ConfirmSheet: View {
    @ObservedObject var model: CleanerModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("确认移入废纸篓", systemImage: "trash").font(.title2.bold())
            Text("\(model.pending.count) 个项目 · 逻辑大小 \(bytes(model.pending.reduce(0) { $0 + $1.size }))").font(.headline).foregroundStyle(accent)
            Text("请核对下面的完整路径。应用关联文件可能包含个人数据；缓存可能被运行中的应用占用。移入后可在恢复中心恢复，直到废纸篓被清空。").font(.callout).foregroundStyle(.secondary)
            ScrollView { VStack(alignment: .leading, spacing: 10) { ForEach(model.pending) { item in HStack { Text(item.path).font(.caption).textSelection(.enabled); Spacer(); Text(bytes(item.size)).font(.caption.monospacedDigit()) }.padding(10).background(panelColor).clipShape(RoundedRectangle(cornerRadius: 7)) } } }
            HStack { Button("取消") { model.confirm = false }; Spacer(); Button("确认移入废纸篓") { model.execute() }.buttonStyle(.borderedProminent).foregroundStyle(canvas) }
        }.padding(28).frame(width: 680, height: 490).background(canvas).preferredColorScheme(.dark)
    }
}
