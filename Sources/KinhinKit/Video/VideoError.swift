import Foundation

/// What can go wrong setting up or running a video build, in words that name the fix.
public enum VideoError: LocalizedError, Equatable {
    case invalidName(String)
    case alreadyExists(String)
    case noVideosFolder(String)
    case unknownProject(name: String, available: [String])
    case noRuntime
    case runtimeUnavailable(String)
    case imageUnavailable(image: String, reason: String)
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName(let name):
            return "\"\(name)\" is not a valid video name (use letters, digits, - and _, with / for folders)"
        case .alreadyExists(let path):
            return "\(path) already exists; kinhin will not overwrite it"
        case .noVideosFolder(let path):
            return "no \(VideoProjects.folder)/ in \(path). Run `kinhin video init` there to create one"
        case .unknownProject(let name, let available):
            let have =
                available.isEmpty ? "none yet (run `kinhin video init \(name)`)" : available.joined(separator: ", ")
            return "no video \"\(name)\" in \(VideoProjects.folder)/ (have: \(have))"
        case .noRuntime:
            return "videos build in a container, and neither Apple's `container` nor Docker is running. "
                + "Install one (brew install container && container system start, or Docker) and try again"
        case .runtimeUnavailable(let why):
            return why
        case .imageUnavailable(let image, let reason):
            return "could not get the video image \(image): \(reason). "
                + "Check your network, or build it from a kinhin checkout "
                + "(docker build -t kinhin-video:local video/) and pass --image kinhin-video:local"
        case .launchFailed(let why):
            return "could not start the build: \(why)"
        }
    }
}
