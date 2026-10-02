import Foundation

/// Rebuilds a runtime's configured base image from config.yaml alone: the
/// macOS runner VM (base image, provision script) or a Linux image
/// rebuilt on top of the already-baked one when it exists. The app's
/// Prepare/Rebuild buttons and the setup checklist all go through here, so
/// no entry point drops a configured key. (`kinhin image prepare` adds its
/// own flag overrides on top of the same preparers.)
public enum ImageBuildService {
    public static func rebuild(_ runtime: RuntimeID, config cfg: KinhinConfig, shell: ShellRunning = Shell())
        async throws
    {
        switch runtime {
        case .tart:
            let tart = try TartController(configuredPath: cfg.tartPath)
            try await ImagePreparer(tart: tart, ssh: SSHExecutor()).run(ImagePreparer.Options(config: cfg))
            // Derived project images were cloned from the base just replaced.
            await ProjectImageService.invalidateAll(tart: tart)
        case .appleContainer:
            guard let container = cfg.container else { throw ImageError.notConfigured(section: "container") }
            try await AppleContainerRuntime.startSystem(shell: shell)
            let base = LinuxImageOptions.baseImage(
                configured: container.image, localImages: await AppleContainerRuntime(shell: shell).localImageNames(),
                fallback: LinuxBaseImage.resolve(configured: container.baseImage))
            let options = ContainerImagePreparer.Options(image: base, target: container.image)
            try await ContainerImagePreparer(shell: shell).prepare(options)
        case .docker:
            guard let docker = cfg.docker else { throw ImageError.notConfigured(section: "docker") }
            let base = LinuxImageOptions.baseImage(
                configured: docker.image,
                localImages: await DockerRuntime(shell: shell, image: docker.image).localImageNames(
                    reusing: docker.image, for: docker.platform),
                fallback: LinuxBaseImage.resolve(configured: docker.baseImage))
            var options = DockerImagePreparer.Options(image: base, target: docker.image)
            options.platform = docker.platform
            try await DockerImagePreparer(shell: shell).prepare(options)
        case .host:
            break  // host runners use the Mac itself: nothing to build
        }
    }
}
