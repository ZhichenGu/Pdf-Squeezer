import SwiftUI
import UniformTypeIdentifiers
import PDFKit
import AppKit

struct DropArea: ViewModifier {
    @ObservedObject var desk: Desk
    @Binding var hovering: Bool
    func body(content: Content) -> some View {
        content.onDrop(of: [UTType.fileURL], isTargeted: $hovering) { providers in
            Task { @MainActor in
                var urls = [URL]()
                for provider in providers {
                    let url: URL? = await withCheckedContinuation { continuation in
                        _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                            continuation.resume(returning: object as? URL)
                        }
                    }
                    if let url { urls.append(url) }
                }
                desk.add(urls)
            }
            return true
        }
    }
}

struct SettingsPanel: View {
    @ObservedObject var desk: Desk
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("压缩设置").font(.headline)
            Text("质量和 DPI 对所选文件统一生效").font(.caption).foregroundStyle(muted)
            HStack {
                Text("图片质量")
                Spacer()
                Text("\(Int(desk.quality))%").monospacedDigit()
            }
            Slider(value: $desk.quality, in: 45...98, step: 1)
            HStack {
                Text("图片分辨率")
                Spacer()
                Picker("图片分辨率", selection: $desk.dpi) {
                    ForEach([96, 120, 150, 180, 240, 300], id: \.self) { value in
                        Text("\(value) DPI").tag(Double(value))
                    }
                }.labelsHidden().frame(width: 110)
            }
            Toggle("按目标大小自动调整", isOn: $desk.adaptive).toggleStyle(.switch)
            Text(desk.adaptive ? "在各自的目标内搜索尽可能高的画质。" : "按当前参数压缩一次。")
                .font(.caption).foregroundStyle(muted)
            Divider()
            SizeEstimate(desk: desk)
            Text("设置和任务自动保存").font(.caption).foregroundStyle(muted)
        }.padding(18).frame(width: 300)
        .task(id: desk.plan) { await desk.estimateCurrent() }
    }
}

struct SizeEstimate: View {
    @ObservedObject var desk: Desk
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let file = desk.current {
                Text("试压文件 · "+file.source.lastPathComponent)
                    .font(.caption).lineLimit(1).truncationMode(.middle).help(file.source.lastPathComponent)
                if desk.plan == desk.estimateKey, let bytes = desk.estimateBytes {
                    Text(sizeText(file.bytes)+" → "+sizeText(bytes))
                        .font(.callout.weight(.semibold)).monospacedDigit()
                    Text(desk.adaptive && bytes > (desk.limit ?? 0) ? "当前参数仍超标，正式压缩会继续调整。" : "按当前质量和 DPI 试压。")
                        .font(.caption).foregroundStyle(muted)
                    Button("查看试压对比") { desk.mode = "试压"; dismiss() }
                } else if desk.plan == nil {
                    Text("先在文件行填写有效的目标 MB。").font(.caption).foregroundStyle(muted)
                } else if !desk.estimateError.isEmpty {
                    Text(desk.estimateError).font(.caption).foregroundStyle(.orange).lineLimit(2)
                } else {
                    HStack {
                        ProgressView().controlSize(.mini)
                        Text("正在计算试压大小…").font(.caption).foregroundStyle(muted)
                    }
                }
            } else {
                Text("添加文件后即可试压").font(.caption).foregroundStyle(muted)
            }
            Spacer(minLength: 0)
        }.frame(height: 105, alignment: .topLeading)
    }
}

