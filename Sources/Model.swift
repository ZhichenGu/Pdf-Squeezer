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
    var analysis = ""
    var retryStrong = false
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
        try Task.checkCancellation()
        let output = String(decoding:data,as:UTF8.self)
        guard process.terminationStatus == 0 else {
            throw NSError(domain:"worker",code:1,userInfo:[NSLocalizedDescriptionKey:output.split(separator:"\n").last.map(String.init) ?? "无法读取或处理这份 PDF。"])
        }
        try Task.checkCancellation()
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
        guard !busy,let f=current,let target=limit else{return nil}
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
            do {
                _=try await runWorker("engine.py",[f.source.path,url.path,String(key.target),String(key.dpi),String(key.quality),"0"])
            } catch {
                try? FileManager.default.removeItem(at:url)
                throw error
            }
            guard !Task.isCancelled,key==plan else {try? FileManager.default.removeItem(at:url);return}
            estimateURL=url; estimateBytes=byteCount(url); estimateKey=key
        } catch { if !Task.isCancelled {estimateError="试压失败："+error.localizedDescription} }
    }
    @Published var files: [FileItem] = [] { didSet { persist() } }
    @Published var focus: UUID?
    @Published var batchTarget = "10" { didSet { persist() } }
    @Published var batchSummary = ""
    @Published var warning:SizeWarning?
    var afterWarning:(()->Void)?
    func effectiveLimit(_ file:FileItem)->Int64? {
        bytesFromMB(file.targetMB)
    }
    func checkLimits(_ items:[FileItem]) -> SizeWarning? {
        let issues=items.compactMap{ f -> ExportIssue? in
            guard let cap=effectiveLimit(f),f.resultBytes>cap else{return nil}
            return ExportIssue(file:f,target:cap)
        }
        return issues.isEmpty ? nil:SizeWarning(files:items,issues:issues)
    }
    @Published var quality = 85.0 { didSet { persist() } }
    @Published var dpi = 180.0 { didSet { persist() } }
    @Published var adaptive = true { didSet { persist() } }
    @Published var busy = false
    @Published var active: UUID?
    @Published var progress = ""
    @Published var notice = ""
    @Published var mode = "原稿"
    @Published var zoom = 1.0
    @Published var webChecks: Set<UUID> = []
    private var batchTask:Task<Void,Never>?
    @Published var stopping = false
    @Published var outputFolder = "" { didSet { persist() } }
    @Published var memoryError = ""
    private let defaults:UserDefaults
    private var restoring = true
    let temp:URL
    init(defaults:UserDefaults = .standard, storage:URL? = nil) {
        self.defaults = defaults
        temp = storage ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("PDF-Squeezer/Results")
        do { try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true) }
        catch { memoryError="无法创建结果保存目录："+error.localizedDescription }
        if let data=defaults.data(forKey:"session-v12"),let saved=try? JSONDecoder().decode(SavedSession.self,from:data) {
            quality=min(98,max(45,saved.quality));dpi=saved.dpi
            adaptive=saved.adaptive;batchTarget=saved.batchTarget
            outputFolder=saved.outputFolder
            for record in saved.files {
                let source=URL(fileURLWithPath:record.path)
                guard let doc=PDFDocument(url:source),!doc.isLocked,doc.pageCount>0 else {continue}
                var file=FileItem(source:source,bytes:byteCount(source),pages:doc.pageCount)
                file.targetMB=record.target;file.checked=record.checked
                file.page=min(max(0,record.page),file.pages-1)
                file.message=record.message == "处理失败" ? "处理失败":""
                file.retryStrong=record.retryStrong ?? false
                let unchanged=record.bytes==file.bytes && record.modified == modification(source)
                if unchanged,let name=record.result, !name.contains("/"),name.hasSuffix(".pdf") {
                    let result=temp.appendingPathComponent(name)
                    if let resultDoc=PDFDocument(url:result),resultDoc.pageCount==file.pages {
                        file.result=result;file.resultBytes=byteCount(result);file.limit=record.limit
                    }
                }
                files.append(file)
            }
            focus=files.first?.id
        }
        restoring=false
        for file in files { audit(file) }
        pruneCache()
    }
    func persist() {
        guard !restoring else{return}
        let records=files.map {f in SavedFile(path:f.source.path,target:f.targetMB,checked:f.checked,
            page:f.page,bytes:f.bytes,modified:modification(f.source),
            result:f.result?.lastPathComponent,limit:f.limit,message:f.message,retryStrong:f.retryStrong)}
        let state=SavedSession(quality:quality,dpi:dpi,adaptive:adaptive,batchTarget:batchTarget,
            outputFolder:outputFolder,files:records)
        if let data=try? JSONEncoder().encode(state) {defaults.set(data,forKey:"session-v12")}
    }
    func pruneCache() {
        let keep=Set(files.compactMap{$0.result?.lastPathComponent} + [estimateURL?.lastPathComponent].compactMap{$0})
        for url in (try? FileManager.default.contentsOfDirectory(at:temp,includingPropertiesForKeys:nil)) ?? [] {
            if !keep.contains(url.lastPathComponent) {try? FileManager.default.removeItem(at:url)}
        }
    }
    func stop() {
        stopping=true
        batchTask?.cancel()
    }
    func retryFailures() {
        let failed=files.filter{$0.message=="处理失败"}
        guard !failed.isEmpty else{return}
        start(items:failed,retrying:true)
    }
    func audit(_ file:FileItem) {
        Task {
            do {
                let output=try await runWorker("linkaudit.py",[file.source.path])
                let links=try JSONDecoder().decode([LinkInfo].self,from:Data(output.utf8))
                edit(file.id){$0.links=links;$0.audit=""}
                let report=try await runWorker("preflight.py",[file.source.path])
                if let object=try JSONSerialization.jsonObject(with:Data(report.utf8)) as? [String:String] {
                    edit(file.id){$0.analysis=object["summary"] ?? ""}
                }
            } catch {edit(file.id){$0.audit="链接或文件分析读取失败"}}
        }
    }
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
        return values
    }
    var limit:Int64? {
        guard let f=current else{return nil}
        return bytesFromMB(f.targetMB)
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
            audit(item)
        }
        if !failed.isEmpty { notice="无法打开或需要解锁："+failed.joined(separator:"、") }
    }
    func start(items:[FileItem]? = nil, retrying:Bool = false) {
        guard !busy,let goals=goals else { return }
        let list=items ?? checked
        guard !list.isEmpty else{return}
        let settings=[String(Int(dpi)),String(Int(quality)),adaptive ? "1":"0"]
        if mode=="试压" {mode="原稿"}
        busy=true;stopping=false;batchSummary=""
        batchTask=Task {
            var failures=[String]()
            var completedIDs=Set<UUID>()
            for (idx,f) in list.enumerated() {
                if Task.isCancelled {break}
                guard let goal=goals[f.id] ?? bytesFromMB(f.targetMB) else{continue}
                active=f.id
                let prefix="\(idx+1)/\(list.count)"
                progress="\(prefix) · 读取 PDF"
                let strong=retrying && f.retryStrong
                edit(f.id){$0.message="处理中";$0.retryStrong=strong}
                let out=temp.appendingPathComponent(UUID().uuidString+".pdf")
                do {
                    if !strong,let key=estimateKey,key.file==f.id,key.target==goal,key.dpi==Int(dpi),key.quality==Int(quality),key.modified==(try? f.source.resourceValues(forKeys:[.contentModificationDateKey]))?.contentModificationDate,let cached=estimateURL,estimateBytes != nil,!adaptive {
                        try FileManager.default.copyItem(at:cached,to:out)
                    } else {
                        let script=strong ? "strong.py":"engine.py"
                        let arguments=[f.source.path,out.path,String(goal)]+(strong ? []:settings)
                        _=try await runWorker(script,arguments){line in
                        Task { @MainActor in if self.active==f.id {self.progress=prefix+" · "+line} }
                    }
                    }
                    try Task.checkCancellation()
                    guard let doc=PDFDocument(url:out),doc.pageCount==f.pages else { throw NSError(domain:"PDF",code:2,userInfo:[NSLocalizedDescriptionKey:"输出文档校验失败"]) }
                    edit(f.id){$0.result=out; $0.resultBytes=byteCount(out); $0.limit=goal; $0.message=""}
                    completedIDs.insert(f.id)
                    if focus==f.id {mode="对比"}
                } catch {
                    try? FileManager.default.removeItem(at:out)
                    if Task.isCancelled {edit(f.id){$0.message="已停止"};break}
                    edit(f.id){$0.message="处理失败"}
                    failures.append(f.source.lastPathComponent+"："+error.localizedDescription)
                }
            }
            let completed=files.filter{completedIDs.contains($0.id)}
            let bytes=completed.reduce(Int64(0)){$0+$1.resultBytes}
            batchSummary="本次完成 \(completed.count)/\(list.count) 份 · 合计 "+sizeText(bytes)
            if Task.isCancelled {batchSummary="已停止 · "+batchSummary}
            active=nil; busy=false; stopping=false; progress=""; batchTask=nil
            if !failures.isEmpty {notice=failures.joined(separator:"\n")}
            else if !Task.isCancelled {warning=checkLimits(completed)}
            persist();pruneCache()
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
        busy=true;stopping=false
        focusOn(request.issues[0].file)
        batchTask=Task {
            var failures=[String]()
            for (i,issue) in request.issues.enumerated() {
                if Task.isCancelled {break}
                let file=issue.file
                let out=temp.appendingPathComponent(UUID().uuidString+".pdf")
                active=file.id
                let prefix="强压 \(i+1)/\(request.issues.count)"
                progress=prefix+" · 渲染页面"
                edit(file.id){$0.message="强压中";$0.retryStrong=true}
                do {
                    _=try await runWorker("strong.py",[file.source.path,out.path,String(issue.target)]){line in
                        Task {@MainActor in if self.active==file.id {self.progress=prefix+" · "+line} }
                    }
                    try Task.checkCancellation()
                    let bytes=byteCount(out)
                    guard bytes>0,bytes<=issue.target,let doc=PDFDocument(url:out),doc.pageCount==file.pages else {
                        throw NSError(domain:"PDF",code:2,userInfo:[NSLocalizedDescriptionKey:"强压结果未通过大小或页数校验。"])
                    }
                    edit(file.id){$0.result=out; $0.resultBytes=bytes; $0.limit=issue.target; $0.message=""}
                } catch {
                    try? FileManager.default.removeItem(at:out)
                    if Task.isCancelled {edit(file.id){$0.message="已停止"};break}
                    edit(file.id){$0.message="处理失败"}
                    failures.append(file.source.lastPathComponent+"："+error.localizedDescription)
                }
            }
            let ids=Set(request.files.map(\.id))
            let sum=files.filter{ids.contains($0.id)}.reduce(Int64(0)){$0+$1.resultBytes}
            batchSummary="强压达标 \(request.issues.count-failures.count)/\(request.issues.count) 份 · 本组共 "+sizeText(sum)
            if Task.isCancelled {batchSummary="已停止 · 已有成品可继续导出"}
            active=nil;busy=false;stopping=false;progress="";mode="对比";batchTask=nil
            if !failures.isEmpty {notice=failures.joined(separator:"\n")}
            persist();pruneCache()
        }
    }
    func saveResults(_ ready:[FileItem]) {
        let panel=NSOpenPanel(); panel.canChooseFiles=false; panel.canChooseDirectories=true; panel.canCreateDirectories=true
        panel.prompt="导出到此处"
        if !outputFolder.isEmpty {panel.directoryURL=URL(fileURLWithPath:outputFolder)}
        guard panel.runModal() == .OK,let dir=panel.url else { return }
        outputFolder=dir.path
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

private func modification(_ url:URL)->Date? {
    (try? url.resourceValues(forKeys:[.contentModificationDateKey]))?.contentModificationDate
}
private struct SavedFile:Codable {
    let path:String
    let target:String
    let checked:Bool
    let page:Int
    let bytes:Int64
    let modified:Date?
    let result:String?
    let limit:Int64
    let message:String?
    let retryStrong:Bool?
}
private struct SavedSession:Codable {
    let quality:Double
    let dpi:Double
    let adaptive:Bool
    let batchTarget:String
    let outputFolder:String
    let files:[SavedFile]
}
