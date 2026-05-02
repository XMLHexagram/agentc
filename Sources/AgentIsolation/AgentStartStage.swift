import Foundation

/// Stage transitions reported during ``AgentSession/start(entrypoint:timeout:progress:)``.
///
/// Hosts that pass a progress handler receive each stage exactly once, in order.
/// Stages bracket the long-running phases of agent startup so the host can update UI
/// (spinner labels, etc.) without resorting to time-based heuristics.
public enum AgentStartStage: Sendable, Equatable {
  /// Mount setup, bootstrap copy, environment construction. Usually fast (<100 ms).
  case preparingMounts

  /// `runtime.runContainer` entered: registering the container with the runtime's
  /// manager (image lookup, rootfs allocation).
  case creatingContainer

  /// VM image is being booted and its rootfs initialised. This is typically the
  /// dominant cost on cold start (~1–3 s on Apple Silicon).
  case bootingVM

  /// Container is up; its entrypoint process is starting.
  case startingAgent

  /// `runtime.runContainer` returned and stdout streaming is wired up. The next
  /// thing the host will see is real output from inside the container.
  case ready
}

/// Async progress callback invoked once per ``AgentStartStage`` transition.
public typealias AgentStartProgressHandler = @Sendable (AgentStartStage) async -> Void