struct FileRow: View {
    @ObservedObject var desk: Desk
    let file: FileItem
    private var invalid: Bool { desk.effectiveLimit(file) == nil }
    private var status: String {
        if invalid { return "目标无效" }
        if !file.message.isEmpty { return file.message }
        if file.result != nil {
            return file.resultBytes <= (desk.effectiveLimit(file) ?? 0) ? "已达标" : "超出目标"
        }
        return "待压缩"
    }
    private var symbol: String {
        if invalid || file.message == "处理失败" { return "exclamationmark.circle" }
        if file.message == "已停止" { return "pause.circle" }
        if file.message == "处理中" || file.message == "强压中" { return "ellipsis.circle" }
        if file.result != nil { return status == "已达标" ? "checkmark.circle" : "exclamationmark.triangle" }
        return "circle.dashed"
    }
    private var statusColor: Color {
        if invalid { return .red }
        if status == "超出目标" || file.message == "处理失败" { return .orange }
        return muted
    }
    var body: some View {
        HStack(spacing: 8) {
            Toggle("勾选 "+file.source.lastPathComponent, isOn: Binding(
                get: { file.checked }, set: { value in desk.edit(file.id) { $0.checked = value } }))
                .labelsHidden().toggleStyle(.checkbox).disabled(desk.busy)
                .help("勾选后参与批量压缩")
            Button { desk.focusOn(file) } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(file.source.lastPathComponent).font(.system(size: 13, weight: .medium))
                        .lineLimit(1).truncationMode(.middle)
                    Text(file.result == nil ? sizeText(file.bytes) : sizeText(file.bytes)+" → "+sizeText(file.resultBytes))
                        .font(.caption).monospacedDigit().foregroundStyle(muted).lineLimit(1)
                    Label(status, systemImage: symbol).font(.caption2).foregroundStyle(statusColor)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).help(file.source.lastPathComponent)
            VStack(alignment: .leading, spacing: 3) {
                Text("目标 MB").font(.system(size: 10)).foregroundStyle(muted)
                TextField("10", text: Binding(
                    get: { desk.files.first(where: { $0.id == file.id })?.targetMB ?? "" },
                    set: { value in desk.edit(file.id) { $0.targetMB = value } }))
                    .textFieldStyle(.roundedBorder).frame(width: 64).disabled(desk.busy)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(invalid ? Color.red : Color.clear))
                    .accessibilityLabel(file.source.lastPathComponent+" 目标 MB")
                    .help("填写大于 0、最多 1000000 的 MB 数值")
                Text(invalid ? "请输入正数" : " ").font(.system(size: 10)).foregroundStyle(.red)
                    .frame(height: 12)
            }
            VStack(spacing: 5) {
                Button { desk.remove(file.id) } label: { Image(systemName: "xmark").frame(width: 20, height: 20) }
                    .help("从队列移除").accessibilityLabel("移除 "+file.source.lastPathComponent)
                Button { desk.retry(file) } label: { Image(systemName: "arrow.clockwise").frame(width: 20, height: 20) }
                    .help("重试此文件").accessibilityLabel("重试 "+file.source.lastPathComponent)
                    .opacity(file.message == "处理失败" ? 1 : 0)
                    .disabled(file.message != "处理失败" || invalid)
            }.buttonStyle(.borderless).font(.system(size: 11)).disabled(desk.busy)
        }.padding(.horizontal, 10).frame(height: 74)
            .background(desk.focus == file.id ? mint.opacity(0.65) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
    }
}

