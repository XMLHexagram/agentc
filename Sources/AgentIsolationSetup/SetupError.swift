import Foundation

/// Errors from agent setup operations.
public enum SetupError: LocalizedError {
  case configRepoError(String)
  case bootstrapNotFound(String)
  case bootstrapDownloadFailed(String)

  public var errorDescription: String? {
    switch self {
    case .configRepoError(let message): "agentc setup: \(message)"
    case .bootstrapNotFound(let message): "agentc setup: \(message)"
    case .bootstrapDownloadFailed(let message): "agentc setup: \(message)"
    }
  }
}
