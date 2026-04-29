import Foundation

/// Manages the agent-isolation-configurations git repository (clone / pull).
public enum ConfigurationsManager {
  public static let defaultRepo = "https://github.com/laosb/agent-isolation-configurations"
  public static let defaultUpdateInterval = 86400

  /// Ensure the configurations repo is cloned and up-to-date.
  public static func ensureRepo(
    at dir: URL,
    repoURL: String? = nil,
    updateInterval: Int? = nil
  ) async throws {
    let repo = repoURL ?? defaultRepo
    let interval = updateInterval ?? defaultUpdateInterval

    let parentDir = dir.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

    // Acquire an exclusive file lock so parallel processes don't race.
    let lockPath = parentDir.appendingPathComponent(".configurations.lock").path
    let lockFD = open(lockPath, O_RDWR | O_CREAT, 0o644)
    guard lockFD >= 0 else {
      throw SetupError.configRepoError("Failed to create configurations lock file")
    }
    defer {
      flock(lockFD, LOCK_UN)
      close(lockFD)
    }
    guard flock(lockFD, LOCK_EX) == 0 else {
      throw SetupError.configRepoError("Failed to acquire configurations lock")
    }

    let gitDir = dir.appendingPathComponent(".git")

    if !FileManager.default.fileExists(atPath: gitDir.path) {
      // Remove dir if it exists but isn't a valid git repo
      if FileManager.default.fileExists(atPath: dir.path) {
        try FileManager.default.removeItem(at: dir)
      }
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
      process.arguments = ["clone", "--depth", "1", repo, dir.path]
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        throw SetupError.configRepoError("Failed to clone configurations repo from \(repo)")
      }
      return
    }

    // Check if update is needed
    let markerFile = dir.appendingPathComponent(".agentc-last-pull")
    let now = Date()
    if let attrs = try? FileManager.default.attributesOfItem(atPath: markerFile.path),
      let modified = attrs[.modificationDate] as? Date,
      now.timeIntervalSince(modified) < Double(interval)
    {
      return  // Recently updated
    }

    // Pull updates
    let pull = Process()
    pull.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    pull.arguments = ["-C", dir.path, "pull", "--ff-only", "--quiet"]
    pull.standardOutput = FileHandle.nullDevice
    pull.standardError = FileHandle.nullDevice
    try? pull.run()
    pull.waitUntilExit()

    // Update marker regardless of pull success
    FileManager.default.createFile(atPath: markerFile.path, contents: nil)
  }
}
