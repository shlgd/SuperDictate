import Darwin
import Foundation

enum LocalSpeechStorage {
    static func cleanupAbandonedFiles(root: URL = LocalSpeechPaths.root) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return }
        let lock = open(root.appendingPathComponent(".install.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { return }
        defer { Darwin.close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { return }
        for profile in SpeechModelProfile.selectable where profile.isExperimental {
            let directory = root.appendingPathComponent("models/\(profile.rawValue)")
            guard fm.fileExists(atPath: directory.path) else { continue }
            if !fm.fileExists(atPath: directory.appendingPathComponent("ready.json").path) {
                try fm.removeItem(at: directory)
            } else {
                for file in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                    where file.pathExtension == "part" || file.lastPathComponent == "ready.tmp" {
                    try fm.removeItem(at: file)
                }
            }
        }
        let stage = root.appendingPathComponent(".runtime-stage")
        if fm.fileExists(atPath: stage.path) { try fm.removeItem(at: stage) }
        for base in [root, root.appendingPathComponent("tmp")] {
            for directory in (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [] {
                let parts = directory.lastPathComponent.split(separator: "-")
                guard parts.count >= 2, parts[0] == "audio" || parts[0] == "session",
                      let pid = pid_t(parts[1]), pid > 0 else { continue }
                if kill(pid, 0) != 0 && errno == ESRCH { try fm.removeItem(at: directory) }
            }
        }
    }

    static func remove(_ profile: SpeechModelProfile, active: SpeechModelProfile,
                       root: URL = LocalSpeechPaths.root) throws {
        guard profile.isExperimental, profile != active else { throw localSpeechError("Switch to another model before deleting this one") }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let lock = open(root.appendingPathComponent(".install.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw localSpeechError("Cannot lock model storage") }
        defer { Darwin.close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw localSpeechError("Wait for the current model download to finish") }
        let directory = root.appendingPathComponent("models/\(profile.rawValue)")
        if fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) }
        let anyModels = SpeechModelProfile.selectable.contains {
            $0.isExperimental && fm.fileExists(atPath: root.appendingPathComponent("models/\($0.rawValue)/ready.json").path)
        }
        if !anyModels && !active.isExperimental {
            for name in ["runtime-v2", "runtime-mlx", "runtime-giga", ManagedSpeechRuntime.distribution] {
                let url = root.appendingPathComponent(name)
                if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            }
        }
    }
}
