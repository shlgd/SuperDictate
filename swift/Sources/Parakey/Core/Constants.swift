// Parakey — push-to-talk dictation for macOS Apple Silicon.
// Core / Constants.swift

import AppKit
import AVFoundation
import CoreGraphics
import Foundation

// MARK: - Audio & Sample Rates

let SAMPLE_RATE: Double = 16_000
let MAX_RECORDING_SECONDS: TimeInterval = 20 * 60   // auto-release if held longer
let PENDING_DICTATION_FILE_VERSION: UInt32 = 1
let PENDING_DICTATION_HEADER_SIZE = 16
let PENDING_DICTATION_MAX_SECONDS: TimeInterval = 30 * 60
let PENDING_DICTATION_MAX_BYTES = Int(PENDING_DICTATION_MAX_SECONDS * SAMPLE_RATE * 4) + PENDING_DICTATION_HEADER_SIZE
let MIN_CLIP_SECONDS: Double = 0.25

// MARK: - Keycodes

let DEFAULT_HOTKEY_KEYCODE: CGKeyCode = 54  // Right Command
let RIGHT_COMMAND_KEYCODE: CGKeyCode = 54
let LEFT_COMMAND_KEYCODE: CGKeyCode = 55
let RIGHT_OPTION_KEYCODE: CGKeyCode = 61
let RIGHT_SHIFT_KEYCODE: CGKeyCode = 60
let FN_KEYCODE: CGKeyCode = 63
let ESCAPE_KEYCODE: CGKeyCode = 53
let RETURN_KEYCODE: CGKeyCode = 36
let ENTER_AFTER_INSERT_DELAY_NANOSECONDS: UInt64 = 120_000_000

// MARK: - Updates

let UPDATE_CHECK_FIRST_DELAY_SECONDS: TimeInterval = 30
let UPDATE_CHECK_INTERVAL_SECONDS: TimeInterval = 6 * 3600  // 6h
let UPDATE_REMIND_LATER_SECONDS: TimeInterval = 24 * 3600  // 24h
let GITHUB_LATEST_RELEASE_URL = URL(string: "https://api.github.com/repos/shlgd/SuperDictate/releases/latest")!
let GITHUB_REPOSITORY_PAGE = URL(string: "https://github.com/shlgd/SuperDictate")!
let GITHUB_RELEASES_PAGE = URL(string: "https://github.com/shlgd/SuperDictate/releases/latest")!
let GITHUB_UPDATE_MANIFEST_URL = URL(string: "https://raw.githubusercontent.com/shlgd/SuperDictate/main/update.json")!
let UPDATE_ARCHIVE_MAX_BYTES = 64 * 1024 * 1024
let HOMEBREW_CASK_TAP = "shlgd/superdictate"
let HOMEBREW_CASK_TOKEN = "shlgd/superdictate/superdictate"
let HOMEBREW_CASK_INSTALLED_TOKEN = "parakey"
let INSTALLED_APP_BUNDLE_PATH = "/Applications/SuperDictate.app"
let AGENT_ARGUMENT = "--agent"
let AGENT_LABEL = "com.local.superdictate.agent"
let APP_SUPPORT_DIR_NAME = "SuperDictate"
let AGENT_STATUS_FILE_NAME = "AgentStatus.json"
let CONTROL_PANEL_PID_FILE_NAME = "ControlPanel.pid"
let UPDATE_HELPER_LOG_PATH = (NSHomeDirectory() as NSString)
    .appendingPathComponent("Library/Logs/SuperDictate-update.log")
let UPDATE_PROGRESS_ARGUMENT = "--update-progress"
let UPDATE_PROGRESS_APP_PREFIX = "SuperDictate-update-progress-"
let MAX_SKIPPED_UPDATE_VERSIONS = 20

// MARK: - App Version

func currentBundleVersion() -> String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        ?? "0.2.40"
}

func currentBundleBuild() -> String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
}

struct AppMemoryUsage {
    let residentBytes: UInt64
    let physicalFootprintBytes: UInt64
}

