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
        desk.retryFailures()
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
        print("PASS settings, trial, failure recovery, retry, cancellation, session restoration")
    }
}
