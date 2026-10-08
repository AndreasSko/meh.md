import Foundation
import ObjectiveC
import XCTest

/// Test-runner-only native event synthesis. A single pointer remains down
/// through every folder dwell; these runtime APIs never enter the app target.
@MainActor
enum NotebookContinuousDrag {
    static func perform(
        from source: CGPoint, hoveringOver folders: [CGPoint],
        to destination: CGPoint, hoverDuration: TimeInterval = 1.2
    ) throws {
        let pathClass = try runtimeClass("XCPointerEventPath")
        let recordClass = try runtimeClass("XCSynthesizedEventRecord")
        let path: AnyObject
        #if os(macOS)
        let initializer = NSSelectorFromString("initForMouseEventsAtLocation:")
        typealias InitializeMouse = @convention(c)
            (AnyObject, Selector, CGPoint) -> Unmanaged<AnyObject>
        let initialize = unsafeBitCast(
            try implementation(pathClass, initializer, encoding: "@32@0:8{CGPoint=dd}16"),
            to: InitializeMouse.self
        )
        path = initialize(try allocate(pathClass), initializer, source).takeRetainedValue()
        // Mouse presses read the last event's coordinate, so seed that
        // event before holding the button at the source row.
        let positionSelector = NSSelectorFromString("moveMouseToPoint:atOffset:duration:")
        typealias PositionMouse = @convention(c)
            (AnyObject, Selector, CGPoint, Double, Double) -> Void
        let positionMouse = unsafeBitCast(
            try implementation(pathClass, positionSelector, encoding: "v48@0:8{CGPoint=dd}16d32d40"),
            to: PositionMouse.self
        )
        positionMouse(path, positionSelector, source, 0, 0.1)
        try button(path, selector: "pressButton:atOffset:clickCount:", offset: 0.25)
        #else
        let initializer = NSSelectorFromString("initForTouchAtPoint:offset:")
        typealias InitializeTouch = @convention(c)
            (AnyObject, Selector, CGPoint, Double) -> Unmanaged<AnyObject>
        let initialize = unsafeBitCast(
            try implementation(pathClass, initializer, encoding: "@40@0:8{CGPoint=dd}16d32"),
            to: InitializeTouch.self
        )
        path = initialize(try allocate(pathClass), initializer, source, 0).takeRetainedValue()
        #endif

        var offset = 0.6
        try move(path, to: source, at: offset)
        for (index, folder) in folders.enumerated() {
            // Start moving promptly after the lift dwell, matching the
            // native public drag API rather than opening a context menu.
            offset += index == 0 ? 0.2 : 0.6
            try move(path, to: folder, at: offset)
            offset += hoverDuration
            try move(path, to: folder, at: offset)
        }
        offset += 0.3
        try move(path, to: destination, at: offset)
        offset += 0.2
        #if os(macOS)
        try button(path, selector: "releaseButton:atOffset:clickCount:", offset: offset)
        #else
        let liftSelector = NSSelectorFromString("liftUpAtOffset:")
        typealias Lift = @convention(c) (AnyObject, Selector, Double) -> Void
        let lift = unsafeBitCast(
            try implementation(pathClass, liftSelector, encoding: "v24@0:8d16"),
            to: Lift.self
        )
        lift(path, liftSelector, offset)
        #endif

        let recordInitializer = NSSelectorFromString("initWithName:interfaceOrientation:")
        typealias InitializeRecord = @convention(c)
            (AnyObject, Selector, NSString, Int64) -> Unmanaged<AnyObject>
        let initializeRecord = unsafeBitCast(
            try implementation(recordClass, recordInitializer, encoding: "@32@0:8@16q24"),
            to: InitializeRecord.self
        )
        // Mac event archives use 0; the portrait iOS fixture uses 1.
        #if os(macOS)
        let orientation: Int64 = 0
        #else
        let orientation: Int64 = 1
        #endif
        let record = initializeRecord(
            try allocate(recordClass), recordInitializer, "Notebook multihop drag", orientation
        ).takeRetainedValue()
        let addSelector = NSSelectorFromString("addPointerEventPath:")
        typealias AddPath = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        let add = unsafeBitCast(
            try implementation(recordClass, addSelector, encoding: "v24@0:8@16"),
            to: AddPath.self
        )
        add(record, addSelector, path)
        let data = try NSKeyedArchiver.archivedData(
            withRootObject: record, requiringSecureCoding: false
        )
        XCTContext.runActivity(named: "Continuous native drag event path") { activity in
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "com.apple.binary-property-list")
            attachment.name = "Continuous drag pointer events"
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
        try synthesize(record, timeout: offset + 15)
    }

