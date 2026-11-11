import SwiftUI
import UniformTypeIdentifiers
import PDFKit

struct DropArea: ViewModifier {
    @ObservedObject var desk: Desk
    @Binding var hovering: Bool
    func body(content:Content)->some View {
        content.onDrop(of:[UTType.fileURL],isTargeted:$hovering){providers in
            Task { @MainActor in
                var urls=[URL]()
                for provider in providers {
                    let url:URL?=await withCheckedContinuation{continuation in
                        _=provider.loadObject(ofClass:NSURL.self){obj,_ in continuation.resume(returning:obj as? URL)}
                    }
                    if let url {urls.append(url)}
                }
                desk.add(urls)
            }
            return true
        }
    }
}

struct SettingsPanel:View {
    @ObservedObject var desk:Desk
    var body:some View {
        VStack(alignment:.leading,spacing:17) {
            Text("压缩设置").font(.title3.bold())
            HStack{Text("图片质量");Spacer();Text("\(Int(desk.quality))%").monospacedDigit().foregroundStyle(teal)}
            Slider(value:$desk.quality,in:45...98,step:1)
            HStack {Text("图片分辨率");Spacer();Picker("",selection:$desk.dpi){
                ForEach([96,120,150,180,240,300],id:\.self){x in Text("\(x) DPI").tag(Double(x))}
            }.labelsHidden().frame(width:110)}
            Divider()
            Toggle("按目标大小自动调整",isOn:$desk.adaptive).toggleStyle(.switch)
            Text(desk.adaptive ? "从所选质量和分辨率开始，逐步降低图片精度，直到达标或达到下限。":"按所选参数压缩一次，保留实际结果供预览。")
                .font(.caption).foregroundStyle(muted).fixedSize(horizontal:false,vertical:true)
            Divider()
            SizeEstimate(desk:desk, expanded:true)
        }.padding(20).frame(width:300)
        .task(id:desk.plan){await desk.estimateCurrent()}
    }
}

struct SizeEstimate:View {
    @ObservedObject var desk:Desk
    let expanded:Bool
    @Environment(\.dismiss) var dismiss
    var body:some View {
        VStack(alignment:.leading,spacing:7) {
            if expanded {Text("当前文件试压").font(.subheadline.bold())}
            if let f=desk.current {
                if desk.plan == desk.estimateKey, let bytes=desk.estimateBytes {
                    Text(sizeText(f.bytes)+" → "+sizeText(bytes)).font(.system(size:12,weight:.semibold)).monospacedDigit().foregroundStyle(teal)
                    if expanded {
                        Text(f.bytes <= (desk.limit ?? 0) ? "原文件已达标，保留原始质量。":(desk.adaptive && bytes > (desk.limit ?? 0) ? "按当前参数仍超标，正式压缩时会继续调整。":"按当前质量和分辨率计算。")).font(.caption).foregroundStyle(muted)
                        Button("查看试压对比"){desk.mode="试压";dismiss()}.disabled(desk.estimateURL==nil)
                    }
                } else if expanded {
                    if desk.plan == nil {Text("请填写有效的目标大小。").font(.caption)}
                    else if !desk.estimateError.isEmpty {Text(desk.estimateError).font(.caption).foregroundStyle(.orange)}
                    else { HStack {ProgressView().controlSize(.mini);Text("正在计算试压大小…").font(.caption)} }
                }
            } else if expanded {Text("添加文件后即可查看试压大小。").font(.caption).foregroundStyle(muted)}
        }
    }
}

