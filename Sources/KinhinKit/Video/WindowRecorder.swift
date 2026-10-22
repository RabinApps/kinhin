import AVFoundation
import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import Synchronization

/// A window `kinhin video record` can capture.
public struct RecordableWindow: Equatable, Sendable {
    public let id: UInt32
    /// The owning app's name, as the window list shows it.
    public let app: String
    public let title: String
    /// Size in points.
    public let width: Int
    public let height: Int

    public init(id: UInt32, app: String, title: String, width: Int, height: Int) {
        self.id = id
        self.app = app
        self.title = title
        self.width = width
        self.height = height
    }

    /// `App — Title`, or just the app when the window has no title.
    public var label: String { title.isEmpty ? app : "\(app) — \(title)" }
}

/// What a finished recording contains.
public struct WindowRecording: Equatable, Sendable {
    public let url: URL
    public let width: Int
    public let height: Int
    public let frames: Int
    public let seconds: Double
    /// When the first picture arrived (wall clock). A recording that wants to line up with an event that started at a known
    /// time subtracts this from that time, instead of guessing the recorder's start-up delay.
    public let firstFrameAt: Date?
}

public enum WindowRecorderError: LocalizedError, Equatable {
    case permissionMissing
    case noWindow(query: String, available: [String])
    case ambiguous(query: String, matches: [String])
    case noWindowWithID(UInt32)
    case noFrames(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .permissionMissing:
            return "kinhin needs Screen Recording permission. Turn it on for the app that runs this command (Terminal, "
                + "iTerm or kinhin) in System Settings → Privacy & Security → Screen Recording, then run it again."
        case let .noWindow(query, available):
            // Duplicates (one app, many windows) and very long lists are cut to the first twelve distinct windows.
            var seen = Set<String>()
            let distinct = available.filter { seen.insert($0).inserted }
            let shown = distinct.prefix(12)
            var list =
                shown.isEmpty ? "No windows are on screen." : "Windows on screen:\n  " + shown.joined(separator: "\n  ")
            if distinct.count > shown.count { list += "\n  …and \(distinct.count - shown.count) more" }
            return "No window matches \"\(query)\". \(list)"
        case let .ambiguous(query, matches):
            return
                "\"\(query)\" matches more than one app: \(matches.joined(separator: ", ")). Use a longer name, or --window ID."
        case let .noWindowWithID(id):
            return "No window has id \(id). Run `kinhin video record --list-windows` to see the ids."
        case let .noFrames(label):
            return "No frames came from \(label). Is the window open and not minimized?"
        case let .writeFailed(reason):
            return "Writing the recording failed: \(reason)"
        }
    }
}

/// Records one window with ScreenCaptureKit, with the mouse pointer left out. `screencapture` and ffmpeg's
/// avfoundation input both draw the pointer into the frames on current macOS, so the video tools use this instead.
public enum WindowRecorder {
    /// Every normal window on this Mac that can be captured, largest first.
    public static func windows() async throws -> [RecordableWindow] {
        let content = try await shareableContent()
        return content.windows
            .filter { $0.windowLayer == 0 && $0.frame.width > 0 && $0.frame.height > 0 }
            .compactMap { window -> RecordableWindow? in
                guard let app = window.owningApplication?.applicationName, !app.isEmpty else { return nil }
                return RecordableWindow(
                    id: window.windowID, app: app, title: window.title ?? "",
                    width: Int(window.frame.width), height: Int(window.frame.height))
            }
            .sorted { $0.width * $0.height > $1.width * $1.height }
    }

    /// Picks the window a query names. A query matches an app name exactly, then an app name that contains it, then a
    /// window title that contains it. Several windows of one app resolve to its largest; windows of different apps are
    /// an error, so a recording never starts on the wrong app.
    public static func find(_ query: String, in windows: [RecordableWindow]) throws -> RecordableWindow {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let available = windows.map(\.label)
        let tiers: [(RecordableWindow) -> Bool] = [
            { $0.app.lowercased() == needle },
            { $0.app.lowercased().contains(needle) },
            { $0.title.lowercased().contains(needle) },
        ]
        for matches in tiers {
            let found = windows.filter(matches)
            guard !found.isEmpty else { continue }
            let apps = Set(found.map(\.app))
            guard apps.count == 1, let largest = found.max(by: { $0.width * $0.height < $1.width * $1.height }) else {
                throw WindowRecorderError.ambiguous(query: query, matches: apps.sorted())
            }
            return largest
        }
        throw WindowRecorderError.noWindow(query: query, available: available)
    }