struct DeskView: View {
    @ObservedObject var desk: Desk
    @AppStorage("sidebarWidth") private var sidebarWidth = 340.0
    @State private var hover = false
    @State private var settings = false
    @State private var showLinks = false
    @State private var batchOptions = false
    @State private var showDetails = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.zipper").foregroundStyle(teal).font(.system(size: 18))
                Text("轻压").font(.system(size: 17, weight: .semibold))
                if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                    Text("版本 V"+version).font(.caption).foregroundStyle(muted)
                }
                Spacer()
                Button { settings.toggle() } label: { Label("设置", systemImage: "slider.horizontal.3") }
                    .disabled(desk.busy).popover(isPresented: $settings) { SettingsPanel(desk: desk) }
            }.padding(.horizontal, 16).frame(height: 48)
            Divider()
            GeometryReader { geometry in
                let width = sidebarWidthFor(preferred: sidebarWidth, available: geometry.size.width)
                HStack(spacing: 0) {
                    sidebar.frame(width: width)
                    WorkspaceDivider(width: width, maximum: min(460, geometry.size.width - 488)) {
                        sidebarWidth = Double($0)
                    }.frame(width: 8)
                    right.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }.foregroundStyle(ink).background(.white).tint(teal).preferredColorScheme(.light)
            .frame(minWidth: 860, minHeight: 600)
            .sheet(isPresented: $showLinks) {
                if let id = desk.focus { LinksPanel(desk: desk, id: id) }
            }
            .sheet(item: $desk.warning, onDismiss: {
                let action = desk.afterWarning; desk.afterWarning = nil
                DispatchQueue.main.async { action?() }
            }) { warning in
                SizeWarningPanel(warning: warning, accept: {
                    desk.afterWarning = { desk.saveResults(warning.files) }; desk.warning = nil
                }, adjust: {
                    desk.afterWarning = { desk.focusOn(warning.issues[0].file); settings = true }; desk.warning = nil
                }, retry: {
                    desk.afterWarning = { desk.force(warning) }; desk.warning = nil
                }, cancel: { desk.warning = nil })
            }
            .alert("轻压", isPresented: Binding(
                get: { !desk.notice.isEmpty }, set: { if !$0 { desk.notice = "" } })) {
                    Button("好") { desk.notice = "" }
                } message: { Text(desk.notice) }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("文件").font(.headline)
                Text("\(desk.files.count)").font(.caption).foregroundStyle(muted)
                Spacer()
                Button("添加…") { desk.choose() }.buttonStyle(.borderless)
            }.padding(.horizontal, 16).frame(height: 44)
            if desk.files.isEmpty {
                Button { desk.choose() } label: {
                    Label("拖入 PDF 或点此选择", systemImage: "tray.and.arrow.down")
                        .font(.callout).frame(maxWidth: .infinity).frame(height: 70)
                        .background(mint.opacity(0.3), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(line, style: StrokeStyle(dash: [4, 4])))
                }.buttonStyle(.plain).padding(.horizontal, 12).padding(.bottom, 8)
            } else {
                HStack {
                    Toggle("全选", isOn: Binding(
                        get: { desk.checked.count == desk.files.count },
                        set: { value in for i in desk.files.indices { desk.files[i].checked = value } }))
                        .toggleStyle(.checkbox).disabled(desk.busy)
                    Spacer()
                    Text("已选 \(desk.checked.count) 份").font(.caption).foregroundStyle(muted)
                }.padding(.horizontal, 16).frame(height: 30)
            }
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(desk.files) { file in FileRow(desk: desk, file: file) }
                }.padding(.horizontal, 6)
            }
            Divider()
            controls
        }.background(Color(red: 0.982, green: 0.985, blue: 0.979))
            .overlay { Rectangle().strokeBorder(hover ? teal : .clear, lineWidth: 2).allowsHitTesting(false) }
            .modifier(DropArea(desk: desk, hovering: $hover))
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack {
                Text("所选文件").font(.caption.weight(.semibold))
                Spacer()
                Button("批量设定…") { batchOptions.toggle() }.disabled(desk.checked.isEmpty || desk.busy)
                    .popover(isPresented: $batchOptions) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("统一填写所选文件的单份目标").font(.headline)
                            HStack { TextField("10", text: $desk.batchTarget).frame(width: 86); Text("MB") }
                            Button("应用到 \(desk.checked.count) 份文件") { desk.applyBatchTarget(); batchOptions = false }
                                .disabled(desk.bytesFromMB(desk.batchTarget) == nil)
                        }.padding(18)
                    }
            }.frame(height: 24)
            HStack(alignment: .center, spacing: 8) {
                if desk.busy { ProgressView().controlSize(.mini) }
                Text(feedback).font(.caption).foregroundStyle(muted).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading).help(feedback)
                if desk.busy {
                    Button(desk.stopping ? "正在停止…" : "停止") { desk.stop() }.disabled(desk.stopping)
                } else if desk.files.contains(where: { $0.message == "处理失败" }) {
                    Button("重试失败文件") { desk.retryFailures() }
                }
            }.frame(height: 36)
            Button { desk.start() } label: {
                Text(desk.busy ? "正在压缩" : "压缩所选文件（\(desk.checked.count)）")
                    .font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 34)
                    .foregroundStyle(.white).background(teal, in: RoundedRectangle(cornerRadius: 6))
            }.buttonStyle(.plain).disabled(desk.busy || desk.checked.isEmpty || desk.goals == nil)
            Button { desk.export(desk.checked) } label: {
                Label("导出已勾选的成品", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
            }.disabled(desk.busy || !desk.checked.contains(where: { $0.result != nil })).frame(height: 25)
        }.padding(14)
    }

    private var feedback: String {
        if desk.busy { return desk.progress }
        if !desk.memoryError.isEmpty { return desk.memoryError }
        if desk.goals == nil { return "请修正文件行中标红的目标大小。" }
        if !desk.batchSummary.isEmpty { return desk.batchSummary }
        return ""
    }

    @ViewBuilder private var right: some View {
        if let file = desk.current {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(file.source.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
                            .help(file.source.lastPathComponent)
                        Text("\(file.pages) 页 · "+sizeText(file.bytes)).font(.caption).foregroundStyle(muted)
                    }
                    Spacer(minLength: 0)
                    Button { showDetails.toggle() } label: { Image(systemName: "info.circle") }
                        .buttonStyle(.borderless).help("文件详情").accessibilityLabel("文件详情")
                        .popover(isPresented: $showDetails) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("文件详情").font(.headline)
                                Text(file.source.lastPathComponent).textSelection(.enabled)
                                Text("\(file.pages) 页 · "+sizeText(file.bytes))
                                Text(file.analysis.isEmpty ? "正在分析文件组成…" : "文件组成（数据流） · "+file.analysis)
                                    .font(.caption).foregroundStyle(muted)
                            }.padding(18).frame(width: 290)
                        }
                    Button { showLinks = true } label: {
                        Label(file.links.contains(where: { $0.problem }) ? "链接异常" : "链接 \(file.links.count)",
                              systemImage: file.links.contains(where: { $0.problem }) ? "exclamationmark.triangle" : "link")
                    }
                }.padding(.horizontal, 16).frame(height: 58)
                Divider()
                HStack(spacing: 0) {
                    ForEach(["原稿", "试压", "对比", "成品"], id: \.self) { value in
                        Button { desk.mode = value } label: {
                            Text(value).font(.system(size: 12, weight: desk.mode == value ? .semibold : .regular))
                                .frame(width: 43, height: 25)
                                .background(desk.mode == value ? Color.white : .clear, in: RoundedRectangle(cornerRadius: 4))
                        }.buttonStyle(.plain)
                            .disabled(value == "试压" ? desk.validEstimate == nil : (["对比", "成品"].contains(value) && file.result == nil))
                    }
                    Spacer()
                    Button { desk.zoom = max(1, desk.zoom-0.5) } label: { Image(systemName: "minus.magnifyingglass") }
                        .disabled(desk.zoom <= 1).help("缩小").accessibilityLabel("缩小")
                    Text(desk.zoom == 1 ? "适合页面" : "\(Int(desk.zoom*100))%").font(.caption).frame(width: 54)
                    Button { desk.zoom = min(4, desk.zoom+0.5) } label: { Image(systemName: "plus.magnifyingglass") }
                        .disabled(desk.zoom >= 4).help("放大").accessibilityLabel("放大")
                }.buttonStyle(.borderless).padding(.horizontal, 16).frame(height: 38).background(field.opacity(0.5))
                PreviewCanvas(f: file, mode: desk.mode, zoom: desk.zoom, draft: desk.validEstimate)
                Divider()
                HStack(spacing: 8) {
                    Button { desk.edit(file.id) { $0.page -= 1 } } label: { Image(systemName: "chevron.left") }
                        .disabled(file.page == 0).help("上一页").accessibilityLabel("上一页")
                    Text("\(file.page+1) / \(file.pages)").font(.caption.monospacedDigit())
                    Button { desk.edit(file.id) { $0.page += 1 } } label: { Image(systemName: "chevron.right") }
                        .disabled(file.page+1 >= file.pages).help("下一页").accessibilityLabel("下一页")
                    Spacer()
                    if let cap = desk.effectiveLimit(file), file.result != nil {
                        Label(file.resultBytes <= cap ? "已达标" : "超出目标",
                              systemImage: file.resultBytes <= cap ? "checkmark.circle" : "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(file.resultBytes <= cap ? muted : .orange)
                        Text(sizeText(file.resultBytes)).font(.callout.weight(.semibold))
                    }
                    Button("导出…") { desk.export([file]) }.disabled(desk.busy || file.result == nil)
                }.padding(.horizontal, 12).frame(height: 40)
                HStack {
                    Text(desk.exportMessage).font(.caption).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Button("在 Finder 中显示") { desk.revealExport() }.buttonStyle(.borderless)
                    Button { desk.exportMessage = "" } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).help("关闭导出提示").accessibilityLabel("关闭导出提示")
                }.padding(.horizontal, 14).frame(height: 30)
                    .opacity(desk.exportMessage.isEmpty ? 0 : 1).disabled(desk.exportMessage.isEmpty)
                    .background(field.opacity(desk.exportMessage.isEmpty ? 0 : 0.6))
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "doc.badge.plus").font(.system(size: 32)).foregroundStyle(muted)
                Text("拖入 PDF 开始预览").font(.headline)
                Button("选择 PDF…") { desk.choose() }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(field)
                .modifier(DropArea(desk: desk, hovering: $hover))
        }
    }
}

@MainActor final class DeskDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) { Desk.shared.add(urls) }
}

@main struct PaperPress: App {
    @NSApplicationDelegateAdaptor(DeskDelegate.self) var delegate
    @StateObject private var desk = Desk.shared
    var body: some Scene {
        Window("轻压", id: "desk") {
            DeskView(desk: desk).onOpenURL { desk.add([$0]) }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    desk.stop(); desk.persist()
                }
        }.defaultSize(width: 1090, height: 728)
            .commands { CommandGroup(after: .newItem) { Button("添加 PDF…") { desk.choose() }.keyboardShortcut("o") } }
    }
}
