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
            Text("LOCAL · v0.3").font(.system(size: 10, weight: .medium)).tracking(1).foregroundStyle(.tertiary).padding(.top, 12)
        }.padding(.horizontal, 20).padding(.bottom, 22).frame(width: 224).background(Color(red: 0.075, green: 0.09, blue: 0.12))
    }
    private var toolbar: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) { Text(model.page.rawValue).font(.system(size: 27, weight: .bold)); Text(model.page.subtitle).font(.callout).foregroundStyle(.secondary) }
            Spacer(minLength: 10)
            Button { settings = true } label: { Image(systemName: "gearshape").font(.title3) }.buttonStyle(.plain).help("扫描设置与目录范围")
            Button { model.exportReport() } label: { Image(systemName: "square.and.arrow.up").font(.title3) }.buttonStyle(.plain).disabled(model.report == nil).help("导出 JSON 扫描报告")
            if model.page == .apps {
                if model.appLoading { Button("停止应用扫描", systemImage: "stop.fill") { model.cancelApps() }.buttonStyle(.bordered) }
                else { Button("刷新应用", systemImage: "arrow.clockwise") { model.loadApps() }.buttonStyle(.borderedProminent).disabled(model.busy) }
            } else if model.page == .history {
                Button("刷新记录", systemImage: "arrow.clockwise") { model.refreshHistory() }.buttonStyle(.bordered)
            } else if model.scanning {
                Button("停止扫描", systemImage: "stop.fill") { model.cancel() }.buttonStyle(.bordered)
            } else {
                Button(model.report == nil ? "深度扫描" : "重新扫描", systemImage: "viewfinder") { model.scan() }.buttonStyle(.borderedProminent).foregroundStyle(canvas).controlSize(.large).disabled(model.busy || model.roots.isEmpty)
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
            Text(model.options.maxDepth == 0 ? "全部层级" : "最多 \(model.options.maxDepth) 层").font(.caption).foregroundStyle(accent)
        }.padding(18).background(accent.opacity(0.08))
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 24) {
            let disk = model.disk
            HStack(spacing: 28) {
                VStack(alignment: .leading, spacing: 13) {
                    Label("MAC 存储空间", systemImage: "internaldrive").font(.caption.weight(.medium)).tracking(1).foregroundStyle(.secondary)
                    Text("让每一 GB\n都有来有去。").font(.system(size: 38, weight: .bold)).lineSpacing(3)
                    Text("\(bytes(disk.free)) 可用 / \(bytes(disk.total)) 总容量").font(.callout).foregroundStyle(accent)
                    Text("从文件、目录和应用三条线深入分析。\n规则给出依据，最后的决定留给你。").font(.callout).foregroundStyle(.secondary).lineSpacing(4)
                }; Spacer()
                ZStack {
                    Circle().stroke(.white.opacity(0.055), lineWidth: 18)
                    Circle().trim(from: 0, to: disk.total > 0 ? min(1, max(0, Double(disk.total - disk.free) / Double(disk.total))) : 0)
                        .stroke(AngularGradient(colors: [accent.opacity(0.2), accent, .cyan], center: .center), style: StrokeStyle(lineWidth: 18, lineCap: .round)).rotationEffect(.degrees(-90))
                    VStack(spacing: 6) { Text(bytes(disk.free)).font(.system(size: 27, weight: .bold, design: .rounded)); Text("系统报告可用容量").font(.caption).foregroundStyle(.secondary) }
                }.frame(width: 190, height: 190).padding(20)
            }.padding(28).card()
            HStack(spacing: 14) {
                MetricCard(title: "已分析空间", value: model.report.map { bytes($0.measuredSize) } ?? "—", foot: "所选目录 · 逻辑大小", icon: "chart.pie", color: .blue)
                MetricCard(title: "建议清理", value: model.report == nil ? "—" : bytes(model.recommendedSize), foot: "\(model.recommended.count) 项通过保守判断", icon: "arrow.triangle.2.circlepath", color: accent)
                MetricCard(title: "待判断项目", value: model.report == nil ? "—" : "\(model.candidates.count)", foot: "旧文件 / 安装包 / 大文件", icon: "checklist", color: .orange)
            }
            if let report = model.report {
                RecommendationSummary(model: model)
                CoverageCard(report: report)
                SectionTitle(title: "空间去向", subtitle: "按所选扫描目录聚合；点击深入查看", action: "查看空间分析") { model.page = .space }
                DistributionView(items: report.topItems) { path in model.spaceType = "全部"; model.folder = path; model.page = .space }
                SectionTitle(title: "规则候选", subtitle: "按命中依据分组，不把所有占用都当作垃圾", action: "查看全部") { model.page = .rules }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(ScanEngine.categories, id: \.self) { category in
                        let items = model.candidates.filter { $0.category == category }
                        Button { model.category = category; model.page = .rules } label: {
                            VStack(alignment: .leading, spacing: 10) { HStack { Text(category).font(.headline); Spacer(); Image(systemName: "arrow.up.right").foregroundStyle(.secondary) }; Text(bytes(items.reduce(0) { $0 + $1.item.logicalSize })).font(.title2.bold()); Text("\(items.count) 个结果").font(.caption).foregroundStyle(.secondary) }.padding(18).card()
                        }.buttonStyle(.plain)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    SectionTitle(title: "扫描范围已就绪", subtitle: "\(model.roots.count) 个目录 · 默认递归到全部层级")
                    Text("包含下载、文档、桌面、媒体、应用缓存、日志、Xcode 构建缓存和本地模型目录。可以在扫描设置中增减目录。").foregroundStyle(.secondary).font(.callout)
                    HStack { Label("递归统计", systemImage: "folder.badge.gearshape"); Spacer(); Label("命中依据", systemImage: "text.magnifyingglass"); Spacer(); Label("操作可恢复", systemImage: "clock.arrow.circlepath") }.font(.callout).foregroundStyle(accent).padding(.top, 8)
                }.padding(24).card()
            }
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
            if report.limited { Text("已达到深度或条目上限。可提高限制，或缩小范围后重扫。").font(.caption).foregroundStyle(.orange) }
            if report.skippedCloud > 0 { Text("\(report.skippedCloud) 个未下载的云端文件被跳过。").font(.caption).foregroundStyle(.orange) }
            if report.skippedLinks > 0 { Text("跳过 \(report.skippedLinks) 个符号链接，避免重复统计和越界。").font(.caption).foregroundStyle(.secondary) }
            if !report.issues.isEmpty {
                DisclosureGroup("\(report.issues.count) 处访问错误（最多记录 250 处）") {
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
    var body: some View { ContentUnavailableView { Label("先做一次深度扫描", systemImage: "viewfinder") } description: { Text("扫描会递归统计文件和目录；完成后即可查看占用与规则命中依据。") } actions: { Button("开始扫描") { model.scan() }.disabled(model.scanning).buttonStyle(.borderedProminent) }.padding(.vertical, 80) }
}

struct SpaceView: View {
    @ObservedObject var model: CleanerModel
    @ViewState private var limit = 300
    var body: some View {
        if let report = model.report {
            VStack(alignment: .leading, spacing: 18) {
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
                    Text("建议删除 \(model.recommended.count) 项 · \(bytes(model.recommendedSize))（逻辑大小）").font(.callout).foregroundStyle(accent)
                    let required = model.candidates.filter { model.recommendation($0).decision == .required }.count
                    Text("建议保留 \(model.candidates.count - required - model.recommended.count) 项 · 必须保留 \(required) 项").font(.caption).foregroundStyle(.secondary)
                }; Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("一键清理建议项", systemImage: "trash") { model.deleteRecommended() }.buttonStyle(.borderedProminent).foregroundStyle(canvas)
                    .disabled(model.recommended.isEmpty || model.scanning || model.busy || !model.keepReady || model.stale || model.report?.cancelled == true)
            }
            Text("点击即重检并移入废纸篓，可在恢复中心撤回。仅处理建议删除项；你标记保留的文件会在后续扫描中排除。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("判断依据：文件用途、目录内最新写入、程序运行状态；未知用途默认保留。").font(.caption).foregroundStyle(.secondary)
                Spacer(); Button("刷新运行状态与建议") { model.refreshRecommendations() }.font(.caption).disabled(model.busy || model.scanning)
            }
            if model.stale { Text("文件已发生清理或恢复，请重新扫描后再使用一键建议。").font(.caption).foregroundStyle(.orange) }
            if !model.keepReady { Text("保留设置未能读取，一键清理暂停。请查看底部错误信息。").font(.caption).foregroundStyle(.orange) }
        }.padding(20).card()
    }
}

struct RulesView: View {
    @ObservedObject var model: CleanerModel
    @ViewState private var expanded: String?
    @ViewState private var limit = 300
    var body: some View {
        if let report = model.report {
            VStack(alignment: .leading, spacing: 18) {
                RecommendationSummary(model: model)
                CoverageCard(report: report)
                HStack {
                    Picker("分类", selection: $model.category) { Text("全部类型").tag("全部"); ForEach(ScanEngine.categories, id: \.self) { Text($0).tag($0) } }.frame(width: 180)
                    Picker("判断", selection: $model.riskFilter) { Text("全部建议").tag("全部"); ForEach(AdviceDecision.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) } }.frame(width: 180)
                    Spacer(); SearchField(text: $model.query)
                }
                HStack {
                    Text("\(model.filtered.count) 个命中 · 选择 \(model.selected.count) 项 / \(bytes(model.selectedSize))").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("选中建议删除") { for c in model.filtered where model.recommendation(c).decision == .delete { model.selected.insert(c.id) } }.disabled(model.busy || model.scanning)
                    Button("清空选择") { model.selected.removeAll() }
                    Button("预览清理", systemImage: "trash") { model.planRules() }.buttonStyle(.borderedProminent).foregroundStyle(canvas).disabled(model.selected.isEmpty || model.busy || model.scanning)
                }
                LazyVStack(spacing: 9) {
                    ForEach(model.filtered.prefix(limit)) { candidate in
                        let advice = model.recommendation(candidate)
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 14) {
                                Toggle("选择", isOn: Binding(get: { model.selected.contains(candidate.id) }, set: { model.setChoice($0 ? .delete : .automatic, for: candidate) })).toggleStyle(.checkbox).labelsHidden().disabled(advice.decision == .required || model.busy || model.scanning)
                                Image(systemName: candidate.item.icon).foregroundStyle(accent).frame(width: 25)
                                VStack(alignment: .leading, spacing: 5) { Text(candidate.item.name).font(.callout.weight(.medium)).lineLimit(1); Text(candidate.item.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                                Spacer(); AdviceBadge(advice: advice)
                                if advice.decision != .required {
                                    Picker("处理方式", selection: Binding(get: { model.choice(candidate) }, set: { model.setChoice($0, for: candidate) })) { ForEach(FileChoice.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 90).disabled(model.busy || model.scanning)
                                } else {
                                    let kept = model.keptPaths.contains(candidate.id)
                                    Button(kept ? "取消标记" : "始终保留") { model.setChoice(kept ? .automatic : .keep, for: candidate) }.font(.caption).disabled(model.busy || model.scanning || !model.keepReady)
                                }
                                Text(bytes(candidate.item.logicalSize)).font(.callout.monospacedDigit().weight(.semibold)).frame(width: 90, alignment: .trailing)
                                Button { expanded = expanded == candidate.id ? nil : candidate.id } label: { Image(systemName: expanded == candidate.id ? "chevron.up" : "chevron.down") }.buttonStyle(.plain)
                            }
                            Text(advice.reason).font(.caption).foregroundStyle(.secondary).lineLimit(expanded == candidate.id ? nil : 2)
                            if expanded == candidate.id {
                                Divider()
                                Text(candidate.category + " · " + candidate.reason).font(.callout).foregroundStyle(.secondary)
                                Text("最后修改：" + (candidate.item.modified?.formatted() ?? "未获取") + " · 已分配：" + bytes(candidate.item.allocatedSize)).font(.caption).foregroundStyle(.secondary)
                                Text("目录内最新写入：" + (candidate.item.latestModified?.formatted() ?? "未获取，保守保留")).font(.caption).foregroundStyle(.secondary)
                                HStack { Text("类型：\(candidate.item.type) · 文件数：\(candidate.item.fileCount)").font(.caption); Spacer(); Button("在 Finder 显示") { model.reveal(candidate.item.path) }.font(.caption) }.foregroundStyle(.secondary)
                            }
                        }.padding(16).card()
                    }
                }
                if model.filtered.isEmpty { ContentUnavailableView("当前筛选没有命中", systemImage: "checkmark.seal", description: Text("未命中不代表扫描覆盖了整个磁盘；可以调整规则阈值或扫描范围。")) }
                if model.filtered.count > limit { Button("显示更多（共 \(model.filtered.count) 项）") { limit += 300 } }
            }
        } else { EmptyScan(model: model) }
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
                Picker("条目上限", selection: $model.options.entryLimit) { Text("30 万").tag(300_000); Text("100 万").tag(1_000_000); Text("200 万").tag(2_000_000) }
            }
            HStack {
                Picker("大文件阈值", selection: $model.options.largeThreshold) { ForEach([100, 500, 1024], id: \.self) { n in Text("\(n) MB").tag(Int64(n) * 1024 * 1024) } }
                Picker("陈旧下载", selection: $model.options.oldDays) { ForEach([30, 90, 180], id: \.self) { n in Text("\(n) 天未修改").tag(n) } }
            }
            Text("旧日志 ≥30 天；旧安装包 ≥14 天。全部层级也受条目上限约束，达到限制会明确标为部分结果。文件类型按扩展名 / macOS 类型识别，并结合位置和时间判断。").font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack { Text("扫描目录（\(model.roots.count)）").font(.headline); Spacer(); Button("恢复默认") { model.roots = ScanEngine.defaultRoots() }; Button("添加目录") { model.pickFolder() } }
            ScrollView { VStack(alignment: .leading, spacing: 8) { ForEach(model.roots, id: \.path) { root in HStack { Image(systemName: "folder").foregroundStyle(accent); Text(root.path).font(.caption).textSelection(.enabled); Spacer(); Button { model.roots.removeAll { $0 == root } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain) }.padding(8).background(.white.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius: 6)) } } }
            Text("新增外置盘等范围可只读分析；清理仅允许用户目录和非系统应用，不会请求管理员权限。设置更改后需要重新扫描。").font(.caption).foregroundStyle(.secondary)
        }.padding(28).frame(width: 660, height: 590).background(canvas).preferredColorScheme(.dark)
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
