import AppKit
import SwiftUI

func sidebarWidthFor(preferred: Double, available: CGFloat) -> CGFloat {
    let desired = preferred.isFinite ? CGFloat(preferred) : 340
    return min(max(306, min(460, available - 488)), max(306, desired))
}

struct WorkspaceDivider: NSViewRepresentable {
    let width: CGFloat
    let maximum: CGFloat
    let resize: (CGFloat) -> Void

    func makeNSView(context: Context) -> DividerView { DividerView() }

    func updateNSView(_ view: DividerView, context: Context) {
        view.width = width
        view.maximum = max(306, maximum)
        view.resize = resize
        view.setAccessibilityValue(NSNumber(value: Double(width)))
    }
}

// A native handle supplies macOS cursor, keyboard and accessibility behavior.
// Only user adjustments save the preference; narrowing the window only clamps it.
final class DividerView: NSView {
    var width: CGFloat = 340
    var maximum: CGFloat = 460
    var resize: (CGFloat) -> Void = { _ in }
    private var startX: CGFloat = 0
    private var startWidth: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("调整文件列表宽度")
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height).fill()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        startX = event.locationInWindow.x
        startWidth = width
    }

    override func mouseDragged(with event: NSEvent) {
        resize(min(maximum, max(306, startWidth + event.locationInWindow.x - startX)))
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: adjust(-10)
        case 124: adjust(10)
        default: super.keyDown(with: event)
        }
    }

    private func adjust(_ delta: CGFloat) {
        resize(min(maximum, max(306, width + delta)))
    }

    override func accessibilityPerformIncrement() -> Bool { adjust(10); return true }
    override func accessibilityPerformDecrement() -> Bool { adjust(-10); return true }
}
