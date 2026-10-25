import CoreGraphics
import Foundation

/// Where the pointer was while a window was recorded, and where it clicked. The clip never shows the pointer; this log is
/// the only trace of it, and a video scene's `autoZoom` turns its clicks into camera moves. Positions are 0 to 1 across the
/// window, and times are seconds from the window's first picture, so they line up with the clip the way `demoStartsAt` does.
public struct PointerLog: Codable, Equatable, Sendable {
    /// One reading of the pointer while it was over the window.
    public struct Sample: Codable, Equatable, Sendable {
        public let t: Double
        public let x: Double
        public let y: Double
    }

    /// A press of the left button while the pointer was over the window.
    public struct Click: Codable, Equatable, Sendable {
        public let t: Double
        public let x: Double
        public let y: Double
    }

    public var samples: [Sample]
    public var clicks: [Click]

    public init(samples: [Sample], clicks: [Click]) {
        self.samples = samples
        self.clicks = clicks
    }

    /// Writes the log as JSON (sorted keys, so the file is the same for the same take).
    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// Collects pointer readings while a window is recorded. Readings are Unix times and global screen points (top-left origin,
/// as ScreenCaptureKit reports a window's frame); `finish` turns them into a `PointerLog` on the window's own terms.
public struct PointerLogBuilder: Sendable {
    private let window: CGRect
    private var samples: [(at: Double, x: Double, y: Double)] = []
    private var clicks: [(at: Double, x: Double, y: Double)] = []
    private var leftWasDown = false

    public init(window: CGRect) {
        self.window = window
    }

    /// Adds one reading. A click is a press: the button going from up to down while the pointer is over the window.
    public mutating func add(at time: Double, point: CGPoint, leftDown: Bool) {
        let pressed = leftDown && !leftWasDown
        leftWasDown = leftDown
        guard let inside = Self.normalized(point, in: window) else { return }
        samples.append((time, inside.x, inside.y))
        if pressed { clicks.append((time, inside.x, inside.y)) }
    }

    /// The log with its times counted from `origin` (the first picture). Readings from before it are dropped.
    public func finish(from origin: Double) -> PointerLog {
        PointerLog(
            samples: samples.filter { $0.at >= origin }.map {
                PointerLog.Sample(t: rounded($0.at - origin), x: $0.x, y: $0.y)
            },
            clicks: clicks.filter { $0.at >= origin }.map {
                PointerLog.Click(t: rounded($0.at - origin), x: $0.x, y: $0.y)
            })
    }

    /// The point as 0 to 1 across `frame`, or nil when it is outside the frame.
    public static func normalized(_ point: CGPoint, in frame: CGRect) -> CGPoint? {
        guard frame.width > 0, frame.height > 0 else { return nil }
        let x = (point.x - frame.minX) / frame.width
        let y = (point.y - frame.minY) / frame.height
        guard (0...1).contains(x), (0...1).contains(y) else { return nil }
        return CGPoint(x: x, y: y)
    }
}

/// Rounds to milliseconds, which is all a camera move can use.
private func rounded(_ seconds: Double) -> Double {
    (seconds * 1000).rounded() / 1000
}
