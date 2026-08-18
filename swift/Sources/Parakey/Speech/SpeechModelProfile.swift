// Parakey — push-to-talk dictation for macOS Apple Silicon.
// Speech / SpeechModelProfile.swift

import Foundation
import FluidAudio

private func resolvedFluidAudioSupportDirectory(_ override: URL?) -> URL? {
    override
        ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("FluidAudio", isDirectory: true)
}

func isSafeSpeechModelCacheDirectory(_ cacheDir: URL,
                                     fluidAudioSupportDirectory: URL? = nil) -> Bool {
    let supportDirectory = resolvedFluidAudioSupportDirectory(fluidAudioSupportDirectory)
    guard let supportDirectory else { return false }

    let cacheURL = cacheDir.standardizedFileURL
    let supportURL = supportDirectory.standardizedFileURL
    guard cacheURL.isFileURL, supportURL.isFileURL else { return false }

    let cachePath = cacheURL.path
    let supportPath = supportURL.path
    let supportPrefix = supportPath.hasSuffix("/") ? supportPath : "\(supportPath)/"
    guard cachePath.hasPrefix(supportPrefix), cachePath != supportPath else { return false }

    let relativePath = String(cachePath.dropFirst(supportPrefix.count))
    let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
    return !components.isEmpty
        && !components.contains("")
        && !components.contains(".")
        && !components.contains("..")
}

func isExistingSpeechModelCacheDirectorySafeForRemoval(
    _ cacheDir: URL,
    fluidAudioSupportDirectory: URL? = nil
) -> Bool {
    guard isSafeSpeechModelCacheDirectory(cacheDir,
                                          fluidAudioSupportDirectory: fluidAudioSupportDirectory),
          let supportDirectory = resolvedFluidAudioSupportDirectory(fluidAudioSupportDirectory) else {
        return false
    }

    let cachePath = cacheDir.standardizedFileURL.path
    let supportPath = supportDirectory.standardizedFileURL.path
    let supportPrefix = supportPath.hasSuffix("/") ? supportPath : "\(supportPath)/"
    let relativePath = String(cachePath.dropFirst(supportPrefix.count))
    let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)

    guard isExistingPlainDirectory(supportPath) else { return false }
    var currentPath = supportPath
    for component in components {
        currentPath = (currentPath as NSString).appendingPathComponent(String(component))
        guard isExistingPlainDirectory(currentPath) else { return false }
    }
    return currentPath == cachePath
}

func speechModelCacheBaseDirectory() -> URL {
    MLModelConfigurationUtils.defaultModelsDirectory()
}

func speechModelCacheDirectory(for _: SpeechModelProfile) -> URL {
    AsrModels.defaultCacheDirectory(for: .v3)
}

func speechModelDownloadRequiredBytes(for profile: SpeechModelProfile,
                                      headroomBytes: Int64 = MODEL_DOWNLOAD_HEADROOM_BYTES) -> Int64 {
    profile.estimatedDownloadBytes + headroomBytes
}

func formattedByteCount(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}

func speechModelDiskSpaceFailureDetail(profile: SpeechModelProfile,
                                       availableBytes: Int64?,
                                       requiredBytes: Int64) -> String? {
    guard let availableBytes, availableBytes >= 0, availableBytes < requiredBytes else {
        return nil
    }
    return """
    Parakey needs \(profile.downloadSizeText) of free disk space to download \(profile.shortName), plus room for CoreML to prepare it.

    Available: \(formattedByteCount(UInt64(availableBytes)))
    Needed: \(formattedByteCount(UInt64(requiredBytes)))

    Free some disk space, then retry loading the speech model. Audio is not uploaded.
    """
}

func availableImportantDiskSpaceBytes(containing url: URL) -> Int64? {
    let fm = FileManager.default
    var probe = url.standardizedFileURL
    while !fm.fileExists(atPath: probe.path), probe.path != "/" {
        probe.deleteLastPathComponent()
    }
    guard let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
          let capacity = values.volumeAvailableCapacityForImportantUsage else {
        return nil
    }
    return Int64(capacity)
}

func speechModelCacheExists(for profile: SpeechModelProfile) -> Bool {
    FileManager.default.fileExists(atPath: speechModelCacheDirectory(for: profile).path)
}

func assertSufficientDiskSpaceForSpeechModelDownload(profile: SpeechModelProfile) throws {
    let requiredBytes = speechModelDownloadRequiredBytes(for: profile)
    let availableBytes = availableImportantDiskSpaceBytes(containing: speechModelCacheBaseDirectory())
    guard let detail = speechModelDiskSpaceFailureDetail(profile: profile,
                                                        availableBytes: availableBytes,
                                                        requiredBytes: requiredBytes) else {
        return
    }
    throw NSError(domain: "Parakey",
                  code: -8,
                  userInfo: [NSLocalizedDescriptionKey: detail])
}

func removeSpeechModelCacheDirectory(_ cacheDir: URL) async throws -> Bool {
    guard isSafeSpeechModelCacheDirectory(cacheDir) else {
        throw NSError(
            domain: "Parakey",
            code: -3,
            userInfo: [
                NSLocalizedDescriptionKey: "Refusing to remove unexpected speech model cache path: \(cacheDir.path)"
            ]
        )
    }

    return try await Task.detached(priority: .userInitiated) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: cacheDir.path) else {
            return false
        }
        guard isExistingSpeechModelCacheDirectorySafeForRemoval(cacheDir) else {
            throw NSError(
                domain: "Parakey",
                code: -4,
                userInfo: [
                    NSLocalizedDescriptionKey: "Refusing to remove unsafe speech model cache path: \(cacheDir.path)"
                ]
            )
        }
        try fm.removeItem(at: cacheDir)
        return true
    }.value
}

func isExistingPlainDirectory(_ path: String) -> Bool {
    var st = stat()
    guard lstat(path, &st) == 0 else { return false }
    return (st.st_mode & S_IFMT) == S_IFDIR
}
