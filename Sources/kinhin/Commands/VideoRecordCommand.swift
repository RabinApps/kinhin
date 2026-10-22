import Foundation
import KinhinKit

/// `kinhin video record <app or title> | --window ID | --list-windows`: a clip of one window, with the pointer left out, for a
/// video's `app` scene. The capture is in KinhinKit (`Video/WindowRecorder.swift`); this file is flags and output.
enum VideoRecordCommand {
    private static let valueFlags: Set<String> = ["--seconds", "--out", "--window", "--pointer"]
    static let defaultSeconds = 10.0
    static let maximumSeconds = 600.0

    static func run(_ rest: [String]) async throws {
        do {
            if hasFlag("--list-windows", in: rest) {
                for window in try await WindowRecorder.windows() {
                    print("\(window.id)\t\(window.width)x\(window.height)\t\(window.label)")
                }
                return
            }
            let seconds = try number("--seconds", in: rest) ?? defaultSeconds
            guard seconds > 0, seconds <= maximumSeconds else {
                throw CLIError("--seconds takes a number from 1 to \(Int(maximumSeconds))", exit: .usage)
            }
            let windows = try await WindowRecorder.windows()
            let target = try chooseWindow(rest, from: windows)
            let out = URL(fileURLWithPath: flag("--out", in: rest) ?? "\(fileStem(target.app)).mov")
            let json = hasFlag("--json", in: rest)
            if !json { print("recording \(target.label) for \(Int(seconds)) s…") }
            let pointer = flag("--pointer", in: rest).map { URL(fileURLWithPath: $0) }
            // The log is written after the movie, so the same path would overwrite the movie with JSON.
            if let pointer, pointer.standardizedFileURL == out.standardizedFileURL {
                throw CLIError("--pointer and --out must be different files", exit: .usage)
            }
            let recording = try await WindowRecorder.record(target, seconds: seconds, to: out, pointer: pointer)
            if json {
                try printJSON(recording)
            } else {
                print("wrote \(recording.url.path): \(recording.width)x\(recording.height), \(recording.frames) frames")
            }
        } catch let error as WindowRecorderError {
            // Naming the wrong window is a usage problem; a missing grant or a failed capture is a runtime one.
            switch error {
            case .noWindow, .ambiguous, .noWindowWithID:
                throw CLIError(error.localizedDescription, exit: .usage)
            case .permissionMissing, .noFrames, .writeFailed:
                throw CLIError(error.localizedDescription, exit: .runtime)
            }
        }
    }

    /// The recording as JSON, with `firstFrameAt` as Unix seconds (null when no picture came), for scripts that line the
    /// clip up with an event.
    static func printJSON(_ recording: WindowRecording) throws {
        let object: [String: Any] = [
            "path": recording.url.path,
            "width": recording.width,
            "height": recording.height,
            "frames": recording.frames,
            "seconds": recording.seconds,
            "firstFrameAt": recording.firstFrameAt?.timeIntervalSince1970 ?? NSNull(),
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    /// `--window ID` when given, else the window the operand names.
    static func chooseWindow(_ rest: [String], from windows: [RecordableWindow]) throws -> RecordableWindow {
        if let text = flag("--window", in: rest) {
            guard let id = UInt32(text), let window = windows.first(where: { $0.id == id }) else {
                throw WindowRecorderError.noWindowWithID(UInt32(text) ?? 0)
            }
            return window
        }
        guard let query = operand(in: rest) else {
            throw CLIError(
                "kinhin video record takes an app or window title, or --window ID (try --list-windows)", exit: .usage)
        }
        return try WindowRecorder.find(query, in: windows)
    }

    /// The first operand that is neither a flag nor a flag's value.
    static func operand(in args: [String]) -> String? {
        var skipNext = false
        for arg in args {
            if skipNext {
                skipNext = false
            } else if valueFlags.contains(arg) {
                skipNext = true
            } else if !arg.hasPrefix("-") {
                return arg
            }
        }
        return nil
    }

    static func number(_ name: String, in rest: [String]) throws -> Double? {
        guard let text = flag(name, in: rest) else { return nil }
        guard let value = Double(text) else { throw CLIError("\(name) takes a number of seconds", exit: .usage) }
        return value
    }

    /// The app name as a file name: `kinhin-app` becomes `kinhin-app`, `Apple Notes` becomes `Apple-Notes`.
    static func fileStem(_ app: String) -> String {
        let cleaned = app.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? String($0) : "-" }.joined()
        return cleaned.isEmpty ? "recording" : cleaned
    }
}
