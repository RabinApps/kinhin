import Foundation

/// The container image that holds the video suite (Node, Chromium, ffmpeg, the voice model and the pipeline itself).
/// Published to the GitHub container registry for every release, so a user needs no copy of `video/`.
public enum VideoImage {
    public static let repository = "ghcr.io/rabinapps/kinhin-video"
    public static let overrideVariable = "KINHIN_VIDEO_IMAGE"

    /// The image to run: `override` (a `--image` flag), else `KINHIN_VIDEO_IMAGE`, else the image released with this kinhin.
    public static func reference(
        override: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment,
        version: String = kinhinVersion.current
    ) -> String {
        if let override, !override.isEmpty { return override }
        if let fromEnvironment = environment[overrideVariable], !fromEnvironment.isEmpty { return fromEnvironment }
        return "\(repository):\(version)"
    }
}
