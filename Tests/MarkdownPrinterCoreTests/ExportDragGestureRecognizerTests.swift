import AppKit
import XCTest
@testable import MarkdownPrinterUI

@MainActor
final class ExportDragGestureRecognizerTests: XCTestCase {
    func testHoldRecognizesInTrackingModeAndRetainsEachMouseEvent() throws {
        let recognizer = ExportDragGestureRecognizer(target: nil, action: nil)
        recognizer.minimumPressDuration = 0.01
        var states: [NSGestureRecognizer.State] = []
        recognizer.onStateChanged = { _, state in states.append(state) }
        let down = event(.leftMouseDown, at: .zero)
        recognizer.mouseDown(with: down)
        XCTAssertTrue(states.isEmpty)
        runTrackingLoop()
        XCTAssertEqual(states, [.began])
        XCTAssertTrue(recognizer.mouseEvent === down)
        let drag = event(.leftMouseDragged, at: NSPoint(x: 300, y: 400))
        recognizer.mouseDragged(with: drag)
        XCTAssertEqual(states, [.began, .changed])
        XCTAssertTrue(recognizer.mouseEvent === drag)
        XCTAssertEqual(recognizer.location(in: nil), drag.locationInWindow)
        let up = event(.leftMouseUp, at: drag.locationInWindow)
        recognizer.mouseUp(with: up)
        XCTAssertEqual(states, [.began, .changed, .ended])
        XCTAssertTrue(recognizer.mouseEvent === up)
        recognizer.reset()
        XCTAssertNil(recognizer.mouseEvent)
        XCTAssertEqual(recognizer.location(in: nil), .zero)
        XCTAssertTrue(recognizer.delaysPrimaryMouseButtonEvents)
        XCTAssertFalse(recognizer.canBePrevented(by: NSClickGestureRecognizer()))
    }

    func testQuickClickAndEarlySelectionMovementReleaseTheGestureWithoutExporting() {
        for movesEarly in [false, true] {
            let recognizer = ExportDragGestureRecognizer(target: nil, action: nil)
            recognizer.minimumPressDuration = 0.01
            recognizer.allowableMovement = 5
            var states: [NSGestureRecognizer.State] = []
            recognizer.onStateChanged = { _, state in states.append(state) }
            recognizer.mouseDown(with: event(.leftMouseDown, at: .zero))
            if movesEarly {
                recognizer.mouseDragged(with: event(.leftMouseDragged, at: NSPoint(x: 6, y: 0)))
                recognizer.mouseDragged(with: event(.leftMouseDragged, at: NSPoint(x: 7, y: 0)))
            }
            recognizer.mouseUp(with: event(.leftMouseUp, at: .zero))
            runTrackingLoop()
            XCTAssertEqual(states, [.failed])
            recognizer.reset()
        }
    }

    func testSmallMovementStillAllowsHoldAndResetCancelsPendingAndReadyPresses() {
        for finishesHold in [false, true] {
            let recognizer = ExportDragGestureRecognizer(target: nil, action: nil)
            recognizer.minimumPressDuration = 0.01
            recognizer.allowableMovement = 5
            var states: [NSGestureRecognizer.State] = []
            recognizer.onStateChanged = { _, state in states.append(state) }
            recognizer.mouseDown(with: event(.leftMouseDown, at: .zero))
            recognizer.mouseDragged(with: event(.leftMouseDragged, at: NSPoint(x: 3, y: 4)))
            if finishesHold { runTrackingLoop() }
            recognizer.reset()
            runTrackingLoop()
            recognizer.mouseDragged(with: event(.leftMouseDragged, at: NSPoint(x: 30, y: 40)))
            recognizer.mouseUp(with: event(.leftMouseUp, at: .zero))
            XCTAssertEqual(states, finishesHold ? [.began, .cancelled] : [.cancelled])
        }
    }

    func testRepeatedMouseDownReplacesThePendingTimerAndCodingRestoresEventDelay() throws {
        let recognizer = ExportDragGestureRecognizer(target: nil, action: nil)
        recognizer.minimumPressDuration = 0.01
        var states: [NSGestureRecognizer.State] = []
        recognizer.onStateChanged = { _, state in states.append(state) }
        recognizer.mouseDown(with: event(.leftMouseDown, at: .zero))
        recognizer.mouseDown(with: event(.leftMouseDown, at: NSPoint(x: 10, y: 20)))
        runTrackingLoop()
        XCTAssertEqual(states, [.began])
        recognizer.reset()
        let data = try NSKeyedArchiver.archivedData(withRootObject: recognizer, requiringSecureCoding: false)
        let restored = try XCTUnwrap(NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data) as? ExportDragGestureRecognizer)
        XCTAssertTrue(restored.delaysPrimaryMouseButtonEvents)
    }

    private func event(_ type: NSEvent.EventType, at location: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: location, modifierFlags: .option,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func runTrackingLoop() {
        let deadline = Date().addingTimeInterval(0.03)
        while Date() < deadline {
            RunLoop.main.run(mode: .eventTracking, before: deadline)
        }
    }
}