func currentAppMemoryUsage() -> AppMemoryUsage? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<natural_t>.stride)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
            task_info(mach_task_self_,
                      task_flavor_t(TASK_VM_INFO),
                      rebound,
                      &count)
        }
    }
    guard result == KERN_SUCCESS else { return nil }
    return AppMemoryUsage(residentBytes: UInt64(info.resident_size),
                          physicalFootprintBytes: UInt64(info.phys_footprint))
}

// MARK: - Limits & Diagnostics

let MAX_CORRECTION_SYNC_PATH_BYTES = 4096
let MAX_INPUT_DEVICE_PREFERENCE_BYTES = 512
let DIAGNOSTICS_LOG_MAX_BYTES = 128 * 1024
let DIAGNOSTICS_LOG_MAX_LINES = 40
let DIAGNOSTICS_LOG_MAX_LINE_CHARACTERS = 4096
let TRANSCRIPT_HISTORY_ARCHIVE_MAX_ENTRIES = 100

// MARK: - HUD Layout & Timings

let RECORDING_HUD_BASE_SIZE = NSSize(width: 64, height: 38)
let RECORDING_HUD_ANIMATE_IN_SECONDS: TimeInterval = 0.32
let RECORDING_HUD_ANIMATE_OUT_SECONDS: TimeInterval = 0.23
let RECORDING_HUD_TRANSCRIBING_RESOLVE_SECONDS: TimeInterval = 0.20
let RECORDING_HUD_TRANSCRIBING_MIN_VISIBLE_SECONDS: TimeInterval = 0.24
let RECORDING_HUD_TARGET_REFRESH_INTERVAL: TimeInterval = 0.16
let RECORDING_HUD_TARGET_FOLLOW_RESPONSE: CGFloat = 22
let RECORDING_HUD_TARGET_CACHE_MAX_AGE: TimeInterval = 10 * 60
let RECORDING_HUD_DISPLAY_LINK_MIN_FPS: Float = 60
let RECORDING_HUD_DISPLAY_LINK_MAX_FPS: Float = 120
let RECORDING_HUD_RECORDING_BASE_PHASE_SPEED: CGFloat = 16.96
let RECORDING_HUD_RECORDING_LEVEL_PHASE_SPEED: CGFloat = 10.08
let RECORDING_HUD_TRANSCRIBING_PHASE_SPEED: CGFloat = 10.2
let RECORDING_HUD_EXPORT_ARGUMENT = "--export-hud-animation"

// MARK: - Notifications

let HOTKEY_CAPTURE_BEGIN_NOTIFICATION = Notification.Name("com.local.superdictate.hotkey-capture-begin")
let HOTKEY_CAPTURE_END_NOTIFICATION = Notification.Name("com.local.superdictate.hotkey-capture-end")
let SETTINGS_CHANGED_NOTIFICATION = Notification.Name("com.local.superdictate.settings-changed")

// MARK: - Failure & Retries

let HOTKEY_CAPTURE_FAILSAFE_SECONDS: TimeInterval = 45
let DICTATION_ERROR_FLASH_SECONDS: TimeInterval = 1.5
let AUDIO_START_RETRY_DELAYS_SECONDS: [UInt64] = [1, 3, 8]
let AUDIO_IDLE_STOP_DELAY_SECONDS: TimeInterval = 5
let AUDIO_CONFIGURATION_CHANGE_SUPPRESSION_SECONDS: TimeInterval = 1
let MODEL_DOWNLOAD_HEADROOM_BYTES: Int64 = 500 * 1024 * 1024

// MARK: - Settings & Corrections Suite

let SETTINGS_SUITE = "com.local.superdictate"
let CORRECTIONS_FILE_UTI = "com.local.superdictate.corrections"
let CORRECTIONS_FILE_EXTENSION = "superdictate-corrections"
let CORRECTIONS_FILE_NAME = "SuperDictate Corrections.\(CORRECTIONS_FILE_EXTENSION)"
let MAX_TRANSCRIPT_CORRECTIONS = 512
let MAX_TRANSCRIPT_CORRECTION_SOURCE_BYTES = 512
let MAX_TRANSCRIPT_CORRECTION_REPLACEMENT_BYTES = 4096

let CORE_AUDIO_DEFAULT_AGGREGATE_PREFIX = "CADefaultDeviceAggregate-"
