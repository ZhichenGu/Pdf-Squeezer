import AppKit
import SwiftUI
import PDFKit

struct LinkInfo: Decodable {
    let page: Int
    let label: String
    let url: String
    var status: String
    var problem: Bool
}

struct FileItem: Identifiable {
    let id = UUID()
    let source: URL
    let bytes: Int64
    let pages: Int
    var targetMB = "10"
    var checked = true
    var result: URL?
    var resultBytes: Int64 = 0
    var limit: Int64 = 0
    var message = ""
    var links: [LinkInfo] = []
    var audit = "正在读取链接"
    var page = 0
    var status: String {
        if !message.isEmpty { return message }
        if result != nil { return resultBytes <= limit ? "已达标" : "未达目标" }
        return "待压缩"
    }
}

func sizeText(_ n: Int64) -> String { String(format: "%.2f MB", Double(n)/1_000_000) }
func byteCount(_ url: URL) -> Int64 {
    Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
}
func runWorker(_ script: String, _ args: [String], progress: @escaping @Sendable (String)->Void = {_ in}) async throws -> String {
    let controller=WorkerController()
    return try await withTaskCancellationHandler(operation: {
    try await Task.detached(priority: .userInitiated) {
        let resources = Bundle.main.resourceURL!
        let process = Process()
        process.executableURL = resources.appendingPathComponent("runtime/bin/python3.12")
        process.arguments = ["-B",resources.appendingPathComponent(script).path] + args
        var env = ProcessInfo.processInfo.environment
        env["PYTHONHOME"] = resources.appendingPathComponent("runtime").path
        env["PYTHONNOUSERSITE"] = "1"
        env["PYTHONPATH"] = resources.path
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try controller.start(process)
        var data = Data()
        while true {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
            if script != "linkaudit.py", let line = String(data:chunk, encoding:.utf8)?.trimmingCharacters(in:.whitespacesAndNewlines) { progress(line) }
        }
        process.waitUntilExit()
        let output = String(decoding:data,as:UTF8.self)
        guard process.terminationStatus == 0 else {
            throw NSError(domain:"worker",code:1,userInfo:[NSLocalizedDescriptionKey:output.split(separator:"\n").last.map(String.init) ?? "无法读取或处理这份 PDF。"])
        }
        return output
    }.value
    }, onCancel:{controller.cancel()})
}

private final class WorkerController:@unchecked Sendable {
    private let lock=NSLock()
    private var process:Process?
    private var cancelled=false
    func start(_ p:Process)throws {
        lock.lock(); defer {lock.unlock()}
        guard !cancelled else{throw CancellationError()}
        try p.run();process=p
    }
    func cancel() {
        lock.lock();defer {lock.unlock()}
        cancelled=true
        if let p=process,p.isRunning {p.terminate()}
    }
}

struct EstimatePlan:Hashable {
    let file:UUID
    let target:Int64
    let dpi:Int
    let quality:Int
    let modified:Date?
}

