import Foundation

// MARK: - Linux container sections (container:, docker:)

extension ConfigLoader {
    static func parseContainer(_ container: PartialConfig.PartialContainer) throws -> KinhinConfig.ContainerConfig {
        guard let containerImage = container.image, !containerImage.isEmpty else {
            throw ConfigError.invalid(
                "container.image must not be empty (a Linux OCI image baked with runner agents)")
        }
        try Self.requireSafeImageReference(containerImage, key: "container.image")
        if let cpus = container.cpus, cpus < 1 {
            throw ConfigError.invalid("container.cpus must be >= 1")
        }
        if let mem = container.memoryGB, mem < 2 {
            throw ConfigError.invalid("container.memory_gb must be >= 2")
        }
        if container.platform != nil {
            throw ConfigError.invalid(
                "container.platform is not supported: Apple container runs linux/arm64 only "
                    + "(docker.platform can select linux/amd64)")
        }
        let containerBase = try Self.validatedBaseImage(container.baseImage, key: "container.base_image")
        return KinhinConfig.ContainerConfig(
            image: containerImage,
            cpus: container.cpus ?? KinhinConfig.ContainerConfig.defaultCPUs,
            memoryGB: container.memoryGB ?? KinhinConfig.ContainerConfig.defaultMemoryGB,
            labels: container.labels,
            baseImage: containerBase,
            fleetLabels: container.fleetLabels
        )
    }

    static func parseDocker(_ docker: PartialConfig.PartialDocker) throws -> KinhinConfig.DockerForgeConfig {
        guard let dockerImage = docker.image, !dockerImage.isEmpty else {
            throw ConfigError.invalid("docker.image must not be empty (a Linux OCI image baked with runner agents)")
        }
        try Self.requireSafeImageReference(dockerImage, key: "docker.image")
        if let cpus = docker.cpus, cpus < 1 {
            throw ConfigError.invalid("docker.cpus must be >= 1")
        }
        if let mem = docker.memoryGB, mem < 1 {
            throw ConfigError.invalid("docker.memory_gb must be >= 1")
        }
        if let slots = docker.maxSlots, slots < 1 {
            throw ConfigError.invalid("docker.max_slots must be >= 1")
        }
        let dockerBase = try Self.validatedBaseImage(docker.baseImage, key: "docker.base_image")
        var dockerPlatform = LinuxPlatform.arm64
        if let raw = docker.platform {
            guard let parsed = LinuxPlatform(configValue: raw) else {
                throw ConfigError.invalid("docker.platform must be linux/arm64 or linux/amd64, got \"\(raw)\"")
            }
            dockerPlatform = parsed
        }
        return KinhinConfig.DockerForgeConfig(
            image: dockerImage,
            cpus: docker.cpus ?? KinhinConfig.DockerForgeConfig.defaultCPUs,
            memoryGB: docker.memoryGB ?? KinhinConfig.DockerForgeConfig.defaultMemoryGB,
            maxSlots: docker.maxSlots ?? KinhinConfig.DockerForgeConfig.defaultMaxSlots,
            baseImage: dockerBase,
            platform: dockerPlatform,
            fleetLabels: docker.fleetLabels
        )
    }

    /// An OCI image reference is passed to `docker run` / `container run` as a
    /// positional argument: a leading dash would be read as a flag, and whitespace
    /// or control characters never belong in a reference.
    static func requireSafeImageReference(_ image: String, key: String) throws {
        let safe = image.range(of: #"^[A-Za-z0-9][A-Za-z0-9._/:@+-]*\z"#, options: .regularExpression) != nil
        guard safe else {
            throw ConfigError.invalid(
                "\(key) '\(image)' is not a valid image reference (letters, digits and . _ / : @ + -; no leading dash)")
        }
    }
}
