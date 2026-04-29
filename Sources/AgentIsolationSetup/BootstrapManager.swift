import Foundation

/// Locates or downloads the agentc-bootstrap binary used as the container entrypoint.
public enum BootstrapManager {
  /// Default version to download when not specified.
  public static let defaultVersion = "1.0.0-beta.4"

  /// Expected install location for the bootstrap binary.
  public static var bootstrapBinaryPath: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".agentc/bin/bootstrap")
  }

  /// Resolve the bootstrap binary path, downloading from GitHub Releases if missing.
  public static func resolveBootstrapBinary(
    version: String? = nil,
    verbose: Bool = false
  ) async throws -> URL {
    let binaryPath = bootstrapBinaryPath

    if FileManager.default.fileExists(atPath: binaryPath.path) {
      return binaryPath
    }

    try await downloadBootstrap(
      version: version ?? defaultVersion,
      to: binaryPath,
      verbose: verbose
    )
    return binaryPath
  }

  private static func downloadBootstrap(
    version: String, to destination: URL, verbose: Bool
  ) async throws {
    let arch = hostArchLabel()
    let assetName = "agentc-bootstrap-\(arch)-linux-static.tar.gz"
    let url =
      "https://github.com/laosb/agentc/releases/download/v\(version)/\(assetName)"

    let tmpDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("agentc-bootstrap-dl-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let tarPath = tmpDir.appendingPathComponent(assetName)

    // Download
    let curl = Process()
    curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    curl.arguments = ["-fsSL", url, "-o", tarPath.path]
    curl.standardOutput = FileHandle.nullDevice
    curl.standardError = FileHandle.nullDevice
    try curl.run()
    curl.waitUntilExit()
    guard curl.terminationStatus == 0 else {
      throw SetupError.bootstrapDownloadFailed(
        "Failed to download bootstrap binary from \(url)")
    }

    // Extract
    let tar = Process()
    tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    tar.arguments = ["xzf", tarPath.path, "-C", tmpDir.path]
    tar.standardOutput = FileHandle.nullDevice
    tar.standardError = FileHandle.nullDevice
    try tar.run()
    tar.waitUntilExit()
    guard tar.terminationStatus == 0 else {
      throw SetupError.bootstrapDownloadFailed("Failed to extract bootstrap archive")
    }

    // Install
    let extractedBinary = tmpDir.appendingPathComponent("agentc-bootstrap")
    let destDir = destination.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: destDir, withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: destination)
    try FileManager.default.moveItem(at: extractedBinary, to: destination)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: destination.path)
  }

  private static func hostArchLabel() -> String {
    #if arch(arm64)
      return "arm64"
    #elseif arch(x86_64)
      return "x64"
    #else
      return "unknown"
    #endif
  }
}
