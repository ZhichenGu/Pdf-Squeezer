import SwiftUI

struct ExportIssue:Identifiable {
    var id:UUID {file.id}
    let file:FileItem
    let target:Int64
}
struct SizeWarning:Identifiable {
    let id=UUID()
    let files:[FileItem]
    let issues:[ExportIssue]
    var bytes:Int64 {files.reduce(0){$0+$1.resultBytes}}
}

struct SizeWarningPanel:View {
    let warning:SizeWarning
    let accept:()->Void
    let adjust:()->Void
    let retry:()->Void
    let cancel:()->Void
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Label("压缩结果超过目标",systemImage:"exclamationmark.triangle.fill")
                .font(.title2.bold()).foregroundStyle(ink)
            ScrollView {
                VStack(alignment:.leading,spacing:12) {
                    ForEach(warning.issues){ issue in
                        VStack(alignment:.leading,spacing:5){
                            Text(issue.file.source.lastPathComponent).lineLimit(2)
                            Text("当前 "+sizeText(issue.file.resultBytes)+"　目标 "+sizeText(issue.target)+"　超出 "+sizeText(issue.file.resultBytes-issue.target))
                                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        }.frame(maxWidth:.infinity,alignment:.leading)
                    }
                }
            }.frame(height:min(CGFloat(warning.issues.count)*59,190))
            Divider()
            Text("强力压缩会把页面画面转为图片，保留可搜索文字和链接。放大时细节可能变软，完成后可先对比再导出。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            HStack {
                Button("取消",action:cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("调整参数",action:adjust)
                Button("强力压缩",action:retry)
                Button("导出 "+sizeText(warning.bytes),action:accept)
            }
        }.padding(24).frame(width:550)
    }
}
