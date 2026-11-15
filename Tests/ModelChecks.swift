import AppKit
import Foundation
import PDFKit

@main struct ModelChecks {
    @MainActor static func wait(_ desk:Desk) async throws {
        for _ in 0..<3000 {
            if !desk.busy {return}
            try await Task.sleep(for:.milliseconds(20))
        }
        fatalError("任务等待超时")
    }
    @MainActor static func main() async throws {
        precondition(sidebarWidthFor(preferred:400,available:1100)==400)
        precondition(sidebarWidthFor(preferred:400,available:860)==372)
        precondition(sidebarWidthFor(preferred:400,available:1100)==400)
        precondition(sidebarWidthFor(preferred:200,available:1100)==306)
        precondition(sidebarWidthFor(preferred:900,available:1100)==460)
        precondition(sidebarWidthFor(preferred:.nan,available:1100)==340)
        let divider=DividerView(frame:.zero)
        divider.width=400;divider.maximum=410
        var adjusted:CGFloat=0
        divider.resize={adjusted=$0}
        precondition(divider.accessibilityPerformIncrement() && adjusted==410)
        divider.width=306
        precondition(divider.accessibilityPerformDecrement() && adjusted==306)
        let root=URL(fileURLWithPath:CommandLine.arguments[1])
        let source=root.appendingPathComponent("model.pdf")
        let domain="local.pdfcompressor.tests."+UUID().uuidString
        let defaults=UserDefaults(suiteName:domain)!
        defer {defaults.removePersistentDomain(forName:domain)}
        let desk=Desk(defaults:defaults,storage:root.appendingPathComponent("model-results"))
        desk.add([source])
        precondition(desk.files.count==1)
        desk.quality=78;desk.dpi=150;desk.adaptive=false
        desk.edit(desk.files[0].id){$0.targetMB="10"}
        await desk.estimateCurrent()
        precondition(desk.estimateBytes != nil && desk.estimateURL != source)
        desk.start()
        try await wait(desk)
        precondition(desk.files[0].result != nil && desk.files[0].message.isEmpty)
        let exportDirectory=root.appendingPathComponent("export-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:exportDirectory,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:exportDirectory)}
        desk.saveResults(desk.files,to:exportDirectory)
        precondition(desk.notice.isEmpty && desk.exportMessage=="已导出 1 份 PDF")
        let saved=exportDirectory.appendingPathComponent("model（压缩版）.pdf")
        let savedData=try Data(contentsOf:saved)
        let resultData=try Data(contentsOf:desk.files[0].result!)
        precondition(savedData==resultData)
        desk.saveResults(desk.files,to:exportDirectory)
        precondition(FileManager.default.fileExists(atPath:exportDirectory.appendingPathComponent("model（压缩版）-2.pdf").path))
        let existing=desk.files[0].result
        // A failed re-run must retain the last successful output.
        let original=try Data(contentsOf:source)
        try Data("invalid".utf8).write(to:source)
        desk.estimateKey=nil;desk.start()
        try await wait(desk)
        precondition(desk.files[0].message=="处理失败")
        precondition(desk.files[0].result==existing)
        try original.write(to:source)
        desk.notice=""
        desk.retry(desk.files[0])
        try await wait(desk)
        precondition(desk.files[0].message.isEmpty)
        desk.adaptive=true
        desk.edit(desk.files[0].id){$0.targetMB="0.2"}
        desk.start()
        try await Task.sleep(for:.milliseconds(80))
        desk.stop()
        try await wait(desk)
        precondition(desk.files[0].message=="已停止")
        precondition(desk.files[0].result != nil)
        desk.notice=""
        desk.edit(desk.files[0].id){$0.targetMB="0.000001"}
        desk.export(desk.files)
        precondition(desk.warning?.issues.count==1 && desk.warning?.issues.first?.target==1)
        desk.warning=nil
        let issue=ExportIssue(file:desk.files[0],target:1)
        desk.force(SizeWarning(files:desk.files,issues:[issue]))
        try await wait(desk)
        precondition(desk.files[0].message=="处理失败" && desk.files[0].result != nil)
        desk.edit(desk.files[0].id){$0.targetMB="0.045"}
        desk.notice=""
        desk.retryFailures()
        try await wait(desk)
        precondition(desk.files[0].message.isEmpty && desk.files[0].resultBytes<=45000)
        desk.edit(desk.files[0].id){$0.targetMB="0.2"}
        desk.outputFolder=root.path
        desk.edit(desk.files[0].id){$0.page=1}
        desk.persist()
        let restored=Desk(defaults:defaults,storage:desk.temp)
        precondition(restored.quality==78 && restored.dpi==150 && restored.adaptive)
        precondition(restored.files.count==1 && restored.files[0].targetMB=="0.2")
        precondition(restored.files[0].page==1 && restored.files[0].result != nil)
        precondition(restored.outputFolder==root.path)
        // Source replacement invalidates cached results on the next launch.
        try Data("replaced".utf8).write(to:source)
        let invalidated=Desk(defaults:defaults,storage:desk.temp)
        precondition(invalidated.files.isEmpty)
        print("PASS settings, trial, export feedback and collision, failure recovery, row retry, cancellation, session restoration")
    }
}