struct DeskView:View {
    @ObservedObject var desk:Desk
    @State var hover=false
    @State var settings=false
    @State var showLinks=false
    @State var batchOptions=false
    var body:some View {
        VStack(spacing:0) {
            HStack(spacing:11) {
                Image(systemName:"square.3.layers.3d.down.right").font(.system(size:20,weight:.semibold))
                    .foregroundStyle(.white).frame(width:36,height:36).background(teal,in:RoundedRectangle(cornerRadius:9))
                HStack(alignment:.firstTextBaseline,spacing:7) {
                    Text("PDF压缩").font(.system(size:21,weight:.bold))
                    if let version = Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String {
                        Text("版本 V\(version)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button {settings.toggle()} label:{Label("设置",systemImage:"slider.horizontal.3")}.disabled(desk.busy)
                    .popover(isPresented:$settings){SettingsPanel(desk:desk)}
            }.padding(.horizontal,22).frame(height:61)
            Divider()
            HStack(spacing:0) {
                sidebar.frame(width:292)
                Divider()
                right.frame(maxWidth:.infinity,maxHeight:.infinity)
            }
        }.foregroundStyle(ink).background(Color.white).tint(teal).preferredColorScheme(.light)
        .frame(minWidth:860,minHeight:570)
        .sheet(isPresented:$showLinks){if let id=desk.focus {LinksPanel(desk:desk,id:id)}}
        .sheet(item:$desk.warning,onDismiss:{
            let action=desk.afterWarning;desk.afterWarning=nil
            DispatchQueue.main.async {action?()}
        }) { warning in
            SizeWarningPanel(warning:warning,accept:{
                desk.afterWarning={desk.saveResults(warning.files)};desk.warning=nil
            },adjust:{
                desk.afterWarning={desk.focusOn(warning.issues[0].file);settings=true};desk.warning=nil
            },retry:{
                desk.afterWarning={desk.force(warning)};desk.warning=nil
            },cancel:{desk.warning=nil})
        }
        .alert("PDF压缩",isPresented:Binding(get:{!desk.notice.isEmpty},set:{if !$0{desk.notice=""}})){Button("好"){desk.notice=""}}message:{Text(desk.notice)}
    }

    var sidebar:some View {
        VStack(alignment:.leading,spacing:0){
            HStack {Text("文件队列").font(.headline); Text(String(desk.files.count)).font(.caption.monospacedDigit()).foregroundStyle(muted)
                Spacer()
                Button("添加…"){desk.choose()}.buttonStyle(.borderless)
            }.padding(.horizontal,18).padding(.top,19)
            Button {desk.choose()} label:{
                VStack(spacing:7){Image(systemName:"tray.and.arrow.down").font(.title2);Text("拖入 PDF 或点此选择").font(.system(size:12,weight:.medium))}
                    .foregroundStyle(teal).frame(maxWidth:.infinity).frame(height:79)
                    .background(hover ? mint:mint.opacity(0.37),in:RoundedRectangle(cornerRadius:9))
                    .overlay(RoundedRectangle(cornerRadius:9).strokeBorder(teal.opacity(0.45),style:StrokeStyle(lineWidth:1,dash:[4,4])))
            }.buttonStyle(.plain).padding(.horizontal,15).padding(.vertical,14)
            if !desk.files.isEmpty {
                HStack {
                    Toggle("全选",isOn:Binding(get:{desk.checked.count==desk.files.count},set:{v in for i in desk.files.indices {desk.files[i].checked=v}})).toggleStyle(.checkbox)
                    Spacer();Text("已选 \(desk.checked.count) 份").font(.caption).foregroundStyle(muted)
                }.padding(.horizontal,19).padding(.bottom,9)
            }
            ScrollView{
                LazyVStack(spacing:4){
                    ForEach(desk.files){f in
                        HStack(spacing:9){
                            Toggle("",isOn:Binding(get:{f.checked},set:{v in desk.edit(f.id){$0.checked=v}})).labelsHidden().toggleStyle(.checkbox)
                            Button {desk.focusOn(f)} label:{
                                VStack(alignment:.leading,spacing:6){
                                    Text(f.source.lastPathComponent).font(.system(size:13,weight:.medium)).lineLimit(1).truncationMode(.middle)
                                    HStack(spacing:5){Text(sizeText(f.bytes));Text("·");Text("目标 "+f.targetMB+" MB");Text("·");Text(f.result != nil && f.message.isEmpty ? (f.resultBytes <= (desk.effectiveLimit(f) ?? 0) ? "已达标":"未达目标"):f.status).foregroundStyle(f.result == nil ? muted:teal)}
                                        .font(.caption).foregroundStyle(muted)
                                }.frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Button {desk.remove(f.id)}label:{Image(systemName:"xmark").font(.caption2)}.buttonStyle(.plain).disabled(desk.busy).help("从队列移除")
                        }.padding(.horizontal,10).padding(.vertical,10).background(desk.focus==f.id ? mint:Color.clear,in:RoundedRectangle(cornerRadius:6))
                    }
                }.padding(.horizontal,8)
            }
            Divider()
            VStack(alignment:.leading,spacing:11){
                HStack {
                    Text("所选文件").font(.system(size:12,weight:.semibold));Spacer()
                    Button("批量设定…"){batchOptions.toggle()}.disabled(desk.checked.isEmpty || desk.busy)
                    .popover(isPresented:$batchOptions){
                        VStack(alignment:.leading,spacing:12){
                            Text("统一填写所选文件的单份目标").font(.headline)
                            HStack{TextField("10",text:$desk.batchTarget).frame(width:86);Text("MB")}
                            Button("应用到 \(desk.checked.count) 份文件"){desk.applyBatchTarget();batchOptions=false}
                                .disabled(desk.bytesFromMB(desk.batchTarget)==nil)
                        }.padding(18)
                    }
                }
                Toggle("限制所选文件的合计大小",isOn:$desk.useTotal).toggleStyle(.checkbox).disabled(desk.busy)
                if desk.useTotal {
                    HStack {Text("合计上限");TextField("20",text:$desk.totalMB).frame(width:73);Text("MB")}.font(.caption).disabled(desk.busy)
                }
                if !desk.batchSummary.isEmpty {Text(desk.batchSummary).font(.caption).foregroundStyle(muted)}
                if desk.estimateBytes != nil && desk.estimateKey == desk.plan { SizeEstimate(desk:desk,expanded:false) }
                if desk.busy {HStack {ProgressView().controlSize(.mini);Text(desk.progress).font(.caption).foregroundStyle(muted)}}
                if desk.goals==nil {Text("请检查所选文件的目标和合计上限。").font(.caption).foregroundStyle(.red)}
                Button {desk.start()} label:{
                    Label(desk.busy ? "正在压缩":"压缩所选文件"+(desk.checked.isEmpty ? "":"（\(desk.checked.count)）"),systemImage:"arrow.down.right.and.arrow.up.left")
                        .font(.system(size:13,weight:.semibold)).frame(maxWidth:.infinity).frame(height:37)
                        .foregroundStyle(.white).background(teal,in:RoundedRectangle(cornerRadius:7))
                }.buttonStyle(.plain).disabled(desk.busy || desk.checked.isEmpty || desk.goals==nil)
                if desk.checked.contains(where:{$0.result != nil}) {
                    Button {desk.export(desk.checked)} label:{Label("导出已勾选的成品",systemImage:"square.and.arrow.up").frame(maxWidth:.infinity)}.disabled(desk.busy)
                }
            }.padding(17)
        }.background(Color(red:0.982,green:0.985,blue:0.979)).modifier(DropArea(desk:desk,hovering:$hover))
    }

    @ViewBuilder var right:some View {
        if let f=desk.current {
            VStack(spacing:0){
                HStack {
                    VStack(alignment:.leading,spacing:5){
                        Text(f.source.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
                        Text("\(f.pages) 页  ·  \(sizeText(f.bytes))").font(.caption).foregroundStyle(muted)
                    }
                    Spacer()
                    HStack(spacing:4){
                        Text("单份目标").font(.caption).foregroundStyle(muted)
                        TextField("10",text:Binding(get:{desk.files.first(where:{$0.id==f.id})?.targetMB ?? ""},set:{v in desk.edit(f.id){$0.targetMB=v}})).frame(width:54).disabled(desk.busy)
                        Text("MB").font(.caption).foregroundStyle(muted)
                    }
                    Button {showLinks=true} label:{Label(f.links.contains(where:{$0.problem}) ? "链接异常 \(f.links.filter{$0.problem}.count)":"链接 \(f.links.count)",systemImage:f.links.contains(where:{$0.problem}) ? "exclamationmark.triangle.fill":"link")}
                }.padding(.horizontal,19).frame(height:65)
                Divider()
                HStack {
                    if f.result != nil || desk.validEstimate != nil {Picker("",selection:$desk.mode){ForEach(["原稿"]+(desk.validEstimate != nil ? ["试压"]:[])+(f.result != nil ? ["对比","成品"]:[]),id:\.self){Text($0)}}.pickerStyle(.segmented).labelsHidden().frame(width:200)}
                    else {Label("原稿预览",systemImage:"doc.text").font(.caption.weight(.medium)).foregroundStyle(muted)}
                    if desk.useTotal,f.checked,let goal=desk.limit {Text("分配 "+sizeText(goal)).font(.caption2).foregroundStyle(teal)}
                    Spacer()
                    Button {desk.zoom=max(1,desk.zoom-0.5)} label:{Image(systemName:"minus.magnifyingglass")}.disabled(desk.zoom<=1)
                    Text(desk.zoom==1 ? "适合页面":"\(Int(desk.zoom*100))%").font(.caption).frame(width:54)
                    Button {desk.zoom=min(4,desk.zoom+0.5)} label:{Image(systemName:"plus.magnifyingglass")}.disabled(desk.zoom>=4)
                }.buttonStyle(.borderless).padding(.horizontal,19).frame(height:40)
                PreviewCanvas(f:f,mode:desk.mode,zoom:desk.zoom,draft:desk.validEstimate)
                Divider()
                HStack {
                    Button {desk.edit(f.id){$0.page-=1}} label:{Image(systemName:"chevron.left")}.disabled(f.page==0)
                    Text("\(f.page+1) / \(f.pages)").font(.caption.monospacedDigit())
                    Button {desk.edit(f.id){$0.page+=1}} label:{Image(systemName:"chevron.right")}.disabled(f.page+1>=f.pages)
                    Spacer()
                    if f.result != nil {
                        if let goal=desk.effectiveLimit(f) {Text(f.resultBytes<=goal ? "已达标":"未达 \(sizeText(goal))").foregroundStyle(f.resultBytes<=goal ? teal:Color.orange)}
                        Text(sizeText(f.resultBytes)).bold()
                        Button("导出…"){desk.export([f])}.disabled(desk.busy)
                    }
                }.padding(.horizontal,15).frame(height:45)
            }
        } else {
            VStack(spacing:16) {
                ZStack {
                    RoundedRectangle(cornerRadius:7).fill(Color(red:0.78,green:0.86,blue:0.81)).frame(width:73,height:93).rotationEffect(.degrees(-14)).offset(x:-12,y:0)
                    VStack(alignment:.leading,spacing:7){Text("PDF").font(.system(size:18,weight:.bold,design:.rounded)).foregroundStyle(teal)
                        ForEach([37,46,28],id:\.self){w in Capsule().fill(teal.opacity(0.25)).frame(width:CGFloat(w),height:3)}
                    }.frame(width:75,height:94).background(.white,in:RoundedRectangle(cornerRadius:7)).shadow(color:.black.opacity(0.10),radius:5,y:4).rotationEffect(.degrees(5))
                }.padding(.bottom,8)
                Text("添加 PDF 开始预览").font(.title3.bold())
                Text("可一次拖入多份文件，再勾选需要压缩的项目。").font(.callout).foregroundStyle(muted)
                Button("选择 PDF…"){desk.choose()}
            }.frame(maxWidth:.infinity,maxHeight:.infinity).background(field).modifier(DropArea(desk:desk,hovering:$hover))
        }
    }
}

@MainActor final class DeskDelegate:NSObject,NSApplicationDelegate {
    func application(_ application:NSApplication,open urls:[URL]) {Desk.shared.add(urls)}
}

@main struct PaperPress:App {
    @NSApplicationDelegateAdaptor(DeskDelegate.self) var delegate
    @StateObject private var desk=Desk.shared
    var body:some Scene {
        Window("PDF压缩",id:"desk"){DeskView(desk:desk)
            .onOpenURL{desk.add([$0])}
            .onReceive(NotificationCenter.default.publisher(for:NSApplication.willTerminateNotification)){_ in try? FileManager.default.removeItem(at:desk.temp)}
        }.defaultSize(width:1090,height:728)
        .commands {CommandGroup(after:.newItem){Button("添加 PDF…"){desk.choose()}.keyboardShortcut("o")}}
    }
}