@MainActor final class Desk: ObservableObject {
    static let shared=Desk()
    @Published var estimateKey:EstimatePlan?
    @Published var estimateBytes:Int64?
    @Published var estimateURL:URL?
    @Published var estimateError=""
    var plan:EstimatePlan? {
        guard let f=current,let target=limit else{return nil}
        return EstimatePlan(file:f.id,target:target,dpi:Int(dpi),quality:Int(quality),modified:(try? f.source.resourceValues(forKeys:[.contentModificationDateKey]))?.contentModificationDate)
    }
    var validEstimate:URL? {estimateKey == plan ? estimateURL:nil}
    func estimateCurrent() async {
        guard let f=current,let key=plan,estimateKey != key || estimateBytes==nil else{return}
        if mode=="试压" {mode="原稿"}
        estimateError=""
        do {
            try await Task.sleep(for:.milliseconds(500))
            let url=temp.appendingPathComponent(UUID().uuidString+".pdf")
            if f.bytes <= key.target {
                estimateURL=f.source; estimateBytes=f.bytes; estimateKey=key; return
            }
            _=try await runWorker("engine.py",[f.source.path,url.path,String(key.target),String(key.dpi),String(key.quality),"0"])
            guard !Task.isCancelled,key==plan else {try? FileManager.default.removeItem(at:url);return}
            estimateURL=url; estimateBytes=byteCount(url); estimateKey=key
        } catch { if !Task.isCancelled {estimateError="试压失败："+error.localizedDescription} }
    }
    @Published var files: [FileItem] = []
    @Published var focus: UUID?
    @Published var batchTarget = "10"
    @Published var useTotal = false
    @Published var totalMB = "20"
    @Published var batchSummary = ""
    @Published var warning:SizeWarning?
    var afterWarning:(()->Void)?
    func effectiveLimit(_ file:FileItem)->Int64? {
        file.checked ? goals?[file.id]:bytesFromMB(file.targetMB)
    }
    func checkLimits(_ items:[FileItem]) -> SizeWarning? {
        let issues=items.compactMap{ f -> ExportIssue? in
            guard let cap=effectiveLimit(f),f.resultBytes>cap else{return nil}
            return ExportIssue(file:f,target:cap)
        }
        return issues.isEmpty ? nil:SizeWarning(files:items,issues:issues)
    }
    @Published var quality = 85.0
    @Published var dpi = 180.0
    @Published var adaptive = true
    @Published var busy = false
    @Published var active: UUID?
    @Published var progress = ""
    @Published var notice = ""
    @Published var mode = "原稿"
    @Published var zoom = 1.0
    @Published var webChecks: Set<UUID> = []
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("Paperpress-"+UUID().uuidString)
    init() { try? FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true) }
    var current: FileItem? { files.first{$0.id==focus} }
    var checked: [FileItem] { files.filter(\.checked) }
    func bytesFromMB(_ target:String)->Int64? {
        guard let v=Double(target.trimmingCharacters(in:.whitespaces).replacingOccurrences(of:",",with:".")), v.isFinite,v>=0.000001,v<=1_000_000 else { return nil }
        return Int64(v*1_000_000)
    }
    var goals:[UUID:Int64]? {
        var values=[UUID:Int64]()
        for file in checked {
            guard let cap=bytesFromMB(file.targetMB) else{return nil}
            values[file.id]=cap
        }
        guard useTotal else{return values}
        guard let total=bytesFromMB(totalMB),total>=Int64(values.count) else{return nil}
        for file in checked {values[file.id]=min(values[file.id]!,max(1,file.bytes))}
        let sum=values.values.reduce(0,+)
        guard sum>total else{return values}
        let available=total-Int64(values.count)
        return values.mapValues{1+Int64(floor(Double(available)*Double($0)/Double(sum)))}
    }
    var limit:Int64? {
        guard let f=current else{return nil}
        return f.checked ? goals?[f.id]:bytesFromMB(f.targetMB)
    }
    func applyBatchTarget() {
        guard bytesFromMB(batchTarget) != nil else{return}
        for i in files.indices where files[i].checked {files[i].targetMB=batchTarget}
    }
    func edit(_ id:UUID,_ update:(inout FileItem)->Void) {
        if let i=files.firstIndex(where:{$0.id==id}) { update(&files[i]) }
    }
    func focusOn(_ f:FileItem) {
        focus=f.id; mode=f.result == nil ? "原稿":"对比"; zoom=1
    }
    func remove(_ id:UUID) {
        guard !busy else { return }
        files.removeAll{$0.id==id}
        if focus==id { if let f=files.first { focusOn(f) } else { focus=nil } }
    }
    func choose() {
        let p=NSOpenPanel(); p.allowedContentTypes=[.pdf]; p.allowsMultipleSelection=true
        if p.runModal() == .OK { add(p.urls) }
    }
    func add(_ urls:[URL]) {
        var failed=[String]()
        for u in urls {
            let u=u.standardizedFileURL
            if files.contains(where:{$0.source==u}) { continue }
            guard u.pathExtension.lowercased()=="pdf",let doc=PDFDocument(url:u),!doc.isLocked,doc.pageCount>0 else { failed.append(u.lastPathComponent); continue }
            let item=FileItem(source:u,bytes:byteCount(u),pages:doc.pageCount)
            files.append(item)
            if current == nil { focusOn(item) }
            Task {
                do {
                    let output=try await runWorker("linkaudit.py",[u.path])
                    let links=try JSONDecoder().decode([LinkInfo].self,from:Data(output.utf8))
                    edit(item.id){$0.links=links; $0.audit=""}
                } catch { edit(item.id){$0.audit="链接读取失败"} }
            }
        }
        if !failed.isEmpty { notice="无法打开或需要解锁："+failed.joined(separator:"、") }
    }
    func start() {
        guard !busy,let goals=goals,!checked.isEmpty else { return }
        let list=checked, settings=[String(Int(dpi)),String(Int(quality)),adaptive ? "1":"0"]
        busy=true;batchSummary=""
        let totalBudget=useTotal ? bytesFromMB(totalMB):nil
        Task {
            for (idx,f) in list.enumerated() {
                guard let goal=goals[f.id] else{continue}
                active=f.id
                let prefix="\(idx+1)/\(list.count)"
                progress="\(prefix) · 读取 PDF"
                edit(f.id){$0.message="处理中"}
                let out=temp.appendingPathComponent(UUID().uuidString+".pdf")
                do {
                    if let key=estimateKey,key.file==f.id,key.target==goal,key.dpi==Int(dpi),key.quality==Int(quality),key.modified==(try? f.source.resourceValues(forKeys:[.contentModificationDateKey]))?.contentModificationDate,let cached=estimateURL,let size=estimateBytes,(size<=goal || !adaptive) {
                        try FileManager.default.copyItem(at:cached,to:out)
                    } else { _=try await runWorker("engine.py",[f.source.path,out.path,String(goal)]+settings){line in
                        Task { @MainActor in if self.active==f.id {self.progress=prefix+" · "+line} }
                    }
                    }
                    guard let doc=PDFDocument(url:out),doc.pageCount==f.pages else { throw NSError(domain:"PDF",code:2,userInfo:[NSLocalizedDescriptionKey:"输出文档校验失败"]) }
                    edit(f.id){$0.result=out; $0.resultBytes=byteCount(out); $0.limit=goal; $0.message=""}
                    if focus==f.id {mode="对比"}
                } catch {
                    edit(f.id){$0.message="处理失败"; $0.result=nil}
                    notice=f.source.lastPathComponent+"："+error.localizedDescription
                }
            }
            let completed=files.filter{goals[$0.id] != nil && $0.result != nil}
            let bytes=completed.reduce(Int64(0)){$0+$1.resultBytes}
            batchSummary="本次完成 \(completed.count)/\(list.count) 份 · 合计 "+sizeText(bytes)
            if let budget=totalBudget {batchSummary += completed.count != list.count ? "（部分完成）":(bytes<=budget ? "（总量达标）":"（超过合计上限）")}
            active=nil; busy=false; progress=""
            if notice.isEmpty {warning=checkLimits(completed)}
        }
    }
    func export(_ items:[FileItem]) {
        let ready=items.filter{$0.result != nil}
        guard !ready.isEmpty else{return}
        if ready.contains(where:{effectiveLimit($0)==nil}) {
            notice="请先填写有效的目标大小。";return
        }
        if let problem=checkLimits(ready) {warning=problem;return}
        saveResults(ready)
    }
    func force(_ request:SizeWarning) {
        guard !busy else{return}
        busy=true
        focusOn(request.issues[0].file)
        Task {
            var failures=[String]()
            for (i,issue) in request.issues.enumerated() {
                let file=issue.file
                let out=temp.appendingPathComponent(UUID().uuidString+".pdf")
                active=file.id
                let prefix="强压 \(i+1)/\(request.issues.count)"
                progress=prefix+" · 渲染页面"
                edit(file.id){$0.message="强压中"}
                do {
                    _=try await runWorker("strong.py",[file.source.path,out.path,String(issue.target)]){line in
                        Task {@MainActor in if self.active==file.id {self.progress=prefix+" · "+line} }
                    }
                    let bytes=byteCount(out)
                    guard bytes>0,bytes<=issue.target,let doc=PDFDocument(url:out),doc.pageCount==file.pages else {
                        throw NSError(domain:"PDF",code:2,userInfo:[NSLocalizedDescriptionKey:"强压结果未通过大小或页数校验。"])
                    }
                    edit(file.id){$0.result=out; $0.resultBytes=bytes; $0.limit=issue.target; $0.message=""}
                } catch {
                    try? FileManager.default.removeItem(at:out)
                    edit(file.id){$0.message=""}
                    failures.append(file.source.lastPathComponent+"："+error.localizedDescription)
                }
            }
            let ids=Set(request.files.map(\.id))
            let sum=files.filter{ids.contains($0.id)}.reduce(Int64(0)){$0+$1.resultBytes}
            batchSummary="强压达标 \(request.issues.count-failures.count)/\(request.issues.count) 份 · 本组共 "+sizeText(sum)
            active=nil;busy=false;progress="";mode="对比"
            if !failures.isEmpty {notice=failures.joined(separator:"\n")}
        }
    }
    func saveResults(_ ready:[FileItem]) {
        let panel=NSOpenPanel(); panel.canChooseFiles=false; panel.canChooseDirectories=true; panel.canCreateDirectories=true
        panel.prompt="导出到此处"
        guard panel.runModal() == .OK,let dir=panel.url else { return }
        do {
            for f in ready {
                let title=f.source.deletingPathExtension().lastPathComponent+"（压缩版）"
                var i=1
                while true {
                    let name=i==1 ? title : title+"-"+String(i)
                    do { try FileManager.default.copyItem(at:f.result!,to:dir.appendingPathComponent(name+".pdf"));break }
                    catch let error as NSError where error.domain==NSCocoaErrorDomain && error.code==NSFileWriteFileExistsError { i+=1 }
                }
            }
            notice="已导出 \(ready.count) 份 PDF 至「\(dir.lastPathComponent)」。"
        } catch { notice=error.localizedDescription }
    }
    func checkWeb(_ f:FileItem) {
        guard !webChecks.contains(f.id) else {return}
        webChecks.insert(f.id)
        Task {
            let urls=Set(f.links.filter{["https","http"].contains(URL(string:$0.url)?.scheme?.lowercased() ?? "") && $0.status != "地址格式无效"}.map(\.url))
            for raw in urls {
                guard let url=URL(string:raw) else {continue}
                let (status,issue)=await probe(url)
                edit(f.id){ file in for i in file.links.indices where file.links[i].url==raw {file.links[i].status=status; file.links[i].problem=issue} }
            }
            webChecks.remove(f.id)
        }
    }
}

func probe(_ url:URL) async -> (String,Bool) {
    let config=URLSessionConfiguration.ephemeral
    config.httpShouldSetCookies=false; config.urlCredentialStorage=nil
    config.timeoutIntervalForRequest=8; config.timeoutIntervalForResource=12
    let session=URLSession(configuration:config)
    defer {session.invalidateAndCancel()}
    for method in ["HEAD","GET"] {
        var req=URLRequest(url:url)
        req.httpMethod=method
        if method=="GET" { req.setValue("bytes=0-0",forHTTPHeaderField:"Range") }
        do {
            let (_,response)=try await session.bytes(for:req)
            guard let http=response as? HTTPURLResponse else {return ("无法确认",true)}
            let code=http.statusCode
            if method=="HEAD",code>=400 {continue}
            switch code {
            case 200..<400: return ("可访问 · \(code)",false)
            case 401,403: return ("需要登录或访问受限 · \(code)",true)
            case 404,410: return ("目标页面不存在 · \(code)",true)
            default: return ("服务器返回 \(code)",true)
            }
        } catch { if method=="GET" {return ("连接失败 · "+error.localizedDescription,true)} }
    }
    return ("无法确认",true)
}