    /// Records `window` for `seconds` into `url` (an existing file is replaced). Records the window's own pixels only, so
    /// anything over it, and the pointer, stay out of the clip. With `pointer`, also writes a `PointerLog` there: where the
    /// pointer was over the window and where it clicked, which is how the pointer still shapes the video (`autoZoom`).
    public static func record(
        _ window: RecordableWindow, seconds: Double, to url: URL, pointer: URL? = nil
    ) async throws -> WindowRecording {
        let content = try await shareableContent()
        guard let target = content.windows.first(where: { $0.windowID == window.id }) else {
            throw WindowRecorderError.noWindowWithID(window.id)
        }
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let scale = CGFloat(filter.pointPixelScale)
        // H.264 needs even dimensions.
        let width = Int(target.frame.width * scale) & ~1
        let height = Int(target.frame.height * scale) & ~1

        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.showsCursor = false
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 6

        // Replacing an old recording: a file that is not there yet is the case this is for, so the error is ignored.
        try? FileManager.default.removeItem(at: url)
        let writer = try FrameWriter(url: url, width: width, height: height)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: writer)
        // A nil queue lets ScreenCaptureKit deliver frames on its own background queue.
        try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: nil)
        let frame = target.frame
        let sampling: Task<PointerLogBuilder, Never>? = pointer == nil ? nil : Task { await samplePointer(over: frame) }
        defer { sampling?.cancel() }
        try await stream.startCapture()
        try await Task.sleep(for: .seconds(seconds))
        try await stream.stopCapture()
        try await writer.finish()
        sampling?.cancel()

        guard writer.frameCount > 0 else { throw WindowRecorderError.noFrames(window.label) }
        if let pointer, let sampling, let origin = writer.firstFrameAt {
            try await sampling.value.finish(from: origin.timeIntervalSince1970).write(to: pointer)
        }
        return WindowRecording(
            url: url, width: width, height: height, frames: writer.frameCount, seconds: seconds,
            firstFrameAt: writer.firstFrameAt)
    }

    // MARK: private

    /// Reads the pointer's position and left button about 30 times a second until cancelled. Both are readable without a
    /// permission grant, and the pointer is never drawn into the picture, so this costs the clip nothing.
    private static func samplePointer(over frame: CGRect) async -> PointerLogBuilder {
        var builder = PointerLogBuilder(window: frame)
        while !Task.isCancelled {
            let point = CGEvent(source: nil)?.location ?? .zero
            let down = CGEventSource.buttonState(.combinedSessionState, button: .left)
            builder.add(at: Date().timeIntervalSince1970, point: point, leftDown: down)
            // A cancelled sleep throws; the loop then ends on its own check, so the error is not needed.
            try? await Task.sleep(for: .milliseconds(33))
        }
        return builder
    }

    /// Starts the window server connection a command-line process needs before ScreenCaptureKit works.
    @MainActor
    private static func connect() {
        _ = NSApplication.shared
    }

    private static func shareableContent() async throws -> SCShareableContent {
        await connect()
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            if !CGPreflightScreenCaptureAccess() { throw WindowRecorderError.permissionMissing }
            throw error
        }
    }
}

/// Writes ScreenCaptureKit frames to an H.264 .mov. The stream calls it on one serial queue.
private final class FrameWriter: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private var started = false
    private(set) var frameCount = 0
    private let firstFrame = Mutex<Date?>(nil)

    var firstFrameAt: Date? { firstFrame.withLock { $0 } }

    init(url: URL, width: Int, height: Int) throws {
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        } catch {
            throw WindowRecorderError.writeFailed(error.localizedDescription)
        }
        input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        // ScreenCaptureKit also sends status-only buffers with no picture; only complete frames are written.
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
            let status = attachments.first?[.status] as? Int,
            status == SCFrameStatus.complete.rawValue
        else { return }
        if !started {
            guard writer.startWriting() else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startSession(atSourceTime: pts)
            started = true
            firstFrame.withLock { $0 = Self.captureTime(of: pts) }
        }
        if input.isReadyForMoreMediaData, input.append(sampleBuffer) { frameCount += 1 }
    }

    /// When a frame was captured, as wall-clock time. The presentation time is on the host clock, which is when the
    /// frame was captured; the callback runs later, after ScreenCaptureKit has queued and delivered it.
    private static func captureTime(of presentation: CMTime) -> Date {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let age = CMTimeSubtract(now, presentation).seconds
        return Date().addingTimeInterval(-age)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // The recording ends with the frames written so far; the caller sees a short or empty file, not this error.
    }

    func finish() async throws {
        // No picture arrived (a minimised or empty window): the writer never started, and marking its input finished would
        // raise an Objective-C exception. The caller reports that no frames came.
        guard started else { return }
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        if writer.status == .failed {
            throw WindowRecorderError.writeFailed(writer.error?.localizedDescription ?? "unknown error")
        }
    }
}
