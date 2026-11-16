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
            if warning.issues.count == 1 {
                issuesList
            } else {
                ScrollView { issuesList }.frame(height:min(CGFloat(warning.issues.count)*80,190))
            }
            if let summary=warning.issues.first?.file.analysis, !summary.isEmpty {
                Text("文件组成 · "+summary).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Text("强力压缩可能降低放大后的细节，可搜索文字和链接会保留。完成后可先对比再导出。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            HStack {
                Button("取消",action:cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("调整参数",action:adjust)
                Button("强力压缩",action:retry)
                Button("仍导出 "+sizeText(warning.bytes),action:accept)
            }
        }.padding(24).frame(width:550)
    }
    private var issuesList: some View {
        VStack(alignment:.leading,spacing:12) {
                    ForEach(warning.issues){ issue in
                        VStack(alignment:.leading,spacing:5){
                            Text(issue.file.source.lastPathComponent).lineLimit(2)
                            HStack(spacing:8) {
                                Text(sizeText(issue.file.resultBytes)).foregroundStyle(.orange)
                                Image(systemName:"arrow.right").font(.caption).foregroundStyle(.secondary)
                                Text("目标 "+sizeText(issue.target))
                            }.font(.system(size:16,weight:.semibold)).monospacedDigit()
                            Text("超出 "+sizeText(issue.file.resultBytes-issue.target)).font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth:.infinity,alignment:.leading)
                    }
        }
    }

}