    private static func runtimeClass(_ name: String) throws -> NSObject.Type {
        guard let type = NSClassFromString(name) as? NSObject.Type else {
            throw XCTSkip("Continuous drag runtime class unavailable: \(name)")
        }
        return type
    }

    private static func allocate(_ type: NSObject.Type) throws -> AnyObject {
        guard let object = type.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue()
        else { throw XCTSkip("Continuous drag runtime allocation unavailable") }
        return object
    }

    private static func implementation(
        _ type: AnyClass, _ selector: Selector, encoding: String
    ) throws -> IMP {
        guard let method = class_getInstanceMethod(type, selector),
              let types = method_getTypeEncoding(method),
              String(cString: types) == encoding else {
            throw XCTSkip("Continuous drag runtime signature unavailable: \(selector)")
        }
        return method_getImplementation(method)
    }

    private static func move(_ path: AnyObject, to point: CGPoint, at offset: Double) throws {
        #if os(macOS)
        let selector = NSSelectorFromString("dragWithButton:toPoint:atOffset:duration:")
        typealias MoveMouse = @convention(c)
            (AnyObject, Selector, UInt64, CGPoint, Double, Double) -> Void
        let move = unsafeBitCast(
            try implementation(type(of: path), selector, encoding: "v56@0:8Q16{CGPoint=dd}24d40d48"),
            to: MoveMouse.self
        )
        // Mouse paths describe a movement interval; touch paths describe
        // its endpoint. Finish this interval at the existing dwell offset.
        move(path, selector, 1, point, offset - 0.1, 0.1)
        #else
        let selector = NSSelectorFromString("moveToPoint:atOffset:")
        typealias Move = @convention(c) (AnyObject, Selector, CGPoint, Double) -> Void
        let move = unsafeBitCast(
            try implementation(type(of: path), selector, encoding: "v40@0:8{CGPoint=dd}16d32"),
            to: Move.self
        )
        move(path, selector, point, offset)
        #endif
    }

    #if os(macOS)
    private static func button(_ path: AnyObject, selector name: String, offset: Double) throws {
        let selector = NSSelectorFromString(name)
        typealias Button = @convention(c)
            (AnyObject, Selector, UInt64, Double, UInt64) -> Void
        let button = unsafeBitCast(
            try implementation(type(of: path), selector, encoding: "v40@0:8Q16d24Q32"),
            to: Button.self
        )
        // XCTest uses 1 for the left mouse button in its event archive.
        button(path, selector, 1, offset, 1)
    }
    #endif

    private static func synthesize(_ record: AnyObject, timeout: Double) throws {
        let device = XCUIDevice.shared
        let getter = NSSelectorFromString("eventSynthesizer")
        guard device.responds(to: getter),
              let synthesizer = device.perform(getter)?.takeUnretainedValue() else {
            throw XCTSkip("Continuous native drag synthesizer unavailable")
        }
        let selector = NSSelectorFromString("synthesizeEvent:completion:")
        typealias Completion = @convention(block) (Bool, NSError?) -> Void
        typealias Synthesize = @convention(c)
            (AnyObject, Selector, AnyObject, @escaping Completion) -> AnyObject?
        let synthesize = unsafeBitCast(
            try implementation(type(of: synthesizer), selector, encoding: "@32@0:8@16@?24"),
            to: Synthesize.self
        )
        let result = SynthesisResult()
        let completion = XCTestExpectation(description: "Continuous native drag completed")
        _ = synthesize(synthesizer, selector, record) { success, error in
            result.finish(success: success, error: error)
            completion.fulfill()
        }
        guard XCTWaiter.wait(for: [completion], timeout: timeout) == .completed else {
            throw SynthesisFailure("Continuous native drag synthesis timed out")
        }
        if let error = result.error { throw error }
        guard result.success else { throw SynthesisFailure("Native drag synthesis failed") }
    }

    private struct SynthesisFailure: LocalizedError {
        let errorDescription: String?
        init(_ description: String) { errorDescription = description }
    }

    private final class SynthesisResult: @unchecked Sendable {
        private let lock = NSLock()
        private var succeeded = false
        private var failure: NSError?
        var success: Bool { lock.withLock { succeeded } }
        var error: NSError? { lock.withLock { failure } }
        func finish(success: Bool, error: NSError?) {
            lock.withLock { succeeded = success; failure = error }
        }
    }
}
