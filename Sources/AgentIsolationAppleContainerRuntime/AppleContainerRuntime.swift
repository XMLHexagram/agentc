#if canImport(Containerization)
  import AgentIsolation
  import Containerization
  import ContainerizationArchive
  import ContainerizationExtras
  import ContainerizationOCI
  import ContainerizationOS
  import Foundation
  import Logging
  import System

  // MARK: - AppleContainerRuntime

  /// Container runtime that runs containers directly using Apple's Virtualization.framework
  /// via the `containerization` package — no XPC daemon required.
  public final class AppleContainerRuntime: ContainerRuntime, @unchecked Sendable {
    public typealias Image = AppleContainerImage
    public typealias Container = AppleContainerContainer

    private let storagePath: URL
    private var manager: ContainerManager?
    private var imageStore: ImageStore?

    private static var containerAppDataRoot: URL {
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first!
        .appendingPathComponent("com.apple.container")
    }

    public required init(config: ContainerRuntimeConfiguration) {
      self.storagePath = URL(fileURLWithPath: config.storagePath)
    }

    // MARK: - ContainerRuntime

    public func prepare() async throws {
      try FileManager.default.createDirectory(at: storagePath, withIntermediateDirectories: true)

      let kernel = try await getOrDownloadKernel()

      let imageStoreRoot = storagePath.appendingPathComponent("imagestore")
      let store = try ImageStore(path: imageStoreRoot)
      self.imageStore = store

      let network: Network?
      if #available(macOS 26.0, *) {
        network = try VmnetNetwork()
      } else {
        network = nil
      }

      self.manager = try await ContainerManager(
        kernel: kernel,
        initfsReference: "ghcr.io/apple/containerization/vminit:0.29.0",
        imageStore: store,
        network: network
      )
    }

    public func pullImage(ref: String) async throws -> AppleContainerImage? {
      try await pullImage(ref: ref, progress: nil)
    }

    /// Pull an image with optional progress callback.
    /// `progress` receives batched events (per-blob granularity, not byte-level) — see
    /// `Containerization.ProgressHandler`. Use this overload when the host wants to
    /// display download progress to a user.
    public func pullImage(
      ref: String,
      progress: ProgressHandler?
    ) async throws -> AppleContainerImage? {
      guard let store = imageStore else {
        throw AppleContainerRuntimeError.notPrepared
      }
      let resolvedRef = Self.normalizedDockerHubRef(ref)
      do {
        let image = try await store.pull(
          reference: resolvedRef,
          platform: .current,
          progress: progress
        )
        return AppleContainerImage(ref: ref, digest: image.digest)
      } catch {
        // Pull failure — image may not exist or network error
        return nil
      }
    }

    /// Direct access to the underlying ImageStore for management UIs (list / delete /
    /// inspect). Returns nil if `prepare()` hasn't been called yet.
    public func imageStoreRef() -> ImageStore? {
      imageStore
    }

    public func inspectImage(ref: String) async throws -> AppleContainerImage? {
      guard let store = imageStore else {
        throw AppleContainerRuntimeError.notPrepared
      }
      // Try the ref as given first (image may have been pulled with the full name)
      if let image = try? await store.get(reference: ref) {
        return AppleContainerImage(ref: ref, digest: image.digest)
      }
      // Fall back to the normalized Docker Hub reference for bare names
      let resolvedRef = Self.normalizedDockerHubRef(ref)
      if resolvedRef != ref, let image = try? await store.get(reference: resolvedRef) {
        return AppleContainerImage(ref: ref, digest: image.digest)
      }
      return nil
    }

    public func removeImage(ref: String) async throws {
      guard let store = imageStore else {
        throw AppleContainerRuntimeError.notPrepared
      }
      let resolvedRef = Self.normalizedDockerHubRef(ref)
      try await store.delete(reference: resolvedRef, performCleanup: true)
    }

    public func removeImage(digest: String) async throws {
      guard let store = imageStore else {
        throw AppleContainerRuntimeError.notPrepared
      }
      try await store.delete(reference: digest, performCleanup: true)
    }

    public func runContainer(
      imageRef: String,
      configuration: ContainerConfiguration
    ) async throws -> AppleContainerContainer {
      try await runContainer(
        imageRef: imageRef,
        configuration: configuration,
        progress: nil
      )
    }

    /// Stage-instrumented runContainer. Emits ``AgentStartStage`` events at the
    /// boundaries between manager.create / container.create / container.start so
    /// the host can render real progress instead of time-based heuristics.
    ///
    /// Uses a **rootfs template cache** keyed by image digest. The first container
    /// for a given image goes through the full unpack (~30-40s for a typical
    /// 280 MB / 14k file image) and saves the resulting `rootfs.ext4` as a template
    /// at `<storage>/rootfs-templates/<digest>.ext4`. Subsequent containers using
    /// the same image skip unpacking entirely — APFS `clonefile()` produces a
    /// copy-on-write rootfs in milliseconds.
    public func runContainer(
      imageRef: String,
      configuration: ContainerConfiguration,
      progress: AgentStartProgressHandler?
    ) async throws -> AppleContainerContainer {
      guard var manager, let imageStore else {
        throw AppleContainerRuntimeError.notPrepared
      }

      // Set up terminal before creating the container
      var terminal: Terminal? = nil
      switch configuration.io {
      case .currentTerminal:
        terminal = try? Terminal.current
        try terminal?.setraw()
      default:
        break
      }

      let containerID = UUID().uuidString.lowercased()
      let resolvedRef = Self.normalizedDockerHubRef(imageRef)

      await progress?(.creatingContainer)

      // Container configuration is identical across fast/slow paths — captured once
      // here and reused as the trailing closure to whichever manager.create overload
      // we end up calling.
      let configureContainer: (inout LinuxContainer.Configuration) throws -> Void = { containerConfig in
        containerConfig.cpus = configuration.cpuCount
        containerConfig.memoryInBytes = UInt64(configuration.memoryLimitMiB).mib()
        containerConfig.hosts = .default
        containerConfig.useInit = true

        if !configuration.entrypoint.isEmpty {
          containerConfig.process.arguments = configuration.entrypoint
        }
        if let workDir = configuration.workingDirectory {
          containerConfig.process.workingDirectory = workDir
        }
        for (key, value) in configuration.environment {
          containerConfig.process.environmentVariables.append("\(key)=\(value)")
        }
        for mount in configuration.mounts {
          containerConfig.mounts.append(
            .share(source: mount.hostPath, destination: mount.containerPath))
        }
        switch configuration.io {
        case .currentTerminal:
          if let t = terminal {
            containerConfig.process.setTerminalIO(terminal: t)
          }
        case .standardIO:
          containerConfig.process.stdin = FileDescriptorReader(.standardInput)
          containerConfig.process.stdout = FileDescriptorWriter(.standardOutput)
          containerConfig.process.stderr = FileDescriptorWriter(.standardError)
        case .custom(let stdin, let stdout, let stderr, let isTerminal):
          containerConfig.process.terminal = isTerminal
          containerConfig.process.stdin = ContainerizationReaderStream(stdin)
          containerConfig.process.stdout = ContainerizationWriter(stdout)
          // When terminal=true the PTY's master fd merges stdout and stderr —
          // Containerization rejects a separate stderr writer in that mode.
          if !isTerminal {
            containerConfig.process.stderr = ContainerizationWriter(stderr)
          }
        }
      }

      // Resolve image once so we can derive the digest for template caching.
      let image = try await imageStore.get(reference: resolvedRef)
      let templateURL = rootfsTemplateURL(storage: storagePath, digest: image.digest)
      let containerDir = imageStore.path
        .appendingPathComponent("containers")
        .appendingPathComponent(containerID)
      let rootfsURL = containerDir.appendingPathComponent("rootfs.ext4")

      let container: LinuxContainer
      if FileManager.default.fileExists(atPath: templateURL.path),
         (try? cloneRootfs(template: templateURL, container: rootfsURL)) != nil
      {
        // Fast path: clone the cached template (APFS CoW, ~ms) and use the
        // pre-built-rootfs overload of manager.create — no unpacking.
        let mount = Mount.block(
          format: "ext4",
          source: rootfsURL.absolutePath(),
          destination: "/",
          options: []
        )
        container = try await manager.create(
          containerID,
          image: image,
          rootfs: mount,
          configuration: configureContainer
        )
      } else {
        // Slow path: full unpack. After success, save the rootfs as a template
        // for next time. Translate Containerization's progress stream into our
        // AgentStartStage.unpackingRootfs aggregate (cumulative bytes + files).
        let unpackTracker = UnpackProgressTracker(forward: progress)
        let unpackProgress: ProgressHandler = { events in
          await unpackTracker.handle(events)
        }

        container = try await manager.create(
          containerID,
          reference: resolvedRef,
          rootfsSizeInBytes: UInt64(8).gib(),
          progress: unpackProgress,
          configuration: configureContainer
        )

        // Best-effort template save — failure here is non-fatal (next start will
        // simply unpack again).
        saveRootfsTemplate(from: rootfsURL, to: templateURL)
      }

      await progress?(.bootingVM)
      try await container.create()
      await progress?(.startingAgent)
      try await container.start()

      if let t = terminal {
        try? await container.resize(to: try t.size)
      }

      return AppleContainerContainer(
        id: containerID,
        container: container,
        manager: manager,
        terminal: terminal
      )
    }

    public func shutdown() async throws {
      manager = nil
      imageStore = nil
    }

    public func removeContainer(_ container: AppleContainerContainer) async throws {
      container.terminal?.tryReset()
      try await container.underlyingContainer.stop()
      try container.manager.delete(container.id)
    }

    // MARK: - Image Reference Normalization

    /// Normalizes a bare image reference to a fully qualified Docker Hub reference.
    /// e.g., "swift:6.3" → "docker.io/library/swift:6.3",
    ///       "user/repo:tag" → "docker.io/user/repo:tag".
    /// Already-qualified references (containing a registry domain) are returned as-is.
    static func normalizedDockerHubRef(_ ref: String) -> String {
      // Strip tag (@sha256:...) or tag (:tag) to isolate the name portion
      let name: String
      if let atIndex = ref.firstIndex(of: "@") {
        name = String(ref[..<atIndex])
      } else {
        name = ref
      }

      guard let slashIndex = name.firstIndex(of: "/") else {
        // No slash → bare name like "swift:6.3"
        return "docker.io/library/\(ref)"
      }

      let firstComponent = name[..<slashIndex]
      // A registry domain contains a dot, a colon (port), or is "localhost"
      if firstComponent.contains(".") || firstComponent.contains(":")
        || firstComponent == "localhost"
      {
        return ref
      }

      // Has a slash but no registry (e.g., "user/repo:tag")
      return "docker.io/\(ref)"
    }

    // MARK: - Kernel

    private func getOrDownloadKernel() async throws -> Kernel {
      // 1. Try the container app's installed kernel
      let appKernelLink =
        Self.containerAppDataRoot
        .appendingPathComponent("kernels")
        .appendingPathComponent("default.kernel-arm64")
      let appKernelResolved = appKernelLink.resolvingSymlinksInPath()
      if FileManager.default.fileExists(atPath: appKernelResolved.path) {
        return Kernel(path: appKernelResolved, platform: .linuxArm)
      }

      // 2. Try our own cached kernel
      let ourKernelDir = storagePath.appendingPathComponent("kernels")
      let ourKernelLink = ourKernelDir.appendingPathComponent("default.kernel-arm64")
      let ourKernelResolved = ourKernelLink.resolvingSymlinksInPath()
      if FileManager.default.fileExists(atPath: ourKernelResolved.path) {
        return Kernel(path: ourKernelResolved, platform: .linuxArm)
      }

      // 3. Download kernel from kata-containers
      fputs("agentc: downloading kernel (one-time setup)...\n", stderr)
      let tarURL = URL(
        string:
          "https://github.com/kata-containers/kata-containers/releases/download/3.26.0/kata-static-3.26.0-arm64.tar.zst"
      )!
      let kernelPathInArchive = "opt/kata/share/kata-containers/vmlinux-6.18.5-177"

      let (tempFile, _) = try await URLSession.shared.download(from: tarURL)
      defer { try? FileManager.default.removeItem(at: tempFile) }

      let archiveReader = try ArchiveReader(file: tempFile)
      let (_, kernelData) = try archiveReader.extractFile(path: kernelPathInArchive)

      try FileManager.default.createDirectory(at: ourKernelDir, withIntermediateDirectories: true)
      let kernelBinary = ourKernelDir.appendingPathComponent("vmlinux-6.18.5-177")
      try kernelData.write(to: kernelBinary, options: .atomic)

      try? FileManager.default.removeItem(at: ourKernelLink)
      try FileManager.default.createSymbolicLink(
        at: ourKernelLink, withDestinationURL: kernelBinary)

      return Kernel(path: kernelBinary, platform: .linuxArm)
    }
  }

  // MARK: - Associated Types

  public struct AppleContainerImage: ContainerRuntimeImage {
    public var ref: String
    public var digest: String

    public init(ref: String, digest: String) {
      self.ref = ref
      self.digest = digest
    }
  }

  public final class AppleContainerContainer: ContainerRuntimeContainer, @unchecked Sendable {
    public let id: String
    let underlyingContainer: LinuxContainer
    var manager: ContainerManager
    var terminal: Terminal?

    init(
      id: String,
      container: LinuxContainer,
      manager: ContainerManager,
      terminal: Terminal?
    ) {
      self.id = id
      self.underlyingContainer = container
      self.manager = manager
      self.terminal = terminal
    }

    public func wait(timeoutInSeconds: Int64?) async throws -> Int32 {
      let exitStatus: ExitStatus
      if let t = terminal {
        let sigwinchStream = AsyncSignalHandler.create(notify: [SIGWINCH])
        exitStatus = try await withThrowingTaskGroup(of: ExitStatus?.self) { group in
          group.addTask {
            for await _ in sigwinchStream.signals {
              try await self.underlyingContainer.resize(to: try t.size)
            }
            return nil
          }
          group.addTask { try await self.underlyingContainer.wait() }
          var result: ExitStatus? = nil
          for try await value in group {
            if let value {
              result = value
              group.cancelAll()
              break
            }
          }
          return result ?? ExitStatus(exitCode: 0)
        }
      } else {
        exitStatus = try await underlyingContainer.wait()
      }
      return exitStatus.exitCode
    }

    public func stop() async throws {
      terminal?.tryReset()
      try await underlyingContainer.stop()
    }

    public func resize(cols: Int, rows: Int) async throws {
      try await underlyingContainer.resize(
        to: ContainerizationOS.Terminal.Size(
          width: UInt16(cols), height: UInt16(rows)))
    }
  }

  // MARK: - Errors

  public enum AppleContainerRuntimeError: LocalizedError {
    case notPrepared

    public var errorDescription: String? {
      switch self {
      case .notPrepared:
        return "Container runtime has not been prepared. Call prepare() first."
      }
    }
  }

  // MARK: - Rootfs template cache

  /// Path of the cached rootfs template for an image digest. Each unique image
  /// content (by content-addressed digest) gets its own template; tags pointing to
  /// new content automatically miss the cache and trigger a fresh unpack-and-save.
  private func rootfsTemplateURL(storage: URL, digest: String) -> URL {
    // Replace `:` (sha256:abc...) for filesystem safety on legacy filesystems.
    let safe = digest.replacingOccurrences(of: ":", with: "-")
    return storage
      .appendingPathComponent("rootfs-templates")
      .appendingPathComponent("\(safe).ext4")
  }

  /// Clone a template ext4 file into the container's rootfs path.
  ///
  /// Uses POSIX `clonefile()` which is O(1) on APFS via copy-on-write — the file
  /// appears as a separate full-sized rootfs, but only diverging blocks consume
  /// extra disk. On non-APFS filesystems clonefile falls through to a regular copy.
  private func cloneRootfs(template: URL, container destination: URL) throws {
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    // clonefile rejects an existing destination; remove if present.
    try? FileManager.default.removeItem(at: destination)

    let result = template.path.withCString { src in
      destination.path.withCString { dst in
        clonefile(src, dst, 0)
      }
    }
    if result != 0 {
      let err = errno
      throw NSError(
        domain: NSPOSIXErrorDomain, code: Int(err),
        userInfo: [
          NSLocalizedDescriptionKey:
            "clonefile failed: \(String(cString: strerror(err)))"
        ])
    }
  }

  /// Persist a freshly unpacked rootfs as a reusable template. Best-effort:
  /// any failure is dropped silently (the next session will simply unpack again).
  private func saveRootfsTemplate(from rootfs: URL, to template: URL) {
    try? cloneRootfs(template: rootfs, container: template)
  }

  // MARK: - Unpack progress

  /// Aggregates per-event Containerization unpack progress (additive byte / item
  /// counters) into cumulative totals, then forwards each update as an
  /// ``AgentStartStage.unpackingRootfs`` event for hosts.
  private actor UnpackProgressTracker {
    private let forward: AgentStartProgressHandler?
    private var processedSize: Int64 = 0
    private var totalSize: Int64 = 0
    private var processedItems: Int = 0
    private var totalItems: Int = 0

    init(forward: AgentStartProgressHandler?) { self.forward = forward }

    func handle(_ events: [ProgressEvent]) async {
      for event in events {
        switch event {
        case .addItems(let n): processedItems += n
        case .addTotalItems(let n): totalItems += n
        case .addSize(let n): processedSize += n
        case .addTotalSize(let n): totalSize += n
        }
      }
      await forward?(
        .unpackingRootfs(
          processedSize: processedSize,
          totalSize: totalSize,
          processedItems: processedItems,
          totalItems: totalItems
        ))
    }
  }
#endif
