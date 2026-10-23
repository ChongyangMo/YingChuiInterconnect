import AppKit
import ApplicationServices
import XCTest
import YingchuiProtocol
@testable import YingchuiMac

final class MacNativeDragTests: XCTestCase, @unchecked Sendable {
    @MainActor
    func testNativeSidebarDividerSliderAndTextSelectionRespondToHeldDrag() async throws {
        _ = try XCTUnwrap(AXIsProcessTrusted() ? true : nil, "原生拖动验证需要已有辅助功能授权")
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let window = NSWindow(contentRect: CGRect(x: screen.visibleFrame.midX - 260,
            y: screen.visibleFrame.midY - 160, width: 520, height: 320),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "拖动自动验证"
        window.level = .floating
        window.isReleasedWhenClosed = false
        let split = NSSplitView(frame: CGRect(x: 0, y: 0, width: 520, height: 320))
        split.isVertical = true
        split.dividerStyle = .thick
        let left = NSView(frame: CGRect(x: 0, y: 0, width: 180, height: 320))
        let right = NSView(frame: CGRect(x: 0, y: 0, width: 330, height: 320))
        split.addArrangedSubview(left)
        split.addArrangedSubview(right)
        window.contentView = split
        split.setPosition(180, ofDividerAt: 0)
        let slider = NSSlider(value: 0.2, minValue: 0, maxValue: 1, target: nil, action: nil)
        slider.frame = CGRect(x: 10, y: 230, width: 200, height: 24)
        right.addSubview(slider)
        let text = NSTextView(frame: CGRect(x: 10, y: 30, width: 230, height: 120))
        text.string = "拖动选择文字并验证鼠标按住状态"
        text.font = .systemFont(ofSize: 15)
        right.addSubview(text)
        let originalPointer = CGEvent(source: nil)?.location
        defer {
            window.close()
            if let originalPointer {
                CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                    mouseCursorPosition: originalPointer, mouseButton: .left)?.post(tap: .cghidEventTap)
            }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        try await Task.sleep(for: .milliseconds(350))
        let bounds = CGDisplayBounds(CGMainDisplayID())
        func point(_ local: CGPoint, in view: NSView) -> CGPoint {
            let cocoa = window.convertPoint(toScreen: view.convert(local, to: nil))
            return CGPoint(x: cocoa.x, y: bounds.height - cocoa.y)
        }

        let oldWidth = left.frame.width
        let divider = point(CGPoint(x: left.frame.maxX + split.dividerThickness / 2, y: 160), in: split)
        try await injectDrag(from: divider, to: CGPoint(x: divider.x + 60, y: divider.y), bounds: bounds)
        XCTAssertGreaterThan(left.frame.width, oldWidth + 40, "真实侧栏分隔线应跟随拖动改变宽度")

        let cell = try XCTUnwrap(slider.cell as? NSSliderCell)
        let knob = cell.knobRect(flipped: slider.isFlipped)
        let knobPoint = point(CGPoint(x: knob.midX, y: knob.midY), in: slider)
        try await injectDrag(from: knobPoint, to: CGPoint(x: knobPoint.x + 80, y: knobPoint.y),
            bounds: bounds, relative: true)
        XCTAssertGreaterThan(slider.doubleValue, 0.5, "真实滑块应识别按住状态下的相对移动")

        let textStart = point(CGPoint(x: 8, y: 10), in: text)
        try await injectDrag(from: textStart, to: CGPoint(x: textStart.x + 160, y: textStart.y), bounds: bounds)
        XCTAssertGreaterThan(text.selectedRange().length, 3, "原生文字应可按住并拖选")
    }

    @MainActor
    func testNativeSidebarItemsCanBeReorderedByDragging() async throws {
        _ = try XCTUnwrap(AXIsProcessTrusted() ? true : nil, "侧栏排序验证需要已有辅助功能授权")
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let window = NSWindow(contentRect: CGRect(x: screen.visibleFrame.midX - 150,
            y: screen.visibleFrame.midY - 150, width: 300, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "侧栏排序自动验证"
        window.level = .floating
        window.isReleasedWhenClosed = false
        let source = NativeSidebarDataSource()
        let outline = NSOutlineView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("项目"))
        column.width = 280
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 36
        outline.dataSource = source
        outline.delegate = source
        outline.registerForDraggedTypes([NativeSidebarDataSource.type])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        window.contentView = outline
        outline.reloadData()
        let originalPointer = CGEvent(source: nil)?.location
        defer {
            window.close()
            if let originalPointer {
                CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                    mouseCursorPosition: originalPointer, mouseButton: .left)?.post(tap: .cghidEventTap)
            }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        try await Task.sleep(for: .milliseconds(350))
        let bounds = CGDisplayBounds(CGMainDisplayID())
        func point(_ local: CGPoint) -> CGPoint {
            let cocoa = window.convertPoint(toScreen: outline.convert(local, to: nil))
            return CGPoint(x: cocoa.x, y: bounds.height - cocoa.y)
        }
        let start = point(CGPoint(x: 90, y: outline.rect(ofRow: 0).midY))
        let end = point(CGPoint(x: 90, y: outline.rect(ofRow: 2).maxY))
        try await injectDrag(from: start, to: end, bounds: bounds)
        XCTAssertEqual(source.acceptedDrops, 1, "侧栏应收到真实的拖放操作")
        XCTAssertEqual(source.items.map { $0 as String }, ["第二项", "第三项", "第一项", "第四项"])
    }

    @MainActor
    private func injectDrag(from start: CGPoint, to end: CGPoint, bounds: CGRect, relative: Bool = false) async throws {
        let id = UUID()
        func touch(_ phase: RemoteTouchPhase, at point: CGPoint) throws -> [CGEvent] {
            try MacTouchEventFactory.events(for: RemoteTouchInput(phase: phase,
                x: (point.x - bounds.minX) / bounds.width, y: (point.y - bounds.minY) / bounds.height,
                gestureID: id), bounds: bounds)
        }
        var events = try touch(.dragBegan, at: start)
        var pressed = RemoteButtonState()
        pressed.record(.left, pressed: true)
        var previous = start
        for step in 1...8 {
            let point = CGPoint(x: start.x + (end.x - start.x) * Double(step) / 8,
                                y: start.y + (end.y - start.y) * Double(step) / 8)
            if relative {
                events.append(try XCTUnwrap(MacPointerEventFactory.movement(from: previous,
                    deltaX: point.x - previous.x, deltaY: point.y - previous.y, buttons: pressed)))
            } else {
                events += try touch(.dragMoved, at: point)
            }
            previous = point
        }
        events += try touch(.dragEnded, at: end)
        let finished = expectation(description: "原生控件拖动事件已发送")
        let batch = NativeDragEventBatch(events: events)
        DispatchQueue.global(qos: .userInteractive).async {
            // AppKit 控件可能在鼠标按下时进入跟踪循环，独立队列保证松开事件仍能送达。
            for event in batch.events {
                event.post(tap: .cghidEventTap)
                Thread.sleep(forTimeInterval: 0.04)
            }
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 5)
        try await Task.sleep(for: .milliseconds(200))
    }
}

private struct NativeDragEventBatch: @unchecked Sendable {
    let events: [CGEvent]
}

@MainActor
private final class NativeSidebarDataSource: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    static let type = NSPasteboard.PasteboardType("com.yingchui.tests.sidebar")
    var items: [NSString] = ["第一项", "第二项", "第三项", "第四项"]
    var acceptedDrops = 0
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { item == nil ? items.count : 0 }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { false }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { items[index] }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        NSTextField(labelWithString: item as! String)
    }
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        let writer = NSPasteboardItem()
        writer.setString(item as! String, forType: Self.type)
        return writer
    }
    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        if let item { outlineView.setDropItem(nil, dropChildIndex: outlineView.row(forItem: item) + 1) }
        return .move
    }
    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo,
                     item: Any?, childIndex index: Int) -> Bool {
        guard item == nil, index >= 0, index <= items.count,
              let value = info.draggingPasteboard.string(forType: Self.type),
              let oldIndex = items.firstIndex(of: value as NSString) else { return false }
        let moved = items.remove(at: oldIndex)
        items.insert(moved, at: index > oldIndex ? index - 1 : index)
        acceptedDrops += 1
        outlineView.reloadData()
        return true
    }
}
