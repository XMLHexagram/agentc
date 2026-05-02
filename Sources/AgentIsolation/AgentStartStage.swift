import Foundation

/// Stage transitions reported during ``AgentSession/start(entrypoint:timeout:progress:)``.
///
/// Hosts that pass a progress handler receive each stage as it begins, plus
/// repeated ``unpackingRootfs`` events for the duration of layer extraction
/// (the dominant cost of fresh container creation).
public enum AgentStartStage: Sendable, Equatable {
  /// Mount setup, bootstrap copy, environment construction. Usually fast (<100 ms).
  case preparingMounts

  /// `runtime.runContainer` entered: registering the container with the runtime's
  /// manager. Image layer extraction follows; see ``unpackingRootfs``.
  case creatingContainer

  /// Cumulative rootfs unpack progress. Fires repeatedly as image layers are
  /// extracted into the rootfs. `totalSize` / `totalItems` are 0 until the
  /// unpacker scans layer headers (typically after the first few hundred ms).
  ///
  /// On a fresh containerID this is the slowest stage by far — for a 155 MB
  /// claudec image this can be 20-40 s as ext4 + 7 layers worth of files
  /// (~30k inodes) get materialised.
  case unpackingRootfs(
    processedSize: Int64,
    totalSize: Int64,
    processedItems: Int,
    totalItems: Int
  )

  /// VM image is being booted and its rootfs mounted (after unpack completes).
  case bootingVM

  /// Container is up; its entrypoint process is starting.
  case startingAgent

  /// `runtime.runContainer` returned and stdout streaming is wired up. The next
  /// thing the host will see is real output from inside the container.
  case ready
}

/// Async progress callback invoked once per ``AgentStartStage`` transition.
public typealias AgentStartProgressHandler = @Sendable (AgentStartStage) async -> Void
