import SwiftUI
import PDFKit

let ink = Color(red:0.10,green:0.17,blue:0.17)
let muted = Color(red:0.34,green:0.39,blue:0.39)
let teal = Color(red:0.03,green:0.38,blue:0.33)
let mint = Color(red:0.87,green:0.94,blue:0.91)
let line = Color.black.opacity(0.105)
let field = Color(red:0.935,green:0.942,blue:0.934)

struct PreviewKey: Hashable {
    let original:URL
    let result:URL?
    let page:Int
    let scale:Int
}
struct Shots {
    let before:NSImage
    let after:NSImage?
}
struct PreviewCanvas:View {
    let f:FileItem
    let mode:String
    let zoom:Double
    let draft:URL?
    @State private var shots:Shots?
    @State private var position=0.5
    @State private var failed=false
    @Environment(\.displayScale) var screenScale
    var body:some View {
        GeometryReader { geo in
            let width=max(100,geo.size.width-60), height=max(100,geo.size.height-60)
            let resolution=Int(min(6000,ceil(max(width,height)*zoom*screenScale/256)*256))
            let key=PreviewKey(original:f.source,result:mode=="试压" ? draft:f.result,page:f.page,scale:resolution)
            ZStack {
                field
                if let shots {
                    let image=shots.before
                    let fit=min(width/image.size.width,height/image.size.height)*zoom
                    let w=image.size.width*fit,h=image.size.height*fit
                    ScrollView([.horizontal,.vertical]) {
                        ZStack(alignment:.leading) {
                            Image(nsImage:mode=="成品" ? shots.after ?? image:image).resizable()
                            if ["对比","试压"].contains(mode),let after=shots.after {
                                Image(nsImage:after).resizable().frame(width:w,height:h)
                                    .mask(alignment:.trailing) {Rectangle().frame(width:w*(1-position))}
                                Rectangle().fill(teal).frame(width:2,height:h).offset(x:w*position-1)
                                Image(systemName:"arrow.left.and.right").font(.system(size:13,weight:.bold))
                                    .foregroundStyle(.white).frame(width:33,height:33).background(teal,in:Circle())
                                    .position(x:w*position,y:h/2)
                                HStack { badge("原稿");Spacer();badge(mode=="试压" ? "参数试压":"压缩后") }.padding(9).frame(width:w,height:h,alignment:.top)
                            }
                        }.frame(width:w,height:h).background(.white).shadow(color:.black.opacity(0.15),radius:7,y:2)
                        .contentShape(Rectangle())
                        .simultaneousGesture(DragGesture(minimumDistance:0,coordinateSpace:.local).onChanged{v in
                            if ["对比","试压"].contains(mode) { position=max(0,min(1,v.location.x/w)) }
                        })
                        .padding(24).frame(minWidth:geo.size.width,minHeight:geo.size.height)
                    }
                } else if failed { Label("当前页预览不可用",systemImage:"doc.badge.ellipsis") }
                else { ProgressView().controlSize(.small) }
            }.task(id:key) {
                failed=false
                shots=nil
                let result=await Task.detached(priority:.userInitiated) { () -> Shots? in
                    func draw(_ url:URL)->NSImage? {
                        guard let page=PDFDocument(url:url)?.page(at:key.page) else{return nil}
                        var rect=page.bounds(for:.cropBox)
                        if (abs(page.rotation)%180)==90 {rect.size=CGSize(width:rect.height,height:rect.width)}
                        guard min(rect.width,rect.height)>0 else{return nil}
                        let factor=CGFloat(key.scale)/max(rect.width,rect.height)
                        return page.thumbnail(of:CGSize(width:rect.width*factor,height:rect.height*factor),for:.cropBox)
                    }
                    guard let before=draw(key.original) else{return nil}
                    return Shots(before:before,after:key.result.flatMap(draw))
                }.value
                guard !Task.isCancelled else{return}
                shots=result; failed=result==nil
            }
        }
    }
    func badge(_ text:String)->some View {
        Text(text).font(.caption.bold()).foregroundStyle(.white).padding(.horizontal,7).padding(.vertical,4)
            .background(.black.opacity(0.62),in:RoundedRectangle(cornerRadius:4))
    }
}

struct LinksPanel:View {
    @ObservedObject var desk:Desk
    let id:UUID
    @Environment(\.dismiss) var dismiss
    var body:some View {
        if let f=desk.files.first(where:{$0.id==id}) {
            VStack(alignment:.leading,spacing:16) {
                HStack {Label("链接检查",systemImage:"link").font(.title2.bold());Spacer();Button("完成"){dismiss()} }
                Text(f.source.lastPathComponent).foregroundStyle(muted).lineLimit(1)
                Divider()
                if f.links.isEmpty { Text(f.audit.isEmpty ? "未发现 PDF 链接注释。":f.audit).foregroundStyle(muted); Spacer() }
                else {
                    ScrollView {
                        VStack(spacing:0) {
                            ForEach(f.links.indices,id:\.self){ i in
                                let l=f.links[i]
                                HStack(alignment:.top,spacing:12) {
                                    Button("第 \(l.page) 页"){desk.edit(id){$0.page=l.page-1}; dismiss()}.buttonStyle(.borderless)
                                    VStack(alignment:.leading,spacing:5) {
                                        Text(l.label).lineLimit(2).textSelection(.enabled)
                                        Label(l.status,systemImage:l.problem ? "exclamationmark.triangle":"link").font(.caption)
                                            .foregroundStyle(l.problem ? Color.orange:muted)
                                    };Spacer()
                                }.padding(.vertical,10)
                                Divider()
                            }
                        }
                    }
                    HStack {
                        Text("联网检测会访问文档中的网页地址。").font(.caption).foregroundStyle(muted)
                        Spacer()
                        Button(desk.webChecks.contains(id) ? "正在检测…":"检测网址"){desk.checkWeb(f)}
                            .disabled(desk.webChecks.contains(id) || !f.links.contains{["http","https"].contains(URL(string:$0.url)?.scheme?.lowercased() ?? "")})
                    }
                }
            }.padding(24).frame(width:540,height:400)
        }
    }
}
