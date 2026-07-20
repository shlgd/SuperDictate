// Parakey — push-to-talk dictation for macOS Apple Silicon.
//
// Single-file Swift menu-bar app. The whole runtime lives in this
// file: hotkey capture (`CGEventTap`), audio capture
// (`AVAudioEngine`), transcription (`FluidAudio` on the Apple
// Neural Engine), paste-at-cursor (`NSPasteboard` + `CGEvent`),
// system-audio mute (`NSAppleScript`), menu-bar UI, settings,
// rolling history, in-app updater, TCC self-healing.
//
// Section comments (`// MARK: -`) tag every major region; Cmd+Ctrl+Up
// in Xcode jumps between them. Keep them honest as you edit.
//
// Architectural invariants the build relies on are documented in
// ../../AGENTS.md — read that before refactoring concurrency,
// resource loading, or codesigning. In particular:
//   - `AudioCapture` is *not* @MainActor (AVAudioEngine tap fires on
//     an audio thread; main-actor entry would SIGTRAP under Swift 6
//     strict concurrency).
//   - `AVAudioConverter` inputBlock must return .noDataNow, never
//     .endOfStream — the latter puts the converter in a terminal
//     state and every press after the first captures silence.
//   - Resources are loaded via `Bundle.main`, never `Bundle.module`
//     — SwiftPM's auto-generated resource bundle has no Info.plist
//     and breaks `codesign --deep`.

import AppKit
import AVFoundation
import AudioToolbox
import Foundation
import CoreGraphics
import CryptoKit
import Darwin
import ApplicationServices
import FluidAudio
import IOKit
import QuartzCore
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - Constants

let SAMPLE_RATE: Double = 16_000
let MAX_RECORDING_SECONDS: TimeInterval = 20 * 60   // auto-release if held longer
let PENDING_DICTATION_FILE_VERSION: UInt32 = 1
let PENDING_DICTATION_HEADER_SIZE = 16
let PENDING_DICTATION_MAX_SECONDS: TimeInterval = 30 * 60
let PENDING_DICTATION_MAX_BYTES = Int(PENDING_DICTATION_MAX_SECONDS * SAMPLE_RATE * 4) + PENDING_DICTATION_HEADER_SIZE
let DEFAULT_HOTKEY_KEYCODE: CGKeyCode = 54  // Right Command
let RIGHT_COMMAND_KEYCODE: CGKeyCode = 54
let LEFT_COMMAND_KEYCODE: CGKeyCode = 55
let RIGHT_OPTION_KEYCODE: CGKeyCode = 61
let RIGHT_SHIFT_KEYCODE: CGKeyCode = 60
let FN_KEYCODE: CGKeyCode = 63
let ESCAPE_KEYCODE: CGKeyCode = 53
let RETURN_KEYCODE: CGKeyCode = 36
let ENTER_AFTER_INSERT_DELAY_NANOSECONDS: UInt64 = 120_000_000
let MIN_CLIP_SECONDS: Double = 0.25
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
let MAX_CORRECTION_SYNC_PATH_BYTES = 4096
let MAX_INPUT_DEVICE_PREFERENCE_BYTES = 512
let DIAGNOSTICS_LOG_MAX_BYTES = 128 * 1024
let DIAGNOSTICS_LOG_MAX_LINES = 40
let DIAGNOSTICS_LOG_MAX_LINE_CHARACTERS = 4096
let TRANSCRIPT_HISTORY_ARCHIVE_MAX_ENTRIES = 100
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
let HOTKEY_CAPTURE_BEGIN_NOTIFICATION = Notification.Name("com.local.superdictate.hotkey-capture-begin")
let HOTKEY_CAPTURE_END_NOTIFICATION = Notification.Name("com.local.superdictate.hotkey-capture-end")
let HOTKEY_CAPTURE_FAILSAFE_SECONDS: TimeInterval = 45
let DICTATION_ERROR_FLASH_SECONDS: TimeInterval = 1.5  // how long the menu-bar icon flags a dropped dictation before returning to idle
let AUDIO_START_RETRY_DELAYS_SECONDS: [UInt64] = [1, 3, 8]
let AUDIO_IDLE_STOP_DELAY_SECONDS: TimeInterval = 5
let AUDIO_CONFIGURATION_CHANGE_SUPPRESSION_SECONDS: TimeInterval = 1
let MODEL_DOWNLOAD_HEADROOM_BYTES: Int64 = 500 * 1024 * 1024

let SETTINGS_SUITE = "com.local.superdictate"
let CORRECTIONS_FILE_UTI = "com.local.superdictate.corrections"
let CORRECTIONS_FILE_EXTENSION = "superdictate-corrections"
let CORRECTIONS_FILE_NAME = "SuperDictate Corrections.\(CORRECTIONS_FILE_EXTENSION)"
let MAX_TRANSCRIPT_CORRECTIONS = 512
let MAX_TRANSCRIPT_CORRECTION_SOURCE_BYTES = 512
let MAX_TRANSCRIPT_CORRECTION_REPLACEMENT_BYTES = 4096

/// Visible state of the menu-bar item. Idle/loading/busy use the
/// template image so macOS handles light/dark menu bars. Recording and
/// error states use pre-tinted static frames so the state remains
/// visible even when macOS ignores contentTintColor on template images.
enum MenuBarState {
    case loading
    case idle
    case recording
    case busy
    case error
}

enum RecordingHUDMode {
    case recording
    case transcribing
    /// Brief flash shown when a dictation fails (transcription error,
    /// paste failure). Renders a static yellow capsule so the user
    /// gets visual feedback even when the menu-bar icon is hidden.
    case error
}

/// A global dictation shortcut: either one modifier key or a regular
/// keyboard key with an optional Control/Option/Shift/Command chord.
struct HotkeyChoice: Equatable {
    let name: String
    let keycode: CGKeyCode
    let isModifier: Bool
    /// Which CGEventFlags mask bit fires for this modifier (nil for non-modifiers).
    let modifierFlag: CGEventFlags?
    /// Modifier keys required alongside a non-modifier key.
    let requiredModifiers: CGEventFlags

    init(name: String,
         keycode: CGKeyCode,
         isModifier: Bool,
         modifierFlag: CGEventFlags?,
         requiredModifiers: CGEventFlags = []) {
        self.name = name
        self.keycode = keycode
        self.isModifier = isModifier
        self.modifierFlag = modifierFlag
        self.requiredModifiers = requiredModifiers.intersection(HOTKEY_SHORTCUT_MODIFIER_MASK)
    }
}

let HOTKEY_SHORTCUT_MODIFIER_MASK: CGEventFlags = [
    .maskControl,
    .maskAlternate,
    .maskShift,
    .maskCommand,
    .maskSecondaryFn,
]

let MODIFIER_HOTKEY_CHOICES: [HotkeyChoice] = [
    HotkeyChoice(name: "Left Control", keycode: 59, isModifier: true, modifierFlag: .maskControl),
    HotkeyChoice(name: "Right Control", keycode: 62, isModifier: true, modifierFlag: .maskControl),
    HotkeyChoice(name: "Left Option", keycode: 58, isModifier: true, modifierFlag: .maskAlternate),
    HotkeyChoice(name: "Right Option", keycode: 61, isModifier: true, modifierFlag: .maskAlternate),
    HotkeyChoice(name: "Left Shift", keycode: 56, isModifier: true, modifierFlag: .maskShift),
    HotkeyChoice(name: "Right Shift", keycode: 60, isModifier: true, modifierFlag: .maskShift),
    HotkeyChoice(name: "Left Command", keycode: 55, isModifier: true, modifierFlag: .maskCommand),
    HotkeyChoice(name: "Right Command", keycode: 54, isModifier: true, modifierFlag: .maskCommand),
    HotkeyChoice(name: "Fn", keycode: FN_KEYCODE, isModifier: true, modifierFlag: .maskSecondaryFn),
]

let FUNCTION_KEY_NAMES_BY_KEYCODE: [CGKeyCode: String] = [
    122: "F1",
    120: "F2",
    99: "F3",
    118: "F4",
    96: "F5",
    97: "F6",
    98: "F7",
    100: "F8",
    101: "F9",
    109: "F10",
    103: "F11",
    111: "F12",
    105: "F13",
    107: "F14",
    113: "F15",
    106: "F16",
    64: "F17",
    79: "F18",
    80: "F19",
    90: "F20",
]

let HOTKEY_CHOICES: [HotkeyChoice] = [
    MODIFIER_HOTKEY_CHOICES.first(where: { $0.keycode == 62 })!,
    MODIFIER_HOTKEY_CHOICES.first(where: { $0.keycode == 61 })!,
    MODIFIER_HOTKEY_CHOICES.first(where: { $0.keycode == 54 })!,
    HotkeyChoice(name: "F5",            keycode: 96,  isModifier: false, modifierFlag: nil),
    HotkeyChoice(name: "F6",            keycode: 97,  isModifier: false, modifierFlag: nil),
    HotkeyChoice(name: "F13",           keycode: 105, isModifier: false, modifierFlag: nil),
    HotkeyChoice(name: "F18",           keycode: 79,  isModifier: false, modifierFlag: nil),
    HotkeyChoice(name: "F19",           keycode: 80,  isModifier: false, modifierFlag: nil),
]

private let HOTKEY_KEY_NAMES_BY_KEYCODE: [CGKeyCode: String] = [
    0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
    11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2",
    20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8",
    29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return",
    37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N",
    46: "M", 47: ".", 48: "Tab", 49: "Space", 50: "`", 51: "Delete", 53: "Escape",
    65: "Keypad .", 67: "Keypad *", 69: "Keypad +", 71: "Clear", 75: "Keypad /",
    76: "Enter", 78: "Keypad -", 81: "Keypad =", 82: "Keypad 0", 83: "Keypad 1",
    84: "Keypad 2", 85: "Keypad 3", 86: "Keypad 4", 87: "Keypad 5", 88: "Keypad 6",
    89: "Keypad 7", 91: "Keypad 8", 92: "Keypad 9", 114: "Help", 115: "Home",
    116: "Page Up", 117: "Forward Delete", 119: "End", 121: "Page Down", 123: "Left Arrow",
    124: "Right Arrow", 125: "Down Arrow", 126: "Up Arrow",
]

private func hotkeyKeyName(for keycode: CGKeyCode) -> String {
    FUNCTION_KEY_NAMES_BY_KEYCODE[keycode]
        ?? HOTKEY_KEY_NAMES_BY_KEYCODE[keycode]
        ?? "Key \(keycode)"
}

private func hotkeyModifierSymbols(_ flags: CGEventFlags) -> String {
    var result = ""
    if flags.contains(.maskControl) { result += "⌃" }
    if flags.contains(.maskAlternate) { result += "⌥" }
    if flags.contains(.maskShift) { result += "⇧" }
    if flags.contains(.maskCommand) { result += "⌘" }
    if flags.contains(.maskSecondaryFn) { result += "fn" }
    return result
}

private func modifierHotkeyName(primary: HotkeyChoice,
                                requiredModifiers: CGEventFlags) -> String {
    var parts: [String] = []
    if requiredModifiers.contains(.maskControl) { parts.append("Control") }
    if requiredModifiers.contains(.maskAlternate) { parts.append("Option") }
    if requiredModifiers.contains(.maskShift) { parts.append("Shift") }
    if requiredModifiers.contains(.maskCommand) { parts.append("Command") }
    if requiredModifiers.contains(.maskSecondaryFn) { parts.append("Fn") }
    parts.append(primary.name)
    return parts.joined(separator: " + ")
}

func recordableHotkeyChoice(forKeycode keycode: CGKeyCode,
                            modifiers: CGEventFlags = []) -> HotkeyChoice? {
    let normalizedModifiers = modifiers.intersection(HOTKEY_SHORTCUT_MODIFIER_MASK)
    if let choice = MODIFIER_HOTKEY_CHOICES.first(where: { $0.keycode == keycode }) {
        let requiredModifiers = choice.modifierFlag.map {
            normalizedModifiers.subtracting($0)
        } ?? normalizedModifiers
        return HotkeyChoice(name: modifierHotkeyName(primary: choice,
                                                     requiredModifiers: requiredModifiers),
                            keycode: choice.keycode,
                            isModifier: true,
                            modifierFlag: choice.modifierFlag,
                            requiredModifiers: requiredModifiers)
    }
    guard keycode <= 255, keycode != ESCAPE_KEYCODE else { return nil }
    let name = hotkeyModifierSymbols(normalizedModifiers) + hotkeyKeyName(for: keycode)
    return HotkeyChoice(name: name,
                        keycode: keycode,
                        isModifier: false,
                        modifierFlag: nil,
                        requiredModifiers: normalizedModifiers)
}

func hotkeyChoice(forKeycode keycode: CGKeyCode,
                  modifiers: CGEventFlags = []) -> HotkeyChoice {
    recordableHotkeyChoice(forKeycode: keycode, modifiers: modifiers)
        ?? HOTKEY_CHOICES.first(where: { $0.keycode == DEFAULT_HOTKEY_KEYCODE })!
}

func normalizedHotkeyKeycode(storedValue value: Any?) -> CGKeyCode? {
    let raw: Int?
    if let number = value as? NSNumber {
        raw = number.intValue
    } else if let string = value as? String {
        raw = Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
    } else {
        raw = nil
    }

    guard let raw,
          raw >= 0,
          raw <= Int(CGKeyCode.max),
          recordableHotkeyChoice(forKeycode: CGKeyCode(raw)) != nil else {
        return nil
    }
    return CGKeyCode(raw)
}

enum TriggerMode: String { case hold, toggle }
let TRIGGER_DISPLAY: [TriggerMode: String] = [
    .hold: "Press and hold",
    .toggle: "Press to toggle",
]

enum DictationCompletionBehavior: String, CaseIterable {
    case insert
    case insertAndEnter

    var opposite: DictationCompletionBehavior {
        self == .insert ? .insertAndEnter : .insert
    }

    var pressesEnter: Bool { self == .insertAndEnter }
}

enum InterfaceLanguage: String, CaseIterable {
    case russian = "ru"
    case english = "en"
}

func localizedText(_ russian: String,
                   _ english: String,
                   language: InterfaceLanguage) -> String {
    language == .russian ? russian : english
}

func localizedHotkeyName(_ choice: HotkeyChoice,
                         language: InterfaceLanguage) -> String {
    guard language == .russian else { return choice.name }
    if choice.isModifier {
        let primary: String
        switch choice.keycode {
        case 59: primary = "Левый Control"
        case 62: primary = "Правый Control"
        case 58: primary = "Левый Option"
        case 61: primary = "Правый Option"
        case 56: primary = "Левый Shift"
        case 60: primary = "Правый Shift"
        case 55: primary = "Левый Command"
        case 54: primary = "Правый Command"
        case FN_KEYCODE: primary = "Fn"
        default: primary = choice.name
        }
        var parts: [String] = []
        if choice.requiredModifiers.contains(.maskControl) { parts.append("Control") }
        if choice.requiredModifiers.contains(.maskAlternate) { parts.append("Option") }
        if choice.requiredModifiers.contains(.maskShift) { parts.append("Shift") }
        if choice.requiredModifiers.contains(.maskCommand) { parts.append("Command") }
        if choice.requiredModifiers.contains(.maskSecondaryFn) { parts.append("Fn") }
        parts.append(primary)
        return parts.joined(separator: " + ")
    }

    let keyName: String
    switch choice.keycode {
    case 36: keyName = "Return"
    case 48: keyName = "Tab"
    case 49: keyName = "Пробел"
    case 51: keyName = "Delete"
    case 76: keyName = "Enter"
    case 115: keyName = "Home"
    case 116: keyName = "Page Up"
    case 117: keyName = "Forward Delete"
    case 119: keyName = "End"
    case 121: keyName = "Page Down"
    case 123: keyName = "Стрелка влево"
    case 124: keyName = "Стрелка вправо"
    case 125: keyName = "Стрелка вниз"
    case 126: keyName = "Стрелка вверх"
    default: keyName = hotkeyKeyName(for: choice.keycode)
    }
    return hotkeyModifierSymbols(choice.requiredModifiers) + keyName
}

enum PasteSuffix: String { case appendSpace = "space", none, appendNewline = "newline" }
let PASTE_SUFFIX_DISPLAY: [PasteSuffix: String] = [
    .appendSpace: "Append space",
    .none: "No suffix",
    .appendNewline: "Append newline",
]

/// User-visible language choice for the v3 decoder script filter. `.auto`
/// passes no hint and lets the decoder pick freely — the right default for
/// almost everyone. Selecting a specific language biases the joint head
/// toward that script (Latin vs Cyrillic), which prevents the occasional
/// Cyrillic-character bleed-through that v3 can emit when transcribing
/// Latin-script speech (FluidAudio v0.14.1 fix). Raw values match
/// FluidAudio's `Language` BCP-47-ish keys so `fluidLanguage` is a direct
/// lookup.
enum DictationLanguage: String, CaseIterable {
    case auto
    case english = "en"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case italian = "it"
    case portuguese = "pt"
    case romanian = "ro"
    case polish = "pl"
    case czech = "cs"
    case slovak = "sk"
    case slovenian = "sl"
    case croatian = "hr"
    case bosnian = "bs"
    case russian = "ru"
    case ukrainian = "uk"
    case belarusian = "be"
    case bulgarian = "bg"
    case serbian = "sr"

    /// Map to FluidAudio's `Language` enum. Returns nil for `.auto` so the
    /// caller passes no hint and the decoder script filter stays off.
    var fluidLanguage: Language? {
        switch self {
        case .auto:        return nil
        case .english:     return .english
        case .spanish:     return .spanish
        case .french:      return .french
        case .german:      return .german
        case .italian:     return .italian
        case .portuguese:  return .portuguese
        case .romanian:    return .romanian
        case .polish:      return .polish
        case .czech:       return .czech
        case .slovak:      return .slovak
        case .slovenian:   return .slovenian
        case .croatian:    return .croatian
        case .bosnian:     return .bosnian
        case .russian:     return .russian
        case .ukrainian:   return .ukrainian
        case .belarusian:  return .belarusian
        case .bulgarian:   return .bulgarian
        case .serbian:     return .serbian
        }
    }
}

let DICTATION_LANGUAGE_DISPLAY: [DictationLanguage: String] = [
    .auto: "Auto-detect",
    .english: "English",
    .spanish: "Spanish",
    .french: "French",
    .german: "German",
    .italian: "Italian",
    .portuguese: "Portuguese",
    .romanian: "Romanian",
    .polish: "Polish",
    .czech: "Czech",
    .slovak: "Slovak",
    .slovenian: "Slovenian",
    .croatian: "Croatian",
    .bosnian: "Bosnian",
    .russian: "Russian",
    .ukrainian: "Ukrainian",
    .belarusian: "Belarusian",
    .bulgarian: "Bulgarian",
    .serbian: "Serbian",
]

enum SpeechModelProfile: String, CaseIterable {
    case multilingualV3 = "multilingual_v3"
    // Deprecated production option. Kept only so old saved preferences
    // can be read and migrated back to the supported v3 model.
    case englishUnified = "english_unified"

    static let productionDefault: SpeechModelProfile = .multilingualV3

    var isProductionSupported: Bool {
        self == .multilingualV3
    }

    var productionProfile: SpeechModelProfile {
        isProductionSupported ? self : Self.productionDefault
    }

    var displayName: String {
        switch self {
        case .multilingualV3:
            return "Multilingual (Parakeet TDT v3)"
        case .englishUnified:
            return "English optimized (Parakeet Unified, deprecated)"
        }
    }

    var shortName: String {
        switch self {
        case .multilingualV3:
            return "Parakeet TDT v3"
        case .englishUnified:
            return "Parakeet Unified"
        }
    }

    var aboutModelText: String {
        switch self {
        case .multilingualV3:
            return "FluidAudio · Parakeet TDT v3 multilingual (CoreML / ANE)"
        case .englishUnified:
            return "FluidAudio · Parakeet Unified English (deprecated)"
        }
    }

    var setupReadyDetail: String {
        "\(shortName) is loaded locally."
    }

    var cacheResetDetail: String {
        switch self {
        case .multilingualV3:
            return "Parakey will delete the local Parakeet TDT v3 model cache, unload the current speech model, and download a fresh verified copy before dictation is available again."
        case .englishUnified:
            return "Parakey will delete the local Parakeet TDT v3 model cache, unload the current speech model, and download a fresh verified copy before dictation is available again."
        }
    }

    var estimatedDownloadBytes: Int64 {
        700 * 1024 * 1024
    }

    var downloadSizeText: String {
        "about 500-700 MB"
    }
}

func productionSpeechModelProfile(rawValue: String?) -> SpeechModelProfile {
    guard let rawValue,
          let profile = SpeechModelProfile(rawValue: rawValue),
          profile.isProductionSupported else {
        return .productionDefault
    }
    return profile
}

enum RecentTranscriptLimit: String, CaseIterable {
    case off
    case last1 = "1"
    case last5 = "5"
    case last10 = "10"

    var count: Int {
        switch self {
        case .off: return 0
        case .last1: return 1
        case .last5: return 5
        case .last10: return 10
        }
    }
}

let DEFAULT_RECENT_TRANSCRIPT_LIMIT = RecentTranscriptLimit.last10
let RECENT_TRANSCRIPT_LIMIT_DISPLAY: [RecentTranscriptLimit: String] = [
    .off: "Off",
    .last1: "Last 1",
    .last5: "Last 5",
    .last10: "Last 10",
]

enum RecordingHUDAccentColor: String, CaseIterable {
    case red
    case orange
    case pink
    case purple
    case blue
    case cyan
    case green
    case white

    var displayName: String {
        switch self {
        case .red: return "Red"
        case .orange: return "Orange"
        case .pink: return "Pink"
        case .purple: return "Purple"
        case .blue: return "Blue"
        case .cyan: return "Cyan"
        case .green: return "Green"
        case .white: return "White"
        }
    }

    var nsColor: NSColor {
        switch self {
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .pink: return .systemPink
        case .purple: return .systemPurple
        case .blue: return NSColor(calibratedRed: 0.0, green: 0.44, blue: 1.0, alpha: 1)
        case .cyan: return .systemCyan
        case .green: return .systemGreen
        case .white: return .white
        }
    }
}

enum RecordingHUDSize: String, CaseIterable {
    case compact
    case standard
    case large

    var displayName: String {
        switch self {
        case .compact: return "Compact"
        case .standard: return "Standard"
        case .large: return "Large"
        }
    }

    var visualScale: CGFloat {
        switch self {
        case .compact: return 1.15
        case .standard: return 1.5
        case .large: return 1.85
        }
    }

    var expandedSize: NSSize {
        NSSize(width: RECORDING_HUD_BASE_SIZE.width * visualScale,
               height: RECORDING_HUD_BASE_SIZE.height * visualScale)
    }
}

enum RecordingHUDBackgroundStyle: String, CaseIterable {
    case system
    case dark
    case light

    var displayName: String {
        switch self {
        case .system: return "System"
        case .dark: return "Dark"
        case .light: return "Light"
        }
    }
}

func parseRecentTranscriptLimit(storedValue value: Any?) -> RecentTranscriptLimit? {
    if let raw = value as? String {
        return RecentTranscriptLimit(rawValue: raw)
    }
    if let number = value as? NSNumber {
        return RecentTranscriptLimit(rawValue: number.stringValue)
    }
    return nil
}

func limitedRecentTranscripts(_ transcripts: [String], limit: RecentTranscriptLimit) -> [String] {
    let count = limit.count
    guard count > 0 else { return [] }
    guard transcripts.count > count else { return transcripts }
    return Array(transcripts.prefix(count))
}

struct ASRTimingBreakdown: Codable, Equatable, Sendable {
    let totalSeconds: Double
    let workerQueueSeconds: Double
    let decoderPreparationSeconds: Double
    let fluidCallSeconds: Double
    let fluidProcessingSeconds: Double

    init(totalSeconds: Double,
         workerQueueSeconds: Double,
         decoderPreparationSeconds: Double,
         fluidCallSeconds: Double,
         fluidProcessingSeconds: Double) {
        self.totalSeconds = max(0, totalSeconds.isFinite ? totalSeconds : 0)
        self.workerQueueSeconds = max(0, workerQueueSeconds.isFinite ? workerQueueSeconds : 0)
        self.decoderPreparationSeconds = max(0, decoderPreparationSeconds.isFinite ? decoderPreparationSeconds : 0)
        self.fluidCallSeconds = max(0, fluidCallSeconds.isFinite ? fluidCallSeconds : 0)
        self.fluidProcessingSeconds = max(0, fluidProcessingSeconds.isFinite ? fluidProcessingSeconds : 0)
    }

    var frameworkOverheadSeconds: Double {
        max(0, totalSeconds - workerQueueSeconds - decoderPreparationSeconds - fluidProcessingSeconds)
    }
}

struct TranscriptHistoryEntry: Codable, Equatable {
    let text: String
    let transcriptionDurationSeconds: Double?
    let asrTiming: ASRTimingBreakdown?

    init(text: String,
         transcriptionDurationSeconds: Double? = nil,
         asrTiming: ASRTimingBreakdown? = nil) {
        self.text = text
        if let duration = transcriptionDurationSeconds,
           duration.isFinite,
           duration >= 0 {
            self.transcriptionDurationSeconds = duration
        } else {
            self.transcriptionDurationSeconds = nil
        }
        self.asrTiming = asrTiming
    }
}

func limitedRecentTranscriptEntries(_ entries: [TranscriptHistoryEntry],
                                    limit: RecentTranscriptLimit) -> [TranscriptHistoryEntry] {
    let count = limit.count
    guard count > 0 else { return [] }
    guard entries.count > count else { return entries }
    return Array(entries.prefix(count))
}

func limitedTranscriptHistoryArchive(_ entries: [TranscriptHistoryEntry],
                                     maximumCount: Int = TRANSCRIPT_HISTORY_ARCHIVE_MAX_ENTRIES) -> [TranscriptHistoryEntry] {
    guard maximumCount > 0 else { return [] }
    guard entries.count > maximumCount else { return entries }
    return Array(entries.prefix(maximumCount))
}

func transcriptHistoryArchive(_ entries: [TranscriptHistoryEntry],
                              removing index: Int) -> [TranscriptHistoryEntry] {
    guard entries.indices.contains(index) else { return entries }
    var next = entries
    next.remove(at: index)
    return next
}

private let DICTATION_USAGE_MAX_DAYS = 400

struct DailyDictationUsage: Codable, Equatable {
    let day: String
    var dictationCount: Int
    var characterCount: Int
    var audioSeconds: Double
    var asrSeconds: Double

    init(day: String,
         dictationCount: Int = 0,
         characterCount: Int = 0,
         audioSeconds: Double = 0,
         asrSeconds: Double = 0) {
        self.day = day
        self.dictationCount = max(0, dictationCount)
        self.characterCount = max(0, characterCount)
        self.audioSeconds = max(0, audioSeconds.isFinite ? audioSeconds : 0)
        self.asrSeconds = max(0, asrSeconds.isFinite ? asrSeconds : 0)
    }

    mutating func add(dictations: Int,
                      characters: Int,
                      audio: Double,
                      asr: Double) {
        dictationCount += max(0, dictations)
        characterCount += max(0, characters)
        audioSeconds += max(0, audio.isFinite ? audio : 0)
        asrSeconds += max(0, asr.isFinite ? asr : 0)
    }
}

struct DictationUsageDaySlot: Equatable {
    let date: Date
    let usage: DailyDictationUsage
}

struct DictationUsageWeekSnapshot: Equatable {
    let days: [DictationUsageDaySlot]

    var totalDictations: Int { days.reduce(0) { $0 + $1.usage.dictationCount } }
    var totalCharacters: Int { days.reduce(0) { $0 + $1.usage.characterCount } }
    var totalAudioSeconds: Double { days.reduce(0) { $0 + $1.usage.audioSeconds } }
    var totalASRSeconds: Double { days.reduce(0) { $0 + $1.usage.asrSeconds } }
    var averageASRSeconds: Double {
        totalDictations > 0 ? totalASRSeconds / Double(totalDictations) : 0
    }
    var averageCharactersPerDictation: Double {
        totalDictations > 0 ? Double(totalCharacters) / Double(totalDictations) : 0
    }
    var realtimeSpeedRatio: Double {
        totalASRSeconds > 0 ? totalAudioSeconds / totalASRSeconds : 0
    }
}

func dictationUsageDayKey(for date: Date, calendar: Calendar) -> String {
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d",
                  components.year ?? 0,
                  components.month ?? 0,
                  components.day ?? 0)
}

func mergedDailyDictationUsage(_ stats: [DailyDictationUsage],
                               maximumDays: Int = DICTATION_USAGE_MAX_DAYS) -> [DailyDictationUsage] {
    guard maximumDays > 0 else { return [] }
    var byDay: [String: DailyDictationUsage] = [:]
    for stat in stats where !stat.day.isEmpty {
        var combined = byDay[stat.day] ?? DailyDictationUsage(day: stat.day)
        combined.add(dictations: stat.dictationCount,
                     characters: stat.characterCount,
                     audio: stat.audioSeconds,
                     asr: stat.asrSeconds)
        byDay[stat.day] = combined
    }
    return Array(byDay.values.sorted { $0.day < $1.day }.suffix(maximumDays))
}

func addingDictationUsageSample(to stats: [DailyDictationUsage],
                                at date: Date,
                                characterCount: Int,
                                audioSeconds: Double,
                                asrSeconds: Double,
                                calendar: Calendar) -> [DailyDictationUsage] {
    guard characterCount > 0 else { return stats }
    let day = dictationUsageDayKey(for: date, calendar: calendar)
    var next = stats
    if let index = next.firstIndex(where: { $0.day == day }) {
        next[index].add(dictations: 1,
                        characters: characterCount,
                        audio: audioSeconds,
                        asr: asrSeconds)
    } else {
        next.append(DailyDictationUsage(day: day,
                                        dictationCount: 1,
                                        characterCount: characterCount,
                                        audioSeconds: audioSeconds,
                                        asrSeconds: asrSeconds))
    }
    return mergedDailyDictationUsage(next)
}

func lastSevenCompletedDictationUsage(_ stats: [DailyDictationUsage],
                                      referenceDate: Date,
                                      calendar: Calendar) -> DictationUsageWeekSnapshot {
    let byDay = Dictionary(uniqueKeysWithValues: mergedDailyDictationUsage(stats).map { ($0.day, $0) })
    let today = calendar.startOfDay(for: referenceDate)
    let days = (1...7).reversed().compactMap { offset -> DictationUsageDaySlot? in
        guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
        let key = dictationUsageDayKey(for: date, calendar: calendar)
        return DictationUsageDaySlot(date: date,
                                     usage: byDay[key] ?? DailyDictationUsage(day: key))
    }
    return DictationUsageWeekSnapshot(days: days)
}

func importedDailyDictationUsage(from logText: String,
                                 fileCreatedAt: Date,
                                 calendar: Calendar) -> [DailyDictationUsage] {
    let pattern = #"^\[(\d{2}):(\d{2}):(\d{2})\]\s+([0-9]+(?:\.[0-9]+)?) s audio → ([0-9]+(?:\.[0-9]+)?) s → (\d+) chars"#
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }

    var currentDay = calendar.startOfDay(for: fileCreatedAt)
    var previousSecondsOfDay: Int?
    var stats: [DailyDictationUsage] = []

    for lineSlice in logText.split(separator: "\n", omittingEmptySubsequences: true) {
        let line = String(lineSlice)
        let fullRange = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = expression.firstMatch(in: line, range: fullRange) else {
            if line.count >= 10,
               line.first == "[",
               let hour = Int(line.dropFirst(1).prefix(2)),
               let minute = Int(line.dropFirst(4).prefix(2)),
               let second = Int(line.dropFirst(7).prefix(2)) {
                let secondsOfDay = (hour * 3_600) + (minute * 60) + second
                if let previousSecondsOfDay, secondsOfDay < previousSecondsOfDay,
                   let nextDay = calendar.date(byAdding: .day, value: 1, to: currentDay) {
                    currentDay = nextDay
                }
                previousSecondsOfDay = secondsOfDay
            }
            continue
        }

        func capture(_ index: Int) -> String? {
            guard let range = Range(match.range(at: index), in: line) else { return nil }
            return String(line[range])
        }
        guard let hour = capture(1).flatMap(Int.init),
              let minute = capture(2).flatMap(Int.init),
              let second = capture(3).flatMap(Int.init),
              let audio = capture(4).flatMap(Double.init),
              let asr = capture(5).flatMap(Double.init),
              let characters = capture(6).flatMap(Int.init) else {
            continue
        }

        let secondsOfDay = (hour * 3_600) + (minute * 60) + second
        if let previousSecondsOfDay, secondsOfDay < previousSecondsOfDay,
           let nextDay = calendar.date(byAdding: .day, value: 1, to: currentDay) {
            currentDay = nextDay
        }
        previousSecondsOfDay = secondsOfDay
        stats = addingDictationUsageSample(to: stats,
                                           at: currentDay,
                                           characterCount: characters,
                                           audioSeconds: audio,
                                           asrSeconds: asr,
                                           calendar: calendar)
    }
    return stats
}

func transcriptionDurationLabel(_ duration: Double?) -> String {
    guard let duration, duration.isFinite, duration >= 0 else { return "\u{2014}" }
    return String(format: "%.3f s", duration)
}

func millisecondsLabel(_ duration: Double) -> String {
    String(format: "%.1f ms", max(0, duration) * 1_000)
}

func asrTimingTooltip(_ timing: ASRTimingBreakdown?) -> String? {
    guard let timing else { return nil }
    return [
        "ASR total  \(millisecondsLabel(timing.totalSeconds))",
        "FluidAudio  \(millisecondsLabel(timing.fluidProcessingSeconds))",
        "Decoder setup  \(millisecondsLabel(timing.decoderPreparationSeconds))",
        "Actor + framework  \(millisecondsLabel(timing.workerQueueSeconds + timing.frameworkOverheadSeconds))",
    ].joined(separator: "\n")
}

struct DictationLatencyMetrics: Equatable {
    let audioSeconds: Double
    let hotkeyDispatchSeconds: Double?
    let releasePreparationSeconds: Double
    let settingsRefreshSeconds: Double
    let releasePermissionCheckSeconds: Double
    let audioFinalizeSeconds: Double
    let audioDetachSeconds: Double
    let journalFlushSeconds: Double
    let audioFlattenSeconds: Double
    let transcribingUISeconds: Double
    let taskQueueSeconds: Double
    let releaseToASRSeconds: Double
    let asrTiming: ASRTimingBreakdown
    let postprocessingSeconds: Double
    let historyPersistenceSeconds: Double
    let journalCleanupSeconds: Double
    let permissionRecheckSeconds: Double
    let insertionDispatchSeconds: Double
    let releaseToPasteDispatchSeconds: Double
    let enterDelaySeconds: Double?
    let pasteSucceeded: Bool

    var logLine: String {
        let enter = enterDelaySeconds.map(millisecondsLabel) ?? "off"
        let hotkeyDispatch = hotkeyDispatchSeconds.map(millisecondsLabel) ?? "off"
        let releaseState = max(
            0,
            releasePreparationSeconds - settingsRefreshSeconds - releasePermissionCheckSeconds
        )
        return [
            "latency:",
            "audio=\(String(format: "%.3f", audioSeconds))s",
            "hotkey_dispatch=\(hotkeyDispatch)",
            "release_prep=\(millisecondsLabel(releasePreparationSeconds))",
            "settings_refresh=\(millisecondsLabel(settingsRefreshSeconds))",
            "release_permission=\(millisecondsLabel(releasePermissionCheckSeconds))",
            "release_state=\(millisecondsLabel(releaseState))",
            "audio_finalize=\(millisecondsLabel(audioFinalizeSeconds))",
            "audio_detach=\(millisecondsLabel(audioDetachSeconds))",
            "journal_flush=\(millisecondsLabel(journalFlushSeconds))",
            "audio_flatten=\(millisecondsLabel(audioFlattenSeconds))",
            "transcribing_ui_overlap=\(millisecondsLabel(transcribingUISeconds))",
            "task_queue=\(millisecondsLabel(taskQueueSeconds))",
            "release_to_asr=\(millisecondsLabel(releaseToASRSeconds))",
            "worker_queue=\(millisecondsLabel(asrTiming.workerQueueSeconds))",
            "decoder_setup=\(millisecondsLabel(asrTiming.decoderPreparationSeconds))",
            "fluid_call=\(millisecondsLabel(asrTiming.fluidCallSeconds))",
            "fluid_processing=\(millisecondsLabel(asrTiming.fluidProcessingSeconds))",
            "framework_overhead=\(millisecondsLabel(asrTiming.frameworkOverheadSeconds))",
            "asr_total=\(millisecondsLabel(asrTiming.totalSeconds))",
            "postprocess=\(millisecondsLabel(postprocessingSeconds))",
            "history=\(millisecondsLabel(historyPersistenceSeconds))",
            "journal_cleanup=\(millisecondsLabel(journalCleanupSeconds))",
            "permission_recheck=\(millisecondsLabel(permissionRecheckSeconds))",
            "insert_dispatch=\(millisecondsLabel(insertionDispatchSeconds))",
            "release_to_paste=\(millisecondsLabel(releaseToPasteDispatchSeconds))",
            "enter_wait=\(enter)",
            "paste=\(pasteSucceeded ? "ok" : "failed")",
        ].joined(separator: " ")
    }
}

func normalizedStoredAppVersion(_ value: String) -> String? {
    UpdateCheck.normalizedReleaseVersion(from: value)
}

func normalizedSkippedUpdateVersions(_ values: [String]) -> [String] {
    var result: [String] = []
    var seen = Set<String>()

    for value in values.reversed() {
        guard let version = UpdateCheck.normalizedReleaseVersion(from: value),
              !seen.contains(version) else {
            continue
        }
        seen.insert(version)
        result.append(version)
        if result.count == MAX_SKIPPED_UPDATE_VERSIONS { break }
    }

    return result.reversed()
}

enum UpdateCheckSource: String, Equatable {
    case automatic
    case manual
    /// Check fired because the user re-enabled automatic update checks
    /// in the settings menu — user-initiated like .manual but silent like
    /// .automatic, so diagnostics record it as its own source.
    case settingsToggle = "settings_toggle"

    var diagnosticLabel: String {
        switch self {
        case .automatic: return "automatic"
        case .manual: return "manual"
        case .settingsToggle: return "settings toggle"
        }
    }
}

enum UpdateCheckResult: String, Equatable {
    case failed = "failed"
    case upToDate = "up_to_date"
    case available = "available"
    case skipped = "skipped"

    var diagnosticLabel: String {
        switch self {
        case .failed: return "failed or unavailable"
        case .upToDate: return "up to date"
        case .available: return "update available"
        case .skipped: return "skipped version available"
        }
    }
}

func updateCheckResult(for release: GitHubRelease?,
                       currentVersion: String,
                       skippedVersions: [String]) -> UpdateCheckResult {
    guard let release else { return .failed }
    guard isNewer(release.version, than: currentVersion) else { return .upToDate }
    return skippedVersions.contains(release.version) ? .skipped : .available
}

func shouldSuppressUpdateForReminder(version: String,
                                     reminderVersion: String?,
                                     reminderUntil: Date?,
                                     now: Date) -> Bool {
    guard let reminderVersion,
          let reminderUntil,
          reminderVersion == version else {
        return false
    }
    return now < reminderUntil
}

/// True when a fetched release makes a stored "Remind me later" pause
/// stale: either the pause expired for the same version (it is about
/// to be re-shown), or a NEWER release superseded the paused one.
/// Without the newer-version case, pausing v0.3.0 and seeing v0.3.1
/// ship within 24 h left diagnostics showing both "Pending update:
/// v0.3.1" and "Reminder paused: v0.3.0 until …". An OLDER fetched
/// version (e.g. a retracted release) keeps the pause.
func shouldClearUpdateReminderPause(fetchedVersion: String, pausedVersion: String?) -> Bool {
    guard let pausedVersion else { return false }
    return fetchedVersion == pausedVersion || isNewer(fetchedVersion, than: pausedVersion)
}

/// Validates a persisted "Remind me later" expiry read back from
/// UserDefaults. Non-Date values and dates further in the future than
/// one full pause window are treated as corrupt and degrade to nil,
/// so a tampered or clock-skewed value re-arms the reminder instead
/// of suppressing updates indefinitely. Past dates pass through —
/// an expired pause is legitimate state that the suppress logic and
/// `shouldClearUpdateReminderPause` handle.
func normalizedUpdateReminderPauseExpiry(storedValue value: Any?,
                                         now: Date = Date(),
                                         maxPauseSeconds: TimeInterval = UPDATE_REMIND_LATER_SECONDS) -> Date? {
    guard let date = value as? Date else { return nil }
    guard date.timeIntervalSince(now) <= maxPauseSeconds else { return nil }
    return date
}

func updateCheckDiagnosticText(checkedAt: Date?,
                               source: UpdateCheckSource?,
                               result: UpdateCheckResult?,
                               releaseVersion: String) -> String {
    guard let checkedAt else { return "never" }
    let timestamp = ISO8601DateFormatter().string(from: checkedAt)
    let sourceText = source?.diagnosticLabel ?? "unknown source"
    let resultText = result?.diagnosticLabel ?? "unknown result"
    let versionText = releaseVersion.isEmpty ? "" : " (latest v\(releaseVersion))"
    return "\(timestamp), \(sourceText), \(resultText)\(versionText)"
}

struct AudioInputDevice: Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

private let CORE_AUDIO_DEFAULT_AGGREGATE_PREFIX = "CADefaultDeviceAggregate-"

struct TranscriptCorrection: Codable, Equatable, Sendable {
    let source: String
    let replacement: String
}

// MARK: - Text correction transfer

struct TranscriptCorrectionsDocument: Codable {
    let schemaVersion: Int
    let exportedAt: Date
    let appVersion: String
    let corrections: [TranscriptCorrection]
}

enum TranscriptCorrectionsDocumentError: LocalizedError {
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            return "This corrections file uses schema version \(version), which this version of Parakey cannot read."
        }
    }
}

enum TranscriptCorrectionsTransferError: LocalizedError {
    case fileTooLarge(Int, Int)
    case notRegularFile

    var errorDescription: String? {
        switch self {
        case .fileTooLarge(let bytes, let limit):
            let actual = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            let maximum = ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)
            return "This corrections file is \(actual), which is larger than Parakey's \(maximum) import limit."
        case .notRegularFile:
            return "The selected corrections path is not a regular file."
        }
    }
}

enum TranscriptCorrectionsTransfer {
    static let schemaVersion = 1
    /// Hard cap for corrections files and in-memory transfers.
    /// Derivation: the worst-case legal set is MAX_TRANSCRIPT_CORRECTIONS
    /// (512) entries at the per-field caps (512 B source + 4096 B
    /// replacement) ≈ 2.25 MiB of raw field bytes, ~2.4 MB once JSON
    /// keys, quoting, and pretty-printing are added — already over the
    /// old 2 MiB cap, which made a full legal set silently unsaveable.
    /// 4 MiB fits that worst case with headroom for JSON escaping while
    /// still rejecting runaway files.
    static let maxFileBytes = 4 * 1024 * 1024

    static var contentType: UTType {
        UTType(filenameExtension: CORRECTIONS_FILE_EXTENSION)
            ?? UTType(exportedAs: CORRECTIONS_FILE_UTI, conformingTo: .json)
    }

    static func encode(_ corrections: [TranscriptCorrection]) throws -> Data {
        let document = TranscriptCorrectionsDocument(
            schemaVersion: schemaVersion,
            exportedAt: Date(),
            appVersion: currentBundleVersion(),
            corrections: normalizedTranscriptCorrections(corrections)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }

    /// Decode result that also reports how many entries the file held
    /// BEFORE normalization, so the import dialog can disclose
    /// truncation (over-cap, invalid, or duplicate entries) instead of
    /// presenting the capped count as the file's content.
    struct CountedDecodeResult: Sendable, Equatable {
        let corrections: [TranscriptCorrection]
        let originalCount: Int
    }

    static func decode(_ data: Data) throws -> [TranscriptCorrection] {
        try decodeCounted(data).corrections
    }

    static func decodeCounted(_ data: Data) throws -> CountedDecodeResult {
        try validateTransferSize(data.count)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let document = try? decoder.decode(TranscriptCorrectionsDocument.self, from: data) {
            guard document.schemaVersion == schemaVersion else {
                throw TranscriptCorrectionsDocumentError.unsupportedSchema(document.schemaVersion)
            }
            return CountedDecodeResult(
                corrections: normalizedTranscriptCorrections(document.corrections),
                originalCount: document.corrections.count
            )
        }

        // Early internal builds stored the bare array. Keeping the
        // fallback costs almost nothing and makes hand-authored files
        // forgiving while the public file format settles.
        let legacy = try decoder.decode([TranscriptCorrection].self, from: data)
        return CountedDecodeResult(
            corrections: normalizedTranscriptCorrections(legacy),
            originalCount: legacy.count
        )
    }

    static func validateTransferSize(_ bytes: Int) throws {
        guard bytes <= maxFileBytes else {
            throw TranscriptCorrectionsTransferError.fileTooLarge(bytes, maxFileBytes)
        }
    }

    /// Writes the encoded document and returns the exact bytes that
    /// landed on disk, so callers can fingerprint what was written
    /// without re-reading the file (a re-read races with sync
    /// providers replacing the file behind us).
    @discardableResult
    static func write(_ corrections: [TranscriptCorrection], to url: URL) throws -> Data {
        let data = try encode(corrections)
        try validateTransferSize(data.count)
        try validateWritablePath(url)
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return data
    }

    static func read(from url: URL) throws -> [TranscriptCorrection] {
        try decode(try readData(from: url))
    }

    static func readCounted(from url: URL) throws -> CountedDecodeResult {
        try decodeCounted(try readData(from: url))
    }

    private static func readData(from url: URL) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            if errno == ELOOP {
                throw TranscriptCorrectionsTransferError.notRegularFile
            }
            throw currentPOSIXError()
        }
        defer { _ = Darwin.close(fd) }

        var st = stat()
        guard Darwin.fstat(fd, &st) == 0 else {
            throw currentPOSIXError()
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            throw TranscriptCorrectionsTransferError.notRegularFile
        }
        if st.st_size > off_t(maxFileBytes) {
            throw TranscriptCorrectionsTransferError.fileTooLarge(Int(st.st_size), maxFileBytes)
        }

        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var data = Data()
        while true {
            guard let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty else {
                break
            }
            data.append(chunk)
            try validateTransferSize(data.count)
        }
        return data
    }

    private static func validateWritablePath(_ url: URL) throws {
        var st = stat()
        guard lstat(url.path, &st) == 0 else {
            if errno == ENOENT { return }
            throw currentPOSIXError()
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            throw TranscriptCorrectionsTransferError.notRegularFile
        }
    }
}

// MARK: - Correction sync path safety
//
// The corrections sync-file path is persisted in UserDefaults and used
// by the periodic timer to read and write without further user
// confirmation. If an attacker can plant a leaf symlink at that path
// (e.g. via prior local code execution), each subsequent sync would
// follow it and either read or overwrite an unrelated file. Reject
// leaf-symlinks at the boundary. Parent-directory symlinks are not
// blocked — those are legitimate sync-provider layouts the user has
// already chosen.

enum TranscriptCorrectionsSyncPathError: LocalizedError {
    case isSymbolicLink

    var errorDescription: String? {
        switch self {
        case .isSymbolicLink:
            return "The text correction sync file is a symbolic link. Parakey refuses to sync through symlinks. Reconnect Parakey to a regular file."
        }
    }
}

func normalizedCorrectionSyncFilePath(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          trimmed.utf8.count <= MAX_CORRECTION_SYNC_PATH_BYTES,
          !trimmed.unicodeScalars.contains(where: { $0.value == 0 }),
          (trimmed as NSString).isAbsolutePath else {
        return nil
    }
    return URL(fileURLWithPath: trimmed).standardizedFileURL.path
}

func validateCorrectionSyncPath(_ url: URL) throws {
    var st = stat()
    // lstat (not stat) so we inspect the link itself rather than its
    // target. Missing files are fine — first-time writes are allowed.
    guard lstat(url.path, &st) == 0 else { return }
    if (st.st_mode & S_IFMT) == S_IFLNK {
        throw TranscriptCorrectionsSyncPathError.isSymbolicLink
    }
}

func shouldStopCorrectionSync(afterPathValidationError error: Error) -> Bool {
    error is TranscriptCorrectionsSyncPathError
}

// MARK: - Model registry hardening
//
// FluidAudio reads REGISTRY_URL and MODEL_REGISTRY_URL from the process
// environment to override the speech-model download base URL. Parakey
// does not document either as a feature, so a value here means either
// (a) a developer is debugging a mirror — uncommon — or (b) a process
// or LaunchAgent has injected one to redirect first-launch model
// downloads to an attacker-controlled host. An attacker who can plant
// `~/Library/LaunchAgents/*.plist` with `EnvironmentVariables` gets
// this persistence channel for free on every GUI app launch. Treat
// any value as adversarial: log it, present a blocking alert, refuse
// to start. The user fixes the env source and relaunches.
//
// We do not block HF_TOKEN etc. — those are auth headers FluidAudio
// sends to the (unchanged) huggingface.co host; a user with HF_TOKEN
// set for unrelated tooling shouldn't be punished.

let HOSTILE_REGISTRY_ENV_VARS = ["REGISTRY_URL", "MODEL_REGISTRY_URL"]

func detectedHostileRegistryEnvVars(in env: [String: String]) -> [String] {
    HOSTILE_REGISTRY_ENV_VARS.filter { env[$0] != nil }.sorted()
}

@MainActor
func refuseHostileRegistryEnvironmentAndExit() {
    let detected = detectedHostileRegistryEnvVars(in: ProcessInfo.processInfo.environment)
    guard !detected.isEmpty else { return }
    let names = detected.joined(separator: ", ")
    log("refusing to start: registry override env var(s) set: \(names)")
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = "Parakey refused to start"
    alert.informativeText = """
        These environment variable(s) are set in Parakey's process: \(names).

        FluidAudio uses them to override the speech-model download URL. Parakey does not support this and treats it as a sign that the launch environment has been tampered with.

        Check ~/Library/LaunchAgents/, your shell rc files, and any parent process. Once the variables are gone, launch Parakey again.
        """
    alert.addButton(withTitle: "Quit")
    alert.runModal()
    exit(EXIT_FAILURE)
}

// MARK: - Speech model integrity
//
// FluidAudio owns the Hugging Face download mechanics, but it does not
// pin the downloaded CoreML bundle contents. Parakey downloads first,
// verifies the files that will be loaded by CoreML, and only then asks
// FluidAudio to compile/load the models. The manifest is intentionally
// tied to one upstream repo commit; a legitimate upstream model change
// should arrive as an explicit Parakey update with refreshed hashes.

struct ModelFileDigest: Equatable {
    let relativePath: String
    let sha256: String
}

enum ModelIntegrityError: LocalizedError {
    case invalidManifestPath(String)
    case missingFile(String)
    case unexpectedFile(String)
    case invalidFileType(String)
    case digestMismatch(path: String, expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .invalidManifestPath(let path):
            return "Speech model integrity manifest contains an unsafe path: \(path)"
        case .missingFile(let path):
            return "Speech model integrity check failed: missing file \(path)"
        case .unexpectedFile(let path):
            return "Speech model integrity check failed: unexpected file \(path)"
        case .invalidFileType(let path):
            return "Speech model integrity check failed: \(path) is not a regular file or directory"
        case .digestMismatch(let path, let expected, let actual):
            return "Speech model integrity check failed for \(path): expected \(expected), got \(actual)"
        }
    }
}

enum ModelIntegrity {
    static let parakeetV3Repository = "FluidInference/parakeet-tdt-0.6b-v3-coreml"
    static let parakeetV3RepositoryCommit = "aed02740059203c4a87495924f685de3722ae9ce"
    private static let sha256Characters = Set("0123456789abcdefABCDEF")

    private static let parakeetV3StrictDirectories = [
        "Decoder.mlmodelc",
        "Encoder.mlmodelc",
        "JointDecisionv3.mlmodelc",
        "Preprocessor.mlmodelc",
    ]

    private static let parakeetV3Files = [
        // BEGIN GENERATED PARAKEET_V3_MODEL_MANIFEST
        ModelFileDigest(relativePath: "Decoder.mlmodelc/analytics/coremldata.bin", sha256: "4238c4e81ecd0dc94bd7dfbb60f7e2cc824107c1ffe0387b8607b72833dba350"),
        ModelFileDigest(relativePath: "Decoder.mlmodelc/coremldata.bin", sha256: "18647af085d87bd8f3121c8a9b4d4564c1ede038dab63d295b4e745cf2d7fb99"),
        ModelFileDigest(relativePath: "Decoder.mlmodelc/metadata.json", sha256: "a39e93cd8371b8ded92635c7804fcd0590f0d1dd9415c6d19a0484be073077d9"),
        ModelFileDigest(relativePath: "Decoder.mlmodelc/model.mil", sha256: "ef2a0a281695398a62fde86ac269c68f73d5b578d7ed3b31f2ba91a2d1ea1f35"),
        ModelFileDigest(relativePath: "Decoder.mlmodelc/weights/weight.bin", sha256: "48adf0f0d47c406c8253d4f7fef967436a39da14f5a65e66d5a4b407be355d41"),
        ModelFileDigest(relativePath: "Encoder.mlmodelc/analytics/coremldata.bin", sha256: "42e638870d73f26b332918a3496ce36793fbb413a81cbd3d16ba01328637a105"),
        ModelFileDigest(relativePath: "Encoder.mlmodelc/coremldata.bin", sha256: "d48034a167a82e88fc3df64f60af963ab3983538271175b8319e7d5720a0fb86"),
        ModelFileDigest(relativePath: "Encoder.mlmodelc/metadata.json", sha256: "da24da9cca943fb29d7fa8e376d57fca7cb3aa08ca51b956b0b0e56813f087e9"),
        ModelFileDigest(relativePath: "Encoder.mlmodelc/model.mil", sha256: "ed7b19156ca29fa7dfd6891deb9fda4b0e8893f68597c985d135736546a43808"),
        ModelFileDigest(relativePath: "Encoder.mlmodelc/weights/weight.bin", sha256: "e2020f323703477a5b21d7c2d282c403e371afb5962e79877e3033e73ba6f421"),
        ModelFileDigest(relativePath: "JointDecisionv3.mlmodelc/analytics/coremldata.bin", sha256: "26def4bf73dd56d29dee21c8ef97cb8969e62f6120ed1adc91e46828e2737b6c"),
        ModelFileDigest(relativePath: "JointDecisionv3.mlmodelc/coremldata.bin", sha256: "f5fc08b741400f0088492c9e839418b1e18522f19cba28d361dd030c5f398342"),
        ModelFileDigest(relativePath: "JointDecisionv3.mlmodelc/metadata.json", sha256: "d9307211b9a37e0f0ac260c7660b1571a3de25841035cfdf9b58fd40425f890f"),
        ModelFileDigest(relativePath: "JointDecisionv3.mlmodelc/model.mil", sha256: "be60732943389a047175111a83f8839f3eb39d4803adafa828a0871b2f39818d"),
        ModelFileDigest(relativePath: "JointDecisionv3.mlmodelc/weights/weight.bin", sha256: "4e0e63d840032f7f07ddb1d64446051166281e5491bf22da8a945c41f6eedb3e"),
        ModelFileDigest(relativePath: "Preprocessor.mlmodelc/analytics/coremldata.bin", sha256: "c9beeb989c8d66f8be11df59bc6df277ec76cee404f6865b46243835ef562f6d"),
        ModelFileDigest(relativePath: "Preprocessor.mlmodelc/coremldata.bin", sha256: "dbde3f2300842c1fd51ef3ff948a0bcffe65ffd2dca10707f2509f32c1d65b1d"),
        ModelFileDigest(relativePath: "Preprocessor.mlmodelc/metadata.json", sha256: "2a98699e22d279dd37fa1d238aeb1c6db1df0d6fad687775324157689d8f3acf"),
        ModelFileDigest(relativePath: "Preprocessor.mlmodelc/model.mil", sha256: "4b8518a956450fec57f06c2a21bdffc26973f7f1fa6842fb38fe917f896b6b93"),
        ModelFileDigest(relativePath: "Preprocessor.mlmodelc/weights/weight.bin", sha256: "129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea"),
        ModelFileDigest(relativePath: "parakeet_vocab.json", sha256: "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735"),
        // END GENERATED PARAKEET_V3_MODEL_MANIFEST
    ]

    static func verifyParakeetV3Model(at directory: URL) throws {
        try verifyFiles(root: directory,
                        expectedFiles: parakeetV3Files,
                        strictDirectories: parakeetV3StrictDirectories)
        log("ASR: verified \(parakeetV3Files.count) model files from \(parakeetV3Repository) @ \(parakeetV3RepositoryCommit)")
    }

    static func verifyFiles(root: URL,
                            expectedFiles: [ModelFileDigest],
                            strictDirectories: [String]) throws {
        var expectedByPath: [String: String] = [:]
        var expectedDirectoryPaths = Set<String>()
        for directory in strictDirectories {
            try validateRelativePath(directory)
            expectedDirectoryPaths.insert(directory)
        }

        for file in expectedFiles {
            try validateRelativePath(file.relativePath)
            try validateSHA256(file.sha256, relativePath: file.relativePath)
            if expectedByPath.updateValue(file.sha256.lowercased(),
                                          forKey: file.relativePath) != nil {
                throw ModelIntegrityError.invalidManifestPath("duplicate file path: \(file.relativePath)")
            }
            expectedDirectoryPaths.formUnion(parentDirectories(of: file.relativePath))
        }
        var seenPaths: Set<String> = []

        for file in expectedFiles {
            let fileURL = root.appendingPathComponent(file.relativePath, isDirectory: false)
            try requireRegularFile(fileURL, relativePath: file.relativePath)

            let actual = try sha256Hex(of: fileURL, relativePath: file.relativePath)
            let expected = file.sha256.lowercased()
            guard actual == expected else {
                throw ModelIntegrityError.digestMismatch(path: file.relativePath,
                                                         expected: expected,
                                                         actual: actual)
            }
            seenPaths.insert(file.relativePath)
        }

        guard seenPaths.count == expectedFiles.count else {
            throw ModelIntegrityError.invalidManifestPath("duplicate file path")
        }

        for directory in strictDirectories {
            let directoryURL = root.appendingPathComponent(directory, isDirectory: true)
            try requireDirectory(directoryURL, relativePath: directory)
            guard let enumerator = FileManager.default.enumerator(at: directoryURL,
                                                                  includingPropertiesForKeys: nil)
            else { continue }

            for case let itemURL as URL in enumerator {
                let relativePath = relativePath(of: itemURL, under: root)
                switch try fileSystemNodeType(itemURL, relativePath: relativePath) {
                case .directory:
                    guard expectedDirectoryPaths.contains(relativePath) else {
                        throw ModelIntegrityError.unexpectedFile(relativePath)
                    }
                case .regularFile:
                    guard expectedByPath[relativePath] != nil else {
                        throw ModelIntegrityError.unexpectedFile(relativePath)
                    }
                }
            }
        }
    }

    static func sha256Hex(of url: URL, relativePath: String) throws -> String {
        let handle = try openRegularFileForHashing(url, relativePath: relativePath)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            guard let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty else {
                break
            }
            hasher.update(data: chunk)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func openRegularFileForHashing(_ url: URL,
                                                  relativePath: String) throws -> FileHandle {
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            if errno == ENOENT { throw ModelIntegrityError.missingFile(relativePath) }
            throw ModelIntegrityError.invalidFileType(relativePath)
        }

        do {
            var st = stat()
            guard Darwin.fstat(fd, &st) == 0 else {
                throw ModelIntegrityError.invalidFileType(relativePath)
            }
            guard (st.st_mode & S_IFMT) == S_IFREG else {
                throw ModelIntegrityError.invalidFileType(relativePath)
            }
            return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        } catch {
            _ = Darwin.close(fd)
            throw error
        }
    }

    private enum FileSystemNodeType {
        case regularFile
        case directory
    }

    private static func validateRelativePath(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/") else {
            throw ModelIntegrityError.invalidManifestPath(path)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(".."),
              !components.contains("."),
              !components.contains("") else {
            throw ModelIntegrityError.invalidManifestPath(path)
        }
    }

    private static func validateSHA256(_ digest: String, relativePath: String) throws {
        guard digest.count == 64,
              digest.allSatisfy({ sha256Characters.contains($0) }) else {
            throw ModelIntegrityError.invalidManifestPath("invalid SHA-256 digest for \(relativePath)")
        }
    }

    private static func parentDirectories(of path: String) -> Set<String> {
        var result = Set<String>()
        var current = path
        while let slash = current.lastIndex(of: "/") {
            current = String(current[..<slash])
            result.insert(current)
        }
        return result
    }

    private static func requireRegularFile(_ url: URL, relativePath: String) throws {
        guard try fileSystemNodeType(url, relativePath: relativePath) == .regularFile else {
            throw ModelIntegrityError.invalidFileType(relativePath)
        }
    }

    private static func requireDirectory(_ url: URL, relativePath: String) throws {
        guard try fileSystemNodeType(url, relativePath: relativePath) == .directory else {
            throw ModelIntegrityError.invalidFileType(relativePath)
        }
    }

    private static func fileSystemNodeType(_ url: URL,
                                           relativePath: String) throws -> FileSystemNodeType {
        var st = stat()
        guard lstat(url.path, &st) == 0 else {
            if errno == ENOENT { throw ModelIntegrityError.missingFile(relativePath) }
            throw ModelIntegrityError.invalidFileType(relativePath)
        }

        switch st.st_mode & S_IFMT {
        case S_IFREG:
            return .regularFile
        case S_IFDIR:
            return .directory
        default:
            throw ModelIntegrityError.invalidFileType(relativePath)
        }
    }

    private static func relativePath(of url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : "\(rootPath)/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(prefix) else { return url.lastPathComponent }
        return String(path.dropFirst(prefix.count))
    }
}

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

private func isExistingPlainDirectory(_ path: String) -> Bool {
    var st = stat()
    guard lstat(path, &st) == 0 else { return false }
    return (st.st_mode & S_IFMT) == S_IFDIR
}

func normalizedTranscriptCorrectionSource(_ source: String) -> String {
    source
        .split(whereSeparator: { $0.isWhitespace })
        .joined(separator: " ")
        .lowercased()
}

func normalizedTranscriptCorrections(_ corrections: [TranscriptCorrection]) -> [TranscriptCorrection] {
    var result: [TranscriptCorrection] = []
    var indexBySource: [String: Int] = [:]

    for correction in corrections {
        let source = correction.source.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = correction.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = normalizedTranscriptCorrectionSource(source)
        guard !source.isEmpty,
              !replacement.isEmpty,
              !key.isEmpty,
              source.utf8.count <= MAX_TRANSCRIPT_CORRECTION_SOURCE_BYTES,
              replacement.utf8.count <= MAX_TRANSCRIPT_CORRECTION_REPLACEMENT_BYTES,
              !source.unicodeScalars.contains(where: { $0.value == 0 }),
              !replacement.unicodeScalars.contains(where: { $0.value == 0 }) else {
            continue
        }

        let cleaned = TranscriptCorrection(source: source, replacement: replacement)
        if let existing = indexBySource[key] {
            result[existing] = cleaned
        } else {
            guard result.count < MAX_TRANSCRIPT_CORRECTIONS else { continue }
            indexBySource[key] = result.count
            result.append(cleaned)
        }
    }

    return result
}

/// First line of the import-confirmation dialog. When the file holds
/// more entries than survive normalization (over the
/// MAX_TRANSCRIPT_CORRECTIONS cap, or invalid/duplicate entries), the
/// dialog must state the file's real count and how many will actually
/// be kept — normalization runs before the dialog, so without this the
/// user is told an oversized file "contains 512 corrections".
func correctionImportCountText(sourceName: String, originalCount: Int, keptCount: Int) -> String {
    guard originalCount > keptCount else {
        return "\(sourceName) contains \(keptCount) corrections."
    }
    return "\(sourceName) contains \(originalCount) entries; only the first \(keptCount) valid corrections (Parakey keeps at most \(MAX_TRANSCRIPT_CORRECTIONS)) will be imported."
}

/// Appended to the import dialog when choosing Merge would push the
/// combined set over the correction cap. The merge path drops over-cap
/// entries silently, so the dialog has to warn before the user picks.
func correctionImportMergeCapWarningText(existingCount: Int,
                                         newCount: Int,
                                         cap: Int = MAX_TRANSCRIPT_CORRECTIONS) -> String? {
    let mergedCount = existingCount + newCount
    guard mergedCount > cap else { return nil }
    return "Merging would produce \(mergedCount) corrections; Parakey keeps at most \(cap), so \(mergedCount - cap) would be dropped."
}

private func utf8ClippedPrefix(_ text: String, maxBytes: Int) -> String {
    guard maxBytes > 0 else { return "" }
    var result = ""
    var usedBytes = 0
    for character in text {
        let byteCount = String(character).utf8.count
        guard usedBytes + byteCount <= maxBytes else { break }
        result.append(character)
        usedBytes += byteCount
    }
    return result
}

func correctionSourcePrefill(from transcript: String) -> String {
    let flat = transcript
        .split(whereSeparator: { $0.isWhitespace })
        .joined(separator: " ")
    return utf8ClippedPrefix(flat, maxBytes: MAX_TRANSCRIPT_CORRECTION_SOURCE_BYTES)
}

func normalizedAudioLevel(from samples: [Float]) -> Float {
    var sumSquares: Double = 0
    var count = 0

    for sample in samples where sample.isFinite {
        let clamped = max(-1, min(1, sample))
        sumSquares += Double(clamped * clamped)
        count += 1
    }

    return normalizedAudioLevel(sumSquares: sumSquares, sampleCount: count)
}

func normalizedAudioLevel(sumSquares: Double, sampleCount: Int) -> Float {
    guard sampleCount > 0, sumSquares > 0 else { return 0 }
    let rms = sqrt(sumSquares / Double(sampleCount))
    guard rms.isFinite, rms > 0 else { return 0 }

    // This is a voice-visibility meter, not a calibrated VU meter.
    // Keep low room tone calm, then aggressively lift speech-range RMS
    // so normal close-mic speech visibly opens the HUD without shouting.
    let decibels = 20 * log10(rms)
    let gated = (decibels + 52) / 20
    guard gated > 0.06 else { return 0 }
    let lifted = pow(max(0, min(1, gated)), 0.42)
    return Float(max(0, min(1, lifted)))
}

func visibleRecordingLevel(rawLevel: Float) -> Float {
    guard rawLevel.isFinite else { return 0 }
    return max(0, min(1, rawLevel))
}

func recordingHUDPhaseSpeed(mode: RecordingHUDMode, level: Float) -> CGFloat {
    switch mode {
    case .recording:
        let voiceLevel = CGFloat(visibleRecordingLevel(rawLevel: level))
        return RECORDING_HUD_RECORDING_BASE_PHASE_SPEED
            + (voiceLevel * RECORDING_HUD_RECORDING_LEVEL_PHASE_SPEED)
    case .transcribing:
        return RECORDING_HUD_TRANSCRIBING_PHASE_SPEED
    case .error:
        return 0
    }
}

struct TranscriptCorrectionSyncMergeResult: Equatable {
    let corrections: [TranscriptCorrection]
    let conflictingSources: [String]
}

struct CorrectionSyncFileFingerprint: Equatable {
    let modifiedAt: Date?
    let size: Int?
    let sha256: String
}

func correctionSyncFingerprint(for url: URL) -> CorrectionSyncFileFingerprint? {
    do {
        let digest = try correctionSyncFileSHA256Hex(url)
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return CorrectionSyncFileFingerprint(modifiedAt: values.contentModificationDate,
                                             size: values.fileSize,
                                             sha256: digest)
    } catch {
        return nil
    }
}

/// Fingerprint for bytes this process just wrote to `url`. Content
/// hash and size come from the in-memory data — never from re-reading
/// the file, which races with a sync provider replacing it in the
/// write-to-fingerprint window and would swallow that remote change
/// until the next local edit. Only the modification date is read
/// back; if even that races, the SHA mismatch on the next scan still
/// detects the remote change.
func correctionSyncFingerprint(forWrittenData data: Data, at url: URL) -> CorrectionSyncFileFingerprint {
    var hasher = SHA256()
    hasher.update(data: data)
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate
    return CorrectionSyncFileFingerprint(modifiedAt: modifiedAt,
                                         size: data.count,
                                         sha256: digest)
}

private func correctionSyncFileSHA256Hex(_ url: URL) throws -> String {
    let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else {
        throw currentPOSIXError()
    }
    defer { _ = Darwin.close(fd) }

    var st = stat()
    guard Darwin.fstat(fd, &st) == 0 else {
        throw currentPOSIXError()
    }
    guard (st.st_mode & S_IFMT) == S_IFREG else {
        throw TranscriptCorrectionsTransferError.notRegularFile
    }
    guard st.st_size <= TranscriptCorrectionsTransfer.maxFileBytes else {
        throw TranscriptCorrectionsTransferError.fileTooLarge(Int(st.st_size),
                                                              TranscriptCorrectionsTransfer.maxFileBytes)
    }

    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    var hasher = SHA256()
    while true {
        guard let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty else {
            break
        }
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

func mergedTranscriptCorrectionsForSync(base: [TranscriptCorrection],
                                        local: [TranscriptCorrection],
                                        remote: [TranscriptCorrection]) -> TranscriptCorrectionSyncMergeResult {
    let base = normalizedTranscriptCorrections(base)
    let local = normalizedTranscriptCorrections(local)
    let remote = normalizedTranscriptCorrections(remote)

    func dictionaryBySource(_ corrections: [TranscriptCorrection]) -> [String: TranscriptCorrection] {
        Dictionary(uniqueKeysWithValues: corrections.map {
            (normalizedTranscriptCorrectionSource($0.source), $0)
        })
    }

    let baseBySource = dictionaryBySource(base)
    let localBySource = dictionaryBySource(local)
    let remoteBySource = dictionaryBySource(remote)

    var orderedSources: [String] = []
    var seenSources: Set<String> = []
    func appendSources(from corrections: [TranscriptCorrection]) {
        for correction in corrections {
            let key = normalizedTranscriptCorrectionSource(correction.source)
            if seenSources.insert(key).inserted {
                orderedSources.append(key)
            }
        }
    }

    appendSources(from: local)
    appendSources(from: remote)
    appendSources(from: base)

    var merged: [TranscriptCorrection] = []
    var conflicts: [String] = []

    for source in orderedSources {
        let baseline = baseBySource[source]
        let localCorrection = localBySource[source]
        let remoteCorrection = remoteBySource[source]

        let chosen: TranscriptCorrection?
        if localCorrection == remoteCorrection {
            chosen = localCorrection
        } else if localCorrection == baseline {
            chosen = remoteCorrection
        } else if remoteCorrection == baseline {
            chosen = localCorrection
        } else {
            conflicts.append(localCorrection?.source ?? remoteCorrection?.source ?? baseline?.source ?? source)
            continue
        }

        if let chosen {
            merged.append(chosen)
        }
    }

    return TranscriptCorrectionSyncMergeResult(corrections: merged,
                                               conflictingSources: conflicts)
}

// MARK: - Audio input devices

func audioObjectStringProperty(_ objectID: AudioObjectID,
                               selector: AudioObjectPropertySelector) -> String? {
    var address = AudioObjectPropertyAddress(mSelector: selector,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var rawValue: UnsafeRawPointer?
    var size = UInt32(MemoryLayout<UnsafeRawPointer?>.size)
    let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &rawValue)
    guard status == noErr, let rawValue else { return nil }
    let string = Unmanaged<CFString>.fromOpaque(rawValue).takeUnretainedValue() as String
    return string.isEmpty ? nil : string
}

func audioDeviceHasInputChannels(_ deviceID: AudioDeviceID) -> Bool {
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                             mScope: kAudioDevicePropertyScopeInput,
                                             mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
          size > 0 else { return false }

    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                               alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    let bufferList = raw.assumingMemoryBound(to: AudioBufferList.self)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferList) == noErr else {
        return false
    }

    let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
    return buffers.contains { $0.mNumberChannels > 0 }
}

func isDefaultAggregateAudioInputPreference(_ preference: String) -> Bool {
    let trimmed = preference.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.range(of: CORE_AUDIO_DEFAULT_AGGREGATE_PREFIX,
                         options: [.anchored, .caseInsensitive]) != nil
}

func normalizedInputDevicePreference(_ preference: String) -> String? {
    let trimmed = preference.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          trimmed.utf8.count <= MAX_INPUT_DEVICE_PREFERENCE_BYTES,
          !trimmed.unicodeScalars.contains(where: { $0.value == 0 }),
          !isDefaultAggregateAudioInputPreference(trimmed) else {
        return nil
    }
    return trimmed
}

func isDefaultAggregateAudioInputDevice(_ device: AudioInputDevice) -> Bool {
    isDefaultAggregateAudioInputPreference(device.uid)
        || isDefaultAggregateAudioInputPreference(device.name)
}

func availableAudioInputDevices() -> [AudioInputDevice] {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size) == noErr,
          size >= UInt32(MemoryLayout<AudioDeviceID>.size) else { return [] }

    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var ids = Array(repeating: AudioDeviceID(0), count: count)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                     &address, 0, nil, &size, &ids) == noErr else { return [] }

    return ids.compactMap { id in
        guard audioDeviceHasInputChannels(id),
              let uid = audioObjectStringProperty(id, selector: kAudioDevicePropertyDeviceUID),
              let name = audioObjectStringProperty(id, selector: kAudioObjectPropertyName) else {
            return nil
        }
        let device = AudioInputDevice(id: id, uid: uid, name: name)
        return isDefaultAggregateAudioInputDevice(device) ? nil : device
    }
    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
}

func audioInputDevice(matching preference: String,
                      in devices: [AudioInputDevice] = availableAudioInputDevices()) -> AudioInputDevice? {
    guard let trimmed = normalizedInputDevicePreference(preference) else { return nil }
    return devices.first { $0.uid == trimmed }
        ?? devices.first { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
}

// MARK: - Logger
//
// All output goes to stderr (line-buffered, so we don't lose lines
// across an abrupt exit) and to ~/Library/Logs/SuperDictate.log.

final class Logger: @unchecked Sendable {
    static let shared = Logger()
    private let url: URL
    private let q = DispatchQueue(label: "ParakeyLogger")

    var fileURL: URL { url }

    init() {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        url = logs.appendingPathComponent("SuperDictate.log")
    }

    func log(_ msg: String) {
        let stamp = ISO8601DateFormatter.timeOnly.string(from: Date())
        let line = "[\(stamp)] \(msg)\n"
        let data = Data(line.utf8)
        FileHandle.standardError.write(data)
        q.async { [url] in
            do {
                try appendPrivateLogData(data, to: url)
            } catch {
                let fallback = "Logger: file write failed: \(error.localizedDescription)\n"
                FileHandle.standardError.write(Data(fallback.utf8))
            }
        }
    }
}

func log(_ msg: String) { Logger.shared.log(msg) }

func superDictateApplicationSupportDirectory() throws -> URL {
    let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(APP_SUPPORT_DIR_NAME, isDirectory: true)
    try FileManager.default.createDirectory(at: url,
                                            withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    return url
}

struct AgentRuntimeState: Codable {
    var status: String
    var detail: String
    var updatedAt: TimeInterval
    var pid: Int32
    var isReady: Bool
    var isRecording: Bool
    var isTranscribing: Bool
    var speechModelReady: Bool
    var missingPermissions: [String]
    var hotkeyName: String
    var triggerMode: String
}

enum AgentRuntimeStateStore {
    static var url: URL {
        (try? superDictateApplicationSupportDirectory()
            .appendingPathComponent(AGENT_STATUS_FILE_NAME)) ??
        FileManager.default.temporaryDirectory.appendingPathComponent(AGENT_STATUS_FILE_NAME)
    }

    static func write(_ state: AgentRuntimeState) {
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: url, options: [.atomic])
        } catch {
            log("agent state write failed: \(error.localizedDescription)")
        }
    }

    static func read() -> AgentRuntimeState? {
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(AgentRuntimeState.self, from: data)
        } catch {
            return nil
        }
    }
}

enum SuperDictateControlPanelRegistry {
    static var url: URL {
        (try? superDictateApplicationSupportDirectory()
            .appendingPathComponent(CONTROL_PANEL_PID_FILE_NAME)) ??
        FileManager.default.temporaryDirectory.appendingPathComponent(CONTROL_PANEL_PID_FILE_NAME)
    }

    @MainActor
    static func activateExistingPanelIfPresent() -> Bool {
        guard let pid = currentPanelPID() else {
            return false
        }
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: [.activateAllWindows])
            return true
        }
        return false
    }

    static func terminateExistingPanelIfPresent() -> Bool {
        guard let pid = currentPanelPID() else { return false }
        if let app = NSRunningApplication(processIdentifier: pid),
           app.terminate() {
            return true
        }
        kill(pid, SIGTERM)
        return true
    }

    static func claimCurrentPanel() {
        do {
            try "\(getpid())\n".write(to: url, atomically: true, encoding: .utf8)
        } catch {
            log("control panel pid write failed: \(error.localizedDescription)")
        }
    }

    static func clearCurrentPanel() {
        guard let raw = try? String(contentsOf: url, encoding: .utf8),
              let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid == getpid() else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func currentPanelPID() -> Int32? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8),
              let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0,
              pid != getpid(),
              processIsAlive(pid: pid) else {
            return nil
        }
        return pid
    }

    private static func processIsAlive(pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}

struct ProcessRunResult {
    let status: Int32
    let output: String
}

enum SuperDictateAgentService {
    static var launchAgentURL: URL {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        return directory.appendingPathComponent("\(AGENT_LABEL).plist")
    }

    static var launchDomain: String { "gui/\(getuid())" }
    static var launchService: String { "\(launchDomain)/\(AGENT_LABEL)" }

    static func agentExecutablePath() -> String {
        Bundle.main.executablePath ??
        "\(INSTALLED_APP_BUNDLE_PATH)/Contents/MacOS/SuperDictate"
    }

    static func installAndStart() throws {
        try writeLaunchAgentPlist()
        _ = runLaunchctl(["bootstrap", launchDomain, launchAgentURL.path])
        _ = runLaunchctl(["enable", launchService])
        let kick = runLaunchctl(["kickstart", "-k", launchService])
        if kick.status != 0 && !isAgentRunning() {
            throw NSError(domain: "SuperDictateAgentService",
                          code: Int(kick.status),
                          userInfo: [NSLocalizedDescriptionKey: kick.output])
        }
    }

    static func restart() throws {
        stop()
        Thread.sleep(forTimeInterval: 0.35)
        try installAndStart()
    }

    static func stop() {
        _ = runLaunchctl(["bootout", launchDomain, launchAgentURL.path])
        terminateAgentProcesses()
        try? FileManager.default.removeItem(at: launchAgentURL)
        writeStoppedState()
    }

    static func isAgentRunning() -> Bool {
        if let state = AgentRuntimeStateStore.read(),
           state.pid > 0,
           state.pid != getpid(),
           processIsAlive(pid: state.pid) {
            return true
        }
        return !agentProcessIDs().isEmpty
    }

    static func agentProcessIDs() -> [Int32] {
        let result = run("/usr/bin/pgrep",
                         ["-f", "\(agentExecutablePath()) \(AGENT_ARGUMENT)"])
        guard result.status == 0 else { return [] }
        return result.output
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { $0 != getpid() }
    }

    private static func writeLaunchAgentPlist() throws {
        let directory = launchAgentURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])

        let logPath = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/SuperDictate-agent.launchd.log").path
        let plist: [String: Any] = [
            "Label": AGENT_LABEL,
            "ProgramArguments": [agentExecutablePath(), AGENT_ARGUMENT],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Interactive",
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist,
                                                      format: .xml,
                                                      options: 0)
        try data.write(to: launchAgentURL, options: [.atomic])
    }

    private static func terminateAgentProcesses() {
        for pid in agentProcessIDs() {
            kill(pid, SIGTERM)
        }
    }

    private static func processIsAlive(pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private static func writeStoppedState() {
        AgentRuntimeStateStore.write(
            AgentRuntimeState(status: "stopped",
                              detail: "Dictation service is stopped.",
                              updatedAt: Date().timeIntervalSince1970,
                              pid: 0,
                              isReady: false,
                              isRecording: false,
                              isTranscribing: false,
                              speechModelReady: false,
                              missingPermissions: [],
                              hotkeyName: Settings.shared.configuredHotkey.name,
                              triggerMode: Settings.shared.triggerMode.rawValue)
        )
    }

    private static func runLaunchctl(_ arguments: [String]) -> ProcessRunResult {
        run("/bin/launchctl", arguments)
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) -> ProcessRunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return ProcessRunResult(status: process.terminationStatus,
                                    output: String(data: data, encoding: .utf8) ?? "")
        } catch {
            return ProcessRunResult(status: 127, output: error.localizedDescription)
        }
    }
}

func privacySafeLogPath(_ path: String) -> String {
    privacySafeLogPath(URL(fileURLWithPath: path))
}

func privacySafeLogPath(_ url: URL) -> String {
    let name = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty || name == "/" ? "<local path>" : name
}

func privacySafeBundlePath(_ path: String) -> String {
    switch path {
    case "/Applications/SuperDictate.app", "/tmp/SuperDictate-dev.app":
        return path
    default:
        return privacySafeLogPath(path)
    }
}

private let PRIVATE_LOG_FILE_MODE = mode_t(S_IRUSR | S_IWUSR)
private let PRIVATE_HELPER_FILE_MODE = mode_t(S_IRUSR | S_IWUSR)

private func appendPrivateLogData(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    let flags = O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW
    let fd = Darwin.open(url.path, flags, PRIVATE_LOG_FILE_MODE)
    guard fd >= 0 else { throw currentPOSIXError() }
    defer { _ = Darwin.close(fd) }

    try validateSingleLinkRegularFileDescriptor(fd)

    guard Darwin.fchmod(fd, PRIVATE_LOG_FILE_MODE) == 0 else {
        throw currentPOSIXError()
    }

    try writeAllData(data, to: fd)
}

private func validateSingleLinkRegularFileDescriptor(_ fd: Int32) throws {
    var st = stat()
    guard Darwin.fstat(fd, &st) == 0 else {
        throw currentPOSIXError()
    }
    guard (st.st_mode & S_IFMT) == S_IFREG else {
        throw posixError(EFTYPE)
    }
    guard st.st_nlink == 1 else {
        throw posixError(EMLINK)
    }
}

private func writeAllData(_ data: Data, to fd: Int32) throws {
    try data.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress else { return }
        var offset = 0
        while offset < rawBuffer.count {
            let written = Darwin.write(fd,
                                       base.advanced(by: offset),
                                       rawBuffer.count - offset)
            if written < 0 {
                if errno == EINTR { continue }
                throw currentPOSIXError()
            }
            guard written > 0 else { throw POSIXError(.EIO) }
            offset += written
        }
    }
}

private func currentPOSIXError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}

private func posixError(_ code: Int32) -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
}

extension ISO8601DateFormatter {
    static let timeOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

// MARK: - Settings
//
// Thin wrapper around the app's standard NSUserDefaults domain, so
// settings persist at `~/Library/Preferences/com.local.superdictate.plist`.
// One property per user-visible setting; defaults are returned inline
// by each getter when the key is missing, rather than via a central
// `register()` call.

final class Settings: @unchecked Sendable {
    private static let keyHotkeyKeycode = "hotkey_keycode"
    private static let keyHotkeyModifiers = "hotkey_modifiers"
    private static let keyEnterHotkeyKeycode = "enter_hotkey_keycode"
    private static let keyEnterHotkeyModifiers = "enter_hotkey_modifiers"
    private static let keyHistoryHotkeyKeycode = "history_hotkey_keycode"
    private static let keyHistoryHotkeyModifiers = "history_hotkey_modifiers"
    private static let keyPrimaryCompletionBehavior = "primary_completion_behavior_v1"
    private static let keyAlternateCompletionEnabled = "alternate_completion_enabled_v1"
    private static let keyInterfaceLanguage = "interface_language"
    private static let keyTriggerMode = "trigger_mode"
    private static let keyPasteSuffix = "paste_suffix"
    private static let keyRecentTranscripts = "recent_transcripts"
    private static let keyRecentTranscriptHistory = "recent_transcript_history"
    private static let keyRecentTranscriptEntries = "recent_transcript_entries_v1"
    private static let keyDailyDictationUsage = "daily_dictation_usage_v1"
    private static let keyDidImportDictationUsageLog = "did_import_dictation_usage_log_v1"
    private static let keyShowRecordingWaveform = "show_recording_waveform"
    private static let keyRecordingHUDRecordingColor = "recording_hud_recording_color"
    private static let keyRecordingHUDTranscribingColor = "recording_hud_transcribing_color"
    private static let keyRecordingHUDBackgroundStyle = "recording_hud_background_style"
    private static let keyRecordingHUDSize = "recording_hud_size"
    private static let legacyKeyShowRecordingIndicator = "show_recording_indicator"
    private static let keyMuteWhileRecording = "mute_while_recording"
    private static let keyPlayFeedbackSounds = "play_feedback_sounds"
    private static let keyShowInDock = "show_in_dock"
    private static let keyInputDevice = "input_device"
    private static let keyCheckForUpdates = "check_for_updates"
    private static let keyLastUpdateCheckAt = "last_update_check_at"
    private static let keyLastUpdateCheckSource = "last_update_check_source"
    private static let keyLastUpdateCheckResult = "last_update_check_result"
    private static let keyLastUpdateCheckVersion = "last_update_check_version"
    private static let keyUpdateReminderPausedVersion = "update_reminder_paused_version"
    private static let keyUpdateReminderPausedUntil = "update_reminder_paused_until"
    private static let keyLastSeenVersion = "last_seen_version"
    private static let keySkippedVersions = "skipped_versions"
    private static let keyTranscriptCorrections = "transcript_corrections"
    private static let keyTranscriptCorrectionsSyncFile = "transcript_corrections_sync_file"
    private static let keyDictationLanguage = "dictation_language"
    private static let keySpeechModelProfile = "speech_model_profile"
    private static let keyInitialSpeechModelChoiceRequired = "initial_speech_model_choice_required"
    private static let keyRemoveFillerWords = "remove_filler_words"
    private static let keyActiveRunMarker = "active_run_marker"
    private static let keyAgentEnabled = "agent_enabled"

    private let defaults: UserDefaults

    static let shared = Settings()

    init() {
        self.defaults = .standard
    }

    @discardableResult
    func refreshFromDisk() -> Bool {
        defaults.synchronize()
    }

    var hotkeyKeycode: CGKeyCode {
        get {
            normalizedHotkeyKeycode(storedValue: defaults.object(forKey: Self.keyHotkeyKeycode))
                ?? DEFAULT_HOTKEY_KEYCODE
        }
        set {
            let normalized = normalizedHotkeyKeycode(storedValue: NSNumber(value: Int(newValue)))
                ?? DEFAULT_HOTKEY_KEYCODE
            defaults.set(Int(normalized), forKey: Self.keyHotkeyKeycode)
        }
    }

    var hotkeyModifiers: CGEventFlags {
        get {
            let raw = defaults.object(forKey: Self.keyHotkeyModifiers) as? NSNumber
            return CGEventFlags(rawValue: raw?.uint64Value ?? 0)
                .intersection(HOTKEY_SHORTCUT_MODIFIER_MASK)
        }
        set {
            defaults.set(NSNumber(value: newValue.intersection(HOTKEY_SHORTCUT_MODIFIER_MASK).rawValue),
                         forKey: Self.keyHotkeyModifiers)
        }
    }

    var configuredHotkey: HotkeyChoice {
        hotkeyChoice(forKeycode: hotkeyKeycode, modifiers: hotkeyModifiers)
    }

    func setConfiguredHotkey(_ choice: HotkeyChoice) {
        hotkeyKeycode = choice.keycode
        hotkeyModifiers = choice.requiredModifiers
    }

    var enterHotkeyKeycode: CGKeyCode {
        get {
            normalizedHotkeyKeycode(storedValue: defaults.object(forKey: Self.keyEnterHotkeyKeycode))
                ?? RIGHT_COMMAND_KEYCODE
        }
        set {
            let normalized = normalizedHotkeyKeycode(storedValue: NSNumber(value: Int(newValue)))
                ?? RIGHT_COMMAND_KEYCODE
            defaults.set(Int(normalized), forKey: Self.keyEnterHotkeyKeycode)
        }
    }

    var enterHotkeyModifiers: CGEventFlags {
        get {
            let raw = defaults.object(forKey: Self.keyEnterHotkeyModifiers) as? NSNumber
            if raw == nil { return .maskAlternate }
            return CGEventFlags(rawValue: raw?.uint64Value ?? 0)
                .intersection(HOTKEY_SHORTCUT_MODIFIER_MASK)
        }
        set {
            defaults.set(NSNumber(value: newValue.intersection(HOTKEY_SHORTCUT_MODIFIER_MASK).rawValue),
                         forKey: Self.keyEnterHotkeyModifiers)
        }
    }

    var configuredEnterHotkey: HotkeyChoice {
        hotkeyChoice(forKeycode: enterHotkeyKeycode, modifiers: enterHotkeyModifiers)
    }

    func setConfiguredEnterHotkey(_ choice: HotkeyChoice) {
        enterHotkeyKeycode = choice.keycode
        enterHotkeyModifiers = choice.requiredModifiers
    }

    var primaryCompletionBehavior: DictationCompletionBehavior {
        get {
            guard let raw = defaults.string(forKey: Self.keyPrimaryCompletionBehavior),
                  let behavior = DictationCompletionBehavior(rawValue: raw) else {
                // Preserve the behavior of releases before v0.2.35.
                return .insert
            }
            return behavior
        }
        set { defaults.set(newValue.rawValue, forKey: Self.keyPrimaryCompletionBehavior) }
    }

    var alternateCompletionEnabled: Bool {
        get {
            guard defaults.object(forKey: Self.keyAlternateCompletionEnabled) != nil else {
                // The alternate finish shortcut was always enabled before v0.2.35.
                return true
            }
            return defaults.bool(forKey: Self.keyAlternateCompletionEnabled)
        }
        set { defaults.set(newValue, forKey: Self.keyAlternateCompletionEnabled) }
    }

    var historyHotkeyKeycode: CGKeyCode {
        get {
            normalizedHotkeyKeycode(storedValue: defaults.object(forKey: Self.keyHistoryHotkeyKeycode))
                ?? RIGHT_COMMAND_KEYCODE
        }
        set {
            let normalized = normalizedHotkeyKeycode(storedValue: NSNumber(value: Int(newValue)))
                ?? RIGHT_COMMAND_KEYCODE
            defaults.set(Int(normalized), forKey: Self.keyHistoryHotkeyKeycode)
        }
    }

    var historyHotkeyModifiers: CGEventFlags {
        get {
            let raw = defaults.object(forKey: Self.keyHistoryHotkeyModifiers) as? NSNumber
            if raw == nil { return .maskShift }
            return CGEventFlags(rawValue: raw?.uint64Value ?? 0)
                .intersection(HOTKEY_SHORTCUT_MODIFIER_MASK)
        }
        set {
            defaults.set(NSNumber(value: newValue.intersection(HOTKEY_SHORTCUT_MODIFIER_MASK).rawValue),
                         forKey: Self.keyHistoryHotkeyModifiers)
        }
    }

    var configuredHistoryHotkey: HotkeyChoice {
        hotkeyChoice(forKeycode: historyHotkeyKeycode, modifiers: historyHotkeyModifiers)
    }

    func setConfiguredHistoryHotkey(_ choice: HotkeyChoice) {
        historyHotkeyKeycode = choice.keycode
        historyHotkeyModifiers = choice.requiredModifiers
    }

    var interfaceLanguage: InterfaceLanguage {
        get {
            guard let raw = defaults.string(forKey: Self.keyInterfaceLanguage),
                  let language = InterfaceLanguage(rawValue: raw) else {
                return .russian
            }
            return language
        }
        set { defaults.set(newValue.rawValue, forKey: Self.keyInterfaceLanguage) }
    }

    var triggerMode: TriggerMode {
        get {
            if let v = defaults.string(forKey: Self.keyTriggerMode), let m = TriggerMode(rawValue: v) {
                return m
            }
            return .toggle
        }
        set { defaults.set(newValue.rawValue, forKey: Self.keyTriggerMode) }
    }

    var agentEnabled: Bool {
        get {
            if defaults.object(forKey: Self.keyAgentEnabled) == nil { return true }
            return defaults.bool(forKey: Self.keyAgentEnabled)
        }
        set { defaults.set(newValue, forKey: Self.keyAgentEnabled) }
    }

    var pasteSuffix: PasteSuffix {
        get {
            if let v = defaults.string(forKey: Self.keyPasteSuffix), let s = PasteSuffix(rawValue: v) {
                return s
            }
            return .appendSpace
        }
        set { defaults.set(newValue.rawValue, forKey: Self.keyPasteSuffix) }
    }

    var recentTranscriptLimit: RecentTranscriptLimit {
        get {
            parseRecentTranscriptLimit(storedValue: defaults.object(forKey: Self.keyRecentTranscripts))
                ?? DEFAULT_RECENT_TRANSCRIPT_LIMIT
        }
        set { defaults.set(newValue.rawValue, forKey: Self.keyRecentTranscripts) }
    }

    var recentTranscriptHistory: [String] {
        get {
            let stored = defaults.stringArray(forKey: Self.keyRecentTranscriptHistory) ?? []
            return Array(
                stored.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .prefix(TRANSCRIPT_HISTORY_ARCHIVE_MAX_ENTRIES)
            )
        }
        set {
            let cleaned = Array(
                newValue.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .prefix(TRANSCRIPT_HISTORY_ARCHIVE_MAX_ENTRIES)
            )
            if cleaned.isEmpty {
                defaults.removeObject(forKey: Self.keyRecentTranscriptHistory)
            } else {
                defaults.set(cleaned, forKey: Self.keyRecentTranscriptHistory)
            }
            defaults.removeObject(forKey: Self.keyRecentTranscriptEntries)
        }
    }

    var recentTranscriptEntries: [TranscriptHistoryEntry] {
        get {
            if let data = defaults.data(forKey: Self.keyRecentTranscriptEntries),
               let decoded = try? JSONDecoder().decode([TranscriptHistoryEntry].self, from: data) {
                let cleaned = decoded.compactMap { entry -> TranscriptHistoryEntry? in
                    let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return nil }
                    return TranscriptHistoryEntry(
                        text: text,
                        transcriptionDurationSeconds: entry.transcriptionDurationSeconds,
                        asrTiming: entry.asrTiming
                    )
                }
                return limitedTranscriptHistoryArchive(cleaned)
            }

            return recentTranscriptHistory.map { TranscriptHistoryEntry(text: $0) }
        }
        set {
            let cleaned = limitedTranscriptHistoryArchive(
                newValue.compactMap { entry -> TranscriptHistoryEntry? in
                    let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return nil }
                    return TranscriptHistoryEntry(
                        text: text,
                        transcriptionDurationSeconds: entry.transcriptionDurationSeconds,
                        asrTiming: entry.asrTiming
                    )
                }
            )

            guard !cleaned.isEmpty else {
                defaults.removeObject(forKey: Self.keyRecentTranscriptEntries)
                defaults.removeObject(forKey: Self.keyRecentTranscriptHistory)
                return
            }

            if let data = try? JSONEncoder().encode(cleaned) {
                defaults.set(data, forKey: Self.keyRecentTranscriptEntries)
            }
            defaults.set(cleaned.map(\.text), forKey: Self.keyRecentTranscriptHistory)
        }
    }

    var dailyDictationUsage: [DailyDictationUsage] {
        get {
            guard let data = defaults.data(forKey: Self.keyDailyDictationUsage),
                  let decoded = try? JSONDecoder().decode([DailyDictationUsage].self, from: data) else {
                return []
            }
            return mergedDailyDictationUsage(decoded)
        }
        set {
            let cleaned = mergedDailyDictationUsage(newValue)
            guard !cleaned.isEmpty else {
                defaults.removeObject(forKey: Self.keyDailyDictationUsage)
                return
            }
            if let data = try? JSONEncoder().encode(cleaned) {
                defaults.set(data, forKey: Self.keyDailyDictationUsage)
            }
        }
    }

    var didImportDictationUsageLog: Bool {
        get { defaults.bool(forKey: Self.keyDidImportDictationUsageLog) }
        set { defaults.set(newValue, forKey: Self.keyDidImportDictationUsageLog) }
    }

    var showRecordingWaveform: Bool {
        get {
            if defaults.object(forKey: Self.keyShowRecordingWaveform) != nil {
                return defaults.bool(forKey: Self.keyShowRecordingWaveform)
            }
            if defaults.object(forKey: Self.legacyKeyShowRecordingIndicator) != nil {
                return defaults.bool(forKey: Self.legacyKeyShowRecordingIndicator)
            }
            return true
        }
        set { defaults.set(newValue, forKey: Self.keyShowRecordingWaveform) }
    }

    var recordingHUDRecordingColor: RecordingHUDAccentColor {
        get {
            guard let raw = defaults.string(forKey: Self.keyRecordingHUDRecordingColor),
                  let color = RecordingHUDAccentColor(rawValue: raw) else {
                return .red
            }
            return color
        }
        set {
            defaults.set(newValue.rawValue, forKey: Self.keyRecordingHUDRecordingColor)
            defaults.synchronize()
        }
    }

    var recordingHUDTranscribingColor: RecordingHUDAccentColor {
        get {
            guard let raw = defaults.string(forKey: Self.keyRecordingHUDTranscribingColor),
                  let color = RecordingHUDAccentColor(rawValue: raw) else {
                return .blue
            }
            return color
        }
        set {
            defaults.set(newValue.rawValue, forKey: Self.keyRecordingHUDTranscribingColor)
            defaults.synchronize()
        }
    }

    var recordingHUDBackgroundStyle: RecordingHUDBackgroundStyle {
        get {
            guard let raw = defaults.string(forKey: Self.keyRecordingHUDBackgroundStyle),
                  let style = RecordingHUDBackgroundStyle(rawValue: raw) else {
                return .system
            }
            return style
        }
        set {
            defaults.set(newValue.rawValue, forKey: Self.keyRecordingHUDBackgroundStyle)
            defaults.synchronize()
        }
    }

    var recordingHUDSize: RecordingHUDSize {
        get {
            guard let raw = defaults.string(forKey: Self.keyRecordingHUDSize),
                  let size = RecordingHUDSize(rawValue: raw) else {
                return .standard
            }
            return size
        }
        set {
            defaults.set(newValue.rawValue, forKey: Self.keyRecordingHUDSize)
            defaults.synchronize()
        }
    }

    var muteWhileRecording: Bool {
        get {
            if defaults.object(forKey: Self.keyMuteWhileRecording) == nil { return true }
            return defaults.bool(forKey: Self.keyMuteWhileRecording)
        }
        set { defaults.set(newValue, forKey: Self.keyMuteWhileRecording) }
    }

    var playFeedbackSounds: Bool {
        get {
            if defaults.object(forKey: Self.keyPlayFeedbackSounds) == nil { return true }
            return defaults.bool(forKey: Self.keyPlayFeedbackSounds)
        }
        set { defaults.set(newValue, forKey: Self.keyPlayFeedbackSounds) }
    }

    var showInDock: Bool {
        get {
            if defaults.object(forKey: Self.keyShowInDock) == nil { return false }
            return defaults.bool(forKey: Self.keyShowInDock)
        }
        set { defaults.set(newValue, forKey: Self.keyShowInDock) }
    }

    var inputDevice: String {
        get {
            guard let raw = defaults.string(forKey: Self.keyInputDevice),
                  let normalized = normalizedInputDevicePreference(raw) else {
                return ""
            }
            return normalized
        }
        set {
            if let normalized = normalizedInputDevicePreference(newValue) {
                defaults.set(normalized, forKey: Self.keyInputDevice)
            } else {
                defaults.removeObject(forKey: Self.keyInputDevice)
            }
        }
    }

    var checkForUpdates: Bool {
        get {
            if defaults.object(forKey: Self.keyCheckForUpdates) == nil { return false }
            return defaults.bool(forKey: Self.keyCheckForUpdates)
        }
        set { defaults.set(newValue, forKey: Self.keyCheckForUpdates) }
    }

    var lastUpdateCheckAt: Date? {
        get { defaults.object(forKey: Self.keyLastUpdateCheckAt) as? Date }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Self.keyLastUpdateCheckAt)
            } else {
                defaults.removeObject(forKey: Self.keyLastUpdateCheckAt)
            }
        }
    }

    var lastUpdateCheckSource: UpdateCheckSource? {
        get {
            guard let raw = defaults.string(forKey: Self.keyLastUpdateCheckSource) else {
                return nil
            }
            return UpdateCheckSource(rawValue: raw)
        }
        set {
            if let newValue {
                defaults.set(newValue.rawValue, forKey: Self.keyLastUpdateCheckSource)
            } else {
                defaults.removeObject(forKey: Self.keyLastUpdateCheckSource)
            }
        }
    }

    var lastUpdateCheckResult: UpdateCheckResult? {
        get {
            guard let raw = defaults.string(forKey: Self.keyLastUpdateCheckResult) else {
                return nil
            }
            return UpdateCheckResult(rawValue: raw)
        }
        set {
            if let newValue {
                defaults.set(newValue.rawValue, forKey: Self.keyLastUpdateCheckResult)
            } else {
                defaults.removeObject(forKey: Self.keyLastUpdateCheckResult)
            }
        }
    }

    var lastUpdateCheckVersion: String {
        get {
            guard let raw = defaults.string(forKey: Self.keyLastUpdateCheckVersion),
                  let normalized = normalizedStoredAppVersion(raw) else {
                return ""
            }
            return normalized
        }
        set {
            if let normalized = normalizedStoredAppVersion(newValue) {
                defaults.set(normalized, forKey: Self.keyLastUpdateCheckVersion)
            } else {
                defaults.removeObject(forKey: Self.keyLastUpdateCheckVersion)
            }
        }
    }

    /// "Remind me later" pause state, persisted so a relaunch inside
    /// the 24 h window does not re-prompt ~30 s after launch. Both
    /// halves are validated independently and corrupt stored values
    /// degrade to nil; ParakeyApp treats a missing half as "no pause"
    /// and clears the leftover at startup.
    var updateReminderPausedVersion: String? {
        get {
            guard let raw = defaults.string(forKey: Self.keyUpdateReminderPausedVersion),
                  let normalized = normalizedStoredAppVersion(raw) else {
                return nil
            }
            return normalized
        }
        set {
            if let newValue, let normalized = normalizedStoredAppVersion(newValue) {
                defaults.set(normalized, forKey: Self.keyUpdateReminderPausedVersion)
            } else {
                defaults.removeObject(forKey: Self.keyUpdateReminderPausedVersion)
            }
        }
    }

    var updateReminderPausedUntil: Date? {
        get {
            normalizedUpdateReminderPauseExpiry(
                storedValue: defaults.object(forKey: Self.keyUpdateReminderPausedUntil)
            )
        }
        set {
            if let newValue,
               normalizedUpdateReminderPauseExpiry(storedValue: newValue) != nil {
                defaults.set(newValue, forKey: Self.keyUpdateReminderPausedUntil)
            } else {
                defaults.removeObject(forKey: Self.keyUpdateReminderPausedUntil)
            }
        }
    }

    var lastSeenVersion: String {
        get {
            guard let raw = defaults.string(forKey: Self.keyLastSeenVersion),
                  let normalized = normalizedStoredAppVersion(raw) else {
                return ""
            }
            return normalized
        }
        set {
            if let normalized = normalizedStoredAppVersion(newValue) {
                defaults.set(normalized, forKey: Self.keyLastSeenVersion)
            } else {
                defaults.removeObject(forKey: Self.keyLastSeenVersion)
            }
        }
    }

    var skippedVersions: [String] {
        get {
            normalizedSkippedUpdateVersions(
                (defaults.array(forKey: Self.keySkippedVersions) as? [String]) ?? []
            )
        }
        set {
            let versions = normalizedSkippedUpdateVersions(newValue)
            if versions.isEmpty {
                defaults.removeObject(forKey: Self.keySkippedVersions)
            } else {
                defaults.set(versions, forKey: Self.keySkippedVersions)
            }
        }
    }

    var transcriptCorrections: [TranscriptCorrection] {
        get {
            guard let data = defaults.data(forKey: Self.keyTranscriptCorrections) else { return [] }
            do {
                return try TranscriptCorrectionsTransfer.decode(data)
            } catch {
                log("settings: transcript correction decode failed: \(error)")
                return []
            }
        }
        set { storeTranscriptCorrections(newValue) }
    }

    /// Persists corrections and reports failure to the caller instead
    /// of swallowing it. With the per-field/per-count caps the encoded
    /// set always fits maxFileBytes in practice (see its derivation
    /// comment), but if encoding or the size guard ever fails the
    /// user's edit must not silently vanish — UI entry points alert on
    /// a non-nil return. The property setter above keeps the
    /// fire-and-forget shape (and the log below) for internal callers.
    @discardableResult
    func storeTranscriptCorrections(_ newValue: [TranscriptCorrection]) -> Error? {
        let corrections = normalizedTranscriptCorrections(newValue)
        guard !corrections.isEmpty else {
            defaults.removeObject(forKey: Self.keyTranscriptCorrections)
            return nil
        }
        do {
            let data = try JSONEncoder().encode(corrections)
            try TranscriptCorrectionsTransfer.validateTransferSize(data.count)
            defaults.set(data, forKey: Self.keyTranscriptCorrections)
            return nil
        } catch {
            log("settings: transcript correction encode failed: \(error)")
            return error
        }
    }

    var transcriptCorrectionsSyncFile: String {
        get {
            guard let raw = defaults.string(forKey: Self.keyTranscriptCorrectionsSyncFile),
                  let normalized = normalizedCorrectionSyncFilePath(raw) else {
                return ""
            }
            return normalized
        }
        set {
            if let normalized = normalizedCorrectionSyncFilePath(newValue) {
                defaults.set(normalized, forKey: Self.keyTranscriptCorrectionsSyncFile)
            } else {
                defaults.removeObject(forKey: Self.keyTranscriptCorrectionsSyncFile)
            }
        }
    }

    var dictationLanguage: DictationLanguage {
        get {
            if let v = defaults.string(forKey: Self.keyDictationLanguage),
               let lang = DictationLanguage(rawValue: v) {
                return lang
            }
            return .auto
        }
        set { defaults.set(newValue.rawValue, forKey: Self.keyDictationLanguage) }
    }

    var speechModelProfile: SpeechModelProfile {
        get {
            productionSpeechModelProfile(rawValue: defaults.string(forKey: Self.keySpeechModelProfile))
        }
        set { defaults.set(newValue.productionProfile.rawValue, forKey: Self.keySpeechModelProfile) }
    }

    @discardableResult
    func normalizeSpeechModelProfileForCurrentBuild() -> Bool {
        var changed = false
        if let raw = defaults.string(forKey: Self.keySpeechModelProfile) {
            let normalized = productionSpeechModelProfile(rawValue: raw)
            if normalized.rawValue != raw {
                defaults.set(SpeechModelProfile.productionDefault.rawValue,
                             forKey: Self.keySpeechModelProfile)
                changed = true
            }
        }
        if defaults.object(forKey: Self.keyInitialSpeechModelChoiceRequired) != nil {
            defaults.removeObject(forKey: Self.keyInitialSpeechModelChoiceRequired)
            changed = true
        }
        return changed
    }

    var removeFillerWords: Bool {
        get { defaults.bool(forKey: Self.keyRemoveFillerWords) }
        set { defaults.set(newValue, forKey: Self.keyRemoveFillerWords) }
    }

    var hasActiveRunMarker: Bool {
        get { defaults.bool(forKey: Self.keyActiveRunMarker) }
        set {
            if newValue {
                defaults.set(true, forKey: Self.keyActiveRunMarker)
            } else {
                defaults.removeObject(forKey: Self.keyActiveRunMarker)
            }
        }
    }
}

// MARK: - Permissions

enum Permission: String, CaseIterable, Equatable {
    case microphone = "Microphone"
    case accessibility = "Accessibility"
    case inputMonitoring = "Input Monitoring"
}

private enum ReadinessTransition: Equatable {
    case rebuildMenuOnly
    case blockForPermissions([Permission])
    case startHotkeyListener
}

private func readinessTransition(
    isReady: Bool,
    isCoreRuntimeReady: Bool,
    missingPermissions: [Permission]
) -> ReadinessTransition {
    if isReady {
        return missingPermissions.isEmpty
            ? .rebuildMenuOnly
            : .blockForPermissions(missingPermissions)
    }

    guard isCoreRuntimeReady else {
        return .rebuildMenuOnly
    }

    return missingPermissions.isEmpty
        ? .startHotkeyListener
        : .blockForPermissions(missingPermissions)
}

private enum AudioRouteChangeAction: Equatable {
    case ignore
    case rebuildMenuOnly
    case deferRefresh
    case restartNow
}

private func audioRouteChangeAction(isTerminating: Bool,
                                    isRestartingAudioInput: Bool,
                                    isCoreRuntimeReady: Bool,
                                    isRecording: Bool,
                                    isBusy: Bool,
                                    hasStartupTask: Bool) -> AudioRouteChangeAction {
    guard !isTerminating, !isRestartingAudioInput else { return .ignore }
    guard isCoreRuntimeReady else { return .rebuildMenuOnly }
    guard !isRecording, !isBusy, !hasStartupTask else { return .deferRefresh }
    return .restartNow
}

private func audioConfigurationChangeIsSuppressed(now: TimeInterval,
                                                  suppressedUntil: TimeInterval?) -> Bool {
    guard let suppressedUntil else { return false }
    return now < suppressedUntil
}

private enum WakeRuntimeRecoveryAction: Equatable {
    case ignore
    case deferUntilIdle
    case startAudioRuntime
    case startFullStartup
}

private func shouldResumeRuntimeAfterSystemSleep(isTerminating: Bool,
                                                 isCoreRuntimeReady: Bool,
                                                 isReady: Bool,
                                                 isRecording: Bool,
                                                 audioIsRunning: Bool) -> Bool {
    guard !isTerminating else { return false }
    return isCoreRuntimeReady || isReady || isRecording || audioIsRunning
}

private func wakeRuntimeRecoveryAction(shouldResumeAfterWake: Bool,
                                       isTerminating: Bool,
                                       hasStartupTask: Bool,
                                       isBusy: Bool,
                                       isSpeechModelReady: Bool) -> WakeRuntimeRecoveryAction {
    guard shouldResumeAfterWake, !isTerminating else { return .ignore }
    guard !hasStartupTask, !isBusy else { return .deferUntilIdle }
    return isSpeechModelReady ? .startAudioRuntime : .startFullStartup
}

private enum StartupFailureStage {
    case speechModel
    case audioInput
    case hotkeyListener

    var statusTitle: String {
        switch self {
        case .speechModel: return "Speech model failed to load"
        case .audioInput: return "Audio input failed to start"
        case .hotkeyListener: return "Hotkey listener failed to start"
        }
    }

    var retryTitle: String {
        switch self {
        case .speechModel: return "Retry Loading Speech Model"
        case .audioInput: return "Retry Audio Startup"
        case .hotkeyListener: return "Retry Hotkey Startup"
        }
    }
}

private struct StartupFailure {
    let stage: StartupFailureStage
    let detail: String

    var statusTitle: String { stage.statusTitle }
    var retryTitle: String { stage.retryTitle }
}

private enum PreviousExitNoticeAction: Equatable {
    case none
    case showNotice
}

private func previousExitNoticeAction(previousRunWasActive: Bool) -> PreviousExitNoticeAction {
    previousRunWasActive ? .showNotice : .none
}

private func speechModelFailureDetail(errorDescription: String) -> String {
    let lower = errorDescription.lowercased()
    let looksLikeIntegrityFailure = [
        "sha",
        "hash",
        "integrity",
        "verification",
        "verified",
        "corrupt",
        "incomplete",
    ].contains { lower.contains($0) }
    let looksLikeNetworkFailure = [
        "download",
        "network",
        "internet",
        "offline",
        "timed out",
        "timeout",
        "could not connect",
        "cannot connect",
        "not connected",
        "host",
        "url",
    ].contains { lower.contains($0) }
    let looksLikeDiskSpaceFailure = [
        "disk space",
        "free some disk",
        "available:",
        "needed:",
    ].contains { lower.contains($0) }

    if looksLikeDiskSpaceFailure {
        return errorDescription
    }

    if looksLikeIntegrityFailure {
        return """
        \(errorDescription)

        The local speech model cache may be incomplete or corrupt. Use Support → Reset Speech Model Cache… to delete it and download a fresh verified copy.
        """
    }
    if looksLikeNetworkFailure {
        return """
        \(errorDescription)

        Parakey needs a one-time download of the local speech model. Check your network connection and retry; audio is not uploaded.
        """
    }
    return """
    \(errorDescription)

    If this keeps happening, use Support → Reset Speech Model Cache… to download a fresh verified copy, then Copy Diagnostics for a GitHub issue.
    """
}

private func fourCharacterCodeString(forRawOSStatus raw: UInt32) -> String? {
    let bytes = [
        UInt8((raw >> 24) & 0xff),
        UInt8((raw >> 16) & 0xff),
        UInt8((raw >> 8) & 0xff),
        UInt8(raw & 0xff),
    ]
    guard bytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7e }) else { return nil }
    return String(bytes: bytes, encoding: .ascii)
}

private func formattedOSStatusCode(_ code: Int) -> String {
    let raw = UInt32(bitPattern: Int32(truncatingIfNeeded: code))
    let hex = String(format: "0x%08x", raw)
    if let fourCharacterCode = fourCharacterCodeString(forRawOSStatus: raw) {
        return "OSStatus \(code) (\(hex), '\(fourCharacterCode)')"
    }
    return "OSStatus \(code) (\(hex))"
}

private func formattedOSStatus(_ status: OSStatus) -> String {
    formattedOSStatusCode(Int(status))
}

private func coreAudioOSStatusCode(from error: NSError) -> Int? {
    let domain = error.domain.lowercased()
    guard error.domain == NSOSStatusErrorDomain
        || domain.contains("coreaudio")
        || domain.contains("avfaudio") else {
        return nil
    }
    return error.code
}

private func stringValue(fromUserInfoValue value: Any?) -> String? {
    guard let value else { return nil }
    let text = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty || text == "nil" ? nil : text
}

private func failedAudioCallDescription(from error: NSError) -> String? {
    for key in ["failed call", "failedCall", "AVAudioEngineFailedCall"] {
        if let text = stringValue(fromUserInfoValue: error.userInfo[key]) {
            return text
        }
    }

    for (key, value) in error.userInfo {
        let lower = key.lowercased()
        guard lower.contains("failed"), lower.contains("call") else { continue }
        if let text = stringValue(fromUserInfoValue: value) {
            return text
        }
    }
    return nil
}

private func audioStartupErrorDescription(_ error: Error) -> String {
    let nsError = error as NSError
    var lines = [nsError.localizedDescription]
    if let statusCode = coreAudioOSStatusCode(from: nsError) {
        lines.append("CoreAudio \(formattedOSStatusCode(statusCode)).")
    }
    if let failedCall = failedAudioCallDescription(from: nsError) {
        lines.append("Failed call: \(failedCall).")
    }
    return lines.joined(separator: "\n")
}

private func singleLineLogDetail(_ text: String) -> String {
    text.components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: " | ")
}

private func audioInputFailureDetail(errorDescription: String) -> String {
    let lower = errorDescription.lowercased()
    let looksLikeCoreAudioFailure = lower.contains("coreaudio")
        || lower.contains("avfaudio")
        || lower.contains("osstatus")
        || lower.contains("kaustartio")
    guard looksLikeCoreAudioFailure else { return errorDescription }

    return """
    \(errorDescription)

    Parakey rebuilt the audio engine and retried microphone startup, but CoreAudio is still refusing to start the input unit. If this began after sleep/wake or an audio-device change, restart CoreAudio with sudo killall coreaudiod or reboot the Mac, then retry audio startup.
    """
}

private func startupFailureDetail(stage: StartupFailureStage, errorDescription: String) -> String {
    switch stage {
    case .speechModel:
        return speechModelFailureDetail(errorDescription: errorDescription)
    case .audioInput:
        return audioInputFailureDetail(errorDescription: errorDescription)
    case .hotkeyListener:
        return errorDescription
    }
}

private func startupFailureDetail(stage: StartupFailureStage, error: Error) -> String {
    let errorDescription = stage == .audioInput
        ? audioStartupErrorDescription(error)
        : error.localizedDescription
    return startupFailureDetail(stage: stage, errorDescription: errorDescription)
}

private func startupFailureLogDetail(stage: StartupFailureStage, error: Error) -> String {
    let detail = stage == .audioInput
        ? audioStartupErrorDescription(error)
        : String(describing: error)
    return singleLineLogDetail(detail)
}

private func audioStartupRetryDelaySeconds(afterFailedAttempt failedAttempt: Int,
                                           retryDelays: [UInt64] = AUDIO_START_RETRY_DELAYS_SECONDS) -> UInt64? {
    guard failedAttempt > 0, failedAttempt <= retryDelays.count else { return nil }
    return retryDelays[failedAttempt - 1]
}

private func audioStartupRetryStatusTitle(nextAttempt: Int,
                                          totalAttempts: Int,
                                          delaySeconds: UInt64) -> String {
    "Audio input failed; retrying in \(delaySeconds)s (\(nextAttempt)/\(totalAttempts))…"
}

private struct SetupChecklistRowState: Equatable {
    let detail: String
    let status: String
    let buttonTitle: String?
}

private func speechModelSetupRowState(profile: SpeechModelProfile,
                                      isSpeechModelReady: Bool,
                                      isStartupInProgress: Bool,
                                      startupStatusTitle: String,
                                      failure: StartupFailure?) -> SetupChecklistRowState {
    if let failure, failure.stage == .speechModel {
        return SetupChecklistRowState(detail: failure.detail,
                                      status: "Needs retry",
                                      buttonTitle: "Retry")
    }
    if isSpeechModelReady {
        return SetupChecklistRowState(detail: profile.setupReadyDetail,
                                      status: "Ready",
                                      buttonTitle: nil)
    }
    if isStartupInProgress {
        return SetupChecklistRowState(detail: startupStatusTitle,
                                      status: "Loading",
                                      buttonTitle: nil)
    }
    return SetupChecklistRowState(detail: "The speech model loads before dictation can start.",
                                  status: "Waiting",
                                  buttonTitle: nil)
}

private func audioInputSetupRowState(isSpeechModelReady: Bool,
                                     isCoreRuntimeReady: Bool,
                                     isStartupInProgress: Bool,
                                     startupStatusTitle: String = "Starting audio input…",
                                     failure: StartupFailure?) -> SetupChecklistRowState {
    if let failure, failure.stage == .audioInput {
        return SetupChecklistRowState(detail: failure.detail,
                                      status: "Needs retry",
                                      buttonTitle: "Retry")
    }
    if isCoreRuntimeReady {
        return SetupChecklistRowState(detail: "Microphone capture is ready.",
                                      status: "Ready",
                                      buttonTitle: nil)
    }
    if !isSpeechModelReady {
        return SetupChecklistRowState(detail: "Available after the speech model loads.",
                                      status: "Waiting",
                                      buttonTitle: nil)
    }
    if isStartupInProgress {
        return SetupChecklistRowState(detail: startupStatusTitle,
                                      status: "Starting",
                                      buttonTitle: nil)
    }
    return SetupChecklistRowState(detail: "Audio input starts before dictation can begin.",
                                  status: "Waiting",
                                  buttonTitle: nil)
}

private func hotkeySetupRowState(isReady: Bool,
                                 hotkeyTestSucceeded: Bool,
                                 triggerMode: TriggerMode,
                                 hotkeyName: String,
                                 failure: StartupFailure?) -> SetupChecklistRowState {
    if let failure, failure.stage == .hotkeyListener {
        return SetupChecklistRowState(detail: failure.detail,
                                      status: "Needs retry",
                                      buttonTitle: "Retry")
    }

    let verb = triggerMode == .hold ? "Hold" : "Press"
    if !isReady {
        return SetupChecklistRowState(detail: "Available after the model, audio input, and permissions are ready.",
                                      status: "Waiting",
                                      buttonTitle: nil)
    }
    if hotkeyTestSucceeded {
        return SetupChecklistRowState(detail: "\(verb) \(hotkeyName) to dictate.",
                                      status: "Detected",
                                      buttonTitle: nil)
    }
    return SetupChecklistRowState(detail: "\(verb) \(hotkeyName). A quick tap is enough to confirm the hotkey.",
                                  status: "Ready to test",
                                  buttonTitle: nil)
}

@MainActor
final class Permissions {
    static func isGranted(_ p: Permission) -> Bool {
        switch p {
        case .microphone:
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .accessibility:
            return AXIsProcessTrusted()
        case .inputMonitoring:
            return CGPreflightListenEventAccess()
        }
    }

    /// Trigger the system prompt or, if previously denied, push the
    /// user toward the right Settings pane. Returns immediately;
    /// actual grant happens asynchronously.
    static func request(_ p: Permission) {
        switch p {
        case .microphone:
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            if status == .denied {
                openSettingsPane("Privacy_Microphone")
            } else {
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    log("Microphone request: granted=\(granted)")
                }
            }
        case .accessibility:
            // The AX-trust-with-prompt API shows a native dialog
            // when status is undetermined, falls through silently if
            // already granted. We also open Settings as a fallback
            // for the previously-denied case.
            // kAXTrustedCheckOptionPrompt is an Apple-defined CFStringRef.
            // Swift 6 strict concurrency complains about referencing the
            // global directly from an @MainActor method; bridge via a
            // string literal that matches its documented value.
            let key = "AXTrustedCheckOptionPrompt"
            _ = AXIsProcessTrustedWithOptions([key: kCFBooleanTrue!] as CFDictionary)
            openSettingsPane("Privacy_Accessibility")
        case .inputMonitoring:
            // CGRequestListenEventAccess is the canonical request
            // path for CGEventTap clients. On macOS 26 it registers
            // the app in the Input Monitoring list and shows a
            // prompt OR opens Settings as appropriate.
            _ = CGRequestListenEventAccess()
            openSettingsPane("Privacy_ListenEvent")
        }
    }

    private static func openSettingsPane(_ subpath: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(subpath)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Hotkey listener
//
// Global event tap on the keyDown / keyUp / flagsChanged stream.
// Right Option is a modifier so it doesn't fire keyDown — we watch
// flagsChanged and diff the .option flag.

private struct HotkeyEventSnapshot: Sendable {
    let typeRawValue: UInt32
    let keycode: CGKeyCode
    let flagsRawValue: UInt64
    let isAutoRepeat: Bool

    var flags: CGEventFlags {
        CGEventFlags(rawValue: flagsRawValue)
    }
}

private enum HotkeyRecordingDecision: Equatable {
    case accept(HotkeyChoice)
    case reject(String)
    case ignore
}

private enum HotkeyPreferenceUpdateResult: Equatable {
    case saved(HotkeyChoice)
    case rejected(String)
    case rolledBack(previous: HotkeyChoice, message: String)
}

private func hotkeyPreferenceUpdateResult(
    requested: HotkeyChoice,
    previous: HotkeyChoice,
    persisted: HotkeyChoice
) -> HotkeyPreferenceUpdateResult {
    guard let recordable = recordableHotkeyChoice(forKeycode: requested.keycode,
                                                  modifiers: requested.requiredModifiers) else {
        return .rejected("That key cannot be used for dictation.")
    }

    guard persisted == recordable else {
        return .rolledBack(
            previous: previous,
            message: "Parakey could not save that hotkey, so it kept \(previous.name)."
        )
    }

    return .saved(recordable)
}

private enum HotkeyRecorderRestartAction: Equatable {
    case none
    case restoredListener
    case recordFailure
}

private func hotkeyRecorderRestartAction(
    shouldRestoreHotkeyTap: Bool,
    isTerminating: Bool,
    restartSucceeded: Bool
) -> HotkeyRecorderRestartAction {
    guard shouldRestoreHotkeyTap, !isTerminating else { return .none }
    return restartSucceeded ? .restoredListener : .recordFailure
}

private func hotkeyRecordingDecision(for event: HotkeyEventSnapshot) -> HotkeyRecordingDecision {
    if event.isAutoRepeat { return .ignore }

    if event.typeRawValue == CGEventType.flagsChanged.rawValue {
        guard let baseChoice = MODIFIER_HOTKEY_CHOICES.first(where: { $0.keycode == event.keycode }),
              let mask = baseChoice.modifierFlag,
              event.flags.contains(mask) else {
            return .ignore
        }
        guard let choice = recordableHotkeyChoice(forKeycode: event.keycode,
                                                  modifiers: event.flags) else {
            return .ignore
        }
        return .accept(choice)
    }

    guard event.typeRawValue == CGEventType.keyDown.rawValue else { return .ignore }
    guard let choice = recordableHotkeyChoice(
        forKeycode: event.keycode,
        modifiers: event.flags.intersection(HOTKEY_SHORTCUT_MODIFIER_MASK)
    ),
          !choice.isModifier else {
        return .reject("Escape is reserved for canceling dictation. Choose another key or shortcut.")
    }
    return .accept(choice)
}

private enum HotkeyRecorderCaptureResult: Equatable {
    case candidate(HotkeyChoice)
    case reject(String)
    case cancel
    case ignore
}

private struct HotkeyRecorderCaptureState {
    mutating func consume(_ event: HotkeyEventSnapshot) -> HotkeyRecorderCaptureResult {
        if event.typeRawValue == CGEventType.keyDown.rawValue,
           event.keycode == ESCAPE_KEYCODE {
            return .cancel
        }

        switch hotkeyRecordingDecision(for: event) {
        case .accept(let choice):
            return .candidate(choice)
        case .reject(let message):
            return .reject(message)
        case .ignore:
            return .ignore
        }
    }
}

@MainActor
private final class HotkeyRecorderController: NSObject, NSWindowDelegate {
    private let language: InterfaceLanguage
    private let panel: NSPanel
    private let status: NSTextField
    private let saveButton: NSButton
    private var captureState = HotkeyRecorderCaptureState()
    private var selected: HotkeyChoice?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fallbackMonitor: Any?
    private var completion: ((HotkeyChoice?) -> Void)?
    private var isFinished = false

    init(language: InterfaceLanguage,
         titleOverride: String? = nil,
         completion: @escaping (HotkeyChoice?) -> Void) {
        self.language = language
        self.completion = completion
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 230),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        status = NSTextField(labelWithString: localizedText(
            "Ничего не выбрано",
            "Nothing selected",
            language: language
        ))
        saveButton = NSButton(title: localizedText("Сохранить", "Save", language: language),
                              target: nil,
                              action: nil)
        super.init()

        panel.title = "SuperDictate"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.delegate = self

        let title = NSTextField(labelWithString: titleOverride ?? localizedText(
            "Новое сочетание для диктовки",
            "Record Dictation Shortcut",
            language: language
        ))
        title.font = .systemFont(ofSize: 19, weight: .semibold)

        let instruction = NSTextField(wrappingLabelWithString: localizedText(
            "Нажмите одну клавишу или любое сочетание. Изменение применится только после «Сохранить». Escape закроет окно без изменений.",
            "Press one key or any shortcut. It changes only after you click Save. Escape closes without changes.",
            language: language
        ))
        instruction.font = .systemFont(ofSize: 13)
        instruction.textColor = .secondaryLabelColor

        status.font = .monospacedSystemFont(ofSize: 14, weight: .semibold)
        status.textColor = .labelColor
        status.lineBreakMode = .byTruncatingMiddle

        let statusContainer = NSBox()
        statusContainer.boxType = .custom
        statusContainer.cornerRadius = 7
        statusContainer.borderWidth = 1
        statusContainer.borderColor = .separatorColor
        statusContainer.fillColor = .controlBackgroundColor
        statusContainer.contentViewMargins = NSSize(width: 14, height: 10)
        statusContainer.contentView = status
        statusContainer.heightAnchor.constraint(equalToConstant: 42).isActive = true

        saveButton.target = self
        saveButton.action = #selector(save(_:))
        saveButton.bezelStyle = .rounded
        saveButton.isEnabled = false
        saveButton.keyEquivalent = ""

        let cancelButton = NSButton(
            title: localizedText("Отмена", "Cancel", language: language),
            target: self,
            action: #selector(cancelClicked(_:))
        )
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = ""

        let buttonSpacer = NSView()
        buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttonRow = NSStackView(views: [buttonSpacer, cancelButton, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 10

        let stack = NSStackView(views: [title, instruction, statusContainer, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        instruction.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        statusContainer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let contentView = NSView()
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -18),
        ])
        panel.contentView = contentView
    }

    func present(relativeTo parent: NSWindow? = nil) {
        guard !isFinished else { return }
        if eventTap != nil || fallbackMonitor != nil {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        if !startEventTap() {
            log("Hotkey recorder: CGEventTap unavailable; using AppKit fallback")
            fallbackMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.keyDown, .keyUp, .flagsChanged]
            ) { [weak self] event in
                let typeRawValue: UInt32
                switch event.type {
                case .flagsChanged: typeRawValue = CGEventType.flagsChanged.rawValue
                case .keyUp: typeRawValue = CGEventType.keyUp.rawValue
                default: typeRawValue = CGEventType.keyDown.rawValue
                }
                self?.consume(HotkeyEventSnapshot(
                    typeRawValue: typeRawValue,
                    keycode: CGKeyCode(event.keyCode),
                    flagsRawValue: hotkeyFlags(from: event.modifierFlags).rawValue,
                    isAutoRepeat: event.isARepeat
                ))
                return nil
            }
        }

        if let parent, let screen = parent.screen {
            let frame = panel.frame
            let parentFrame = parent.frame
            let visibleFrame = screen.visibleFrame
            let x = min(max(visibleFrame.minX, parentFrame.midX - frame.width / 2),
                        visibleFrame.maxX - frame.width)
            let y = min(max(visibleFrame.minY, parentFrame.midY - frame.height / 2),
                        visibleFrame.maxY - frame.height)
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func cancel() {
        finish(with: nil)
    }

    @objc private func save(_ sender: NSButton) {
        guard let selected else { return }
        finish(with: selected)
    }

    @objc private func cancelClicked(_ sender: NSButton) {
        cancel()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        cancel()
        return false
    }

    private func startEventTap() -> Bool {
        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        let opaqueSelf = Unmanaged.passUnretained(self).toOpaque()
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let recorder = Unmanaged<HotkeyRecorderController>
                    .fromOpaque(userInfo)
                    .takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    MainActor.assumeIsolated {
                        if let eventTap = recorder.eventTap {
                            CGEvent.tapEnable(tap: eventTap, enable: true)
                        }
                    }
                    return Unmanaged.passUnretained(event)
                }
                let snapshot = HotkeyEventSnapshot(
                    typeRawValue: type.rawValue,
                    keycode: CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)),
                    flagsRawValue: event.flags.rawValue,
                    isAutoRepeat: type == .keyDown
                        && event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                )
                MainActor.assumeIsolated {
                    recorder.consume(snapshot)
                }
                return nil
            },
            userInfo: opaqueSelf
        ) else {
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            CFMachPortInvalidate(eventTap)
            return false
        }
        self.eventTap = eventTap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        log("Hotkey recorder: dedicated CGEventTap active")
        return true
    }

    private func consume(_ snapshot: HotkeyEventSnapshot) {
        guard !isFinished else { return }
        log("Hotkey recorder: event type=\(snapshot.typeRawValue) keycode=\(snapshot.keycode) flags=0x\(String(snapshot.flagsRawValue, radix: 16))")
        switch captureState.consume(snapshot) {
        case .candidate(let choice):
            selected = choice
            saveButton.isEnabled = true
            log("Hotkey recorder: selected \(choice.name)")
            status.stringValue = localizedText(
                "Выбрано: \(localizedHotkeyName(choice, language: language))",
                "Selected: \(localizedHotkeyName(choice, language: language))",
                language: language
            )
        case .reject(let message):
            selected = nil
            saveButton.isEnabled = false
            status.stringValue = localizedText(
                "Эту клавишу нельзя использовать. Выберите другую.",
                message,
                language: language
            )
            NSSound.beep()
        case .cancel:
            cancel()
        case .ignore:
            break
        }
    }

    private func finish(with choice: HotkeyChoice?) {
        guard !isFinished else { return }
        isFinished = true
        if let fallbackMonitor {
            NSEvent.removeMonitor(fallbackMonitor)
            self.fallbackMonitor = nil
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        panel.delegate = nil
        panel.orderOut(nil)
        panel.close()
        let completion = self.completion
        self.completion = nil
        completion?(choice)
    }
}

private func hotkeyFlags(from modifiers: NSEvent.ModifierFlags) -> CGEventFlags {
    var result: CGEventFlags = []
    if modifiers.contains(.control) { result.insert(.maskControl) }
    if modifiers.contains(.option) { result.insert(.maskAlternate) }
    if modifiers.contains(.shift) { result.insert(.maskShift) }
    if modifiers.contains(.command) { result.insert(.maskCommand) }
    if modifiers.contains(.function) { result.insert(.maskSecondaryFn) }
    return result
}

private enum HotkeyTransitionAction: Equatable, Sendable {
    case press
    case release
    case releaseAlternate
    case cancel
    case showHistory
}

private struct HotkeyTransitionResult: Equatable, Sendable {
    let suppress: Bool
    let actions: [HotkeyTransitionAction]

    static let pass = HotkeyTransitionResult(suppress: false, actions: [])
    static let suppressOnly = HotkeyTransitionResult(suppress: true, actions: [])
}

private enum HotkeyShortcutEdge: Equatable {
    case press
    case release
    case suppress
    case pass
}

private struct HotkeyShortcutState {
    private var primaryModifierDown = false
    private var shortcutDown = false
    private var suppressingChordRelease = false

    var isEngaged: Bool { primaryModifierDown || shortcutDown || suppressingChordRelease }

    mutating func reset() {
        primaryModifierDown = false
        shortcutDown = false
        suppressingChordRelease = false
    }

    mutating func consume(_ event: HotkeyEventSnapshot,
                          shortcut: HotkeyChoice) -> HotkeyShortcutEdge {
        if !shortcut.isModifier {
            guard event.keycode == shortcut.keycode else { return .pass }
            if event.typeRawValue == CGEventType.keyDown.rawValue {
                guard !event.isAutoRepeat else { return shortcutDown ? .suppress : .pass }
                let modifiers = event.flags.intersection(HOTKEY_SHORTCUT_MODIFIER_MASK)
                guard modifiers == shortcut.requiredModifiers else { return .pass }
                shortcutDown = true
                return .press
            }
            if event.typeRawValue == CGEventType.keyUp.rawValue, shortcutDown {
                shortcutDown = false
                return .release
            }
            return .pass
        }

        guard event.typeRawValue == CGEventType.flagsChanged.rawValue,
              let primaryMask = shortcut.modifierFlag else {
            return .pass
        }

        let eventModifier = MODIFIER_HOTKEY_CHOICES.first(where: { $0.keycode == event.keycode })
        let isRequiredModifierEvent = eventModifier?.modifierFlag.map {
            shortcut.requiredModifiers.contains($0)
        } ?? false
        let isRelevant = event.keycode == shortcut.keycode || isRequiredModifierEvent
        guard isRelevant else { return .pass }

        if suppressingChordRelease {
            let allModifiers = shortcut.requiredModifiers.union(primaryMask)
            if event.keycode == shortcut.keycode {
                primaryModifierDown = false
            }
            if event.flags.intersection(allModifiers).isEmpty {
                suppressingChordRelease = false
                primaryModifierDown = false
                shortcutDown = false
            }
            return .suppress
        }

        if event.keycode == shortcut.keycode {
            if primaryModifierDown {
                primaryModifierDown = false
            } else if event.flags.contains(primaryMask) {
                primaryModifierDown = true
            }
        }

        let expectedModifiers = shortcut.requiredModifiers.union(primaryMask)
        let requirementsMet = event.flags.intersection(HOTKEY_SHORTCUT_MODIFIER_MASK)
            == expectedModifiers
        let isNowDown = primaryModifierDown && requirementsMet
        if isNowDown, !shortcutDown {
            shortcutDown = true
            return .press
        }
        if shortcutDown, !isNowDown {
            shortcutDown = false
            suppressingChordRelease = !shortcut.requiredModifiers.isEmpty
            return .release
        }
        if shortcutDown || isRequiredModifierEvent {
            return .suppress
        }
        return .pass
    }
}

private struct HotkeyTransitionState {
    private var standardShortcutState = HotkeyShortcutState()
    private var enterShortcutState = HotkeyShortcutState()
    private var historyShortcutState = HotkeyShortcutState()
    private var toggleActive = false
    private var suppressEscapeKeyUp = false

    mutating func resetAll() {
        standardShortcutState.reset()
        enterShortcutState.reset()
        historyShortcutState.reset()
        toggleActive = false
        suppressEscapeKeyUp = false
    }

    mutating func resetToggleState() {
        toggleActive = false
    }

    /// `canStartRecording` mirrors the app-side guard on handlePress
    /// (ready, not recording, not busy, not terminating). Toggle mode
    /// consults it before flipping state — see the `.toggle` case.
    /// Defaults to true so hold-mode behaviour and existing callers
    /// are unchanged.
    mutating func transition(
        for event: HotkeyEventSnapshot,
        hotkey: HotkeyChoice,
        enterHotkey: HotkeyChoice = hotkeyChoice(forKeycode: RIGHT_COMMAND_KEYCODE,
                                                 modifiers: .maskAlternate),
        alternateCompletionEnabled: Bool = true,
        historyHotkey: HotkeyChoice = hotkeyChoice(forKeycode: RIGHT_COMMAND_KEYCODE,
                                                   modifiers: .maskShift),
        triggerMode: TriggerMode,
        isRecording: Bool,
        canStartRecording: Bool = true
    ) -> HotkeyTransitionResult {
        if event.keycode == ESCAPE_KEYCODE {
            return transitionEscape(for: event, isRecording: isRecording)
        }

        if let history = transitionHistoryShortcut(for: event,
                                                    isRecording: isRecording,
                                                    historyHotkey: historyHotkey) {
            return history
        }

        if alternateCompletionEnabled,
           !hotkeyIsModifierPrefix(hotkey, of: enterHotkey) {
            if let completion = transitionEnterShortcut(for: event,
                                                         isRecording: isRecording,
                                                         enterHotkey: enterHotkey) {
                return completion
            }
        }

        let edge = standardShortcutState.consume(event, shortcut: hotkey)

        switch triggerMode {
        case .hold:
            var actions: [HotkeyTransitionAction] = []
            if edge == .press { actions.append(.press) }
            if edge == .release { actions.append(.release) }
            guard edge != .pass else { return .pass }
            return HotkeyTransitionResult(suppress: true, actions: actions)
        case .toggle:
            // Toggle mode: every press flips between "start recording"
            // and "stop recording". Releases are no-ops.
            guard edge != .pass else { return .pass }
            guard edge == .press else { return .suppressOnly }
            if toggleActive {
                toggleActive = false
                return HotkeyTransitionResult(suppress: true, actions: [.release])
            }
            // A press the app will reject (model loading, a
            // transcription in flight, terminating) must not flip the
            // toggle. Otherwise the rejected press strands
            // toggleActive at true, the NEXT press emits a .release
            // the app discards, and only the third press records —
            // with zero feedback in between. Same gate-callback
            // pattern Escape uses via isRecording.
            guard canStartRecording else { return .suppressOnly }
            toggleActive = true
            return HotkeyTransitionResult(suppress: true, actions: [.press])
        }
    }

    private mutating func transitionHistoryShortcut(
        for event: HotkeyEventSnapshot,
        isRecording: Bool,
        historyHotkey: HotkeyChoice
    ) -> HotkeyTransitionResult? {
        switch historyShortcutState.consume(event, shortcut: historyHotkey) {
        case .press:
            standardShortcutState.reset()
            enterShortcutState.reset()
            if !isRecording {
                toggleActive = false
            }
            return HotkeyTransitionResult(suppress: true, actions: [.showHistory])
        case .release, .suppress:
            return .suppressOnly
        case .pass:
            return nil
        }
    }

    private mutating func transitionEnterShortcut(
        for event: HotkeyEventSnapshot,
        isRecording: Bool,
        enterHotkey: HotkeyChoice
    ) -> HotkeyTransitionResult? {
        guard isRecording || enterShortcutState.isEngaged else { return nil }
        switch enterShortcutState.consume(event, shortcut: enterHotkey) {
        case .press where isRecording:
            standardShortcutState.reset()
            toggleActive = false
            return HotkeyTransitionResult(suppress: true, actions: [.releaseAlternate])
        case .press, .release, .suppress:
            return .suppressOnly
        case .pass:
            return nil
        }
    }

    private mutating func transitionEscape(
        for event: HotkeyEventSnapshot,
        isRecording: Bool
    ) -> HotkeyTransitionResult {
        if event.typeRawValue == CGEventType.keyDown.rawValue {
            if event.isAutoRepeat, suppressEscapeKeyUp {
                return .suppressOnly
            }
            guard isRecording else { return .pass }
            suppressEscapeKeyUp = true
            return event.isAutoRepeat
                ? .suppressOnly
                : HotkeyTransitionResult(suppress: true, actions: [.cancel])
        }

        if event.typeRawValue == CGEventType.keyUp.rawValue, suppressEscapeKeyUp {
            suppressEscapeKeyUp = false
            return .suppressOnly
        }

        return .pass
    }
}

@MainActor
final class HotkeyListener {

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var transitionState = HotkeyTransitionState()

    /// User's current hotkey (set via Settings → Hotkey submenu).
    var hotkey: HotkeyChoice = hotkeyChoice(forKeycode: DEFAULT_HOTKEY_KEYCODE)
    var enterHotkey: HotkeyChoice = hotkeyChoice(forKeycode: RIGHT_COMMAND_KEYCODE,
                                                 modifiers: .maskAlternate)
    var alternateCompletionEnabled = true
    var historyHotkey: HotkeyChoice = hotkeyChoice(forKeycode: RIGHT_COMMAND_KEYCODE,
                                                   modifiers: .maskShift)
    var triggerMode: TriggerMode = .hold

    /// onPress fires when a recording should start (press in hold mode,
    /// or first press in toggle mode). onRelease fires when it should
    /// stop (release in hold mode, or second press in toggle mode).
    /// onCancel fires for Escape while a recording is active.
    var onPress: (() -> Void)?
    var onRelease: ((TimeInterval) -> Void)?
    var onReleaseAlternate: ((TimeInterval) -> Void)?
    var onCancel: (() -> Void)?
    var onShowHistory: (() -> Void)?
    var isRecordingActive: (() -> Bool)?
    /// Asks the app whether a new recording would actually start if
    /// onPress fired right now (ready, idle, not transcribing, not
    /// terminating). Toggle mode uses it so a press the app would
    /// silently discard doesn't flip the toggle state and leave the
    /// next press emitting a swallowed .release. nil (or no callback
    /// installed) is treated as "would start".
    var canStartRecording: (() -> Bool)?

    @discardableResult
    func start() -> Bool {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
            return true
        }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
                              | (1 << CGEventType.keyUp.rawValue)
                              | (1 << CGEventType.flagsChanged.rawValue)

        let opaqueSelf = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let listener = Unmanaged<HotkeyListener>.fromOpaque(userInfo).takeUnretainedValue()
                let snapshot = HotkeyEventSnapshot(
                    typeRawValue: type.rawValue,
                    keycode: CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)),
                    flagsRawValue: event.flags.rawValue,
                    isAutoRepeat: type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                )
                let shouldSuppress = MainActor.assumeIsolated {
                    listener.handleTapCallback(snapshot)
                }
                return shouldSuppress ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: opaqueSelf
        ) else {
            log("CGEvent.tapCreate failed — Input Monitoring permission missing?")
            return false
        }

        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log("HotkeyListener: tap active (watching \(hotkey.name))")
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        transitionState.resetAll()
    }

    /// Replace the current hotkey choice. Safe to call at runtime —
    /// the tap stays bound, only the per-event filter changes.
    func setHotkey(_ choice: HotkeyChoice) {
        self.hotkey = choice
        self.transitionState.resetAll()
        log("HotkeyListener: hotkey changed → \(choice.name)")
    }

    func setEnterHotkey(_ choice: HotkeyChoice) {
        enterHotkey = choice
        transitionState.resetAll()
        log("HotkeyListener: alternate completion hotkey changed → \(choice.name)")
    }

    func setAlternateCompletionEnabled(_ enabled: Bool) {
        alternateCompletionEnabled = enabled
        transitionState.resetAll()
        log("HotkeyListener: alternate completion → \(enabled ? "enabled" : "disabled")")
    }

    func setHistoryHotkey(_ choice: HotkeyChoice) {
        historyHotkey = choice
        transitionState.resetAll()
        log("HotkeyListener: history hotkey changed → \(choice.name)")
    }

    func setTriggerMode(_ mode: TriggerMode) {
        // Reset toggle state when switching modes so we don't get
        // stuck in mid-toggle from a previous session.
        if mode != triggerMode { transitionState.resetToggleState() }
        triggerMode = mode
        log("HotkeyListener: trigger mode → \(mode.rawValue)")
    }

    private func handleTapCallback(_ event: HotkeyEventSnapshot) -> Bool {
        if event.typeRawValue == CGEventType.tapDisabledByTimeout.rawValue
            || event.typeRawValue == CGEventType.tapDisabledByUserInput.rawValue {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
                log("HotkeyListener: event tap re-enabled after \(event.typeRawValue)")
            }
            return false
        }

        let result = transitionState.transition(for: event,
                                                hotkey: hotkey,
                                                enterHotkey: enterHotkey,
                                                alternateCompletionEnabled: alternateCompletionEnabled,
                                                historyHotkey: historyHotkey,
                                                triggerMode: triggerMode,
                                                isRecording: isRecordingActive?() ?? false,
                                                canStartRecording: canStartRecording?() ?? true)
        dispatchHotkeyActions(result.actions)
        return result.suppress
    }

    private func dispatchHotkeyActions(_ actions: [HotkeyTransitionAction]) {
        guard !actions.isEmpty else { return }
        let detectedAt = ProcessInfo.processInfo.systemUptime

        Task { @MainActor [weak self] in
            self?.performHotkeyActions(actions, detectedAt: detectedAt)
        }
    }

    private func performHotkeyActions(_ actions: [HotkeyTransitionAction], detectedAt: TimeInterval) {
        for action in actions {
            switch action {
            case .press: onPress?()
            case .release: onRelease?(detectedAt)
            case .releaseAlternate: onReleaseAlternate?(detectedAt)
            case .cancel: onCancel?()
            case .showHistory: onShowHistory?()
            }
        }
    }

    /// Called when the recording stops via a path other than the
    /// hotkey (auto-release at max duration, app quitting, etc.) so
    /// toggle mode doesn't end up offset by one.
    func resetToggleState() {
        transitionState.resetToggleState()
    }
}

// MARK: - Audio capture
//
// AVAudioEngine tap on the input node, downmix to mono / 16 kHz /
// Float32 if needed, append to a buffer while recording.
//
// Deliberately NOT @MainActor. AVAudioEngine's installTap delivers
// callbacks on an audio worker thread. Under Swift 6 strict
// concurrency, calling a @MainActor method from that thread triggers
// dispatch_assert_queue_fail (SIGTRAP) and kills the process. We
// instead guard mutable state with NSLock and let the tap callback
// run wherever AVFoundation calls it.
//
// Locking discipline: `lock` protects ALL mutable state shared with
// the render thread — `samples`, `_isRunning`, `latestLevel`,
// `latestLevelSequence`, `recordingGeneration`, the engine-open flag,
// AND the converter trio (`converter`, `converterInputFormat`,
// `manuallyMixInputToMono`). The trio is written on the main thread
// in startEngine/stopEngine and read in handleTap on AVFoundation's
// render thread; removeTap(onBus:) does NOT wait for in-flight tap
// callbacks, so an unlocked read could race stopEngine nil-ing the
// converter (an unsynchronised ARC pointer read — potential
// use-after-free). handleTap snapshots the trio once, inside the
// same lock acquisition that reads `_isRunning`, and works off the
// snapshots; a straggler callback then keeps the old converter
// alive through its own strong reference, which is safe.
// `configurationObserver` and `onConfigurationChange` are
// main-thread-only: the observer is registered with queue: .main so
// the notification callback runs on the same thread that installs
// the observer and that clears `onConfigurationChange` at
// termination.

private struct CapturedAudioSegments {
    let segments: [[Float]]
    let sampleCount: Int

    func flattened() -> [Float] {
        guard sampleCount > 0 else { return [] }
        var out: [Float] = []
        out.reserveCapacity(sampleCount)
        for segment in segments {
            out.append(contentsOf: segment)
        }
        return out
    }
}

private struct CapturedRecording {
    let samples: [Float]
    let recoveryURL: URL?
    let detachSeconds: TimeInterval
    let journalFlushSeconds: TimeInterval
    let flattenSeconds: TimeInterval
}

private enum PendingDictationRecovery {
    private static let directoryName = "PendingDictations"
    private static let fileExtension = "sdaudio"
    private static let magic = Data("SDAR".utf8)

    static func directoryURL() throws -> URL {
        let url = try superDictateApplicationSupportDirectory()
            .appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                              ofItemAtPath: url.path)
        return url
    }

    static func createJournal() throws -> PendingDictationJournal {
        try PendingDictationJournal(url: directoryURL()
            .appendingPathComponent("pending-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension))
    }

    static func pendingURLs() -> [URL] {
        guard let directory = try? directoryURL(),
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.creationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else { return [] }

        return urls
            .filter { $0.pathExtension == fileExtension && $0.lastPathComponent.hasPrefix("pending-") }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return left < right
            }
    }

    static func loadSamples(from url: URL) throws -> [Float] {
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw currentPOSIXError() }
        defer { _ = Darwin.close(fd) }

        try validateSingleLinkRegularFileDescriptor(fd)
        var st = stat()
        guard Darwin.fstat(fd, &st) == 0 else { throw currentPOSIXError() }
        guard st.st_size >= PENDING_DICTATION_HEADER_SIZE,
              st.st_size <= PENDING_DICTATION_MAX_BYTES else {
            throw posixError(EFBIG)
        }

        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.readToEnd() ?? Data()
        guard data.count >= PENDING_DICTATION_HEADER_SIZE,
              data.prefix(4) == magic,
              readUInt32LE(data, offset: 4) == PENDING_DICTATION_FILE_VERSION,
              readUInt32LE(data, offset: 8) == UInt32(SAMPLE_RATE),
              readUInt32LE(data, offset: 12) == UInt32(MemoryLayout<Float>.size) else {
            throw posixError(EINVAL)
        }

        let payload = data.dropFirst(PENDING_DICTATION_HEADER_SIZE)
        // A process can die halfway through the final write. Preserve every
        // complete float instead of rejecting the whole recording for 1-3
        // trailing bytes.
        let usablePayloadCount = payload.count - (payload.count % MemoryLayout<Float>.size)
        let usablePayload = payload.prefix(usablePayloadCount)
        var samples = [Float](repeating: 0,
                              count: usablePayload.count / MemoryLayout<Float>.size)
        samples.withUnsafeMutableBytes { destination in
            usablePayload.withUnsafeBytes { source in
                destination.copyBytes(from: source)
            }
        }
        return samples
    }

    static func remove(_ url: URL?) {
        guard let url else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch where (error as NSError).code == NSFileNoSuchFileError {
            return
        } catch {
            log("pending dictation cleanup failed: \(error.localizedDescription)")
        }
    }

    static func headerData() -> Data {
        var data = magic
        appendUInt32LE(PENDING_DICTATION_FILE_VERSION, to: &data)
        appendUInt32LE(UInt32(SAMPLE_RATE), to: &data)
        appendUInt32LE(UInt32(MemoryLayout<Float>.size), to: &data)
        return data
    }

    private static func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    private static func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        return data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            return UInt32(bytes[offset])
                | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24)
        }
    }
}

private final class PendingDictationJournal: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "SuperDictate.PendingDictationJournal",
                                      qos: .utility)
    private var fileDescriptor: Int32
    private var didLogWriteFailure = false

    init(url: URL) throws {
        self.url = url
        fileDescriptor = -1
        let flags = O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW
        let fd = Darwin.open(url.path, flags, PRIVATE_LOG_FILE_MODE)
        guard fd >= 0 else { throw currentPOSIXError() }
        do {
            try validateSingleLinkRegularFileDescriptor(fd)
            guard Darwin.fchmod(fd, PRIVATE_LOG_FILE_MODE) == 0 else {
                throw currentPOSIXError()
            }
            try writeAllData(PendingDictationRecovery.headerData(), to: fd)
            fileDescriptor = fd
        } catch {
            _ = Darwin.close(fd)
            _ = Darwin.unlink(url.path)
            throw error
        }
    }

    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let data = samples.withUnsafeBytes { Data($0) }
        queue.async { [self] in
            guard fileDescriptor >= 0 else { return }
            do {
                try writeAllData(data, to: fileDescriptor)
            } catch where !didLogWriteFailure {
                didLogWriteFailure = true
                log("pending dictation write failed: \(error.localizedDescription)")
            } catch {}
        }
    }

    func finish() {
        queue.sync { [self] in
            guard fileDescriptor >= 0 else { return }
            if Darwin.fsync(fileDescriptor) != 0, !didLogWriteFailure {
                didLogWriteFailure = true
                log("pending dictation sync failed: \(currentPOSIXError().localizedDescription)")
            }
            _ = Darwin.close(fileDescriptor)
            fileDescriptor = -1
        }
    }
}

private struct AudioSampleAccumulator {
    private var segments: [[Float]] = []
    private(set) var sampleCount = 0

    mutating func append(_ segment: [Float]) {
        guard !segment.isEmpty else { return }
        segments.append(segment)
        sampleCount += segment.count
    }

    mutating func removeAll(keepingCapacity: Bool) {
        segments.removeAll(keepingCapacity: keepingCapacity)
        sampleCount = 0
    }

    mutating func drain() -> CapturedAudioSegments {
        let captured = CapturedAudioSegments(segments: segments,
                                             sampleCount: sampleCount)
        segments.removeAll(keepingCapacity: true)
        sampleCount = 0
        return captured
    }
}

func selectedMonoMixChannelIndices(channelRMS: [Double]) -> [Int] {
    let peak = channelRMS.max() ?? 0
    let active = channelRMS.enumerated()
        .filter { pair in peak > 0 && pair.element >= peak * 0.25 }
        .map { $0.offset }
    return active.isEmpty ? [0] : active
}

func channelRMSValues(channels: UnsafePointer<UnsafeMutablePointer<Float>>,
                      channelCount: Int,
                      frameCount: Int) -> [Double] {
    guard channelCount > 0, frameCount > 0 else { return [] }
    var rms = Array(repeating: 0.0, count: channelCount)
    for channelIndex in 0..<channelCount {
        var sumSquares = 0.0
        let source = channels[channelIndex]
        for frameIndex in 0..<frameCount {
            let sample = source[frameIndex]
            guard sample.isFinite else { continue }
            let clamped = max(-1, min(1, sample))
            sumSquares += Double(clamped * clamped)
        }
        rms[channelIndex] = sqrt(sumSquares / Double(frameCount))
    }
    return rms
}

func writeMonoMix(channels: UnsafePointer<UnsafeMutablePointer<Float>>,
                  selectedChannels: [Int],
                  frameCount: Int,
                  to mono: UnsafeMutablePointer<Float>) {
    guard frameCount > 0 else { return }
    let selectedChannels = selectedChannels.isEmpty ? [0] : selectedChannels
    let scale = Float(1.0 / Double(selectedChannels.count))
    for frameIndex in 0..<frameCount {
        var mixed: Float = 0
        for channelIndex in selectedChannels {
            mixed += channels[channelIndex][frameIndex] * scale
        }
        mono[frameIndex] = mixed
    }
}

final class AudioCapture: @unchecked Sendable {
    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var manuallyMixInputToMono = false
    private let lock = NSLock()
    private var samples = AudioSampleAccumulator()
    private var _isRunning = false
    private var latestLevel: Float = 0
    private var latestLevelSequence: UInt64 = 0
    private var recordingGeneration: UInt64 = 0
    private var recoveryJournal: PendingDictationJournal?
    private var engineStarted = false
    private var configurationObserver: NSObjectProtocol?

    var onConfigurationChange: (@Sendable () -> Void)?

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isRunning
    }

    var isEngineStarted: Bool {
        lock.lock(); defer { lock.unlock() }
        return engineStarted
    }

    fileprivate func startEngine(inputDevicePreference: String = "",
                                 recordingImmediately: Bool = false,
                                 recoveryJournal: PendingDictationJournal? = nil) throws {
        if isEngineStarted {
            if recordingImmediately {
                beginRecording(recoveryJournal: recoveryJournal)
            }
            return
        }

        let input = engine.inputNode
        applyInputDevicePreference(inputDevicePreference, to: input)
        let inputFormat = input.outputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: SAMPLE_RATE,
            channels: 1,
            interleaved: false
        ) else { throw NSError(domain: "Parakey", code: -1) }

        let sourceFormat = converterSourceFormat(for: inputFormat)
        let mixToMono = inputFormat.channelCount > 1 && sourceFormat.channelCount == 1
        let newConverter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        // Publish the converter trio under the lock — handleTap reads
        // them on the render thread (see the locking-discipline note
        // on the class comment).
        lock.lock()
        converterInputFormat = sourceFormat
        manuallyMixInputToMono = mixToMono
        converter = newConverter
        if recordingImmediately {
            recordingGeneration &+= 1
            samples.removeAll(keepingCapacity: true)
            latestLevel = 0
            latestLevelSequence &+= 1
            _isRunning = true
            self.recoveryJournal = recoveryJournal
        }
        lock.unlock()
        let mixLabel = mixToMono ? " via manual mono mix" : ""
        log("AudioCapture: input \(inputFormat.sampleRate) Hz \(inputFormat.channelCount)ch\(mixLabel) → \(targetFormat.sampleRate) Hz mono")

        // Capture targetFormat by value into the closure. self is
        // weak so the engine doesn't keep AudioCapture alive past
        // its owner. The closure runs on AVFoundation's audio
        // thread — handleTap is non-isolated and uses NSLock for
        // any shared-state access.
        input.installTap(onBus: 0, bufferSize: 512, format: inputFormat) { [weak self] buffer, _ in
            self?.handleTap(buffer: buffer, target: targetFormat)
        }

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            clearStoppedCaptureState()
            resetEngineInstance()
            throw error
        }
        lock.lock()
        engineStarted = true
        lock.unlock()
        installConfigurationObserver()
        log("AudioCapture: engine started")
    }

    fileprivate func startRecording(inputDevicePreference: String = "",
                                    recoveryJournal: PendingDictationJournal? = nil) throws {
        if isEngineStarted {
            beginRecording(recoveryJournal: recoveryJournal)
            return
        }
        try startEngine(inputDevicePreference: inputDevicePreference,
                        recordingImmediately: true,
                        recoveryJournal: recoveryJournal)
    }

    func stopEngine() {
        removeConfigurationObserver()

        let wasEngineStarted = isEngineStarted
        clearStoppedCaptureState()

        guard wasEngineStarted else { return }
        engine.inputNode.removeTap(onBus: 0)
        resetEngineInstance()
    }

    private func clearStoppedCaptureState() {
        lock.lock()
        _isRunning = false
        latestLevel = 0
        latestLevelSequence &+= 1
        recordingGeneration &+= 1
        samples.removeAll(keepingCapacity: true)
        let recoveryJournal = self.recoveryJournal
        self.recoveryJournal = nil
        engineStarted = false
        // Clear the converter trio under the same lock the render
        // thread snapshots them with — removeTap below does not wait
        // for an in-flight tap callback. A callback that already took
        // its snapshot keeps the old converter alive through its own
        // strong reference, which is safe.
        converter = nil
        converterInputFormat = nil
        manuallyMixInputToMono = false
        lock.unlock()
        recoveryJournal?.finish()
    }

    private func resetEngineInstance() {
        engine.stop()
        engine.reset()
        engine = AVAudioEngine()
    }

    fileprivate func beginRecording(recoveryJournal: PendingDictationJournal? = nil) {
        lock.lock()
        let previousJournal = self.recoveryJournal
        recordingGeneration &+= 1
        samples.removeAll(keepingCapacity: true)
        latestLevel = 0
        latestLevelSequence &+= 1
        _isRunning = true
        self.recoveryJournal = recoveryJournal
        lock.unlock()
        previousJournal?.finish()
    }

    private func installConfigurationObserver() {
        removeConfigurationObserver()
        // queue: .main — the notification can be posted from an
        // AVFoundation worker thread, and `onConfigurationChange` is
        // an unsynchronised var that the owner clears on the main
        // thread at termination. Hopping to the main queue makes the
        // read of the callback and the nil-ing write happen on the
        // same thread, so a config change racing teardown can never
        // observe a half-released closure.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.onConfigurationChange?()
        }
    }

    private func removeConfigurationObserver() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
    }

    /// Stops recording, flushes its crash-recovery journal, and returns the captured samples.
    fileprivate func endRecording() -> CapturedRecording {
        let startedAt = ProcessInfo.processInfo.systemUptime
        lock.lock()
        _isRunning = false
        latestLevel = 0
        latestLevelSequence &+= 1
        recordingGeneration &+= 1
        let captured = samples.drain()
        let recoveryJournal = self.recoveryJournal
        self.recoveryJournal = nil
        lock.unlock()
        let detachedAt = ProcessInfo.processInfo.systemUptime
        recoveryJournal?.finish()
        let journalFlushedAt = ProcessInfo.processInfo.systemUptime
        let flattened = captured.flattened()
        let flattenedAt = ProcessInfo.processInfo.systemUptime
        return CapturedRecording(
            samples: flattened,
            recoveryURL: recoveryJournal?.url,
            detachSeconds: detachedAt - startedAt,
            journalFlushSeconds: journalFlushedAt - detachedAt,
            flattenSeconds: flattenedAt - journalFlushedAt
        )
    }

    func latestRecordingLevelSnapshot() -> (level: Float, sequence: UInt64) {
        lock.lock(); defer { lock.unlock() }
        return _isRunning
            ? (latestLevel, latestLevelSequence)
            : (0, latestLevelSequence)
    }

    private func handleTap(buffer: AVAudioPCMBuffer, target: AVAudioFormat) {
        // Snapshot the running flag AND the converter trio in one
        // lock acquisition; bail fast if we're not recording so we
        // don't pay conversion cost for nothing. Working off the
        // snapshots keeps this callback consistent even if
        // stopEngine() clears the fields mid-flight — removeTap does
        // not wait for us, and the local strong reference keeps the
        // converter alive for the rest of this call.
        lock.lock()
        let running = _isRunning
        let generation = recordingGeneration
        let converter = self.converter
        let monoMixFormat = converterInputFormat
        let mixToMono = manuallyMixInputToMono
        lock.unlock()
        guard running, let converter else { return }

        let converterInput = preparedConverterInputBuffer(from: buffer,
                                                          mixToMono: mixToMono,
                                                          monoFormat: monoMixFormat) ?? buffer
        let ratio = target.sampleRate / converterInput.format.sampleRate
        let outCap = AVAudioFrameCount(Double(converterInput.frameLength) * ratio + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCap) else { return }

        // .noDataNow vs .endOfStream: this is reusing the same
        // AVAudioConverter across every tap callback (~50 Hz). If we
        // signal .endOfStream after the buffer, the converter goes
        // into a terminal state and produces 0 samples on every
        // subsequent call — exactly the "first capture was 0.10s,
        // every press after that was 0.00s" bug we saw before this
        // fix. .noDataNow means "I'm out of input *for this call*,
        // but the stream continues" and leaves the converter usable.
        let inputProvider = AudioConverterInputProvider(buffer: converterInput)
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            inputProvider.provide(outStatus: outStatus)
        }
        if status == .error {
            log("AudioCapture: convert error: \(error?.localizedDescription ?? "?")")
            return
        }
        guard let ch = out.floatChannelData?[0] else { return }
        let frameCount = Int(out.frameLength)
        var arr: [Float] = []
        arr.reserveCapacity(frameCount)
        var sumSquares: Double = 0
        var finiteSampleCount = 0
        for sample in UnsafeBufferPointer(start: ch, count: frameCount) {
            arr.append(sample)
            guard sample.isFinite else { continue }
            let clamped = max(-1, min(1, sample))
            sumSquares += Double(clamped * clamped)
            finiteSampleCount += 1
        }
        let level = normalizedAudioLevel(sumSquares: sumSquares,
                                         sampleCount: finiteSampleCount)
        // Re-check running under lock — endRecording() might have
        // fired during conversion, then a rapid next recording may
        // already have started. The generation token keeps straggler
        // frames out of the next clip.
        lock.lock()
        if _isRunning && recordingGeneration == generation {
            samples.append(arr)
            recoveryJournal?.append(arr)
            latestLevel = level
            latestLevelSequence &+= 1
        }
        lock.unlock()
    }

    private func converterSourceFormat(for inputFormat: AVAudioFormat) -> AVAudioFormat {
        guard inputFormat.channelCount > 1,
              let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: inputFormat.sampleRate,
                                             channels: 1,
                                             interleaved: false) else {
            return inputFormat
        }
        return monoFormat
    }

    /// `mixToMono` / `monoFormat` are the caller's lock-held
    /// snapshots of `manuallyMixInputToMono` / `converterInputFormat`
    /// — this runs on the render thread and must not read the shared
    /// fields directly (see the locking-discipline note on the class
    /// comment).
    private func preparedConverterInputBuffer(from buffer: AVAudioPCMBuffer,
                                              mixToMono: Bool,
                                              monoFormat: AVAudioFormat?) -> AVAudioPCMBuffer? {
        guard mixToMono else { return buffer }
        guard let monoFormat,
              let channels = buffer.floatChannelData else {
            return nil
        }

        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        guard channelCount > 1, frameCount > 0 else { return buffer }
        guard let out = AVAudioPCMBuffer(pcmFormat: monoFormat,
                                         frameCapacity: AVAudioFrameCount(frameCount)),
              let mono = out.floatChannelData?[0] else {
            return nil
        }

        let rms = channelRMSValues(channels: channels,
                                   channelCount: channelCount,
                                   frameCount: frameCount)
        writeMonoMix(channels: channels,
                     selectedChannels: selectedMonoMixChannelIndices(channelRMS: rms),
                     frameCount: frameCount,
                     to: mono)
        out.frameLength = AVAudioFrameCount(frameCount)
        return out
    }

    private func applyInputDevicePreference(_ preference: String, to input: AVAudioInputNode) {
        let trimmed = preference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !isDefaultAggregateAudioInputPreference(trimmed) else { return }

        guard let device = audioInputDevice(matching: trimmed) else {
            log("AudioCapture: saved input device unavailable, using system default")
            return
        }
        guard let unit = input.audioUnit else {
            log("AudioCapture: input audio unit unavailable, using system default")
            return
        }

        var deviceID = device.id
        let status = AudioUnitSetProperty(unit,
                                          kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global,
                                          0,
                                          &deviceID,
                                          UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            log("AudioCapture: input device switch failed (\(formattedOSStatus(status))), using system default")
            return
        }
        log("AudioCapture: selected input \(device.name)")
    }
}

private final class AudioConverterInputProvider: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private let lock = NSLock()
    private var didProvideBuffer = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func provide(outStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }

        if didProvideBuffer {
            outStatus.pointee = .noDataNow
            return nil
        }

        didProvideBuffer = true
        outStatus.pointee = .haveData
        return buffer
    }
}

// MARK: - Transcription worker
//
// Owns the FluidAudio AsrManager. The Apple Neural Engine doesn't
// tolerate concurrent inference calls against the same compiled
// CoreML graph — but the actor alone does NOT keep that contract.
// Actors are reentrant at suspension points: while
// `await asr.transcribe(...)` is suspended, a second transcribe()
// call would enter the actor and start concurrent inference. The
// real guard is ParakeyApp.isBusy, which ensures the app never
// issues a second transcribe while one is in flight. The `inFlight`
// flag below is a cheap defensive backstop should that invariant
// ever break: it refuses (and, in DEBUG, asserts on) a re-entrant
// call instead of corrupting ANE state.

private enum LoadedSpeechEngine {
    case parakeetV3(AsrManager)
}

private struct TranscriptionWorkerResult: Sendable {
    let text: String
    let workerQueueSeconds: Double
    let decoderPreparationSeconds: Double
    let fluidCallSeconds: Double
    let fluidProcessingSeconds: Double

    func timing(totalSeconds: Double) -> ASRTimingBreakdown {
        ASRTimingBreakdown(
            totalSeconds: totalSeconds,
            workerQueueSeconds: workerQueueSeconds,
            decoderPreparationSeconds: decoderPreparationSeconds,
            fluidCallSeconds: fluidCallSeconds,
            fluidProcessingSeconds: fluidProcessingSeconds
        )
    }
}

private struct CompletedTranscriptionWorkerResult: Sendable {
    let transcription: TranscriptionWorkerResult
    let completedAt: TimeInterval
}

actor TranscriptionWorker {
    private var engine: LoadedSpeechEngine?
    private var loadedProfile: SpeechModelProfile?
    private(set) var ready = false
    /// Reentrancy backstop — see the comment above. True for the full
    /// duration of transcribe(), including across its await.
    private var inFlight = false

    func load(profile requestedProfile: SpeechModelProfile,
              progressHandler: DownloadUtils.ProgressHandler? = nil) async throws {
        let profile = requestedProfile.productionProfile
        if requestedProfile != profile {
            log("ASR: ignoring unsupported speech model \(requestedProfile.shortName); using \(profile.shortName)")
        }
        if ready, engine != nil, loadedProfile == profile {
            log("ASR: \(profile.shortName) already ready")
            return
        }

        if engine != nil {
            await unload()
        }

        if speechModelCacheExists(for: profile) {
            log("ASR: verifying + loading cached \(profile.shortName) CoreML weights…")
        } else {
            log("ASR: downloading + verifying + loading \(profile.shortName) CoreML weights…")
        }
        let t0 = Date()
        engine = .parakeetV3(try await loadParakeetV3(progressHandler: progressHandler))
        loadedProfile = profile
        ready = true
        log("ASR: \(profile.shortName) ready in \(String(format: "%.2f", Date().timeIntervalSince(t0))) s")
    }

    private func loadParakeetV3(progressHandler: DownloadUtils.ProgressHandler?) async throws -> AsrManager {
        if !speechModelCacheExists(for: .multilingualV3) {
            try assertSufficientDiskSpaceForSpeechModelDownload(profile: .multilingualV3)
        }
        var modelDirectory = try await AsrModels.download(version: .v3,
                                                          progressHandler: progressHandler)
        do {
            try ModelIntegrity.verifyParakeetV3Model(at: modelDirectory)
        } catch {
            log("ASR: model integrity check failed; redownloading once: \(error.localizedDescription)")
            try assertSufficientDiskSpaceForSpeechModelDownload(profile: .multilingualV3)
            modelDirectory = try await AsrModels.download(force: true,
                                                          version: .v3,
                                                          progressHandler: progressHandler)
            try ModelIntegrity.verifyParakeetV3Model(at: modelDirectory)
        }
        let models = try await AsrModels.load(from: modelDirectory,
                                              version: .v3,
                                              progressHandler: progressHandler)
        return AsrManager(config: .default, models: models)
    }

    fileprivate func transcribe(samples: [Float],
                               language: Language? = nil,
                               requestedAt: TimeInterval) async throws -> TranscriptionWorkerResult {
        let workerEnteredAt = ProcessInfo.processInfo.systemUptime
        guard let engine else { throw NSError(domain: "Parakey", code: -2) }
        guard !inFlight else {
            log("ASR: transcribe re-entered while another transcription is in flight — refusing (ParakeyApp.isBusy should make this impossible)")
            assertionFailure("TranscriptionWorker.transcribe re-entered across a suspension point")
            throw NSError(domain: "Parakey", code: -3)
        }
        inFlight = true
        defer { inFlight = false }
        switch engine {
        case .parakeetV3(let asr):
            let decoderPreparationStartedAt = ProcessInfo.processInfo.systemUptime
            var state = try TdtDecoderState()
            let fluidCallStartedAt = ProcessInfo.processInfo.systemUptime
            let result = try await asr.transcribe(samples, decoderState: &state, language: language)
            let fluidCallCompletedAt = ProcessInfo.processInfo.systemUptime
            return TranscriptionWorkerResult(
                text: result.text,
                workerQueueSeconds: workerEnteredAt - requestedAt,
                decoderPreparationSeconds: fluidCallStartedAt - decoderPreparationStartedAt,
                fluidCallSeconds: fluidCallCompletedAt - fluidCallStartedAt,
                fluidProcessingSeconds: result.processingTime
            )
        }
    }

    func warmUp() async throws -> ASRTimingBreakdown {
        let samples = [Float](repeating: 0, count: Int(SAMPLE_RATE * 0.4))
        let requestedAt = ProcessInfo.processInfo.systemUptime
        let transcription = try await transcribe(
            samples: samples,
            language: nil,
            requestedAt: requestedAt
        )
        let completedAt = ProcessInfo.processInfo.systemUptime
        return transcription.timing(totalSeconds: completedAt - requestedAt)
    }

    func unload() async {
        engine = nil
        loadedProfile = nil
        ready = false
        log("ASR: unloaded")
    }
}

// MARK: - Transcript corrections
//
// Deterministic local rewrite pass for words or phrases the model
// consistently mishears. Corrections are applied to the transcript
// text before paste/history, never to audio, and replacement text is
// used exactly as the user typed it.

enum SpeechModelTextRepair {
    /// Parakeet TDT v3 emits `<unk>` for Cyrillic "ё" in Russian text.
    /// For Russian and auto-detect (the app's default audience) the
    /// token is replaced with "ё"/"Ё". For every other language the
    /// token is genuinely unknown and is removed entirely so a stray
    /// Cyrillic character doesn't appear in English/French/etc. text.
    static func apply(to text: String,
                      language: DictationLanguage = .auto) -> String {
        guard text.localizedCaseInsensitiveContains("<unk>") else { return text }

        let replaceWithYo: Bool
        switch language {
        case .auto, .russian:
            replaceWithYo = true
        default:
            replaceWithYo = false
        }

        var result = ""
        result.reserveCapacity(text.count)
        var index = text.startIndex

        while index < text.endIndex {
            if matchesUnknownToken(in: text, at: index) {
                if replaceWithYo {
                    result.append(shouldCapitalizeYo(before: result) ? "Ё" : "ё")
                }
                index = text.index(index, offsetBy: 5)
            } else {
                result.append(text[index])
                index = text.index(after: index)
            }
        }

        if !replaceWithYo {
            result = result
                .replacingOccurrences(of: "  ", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    private static func matchesUnknownToken(in text: String, at index: String.Index) -> Bool {
        let token = "<unk>"
        guard let end = text.index(index, offsetBy: token.count, limitedBy: text.endIndex) else {
            return false
        }
        return text[index..<end].lowercased() == token
    }

    private static func shouldCapitalizeYo(before prefix: String) -> Bool {
        guard let last = prefix.last(where: { !$0.isWhitespace }) else { return true }
        return ".!?".contains(last)
    }
}

enum TranscriptCorrector {
    private struct Match {
        let range: NSRange
        let replacement: String
    }

    static func apply(to text: String, corrections: [TranscriptCorrection]) -> (text: String, appliedCount: Int) {
        let active = normalizedTranscriptCorrections(corrections)
            .sorted { lhs, rhs in
                if lhs.source.count != rhs.source.count { return lhs.source.count > rhs.source.count }
                return lhs.source.localizedCaseInsensitiveCompare(rhs.source) == .orderedAscending
            }

        guard !text.isEmpty, !active.isEmpty else { return (text, 0) }

        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var matches: [Match] = []

        for correction in active {
            guard let pattern = pattern(for: correction.source),
                  let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            else { continue }

            regex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
                guard let range = match?.range, range.location != NSNotFound else { return }
                guard !matches.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) else { return }
                matches.append(Match(range: range, replacement: correction.replacement))
            }
        }

        guard !matches.isEmpty else { return (text, 0) }

        let rewritten = NSMutableString(string: text)
        for match in matches.sorted(by: { $0.range.location > $1.range.location }) {
            rewritten.replaceCharacters(in: match.range, with: match.replacement)
        }
        return (rewritten as String, matches.count)
    }

    private static func pattern(for source: String) -> String? {
        let parts = source
            .split(whereSeparator: { $0.isWhitespace })
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !parts.isEmpty else { return nil }
        return #"(?<![\p{L}\p{N}_])"# + parts.joined(separator: #"\s+"#) + #"(?![\p{L}\p{N}_])"#
    }
}

// MARK: - Filler word removal
//
// Deterministic regex pass that strips standalone non-word fillers
// ("um", "uh", "ah", "er", "erm", "hmm") and cleans up the punctuation
// artifacts left behind. Intentionally conservative: skips ambiguous
// fillers ("like", "you know") that have legitimate non-filler uses,
// and only fires when the user explicitly enables it via Settings →
// Remove filler words. Applied *after* TranscriptCorrector so explicit
// user corrections always win over filler stripping.

enum FillerWordRemover {
    private enum CapitalizationRepairTarget: Hashable {
        case start
        case afterSentenceTerminator(Int)
    }

    /// Non-word interjections only. "like" and "you know" are excluded
    /// because they have valid non-filler meanings ("I like cats", "you
    /// know who"). Most entries are regex fragments that allow the
    /// trailing letter to repeat, since real-world fillers stretch out
    /// ("ummm", "uhhhh", "ahhh", "hmmm") and the word-boundary lookahead
    /// would otherwise reject them. "er" and "erm" deliberately have no
    /// repeat quantifier: "er+" would also match the real word "err".
    private static let fillerPatterns = ["um+", "uh+", "ah+", "er", "erm", "hm+"]

    static func apply(to text: String) -> (text: String, removedCount: Int) {
        guard !text.isEmpty else { return (text, 0) }

        // Word-boundary lookarounds include `'` (so "it's" stays one
        // token) and `-` (so "uh-huh", "uh-oh" don't get split apart).
        let alternation = fillerPatterns.joined(separator: "|")
        let pattern = #"(?i)(?<![\p{L}\p{N}'\-])("# + alternation + #")(?![\p{L}\p{N}'\-])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return (text, 0)
        }

        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: fullRange)
        guard !matches.isEmpty else { return (text, 0) }

        // Preserve sentence-start casing when the removed filler carried
        // the capital ("Um, hello." and "First. Um hello.").
        let capitalizationRepairTargets = capitalizationRepairTargets(for: matches,
                                                                      in: text)

        let mutable = NSMutableString(string: text)
        for match in matches.reversed() {
            mutable.replaceCharacters(in: match.range, with: "")
        }
        var result = mutable as String

        // Clean up artifacts left behind by removal:
        //   1. Comma runs left by consecutive fillers: "x, , , y" →
        //      "x, y". Quantified so a run of ANY length collapses in
        //      one pass — a non-overlapping ",\s*," pattern consumed
        //      pairs and left ",," behind for two-plus fillers.
        //   2. Whitespace before punctuation: "x ." → "x."
        //   3. Orphan comma glued onto terminal punctuation by pass 2:
        //      "x,." → "x." ("That's all, um." must not end ",.")
        //   4. Multiple consecutive spaces → single space
        //   5. Leading punctuation / whitespace, including "?" and "!"
        //      so a removed sentence-initial filler takes its terminal
        //      punctuation with it ("Um? What?" → "What?")
        //   6. Orphan punctuation after an existing sentence terminator:
        //      "x. , y" → "x. y" when removing "Um," after the period.
        //   7. Trailing whitespace
        result = result.replacingOccurrences(of: #"\s*,(?:\s*,)+"#, with: ",", options: .regularExpression)
        result = result.replacingOccurrences(of: #"([.!?])\s+[,.;:!?]+\s*"#, with: "$1 ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s+([.,!?;:])"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #",+([.!?;:])"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"^[\s,.;:!?]+"#, with: "", options: .regularExpression)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        result = restoringCapitalization(in: result,
                                         targets: capitalizationRepairTargets)

        return (result, matches.count)
    }

    private static func capitalizationRepairTargets(for matches: [NSTextCheckingResult],
                                                     in text: String) -> Set<CapitalizationRepairTarget> {
        Set(matches.compactMap { match in
            guard let range = Range(match.range, in: text),
                  text[range].first?.isUppercase == true else {
                return nil
            }
            return capitalizationRepairTarget(for: range, in: text)
        })
    }

    private static func capitalizationRepairTarget(for range: Range<String.Index>,
                                                   in text: String) -> CapitalizationRepairTarget? {
        var index = range.lowerBound
        while index > text.startIndex {
            let previous = text.index(before: index)
            let character = text[previous]
            if character.isWhitespace || isBoundaryWrapper(character) {
                index = previous
                continue
            }
            guard isSentenceTerminator(character) else { return nil }
            return .afterSentenceTerminator(sentenceTerminatorOrdinal(at: previous,
                                                                      in: text))
        }
        return .start
    }

    private static func sentenceTerminatorOrdinal(at target: String.Index,
                                                  in text: String) -> Int {
        var ordinal = 0
        var index = text.startIndex
        while index <= target {
            if isSentenceTerminator(text[index]) {
                ordinal += 1
            }
            index = text.index(after: index)
        }
        return ordinal
    }

    private static func restoringCapitalization(in text: String,
                                                targets: Set<CapitalizationRepairTarget>) -> String {
        guard !targets.isEmpty, !text.isEmpty else { return text }

        let sentenceTargets = Set(targets.compactMap { target -> Int? in
            guard case .afterSentenceTerminator(let ordinal) = target else { return nil }
            return ordinal
        })
        var result = ""
        result.reserveCapacity(text.count)
        var sentenceTerminatorOrdinal = 0
        var shouldCapitalizeNextWord = targets.contains(.start)

        for character in text {
            if shouldCapitalizeNextWord {
                if character.isLowercase {
                    result += character.uppercased()
                    shouldCapitalizeNextWord = false
                    continue
                }
                if character.isLetter || character.isNumber {
                    shouldCapitalizeNextWord = false
                }
            }

            result.append(character)

            if isSentenceTerminator(character) {
                sentenceTerminatorOrdinal += 1
                if sentenceTargets.contains(sentenceTerminatorOrdinal) {
                    shouldCapitalizeNextWord = true
                }
            } else if shouldCapitalizeNextWord,
                      !character.isWhitespace,
                      !isBoundaryWrapper(character),
                      !isOrphanSeparator(character) {
                shouldCapitalizeNextWord = false
            }
        }

        return result
    }

    private static func isSentenceTerminator(_ character: Character) -> Bool {
        character == "." || character == "!" || character == "?"
    }

    private static func isBoundaryWrapper(_ character: Character) -> Bool {
        "\"'“”‘’([{".contains(character)
    }

    private static func isOrphanSeparator(_ character: Character) -> Bool {
        ",.;:!?".contains(character)
    }
}

// MARK: - Recording lifecycle decisions

private enum RecordingReleaseAction: Equatable {
    case discardTooShort(duration: Double)
    case transcribe(duration: Double)
}

private func recordingReleaseAction(capturedSampleCount: Int,
                                    sampleRate: Double = SAMPLE_RATE,
                                    minimumClipSeconds: Double = MIN_CLIP_SECONDS) -> RecordingReleaseAction {
    let duration = sampleRate > 0 ? Double(max(0, capturedSampleCount)) / sampleRate : 0
    return duration < minimumClipSeconds
        ? .discardTooShort(duration: duration)
        : .transcribe(duration: duration)
}

private struct DictationTextProcessingResult: Equatable {
    let text: String
    let appliedCorrectionCount: Int
    let removedFillerWordCount: Int
}

private func processedDictationText(rawTranscript: String,
                                    corrections: [TranscriptCorrection],
                                    removeFillerWords: Bool,
                                    language: DictationLanguage = .auto) -> DictationTextProcessingResult {
    let trimmed = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    let repaired = SpeechModelTextRepair.apply(to: trimmed, language: language)
    let corrected = TranscriptCorrector.apply(to: repaired, corrections: corrections)

    guard removeFillerWords else {
        return DictationTextProcessingResult(text: corrected.text,
                                             appliedCorrectionCount: corrected.appliedCount,
                                             removedFillerWordCount: 0)
    }

    let stripped = FillerWordRemover.apply(to: corrected.text)
    return DictationTextProcessingResult(text: stripped.text,
                                         appliedCorrectionCount: corrected.appliedCount,
                                         removedFillerWordCount: stripped.removedCount)
}

// MARK: - Text insertion
//
// Default path: write to general pasteboard, post Cmd+V. If that setup
// fails, fall back to direct Unicode events so a pasteboard problem
// does not automatically lose the transcript. After a successful paste
// event, restore the previous clipboard if it is still at our temporary
// write, so dictation doesn't replace what the user had copied before
// speaking.

func pastedText(from correctedTranscript: String, suffix: PasteSuffix) -> String {
    switch suffix {
    case .appendSpace:
        return correctedTranscript + " "
    case .none:
        return correctedTranscript
    case .appendNewline:
        return correctedTranscript + "\n"
    }
}

func speechModelStartupStatusTitle(_ progress: DownloadUtils.DownloadProgress) -> String {
    switch progress.phase {
    case .listing:
        return "Checking speech model files…"
    case .downloading(let completedFiles, let totalFiles):
        guard totalFiles > 0 else { return "Loading cached speech model…" }
        let downloadFraction = min(max(progress.fractionCompleted / 0.5, 0), 1)
        let percent = min(100, max(0, Int((downloadFraction * 20).rounded()) * 5))
        return "Downloading speech model… \(percent)% (\(completedFiles)/\(totalFiles))"
    case .compiling:
        return "Preparing speech model…"
    }
}

func speechModelStartupProgressValue(_ progress: DownloadUtils.DownloadProgress) -> Double? {
    switch progress.phase {
    case .downloading(_, let totalFiles):
        guard totalFiles > 0 else { return nil }
        return min(max(progress.fractionCompleted / 0.5, 0), 1)
    case .listing, .compiling:
        return nil
    }
}

enum TextInsertionStrategy: String {
    case clipboardPaste
    case directUnicode

    var displayName: String {
        switch self {
        case .clipboardPaste: return "Clipboard paste"
        case .directUnicode: return "Direct Unicode typing"
        }
    }
}

struct InsertionTargetScreenGeometry: Sendable {
    let frame: NSRect
    let visibleFrame: NSRect
}

struct InsertionTargetQueryContext: Sendable {
    let applicationPID: pid_t
    let applicationName: String
    let bundleIdentifier: String
    let screens: [InsertionTargetScreenGeometry]
    let coordinateReferenceMaxY: CGFloat
    let lastClickPoint: NSPoint?
}

struct FocusedInsertionTargetIdentity: Equatable, Sendable {
    let applicationPID: pid_t
    let windowToken: UInt
    let elementToken: UInt
}

struct FocusedInsertionTargetFrame: Sendable {
    let frame: NSRect
    let visualFrame: NSRect
    let resolutionKind: String
    let identity: FocusedInsertionTargetIdentity
}

struct FocusedInsertionTargetQueryResult: Sendable {
    let applicationPID: pid_t
    let applicationName: String
    let bundleIdentifier: String
    let focusedWindowFrame: NSRect?
    let focusedWindowToken: UInt
    let target: FocusedInsertionTargetFrame?
    let diagnostic: String
}

enum RecordingHUDTargetDecision {
    case none
    case update(FocusedInsertionTargetFrame)
    case switchTarget(FocusedInsertionTargetFrame)
}

struct RecordingHUDTargetStabilizer {
    private(set) var initialApplicationPID: pid_t?
    private(set) var confirmedIdentity: FocusedInsertionTargetIdentity?
    private var pendingIdentity: FocusedInsertionTargetIdentity?
    private var pendingCount = 0

    mutating func reset(initialApplicationPID: pid_t?) {
        self.initialApplicationPID = initialApplicationPID
        confirmedIdentity = nil
        pendingIdentity = nil
        pendingCount = 0
    }

    mutating func observe(_ target: FocusedInsertionTargetFrame?) -> RecordingHUDTargetDecision {
        guard let target else {
            pendingIdentity = nil
            pendingCount = 0
            return .none
        }

        if confirmedIdentity == target.identity {
            pendingIdentity = nil
            pendingCount = 0
            return .update(target)
        }

        let requiredCount: Int
        if let confirmedIdentity {
            requiredCount = confirmedIdentity.applicationPID == target.identity.applicationPID ? 2 : 3
        } else {
            requiredCount = initialApplicationPID == target.identity.applicationPID ? 1 : 3
        }

        if pendingIdentity == target.identity {
            pendingCount += 1
        } else {
            pendingIdentity = target.identity
            pendingCount = 1
        }

        guard pendingCount >= requiredCount else { return .none }
        confirmedIdentity = target.identity
        pendingIdentity = nil
        pendingCount = 0
        return .switchTarget(target)
    }
}

actor FocusedInsertionTargetTracker {
    func query(context: InsertionTargetQueryContext) -> FocusedInsertionTargetQueryResult {
        FocusedInsertionTargetLocator.query(context: context)
    }
}

private enum FocusedInsertionTargetLocator {
    private static let editableAttributeName = "AXEditable"
    private static let frameAttributeName = "AXFrame"
    private static let selectedTextMarkerRangeAttributeName = "AXSelectedTextMarkerRange"
    private static let boundsForTextMarkerRangeAttributeName = "AXBoundsForTextMarkerRange"
    private static let textElementRoles: Set<String> = [
        "AXTextField",
        "AXTextArea",
        "AXComboBox",
    ]
    private static let textElementSubroles: Set<String> = [
        "AXSearchField",
    ]
    private static let queryBudget: TimeInterval = 0.28
    private static let messagingTimeout: Float = 0.16
    private static let maximumScannedElements = 900
    private static let maximumScanDepth = 20

    private struct SearchNode {
        let element: AXUIElement
        let depth: Int
        let assumeFocused: Bool
    }

    static func query(context: InsertionTargetQueryContext) -> FocusedInsertionTargetQueryResult {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let deadline = startedAt + queryBudget
        guard AXIsProcessTrusted() else {
            return result(context: context,
                          focusedWindowFrame: nil,
                          focusedWindowToken: 0,
                          target: nil,
                          detail: "accessibility permission unavailable",
                          startedAt: startedAt)
        }

        let app = AXUIElementCreateApplication(context.applicationPID)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)

        let focusedResult = copyAttribute(app, kAXFocusedUIElementAttribute as CFString)
        let focused = axElement(from: focusedResult.value)
        let focusedRole = focused.flatMap {
            stringAttribute($0, attribute: kAXRoleAttribute as CFString)
        } ?? "none"

        let focusedWindow = focused.flatMap(windowElement(for:))
            ?? elementAttribute(app, kAXFocusedWindowAttribute as CFString)
            ?? elementAttribute(app, kAXMainWindowAttribute as CFString)
        if let focusedWindow {
            AXUIElementSetMessagingTimeout(focusedWindow, messagingTimeout)
        }
        let focusedWindowFrame = focusedWindow.flatMap {
            elementFrame($0, context: context)
        }
        let focusedWindowToken = focusedWindow.map(CFHash) ?? 0

        if let focused {
            AXUIElementSetMessagingTimeout(focused, messagingTimeout)
            if let target = directTargetFrame(in: focused,
                                              assumeFocused: true,
                                              allowUnfocusedTextElement: false,
                                              resolutionPrefix: "focused",
                                              windowToken: focusedWindowToken,
                                              context: context) {
                return result(context: context,
                              focusedWindowFrame: focusedWindowFrame,
                              focusedWindowToken: focusedWindowToken,
                              target: target,
                              detail: "focused=\(focusedRole), direct",
                              startedAt: startedAt)
            }
        }

        if let clickPoint = context.lastClickPoint,
           focusedWindowFrame?.insetBy(dx: -8, dy: -8).contains(clickPoint) != false,
           let target = targetAtLastClick(clickPoint,
                                          app: app,
                                          windowToken: focusedWindowToken,
                                          context: context) {
            return result(context: context,
                          focusedWindowFrame: focusedWindowFrame,
                          focusedWindowToken: focusedWindowToken,
                          target: target,
                          detail: "focused=\(focusedRole), click hit-test",
                          startedAt: startedAt)
        }

        var scannedCount = 0
        if let focused,
           let target = findFocusedTextTarget(in: focused,
                                              rootAssumeFocused: true,
                                              windowToken: focusedWindowToken,
                                              context: context,
                                              deadline: deadline,
                                              scannedCount: &scannedCount) {
            return result(context: context,
                          focusedWindowFrame: focusedWindowFrame,
                          focusedWindowToken: focusedWindowToken,
                          target: target,
                          detail: "focused=\(focusedRole), focused subtree, scanned=\(scannedCount)",
                          startedAt: startedAt)
        }

        if let focusedWindow,
           ProcessInfo.processInfo.systemUptime < deadline,
           let target = findFocusedTextTarget(in: focusedWindow,
                                              rootAssumeFocused: false,
                                              windowToken: focusedWindowToken,
                                              context: context,
                                              deadline: deadline,
                                              scannedCount: &scannedCount) {
            return result(context: context,
                          focusedWindowFrame: focusedWindowFrame,
                          focusedWindowToken: focusedWindowToken,
                          target: target,
                          detail: "focused=\(focusedRole), window scan, scanned=\(scannedCount)",
                          startedAt: startedAt)
        }

        let budgetExpired = ProcessInfo.processInfo.systemUptime >= deadline
        return result(context: context,
                      focusedWindowFrame: focusedWindowFrame,
                      focusedWindowToken: focusedWindowToken,
                      target: nil,
                      detail: "focusedError=\(focusedResult.error.rawValue), focused=\(focusedRole), scanned=\(scannedCount), budgetExpired=\(budgetExpired)",
                      startedAt: startedAt)
    }

    private static func result(context: InsertionTargetQueryContext,
                               focusedWindowFrame: NSRect?,
                               focusedWindowToken: UInt,
                               target: FocusedInsertionTargetFrame?,
                               detail: String,
                               startedAt: TimeInterval) -> FocusedInsertionTargetQueryResult {
        let elapsedMilliseconds = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
        return FocusedInsertionTargetQueryResult(
            applicationPID: context.applicationPID,
            applicationName: context.applicationName,
            bundleIdentifier: context.bundleIdentifier,
            focusedWindowFrame: focusedWindowFrame,
            focusedWindowToken: focusedWindowToken,
            target: target,
            diagnostic: "\(detail), \(String(format: "%.1f", elapsedMilliseconds)) ms"
        )
    }

    private static func findFocusedTextTarget(in root: AXUIElement,
                                              rootAssumeFocused: Bool,
                                              windowToken: UInt,
                                              context: InsertionTargetQueryContext,
                                              deadline: TimeInterval,
                                              scannedCount: inout Int) -> FocusedInsertionTargetFrame? {
        var queue = [SearchNode(element: root, depth: 0, assumeFocused: rootAssumeFocused)]
        var queueIndex = 0
        var visited: Set<UInt> = []

        while queueIndex < queue.count,
              scannedCount < maximumScannedElements,
              ProcessInfo.processInfo.systemUptime < deadline {
            let node = queue[queueIndex]
            queueIndex += 1
            let token = CFHash(node.element)
            guard visited.insert(token).inserted else { continue }
            scannedCount += 1
            AXUIElementSetMessagingTimeout(node.element, messagingTimeout)

            let reportsFocus = boolAttribute(node.element,
                                             attribute: kAXFocusedAttribute as CFString) == true
            if node.assumeFocused || reportsFocus,
               let target = directTargetFrame(in: node.element,
                                              assumeFocused: true,
                                              allowUnfocusedTextElement: false,
                                              resolutionPrefix: node.depth == 0 ? "focused" : "window scan",
                                              windowToken: windowToken,
                                              context: context) {
                return target
            }

            guard node.depth < maximumScanDepth else { continue }
            if let nestedFocused = elementAttribute(node.element,
                                                    kAXFocusedUIElementAttribute as CFString),
               !CFEqual(nestedFocused, node.element) {
                queue.append(SearchNode(element: nestedFocused,
                                        depth: node.depth + 1,
                                        assumeFocused: true))
            }
            for selected in elementArrayAttribute(node.element,
                                                  kAXSelectedChildrenAttribute as CFString) {
                queue.append(SearchNode(element: selected,
                                        depth: node.depth + 1,
                                        assumeFocused: false))
            }
            for child in elementArrayAttribute(node.element, kAXChildrenAttribute as CFString) {
                queue.append(SearchNode(element: child,
                                        depth: node.depth + 1,
                                        assumeFocused: false))
            }
        }
        return nil
    }

    private static func targetAtLastClick(_ point: NSPoint,
                                          app: AXUIElement,
                                          windowToken: UInt,
                                          context: InsertionTargetQueryContext) -> FocusedInsertionTargetFrame? {
        let axPoint = NSPoint(x: point.x,
                              y: context.coordinateReferenceMaxY - point.y)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app,
                                              Float(axPoint.x),
                                              Float(axPoint.y),
                                              &hit) == .success,
              var current = hit else {
            return nil
        }

        for _ in 0..<8 {
            AXUIElementSetMessagingTimeout(current, messagingTimeout)
            if let target = directTargetFrame(in: current,
                                              assumeFocused: false,
                                              allowUnfocusedTextElement: true,
                                              resolutionPrefix: "click",
                                              windowToken: windowToken,
                                              context: context) {
                return target
            }
            guard let parent = elementAttribute(current, kAXParentAttribute as CFString),
                  !CFEqual(parent, current) else {
                break
            }
            current = parent
        }
        return nil
    }

    private static func directTargetFrame(in element: AXUIElement,
                                          assumeFocused: Bool,
                                          allowUnfocusedTextElement: Bool,
                                          resolutionPrefix: String,
                                          windowToken: UInt,
                                          context: InsertionTargetQueryContext) -> FocusedInsertionTargetFrame? {
        let reportsFocus = boolAttribute(element,
                                         attribute: kAXFocusedAttribute as CFString) == true
        let isTextInputElement = isTextInputElement(element)
        guard assumeFocused || reportsFocus || (allowUnfocusedTextElement && isTextInputElement) else {
            return nil
        }

        let identity = FocusedInsertionTargetIdentity(
            applicationPID: context.applicationPID,
            windowToken: windowToken,
            elementToken: CFHash(element)
        )
        let elementFrame = elementFrame(element, context: context)
        if isTextInputElement,
           let caret = caretFrame(in: element, context: context) {
            let visualFrame: NSRect
            if let elementFrame,
               isTextInputElement,
               isReasonableTextInputFrame(elementFrame, near: caret.frame, context: context) {
                visualFrame = visualTargetFrame(elementFrame: elementFrame,
                                                caretFrame: caret.frame,
                                                context: context)
            } else {
                visualFrame = caret.frame
            }
            return FocusedInsertionTargetFrame(
                frame: caret.frame,
                visualFrame: visualFrame,
                resolutionKind: "\(resolutionPrefix) \(caret.resolutionKind)",
                identity: identity
            )
        }

        guard isTextInputElement,
              let elementFrame,
              isReasonableTextInputFrame(elementFrame, near: elementFrame, context: context) else {
            return nil
        }
        return FocusedInsertionTargetFrame(
            frame: elementFrame,
            visualFrame: elementFrame,
            resolutionKind: "\(resolutionPrefix) text element",
            identity: identity
        )
    }

    static func visualTargetFrame(elementFrame: NSRect,
                                  caretFrame: NSRect,
                                  context: InsertionTargetQueryContext) -> NSRect {
        guard let visible = visibleFrame(containing: NSPoint(x: caretFrame.midX,
                                                             y: caretFrame.midY),
                                         context: context),
              elementFrame.height > max(220, visible.height * 0.34) else {
            return elementFrame
        }

        // A native document editor often exposes its entire page as one
        // AXTextArea. Keep the block's left edge, but anchor vertically to
        // the current line instead of placing the HUD above the whole page.
        return NSRect(x: elementFrame.minX,
                      y: caretFrame.minY,
                      width: elementFrame.width,
                      height: caretFrame.height)
    }

    private static func isTextInputElement(_ element: AXUIElement) -> Bool {
        let role = stringAttribute(element, attribute: kAXRoleAttribute as CFString) ?? ""
        let subrole = stringAttribute(element, attribute: kAXSubroleAttribute as CFString) ?? ""
        if textElementRoles.contains(role) || textElementSubroles.contains(subrole) {
            return true
        }
        if boolAttribute(element, attribute: editableAttributeName as CFString) == true {
            return true
        }
        let hasSelectedRange = copyAttribute(element,
                                             kAXSelectedTextRangeAttribute as CFString).error == .success
        return hasSelectedRange
            && (isAttributeSettable(element, kAXValueAttribute as CFString)
                || isAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString))
    }

    private static func caretFrame(in element: AXUIElement,
                                   context: InsertionTargetQueryContext) -> (frame: NSRect, resolutionKind: String)? {
        let markerRange = copyAttribute(element, selectedTextMarkerRangeAttributeName as CFString)
        if markerRange.error == .success,
           let markerRangeValue = markerRange.value {
            var boundsRaw: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(element,
                                                          boundsForTextMarkerRangeAttributeName as CFString,
                                                          markerRangeValue,
                                                          &boundsRaw) == .success,
               let rect = cgRect(from: boundsRaw),
               let caret = normalizedCaretRect(rect) {
                return (appKitRect(fromAXRect: caret, context: context), "caret marker")
            }
        }

        let rangeResult = copyAttribute(element, kAXSelectedTextRangeAttribute as CFString)
        guard rangeResult.error == .success,
              let rangeRaw = rangeResult.value,
              CFGetTypeID(rangeRaw) == AXValueGetTypeID() else {
            return nil
        }
        let rangeValue = unsafeDowncast(rangeRaw, to: AXValue.self)
        guard AXValueGetType(rangeValue) == .cfRange else { return nil }

        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range) else { return nil }
        let candidates = [range, CFRange(location: range.location, length: max(range.length, 1))]
        for candidate in candidates {
            var candidateRange = candidate
            guard let candidateValue = AXValueCreate(.cfRange, &candidateRange) else { continue }
            var boundsRaw: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXBoundsForRangeParameterizedAttribute as CFString,
                candidateValue,
                &boundsRaw
            ) == .success,
            let rect = cgRect(from: boundsRaw),
            let caret = normalizedCaretRect(rect) else {
                continue
            }
            return (appKitRect(fromAXRect: caret, context: context), "caret range")
        }
        return nil
    }

    private static func normalizedCaretRect(_ rect: CGRect) -> CGRect? {
        guard rect.minX.isFinite,
              rect.minY.isFinite,
              rect.width.isFinite,
              rect.height.isFinite,
              rect.width >= 0,
              rect.height > 0,
              rect.height <= 120,
              rect.width <= max(12, rect.height * 1.5) else {
            return nil
        }
        return rect.width > 0
            ? rect
            : CGRect(x: rect.origin.x, y: rect.origin.y, width: 2, height: rect.height)
    }

    private static func elementFrame(_ element: AXUIElement,
                                     context: InsertionTargetQueryContext) -> NSRect? {
        let directFrame = copyAttribute(element, frameAttributeName as CFString)
        if directFrame.error == .success,
           let rect = cgRect(from: directFrame.value),
           rect.width > 0,
           rect.height > 0 {
            return appKitRect(fromAXRect: rect, context: context)
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard axPoint(element, attribute: kAXPositionAttribute as CFString, value: &position),
              axSize(element, attribute: kAXSizeAttribute as CFString, value: &size),
              size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0 else {
            return nil
        }
        return appKitRect(fromAXRect: CGRect(origin: position, size: size), context: context)
    }

    private static func isReasonableTextInputFrame(_ frame: NSRect,
                                                   near anchor: NSRect,
                                                   context: InsertionTargetQueryContext) -> Bool {
        guard frame.minX.isFinite,
              frame.minY.isFinite,
              frame.width.isFinite,
              frame.height.isFinite,
              frame.width > 0,
              frame.height > 0 else {
            return false
        }
        guard frame.insetBy(dx: -8, dy: -8).contains(NSPoint(x: anchor.midX, y: anchor.midY)) else {
            return false
        }
        guard let visible = visibleFrame(containing: NSPoint(x: anchor.midX, y: anchor.midY),
                                         context: context) else {
            return false
        }
        if frame.width > visible.width * 0.92,
           frame.height > visible.height * 0.55 {
            return false
        }
        return frame.height <= visible.height * 0.82
    }

    private static func visibleFrame(containing point: NSPoint,
                                     context: InsertionTargetQueryContext) -> NSRect? {
        if let screen = context.screens.first(where: { $0.frame.contains(point) }) {
            return screen.visibleFrame
        }
        return context.screens.first?.visibleFrame
    }

    private static func windowElement(for element: AXUIElement) -> AXUIElement? {
        elementAttribute(element, kAXWindowAttribute as CFString)
            ?? elementAttribute(element, kAXTopLevelUIElementAttribute as CFString)
    }

    private static func copyAttribute(_ element: AXUIElement,
                                      _ attribute: CFString) -> (error: AXError, value: CFTypeRef?) {
        var raw: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &raw)
        return (error, raw)
    }

    private static func axElement(from raw: CFTypeRef?) -> AXUIElement? {
        guard let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(raw, to: AXUIElement.self)
    }

    private static func elementAttribute(_ element: AXUIElement,
                                         _ attribute: CFString) -> AXUIElement? {
        axElement(from: copyAttribute(element, attribute).value)
    }

    private static func elementArrayAttribute(_ element: AXUIElement,
                                              _ attribute: CFString) -> [AXUIElement] {
        let result = copyAttribute(element, attribute)
        guard result.error == .success, let raw = result.value else { return [] }
        if let single = axElement(from: raw) { return [single] }
        return raw as? [AXUIElement] ?? []
    }

    private static func stringAttribute(_ element: AXUIElement,
                                        attribute: CFString) -> String? {
        let result = copyAttribute(element, attribute)
        guard result.error == .success else { return nil }
        return result.value as? String
    }

    private static func boolAttribute(_ element: AXUIElement,
                                      attribute: CFString) -> Bool? {
        let result = copyAttribute(element, attribute)
        guard result.error == .success else { return nil }
        return result.value as? Bool
    }

    private static func isAttributeSettable(_ element: AXUIElement,
                                            _ attribute: CFString) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute, &settable) == .success
            && settable.boolValue
    }

    private static func cgRect(from raw: CFTypeRef?) -> CGRect? {
        guard let raw,
              CFGetTypeID(raw) == AXValueGetTypeID() else {
            return nil
        }
        let value = unsafeDowncast(raw, to: AXValue.self)
        guard AXValueGetType(value) == .cgRect else { return nil }
        var rect = CGRect.zero
        return AXValueGetValue(value, .cgRect, &rect) ? rect : nil
    }

    private static func axPoint(_ element: AXUIElement,
                                attribute: CFString,
                                value: inout CGPoint) -> Bool {
        let result = copyAttribute(element, attribute)
        guard result.error == .success,
              let raw = result.value,
              CFGetTypeID(raw) == AXValueGetTypeID() else {
            return false
        }
        let axValue = unsafeDowncast(raw, to: AXValue.self)
        return AXValueGetType(axValue) == .cgPoint
            && AXValueGetValue(axValue, .cgPoint, &value)
    }

    private static func axSize(_ element: AXUIElement,
                               attribute: CFString,
                               value: inout CGSize) -> Bool {
        let result = copyAttribute(element, attribute)
        guard result.error == .success,
              let raw = result.value,
              CFGetTypeID(raw) == AXValueGetTypeID() else {
            return false
        }
        let axValue = unsafeDowncast(raw, to: AXValue.self)
        return AXValueGetType(axValue) == .cgSize
            && AXValueGetValue(axValue, .cgSize, &value)
    }

    private static func appKitRect(fromAXRect rect: CGRect,
                                   context: InsertionTargetQueryContext) -> NSRect {
        NSRect(x: rect.origin.x,
               y: context.coordinateReferenceMaxY - rect.origin.y - rect.height,
               width: rect.width,
               height: rect.height)
    }
}

func textInsertionStrategyChain(primary: TextInsertionStrategy) -> [TextInsertionStrategy] {
    switch primary {
    case .clipboardPaste:
        return [.clipboardPaste, .directUnicode]
    case .directUnicode:
        return [.directUnicode]
    }
}

func textInsertionStrategyDescription(primary: TextInsertionStrategy) -> String {
    let strategies = textInsertionStrategyChain(primary: primary).map(\.displayName)
    guard let first = strategies.first else { return "Unavailable" }
    guard strategies.count > 1 else { return first }
    return "\(first) with \(strategies.dropFirst().joined(separator: ", ")) fallback"
}

func unicodeInsertionChunks(for text: String, maxUTF16UnitsPerEvent maxUnits: Int) -> [[UInt16]] {
    guard maxUnits > 0 else { return [] }
    var chunks: [[UInt16]] = []
    var current: [UInt16] = []

    for character in text {
        let units = Array(String(character).utf16)
        if units.count > maxUnits {
            if !current.isEmpty {
                chunks.append(current)
                current.removeAll(keepingCapacity: true)
            }
            chunks.append(units)
            continue
        }
        if !current.isEmpty, current.count + units.count > maxUnits {
            chunks.append(current)
            current.removeAll(keepingCapacity: true)
        }
        current.append(contentsOf: units)
    }

    if !current.isEmpty {
        chunks.append(current)
    }
    return chunks
}

private struct KeyboardEventStep: Equatable {
    let virtualKey: CGKeyCode
    let keyDown: Bool
    let flags: CGEventFlags
}

private func clipboardPasteKeyboardEventSteps(commandKey: CGKeyCode,
                                              pasteKey: CGKeyCode) -> [KeyboardEventStep] {
    [
        KeyboardEventStep(virtualKey: commandKey, keyDown: true, flags: .maskCommand),
        KeyboardEventStep(virtualKey: pasteKey, keyDown: true, flags: .maskCommand),
        KeyboardEventStep(virtualKey: pasteKey, keyDown: false, flags: .maskCommand),
        KeyboardEventStep(virtualKey: commandKey, keyDown: false, flags: []),
    ]
}

private func postKeyboardEventSteps(_ steps: [KeyboardEventStep]) -> Bool {
    let source = CGEventSource(stateID: .hidSystemState)
    let events = steps.compactMap { step -> CGEvent? in
        guard let event = CGEvent(keyboardEventSource: source,
                                  virtualKey: step.virtualKey,
                                  keyDown: step.keyDown) else {
            return nil
        }
        event.flags = step.flags
        return event
    }
    guard events.count == steps.count else { return false }

    for event in events {
        event.post(tap: .cghidEventTap)
    }
    return true
}

@MainActor
private enum KeyboardShortcutPoster {
    @discardableResult
    static func postReturn() -> Bool {
        postKeyboardEventSteps([
            KeyboardEventStep(virtualKey: RETURN_KEYCODE, keyDown: true, flags: []),
            KeyboardEventStep(virtualKey: RETURN_KEYCODE, keyDown: false, flags: []),
        ])
    }
}

@MainActor
enum TextInserter {
    nonisolated static let defaultStrategy = TextInsertionStrategy.clipboardPaste

    nonisolated static var defaultStrategyDescription: String {
        textInsertionStrategyDescription(primary: defaultStrategy)
    }

    @discardableResult
    static func insert(_ text: String, strategy: TextInsertionStrategy = defaultStrategy) -> Bool {
        for candidate in textInsertionStrategyChain(primary: strategy) {
            if insert(text, using: candidate) {
                if candidate != strategy {
                    log("text insertion fallback succeeded: \(candidate.displayName)")
                }
                return true
            }
            log("text insertion attempt failed: \(candidate.displayName)")
        }
        return false
    }

    private static func insert(_ text: String, using strategy: TextInsertionStrategy) -> Bool {
        switch strategy {
        case .clipboardPaste:
            return ClipboardPasteInserter.insert(text)
        case .directUnicode:
            return DirectUnicodeInserter.insert(text)
        }
    }
}

@MainActor
private enum ClipboardPasteInserter {
    private static let virtualKeyCommand: CGKeyCode = 0x37  // left Command
    private static let virtualKeyV: CGKeyCode = 0x09  // ANSI 'v'
    private static let restoreDelay: TimeInterval = 0.35

    static func write(_ text: String, to pb: NSPasteboard) -> Bool {
        pb.clearContents()
        return pb.setString(text, forType: .string)
    }

    static func insert(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        let previous = PasteboardSnapshot.capture(from: pasteboard)
        guard write(text, to: pasteboard) else {
            log("pasteboard write failed")
            return false
        }
        let transientChangeCount = pasteboard.changeCount

        let steps = clipboardPasteKeyboardEventSteps(commandKey: virtualKeyCommand,
                                                     pasteKey: virtualKeyV)
        guard post(steps) else {
            log("paste event creation failed")
            previous.restore(to: pasteboard)
            return false
        }
        restorePasteboard(previous,
                          ifStillTemporaryText: text,
                          changeCount: transientChangeCount,
                          pasteboard: pasteboard)
        return true
    }

    private static func restorePasteboard(_ snapshot: PasteboardSnapshot,
                                          ifStillTemporaryText text: String,
                                          changeCount: Int,
                                          pasteboard: NSPasteboard) {
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
            guard pasteboard.changeCount == changeCount,
                  pasteboard.string(forType: .string) == text else {
                return
            }
            snapshot.restore(to: pasteboard)
        }
    }

    private static func post(_ steps: [KeyboardEventStep]) -> Bool {
        // Post Command as real key events instead of only tagging the V
        // events with .maskCommand. Sleep/wake can leave session modifier
        // state unreliable for flag-only synthetic shortcuts.
        return postKeyboardEventSteps(steps)
    }
}

@MainActor
private struct PasteboardSnapshot {
    private struct Item {
        let values: [(type: NSPasteboard.PasteboardType, data: Data)]
    }

    private let items: [Item]

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            Item(values: item.types.compactMap { type in
                guard let data = item.data(forType: type) else { return nil }
                return (type, data)
            })
        }
        return PasteboardSnapshot(items: items)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restoredItems = items.map { item -> NSPasteboardItem in
            let restored = NSPasteboardItem()
            for value in item.values {
                restored.setData(value.data, forType: value.type)
            }
            return restored
        }
        if !restoredItems.isEmpty {
            pasteboard.writeObjects(restoredItems)
        }
    }
}

@MainActor
private enum DirectUnicodeInserter {
    private static let maxUTF16UnitsPerEvent = 20

    static func insert(_ text: String) -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        var didPostAll = true

        for chunk in unicodeInsertionChunks(for: text, maxUTF16UnitsPerEvent: maxUTF16UnitsPerEvent) {
            didPostAll = post(chunk, source: source) && didPostAll
        }
        return didPostAll
    }

    private static func post(_ units: [UInt16], source: CGEventSource?) -> Bool {
        // Each chunk posts a keyDown AND a matching keyUp carrying the
        // same unicode payload — standard CGEvent unicode-typing
        // practice. A keyDown-only stream leaves apps that track key
        // state believing a key is still held.
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            return false
        }
        down.flags = []
        up.flags = []
        for event in [down, up] {
            units.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
            }
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}

// MARK: - System audio mute
//
// Mute the system output volume during recording so an open Zoom /
// Music / browser tab doesn't get captured back into the mic and
// transcribed alongside the user's voice. Done via NSAppleScript
// since there's no public AVFoundation knob for it. On release we
// only unmute if WE were the ones who muted — leave alone if the
// user had already muted manually.
//
// Threading: every AppleScript round-trip takes milliseconds at best
// and can stall for much longer under load. The hotkey path runs
// behind a session-wide CGEvent tap on the main run loop, where ANY
// main-thread stall delays every keystroke system-wide and a >1 s
// stall makes macOS disable the tap. So the recording-time mute /
// unmute scripts execute on a dedicated serial queue (the *Async
// wrappers below) and report back to the main actor. The serial
// queue is also the ordering guarantee: a mute enqueued before an
// unmute always executes before it. The synchronous isMuted() /
// unmute() remain for launch-time stale-mute recovery, which runs
// before the event tap exists.

/// Outcome of the "set volume with output muted" command plus its
/// follow-up verification read. The distinction matters for crash
/// recovery: a command that succeeded but could not be VERIFIED must
/// be assumed muted, so the recovery marker and watchdog stay armed.
/// Treating it as a failure would dismantle every recovery mechanism
/// for a mute that may well have happened, leaving the system muted
/// with no way back.
enum SystemAudioMuteCommandOutcome: Equatable, Sendable {
    /// Command ran without error and verification confirmed the
    /// output is muted.
    case muted
    /// Command ran without error but the verification read itself
    /// failed. Assume we muted: keeping recovery armed for a mute
    /// that didn't happen is harmless; the reverse is not.
    case assumedMuted
    /// The command itself failed, or verification definitively
    /// reported the output unmuted. Nothing happened to recover from.
    case failed
}

func systemAudioMuteCommandOutcome(commandSucceeded: Bool,
                                   verifiedMuted: Bool?) -> SystemAudioMuteCommandOutcome {
    guard commandSucceeded else { return .failed }
    switch verifiedMuted {
    case .some(true): return .muted
    case .none: return .assumedMuted
    case .some(false): return .failed
    }
}

enum SystemAudio {
    // NSAppleScript isn't Sendable so we can't memoise it across
    // threads under Swift 6 strict concurrency. AppleScript compile
    // is microseconds — happy to take the per-call cost. Each script
    // instance is created, executed, and discarded entirely on one
    // thread (this serial queue or, for the launch-time sync calls,
    // the main thread), which satisfies NSAppleScript's
    // not-thread-safe contract.
    private static let queue = DispatchQueue(label: "ParakeySystemAudio", qos: .userInitiated)

    /// nil = the query itself failed, as opposed to a definitive
    /// muted/unmuted answer.
    static func mutedState() -> Bool? {
        var err: NSDictionary?
        guard let script = NSAppleScript(source: "output muted of (get volume settings)") else {
            return nil
        }
        let result = script.executeAndReturnError(&err)
        guard err == nil else { return nil }
        return result.booleanValue
    }

    static func isMuted() -> Bool { mutedState() == true }

    static func mute() -> SystemAudioMuteCommandOutcome {
        guard let script = NSAppleScript(source: "set volume with output muted") else {
            return systemAudioMuteCommandOutcome(commandSucceeded: false, verifiedMuted: nil)
        }
        var err: NSDictionary?
        script.executeAndReturnError(&err)
        return systemAudioMuteCommandOutcome(commandSucceeded: err == nil,
                                             verifiedMuted: mutedState())
    }

    @discardableResult
    static func unmute() -> Bool {
        var err: NSDictionary?
        _ = NSAppleScript(source: "set volume without output muted")?.executeAndReturnError(&err)
        // A failed verification counts as "not unmuted": the caller
        // keeps the recovery marker + watchdog armed and retries
        // later, which is the safe direction.
        return err == nil && mutedState() == false
    }

    // Async wrappers — see the threading note above. Completions hop
    // back to the main actor, where all mute-lifecycle state lives.
    static func mutedStateAsync(_ completion: @escaping @MainActor @Sendable (Bool?) -> Void) {
        queue.async {
            let state = mutedState()
            Task { @MainActor in completion(state) }
        }
    }

    static func muteAsync(_ completion: @escaping @MainActor @Sendable (SystemAudioMuteCommandOutcome) -> Void) {
        queue.async {
            let outcome = mute()
            Task { @MainActor in completion(outcome) }
        }
    }

    static func unmuteAsync(_ completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        queue.async {
            let unmuted = unmute()
            Task { @MainActor in completion(unmuted) }
        }
    }
}

// MARK: - System audio mute lifecycle
//
// Pure decision functions for the recording-time mute state machine.
// All phase transitions happen on the main actor; only the
// AppleScript execution itself runs on SystemAudio's serial queue.
// At most one command is in flight at a time — each phase has exactly
// one outstanding completion, which performs the next transition.

enum SystemAudioMutePhase: Equatable, Sendable {
    /// No mute lifecycle active; marker + watchdog disarmed.
    case idle
    /// "is the output already muted?" probe in flight. No marker or
    /// watchdog yet, and nothing has been muted.
    case probing
    /// Marker + watchdog armed; the mute command is in flight.
    case muting
    /// We muted the output; marker + watchdog stay armed until an
    /// unmute succeeds (or the watchdog recovers after a crash).
    case muted
    /// Unmute command in flight; marker + watchdog stay armed until
    /// it succeeds.
    case unmuting
}

enum SystemAudioMuteProbeDecision: Equatable, Sendable {
    /// Do not mute: the output is already muted by the user, the
    /// probe failed (we can't risk stomping a user-set mute we can't
    /// see), or the recording already ended. Nothing to arm or undo.
    case standDown
    /// The output is live and the recording still wants it muted —
    /// arm the recovery marker + watchdog, then issue the mute.
    case armRecoveryAndMute
}

func systemAudioMuteProbeDecision(mutedState: Bool?,
                                  unmuteAlreadyRequested: Bool) -> SystemAudioMuteProbeDecision {
    guard mutedState == false, !unmuteAlreadyRequested else { return .standDown }
    return .armRecoveryAndMute
}

enum SystemAudioMuteCommandDecision: Equatable, Sendable {
    /// The mute definitively failed — disarm the marker + watchdog.
    case disarmRecovery
    /// We are (or must assume we are) muted and the recording is
    /// still running — hold the muted state.
    case stayMuted
    /// We muted, but the recording ended while the command ran —
    /// unmute immediately.
    case beginUnmute
}

func systemAudioMuteCommandDecision(outcome: SystemAudioMuteCommandOutcome,
                                    unmuteAlreadyRequested: Bool) -> SystemAudioMuteCommandDecision {
    switch outcome {
    case .failed:
        return .disarmRecovery
    case .muted, .assumedMuted:
        return unmuteAlreadyRequested ? .beginUnmute : .stayMuted
    }
}

enum SystemAudioUnmuteRequestDecision: Equatable, Sendable {
    /// We never muted (or an unmute is already in flight).
    case nothingToDo
    /// A probe or the mute command is still in flight — record the
    /// request; that command's completion honours it.
    case deferUntilCommandSettles
    /// We hold the mute — issue the unmute now.
    case beginUnmute
}

func systemAudioUnmuteRequestDecision(phase: SystemAudioMutePhase) -> SystemAudioUnmuteRequestDecision {
    switch phase {
    case .idle, .unmuting: return .nothingToDo
    case .probing, .muting: return .deferUntilCommandSettles
    case .muted: return .beginUnmute
    }
}

private func systemAudioMuteMarkerURL() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(APP_SUPPORT_DIR_NAME, isDirectory: true)
        .appendingPathComponent("system-audio-muted", isDirectory: false)
}

private func systemAudioMuteMarkerText(pid: pid_t = getpid(), date: Date = Date()) -> String {
    """
    pid=\(pid)
    created=\(ISO8601DateFormatter().string(from: date))
    """
}

private func systemAudioMuteMarkerProcessID(from text: String) -> pid_t? {
    for line in text.split(separator: "\n") {
        guard line.hasPrefix("pid="),
              let raw = Int32(line.dropFirst(4)),
              raw > 0 else { continue }
        return raw
    }
    return nil
}

private func writeSystemAudioMuteMarker(to url: URL = systemAudioMuteMarkerURL(),
                                        text: String = systemAudioMuteMarkerText()) throws {
    let fm = FileManager.default
    let directory = url.deletingLastPathComponent()
    try fm.createDirectory(at: directory,
                           withIntermediateDirectories: true,
                           attributes: [.posixPermissions: 0o700])

    let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw currentPOSIXError() }
    defer { Darwin.close(fd) }
    try text.withCString { raw in
        let data = UnsafeRawPointer(raw)
        let count = strlen(raw)
        var written = 0
        while written < count {
            let n = Darwin.write(fd, data.advanced(by: written), count - written)
            guard n >= 0 else { throw currentPOSIXError() }
            written += n
        }
    }
    _ = Darwin.fchmod(fd, 0o600)
}

private func removeSystemAudioMuteMarker(at url: URL = systemAudioMuteMarkerURL()) {
    try? FileManager.default.removeItem(at: url)
}

private func systemAudioMuteWatchdogScript() -> String {
    #"""
    PID="$1"
    MARKER="$2"

    while /bin/kill -0 "$PID" 2>/dev/null; do
        /bin/sleep 0.5
    done

    if [ -e "$MARKER" ]; then
        /usr/bin/osascript -e 'set volume without output muted' >/dev/null 2>&1 || true
        /bin/rm -f "$MARKER"
    fi
    """#
}

// MARK: - Sounds
//
// Short system sounds: Tink on recording start, Pop after a
// successful paste, Basso when a dictation is dropped. Loaded from
// /System/Library/Sounds so we don't have to bundle audio resources.

@MainActor
enum Sounds {
    private static let start = systemSound("Tink", volume: 0.55)
    private static let done = systemSound("Pop", volume: 0.45)
    private static let error = systemSound("Basso", volume: 0.30)

    private static func systemSound(_ name: String, volume: Float) -> NSSound? {
        let path = "/System/Library/Sounds/\(name).aiff"
        guard let sound = NSSound(contentsOfFile: path, byReference: true) else { return nil }
        sound.volume = volume
        return sound
    }

    static func playStart() { start?.stop(); start?.play() }
    static func playDone()  { done?.stop();  done?.play() }
    static func playError() { error?.stop(); error?.play() }
}

// MARK: - Bundle version helpers

func currentBundleVersion() -> String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
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

func formattedByteCount(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
}

// MARK: - Diagnostics
//
// User-triggered local diagnostics for GitHub issue triage. Keep the
// report useful but metadata-only: no transcript text and no text
// correction contents.

struct DiagnosticsReportSnapshot {
    let generated: String
    let appVersion: String
    let appBuild: String
    let macOS: String
    let bundleID: String
    let bundlePath: String
    let installKind: String
    let status: String
    let startup: String
    let speechModelReady: Bool
    let coreRuntimeReady: Bool
    let readyForDictation: Bool
    let recordingActive: Bool
    let transcribing: Bool
    let memoryLines: [String]
    let permissionLines: [String]
    let settingLines: [String]
    let updateLines: [String]
    let microphoneLines: [String]
    let logPath: String
    let recentLogLines: [String]
}

private func diagnosticBulletLines(_ lines: [String], emptyText: String) -> String {
    guard !lines.isEmpty else { return "- \(emptyText)" }
    return lines.map { "- \($0)" }.joined(separator: "\n")
}

func diagnosticsReportText(from snapshot: DiagnosticsReportSnapshot) -> String {
    """
    Parakey diagnostics
    Generated: \(snapshot.generated)
    App version: \(snapshot.appVersion) (\(snapshot.appBuild))
    macOS: \(snapshot.macOS)
    Bundle ID: \(snapshot.bundleID)
    Bundle path: \(snapshot.bundlePath)
    Install kind: \(snapshot.installKind)

    Status:
    - Menu: \(snapshot.status)
    - Startup: \(snapshot.startup)
    - Speech model ready: \(snapshot.speechModelReady)
    - Core runtime ready: \(snapshot.coreRuntimeReady)
    - Ready for dictation: \(snapshot.readyForDictation)
    - Recording active: \(snapshot.recordingActive)
    - Transcribing: \(snapshot.transcribing)

    Memory:
    \(diagnosticBulletLines(snapshot.memoryLines, emptyText: "Unavailable"))

    Permissions:
    \(diagnosticBulletLines(snapshot.permissionLines, emptyText: "Unavailable"))

    Settings:
    \(diagnosticBulletLines(snapshot.settingLines, emptyText: "Unavailable"))

    Update:
    \(diagnosticBulletLines(snapshot.updateLines, emptyText: "Unavailable"))

    Microphone:
    \(diagnosticBulletLines(snapshot.microphoneLines, emptyText: "Unavailable"))

    Recent log lines:
    \(diagnosticBulletLines(snapshot.recentLogLines, emptyText: "No recent log lines available"))

    Logs: \(snapshot.logPath)
    Privacy: transcript text and text-correction contents are not included.
    """
}

func recentDiagnosticLogLines(from url: URL = Logger.shared.fileURL,
                              maxBytes: Int = DIAGNOSTICS_LOG_MAX_BYTES,
                              maxLines: Int = DIAGNOSTICS_LOG_MAX_LINES) throws -> [String] {
    guard maxBytes > 0, maxLines > 0 else { return [] }

    let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else {
        if errno == ENOENT { return [] }
        throw currentPOSIXError()
    }
    defer { _ = Darwin.close(fd) }

    try validateSingleLinkRegularFileDescriptor(fd)

    var st = stat()
    guard Darwin.fstat(fd, &st) == 0 else { throw currentPOSIXError() }
    guard st.st_size > 0 else { return [] }

    let startOffset = max(Int64(0), Int64(st.st_size) - Int64(maxBytes))
    guard Darwin.lseek(fd, off_t(startOffset), SEEK_SET) >= 0 else {
        throw currentPOSIXError()
    }

    var data = Data()
    data.reserveCapacity(min(maxBytes, Int(st.st_size)))
    while data.count < maxBytes {
        let remaining = maxBytes - data.count
        var buffer = [UInt8](repeating: 0, count: min(8192, remaining))
        let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
            Darwin.read(fd, rawBuffer.baseAddress, rawBuffer.count)
        }
        if bytesRead < 0 {
            if errno == EINTR { continue }
            throw currentPOSIXError()
        }
        guard bytesRead > 0 else { break }
        data.append(buffer, count: bytesRead)
    }

    var text = String(decoding: data, as: UTF8.self)
    if startOffset > 0, let firstNewline = text.firstIndex(of: "\n") {
        text = String(text[text.index(after: firstNewline)...])
    }

    let sanitized = text
        .components(separatedBy: .newlines)
        .map(sanitizedDiagnosticLogLine)
        .filter { !$0.isEmpty }
    return Array(sanitized.suffix(maxLines))
}

private func sanitizedDiagnosticLogLine(_ line: String) -> String {
    var result = String()
    result.reserveCapacity(min(line.count, DIAGNOSTICS_LOG_MAX_LINE_CHARACTERS))
    for scalar in line.unicodeScalars {
        guard result.count < DIAGNOSTICS_LOG_MAX_LINE_CHARACTERS else { break }
        if scalar == "\t" || (scalar.value >= 0x20 && scalar.value != 0x7f) {
            result.unicodeScalars.append(scalar)
        } else {
            result.append(" ")
        }
    }
    return result.trimmingCharacters(in: .whitespaces)
}

func parseSemver(_ s: String) -> [Int] {
    // Strip leading whitespace + 'v', split on '.', take leading
    // digit run from each chunk. Tolerant by design; "" returns []
    // which compares less than any real version.
    let trimmed = s.trimmingCharacters(in: .whitespaces)
        .drop(while: { $0 == "v" || $0 == "V" })
    return trimmed.split(separator: ".").map { chunk in
        var n = 0
        var seen = false
        for c in chunk {
            guard let d = c.wholeNumberValue else { break }
            let multiplied = n.multipliedReportingOverflow(by: 10)
            if multiplied.overflow { return Int.max }
            let added = multiplied.partialValue.addingReportingOverflow(d)
            if added.overflow { return Int.max }
            n = added.partialValue
            seen = true
        }
        return seen ? n : 0
    }
}

func isNewer(_ candidate: String, than current: String) -> Bool {
    let a = parseSemver(candidate)
    let b = parseSemver(current)
    for i in 0..<max(a.count, b.count) {
        let x = i < a.count ? a[i] : 0
        let y = i < b.count ? b[i] : 0
        if x != y { return x > y }
    }
    return false
}

// MARK: - TCC recovery
//
// macOS's TCC database occasionally ends up with a DENIED entry
// for our bundle id that the user can't easily clear (typical
// trigger: an upgrade that changes the signed binary while a
// previous denial is still cached). On a fresh launch after an
// upgrade (CFBundleShortVersionString differs from
// settings.lastSeenVersion), we proactively `tccutil reset` any
// DENIED entry for `com.local.superdictate`. GRANTED entries stay
// intact — we never reset away permissions the user gave us.
//
// The companion to this is the click-twice-to-reset retry in the
// permission rows: if the user clicks a ⚠ row, sees the OS dialog
// say nothing useful, and clicks the same row again, the second
// click runs `tccutil reset` to clear stuck state and re-request.

enum TCC {
    /// Maps the human-readable permission name we use in the menu to
    /// the TCC service identifier `tccutil reset` accepts. Input
    /// Monitoring is "ListenEvent" internally.
    static let serviceName: [Permission: String] = [
        .microphone: "Microphone",
        .accessibility: "Accessibility",
        .inputMonitoring: "ListenEvent",
    ]

    /// Serial so multiple resets (e.g. the upgrade-recovery loop)
    /// execute in the order they were requested.
    private static let queue = DispatchQueue(label: "ParakeyTCCReset", qos: .userInitiated)

    /// Runs `tccutil reset` on a background queue. tccutil is usually
    /// quick but waitUntilExit() on the main thread would run behind
    /// the session-wide event tap, where any stall delays every
    /// keystroke system-wide. `completion`, if provided, is invoked
    /// on the main actor after the reset has finished — callers that
    /// re-request the permission must do so from the completion, or
    /// the request would race the scrub it depends on.
    static func reset(_ p: Permission,
                      bundleID: String,
                      completion: (@MainActor @Sendable () -> Void)? = nil) {
        guard let service = serviceName[p] else {
            if let completion { Task { @MainActor in completion() } }
            return
        }
        queue.async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            proc.arguments = ["reset", service, bundleID]
            proc.environment = systemToolProcessEnvironment()
            proc.standardOutput = Pipe()
            proc.standardError = Pipe()
            do {
                try proc.run()
                proc.waitUntilExit()
                log("  tccutil reset \(service) \(bundleID) → exit \(proc.terminationStatus)")
            } catch {
                log("  tccutil reset \(service) failed: \(error)")
            }
            if let completion { Task { @MainActor in completion() } }
        }
    }
}

// MARK: - Update check
//
// Hits the GitHub Releases API once at boot + every 6 h. Users can
// also force the same lookup from the menu. When a newer version is
// found AND it's not in the user's skipped list, a submenu inserts
// itself at the top of the menu: What's new / Update now / Remind me
// in 24 hours / Skip vX.Y.Z.

struct GitHubRelease: Sendable, Equatable {
    let tagName: String      // 'v0.1.7'
    let version: String      // '0.1.7' (no v)
    let body: String         // release notes, raw markdown
    let htmlURL: String
}

private struct GitHubReleaseResponse: Decodable {
    let tagName: String
    let body: String?
    let htmlURL: String?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case body
        case htmlURL = "html_url"
    }
}

/// Why an update check failed. Carried as a value (not a string) so
/// the manual-check alert can explain the actual problem instead of
/// blaming the network for everything; automatic ticks ignore it and
/// stay silent.
enum UpdateCheckFailure: Error, Equatable, Sendable {
    /// The HTTPS request itself failed (offline, DNS, timeout).
    case network
    /// GitHub answered with a non-2xx status (403 → likely API rate
    /// limiting).
    case httpStatus(Int)
    /// A response arrived but was oversized, malformed, or carried an
    /// unusable tag.
    case unexpectedResponse
}

/// User-facing explanation for a failed *manual* update check. Only
/// the alert behind "Check for Updates…" uses this — automatic and
/// settings-toggle checks never alert.
func manualUpdateCheckFailureText(_ failure: UpdateCheckFailure) -> String {
    switch failure {
    case .network:
        return "SuperDictate couldn't reach GitHub. Check your internet connection and try again."
    case .httpStatus(403):
        return "GitHub declined the update check (HTTP 403). This is usually temporary rate limiting — try again in a few minutes."
    case .httpStatus(let code):
        return "GitHub returned an error (HTTP \(code)). Try again later."
    case .unexpectedResponse:
        return "GitHub returned a response SuperDictate couldn't read. Try again later, or check the releases page on GitHub directly."
    }
}

enum UpdateCheck {
    private static let githubReleaseURLPathPrefix = "/shlgd/SuperDictate/releases/tag/"
    static let maxReleaseResponseBytes = 512 * 1024

    static func fetchLatest() async -> Result<GitHubRelease, UpdateCheckFailure> {
        var req = URLRequest(url: GITHUB_LATEST_RELEASE_URL)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // The privacy docs promise exactly this fixed token — no
        // version, device, or user identifiers. Must stay in sync with
        // docs/privacy/network-calls.json.
        req.setValue("superdictate-update-check", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        do {
            let (data, response) = try await session.data(for: req)
            return parseLatest(data: data, response: response)
        } catch {
            return .failure(.network)
        }
    }

    static func parseLatest(data: Data, response: URLResponse) -> Result<GitHubRelease, UpdateCheckFailure> {
        guard let http = response as? HTTPURLResponse else {
            return .failure(.unexpectedResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            return .failure(.httpStatus(http.statusCode))
        }
        guard data.count <= maxReleaseResponseBytes,
              let payload = try? JSONDecoder().decode(GitHubReleaseResponse.self, from: data) else {
            return .failure(.unexpectedResponse)
        }

        let tag = payload.tagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let version = normalizedReleaseVersion(from: tag) else {
            return .failure(.unexpectedResponse)
        }

        return .success(GitHubRelease(
            tagName: tag,
            version: version,
            body: payload.body ?? "",
            htmlURL: sanitizedReleaseURL(payload.htmlURL, expectedTag: tag)
        ))
    }

    static func normalizedReleaseVersion(from tag: String) -> String? {
        var version = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = version.first, first == "v" || first == "V" {
            version.removeFirst()
        }

        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        for part in parts {
            guard !part.isEmpty,
                  part.allSatisfy({ ("0"..."9").contains($0) }),
                  part == "0" || !part.hasPrefix("0"),
                  Int(part) != nil else {
                return nil
            }
        }
        return parts.joined(separator: ".")
    }

    static func sanitizedReleaseURL(_ value: String?, expectedTag: String) -> String {
        guard let value else { return GITHUB_RELEASES_PAGE.absoluteString }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme == "https",
              components.host == "github.com",
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path == "\(githubReleaseURLPathPrefix)\(expectedTag)" else {
            return GITHUB_RELEASES_PAGE.absoluteString
        }
        return trimmed
    }
}

struct SuperDictateUpdateManifest: Decodable, Equatable, Sendable {
    let version: String
    let sha256: String
}

struct PreparedSuperDictateUpdate: Sendable {
    let version: String
    let workDirectory: URL
    let stagedAppURL: URL
}

enum SuperDictateUpdateInstallerError: LocalizedError, Equatable, Sendable {
    case network
    case httpStatus(Int)
    case invalidManifest
    case manifestVersionMismatch(expected: String, actual: String)
    case archiveTooLarge
    case checksumMismatch
    case extractionFailed(String)
    case invalidBundle(String)
    case appNotWritable

    var errorDescription: String? { message(language: .russian) }

    func message(language: InterfaceLanguage) -> String {
        if language == .english {
            switch self {
            case .network:
                return "The update could not be downloaded. Check your internet connection."
            case .httpStatus(let code):
                return "The update server returned HTTP \(code)."
            case .invalidManifest:
                return "The update manifest is damaged or has an unknown format."
            case .manifestVersionMismatch(let expected, let actual):
                return "GitHub reports version \(expected), but the manifest reports \(actual). The update was stopped."
            case .archiveTooLarge:
                return "The update archive exceeds the allowed size."
            case .checksumMismatch:
                return "The archive checksum did not match. The application was not replaced."
            case .extractionFailed(let detail):
                return "The update could not be extracted: \(detail)"
            case .invalidBundle(let detail):
                return "The new application failed verification: \(detail)"
            case .appNotWritable:
                return "SuperDictate cannot replace the application in Applications. Run the regular installer once."
            }
        }
        switch self {
        case .network:
            return "Не удалось скачать обновление. Проверьте подключение к интернету."
        case .httpStatus(let code):
            return "Сервер обновлений вернул ошибку HTTP \(code)."
        case .invalidManifest:
            return "Манифест обновления повреждён или имеет неизвестный формат."
        case .manifestVersionMismatch(let expected, let actual):
            return "GitHub сообщает о версии \(expected), а манифест — о версии \(actual). Обновление остановлено."
        case .archiveTooLarge:
            return "Архив обновления превышает допустимый размер."
        case .checksumMismatch:
            return "Контрольная сумма архива не совпала. Приложение не будет заменено."
        case .extractionFailed(let detail):
            return "Не удалось распаковать обновление: \(detail)"
        case .invalidBundle(let detail):
            return "Проверка нового приложения не пройдена: \(detail)"
        case .appNotWritable:
            return "SuperDictate не может заменить приложение в папке Applications. Запустите обычный установщик один раз."
        }
    }
}

enum SuperDictateUpdateInstaller {
    private static let manifestMaxBytes = 16 * 1024

    static func fetchManifest(expectedVersion: String) async throws -> SuperDictateUpdateManifest {
        var request = URLRequest(url: GITHUB_UPDATE_MANIFEST_URL)
        request.setValue("superdictate-in-app-update", forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.timeoutInterval = 15
        let (data, response) = try await fetch(request: request, maxBytes: manifestMaxBytes)
        guard (200..<300).contains(response.statusCode) else {
            throw SuperDictateUpdateInstallerError.httpStatus(response.statusCode)
        }
        return try parseManifest(data, expectedVersion: expectedVersion)
    }

    static func parseManifest(_ data: Data,
                              expectedVersion: String) throws -> SuperDictateUpdateManifest {
        guard let manifest = try? JSONDecoder().decode(SuperDictateUpdateManifest.self, from: data),
              UpdateCheck.normalizedReleaseVersion(from: manifest.version) == manifest.version,
              manifest.sha256.count == 64,
              manifest.sha256.allSatisfy({ $0.isHexDigit }) else {
            throw SuperDictateUpdateInstallerError.invalidManifest
        }
        guard manifest.version == expectedVersion else {
            throw SuperDictateUpdateInstallerError.manifestVersionMismatch(
                expected: expectedVersion,
                actual: manifest.version
            )
        }
        return manifest
    }

    static func prepare(manifest: SuperDictateUpdateManifest) async throws -> PreparedSuperDictateUpdate {
        guard appCanBeReplaced(at: Bundle.main.bundleURL) else {
            throw SuperDictateUpdateInstallerError.appNotWritable
        }

        let archiveURL = URL(string: "https://github.com/shlgd/SuperDictate/releases/download/v\(manifest.version)/SuperDictate.zip")!
        var request = URLRequest(url: archiveURL)
        request.setValue("superdictate-in-app-update", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60
        let (archiveData, response) = try await fetch(request: request,
                                                      maxBytes: UPDATE_ARCHIVE_MAX_BYTES)
        guard (200..<300).contains(response.statusCode) else {
            throw SuperDictateUpdateInstallerError.httpStatus(response.statusCode)
        }

        var hasher = SHA256()
        hasher.update(data: archiveData)
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest.caseInsensitiveCompare(manifest.sha256) == .orderedSame else {
            throw SuperDictateUpdateInstallerError.checksumMismatch
        }

        let workDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("SuperDictate-update-\(UUID().uuidString)", isDirectory: true)
        let archiveFile = workDirectory.appendingPathComponent("SuperDictate.zip")
        let extractedDirectory = workDirectory.appendingPathComponent("release", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: extractedDirectory,
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try archiveData.write(to: archiveFile, options: [.atomic])
        } catch {
            try? FileManager.default.removeItem(at: workDirectory)
            throw SuperDictateUpdateInstallerError.extractionFailed(error.localizedDescription)
        }

        let extraction = await Task.detached(priority: .userInitiated) {
            SuperDictateAgentService.run("/usr/bin/ditto",
                                         ["-x", "-k", archiveFile.path, extractedDirectory.path])
        }.value
        guard extraction.status == 0 else {
            try? FileManager.default.removeItem(at: workDirectory)
            throw SuperDictateUpdateInstallerError.extractionFailed(extraction.output)
        }

        let stagedAppURL = extractedDirectory.appendingPathComponent("SuperDictate.app",
                                                                      isDirectory: true)
        do {
            try validateApp(at: stagedAppURL, expectedVersion: manifest.version)
        } catch let error as SuperDictateUpdateInstallerError {
            try? FileManager.default.removeItem(at: workDirectory)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: workDirectory)
            throw SuperDictateUpdateInstallerError.invalidBundle(error.localizedDescription)
        }
        return PreparedSuperDictateUpdate(version: manifest.version,
                                          workDirectory: workDirectory,
                                          stagedAppURL: stagedAppURL)
    }

    static func appCanBeReplaced(at appURL: URL) -> Bool {
        let fileManager = FileManager.default
        guard appURL.pathExtension == "app",
              fileManager.fileExists(atPath: appURL.path) else { return false }
        return fileManager.isWritableFile(atPath: appURL.path)
            && fileManager.isWritableFile(atPath: appURL.deletingLastPathComponent().path)
    }

    static func validateApp(at appURL: URL, expectedVersion: String) throws {
        let fileManager = FileManager.default
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        let executableURL = appURL.appendingPathComponent("Contents/MacOS/SuperDictate")
        guard appURL.lastPathComponent == "SuperDictate.app",
              fileManager.fileExists(atPath: infoURL.path),
              fileManager.isExecutableFile(atPath: executableURL.path),
              let infoData = try? Data(contentsOf: infoURL),
              let info = try? PropertyListSerialization.propertyList(from: infoData,
                                                                     format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "com.local.superdictate",
              info["CFBundleShortVersionString"] as? String == expectedVersion else {
            throw SuperDictateUpdateInstallerError.invalidBundle("неверный идентификатор или версия")
        }

        if let enumerator = fileManager.enumerator(at: appURL,
                                                   includingPropertiesForKeys: [.isSymbolicLinkKey],
                                                   options: []) {
            for case let itemURL as URL in enumerator {
                if (try? itemURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                    throw SuperDictateUpdateInstallerError.invalidBundle("архив содержит символическую ссылку")
                }
            }
        }

        let signature = SuperDictateAgentService.run("/usr/bin/codesign",
                                                      ["--verify", "--deep", "--strict", appURL.path])
        guard signature.status == 0 else {
            throw SuperDictateUpdateInstallerError.invalidBundle("codesign: \(signature.output)")
        }
    }

    private static func fetch(request: URLRequest,
                              maxBytes: Int) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = request.timeoutInterval
        configuration.timeoutIntervalForResource = request.timeoutInterval
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw SuperDictateUpdateInstallerError.network
            }
            guard data.count <= maxBytes else {
                throw SuperDictateUpdateInstallerError.archiveTooLarge
            }
            return (data, http)
        } catch let error as SuperDictateUpdateInstallerError {
            throw error
        } catch {
            throw SuperDictateUpdateInstallerError.network
        }
    }
}

func shellSingleQuoted(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
}

private func sanitizedEnvironmentValue(_ value: String?) -> String? {
    guard let value,
          !value.isEmpty,
          !value.utf8.contains(0),
          !value.contains(where: { $0.isNewline }) else {
        return nil
    }
    return value
}

private func trustedProcessEnvironment(path: String,
                                       current: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
    var env: [String: String] = [
        "HOME": NSHomeDirectory(),
        "PATH": path,
        "SHELL": "/bin/zsh",
        "TMPDIR": NSTemporaryDirectory(),
        "LANG": sanitizedEnvironmentValue(current["LANG"]) ?? "en_US.UTF-8",
    ]

    if let user = sanitizedEnvironmentValue(current["USER"]) {
        env["USER"] = user
    }
    if let logname = sanitizedEnvironmentValue(current["LOGNAME"]) ?? env["USER"] {
        env["LOGNAME"] = logname
    }
    if let encoding = sanitizedEnvironmentValue(current["__CF_USER_TEXT_ENCODING"]) {
        env["__CF_USER_TEXT_ENCODING"] = encoding
    }

    return env
}

private func systemToolProcessEnvironment(current: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
    trustedProcessEnvironment(path: "/usr/bin:/bin:/usr/sbin:/sbin", current: current)
}

private func updateProcessEnvironment(current: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
    trustedProcessEnvironment(path: "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                              current: current)
}

func updateHelperScript(pid: pid_t,
                        brewPath: String,
                        targetVersion: String,
                        statePath: String,
                        appPath: String = INSTALLED_APP_BUNDLE_PATH,
                        releasesPageURL: String = GITHUB_RELEASES_PAGE.absoluteString) -> String {
    #"""
    #!/bin/bash
    set -u
    umask 077

    SCRIPT_PATH="$0"
    BREW=\#(shellSingleQuoted(brewPath))
    TARGET_VERSION=\#(shellSingleQuoted(targetVersion))
    STATE_PATH=\#(shellSingleQuoted(statePath))
    APP_PATH=\#(shellSingleQuoted(appPath))
    RELEASES_PAGE=\#(shellSingleQuoted(releasesPageURL))
    PARAKEY_PID=\#(pid)
    CASK_TAP=\#(shellSingleQuoted(HOMEBREW_CASK_TAP))
    CASK_TOKEN=\#(shellSingleQuoted(HOMEBREW_CASK_TOKEN))
    CASK_INSTALLED_TOKEN=\#(shellSingleQuoted(HOMEBREW_CASK_INSTALLED_TOKEN))
    INFO_PLIST="$APP_PATH/Contents/Info.plist"
    APP_DIR="$(/usr/bin/dirname "$APP_PATH")"

    cleanup() {
        if [ -n "${SCRIPT_PATH:-}" ]; then
            /bin/rm -f "$SCRIPT_PATH" 2>/dev/null || true
        fi
    }
    trap cleanup EXIT

    timestamp() {
        /bin/date -u '+%Y-%m-%dT%H:%M:%SZ'
    }

    log() {
        printf '[%s] %s\n' "$(timestamp)" "$*"
    }

    state() {
        local phase="$1"
        local message="$2"
        local tmp
        log "$message"
        [ -n "$STATE_PATH" ] || return 0
        tmp="${STATE_PATH}.$$"
        if printf '%s\t%s\n' "$phase" "$message" >"$tmp"; then
            /bin/chmod 600 "$tmp" 2>/dev/null || true
            /bin/mv -f "$tmp" "$STATE_PATH" 2>/dev/null || true
        else
            /bin/rm -f "$tmp" 2>/dev/null || true
        fi
    }

    fail() {
        state "failed" "$*"
        /usr/bin/open "$RELEASES_PAGE"
        exit 1
    }

    app_version() {
        /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST" 2>/dev/null || true
    }

    version_at_least() {
        /usr/bin/awk -v actual="$1" -v target="$2" '
            BEGIN {
                actual_count = split(actual, actual_parts, ".")
                target_count = split(target, target_parts, ".")
                for (i = 1; i <= 4; i++) {
                    actual_part = i <= actual_count ? actual_parts[i] : "0"
                    target_part = i <= target_count ? target_parts[i] : "0"
                    sub(/[^0-9].*$/, "", actual_part)
                    sub(/[^0-9].*$/, "", target_part)
                    actual_number = actual_part == "" ? 0 : actual_part + 0
                    target_number = target_part == "" ? 0 : target_part + 0
                    if (actual_number > target_number) { exit 0 }
                    if (actual_number < target_number) { exit 1 }
                }
                exit 0
            }'
    }

    run_brew() {
        log "Running: $BREW $*"
        "$BREW" "$@"
    }

    wait_for_parakey_exit() {
        for _ in {1..60}; do
            if ! kill -0 "$PARAKEY_PID" 2>/dev/null; then
                return 0
            fi
            sleep 0.5
        done

        log "Parakey was still running after 30s; sending TERM before updating."
        kill -TERM "$PARAKEY_PID" 2>/dev/null || true
        for _ in {1..20}; do
            if ! kill -0 "$PARAKEY_PID" 2>/dev/null; then
                return 0
            fi
            sleep 0.5
        done

        fail "Parakey did not quit, so the app bundle was not touched."
    }

    installed_target_version() {
        local installed
        installed="$(app_version)"
        log "Installed app version: ${installed:-unknown}"
        [ -n "$installed" ] && version_at_least "$installed" "$TARGET_VERSION"
    }

    {
        echo "[$(timestamp)] Parakey update starting"
        echo "Target version: $TARGET_VERSION"
        echo "Current installed version: $(app_version)"
        echo "Brew: $BREW"
        echo "Cask tap: $CASK_TAP"
        echo "Cask: $CASK_TOKEN"
        echo "Installed cask name: $CASK_INSTALLED_TOKEN"
        echo "App: $APP_PATH"
    }

    state "preparing" "Preparing Homebrew for Parakey v$TARGET_VERSION..."

    if ! run_brew tap "$CASK_TAP"; then
        fail "brew tap failed; leaving the existing app in place."
    fi

    state "checking" "Checking Homebrew metadata..."
    if ! run_brew update --force; then
        fail "brew update failed; leaving the existing app in place."
    fi

    state "downloading" "Downloading Parakey v$TARGET_VERSION..."
    if ! run_brew fetch --cask --force "$CASK_TOKEN"; then
        fail "brew cask fetch failed; leaving the existing app in place."
    fi

    state "installing" "Installing Parakey v$TARGET_VERSION..."
    wait_for_parakey_exit

    if ! run_brew upgrade --cask --force --appdir="$APP_DIR" "$CASK_TOKEN"; then
        fail "brew cask upgrade failed; leaving the existing app in place."
    fi

    state "verifying" "Verifying the installed app..."
    if ! installed_target_version; then
        log "brew upgrade completed without installing v$TARGET_VERSION; forcing qualified cask reinstall."
        state "installing" "Reinstalling Parakey v$TARGET_VERSION..."
        if ! run_brew update --force; then
            fail "brew update failed before reinstall; leaving the existing app in place."
        fi
        if ! run_brew reinstall --cask --force --appdir="$APP_DIR" "$CASK_TOKEN"; then
            fail "brew cask reinstall failed; leaving the existing app in place."
        fi
    fi

    if ! installed_target_version; then
        fail "Expected Parakey v$TARGET_VERSION or newer after update, but the installed app is still $(app_version)."
    fi

    state "relaunching" "Update complete. Reopening Parakey..."
    sleep 2
    /usr/bin/open "$APP_PATH"
    state "complete" "Parakey v$TARGET_VERSION is installed."
    """#
}

func superDictateDirectUpdateHelperScript(pid: pid_t,
                                           targetVersion: String,
                                           statePath: String,
                                           stagedAppPath: String,
                                           workDirectory: String,
                                           backupAppPath: String,
                                           appPath: String,
                                           language: InterfaceLanguage,
                                           relaunch: Bool = true) -> String {
    let preparing = localizedText("Подготавливаю замену приложения…",
                                  "Preparing to replace the application…",
                                  language: language)
    let installing = localizedText("Устанавливаю SuperDictate v\(targetVersion)…",
                                    "Installing SuperDictate v\(targetVersion)…",
                                    language: language)
    let verifying = localizedText("Проверяю установленную версию…",
                                   "Verifying the installed version…",
                                   language: language)
    let relaunching = localizedText("Обновление готово. Запускаю SuperDictate…",
                                    "Update complete. Reopening SuperDictate…",
                                    language: language)
    let complete = localizedText("SuperDictate v\(targetVersion) установлена.",
                                  "SuperDictate v\(targetVersion) is installed.",
                                  language: language)
    let failed = localizedText("Обновление не установлено. Предыдущая версия восстановлена.",
                                "The update was not installed. The previous version was restored.",
                                language: language)

    return #"""
    #!/bin/bash
    set -u
    umask 077

    SCRIPT_PATH="$0"
    PANEL_PID=\#(pid)
    TARGET_VERSION=\#(shellSingleQuoted(targetVersion))
    STATE_PATH=\#(shellSingleQuoted(statePath))
    STAGED_APP=\#(shellSingleQuoted(stagedAppPath))
    WORK_DIR=\#(shellSingleQuoted(workDirectory))
    BACKUP_APP=\#(shellSingleQuoted(backupAppPath))
    APP_PATH=\#(shellSingleQuoted(appPath))
    SHOULD_RELAUNCH=\#(relaunch ? "1" : "0")
    APP_PARENT="$(/usr/bin/dirname "$APP_PATH")"
    INFO_PLIST="$APP_PATH/Contents/Info.plist"
    SERVICE="gui/$(/usr/bin/id -u)/\#(AGENT_LABEL)"

    timestamp() {
        /bin/date -u '+%Y-%m-%dT%H:%M:%SZ'
    }

    log() {
        printf '[%s] %s\n' "$(timestamp)" "$*"
    }

    state() {
        local phase="$1"
        local message="$2"
        local tmp="${STATE_PATH}.$$"
        log "$message"
        if printf '%s\t%s\n' "$phase" "$message" >"$tmp"; then
            /bin/chmod 600 "$tmp" 2>/dev/null || true
            /bin/mv -f "$tmp" "$STATE_PATH" 2>/dev/null || true
        else
            /bin/rm -f "$tmp" 2>/dev/null || true
        fi
    }

    cleanup() {
        /bin/rm -rf "$WORK_DIR" 2>/dev/null || true
        /bin/rm -f "$SCRIPT_PATH" 2>/dev/null || true
    }
    trap cleanup EXIT

    wait_for_panel_exit() {
        for _ in {1..40}; do
            if ! /bin/kill -0 "$PANEL_PID" 2>/dev/null; then
                return 0
            fi
            /bin/sleep 0.25
        done
        /bin/kill -TERM "$PANEL_PID" 2>/dev/null || true
        /bin/sleep 1
        ! /bin/kill -0 "$PANEL_PID" 2>/dev/null
    }

    verify_app() {
        [ -x "$APP_PATH/Contents/MacOS/SuperDictate" ] || return 1
        [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST" 2>/dev/null)" = "com.local.superdictate" ] || return 1
        [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST" 2>/dev/null)" = "$TARGET_VERSION" ] || return 1
        /usr/bin/codesign --verify --deep --strict "$APP_PATH"
    }

    rollback() {
        log "Rolling back the application bundle."
        if [ -d "$BACKUP_APP" ]; then
            /bin/rm -rf "$APP_PATH" 2>/dev/null || true
            /bin/mv "$BACKUP_APP" "$APP_PATH" 2>/dev/null || true
        fi
        state "failed" \#(shellSingleQuoted(failed))
        if [ "$SHOULD_RELAUNCH" = "1" ] && [ -d "$APP_PATH" ]; then
            /usr/bin/open "$APP_PATH" 2>/dev/null || true
        fi
        exit 1
    }

    state "preparing" \#(shellSingleQuoted(preparing))
    [ -d "$STAGED_APP" ] || rollback
    [ -d "$APP_PATH" ] || rollback
    [ ! -e "$BACKUP_APP" ] || rollback
    [ -w "$APP_PATH" ] && [ -w "$APP_PARENT" ] || rollback
    wait_for_panel_exit || rollback

    /bin/launchctl bootout "$SERVICE" >/dev/null 2>&1 || true
    /usr/bin/pkill -f "$APP_PATH/Contents/MacOS/SuperDictate --agent" >/dev/null 2>&1 || true

    state "installing" \#(shellSingleQuoted(installing))
    /bin/mv "$APP_PATH" "$BACKUP_APP" || rollback
    /usr/bin/ditto "$STAGED_APP" "$APP_PATH" || rollback

    state "verifying" \#(shellSingleQuoted(verifying))
    verify_app || rollback

    /bin/rm -rf "$BACKUP_APP" || true
    state "relaunching" \#(shellSingleQuoted(relaunching))
    if [ "$SHOULD_RELAUNCH" = "1" ]; then
        /usr/bin/open "$APP_PATH" || rollback
    fi
    /bin/sleep 2
    state "complete" \#(shellSingleQuoted(complete))
    """#
}

private func writePrivateUpdateHelperScript(_ script: String,
                                            directory: String = NSTemporaryDirectory(),
                                            fileName: String? = nil) throws -> String {
    guard !directory.isEmpty else { throw posixError(EINVAL) }
    let leafName = fileName ?? "parakey-update-\(UUID().uuidString).sh"
    guard !leafName.isEmpty,
          (leafName as NSString).lastPathComponent == leafName else {
        throw posixError(EINVAL)
    }

    let path = (directory as NSString).appendingPathComponent(leafName)
    let flags = O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW
    let fd = Darwin.open(path, flags, PRIVATE_HELPER_FILE_MODE)
    guard fd >= 0 else { throw currentPOSIXError() }

    var closed = false
    var removeOnFailure = true
    do {
        try validateSingleLinkRegularFileDescriptor(fd)
        guard Darwin.fchmod(fd, PRIVATE_HELPER_FILE_MODE) == 0 else {
            throw currentPOSIXError()
        }
        try writeAllData(Data(script.utf8), to: fd)
        try validateSingleLinkRegularFileDescriptor(fd)

        let closeStatus = Darwin.close(fd)
        closed = true
        guard closeStatus == 0 else { throw currentPOSIXError() }

        removeOnFailure = false
        return path
    } catch {
        if !closed { _ = Darwin.close(fd) }
        if removeOnFailure { _ = Darwin.unlink(path) }
        throw error
    }
}

private struct PrivateOutputFile {
    let path: String
    let handle: FileHandle
}

private func openPrivateUpdateHelperLog(preferredPath: String = UPDATE_HELPER_LOG_PATH,
                                        fallbackDirectory: String = NSTemporaryDirectory()) throws -> PrivateOutputFile {
    do {
        let fd = try openPrivateOutputFileDescriptor(atPath: preferredPath,
                                                     exclusive: false,
                                                     removeOnFailure: false)
        return PrivateOutputFile(path: preferredPath,
                                 handle: FileHandle(fileDescriptor: fd, closeOnDealloc: true))
    } catch {
        let fallbackPath = (fallbackDirectory as NSString)
            .appendingPathComponent("parakey-update-\(UUID().uuidString).log")
        let fd = try openPrivateOutputFileDescriptor(atPath: fallbackPath,
                                                     exclusive: true,
                                                     removeOnFailure: true)
        return PrivateOutputFile(path: fallbackPath,
                                 handle: FileHandle(fileDescriptor: fd, closeOnDealloc: true))
    }
}

private func createPrivateUpdateProgressStateFile(directory: String = NSTemporaryDirectory()) throws -> String {
    let path = (directory as NSString)
        .appendingPathComponent("\(UPDATE_PROGRESS_APP_PREFIX)\(UUID().uuidString).state")
    let fd = try openPrivateOutputFileDescriptor(atPath: path,
                                                 exclusive: true,
                                                 removeOnFailure: true)
    do {
        try writeAllData(Data("starting\tStarting update...\n".utf8), to: fd)
        guard Darwin.close(fd) == 0 else { throw currentPOSIXError() }
        return path
    } catch {
        _ = Darwin.close(fd)
        _ = Darwin.unlink(path)
        throw error
    }
}

private func writePrivateUpdateProgressState(phase: String,
                                             message: String,
                                             to path: String) throws {
    let safePhase = phase.replacingOccurrences(of: "\t", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
    let safeMessage = message.replacingOccurrences(of: "\t", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
    let fd = try openPrivateOutputFileDescriptor(atPath: path,
                                                 exclusive: false,
                                                 removeOnFailure: false)
    do {
        try writeAllData(Data("\(safePhase)\t\(safeMessage)\n".utf8), to: fd)
        guard Darwin.close(fd) == 0 else { throw currentPOSIXError() }
    } catch {
        _ = Darwin.close(fd)
        throw error
    }
}

private func openPrivateOutputFileDescriptor(atPath path: String,
                                             exclusive: Bool,
                                             removeOnFailure: Bool) throws -> Int32 {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)

    var flags = O_WRONLY | O_CREAT | O_NOFOLLOW
    if exclusive { flags |= O_EXCL }

    let fd = Darwin.open(path, flags, PRIVATE_LOG_FILE_MODE)
    guard fd >= 0 else { throw currentPOSIXError() }

    do {
        try validateSingleLinkRegularFileDescriptor(fd)
        guard Darwin.fchmod(fd, PRIVATE_LOG_FILE_MODE) == 0 else {
            throw currentPOSIXError()
        }
        guard Darwin.ftruncate(fd, 0) == 0 else {
            throw currentPOSIXError()
        }
        return fd
    } catch {
        _ = Darwin.close(fd)
        if removeOnFailure { _ = Darwin.unlink(path) }
        throw error
    }
}

// MARK: - App
//
// Single class that owns the lifecycle and the AppKit menu-bar UI.
// All UI state lives here; subsystems (HotkeyListener, AudioCapture,
// TranscriptionWorker, UpdateCheck, …) hold their own state but
// call back into `ParakeyApp` for anything that touches the menu.

private enum DictationReleaseShortcut: Equatable {
    case standard
    case alternate
}

private func shouldPressEnterAfterDictation(
    shortcut: DictationReleaseShortcut,
    primaryBehavior: DictationCompletionBehavior
) -> Bool {
    let behavior = shortcut == .standard ? primaryBehavior : primaryBehavior.opposite
    return behavior.pressesEnter
}

@MainActor
final class CorrectionShareCleanupDelegate: NSObject, @preconcurrency NSSharingServicePickerDelegate, NSSharingServiceDelegate {
    private let cleanup: (String) -> Void

    init(cleanup: @escaping (String) -> Void) {
        self.cleanup = cleanup
    }

    private func runCleanup(reason: String) {
        cleanup(reason)
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker,
                              delegateFor sharingService: NSSharingService) -> NSSharingServiceDelegate? {
        self
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker,
                              didChoose service: NSSharingService?) {
        if service == nil {
            runCleanup(reason: "dismissed")
        }
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        runCleanup(reason: "shared")
    }

    func sharingService(_ sharingService: NSSharingService,
                        didFailToShareItems items: [Any],
                        error: Error) {
        runCleanup(reason: "share failed")
    }
}

private final class RecordingHUDView: NSView {
    var visualScale: CGFloat = RecordingHUDSize.standard.visualScale {
        didSet {
            if oldValue != visualScale { needsDisplay = true }
        }
    }

    var recordingColor: NSColor = .systemRed {
        didSet {
            if !oldValue.isEqual(recordingColor) { needsDisplay = true }
        }
    }

    var transcribingColor: NSColor = NSColor(calibratedRed: 0.0, green: 0.44, blue: 1.0, alpha: 1) {
        didSet {
            if !oldValue.isEqual(transcribingColor) { needsDisplay = true }
        }
    }

    var backgroundStyle: RecordingHUDBackgroundStyle = .system {
        didSet {
            if oldValue != backgroundStyle { needsDisplay = true }
        }
    }

    var showsCapsuleStroke = true {
        didSet {
            if oldValue != showsCapsuleStroke { needsDisplay = true }
        }
    }

    var transcribingElapsedOverride: CGFloat? {
        didSet { needsDisplay = true }
    }

    var revealProgress: CGFloat = 1 {
        didSet {
            if oldValue != revealProgress { needsDisplay = true }
        }
    }

    var mode: RecordingHUDMode = .recording {
        didSet {
            if oldValue != mode {
                modeChangedAt = ProcessInfo.processInfo.systemUptime
                needsDisplay = true
            }
        }
    }
    private var modeChangedAt = ProcessInfo.processInfo.systemUptime

    var level: Float = 0 {
        didSet {
            if oldValue != level { needsDisplay = true }
        }
    }

    var phase: CGFloat = 0 {
        didSet {
            if oldValue != phase { needsDisplay = true }
        }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawFloatingWaveformOnly()
    }

    private func drawFloatingWaveformOnly() {
        let reveal = max(0, min(1, revealProgress))
        guard reveal > 0.001 else { return }

        let clamped = CGFloat(max(0, min(1, level)))
        let audio = pow(clamped, 0.82)
        let settlePeak: CGFloat = 0.68
        let settleOvershoot: CGFloat = 0.10
        let grow: CGFloat
        if reveal <= settlePeak {
            grow = (1 + settleOvershoot) * smootherstep(0, settlePeak, reveal)
        } else {
            grow = (1 + settleOvershoot)
                - (settleOvershoot * smootherstep(settlePeak, 1, reveal))
        }
        let capsuleAlpha = smootherstep(0, 0.34, reveal)
        let contentAlpha = smootherstep(0.16, 0.78, reveal)
        let visualScale = self.visualScale
        let startDiameter: CGFloat = 6 * visualScale
        let finalRect = bounds.insetBy(dx: 4 * visualScale, dy: 4 * visualScale)
        let breathingReady = smootherstep(0.82, 1, reveal)
        let idleBreath = 0.0032 + (0.0018 * sin(phase * 0.31))
        let voiceBreath = audio * (0.014 + (0.008 * ((sin(phase * 0.87) + 1) / 2)))
        let liveScale = 1 + ((idleBreath + voiceBreath) * breathingReady)
        let capsuleWidth = (startDiameter + ((finalRect.width - startDiameter) * grow)) * liveScale
        let capsuleHeight = (startDiameter + ((finalRect.height - startDiameter) * grow)) * liveScale
        let capsuleRect = NSRect(x: bounds.midX - (capsuleWidth / 2),
                                 y: bounds.midY - (capsuleHeight / 2),
                                 width: capsuleWidth,
                                 height: capsuleHeight)
        let capsule = NSBezierPath(roundedRect: capsuleRect,
                                   xRadius: capsuleRect.height / 2,
                                   yRadius: capsuleRect.height / 2)
        let palette = backgroundPalette(alpha: capsuleAlpha)
        palette.fill.setFill()
        capsule.fill()
        let accent: NSColor
        switch mode {
        case .transcribing: accent = transcribingColor
        case .error:        accent = .systemYellow
        case .recording:    accent = recordingColor
        }
        let vividAccent = accent
        if showsCapsuleStroke {
            palette.stroke.setStroke()
            capsule.lineWidth = 1 * visualScale
            capsule.stroke()
        }

        guard contentAlpha > 0.001 else { return }

        NSGraphicsContext.saveGraphicsState()
        guard let context = NSGraphicsContext.current?.cgContext else {
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        capsule.addClip()
        context.setAlpha(contentAlpha)
        defer { NSGraphicsContext.restoreGraphicsState() }

        if mode == .transcribing {
            drawTranscribingWave(in: capsuleRect, alpha: 1)
            return
        }

        if mode == .error {
            drawErrorIndicator(in: capsuleRect)
            return
        }

        let barCount = 8
        let barWidth: CGFloat = 2.05 * visualScale
        let barGap: CGFloat = 2.55 * visualScale
        let minHeight: CGFloat = 3.0 * visualScale
        let maxHeight = min(capsuleRect.height * 0.58, 13.2 * visualScale)
        let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barGap
        let startX = bounds.midX - (totalWidth / 2)
        let centerY = bounds.midY
        let centerIndex = CGFloat(barCount - 1) / 2
        let centerDenominator = max(centerIndex, 1)

        for index in 0..<barCount {
            let i = CGFloat(index)
            let normalized = (i - centerIndex) / centerDenominator
            let envelope = pow(max(0, cos(normalized * .pi / 2)), 0.62)
            let traveling = (sin((phase * 1.02) - (normalized * 2.85)) + 1) / 2
            let counter = (sin((phase * 1.57) + (i * 1.17)) + 1) / 2
            let slowVariance = (sin((phase * 0.23) + (i * 2.11)) + 1) / 2
            let perBarGain = 0.72 + (0.28 * slowVariance)
            let idleMotion = 0.14 + (0.075 * traveling) + (0.055 * counter * envelope)
            let centerBias = 0.22 + (0.78 * envelope)
            let voiceMotion = audio
                * centerBias
                * (0.18 + (0.42 * traveling) + (0.14 * counter))
                * perBarGain
            let activity = min(0.88, idleMotion + voiceMotion)
            let height = minHeight + ((maxHeight - minHeight) * activity)
            let x = startX + CGFloat(index) * (barWidth + barGap)
            let rect = NSRect(x: x,
                              y: centerY - (height / 2),
                              width: barWidth,
                              height: height)
            let path = NSBezierPath(roundedRect: rect,
                                    xRadius: barWidth / 2,
                                    yRadius: barWidth / 2)

            let glowRect = rect.insetBy(dx: -1.1 * visualScale,
                                        dy: -1.1 * visualScale)
            vividAccent.withAlphaComponent(0.07 + (0.10 * activity)).setFill()
            NSBezierPath(roundedRect: glowRect,
                         xRadius: glowRect.width / 2,
                         yRadius: glowRect.width / 2).fill()
            vividAccent.withAlphaComponent(0.74 + (0.26 * activity)).setFill()
            path.fill()
        }
    }

    private func drawTranscribingWave(in capsuleRect: NSRect, alpha: CGFloat) {
        guard alpha > 0.001 else { return }
        let recordingAccent = recordingColor
        let transcribingAccent = transcribingColor
        let barCount = 8
        let visualScale = self.visualScale
        let barWidth: CGFloat = 2.05 * visualScale
        let barGap: CGFloat = 2.55 * visualScale
        let minHeight: CGFloat = 3.2 * visualScale
        let maxHeight = min(capsuleRect.height * 0.60, 14.6 * visualScale)
        let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barGap
        let startX = capsuleRect.midX - (totalWidth / 2)
        let centerY = capsuleRect.midY
        let centerIndex = CGFloat(barCount - 1) / 2
        let centerDenominator = max(centerIndex, 1)
        let age = transcribingElapsedOverride
            ?? CGFloat(max(0, ProcessInfo.processInfo.systemUptime - modeChangedAt))
        let resolveDuration = CGFloat(RECORDING_HUD_TRANSCRIBING_RESOLVE_SECONDS)
        let resolveProgress = min(1, age / resolveDuration)
        let loopPhase = max(0, age - resolveDuration)

        for index in 0..<barCount {
            let i = CGFloat(index)
            let normalized = (i - centerIndex) / centerDenominator
            let envelope = pow(max(0, cos(normalized * .pi / 2)), 0.62)
            let barProgress = CGFloat(index) / CGFloat(max(1, barCount - 1))
            let conversion = smoothstep(barProgress - 0.34, barProgress + 0.08, resolveProgress)
            let front = max(0, 1 - abs(resolveProgress - barProgress) / 0.18) * (1 - smoothstep(0.82, 1, resolveProgress))
            let reverseHead = 1 - (loopPhase * 3.8).truncatingRemainder(dividingBy: 1)
            let reversePulse = max(0, 1 - abs(reverseHead - barProgress) / 0.24)
            let loopWave = (sin((loopPhase * 6.2) + (i * 0.56)) + 1) / 2
            let loopCounter = (sin((loopPhase * 2.8) + (i * 1.27)) + 1) / 2
            let resolveLift = front * (0.48 + (0.30 * envelope))
            let blueLoop = conversion * ((0.14 * loopWave) + (0.08 * loopCounter * envelope) + (0.34 * reversePulse))
            let redHold = (1 - conversion) * (0.16 + (0.12 * envelope))
            let activity = min(0.94,
                               0.15
                               + (0.24 * envelope)
                               + redHold
                               + blueLoop
                               + resolveLift)
            let height = minHeight + ((maxHeight - minHeight) * activity)
            let x = startX + CGFloat(index) * (barWidth + barGap)
            let rect = NSRect(x: x,
                              y: centerY - (height / 2),
                              width: barWidth,
                              height: height)
            let path = NSBezierPath(roundedRect: rect,
                                    xRadius: barWidth / 2,
                                    yRadius: barWidth / 2)

            let glowRect = rect.insetBy(dx: -1.35 * visualScale,
                                        dy: -1.45 * visualScale)
            let fillColor = recordingAccent.blended(withFraction: conversion, of: transcribingAccent) ?? transcribingAccent
            let glowAlpha = (0.055 + (0.12 * front) + (0.10 * reversePulse) + (0.045 * conversion)) * alpha
            fillColor.withAlphaComponent(glowAlpha).setFill()
            NSBezierPath(roundedRect: glowRect,
                         xRadius: glowRect.width / 2,
                         yRadius: glowRect.width / 2).fill()
            fillColor.withAlphaComponent((0.58 + (0.26 * front) + (0.20 * reversePulse) + (0.14 * conversion)) * alpha).setFill()
            path.fill()
        }
    }

    /// Static exclamation mark drawn inside the yellow error capsule.
    private func drawErrorIndicator(in capsuleRect: NSRect) {
        let visualScale = self.visualScale
        let accent = NSColor.systemYellow
        let stemWidth: CGFloat = 2.4 * visualScale
        let stemHeight: CGFloat = min(capsuleRect.height * 0.38, 9 * visualScale)
        let dotDiameter: CGFloat = 2.4 * visualScale
        let gap: CGFloat = 2.0 * visualScale
        let totalHeight = stemHeight + gap + dotDiameter
        let topY = capsuleRect.midY + (totalHeight / 2)

        let stemRect = NSRect(x: capsuleRect.midX - (stemWidth / 2),
                              y: topY - stemHeight,
                              width: stemWidth,
                              height: stemHeight)
        accent.withAlphaComponent(0.88).setFill()
        NSBezierPath(roundedRect: stemRect,
                     xRadius: stemWidth / 2,
                     yRadius: stemWidth / 2).fill()

        let dotRect = NSRect(x: capsuleRect.midX - (dotDiameter / 2),
                             y: topY - totalHeight,
                             width: dotDiameter,
                             height: dotDiameter)
        NSBezierPath(ovalIn: dotRect).fill()
    }

    private func smoothstep(_ edge0: CGFloat, _ edge1: CGFloat, _ value: CGFloat) -> CGFloat {
        guard edge0 != edge1 else { return value >= edge1 ? 1 : 0 }
        let t = max(0, min(1, (value - edge0) / (edge1 - edge0)))
        return t * t * (3 - (2 * t))
    }

    private func smootherstep(_ edge0: CGFloat, _ edge1: CGFloat, _ value: CGFloat) -> CGFloat {
        guard edge0 != edge1 else { return value >= edge1 ? 1 : 0 }
        let t = max(0, min(1, (value - edge0) / (edge1 - edge0)))
        return t * t * t * (t * ((t * 6) - 15) + 10)
    }

    private func backgroundPalette(alpha: CGFloat) -> (fill: NSColor, stroke: NSColor) {
        let light = shouldUseLightBackground()
        if light {
            return (
                NSColor(calibratedWhite: 1.0, alpha: 0.84 * alpha),
                NSColor(calibratedWhite: 0.0, alpha: 0.14 * alpha)
            )
        }
        return (
            NSColor(calibratedWhite: 0.0, alpha: 0.96 * alpha),
            NSColor(calibratedWhite: 0.22, alpha: 0.26 * alpha)
        )
    }

    private func shouldUseLightBackground() -> Bool {
        switch backgroundStyle {
        case .light:
            return true
        case .dark:
            return false
        case .system:
            let appearance = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
            return appearance == .aqua
        }
    }

}

private let RECORDING_HUD_EXPORT_ARGUMENT = "--export-hud-animation"

@MainActor
private func exportRecordingHUDAnimationFrames(to directory: URL) throws {
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: directory.path) {
        try fileManager.removeItem(at: directory)
    }
    try fileManager.createDirectory(at: directory,
                                    withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])

    let hudSize = Settings.shared.recordingHUDSize
    let pointSize = hudSize.expandedSize
    let pixelScale: CGFloat = 4
    let pixelWidth = Int((pointSize.width * pixelScale).rounded())
    let pixelHeight = Int((pointSize.height * pixelScale).rounded())
    let framesPerSecond = 120.0
    let emptyLead = 0.35
    let recordingDuration = 6.20
    let transcribingDuration = 2.40
    let emptyTail = 0.50
    let totalDuration = emptyLead
        + RECORDING_HUD_ANIMATE_IN_SECONDS
        + recordingDuration
        + transcribingDuration
        + RECORDING_HUD_ANIMATE_OUT_SECONDS
        + emptyTail
    let frameCount = Int((totalDuration * framesPerSecond).rounded())

    let view = RecordingHUDView(frame: NSRect(origin: .zero, size: pointSize))
    view.visualScale = hudSize.visualScale
    let settings = Settings.shared
    view.recordingColor = settings.recordingHUDRecordingColor.nsColor
    view.transcribingColor = settings.recordingHUDTranscribingColor.nsColor
    view.backgroundStyle = .dark
    view.showsCapsuleStroke = false
    view.mode = .recording

    var phase: CGFloat = 0
    for frameIndex in 0..<frameCount {
        try autoreleasepool {
            let time = Double(frameIndex) / framesPerSecond
            let revealStart = emptyLead
            let recordingStart = revealStart + RECORDING_HUD_ANIMATE_IN_SECONDS
            let transcribingStart = recordingStart + recordingDuration
            let hideStart = transcribingStart + transcribingDuration
            let tailStart = hideStart + RECORDING_HUD_ANIMATE_OUT_SECONDS

            let reveal: CGFloat
            let level: Float
            let mode: RecordingHUDMode
            let transcribingElapsed: CGFloat?
            if time < revealStart {
                reveal = 0
                level = 0
                mode = .recording
                transcribingElapsed = nil
            } else if time < recordingStart {
                reveal = CGFloat((time - revealStart) / RECORDING_HUD_ANIMATE_IN_SECONDS)
                level = 0
                mode = .recording
                transcribingElapsed = nil
            } else if time < transcribingStart {
                reveal = 1
                let voiceTime = time - recordingStart
                let syllables = pow(max(0, sin((voiceTime * 8.7) + 0.35)), 0.58)
                let phrasing = 0.58 + (0.42 * ((sin((voiceTime * 2.15) - 0.7) + 1) / 2))
                let detail = 0.78 + (0.22 * ((sin((voiceTime * 13.4) + 1.8) + 1) / 2))
                level = Float(min(0.94, 0.10 + (0.78 * syllables * phrasing * detail)))
                mode = .recording
                transcribingElapsed = nil
            } else if time < hideStart {
                reveal = 1
                level = 0
                mode = .transcribing
                transcribingElapsed = CGFloat(time - transcribingStart)
            } else if time < tailStart {
                reveal = 1 - CGFloat((time - hideStart) / RECORDING_HUD_ANIMATE_OUT_SECONDS)
                level = 0
                mode = .transcribing
                transcribingElapsed = CGFloat(time - transcribingStart)
            } else {
                reveal = 0
                level = 0
                mode = .transcribing
                transcribingElapsed = CGFloat(time - transcribingStart)
            }

            phase += recordingHUDPhaseSpeed(mode: mode, level: level)
                / CGFloat(framesPerSecond)
            view.revealProgress = max(0, min(1, reveal))
            view.mode = mode
            view.transcribingElapsedOverride = transcribingElapsed
            view.level = level
            view.phase = phase

            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                                pixelsWide: pixelWidth,
                                                pixelsHigh: pixelHeight,
                                                bitsPerSample: 8,
                                                samplesPerPixel: 4,
                                                hasAlpha: true,
                                                isPlanar: false,
                                                colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0,
                                                bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
                throw NSError(domain: "SuperDictateHUDExport", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Could not create an RGBA frame."])
            }
            bitmap.size = pointSize
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.cgContext.clear(NSRect(origin: .zero, size: pointSize))
            context.cgContext.scaleBy(x: pixelScale, y: pixelScale)
            view.displayIgnoringOpacity(view.bounds, in: context)
            context.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()

            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw NSError(domain: "SuperDictateHUDExport", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Could not encode a PNG frame."])
            }
            let name = String(format: "frame-%05d.png", frameIndex)
            try png.write(to: directory.appendingPathComponent(name), options: .atomic)
        }
    }

    print("HUD_EXPORT frames=\(frameCount) fps=120 size=\(pixelWidth)x\(pixelHeight) duration=\(String(format: "%.3f", totalDuration))")
}

private struct UpdateProgressLaunch {
    let statePath: String
    let logPath: String
    let targetVersion: String
    let cleanupAppPath: String

    init?(arguments: [String]) {
        guard arguments.count >= 5,
              arguments[0] == UPDATE_PROGRESS_ARGUMENT,
              !arguments[1].isEmpty,
              !arguments[2].isEmpty,
              !arguments[3].isEmpty,
              !arguments[4].isEmpty else {
            return nil
        }

        statePath = arguments[1]
        logPath = arguments[2]
        targetVersion = arguments[3]
        cleanupAppPath = arguments[4]
    }
}

private struct UpdateProgressState {
    let phase: String
    let message: String

    static func read(from path: String) -> UpdateProgressState? {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .newlines)
        let parts = trimmed.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        return UpdateProgressState(phase: String(parts[0]), message: String(parts[1]))
    }
}

private func isSafeUpdateProgressCleanupPath(_ path: String) -> Bool {
    guard !path.isEmpty else { return false }
    let tempPath = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .standardizedFileURL
        .path
    let tempPrefix = tempPath.hasSuffix("/") ? tempPath : "\(tempPath)/"
    let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    return url.path.hasPrefix(tempPrefix)
        && url.pathExtension == "app"
        && url.lastPathComponent.hasPrefix(UPDATE_PROGRESS_APP_PREFIX)
}

@MainActor
private final class UpdateProgressAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let launch: UpdateProgressLaunch
    private var window: NSWindow?
    private var pollTimer: Timer?
    private var closeWorkItem: DispatchWorkItem?
    private var lastPhase = ""
    private var lastMessage = ""

    private var messageLabel: NSTextField!
    private var detailLabel: NSTextField!
    private var progress: NSProgressIndicator!
    private var openReleaseButton: NSButton!
    private var closeButton: NSButton!

    init(launch: UpdateProgressLaunch) {
        self.launch = launch
    }

    private var language: InterfaceLanguage { Settings.shared.interfaceLanguage }

    private func t(_ russian: String, _ english: String) -> String {
        localizedText(russian, english, language: language)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildWindow()
        pollState()
        pollTimer = Timer.scheduledTimer(timeInterval: 0.5,
                                         target: self,
                                         selector: #selector(updateProgressTimerFired(_:)),
                                         userInfo: nil,
                                         repeats: true)
        pollTimer?.tolerance = 0.15
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollTimer?.invalidate()
        pollTimer = nil
        closeWorkItem?.cancel()
        scheduleCopiedAppCleanup()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }

    private func buildWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 184),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = t("Обновление SuperDictate", "Updating SuperDictate")
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false

        let title = updateProgressLabel(t("Обновление SuperDictate до v\(launch.targetVersion)",
                                          "Updating SuperDictate to v\(launch.targetVersion)"),
                                        font: .systemFont(ofSize: 18, weight: .semibold))
        messageLabel = updateProgressLabel(t("Запускаю обновление…", "Starting update…"),
                                           font: .systemFont(ofSize: 13, weight: .medium))
        detailLabel = updateProgressLabel(t("SuperDictate автоматически откроется после установки.",
                                             "SuperDictate will reopen automatically when the update finishes."),
                                          font: .systemFont(ofSize: 12),
                                          color: .secondaryLabelColor)
        detailLabel.preferredMaxLayoutWidth = 390

        progress = NSProgressIndicator()
        progress.style = .bar
        progress.isIndeterminate = true
        progress.usesThreadedAnimation = true
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.startAnimation(nil)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let openLog = NSButton(title: t("Открыть журнал", "Open Log"),
                               target: self,
                               action: #selector(openUpdateLogClicked(_:)))
        openLog.bezelStyle = .rounded

        openReleaseButton = NSButton(title: t("Открыть страницу релиза", "Open Release Page"),
                                     target: self,
                                     action: #selector(openReleasePageClicked(_:)))
        openReleaseButton.bezelStyle = .rounded
        openReleaseButton.isHidden = true

        closeButton = NSButton(title: t("Закрыть", "Close"),
                               target: self,
                               action: #selector(closeUpdateProgressClicked(_:)))
        closeButton.bezelStyle = .rounded
        closeButton.isHidden = true

        buttonRow.addArrangedSubview(openLog)
        buttonRow.addArrangedSubview(openReleaseButton)
        buttonRow.addArrangedSubview(NSView())
        buttonRow.addArrangedSubview(closeButton)
        buttonRow.setHuggingPriority(.defaultLow, for: .horizontal)

        root.addArrangedSubview(title)
        root.addArrangedSubview(messageLabel)
        root.addArrangedSubview(progress)
        root.addArrangedSubview(detailLabel)
        root.addArrangedSubview(buttonRow)

        for view in root.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: root.widthAnchor,
                                        constant: -(root.edgeInsets.left + root.edgeInsets.right)).isActive = true
        }

        let container = NSView()
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: 430),
            progress.heightAnchor.constraint(equalToConstant: 14),
        ])

        window.contentView = container
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func updateProgressLabel(_ text: String,
                                     font: NSFont,
                                     color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        return label
    }

    @objc private func updateProgressTimerFired(_ timer: Timer) {
        pollState()
    }

    private func pollState() {
        let state = UpdateProgressState.read(from: launch.statePath)
            ?? UpdateProgressState(phase: "starting",
                                   message: t("Запускаю обновление…", "Starting update…"))
        guard state.phase != lastPhase || state.message != lastMessage else { return }

        lastPhase = state.phase
        lastMessage = state.message
        messageLabel.stringValue = state.message

        switch state.phase {
        case "failed":
            progress.stopAnimation(nil)
            progress.isHidden = true
            detailLabel.stringValue = t("Предыдущая версия сохранена. Подробности доступны в журнале.",
                                        "The previous version was preserved. Open the log for details.")
            openReleaseButton.isHidden = false
            closeButton.isHidden = false
            NSApp.activate(ignoringOtherApps: true)
        case "complete":
            progress.stopAnimation(nil)
            progress.isHidden = true
            detailLabel.stringValue = t("Обновлённое приложение открывается. Это окно скоро закроется.",
                                        "The updated app is opening. This window will close shortly.")
            closeButton.isHidden = false
            scheduleClose(after: 4)
        case "installing":
            detailLabel.stringValue = t("Старая версия закрыта, новая устанавливается. Приложение откроется автоматически.",
                                        "The old version has closed while the new one is installed. It will reopen automatically.")
        case "relaunching":
            detailLabel.stringValue = t("Запускаю новую версию SuperDictate.",
                                        "Opening the new version of SuperDictate.")
            scheduleClose(after: 0.5)
        default:
            detailLabel.stringValue = t("SuperDictate автоматически откроется после установки.",
                                        "SuperDictate will reopen automatically when the update finishes.")
        }
    }

    private func scheduleClose(after delay: TimeInterval) {
        guard closeWorkItem == nil else { return }
        let item = DispatchWorkItem { NSApp.terminate(nil) }
        closeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func scheduleCopiedAppCleanup() {
        guard isSafeUpdateProgressCleanupPath(launch.cleanupAppPath) else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "sleep 2; /bin/rm -rf \"$1\"", "cleanup", launch.cleanupAppPath]
        proc.environment = systemToolProcessEnvironment()
        try? proc.run()
    }

    @objc private func openUpdateLogClicked(_ sender: NSButton) {
        NSWorkspace.shared.open(URL(fileURLWithPath: launch.logPath))
    }

    @objc private func openReleasePageClicked(_ sender: NSButton) {
        NSWorkspace.shared.open(GITHUB_RELEASES_PAGE)
    }

    @objc private func closeUpdateProgressClicked(_ sender: NSButton) {
        NSApp.terminate(nil)
    }
}

@MainActor
private final class HistoryOverlayPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == ESCAPE_KEYCODE {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }
}

@MainActor
private final class HistoryItemLabel: NSTextField {
    init(_ text: String) {
        super.init(frame: .zero)
        stringValue = text
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        backgroundColor = .clear
        focusRingType = .none
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool {
        false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
}

@MainActor
private final class HistoryDeleteButton: NSButton {
    let historyIndex: Int
    private let normalBackground = NSColor.clear
    private let hoverBackground = NSColor.systemRed.withAlphaComponent(0.12)

    init(historyIndex: Int) {
        self.historyIndex = historyIndex
        super.init(frame: .zero)
        title = ""
        image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        contentTintColor = .tertiaryLabelColor
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .none
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = normalBackground.cgColor

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 28),
            heightAnchor.constraint(equalToConstant: 28),
        ])
        toolTip = "Delete from History"
        setAccessibilityLabel("Delete from History")
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool {
        false
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func setHovered(_ hovered: Bool) {
        layer?.backgroundColor = (hovered ? hoverBackground : normalBackground).cgColor
        contentTintColor = hovered ? .systemRed : .tertiaryLabelColor
    }
}

@MainActor
private final class HistoryTranscriptItemView: NSControl {
    enum HitAction {
        case copy(String)
        case delete(Int)
    }

    var transcript = ""
    private let label: HistoryItemLabel
    private let timingLabel: HistoryItemLabel
    private let timingBadge = NSView()
    private let deleteButton: HistoryDeleteButton
    private let onDelete: (Int) -> Void
    private var tracking: NSTrackingArea?
    private let normalBackground = NSColor.controlBackgroundColor.withAlphaComponent(0.28)
    private let hoverBackground = NSColor.labelColor.withAlphaComponent(0.08)
    private let pressedBackground = NSColor.labelColor.withAlphaComponent(0.14)

    init(transcript: String,
         preview: String,
         transcriptionDurationSeconds: Double?,
         asrTiming: ASRTimingBreakdown?,
         historyIndex: Int,
         target: AnyObject?,
         action: Selector,
         onDelete: @escaping (Int) -> Void) {
        self.transcript = transcript
        self.onDelete = onDelete
        label = HistoryItemLabel(preview)
        timingLabel = HistoryItemLabel(transcriptionDurationLabel(transcriptionDurationSeconds))
        deleteButton = HistoryDeleteButton(historyIndex: historyIndex)
        super.init(frame: .zero)
        self.target = target
        self.action = action
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = normalBackground.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.13).cgColor

        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 2
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        timingBadge.wantsLayer = true
        timingBadge.layer?.cornerRadius = 7
        timingBadge.layer?.cornerCurve = .continuous
        timingBadge.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.055).cgColor
        timingBadge.layer?.borderWidth = 1
        timingBadge.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.14).cgColor
        timingBadge.toolTip = asrTimingTooltip(asrTiming)
        timingBadge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(timingBadge)

        timingLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        timingLabel.textColor = transcriptionDurationSeconds == nil ? .tertiaryLabelColor : .secondaryLabelColor
        timingLabel.alignment = .center
        timingLabel.translatesAutoresizingMaskIntoConstraints = false
        timingBadge.addSubview(timingLabel)

        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(deleteButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 56),
            timingBadge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            timingBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            timingBadge.widthAnchor.constraint(equalToConstant: 68),
            timingBadge.heightAnchor.constraint(equalToConstant: 24),
            timingLabel.leadingAnchor.constraint(equalTo: timingBadge.leadingAnchor, constant: 4),
            timingLabel.trailingAnchor.constraint(equalTo: timingBadge.trailingAnchor, constant: -4),
            timingLabel.centerYAnchor.constraint(equalTo: timingBadge.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: timingBadge.trailingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            deleteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool {
        false
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return bounds.contains(point) ? self : nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func updateTrackingAreas() {
        if let tracking {
            removeTrackingArea(tracking)
        }
        let next = NSTrackingArea(rect: bounds,
                                  options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(next)
        tracking = next
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = hoverBackground.cgColor
        updateDeleteHover(for: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateDeleteHover(for: event)
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = normalBackground.cgColor
        deleteButton.setHovered(false)
    }

    override func mouseDown(with event: NSEvent) {
        guard let hitAction = hitAction(atWindowPoint: event.locationInWindow) else { return }
        switch hitAction {
        case .copy:
            layer?.backgroundColor = pressedBackground.cgColor
            guard let action else { return }
            NSApp.sendAction(action, to: target, from: self)
        case .delete(let historyIndex):
            onDelete(historyIndex)
        }
    }

    override func mouseUp(with event: NSEvent) {
        layer?.backgroundColor = normalBackground.cgColor
    }

    func hitAction(atWindowPoint point: NSPoint) -> HitAction? {
        let localPoint = convert(point, from: nil)
        guard bounds.contains(localPoint) else { return nil }
        if deleteButton.frame.insetBy(dx: -6, dy: -6).contains(localPoint) {
            return .delete(deleteButton.historyIndex)
        }
        return .copy(transcript)
    }

    private func updateDeleteHover(for event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        deleteButton.setHovered(deleteButton.frame.contains(point))
    }
}

@MainActor
private final class HistoryToolbarButton: NSControl {
    private let imageView = NSImageView()
    private var tracking: NSTrackingArea?
    private let normalBackground = NSColor.clear
    private let hoverBackground = NSColor.labelColor.withAlphaComponent(0.08)
    private let pressedBackground = NSColor.labelColor.withAlphaComponent(0.14)

    init(symbolName: String,
         accessibilityDescription: String,
         toolTip: String,
         target: AnyObject?,
         action: Selector) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = normalBackground.cgColor

        imageView.image = NSImage(systemSymbolName: symbolName,
                                  accessibilityDescription: accessibilityDescription)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        imageView.image?.isTemplate = true
        imageView.contentTintColor = .secondaryLabelColor
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 32),
            heightAnchor.constraint(equalToConstant: 32),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 17),
            imageView.heightAnchor.constraint(equalToConstant: 17),
        ])
        self.toolTip = toolTip
        setAccessibilityLabel(accessibilityDescription)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        if let tracking {
            removeTrackingArea(tracking)
        }
        let next = NSTrackingArea(rect: bounds,
                                  options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(next)
        tracking = next
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = hoverBackground.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = normalBackground.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = pressedBackground.cgColor
        guard let action else { return }
        NSApp.sendAction(action, to: target, from: self)
    }

    override func mouseUp(with event: NSEvent) {
        layer?.backgroundColor = normalBackground.cgColor
    }
}

private func formattedUsageInteger(_ value: Int) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "ru_RU")
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = 0
    return formatter.string(from: NSNumber(value: max(0, value))) ?? String(max(0, value))
}

private func formattedUsageDuration(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded()))
    if total >= 3_600 {
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        return minutes > 0 ? "\(hours) ч \(minutes) мин" : "\(hours) ч"
    }
    if total >= 60 {
        let minutes = total / 60
        let remainder = total % 60
        return remainder > 0 ? "\(minutes) мин \(remainder) сек" : "\(minutes) мин"
    }
    return "\(total) сек"
}

private func formattedUsageSeconds(_ seconds: Double) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "ru_RU")
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2
    return "\(formatter.string(from: NSNumber(value: max(0, seconds))) ?? "0,00") с"
}

private func compactUsageInteger(_ value: Int) -> String {
    guard value >= 1_000 else { return String(max(0, value)) }
    let scaled = Double(value) / 1_000
    let digits = scaled >= 10 ? 0 : 1
    return String(format: "%.*fк", digits, scaled).replacingOccurrences(of: ".", with: ",")
}

private func russianUsageDateRange(_ snapshot: DictationUsageWeekSnapshot,
                                   calendar: Calendar) -> String {
    guard let first = snapshot.days.first?.date,
          let last = snapshot.days.last?.date else { return "" }
    let locale = Locale(identifier: "ru_RU")
    let firstComponents = calendar.dateComponents([.month, .year], from: first)
    let lastComponents = calendar.dateComponents([.month, .year], from: last)
    let lastFormatter = DateFormatter()
    lastFormatter.locale = locale
    lastFormatter.calendar = calendar
    lastFormatter.dateFormat = "d MMMM"
    if firstComponents == lastComponents {
        return "\(calendar.component(.day, from: first))–\(lastFormatter.string(from: last))"
    }
    let firstFormatter = DateFormatter()
    firstFormatter.locale = locale
    firstFormatter.calendar = calendar
    firstFormatter.dateFormat = "d MMM"
    return "\(firstFormatter.string(from: first)) – \(lastFormatter.string(from: last))"
}

@MainActor
private final class UsageMetricCard: NSView {
    init(symbolName: String,
         tint: NSColor,
         title: String,
         value: String,
         detail: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.052).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.12).cgColor

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .semibold))
        icon.image?.isTemplate = true
        icon.contentTintColor = tint
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)

        let titleLabel = HistoryItemLabel(title)
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        let valueLabel = HistoryItemLabel(value)
        valueLabel.font = .systemFont(ofSize: 31, weight: .bold)
        valueLabel.textColor = .labelColor
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(valueLabel)

        let detailLabel = HistoryItemLabel(detail)
        detailLabel.font = .systemFont(ofSize: 13, weight: .regular)
        detailLabel.textColor = .tertiaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(detailLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 136),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 17),
            icon.widthAnchor.constraint(equalToConstant: 19),
            icon.heightAnchor.constraint(equalToConstant: 19),
            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            valueLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            valueLabel.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 13),
            detailLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            detailLabel.topAnchor.constraint(equalTo: valueLabel.bottomAnchor, constant: 5),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }
}

@MainActor
private final class DictationUsageChartView: NSView {
    let snapshot: DictationUsageWeekSnapshot
    private let calendar: Calendar

    init(snapshot: DictationUsageWeekSnapshot, calendar: Calendar) {
        self.snapshot = snapshot
        self.calendar = calendar
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityLabel("График символов по дням")
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let plot = NSRect(x: 24, y: 32, width: max(1, bounds.width - 48), height: max(1, bounds.height - 72))
        let values = snapshot.days.map(\.usage.characterCount)
        let maximum = max(1, values.max() ?? 0)
        let slotWidth = plot.width / CGFloat(max(1, snapshot.days.count))
        let barWidth = min(54, slotWidth * 0.54)

        let gridColor = NSColor.separatorColor.withAlphaComponent(0.16)
        for fraction in [CGFloat(0), 0.5, 1] {
            let y = plot.maxY - (plot.height * fraction)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: plot.minX, y: y))
            path.line(to: NSPoint(x: plot.maxX, y: y))
            path.lineWidth = 1
            gridColor.setStroke()
            path.stroke()
        }

        let peakIndex = values.firstIndex(of: values.max() ?? 0)
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "ru_RU")
        dayFormatter.calendar = calendar
        dayFormatter.dateFormat = "EEE"

        for (index, slot) in snapshot.days.enumerated() {
            let value = slot.usage.characterCount
            let normalized = CGFloat(value) / CGFloat(maximum)
            let height = value > 0 ? max(4, plot.height * normalized) : 2
            let centerX = plot.minX + (slotWidth * (CGFloat(index) + 0.5))
            let rect = NSRect(x: centerX - (barWidth / 2),
                              y: plot.maxY - height,
                              width: barWidth,
                              height: height)
            let color: NSColor = index == peakIndex && value > 0 ? .systemPink : .systemBlue
            color.withAlphaComponent(value > 0 ? 0.78 : 0.16).setFill()
            NSBezierPath(roundedRect: rect, xRadius: min(7, barWidth / 2), yRadius: min(7, barWidth / 2)).fill()

            if value > 0 {
                let valueText = compactUsageInteger(value) as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
                let size = valueText.size(withAttributes: attributes)
                valueText.draw(at: NSPoint(x: centerX - (size.width / 2),
                                           y: max(3, rect.minY - size.height - 4)),
                               withAttributes: attributes)
            }

            let rawDay = dayFormatter.string(from: slot.date)
                .replacingOccurrences(of: ".", with: "")
                .lowercased()
            let dayText = rawDay as NSString
            let dayAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
            let daySize = dayText.size(withAttributes: dayAttributes)
            dayText.draw(at: NSPoint(x: centerX - (daySize.width / 2), y: plot.maxY + 13),
                         withAttributes: dayAttributes)
        }

        if snapshot.totalDictations == 0 {
            let text = "За этот период пока нет данных" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: bounds.midX - (size.width / 2),
                                  y: plot.midY - (size.height / 2)),
                      withAttributes: attributes)
        }
    }
}

@MainActor
private final class DictationSpeechTimeChartView: NSView {
    private let snapshot: DictationUsageWeekSnapshot
    private let calendar: Calendar

    init(snapshot: DictationUsageWeekSnapshot, calendar: Calendar) {
        self.snapshot = snapshot
        self.calendar = calendar
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityLabel("График времени речи по дням")
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let plot = NSRect(x: 26,
                          y: 42,
                          width: max(1, bounds.width - 52),
                          height: max(1, bounds.height - 82))
        let values = snapshot.days.map { max(0, $0.usage.audioSeconds / 60) }
        let maximum = max(1, values.max() ?? 0)
        let slotWidth = plot.width / CGFloat(max(1, snapshot.days.count))

        let gridColor = NSColor.separatorColor.withAlphaComponent(0.16)
        for fraction in [CGFloat(0), 0.5, 1] {
            let y = plot.maxY - (plot.height * fraction)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: plot.minX, y: y))
            path.line(to: NSPoint(x: plot.maxX, y: y))
            path.lineWidth = 1
            gridColor.setStroke()
            path.stroke()
        }

        let points = values.enumerated().map { index, value in
            NSPoint(x: plot.minX + (slotWidth * (CGFloat(index) + 0.5)),
                    y: plot.maxY - (plot.height * CGFloat(value / maximum)))
        }

        func appendSmoothCurve(to path: NSBezierPath, moveToFirst: Bool = true) {
            guard let first = points.first else { return }
            if moveToFirst {
                path.move(to: first)
            }
            guard points.count > 1 else { return }
            for index in 1..<points.count {
                let p0 = points[max(0, index - 2)]
                let p1 = points[index - 1]
                let p2 = points[index]
                let p3 = points[min(points.count - 1, index + 1)]
                let control1 = NSPoint(x: p1.x + ((p2.x - p0.x) / 6),
                                       y: p1.y + ((p2.y - p0.y) / 6))
                let control2 = NSPoint(x: p2.x - ((p3.x - p1.x) / 6),
                                       y: p2.y - ((p3.y - p1.y) / 6))
                path.curve(to: p2, controlPoint1: control1, controlPoint2: control2)
            }
        }

        if let first = points.first, let last = points.last {
            let area = NSBezierPath()
            area.move(to: NSPoint(x: first.x, y: plot.maxY))
            area.line(to: first)
            appendSmoothCurve(to: area, moveToFirst: false)
            area.line(to: NSPoint(x: last.x, y: plot.maxY))
            area.close()
            NSColor.systemOrange.withAlphaComponent(0.10).setFill()
            area.fill()

            let line = NSBezierPath()
            appendSmoothCurve(to: line)
            line.lineWidth = 3
            line.lineCapStyle = .round
            line.lineJoinStyle = .round
            NSColor.systemOrange.withAlphaComponent(0.88).setStroke()
            line.stroke()
        }

        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "ru_RU")
        dayFormatter.calendar = calendar
        dayFormatter.dateFormat = "EEE"
        let peakIndex = values.firstIndex(of: values.max() ?? 0)

        for (index, slot) in snapshot.days.enumerated() {
            guard index < points.count else { continue }
            let point = points[index]
            let dotRadius: CGFloat = index == peakIndex && values[index] > 0 ? 5.5 : 4
            let dotColor: NSColor = index == peakIndex && values[index] > 0 ? .systemPink : .systemOrange
            dotColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: point.x - dotRadius,
                                        y: point.y - dotRadius,
                                        width: dotRadius * 2,
                                        height: dotRadius * 2)).fill()

            if values[index] > 0 {
                let valueText = "\(Int(values[index].rounded())) м" as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
                let size = valueText.size(withAttributes: attributes)
                valueText.draw(at: NSPoint(x: point.x - (size.width / 2),
                                           y: max(4, point.y - size.height - 10)),
                               withAttributes: attributes)
            }

            let dayText = dayFormatter.string(from: slot.date)
                .replacingOccurrences(of: ".", with: "")
                .lowercased() as NSString
            let dayAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
            let daySize = dayText.size(withAttributes: dayAttributes)
            dayText.draw(at: NSPoint(x: point.x - (daySize.width / 2), y: plot.maxY + 14),
                         withAttributes: dayAttributes)
        }

        if snapshot.totalDictations == 0 {
            let text = "За этот период пока нет данных" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: bounds.midX - (size.width / 2),
                                  y: plot.midY - (size.height / 2)),
                      withAttributes: attributes)
        }
    }
}

@MainActor
final class ParakeyApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private struct CachedInsertionTarget {
        let target: FocusedInsertionTargetFrame
        let windowFrame: NSRect?
        let cachedAt: TimeInterval
    }

    private struct LastExternalClick {
        let applicationPID: pid_t
        let point: NSPoint
        let capturedAt: TimeInterval
    }

    private var statusItem: NSStatusItem!
    private var templateImage: NSImage?
    private var recordingImage: NSImage?
    private var errorImage: NSImage?
    private let audio = AudioCapture()
    private let hotkey = HotkeyListener()
    private let asr = TranscriptionWorker()
    private let insertionTargetTracker = FocusedInsertionTargetTracker()
    private let settings = Settings.shared

    private var isRecording = false
    private var isBusy = false
    private var isReady = false
    private var isCoreRuntimeReady = false
    private var isSpeechModelReady = false
    private var isTerminating = false
    private var isResettingSpeechModelCache = false
    private var isSwitchingSpeechModel = false
    private var fallbackSpeechModelProfileAfterStartupFailure: SpeechModelProfile?
    private var startupTask: Task<Void, Never>?
    private var updateCheckLoopTask: Task<Void, Never>?
    private var manualUpdateCheckTask: Task<Void, Never>?
    private var startupStatusTitle = "Loading speech model…"
    private var speechModelStartupProgressFraction: Double?
    private var startupFailure: StartupFailure?
    private var didTouchAudioEngine = false
    private var permissionReadinessTimer: Timer?
    private var lastPermissionReadinessMissingKey: String?
    /// Recording-time system-audio mute state machine. Main-actor
    /// only; transitions are driven by muteIfNeededForRecording /
    /// unmuteIfWeMuted and the SystemAudio.*Async completions. The
    /// pure decision logic lives in systemAudioMuteProbeDecision /
    /// systemAudioMuteCommandDecision / systemAudioUnmuteRequestDecision.
    private var systemAudioMutePhase: SystemAudioMutePhase = .idle
    /// Set when the recording ends while the probe or mute command is
    /// still in flight; the in-flight completion honours it.
    private var systemAudioUnmuteRequested = false
    private var maxDurationWorkItem: DispatchWorkItem?
    private var audioIdleStopWorkItem: DispatchWorkItem?
    private var isRestartingAudioInput = false
    private var pendingAudioRouteRefresh = false
    private var audioConfigurationChangeSuppressedUntil: TimeInterval?
    private var workspacePowerObservers: [NSObjectProtocol] = []
    private var hotkeyPausedForExternalCapture = false
    private var hotkeyCaptureFailsafeTimer: Timer?
    private var hotkeyRecorder: HotkeyRecorderController?
    private var shouldResumeRuntimeAfterWake = false
    private var didLogDeferredWakeRecovery = false
    private var didOfferSetupChecklistThisLaunch = false
    private var setupChecklistWindow: NSWindow?
    private var setupChecklistRefreshTimer: Timer?
    private var hotkeyTestSucceeded = false
    private var recordingLevelTimer: Timer?
    private var recordingVisualLevel: Float = 0
    private var recordingHUDPhase: CGFloat = 0
    private var lastRecordingLevelSequence: UInt64 = 0
    private var staleRecordingLevelTicks = 0
    private var recordingHUDPanel: NSPanel?
    private var recordingHUDView: RecordingHUDView?
    private var recordingHUDTranscribingStartedAt: TimeInterval?
    private var recordingHUDAnimationToken = 0
    private var recordingHUDDisplayLink: CADisplayLink?
    private var lastRecordingHUDMotionAt: TimeInterval?
    private var lastRecordingHUDTargetRefreshAt: TimeInterval?
    private var recordingHUDRevealStartedAt: TimeInterval?
    private var recordingHUDRevealFrom: CGFloat = 0
    private var recordingHUDRevealTo: CGFloat = 1
    private var recordingHUDRevealDuration: TimeInterval = RECORDING_HUD_ANIMATE_IN_SECONDS
    private var recordingHUDRevealCompletion: (() -> Void)?
    private var recordingHUDRetargetWorkItem: DispatchWorkItem?
    private var recordingHUDInsertionTargetFrame: NSRect?
    private var recordingHUDInsertionTargetVisualFrame: NSRect?
    private var recordingHUDFallbackWindowFrame: NSRect?
    private var recordingHUDTargetStabilizer = RecordingHUDTargetStabilizer()
    private var recordingHUDTargetQueryInFlight = false
    private var recordingHUDTargetSessionToken = 0
    private var recordingHUDWaitingForInitialTarget = false
    private var insertionTargetCache: [pid_t: CachedInsertionTarget] = [:]
    private var globalMouseDownMonitor: Any?
    private var lastExternalClick: LastExternalClick?
    private var errorFlashWorkItem: DispatchWorkItem?
    private var systemAudioMuteWatchdog: Process?
    private var historyOverlayWindow: HistoryOverlayPanel?
    private var historyOverlayAnimationToken = 0
    private var historyOverlayPresented = false
    private var historyOverlayGlobalDismissMonitor: Any?
    private var historyOverlayLocalDismissMonitor: Any?
    private var historyOverlayRows: [HistoryTranscriptItemView] = []
    private var statisticsOverlayWindow: HistoryOverlayPanel?
    private var statisticsOverlayAnimationToken = 0
    private var statisticsOverlayPresented = false
    private var statisticsOverlayGlobalDismissMonitor: Any?
    private var statisticsOverlayLocalDismissMonitor: Any?

    /// Local transcript archive, newest first. UI applies the user's visible limit.
    private var history: [TranscriptHistoryEntry] = []

    private var visibleHistory: [TranscriptHistoryEntry] {
        limitedRecentTranscriptEntries(history, limit: settings.recentTranscriptLimit)
    }

    /// In-session click counter per permission. Click #2 onwards
    /// resets the matching TCC entry before re-requesting — belt
    /// and braces for stuck DENIED entries macOS occasionally caches.
    private var permClickCount: [Permission: Int] = [:]

    /// Latest release detected by the periodic check. nil = no update,
    /// or user has skipped it.
    private var pendingUpdate: GitHubRelease?
    private var isCheckingForUpdates = false
    /// True while the async brew-install preflight for "Update now"
    /// is running; guards against a second click spawning a second
    /// update helper.
    private var isPreparingUpdate = false
    private var reminderPausedUpdateVersion: String?
    private var reminderPausedUntil: Date?

    private struct CorrectionImportSummary {
        let total: Int
        let newCount: Int
        let updatedCount: Int
        let unchangedCount: Int
    }

    private enum CorrectionImportChoice {
        case merge
        case replace
    }

    private var correctionSyncTimer: Timer?
    private var correctionSyncFileFingerprint: CorrectionSyncFileFingerprint?
    private var correctionSyncBaselineCorrections: [TranscriptCorrection] = []
    private var isApplyingCorrectionSyncFile = false
    /// Serial queue for the periodic sync-file scan (validate + hash
    /// + read). The UI recommends putting the sync file in iCloud
    /// Drive, where open(2) on a dataless file can block for seconds
    /// while the content downloads — far too long for the main
    /// thread, which also services the session-wide hotkey event tap.
    /// `correctionSyncScanInFlight` (main-actor) guarantees scans
    /// never overlap; results hop back to the main actor, where the
    /// existing merge/apply logic runs unchanged.
    private static let correctionSyncScanQueue = DispatchQueue(label: "ParakeyCorrectionSyncScan",
                                                               qos: .utility)
    private var correctionSyncScanInFlight = false
    /// Scan request that arrived while a scan was in flight; re-issued
    /// (with the strongest flags seen) when the in-flight scan lands.
    private var pendingCorrectionSyncScan: (force: Bool, presentErrors: Bool)?
    private var correctionSharePicker: NSSharingServicePicker?
    private var correctionShareCleanupDelegate: CorrectionShareCleanupDelegate?
    private var pendingSharedCorrectionsURL: URL?

    // MARK: - Lifecycle

    private func completeReadinessIfPossible(reason: String) {
        let missing = (isReady || isCoreRuntimeReady) ? missingPermissions() : []
        switch readinessTransition(isReady: isReady,
                                   isCoreRuntimeReady: isCoreRuntimeReady,
                                   missingPermissions: missing) {
        case .rebuildMenuOnly:
            if isReady {
                permClickCount.removeAll()
                stopPermissionReadinessMonitor()
            }
            rebuildMenu()
            return
        case .blockForPermissions(let missing):
            enterPermissionBlockedState(missing: missing, reason: reason)
            return
        case .startHotkeyListener:
            break
        }

        hotkey.onPress = { [weak self] in self?.handlePress() }
        hotkey.onRelease = { [weak self] detectedAt in
            self?.handleRelease(shortcut: .standard, hotkeyDetectedAt: detectedAt)
        }
        hotkey.onReleaseAlternate = { [weak self] detectedAt in
            self?.handleRelease(shortcut: .alternate, hotkeyDetectedAt: detectedAt)
        }
        hotkey.onCancel = { [weak self] in self?.cancelActiveRecording(reason: "escape") }
        hotkey.onShowHistory = { [weak self] in self?.toggleHistoryOverlay() }
        hotkey.isRecordingActive = { [weak self] in self?.isRecording == true }
        // Mirrors the first guard in handlePress — if this returns
        // false the press would be silently discarded, so toggle mode
        // must not flip state for it. The missing-permissions case is
        // deliberately NOT part of the gate: that press gives feedback
        // (enterPermissionBlockedState), which also resets the toggle.
        hotkey.canStartRecording = { [weak self] in
            guard let self else { return false }
            return self.isReady && !self.isRecording && !self.isBusy && !self.isTerminating
        }
        let hotkeyReady = hotkeyPausedForExternalCapture || hotkey.start()
        if hotkeyPausedForExternalCapture {
            log("HotkeyListener: startup completed while shortcut capture remains active")
        }
        guard hotkeyReady else {
            isReady = false
            isRecording = false
            isBusy = false
            hotkey.onPress = nil
            hotkey.onRelease = nil
            hotkey.onReleaseAlternate = nil
            hotkey.onCancel = nil
            hotkey.onShowHistory = nil
            hotkey.isRecordingActive = nil
            hotkey.canStartRecording = nil
            hotkey.resetToggleState()
            hotkey.stop()
            log("readiness failed (\(reason)): hotkey listener unavailable")
            setMenuBarState(.error)
            if missingPermissions().isEmpty {
                startupFailure = StartupFailure(stage: .hotkeyListener,
                                                detail: "The keyboard event tap could not be started.")
            } else {
                startPermissionReadinessMonitor(reason: reason)
            }
            rebuildMenu()
            return
        }

        isReady = true
        startupStatusTitle = "Ready"
        startupFailure = nil
        stopPermissionReadinessMonitor()
        setMenuBarState(.idle)
        refreshActivationPolicy()

        rebuildMenu()
        startUpdateCheckLoop()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if settings.normalizeSpeechModelProfileForCurrentBuild() {
            log("ASR: reset unsupported saved speech model selection to \(settings.speechModelProfile.shortName)")
        }

        recoverStaleTCCAfterUpgrade()
        _ = previousExitNoticeAction(previousRunWasActive: settings.hasActiveRunMarker)
        recoverStaleSystemAudioMuteIfNeeded()
        settings.hasActiveRunMarker = true
        restoreUpdateReminderPause()
        history = settings.recentTranscriptEntries
        importDictationUsageFromLogIfNeeded()

        refreshActivationPolicy()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        configureStatusItemImage()
        concealMenuBarIcon()
        setMenuBarState(.loading)
        startCorrectionSyncIfConfigured()
        rebuildMenu()

        audio.onConfigurationChange = { [weak self] in
            Task { @MainActor in
                self?.handleAudioConfigurationChange()
            }
        }
        installWorkspacePowerObservers()
        installGlobalMouseMonitor()
        installHotkeyCaptureObservers()

        // Configure hotkey listener up front so it picks up the user's
        // saved choice the moment the tap goes live.
        hotkey.setHotkey(settings.configuredHotkey)
        hotkey.setEnterHotkey(settings.configuredEnterHotkey)
        hotkey.setAlternateCompletionEnabled(settings.alternateCompletionEnabled)
        hotkey.setHistoryHotkey(settings.configuredHistoryHotkey)
        hotkey.setTriggerMode(settings.triggerMode)
        startStartup(reason: "launch")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openControlPanelFromAgent()
        return true
    }

    func applicationDidResignActive(_ notification: Notification) {
        closeHistoryOverlay()
        closeStatisticsOverlay()
    }

    private func openControlPanelFromAgent() {
        if SuperDictateControlPanelRegistry.activateExistingPanelIfPresent() {
            log("control panel activated from agent")
            return
        }
        guard let executablePath = Bundle.main.executablePath else {
            log("control panel open failed: missing executable path")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = []
        process.environment = systemToolProcessEnvironment()
        do {
            try process.run()
            log("control panel opened from agent")
        } catch {
            log("control panel open failed: \(error.localizedDescription)")
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !isTerminating else { return }
    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        hotkeyRecorder?.cancel()
        hotkeyRecorder = nil
        publishAgentState(status: "stopping", detail: "Dictation service is stopping.")
        settings.hasActiveRunMarker = false
        startupTask?.cancel()
        startupTask = nil
        updateCheckLoopTask?.cancel()
        updateCheckLoopTask = nil
        manualUpdateCheckTask?.cancel()
        manualUpdateCheckTask = nil
        stopPermissionReadinessMonitor()
        stopSetupChecklistRefreshTimer()
        removeWorkspacePowerObservers()
        removeGlobalMouseMonitor()
        removeHotkeyCaptureObservers()
        correctionSyncTimer?.invalidate()
        correctionSyncTimer = nil
        cleanupPendingSharedCorrections(reason: "terminate")
        audio.onConfigurationChange = nil
        cancelRecordingForTermination()
        // If the mute lifecycle is mid-flight or still holding the
        // mute, the watchdog must outlive us: the async unmute
        // requested by cancelRecordingForTermination may not run
        // before the process exits, and the watchdog unmutes + clears
        // the marker once our pid disappears.
        if systemAudioMutePhase == .idle {
            stopSystemAudioMuteWatchdog()
        }
    }

    private func installHotkeyCaptureObservers() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(self,
                           selector: #selector(externalHotkeyCaptureDidBegin(_:)),
                           name: HOTKEY_CAPTURE_BEGIN_NOTIFICATION,
                           object: nil)
        center.addObserver(self,
                           selector: #selector(externalHotkeyCaptureDidEnd(_:)),
                           name: HOTKEY_CAPTURE_END_NOTIFICATION,
                           object: nil)
    }

    private func removeHotkeyCaptureObservers() {
        hotkeyCaptureFailsafeTimer?.invalidate()
        hotkeyCaptureFailsafeTimer = nil
        let center = DistributedNotificationCenter.default()
        center.removeObserver(self, name: HOTKEY_CAPTURE_BEGIN_NOTIFICATION, object: nil)
        center.removeObserver(self, name: HOTKEY_CAPTURE_END_NOTIFICATION, object: nil)
    }

    @objc private func externalHotkeyCaptureDidBegin(_ notification: Notification) {
        guard !isRecording, !isBusy, !isTerminating else { return }
        hotkey.stop()
        hotkeyPausedForExternalCapture = true
        hotkeyCaptureFailsafeTimer?.invalidate()
        hotkeyCaptureFailsafeTimer = Timer.scheduledTimer(
            withTimeInterval: HOTKEY_CAPTURE_FAILSAFE_SECONDS,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                self?.resumeHotkeyAfterExternalCapture(reason: "failsafe")
            }
        }
        log("HotkeyListener: paused for control-panel shortcut capture")
    }

    @objc private func externalHotkeyCaptureDidEnd(_ notification: Notification) {
        resumeHotkeyAfterExternalCapture(reason: "control panel finished")
    }

    private func resumeHotkeyAfterExternalCapture(reason: String) {
        hotkeyCaptureFailsafeTimer?.invalidate()
        hotkeyCaptureFailsafeTimer = nil
        guard hotkeyPausedForExternalCapture, !isTerminating else { return }
        hotkeyPausedForExternalCapture = false
        guard isReady else {
            log("HotkeyListener: shortcut capture ended while service was not ready")
            return
        }
        guard hotkey.start() else {
            isReady = false
            recordStartupFailure(
                stage: .hotkeyListener,
                error: NSError(
                    domain: "SuperDictate",
                    code: -6,
                    userInfo: [NSLocalizedDescriptionKey: "The hotkey listener could not resume after shortcut capture."]
                ),
                reason: "external shortcut capture"
            )
            return
        }
        log("HotkeyListener: resumed after shortcut capture (\(reason))")
    }

    private func installWorkspacePowerObservers() {
        removeWorkspacePowerObservers()
        let center = NSWorkspace.shared.notificationCenter
        workspacePowerObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification,
                               object: nil,
                               queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.handleSystemWillSleep()
                }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification,
                               object: nil,
                               queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.handleSystemDidWake()
                }
            },
        ]
    }

    private func installGlobalMouseMonitor() {
        removeGlobalMouseMonitor()
        globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            let point = NSEvent.mouseLocation
            let capturedAt = ProcessInfo.processInfo.systemUptime
            Task { @MainActor [weak self] in
                guard let self,
                      !self.isTerminating,
                      let app = NSWorkspace.shared.frontmostApplication else {
                    return
                }
                self.lastExternalClick = LastExternalClick(
                    applicationPID: app.processIdentifier,
                    point: point,
                    capturedAt: capturedAt
                )
            }
        }
    }

    private func removeGlobalMouseMonitor() {
        if let globalMouseDownMonitor {
            NSEvent.removeMonitor(globalMouseDownMonitor)
            self.globalMouseDownMonitor = nil
        }
        lastExternalClick = nil
    }

    private func removeWorkspacePowerObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in workspacePowerObservers {
            center.removeObserver(observer)
        }
        workspacePowerObservers.removeAll()
    }

    private func cleanupPendingSharedCorrections(reason: String) {
        correctionSharePicker = nil
        correctionShareCleanupDelegate = nil

        guard let url = pendingSharedCorrectionsURL else { return }
        pendingSharedCorrectionsURL = nil

        let folder = url.deletingLastPathComponent().standardizedFileURL
        let tempRoot = FileManager.default.temporaryDirectory.standardizedFileURL.path
        let normalizedTempRoot = tempRoot.hasSuffix("/") ? tempRoot : "\(tempRoot)/"

        guard url.lastPathComponent == CORRECTIONS_FILE_NAME,
              folder.lastPathComponent.hasPrefix("Parakey-"),
              folder.path.hasPrefix(normalizedTempRoot)
        else {
            log("correction share cleanup skipped (\(reason)): unexpected temp file")
            return
        }

        do {
            try FileManager.default.removeItem(at: folder)
            log("correction share cleanup completed (\(reason))")
        } catch {
            log("correction share cleanup failed (\(reason))")
        }
    }

    private func startStartup(reason: String) {
        guard startupTask == nil else {
            log("startup ignored (\(reason)): already in progress")
            rebuildMenu()
            return
        }

        prepareForStartupAttempt()
        let speechModelProfile = settings.speechModelProfile

        // Load ASR FIRST, then audio + hotkey. Reversing this order
        // makes the first-launch CoreML compile of the ANE Encoder
        // hang. The bench under experiments/swift-bench/ never opens
        // an audio session so it doesn't see this.
        startupTask = Task { @MainActor in
            var stage = StartupFailureStage.speechModel
            defer {
                startupTask = nil
                rebuildMenu()
                recoverRuntimeAfterWakeIfNeeded(reason: "startup finished after wake")
            }

            do {
                try await asr.load(profile: speechModelProfile) { [weak self] progress in
                    Task { @MainActor in
                        self?.updateSpeechModelStartupProgress(progress)
                    }
                }
                guard !Task.isCancelled, !isTerminating else { return }

                do {
                    let warmUpTiming = try await asr.warmUp()
                    log("ASR: CoreML warm-up completed in \(millisecondsLabel(warmUpTiming.totalSeconds))")
                } catch {
                    // Model loading succeeded, so a failed best-effort warm-up
                    // must not make the dictation service unavailable.
                    log("ASR: CoreML warm-up skipped: \(error.localizedDescription)")
                }
                guard !Task.isCancelled, !isTerminating else { return }

                fallbackSpeechModelProfileAfterStartupFailure = nil
                isSpeechModelReady = true
                speechModelStartupProgressFraction = nil

                await recoverPendingDictationsAfterStartup()
                guard !Task.isCancelled, !isTerminating else { return }

                stage = .audioInput
                startupStatusTitle = "Starting audio input…"
                rebuildMenu()

                try await startAudioInputWithRetries(reason: reason,
                                                     initialStatusTitle: "Starting audio input…")
                guard !Task.isCancelled, !isTerminating else { return }

                isCoreRuntimeReady = true
                startupFailure = nil
                startupStatusTitle = "Finishing setup…"
                completeReadinessIfPossible(reason: reason)
            } catch {
                guard !Task.isCancelled, !isTerminating else { return }
                recordStartupFailure(stage: stage, error: error, reason: reason)
            }
        }
    }

    private func recoverPendingDictationsAfterStartup() async {
        let pendingURLs = PendingDictationRecovery.pendingURLs()
        guard !pendingURLs.isEmpty else { return }

        settings.refreshFromDisk()
        startupStatusTitle = "Recovering interrupted dictation…"
        rebuildMenu()
        log("pending dictation recovery: \(pendingURLs.count) recording(s) found")

        for url in pendingURLs {
            guard !Task.isCancelled, !isTerminating else { return }
            do {
                let samples = try PendingDictationRecovery.loadSamples(from: url)
                guard !samples.isEmpty else {
                    PendingDictationRecovery.remove(url)
                    continue
                }
                let duration = Double(samples.count) / SAMPLE_RATE
                let requestedAt = ProcessInfo.processInfo.systemUptime
                let transcription = try await asr.transcribe(
                    samples: samples,
                    language: settings.dictationLanguage.fluidLanguage,
                    requestedAt: requestedAt
                )
                let completedAt = ProcessInfo.processInfo.systemUptime
                let timing = transcription.timing(totalSeconds: completedAt - requestedAt)
                let processed = processedDictationText(rawTranscript: transcription.text,
                                                       corrections: settings.transcriptCorrections,
                                                       removeFillerWords: settings.removeFillerWords,
                                                       language: settings.dictationLanguage)
                if !processed.text.isEmpty {
                    addToHistory(
                        processed.text,
                        transcriptionDurationSeconds: timing.totalSeconds,
                        asrTiming: timing
                    )
                    recordDictationUsage(text: processed.text,
                                         audioSeconds: duration,
                                         asrSeconds: timing.totalSeconds)
                }
                PendingDictationRecovery.remove(url)
                log("pending dictation recovered: \(String(format: "%.2f", duration)) s audio → \(String(format: "%.2f", timing.totalSeconds)) s → \(processed.text.count) chars in history")
            } catch {
                log("pending dictation recovery deferred: \(error.localizedDescription)")
            }
        }
    }

    private func prepareForStartupAttempt() {
        cancelMaxDurationAutoRelease()

        if isRecording || audio.isRunning {
            let captured = audio.endRecording()
            if captured.recoveryURL != nil {
                log("startup restart: active dictation preserved for recovery")
            }
        }
        stopRecordingLevelMeter()
        unmuteIfWeMuted()

        isReady = false
        isCoreRuntimeReady = false
        isSpeechModelReady = false
        isRecording = false
        isBusy = false
        pendingAudioRouteRefresh = false
        shouldResumeRuntimeAfterWake = false
        didLogDeferredWakeRecovery = false
        startupFailure = nil
        startupStatusTitle = "Loading speech model…"
        speechModelStartupProgressFraction = nil

        hotkey.onPress = nil
        hotkey.onRelease = nil
        hotkey.onReleaseAlternate = nil
        hotkey.onCancel = nil
        hotkey.onShowHistory = nil
        hotkey.isRecordingActive = nil
        hotkey.canStartRecording = nil
        hotkey.resetToggleState()
        hotkey.stop()
        if didTouchAudioEngine {
            stopAudioEngineImmediately()
        }

        setMenuBarState(.loading)
        rebuildMenu()
    }

    private func updateSpeechModelStartupProgress(_ progress: DownloadUtils.DownloadProgress) {
        guard startupTask != nil, !isTerminating else { return }
        let next = speechModelStartupStatusTitle(progress)
        let nextProgressFraction = speechModelStartupProgressValue(progress)
        guard next != startupStatusTitle
            || nextProgressFraction != speechModelStartupProgressFraction else { return }
        startupStatusTitle = next
        speechModelStartupProgressFraction = nextProgressFraction
        rebuildMenu()
    }

    private func recordStartupFailure(stage: StartupFailureStage, error: Error, reason: String) {
        if stage == .speechModel,
           let fallback = fallbackSpeechModelProfileAfterStartupFailure,
           fallback != settings.speechModelProfile,
           !isTerminating {
            let failedProfile = settings.speechModelProfile
            fallbackSpeechModelProfileAfterStartupFailure = nil
            settings.speechModelProfile = fallback
            isSwitchingSpeechModel = true
            isCoreRuntimeReady = false
            isSpeechModelReady = false
            isReady = false
            isRecording = false
            isBusy = false
            startupFailure = nil
            startupStatusTitle = "Falling back to \(fallback.shortName)…"
            speechModelStartupProgressFraction = nil
            setMenuBarState(.loading)
            log("ASR: \(failedProfile.shortName) failed to load during switch; falling back to \(fallback.shortName): \(startupFailureLogDetail(stage: stage, error: error))")
            rebuildMenu()
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isTerminating else { return }
                Task { @MainActor in
                    await self.asr.unload()
                    self.isSwitchingSpeechModel = false
                    self.startStartup(reason: "speech model fallback")
                }
            }
            return
        }

        fallbackSpeechModelProfileAfterStartupFailure = nil
        isCoreRuntimeReady = false
        if stage == .speechModel {
            isSpeechModelReady = false
        }
        isReady = false
        isRecording = false
        isBusy = false
        speechModelStartupProgressFraction = nil
        stopRecordingLevelMeter()

        hotkey.onPress = nil
        hotkey.onRelease = nil
        hotkey.onReleaseAlternate = nil
        hotkey.onCancel = nil
        hotkey.onShowHistory = nil
        hotkey.isRecordingActive = nil
        hotkey.canStartRecording = nil
        hotkey.resetToggleState()
        hotkey.stop()
        if didTouchAudioEngine {
            stopAudioEngineImmediately()
        }

        let detail = startupFailureDetail(stage: stage, error: error)
        startupFailure = StartupFailure(stage: stage, detail: detail)
        log("startup failed (\(reason), \(stage)): \(startupFailureLogDetail(stage: stage, error: error))")
        setMenuBarState(.error)
        if !missingPermissions().isEmpty {
            startPermissionReadinessMonitor(reason: reason)
        }
        rebuildMenu()
    }

    private func startAudioInputWithRetries(reason: String,
                                            initialStatusTitle: String) async throws {
        let totalAttempts = AUDIO_START_RETRY_DELAYS_SECONDS.count + 1
        var lastError: Error?

        for attempt in 1...totalAttempts {
            try Task.checkCancellation()
            guard !isTerminating else { throw CancellationError() }

            startupStatusTitle = attempt == 1
                ? initialStatusTitle
                : "Starting audio input… (\(attempt)/\(totalAttempts))"
            rebuildMenu()

            do {
                didTouchAudioEngine = true
                suppressAudioConfigurationChangesFromAppEngineUpdate()
                try audio.startEngine(inputDevicePreference: settings.inputDevice)
                stopAudioEngineImmediately()
                return
            } catch {
                lastError = error
                stopAudioEngineImmediately()
                log("audio startup attempt \(attempt)/\(totalAttempts) failed (\(reason)): \(singleLineLogDetail(audioStartupErrorDescription(error)))")

                guard let delay = audioStartupRetryDelaySeconds(afterFailedAttempt: attempt) else {
                    throw error
                }

                startupStatusTitle = audioStartupRetryStatusTitle(nextAttempt: attempt + 1,
                                                                  totalAttempts: totalAttempts,
                                                                  delaySeconds: delay)
                rebuildMenu()
                try await Task.sleep(nanoseconds: delay * 1_000_000_000)
            }
        }

        if let lastError {
            throw lastError
        }
    }

    // MARK: - Sleep/wake runtime recovery

    private func handleSystemWillSleep() {
        guard !isTerminating else { return }

        if shouldResumeRuntimeAfterSystemSleep(isTerminating: isTerminating,
                                               isCoreRuntimeReady: isCoreRuntimeReady,
                                               isReady: isReady,
                                               isRecording: isRecording,
                                               audioIsRunning: audio.isRunning) {
            shouldResumeRuntimeAfterWake = true
            didLogDeferredWakeRecovery = false
        }

        if isRecording || audio.isRunning {
            cancelActiveRecording(reason: "system sleep", runDeferredRefresh: false)
        }

        guard isCoreRuntimeReady || isReady else {
            rebuildMenu()
            return
        }

        pauseAudioRuntimeForSystemSleep()
    }

    private func handleSystemDidWake() {
        guard !isTerminating else { return }
        guard shouldResumeRuntimeAfterWake else { return }
        log("system wake detected")
        recoverRuntimeAfterWakeIfNeeded(reason: "system wake")
    }

    private func pauseAudioRuntimeForSystemSleep() {
        cancelMaxDurationAutoRelease()
        stopRecordingLevelMeter()
        unmuteIfWeMuted()

        isReady = false
        isCoreRuntimeReady = false
        isRecording = false
        pendingAudioRouteRefresh = false
        hotkey.onPress = nil
        hotkey.onRelease = nil
        hotkey.onReleaseAlternate = nil
        hotkey.onCancel = nil
        hotkey.onShowHistory = nil
        hotkey.isRecordingActive = nil
        hotkey.canStartRecording = nil
        hotkey.resetToggleState()
        hotkey.stop()
        stopAudioEngineImmediately()

        startupFailure = nil
        startupStatusTitle = "Waiting for system wake…"
        setMenuBarState(isBusy ? .busy : .loading)
        log("system sleep: audio runtime paused")
        rebuildMenu()
    }

    private func recoverRuntimeAfterWakeIfNeeded(reason: String) {
        switch wakeRuntimeRecoveryAction(shouldResumeAfterWake: shouldResumeRuntimeAfterWake,
                                         isTerminating: isTerminating,
                                         hasStartupTask: startupTask != nil,
                                         isBusy: isBusy,
                                         isSpeechModelReady: isSpeechModelReady) {
        case .ignore:
            return
        case .deferUntilIdle:
            if !didLogDeferredWakeRecovery {
                didLogDeferredWakeRecovery = true
                log("system wake recovery deferred until idle")
            }
            rebuildMenu()
        case .startAudioRuntime:
            shouldResumeRuntimeAfterWake = false
            didLogDeferredWakeRecovery = false
            startAudioRuntimeAfterWake(reason: reason)
        case .startFullStartup:
            shouldResumeRuntimeAfterWake = false
            didLogDeferredWakeRecovery = false
            startStartup(reason: reason)
        }
    }

    private func startAudioRuntimeAfterWake(reason: String) {
        guard !isRestartingAudioInput else {
            return
        }
        guard startupTask == nil, !isBusy, !isTerminating else {
            shouldResumeRuntimeAfterWake = true
            recoverRuntimeAfterWakeIfNeeded(reason: reason)
            return
        }

        isReady = false
        isCoreRuntimeReady = false
        isRecording = false
        pendingAudioRouteRefresh = false
        isRestartingAudioInput = true
        startupFailure = nil
        startupStatusTitle = "Restarting audio input…"
        hotkey.onPress = nil
        hotkey.onRelease = nil
        hotkey.onReleaseAlternate = nil
        hotkey.onCancel = nil
        hotkey.onShowHistory = nil
        hotkey.isRecordingActive = nil
        hotkey.canStartRecording = nil
        hotkey.resetToggleState()
        hotkey.stop()
        stopAudioEngineImmediately()
        setMenuBarState(.loading)
        rebuildMenu()

        Task { @MainActor in
            defer { isRestartingAudioInput = false }
            do {
                try await startAudioInputWithRetries(reason: reason,
                                                     initialStatusTitle: "Restarting audio input…")
                guard !isTerminating else { return }
                isCoreRuntimeReady = true
                startupStatusTitle = "Finishing setup…"
                completeReadinessIfPossible(reason: reason)
            } catch {
                guard !isTerminating else { return }
                recordStartupFailure(stage: .audioInput, error: error, reason: reason)
            }
        }
    }

    // MARK: - Permission readiness

    private func enterPermissionBlockedState(missing: [Permission]? = nil, reason: String) {
        let missing = missing ?? missingPermissions()
        guard !missing.isEmpty else {
            completeReadinessIfPossible(reason: reason)
            return
        }

        if isRecording || audio.isRunning {
            recoverActiveRecordingToHistory(reason: "permission lost: \(reason)") { [weak self] in
                self?.enterPermissionBlockedState(missing: missing, reason: reason)
            }
            return
        }

        cancelMaxDurationAutoRelease()
        if audio.isEngineStarted {
            stopAudioEngineImmediately()
        }
        stopRecordingLevelMeter()
        unmuteIfWeMuted()

        isReady = false
        isRecording = false
        isBusy = false
        hotkey.onPress = nil
        hotkey.onRelease = nil
        hotkey.onReleaseAlternate = nil
        hotkey.onCancel = nil
        hotkey.onShowHistory = nil
        hotkey.isRecordingActive = nil
        hotkey.canStartRecording = nil
        hotkey.resetToggleState()
        hotkey.stop()

        logPermissionReadinessWait(missing)
        startPermissionReadinessMonitor(reason: reason)
        setMenuBarState(.loading)
        rebuildMenu()
    }

    private func missingPermissions() -> [Permission] {
        Permission.allCases.filter { !Permissions.isGranted($0) }
    }

    @discardableResult
    private func logPermissionReadinessWait(_ missing: [Permission]) -> Bool {
        let key = missing.map(\.rawValue).joined(separator: "|")
        guard key != lastPermissionReadinessMissingKey else { return false }
        lastPermissionReadinessMissingKey = key
        log("readiness retry waiting for permissions: \(missing.map(\.rawValue).joined(separator: ", "))")
        return true
    }

    private func startPermissionReadinessMonitor(reason: String) {
        guard permissionReadinessTimer == nil else { return }
        log("permission readiness monitor started (\(reason))")
        permissionReadinessTimer = Timer.scheduledTimer(timeInterval: 2,
                                                        target: self,
                                                        selector: #selector(permissionReadinessTimerFired(_:)),
                                                        userInfo: nil,
                                                        repeats: true)
        permissionReadinessTimer?.tolerance = 0.5
    }

    private func stopPermissionReadinessMonitor() {
        guard permissionReadinessTimer != nil else { return }
        permissionReadinessTimer?.invalidate()
        permissionReadinessTimer = nil
        lastPermissionReadinessMissingKey = nil
        log("permission readiness monitor stopped")
    }

    @objc private func permissionReadinessTimerFired(_ timer: Timer) {
        guard isCoreRuntimeReady else {
            let missing = missingPermissions()
            guard !missing.isEmpty else {
                permClickCount.removeAll()
                stopPermissionReadinessMonitor()
                rebuildMenu()
                return
            }
            if logPermissionReadinessWait(missing) {
                rebuildMenu()
            }
            return
        }

        if isReady {
            let missing = missingPermissions()
            guard !missing.isEmpty else {
                permClickCount.removeAll()
                stopPermissionReadinessMonitor()
                rebuildMenu()
                return
            }
            enterPermissionBlockedState(missing: missing, reason: "permission monitor")
            return
        }

        completeReadinessIfPossible(reason: "permission monitor")
    }

    // MARK: - File imports

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        var didImport = false
        for filename in filenames {
            let url = URL(fileURLWithPath: filename)
            if importCorrectionsFromUserSelectedFile(url) {
                didImport = true
            }
        }
        sender.reply(toOpenOrPrint: didImport ? .success : .failure)
    }

    // MARK: - Menu bar appearance
    //
    // Same silhouette across all states; only colour shifts. The
    // template image is used for idle/loading/busy so it auto-adapts to
    // light/dark menu bar. For recording/error we swap to pre-rendered,
    // non-template images: NSStatusItem.button silently drops
    // contentTintColor on template images in some macOS configurations,
    // so baking the colour into the image is the only reliable way to
    // guarantee the recording state actually reads.

    private func configureStatusItemImage() {
        guard let button = statusItem.button else { return }
        // The PNG lives in Contents/Resources/ of our .app bundle
        // (the canonical macOS layout — same place release.sh /
        // dev-run.sh copy it). NSImage(named:) on the main bundle
        // finds it under that path automatically; Bundle.module is
        // deliberately not used here so codesign --deep doesn't have
        // to grapple with a SwiftPM resource bundle.
        let image = NSImage(named: "parakey-menubar")
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        templateImage = image
        recordingImage = image.map { tintedCopy(of: $0, with: settings.recordingHUDRecordingColor.nsColor) }
        errorImage = image.map { tintedCopy(of: $0, with: .systemYellow) }
        button.image = image
        button.imagePosition = .imageOnly
        if image == nil {
            button.title = "Parakey"
            log("statusItem: parakey-menubar.png not in Bundle.main — text fallback")
        }
        button.toolTip = "Parakey"
    }

    private func concealMenuBarIcon() {
        statusItem.length = 0
        statusItem.button?.isHidden = true
        statusItem.button?.toolTip = nil
    }

    private func tintedCopy(of source: NSImage, with color: NSColor) -> NSImage {
        let size = source.size
        let rect = NSRect(origin: .zero, size: size)
        let tinted = NSImage(size: size)
        tinted.lockFocus()
        drawTintedIcon(source, in: rect, color: color)
        tinted.unlockFocus()
        tinted.isTemplate = false
        return tinted
    }

    private func drawTintedIcon(_ source: NSImage, in rect: NSRect, color: NSColor) {
        source.draw(in: rect,
                    from: NSRect(origin: .zero, size: source.size),
                    operation: .sourceOver,
                    fraction: 1.0)
        color.set()
        rect.fill(using: .sourceAtop)
    }

    private func setMenuBarState(_ state: MenuBarState) {
        guard let button = statusItem.button else { return }
        switch state {
        case .loading:
            // Subtle dim while the model compiles. nil contentTintColor
            // = system default (black/white per theme); .tertiary gives
            // a "this is here but not yet active" feel.
            button.image = templateImage
            button.contentTintColor = .tertiaryLabelColor
        case .idle:
            // Default tint — macOS auto-handles light/dark menu bar.
            button.image = templateImage
            button.contentTintColor = nil
        case .recording:
            button.image = recordingImage ?? templateImage
            button.contentTintColor = nil
        case .busy:
            // Transcribe is typically <200 ms, briefer than a perceptible
            // colour change. Leave at default; the menu's first row says
            // "Transcribing" if the user pops it open.
            button.image = templateImage
            button.contentTintColor = nil
        case .error:
            button.image = errorImage ?? templateImage
            button.contentTintColor = nil
        }
    }

    private func startRecordingLevelMeter(initialContext: InsertionTargetQueryContext?) {
        recordingLevelTimer?.invalidate()
        recordingLevelTimer = nil
        recordingVisualLevel = 0
        lastRecordingLevelSequence = 0
        staleRecordingLevelTicks = 0
        recordingHUDPhase = 0
        recordingHUDInsertionTargetFrame = nil
        recordingHUDInsertionTargetVisualFrame = nil
        recordingHUDFallbackWindowFrame = nil
        recordingHUDTranscribingStartedAt = nil
        lastRecordingHUDTargetRefreshAt = nil
        recordingHUDRetargetWorkItem?.cancel()
        recordingHUDRetargetWorkItem = nil
        recordingHUDTargetSessionToken &+= 1
        recordingHUDTargetQueryInFlight = false
        recordingHUDWaitingForInitialTarget = settings.showRecordingWaveform
        recordingHUDTargetStabilizer.reset(initialApplicationPID: initialContext?.applicationPID)
        setMenuBarState(.recording)
        let timer = Timer(timeInterval: 1.0 / 24.0,
                          target: self,
                          selector: #selector(recordingLevelTimerFired(_:)),
                          userInfo: nil,
                          repeats: true)
        timer.tolerance = 1.0 / 48.0
        RunLoop.main.add(timer, forMode: .common)
        recordingLevelTimer = timer

        if let initialContext {
            requestRecordingHUDTarget(context: initialContext, isInitial: true)
        } else {
            recordingHUDWaitingForInitialTarget = false
            log("text insertion target unavailable at recording start: frontmost application unavailable")
            if settings.showRecordingWaveform {
                showRecordingHUD(mode: .recording, level: 0)
            }
        }
    }

    private func stopRecordingLevelMeter(resetImage: Bool = true, hideHUD: Bool = true) {
        recordingLevelTimer?.invalidate()
        recordingLevelTimer = nil
        recordingVisualLevel = 0
        lastRecordingLevelSequence = 0
        staleRecordingLevelTicks = 0
        if !isRecording {
            stopRecordingHUDTargetTracking(clearTarget: false)
        }
        if hideHUD {
            recordingHUDPhase = 0
        }
        if hideHUD {
            hideRecordingHUD()
        }
        if resetImage, isRecording {
            setMenuBarState(.recording)
        }
    }

    @objc private func recordingLevelTimerFired(_ timer: Timer) {
        guard isRecording else {
            stopRecordingLevelMeter()
            return
        }
        let snapshot = audio.latestRecordingLevelSnapshot()
        if snapshot.sequence == lastRecordingLevelSequence {
            staleRecordingLevelTicks += 1
        } else {
            lastRecordingLevelSequence = snapshot.sequence
            staleRecordingLevelTicks = 0
        }
        let unsuppressedLevel = staleRecordingLevelTicks > 8 ? 0 : snapshot.level
        let rawLevel = visibleRecordingLevel(rawLevel: unsuppressedLevel)
        let attack: Float = rawLevel > recordingVisualLevel ? 0.65 : 0.28
        recordingVisualLevel += (rawLevel - recordingVisualLevel) * attack
        let now = ProcessInfo.processInfo.systemUptime
        refreshRecordingHUDInsertionTargetIfNeeded(at: now)
        if settings.showRecordingWaveform {
            guard !recordingHUDWaitingForInitialTarget else { return }
            if recordingHUDPanel?.isVisible == true {
                updateRecordingHUD(mode: .recording, level: recordingVisualLevel)
            } else {
                showRecordingHUD(mode: .recording, level: recordingVisualLevel)
            }
        } else {
            hideRecordingHUD()
        }
    }

    private var recordingHUDExpandedSize: NSSize {
        settings.recordingHUDSize.expandedSize
    }

    private func showRecordingHUD(mode: RecordingHUDMode,
                                  level: Float) {
        guard settings.showRecordingWaveform else { return }
        let panel = recordingHUDPanel ?? makeRecordingHUDPanel()
        recordingHUDPanel = panel
        let shouldAnimate = !panel.isVisible
        if let view = recordingHUDView {
            configureRecordingHUDView(view)
            view.mode = mode
            view.level = level
            view.phase = recordingHUDPhase
        }
        if shouldAnimate {
            animateRecordingHUDIn(panel)
        } else {
            recordingHUDAnimationToken += 1
            stopRecordingHUDRevealAnimation(finish: true)
            panel.alphaValue = 1
            recordingHUDView?.revealProgress = 1
            panel.setFrame(recordingHUDFrame(size: recordingHUDExpandedSize), display: true)
            panel.orderFrontRegardless()
        }
        startRecordingHUDMotion()
    }

    private func updateRecordingHUD(mode: RecordingHUDMode,
                                    level: Float) {
        if let view = recordingHUDView {
            configureRecordingHUDView(view)
            view.mode = mode
            view.level = level
            view.phase = recordingHUDPhase
        }
    }

    private func showTranscribingHUD() {
        guard settings.showRecordingWaveform else { return }
        recordingHUDTranscribingStartedAt = ProcessInfo.processInfo.systemUptime
        if recordingHUDPanel?.isVisible == true {
            updateRecordingHUD(mode: .transcribing, level: 0)
        } else {
            showRecordingHUD(mode: .transcribing, level: 0)
        }
        startRecordingHUDMotion()
    }

    private func hideRecordingHUD() {
        recordingHUDRetargetWorkItem?.cancel()
        recordingHUDRetargetWorkItem = nil
        guard let panel = recordingHUDPanel else {
            stopRecordingHUDMotion()
            recordingHUDInsertionTargetFrame = nil
            recordingHUDInsertionTargetVisualFrame = nil
            recordingHUDFallbackWindowFrame = nil
            lastRecordingHUDTargetRefreshAt = nil
            stopRecordingHUDTargetTracking(clearTarget: true)
            return
        }
        recordingHUDAnimationToken += 1
        stopRecordingHUDRevealAnimation(finish: false)
        guard panel.isVisible else {
            stopRecordingHUDMotion()
            panel.alphaValue = 1
            panel.setFrame(recordingHUDFrame(size: recordingHUDExpandedSize), display: false)
            recordingHUDView?.mode = .recording
            recordingHUDView?.level = 0
            recordingHUDView?.phase = 0
            recordingHUDView?.revealProgress = 1
            recordingHUDInsertionTargetFrame = nil
            recordingHUDInsertionTargetVisualFrame = nil
            recordingHUDFallbackWindowFrame = nil
            lastRecordingHUDTargetRefreshAt = nil
            stopRecordingHUDTargetTracking(clearTarget: true)
            return
        }

        let token = recordingHUDAnimationToken
        panel.alphaValue = 1
        panel.setFrame(recordingHUDFrame(size: recordingHUDExpandedSize),
                       display: false)
        startRecordingHUDRevealAnimation(from: recordingHUDView?.revealProgress ?? 1,
                                         to: 0,
                                         duration: RECORDING_HUD_ANIMATE_OUT_SECONDS) { [weak panel, weak self] in
            guard let self, let panel else { return }
            guard self.recordingHUDAnimationToken == token else { return }
            panel.orderOut(nil)
            panel.alphaValue = 1
            panel.setFrame(self.recordingHUDFrame(size: self.recordingHUDExpandedSize),
                           display: false)
            self.recordingHUDView?.mode = .recording
            self.recordingHUDView?.level = 0
            self.recordingHUDView?.phase = 0
            self.recordingHUDView?.revealProgress = 1
            self.recordingHUDInsertionTargetFrame = nil
            self.recordingHUDInsertionTargetVisualFrame = nil
            self.recordingHUDFallbackWindowFrame = nil
            self.lastRecordingHUDTargetRefreshAt = nil
            self.stopRecordingHUDTargetTracking(clearTarget: true)
            self.stopRecordingHUDMotion()
        }
    }

    private func startRecordingHUDMotion() {
        guard recordingHUDDisplayLink == nil,
              let view = recordingHUDView else {
            return
        }
        lastRecordingHUDMotionAt = ProcessInfo.processInfo.systemUptime
        let displayLink = view.displayLink(target: self,
                                           selector: #selector(recordingHUDDisplayLinkFired(_:)))
        displayLink.preferredFrameRateRange = CAFrameRateRange(
            minimum: RECORDING_HUD_DISPLAY_LINK_MIN_FPS,
            maximum: RECORDING_HUD_DISPLAY_LINK_MAX_FPS,
            preferred: RECORDING_HUD_DISPLAY_LINK_MAX_FPS
        )
        displayLink.add(to: .main, forMode: .common)
        recordingHUDDisplayLink = displayLink
    }

    private func stopRecordingHUDMotion() {
        recordingHUDDisplayLink?.invalidate()
        recordingHUDDisplayLink = nil
        lastRecordingHUDMotionAt = nil
    }

    @objc private func recordingHUDDisplayLinkFired(_ displayLink: CADisplayLink) {
        let hudIsVisible = recordingHUDPanel?.isVisible == true
        guard hudIsVisible || recordingHUDRevealStartedAt != nil else {
            stopRecordingHUDMotion()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let previous = lastRecordingHUDMotionAt ?? now
        let dt = max(0.001, min(0.05, now - previous))
        lastRecordingHUDMotionAt = now

        advanceRecordingHUDRevealAnimation(at: now)
        let mode = recordingHUDView?.mode
            ?? ((isBusy && !isRecording) ? .transcribing : .recording)
        let speed = recordingHUDPhaseSpeed(mode: mode, level: recordingVisualLevel)
        recordingHUDPhase += CGFloat(dt) * speed
        recordingHUDView?.phase = recordingHUDPhase
        _ = moveRecordingHUDTowardInsertionTarget(deltaTime: dt)
        recordingHUDView?.displayIfNeeded()
    }

    private func makeRecordingHUDPanel() -> NSPanel {
        let size = recordingHUDExpandedSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        let view = RecordingHUDView(frame: NSRect(origin: .zero, size: size))
        configureRecordingHUDView(view)
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        recordingHUDView = view
        return panel
    }

    private func configureRecordingHUDView(_ view: RecordingHUDView) {
        view.visualScale = settings.recordingHUDSize.visualScale
        view.recordingColor = settings.recordingHUDRecordingColor.nsColor
        view.transcribingColor = settings.recordingHUDTranscribingColor.nsColor
        view.backgroundStyle = settings.recordingHUDBackgroundStyle
    }

    private func animateRecordingHUDIn(_ panel: NSPanel) {
        recordingHUDAnimationToken += 1
        stopRecordingHUDRevealAnimation(finish: false)
        let finalFrame = recordingHUDFrame(size: recordingHUDExpandedSize)
        recordingHUDView?.revealProgress = 0
        panel.alphaValue = 1
        panel.setFrame(finalFrame, display: true)
        panel.contentView?.displayIfNeeded()
        panel.displayIfNeeded()
        panel.orderFrontRegardless()
        startRecordingHUDRevealAnimation(from: 0,
                                         to: 1,
                                         duration: RECORDING_HUD_ANIMATE_IN_SECONDS)
    }

    private func recordingHUDFrame(size: NSSize) -> NSRect {
        if let targetFrame = recordingHUDInsertionTargetVisualFrame ?? recordingHUDInsertionTargetFrame {
            return recordingHUDFrameAboveTarget(targetFrame, size: size)
        }
        if let fallbackWindow = recordingHUDFallbackWindowFrame {
            return recordingHUDFrameInsideFallbackWindow(fallbackWindow, size: size)
        }
        let visible = NSScreen.main?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = visible.midX - (size.width / 2)
        let y = visible.maxY - size.height - 96
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func recordingHUDFrameInsideFallbackWindow(_ windowFrame: NSRect,
                                                       size: NSSize) -> NSRect {
        let screen = screenFor(point: NSPoint(x: windowFrame.midX, y: windowFrame.midY))
        let visible = screen.visibleFrame
        let contentInset = min(180, max(28, windowFrame.width * 0.15))
        let preferredX = windowFrame.minX + contentInset
        let preferredY = windowFrame.minY + min(96, max(44, windowFrame.height * 0.14))
        let x = min(max(preferredX, visible.minX + 12), visible.maxX - size.width - 12)
        let y = min(max(preferredY, visible.minY + 12), visible.maxY - size.height - 12)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func recordingHUDFrameAboveTarget(_ targetFrame: NSRect, size: NSSize) -> NSRect {
        let center = NSPoint(x: targetFrame.midX, y: targetFrame.midY)
        let visible = screenFor(point: center).visibleFrame
        let gap: CGFloat = 12
        let preferredX = targetFrame.minX + 6
        let preferredY = targetFrame.maxY + gap + 8
        let fallbackY = targetFrame.minY - gap - size.height
        let y = preferredY + size.height <= visible.maxY - 8
            ? preferredY
            : fallbackY
        let x = min(max(preferredX, visible.minX + 12), visible.maxX - size.width - 12)
        let clampedY = min(max(y, visible.minY + 12), visible.maxY - size.height - 12)
        return NSRect(x: x, y: clampedY, width: size.width, height: size.height)
    }

    private func startRecordingHUDRevealAnimation(from: CGFloat,
                                                  to: CGFloat,
                                                  duration: TimeInterval,
                                                  completion: (() -> Void)? = nil) {
        recordingHUDRevealFrom = max(0, min(1, from))
        recordingHUDRevealTo = max(0, min(1, to))
        let distance = abs(recordingHUDRevealTo - recordingHUDRevealFrom)
        recordingHUDRevealDuration = max(1.0 / Double(RECORDING_HUD_DISPLAY_LINK_MAX_FPS),
                                         duration * Double(distance))
        recordingHUDRevealCompletion = completion
        recordingHUDView?.revealProgress = recordingHUDRevealFrom
        recordingHUDRevealStartedAt = ProcessInfo.processInfo.systemUptime
        startRecordingHUDMotion()
    }

    private func stopRecordingHUDRevealAnimation(finish: Bool) {
        recordingHUDRevealStartedAt = nil
        let finalProgress = recordingHUDRevealTo
        let completion = recordingHUDRevealCompletion
        recordingHUDRevealCompletion = nil
        if finish {
            recordingHUDView?.revealProgress = finalProgress
            completion?()
        }
    }

    private func advanceRecordingHUDRevealAnimation(at now: TimeInterval) {
        guard let startedAt = recordingHUDRevealStartedAt,
              let view = recordingHUDView else {
            return
        }
        let elapsed = now - startedAt
        let progress = min(1, max(0, elapsed / recordingHUDRevealDuration))
        // The view gives each visual layer its own quintic curve. Keep this
        // master timeline linear so those curves do not get double-eased.
        view.revealProgress = recordingHUDRevealFrom
            + ((recordingHUDRevealTo - recordingHUDRevealFrom) * CGFloat(progress))
        if progress >= 1 {
            stopRecordingHUDRevealAnimation(finish: true)
        }
    }

    private func insertionTargetQueryContext() -> InsertionTargetQueryContext? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let screens = NSScreen.screens.map {
            InsertionTargetScreenGeometry(frame: $0.frame, visibleFrame: $0.visibleFrame)
        }
        let referenceMaxY = screens.first?.frame.maxY
            ?? NSScreen.main?.frame.maxY
            ?? 0
        let now = ProcessInfo.processInfo.systemUptime
        let clickPoint: NSPoint?
        if let lastExternalClick,
           lastExternalClick.applicationPID == app.processIdentifier,
           now - lastExternalClick.capturedAt <= RECORDING_HUD_TARGET_CACHE_MAX_AGE {
            clickPoint = lastExternalClick.point
        } else {
            clickPoint = nil
        }
        return InsertionTargetQueryContext(
            applicationPID: app.processIdentifier,
            applicationName: app.localizedName ?? "unknown",
            bundleIdentifier: app.bundleIdentifier ?? "unknown",
            screens: screens,
            coordinateReferenceMaxY: referenceMaxY,
            lastClickPoint: clickPoint
        )
    }

    private func requestRecordingHUDTarget(context: InsertionTargetQueryContext? = nil,
                                           isInitial: Bool = false) {
        guard isRecording, !recordingHUDTargetQueryInFlight else { return }
        guard let context = context ?? insertionTargetQueryContext() else {
            if isInitial {
                recordingHUDWaitingForInitialTarget = false
                if settings.showRecordingWaveform {
                    showRecordingHUD(mode: .recording, level: recordingVisualLevel)
                }
            }
            return
        }

        recordingHUDTargetQueryInFlight = true
        let sessionToken = recordingHUDTargetSessionToken
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.insertionTargetTracker.query(context: context)
            guard self.recordingHUDTargetSessionToken == sessionToken,
                  self.isRecording else {
                return
            }
            self.recordingHUDTargetQueryInFlight = false
            self.handleRecordingHUDTargetResult(result, isInitial: isInitial)
        }
    }

    private func handleRecordingHUDTargetResult(_ result: FocusedInsertionTargetQueryResult,
                                                isInitial: Bool) {
        lastRecordingHUDTargetRefreshAt = ProcessInfo.processInfo.systemUptime
        if let focusedWindowFrame = result.focusedWindowFrame {
            recordingHUDFallbackWindowFrame = focusedWindowFrame
        }

        let liveTarget = result.target.flatMap {
            shouldUseRecordingHUDInsertionTarget($0) ? $0 : nil
        }
        let observedTarget = liveTarget ?? cachedInsertionTarget(for: result)
        let decision = recordingHUDTargetStabilizer.observe(observedTarget)
        switch decision {
        case .none:
            break
        case .update(let target):
            applyRecordingHUDTarget(target,
                                    queryResult: result,
                                    animateSwitch: false,
                                    updateCache: liveTarget != nil)
        case .switchTarget(let target):
            applyRecordingHUDTarget(target,
                                    queryResult: result,
                                    animateSwitch: recordingHUDPanel?.isVisible == true,
                                    updateCache: liveTarget != nil)
        }

        if isInitial {
            recordingHUDWaitingForInitialTarget = false
            if let liveTarget {
                log("text insertion target captured at recording start: \(liveTarget.resolutionKind), frontmost: \(result.applicationName) (\(result.bundleIdentifier)); \(result.diagnostic)")
            } else if observedTarget != nil {
                log("text insertion target restored from recent cache, frontmost: \(result.applicationName) (\(result.bundleIdentifier)); \(result.diagnostic)")
            } else {
                log("text insertion target unavailable at recording start, frontmost: \(result.applicationName) (\(result.bundleIdentifier)); \(result.diagnostic)")
            }
            if settings.showRecordingWaveform {
                showRecordingHUD(mode: .recording, level: recordingVisualLevel)
            }
        } else if liveTarget != nil,
                  case .switchTarget(let target) = decision {
            log("text insertion target switched during recording: \(target.resolutionKind), frontmost: \(result.applicationName) (\(result.bundleIdentifier))")
        }
    }

    private func applyRecordingHUDTarget(_ target: FocusedInsertionTargetFrame,
                                         queryResult: FocusedInsertionTargetQueryResult,
                                         animateSwitch: Bool,
                                         updateCache: Bool) {
        let previousTargetFrame = recordingHUDInsertionTargetVisualFrame
            ?? recordingHUDInsertionTargetFrame
        recordingHUDInsertionTargetFrame = target.frame
        recordingHUDInsertionTargetVisualFrame = target.visualFrame
        if updateCache {
            insertionTargetCache[target.identity.applicationPID] = CachedInsertionTarget(
                target: target,
                windowFrame: queryResult.focusedWindowFrame,
                cachedAt: ProcessInfo.processInfo.systemUptime
            )
        }
        if animateSwitch {
            animateRecordingHUDRetargetIfNeeded(from: previousTargetFrame,
                                                to: target.visualFrame)
        }
    }

    private func cachedInsertionTarget(for result: FocusedInsertionTargetQueryResult) -> FocusedInsertionTargetFrame? {
        guard let cached = insertionTargetCache[result.applicationPID],
              ProcessInfo.processInfo.systemUptime - cached.cachedAt <= RECORDING_HUD_TARGET_CACHE_MAX_AGE else {
            insertionTargetCache[result.applicationPID] = nil
            return nil
        }
        if result.focusedWindowToken != 0,
           cached.target.identity.windowToken != 0,
           result.focusedWindowToken != cached.target.identity.windowToken {
            return nil
        }

        var frame = cached.target.frame
        var visualFrame = cached.target.visualFrame
        if let oldWindow = cached.windowFrame,
           let newWindow = result.focusedWindowFrame {
            let dx = newWindow.minX - oldWindow.minX
            let dy = newWindow.minY - oldWindow.minY
            frame = frame.offsetBy(dx: dx, dy: dy)
            visualFrame = visualFrame.offsetBy(dx: dx, dy: dy)
            guard newWindow.insetBy(dx: -80, dy: -80).intersects(visualFrame) else {
                return nil
            }
        }
        return FocusedInsertionTargetFrame(
            frame: frame,
            visualFrame: visualFrame,
            resolutionKind: "\(cached.target.resolutionKind) cache",
            identity: cached.target.identity
        )
    }

    private func stopRecordingHUDTargetTracking(clearTarget: Bool) {
        recordingHUDTargetSessionToken &+= 1
        recordingHUDTargetQueryInFlight = false
        recordingHUDWaitingForInitialTarget = false
        lastRecordingHUDTargetRefreshAt = nil
        if clearTarget {
            recordingHUDTargetStabilizer.reset(initialApplicationPID: nil)
            recordingHUDFallbackWindowFrame = nil
        }
    }

    private func refreshRecordingHUDInsertionTargetIfNeeded(at now: TimeInterval) {
        guard isRecording else { return }
        if let last = lastRecordingHUDTargetRefreshAt,
           now - last < RECORDING_HUD_TARGET_REFRESH_INTERVAL {
            return
        }
        lastRecordingHUDTargetRefreshAt = now
        requestRecordingHUDTarget()
    }

    private func shouldUseRecordingHUDInsertionTarget(_ target: FocusedInsertionTargetFrame) -> Bool {
        let frame = target.visualFrame
        guard frame.minX.isFinite,
              frame.minY.isFinite,
              frame.width.isFinite,
              frame.height.isFinite,
              frame.width > 0,
              frame.height > 0 else {
            return false
        }

        let visible = screenFor(point: NSPoint(x: frame.midX, y: frame.midY)).visibleFrame
        if frame.width > visible.width * 0.92,
           frame.height > visible.height * 0.55 {
            return false
        }
        if frame.height > visible.height * 0.82 {
            return false
        }
        return true
    }

    private func moveRecordingHUDTowardInsertionTarget(deltaTime: TimeInterval) -> Bool {
        guard let panel = recordingHUDPanel,
              panel.isVisible,
              recordingHUDView?.revealProgress == 1 else {
            return false
        }

        let target = recordingHUDFrame(size: recordingHUDExpandedSize)
        guard recordingHUDRetargetWorkItem == nil else {
            return true
        }

        let current = panel.frame
        let deltaX = target.midX - current.midX
        let deltaY = target.midY - current.midY
        if abs(deltaX) < 0.35, abs(deltaY) < 0.35 {
            if !NSEqualRects(current, target) {
                panel.setFrame(target, display: false)
            }
            return true
        }

        let response = 1 - CGFloat(exp(-Double(RECORDING_HUD_TARGET_FOLLOW_RESPONSE) * deltaTime))
        let nextCenter = NSPoint(x: current.midX + (deltaX * response),
                                 y: current.midY + (deltaY * response))
        let size = recordingHUDExpandedSize
        let next = NSRect(x: nextCenter.x - (size.width / 2),
                          y: nextCenter.y - (size.height / 2),
                          width: size.width,
                          height: size.height)
        panel.setFrame(clampedRecordingHUDFrame(next), display: false)
        return true
    }

    private func animateRecordingHUDRetargetIfNeeded(from previousTargetFrame: NSRect?,
                                                     to newTargetFrame: NSRect) {
        guard isRecording else { return }
        guard let panel = recordingHUDPanel,
              panel.isVisible,
              recordingHUDView?.mode == .recording else {
            return
        }

        let target = recordingHUDFrameAboveTarget(newTargetFrame,
                                                  size: recordingHUDExpandedSize)
        let distance = hypot(target.midX - panel.frame.midX,
                             target.midY - panel.frame.midY)
        guard distance > 8 else {
            if distance > 1 {
                panel.setFrame(target, display: false)
            }
            return
        }
        if let previousTargetFrame,
           hypot(previousTargetFrame.midX - newTargetFrame.midX,
                 previousTargetFrame.midY - newTargetFrame.midY) < 3,
           abs(previousTargetFrame.width - newTargetFrame.width) < 3,
           abs(previousTargetFrame.height - newTargetFrame.height) < 3 {
            return
        }

        recordingHUDRetargetWorkItem?.cancel()
        recordingHUDRetargetWorkItem = nil
        recordingHUDAnimationToken += 1
        let token = recordingHUDAnimationToken
        stopRecordingHUDRevealAnimation(finish: false)

        startRecordingHUDRevealAnimation(from: recordingHUDView?.revealProgress ?? 1,
                                         to: 0,
                                         duration: RECORDING_HUD_ANIMATE_OUT_SECONDS) { [weak self, weak panel] in
            let work = DispatchWorkItem { [weak self, weak panel] in
                guard let self, let panel else { return }
                self.recordingHUDRetargetWorkItem = nil
                guard self.recordingHUDAnimationToken == token else { return }
                panel.setFrame(target, display: false)
                self.recordingHUDView?.revealProgress = 0
                panel.alphaValue = 1
                panel.contentView?.displayIfNeeded()
                panel.displayIfNeeded()
                panel.orderFrontRegardless()
                self.startRecordingHUDRevealAnimation(from: 0,
                                                      to: 1,
                                                      duration: RECORDING_HUD_ANIMATE_IN_SECONDS)
            }
            self?.recordingHUDRetargetWorkItem = work
            DispatchQueue.main.async(execute: work)
        }
    }

    private func screenForRecordingHUD() -> NSScreen {
        screenFor(point: NSEvent.mouseLocation)
    }

    private func screenFor(point: NSPoint) -> NSScreen {
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) {
            return screen
        }
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            return screen
        }
        preconditionFailure("NSScreen.screens unexpectedly empty")
    }

    private func clampedRecordingHUDFrame(_ frame: NSRect) -> NSRect {
        let screen = screenFor(point: NSPoint(x: frame.midX, y: frame.midY))
        let visible = screen.visibleFrame
        let x = min(max(frame.minX, visible.minX + 12), visible.maxX - frame.width - 12)
        let y = min(max(frame.minY, visible.minY + 12), visible.maxY - frame.height - 12)
        return NSRect(x: x, y: y, width: frame.width, height: frame.height)
    }

    private func finishBusyHUD() {
        if let startedAt = recordingHUDTranscribingStartedAt {
            let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
            let remaining = RECORDING_HUD_TRANSCRIBING_MIN_VISIBLE_SECONDS - elapsed
            if remaining > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
                    guard let self,
                          !self.isRecording,
                          !self.isBusy,
                          self.recordingHUDTranscribingStartedAt == startedAt else { return }
                    self.recordingHUDTranscribingStartedAt = nil
                    self.hideRecordingHUD()
                }
                return
            }
        }
        recordingHUDTranscribingStartedAt = nil
        hideRecordingHUD()
    }

    // Visible + audible cue that a press produced no pasted text — the
    // transcription threw, or the paste itself failed. Without it the menu
    // bar just slips back to idle and the user can't tell their speech was
    // dropped from "pasted somewhere I wasn't looking."
    //
    // The error sound plays unconditionally (not gated by
    // playFeedbackSounds): start/done sounds are optional polish, but
    // a dropped dictation is a failure the user must notice. The HUD
    // flash provides a visual channel for users who run silent or
    // have the menu-bar icon hidden.
    private func signalDictationFailure() {
        Sounds.playError()
        flashErrorFeedback()
    }

    /// Flashes both the menu-bar icon (error tint) and the recording
    /// HUD (static yellow capsule with exclamation mark) for
    /// DICTATION_ERROR_FLASH_SECONDS. A single work item owns both
    /// channels so they always expire together.
    private func flashErrorFeedback() {
        errorFlashWorkItem?.cancel()
        setMenuBarState(.error)
        if settings.showRecordingWaveform {
            showRecordingHUD(mode: .error, level: 0)
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.errorFlashWorkItem = nil
            // Only clear if nothing else has claimed the icon meanwhile — a
            // new recording, an in-flight transcription, a real (non-transient)
            // error state, or termination all own it and must not be stomped.
            guard self.isReady, !self.isRecording, !self.isBusy, !self.isTerminating else { return }
            self.setMenuBarState(.idle)
            self.hideRecordingHUD()
            self.rebuildMenu()
        }
        errorFlashWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + DICTATION_ERROR_FLASH_SECONDS, execute: work)
    }

    // MARK: - Recording loop

    private func handlePress() {
        guard isReady, !isRecording, !isBusy, !isTerminating else {
            // Audible cue when the previous transcription is still in
            // flight — without it the press vanishes silently and the
            // user thinks the hotkey broke. Only fires for the busy
            // case; model-loading and termination have their own UI.
            if isBusy, settings.playFeedbackSounds {
                Sounds.playError()
            }
            return
        }
        let missing = missingPermissions()
        guard missing.isEmpty else {
            enterPermissionBlockedState(missing: missing, reason: "hotkey press")
            return
        }
        let initialInsertionContext = insertionTargetQueryContext()
        cancelAudioIdleStop()
        var recoveryJournal: PendingDictationJournal?
        do {
            recoveryJournal = try PendingDictationRecovery.createJournal()
            didTouchAudioEngine = true
            if !audio.isEngineStarted {
                suppressAudioConfigurationChangesFromAppEngineUpdate()
            }
            try audio.startRecording(inputDevicePreference: settings.inputDevice,
                                     recoveryJournal: recoveryJournal)
        } catch {
            recoveryJournal?.finish()
            PendingDictationRecovery.remove(recoveryJournal?.url)
            stopAudioEngineImmediately()
            log("recording start failed: \(error.localizedDescription)")
            signalDictationFailure()
            return
        }
        isRecording = true
        if setupChecklistWindow?.isVisible == true {
            hotkeyTestSucceeded = true
            updateSetupChecklist()
        }
        startRecordingLevelMeter(initialContext: initialInsertionContext)
        if settings.playFeedbackSounds {
            Sounds.playStart()
        }
        muteIfNeededForRecording()
        log("press: recording")

        scheduleMaxDurationAutoRelease()
        rebuildMenu()
    }

    private func handleRelease(shortcut: DictationReleaseShortcut = .standard,
                               hotkeyDetectedAt: TimeInterval? = nil) {
        guard isRecording, !isTerminating else { return }
        let releaseReceivedAt = ProcessInfo.processInfo.systemUptime
        let hotkeyDispatchSeconds = hotkeyDetectedAt.map { max(0, releaseReceivedAt - $0) }
        let settingsRefreshStartedAt = ProcessInfo.processInfo.systemUptime
        settings.refreshFromDisk()
        let settingsRefreshedAt = ProcessInfo.processInfo.systemUptime
        let shouldPressEnterAfterInsertion = shouldPressEnterAfterDictation(
            shortcut: shortcut,
            primaryBehavior: settings.primaryCompletionBehavior
        )
        let releasePermissionCheckStartedAt = ProcessInfo.processInfo.systemUptime
        let missing = missingPermissions()
        let releasePermissionCheckCompletedAt = ProcessInfo.processInfo.systemUptime
        guard missing.isEmpty else {
            recoverActiveRecordingToHistory(reason: "permission lost on release") { [weak self] in
                self?.enterPermissionBlockedState(missing: missing, reason: "hotkey release")
            }
            return
        }

        isRecording = false
        stopRecordingLevelMeter(hideHUD: false)
        cancelMaxDurationAutoRelease()
        unmuteIfWeMuted()

        let audioFinalizeStartedAt = ProcessInfo.processInfo.systemUptime
        let captured = audio.endRecording()
        let audioFinalizedAt = ProcessInfo.processInfo.systemUptime
        let samples = captured.samples
        let dur: Double
        switch recordingReleaseAction(capturedSampleCount: samples.count) {
        case .discardTooShort(let duration):
            dur = duration
            log("release: clip too short (\(String(format: "%.2f", dur)) s), discarding")
            PendingDictationRecovery.remove(captured.recoveryURL)
            hideRecordingHUD()
            setMenuBarState(.idle)
            rebuildMenu()
            if !runDeferredAudioRouteRefreshIfNeeded() {
                scheduleAudioIdleStop(reason: "short clip")
            }
            return
        case .transcribe(let duration):
            dur = duration
        }
        isBusy = true

        // Start CoreML before AppKit/menu work. The UI still transitions
        // immediately, but its disk/menu updates now overlap inference.
        let asrRequestedAt = ProcessInfo.processInfo.systemUptime
        let transcriptionWorker = asr
        let language = settings.dictationLanguage.fluidLanguage
        let transcriptionTask = Task.detached(priority: .userInitiated) {
            let transcription = try await transcriptionWorker.transcribe(
                samples: samples,
                language: language,
                requestedAt: asrRequestedAt
            )
            return CompletedTranscriptionWorkerResult(
                transcription: transcription,
                completedAt: ProcessInfo.processInfo.systemUptime
            )
        }

        let transcribingUIStartedAt = ProcessInfo.processInfo.systemUptime
        setMenuBarState(.busy)
        showTranscribingHUD()
        rebuildMenu()
        let transcribingUICompletedAt = ProcessInfo.processInfo.systemUptime
        log("release: \(String(format: "%.2f", dur)) s captured, transcribing")

        let taskEnqueuedAt = ProcessInfo.processInfo.systemUptime
        Task { @MainActor in
            let taskStartedAt = ProcessInfo.processInfo.systemUptime
            var dictationFailed = false
            do {
                let completed = try await transcriptionTask.value
                let transcription = completed.transcription
                let asrTiming = transcription.timing(
                    totalSeconds: completed.completedAt - asrRequestedAt
                )
                if !isTerminating {
                    let postprocessingStartedAt = ProcessInfo.processInfo.systemUptime
                    let processed = processedDictationText(rawTranscript: transcription.text,
                                                           corrections: settings.transcriptCorrections,
                                                           removeFillerWords: settings.removeFillerWords,
                                                           language: settings.dictationLanguage)
                    let postprocessingCompletedAt = ProcessInfo.processInfo.systemUptime
                    if processed.appliedCorrectionCount > 0 {
                        log("transcript corrections applied: \(processed.appliedCorrectionCount)")
                    }
                    if processed.removedFillerWordCount > 0 {
                        log("filler words removed: \(processed.removedFillerWordCount)")
                    }
                    let cleaned = processed.text
                    log("\(String(format: "%.2f", dur)) s audio → \(String(format: "%.2f", asrTiming.totalSeconds)) s → \(cleaned.count) chars")
                    if !cleaned.isEmpty {
                        let historyStartedAt = ProcessInfo.processInfo.systemUptime
                        addToHistory(
                            cleaned,
                            transcriptionDurationSeconds: asrTiming.totalSeconds,
                            asrTiming: asrTiming,
                            rebuildMenuAfterPersisting: false
                        )
                        recordDictationUsage(text: cleaned,
                                             audioSeconds: dur,
                                             asrSeconds: asrTiming.totalSeconds)
                        let historyCompletedAt = ProcessInfo.processInfo.systemUptime

                        let journalCleanupStartedAt = ProcessInfo.processInfo.systemUptime
                        PendingDictationRecovery.remove(captured.recoveryURL)
                        let journalCleanupCompletedAt = ProcessInfo.processInfo.systemUptime

                        let permissionRecheckStartedAt = ProcessInfo.processInfo.systemUptime
                        let missing = missingPermissions()
                        let permissionRecheckCompletedAt = ProcessInfo.processInfo.systemUptime
                        guard missing.isEmpty else {
                            isBusy = false
                            finishBusyHUD()
                            enterPermissionBlockedState(missing: missing, reason: "paste")
                            return
                        }

                        let insertionStartedAt = ProcessInfo.processInfo.systemUptime
                        let inserted = TextInserter.insert(
                            pastedText(from: cleaned, suffix: settings.pasteSuffix)
                        )
                        let insertionCompletedAt = ProcessInfo.processInfo.systemUptime
                        var enterDelaySeconds: Double?
                        if inserted {
                            if shouldPressEnterAfterInsertion {
                                let enterDelayStartedAt = ProcessInfo.processInfo.systemUptime
                                try? await Task.sleep(nanoseconds: ENTER_AFTER_INSERT_DELAY_NANOSECONDS)
                                if KeyboardShortcutPoster.postReturn() {
                                    log("return posted after dictation")
                                } else {
                                    log("return event creation failed")
                                }
                                enterDelaySeconds = ProcessInfo.processInfo.systemUptime - enterDelayStartedAt
                            }
                            if settings.playFeedbackSounds {
                                Sounds.playDone()
                            }
                        } else {
                            log("text insertion failed")
                            dictationFailed = true
                        }

                        log(DictationLatencyMetrics(
                            audioSeconds: dur,
                            hotkeyDispatchSeconds: hotkeyDispatchSeconds,
                            releasePreparationSeconds: audioFinalizeStartedAt - releaseReceivedAt,
                            settingsRefreshSeconds: settingsRefreshedAt - settingsRefreshStartedAt,
                            releasePermissionCheckSeconds: releasePermissionCheckCompletedAt - releasePermissionCheckStartedAt,
                            audioFinalizeSeconds: audioFinalizedAt - audioFinalizeStartedAt,
                            audioDetachSeconds: captured.detachSeconds,
                            journalFlushSeconds: captured.journalFlushSeconds,
                            audioFlattenSeconds: captured.flattenSeconds,
                            transcribingUISeconds: transcribingUICompletedAt - transcribingUIStartedAt,
                            taskQueueSeconds: taskStartedAt - taskEnqueuedAt,
                            releaseToASRSeconds: asrRequestedAt - releaseReceivedAt,
                            asrTiming: asrTiming,
                            postprocessingSeconds: postprocessingCompletedAt - postprocessingStartedAt,
                            historyPersistenceSeconds: historyCompletedAt - historyStartedAt,
                            journalCleanupSeconds: journalCleanupCompletedAt - journalCleanupStartedAt,
                            permissionRecheckSeconds: permissionRecheckCompletedAt - permissionRecheckStartedAt,
                            insertionDispatchSeconds: insertionCompletedAt - insertionStartedAt,
                            releaseToPasteDispatchSeconds: insertionCompletedAt - releaseReceivedAt,
                            enterDelaySeconds: enterDelaySeconds,
                            pasteSucceeded: inserted
                        ).logLine)
                    } else {
                        PendingDictationRecovery.remove(captured.recoveryURL)
                    }
                }
            } catch {
                log("transcribe failed: \(error)")
                dictationFailed = true
            }
            isBusy = false
            finishBusyHUD()
            if dictationFailed && !isTerminating {
                signalDictationFailure()
            } else {
                setMenuBarState(.idle)
            }
            rebuildMenu()
            let didRestartAudio = runDeferredAudioRouteRefreshIfNeeded()
            recoverRuntimeAfterWakeIfNeeded(reason: "transcription finished after wake")
            if !didRestartAudio {
                scheduleAudioIdleStop(reason: "recording finished")
            }
        }
    }

    private func recoverActiveRecordingToHistory(reason: String,
                                                 runDeferredRefresh: Bool = true,
                                                 completion: (() -> Void)? = nil) {
        guard isRecording || audio.isRunning else {
            hotkey.resetToggleState()
            completion?()
            return
        }

        cancelMaxDurationAutoRelease()
        let captured = audio.endRecording()
        let duration = Double(captured.samples.count) / SAMPLE_RATE
        isRecording = false
        stopRecordingLevelMeter(hideHUD: false)
        hotkey.resetToggleState()
        unmuteIfWeMuted()

        guard !captured.samples.isEmpty else {
            PendingDictationRecovery.remove(captured.recoveryURL)
            hideRecordingHUD()
            setMenuBarState(.idle)
            rebuildMenu()
            log("recording ended without audio (\(reason))")
            completion?()
            return
        }

        isBusy = true
        setMenuBarState(.busy)
        showTranscribingHUD()
        rebuildMenu()
        log("recording ended nonstandard (\(reason)); recovering \(String(format: "%.2f", duration)) s to history")

        Task { @MainActor in
            var recoveryFailed = false
            do {
                let requestedAt = ProcessInfo.processInfo.systemUptime
                let transcription = try await asr.transcribe(
                    samples: captured.samples,
                    language: settings.dictationLanguage.fluidLanguage,
                    requestedAt: requestedAt
                )
                let completedAt = ProcessInfo.processInfo.systemUptime
                let timing = transcription.timing(totalSeconds: completedAt - requestedAt)
                if !isTerminating {
                    let processed = processedDictationText(rawTranscript: transcription.text,
                                                           corrections: settings.transcriptCorrections,
                                                           removeFillerWords: settings.removeFillerWords,
                                                           language: settings.dictationLanguage)
                    if !processed.text.isEmpty {
                        addToHistory(
                            processed.text,
                            transcriptionDurationSeconds: timing.totalSeconds,
                            asrTiming: timing
                        )
                        recordDictationUsage(text: processed.text,
                                             audioSeconds: duration,
                                             asrSeconds: timing.totalSeconds)
                    }
                    PendingDictationRecovery.remove(captured.recoveryURL)
                    log("recovered dictation: \(String(format: "%.2f", duration)) s audio → \(String(format: "%.2f", timing.totalSeconds)) s → \(processed.text.count) chars in history")
                }
            } catch {
                recoveryFailed = true
                log("dictation recovery failed; audio retained for next launch: \(error.localizedDescription)")
            }

            guard !isTerminating else { return }
            isBusy = false
            finishBusyHUD()
            if recoveryFailed {
                signalDictationFailure()
            } else {
                setMenuBarState(.idle)
            }
            rebuildMenu()
            completion?()
            let didRestartAudio = runDeferredRefresh
                ? runDeferredAudioRouteRefreshIfNeeded()
                : false
            recoverRuntimeAfterWakeIfNeeded(reason: "dictation recovery finished after wake")
            if !didRestartAudio {
                scheduleAudioIdleStop(reason: reason)
            }
        }
    }

    private func cancelActiveRecording(reason: String, runDeferredRefresh: Bool = true) {
        guard isRecording || audio.isRunning else {
            hotkey.resetToggleState()
            return
        }

        recoverActiveRecordingToHistory(reason: reason,
                                        runDeferredRefresh: runDeferredRefresh)
    }

    // Termination cannot await transcription, so it only flushes the
    // recovery journal. The next launch transcribes it into history.
    private func cancelRecordingForTermination() {
        cancelMaxDurationAutoRelease()
        hotkey.onPress = nil
        hotkey.onRelease = nil
        hotkey.onReleaseAlternate = nil
        hotkey.onCancel = nil
        hotkey.onShowHistory = nil
        hotkey.isRecordingActive = nil
        hotkey.canStartRecording = nil
        hotkey.stop()

        let hadActiveRecording = isRecording || audio.isRunning
        let hadMute = systemAudioMutePhase != .idle
        if hadActiveRecording {
            let captured = audio.endRecording()
            if captured.recoveryURL != nil {
                log("terminate: active dictation preserved for next-launch recovery")
            }
        }
        stopRecordingLevelMeter()
        stopAudioEngineImmediately()
        isRecording = false
        isBusy = false
        hotkey.resetToggleState()
        unmuteIfWeMuted()

        if hadActiveRecording || hadMute {
            log("terminate: active recording finalized")
        }
    }

    // Trade-off: the mute is asynchronous relative to recording
    // start. Audio capture is armed immediately when the engine opens
    // on press, while the probe + mute land a few milliseconds later,
    // so a sliver of system audio can bleed into the start of the clip.
    // That beats the alternative — the old synchronous AppleScript
    // calls ran behind the session-wide event tap on the main run
    // loop, stalling every keystroke system-wide (and risking macOS
    // disabling the tap after a >1 s stall).
    private func muteIfNeededForRecording() {
        guard settings.muteWhileRecording else { return }
        guard systemAudioMutePhase == .idle else {
            // A previous recording's lifecycle is still settling
            // (rapid press cycles). Skipping the mute for this
            // recording is safe in the never-stuck sense, but the
            // cost is not always "a few ms": if the previous probe is
            // still in flight when this press lands, it stands down
            // to .idle and THIS recording runs unmuted for its whole
            // duration. Accepted: it needs a press/release/press
            // faster than one AppleScript round-trip, and the
            // alternative (queueing nested mute lifecycles) is far
            // more complex than the failure it prevents.
            log("output mute skipped: previous mute lifecycle still settling")
            return
        }
        systemAudioMutePhase = .probing
        systemAudioUnmuteRequested = false
        // Only mute if we wouldn't be stomping a user-set mute.
        SystemAudio.mutedStateAsync { [weak self] mutedState in
            self?.continueMuteAfterProbe(mutedState: mutedState)
        }
    }

    private func continueMuteAfterProbe(mutedState: Bool?) {
        guard systemAudioMutePhase == .probing else {
            log("output mute probe completion ignored: unexpected phase")
            return
        }
        switch systemAudioMuteProbeDecision(mutedState: mutedState,
                                            unmuteAlreadyRequested: systemAudioUnmuteRequested) {
        case .standDown:
            systemAudioMutePhase = .idle
            systemAudioUnmuteRequested = false
            return
        case .armRecoveryAndMute:
            break
        }

        // Crash-recovery invariant: the marker + watchdog must exist
        // BEFORE the mute command can execute, so a crash at any
        // point after the mute leaves a recovery path. Both are armed
        // here on the main actor; the mute is only enqueued after
        // they exist, and SystemAudio's serial queue preserves that
        // order.
        do {
            try writeSystemAudioMuteMarker()
            try startSystemAudioMuteWatchdog()
        } catch {
            removeSystemAudioMuteMarker()
            stopSystemAudioMuteWatchdog()
            systemAudioMutePhase = .idle
            systemAudioUnmuteRequested = false
            log("output mute skipped: recovery watchdog unavailable (\(error.localizedDescription))")
            return
        }
        systemAudioMutePhase = .muting
        SystemAudio.muteAsync { [weak self] outcome in
            self?.finishMuteCommand(outcome: outcome)
        }
    }

    private func finishMuteCommand(outcome: SystemAudioMuteCommandOutcome) {
        guard systemAudioMutePhase == .muting else {
            log("output mute completion ignored: unexpected phase")
            return
        }
        switch systemAudioMuteCommandDecision(outcome: outcome,
                                              unmuteAlreadyRequested: systemAudioUnmuteRequested) {
        case .disarmRecovery:
            removeSystemAudioMuteMarker()
            stopSystemAudioMuteWatchdog()
            systemAudioMutePhase = .idle
            systemAudioUnmuteRequested = false
            log("output mute failed")
        case .stayMuted:
            systemAudioMutePhase = .muted
            log(outcome == .assumedMuted
                ? "output muted (verification failed; assuming muted, recovery stays armed)"
                : "output muted")
        case .beginUnmute:
            // The recording ended while the mute command ran.
            systemAudioUnmuteRequested = false
            beginSystemAudioUnmute()
        }
    }

    private func unmuteIfWeMuted() {
        switch systemAudioUnmuteRequestDecision(phase: systemAudioMutePhase) {
        case .nothingToDo:
            return
        case .deferUntilCommandSettles:
            systemAudioUnmuteRequested = true
        case .beginUnmute:
            beginSystemAudioUnmute()
        }
    }

    private func beginSystemAudioUnmute() {
        systemAudioMutePhase = .unmuting
        SystemAudio.unmuteAsync { [weak self] unmuted in
            self?.finishUnmuteCommand(unmuted: unmuted)
        }
    }

    private func finishUnmuteCommand(unmuted: Bool) {
        guard systemAudioMutePhase == .unmuting else {
            log("output unmute completion ignored: unexpected phase")
            return
        }
        if unmuted {
            systemAudioMutePhase = .idle
            systemAudioUnmuteRequested = false
            removeSystemAudioMuteMarker()
            stopSystemAudioMuteWatchdog()
            log("output unmuted")
        } else {
            // Stay "muted": the marker + watchdog remain armed, the
            // next recording's release retries the unmute, and the
            // watchdog recovers if we exit first.
            systemAudioMutePhase = .muted
            log("output unmute failed; crash-recovery marker left in place")
        }
    }

    private func startSystemAudioMuteWatchdog() throws {
        stopSystemAudioMuteWatchdog()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = [
            "-c",
            systemAudioMuteWatchdogScript(),
            "parakey-audio-watchdog",
            "\(getpid())",
            systemAudioMuteMarkerURL().path,
        ]
        proc.environment = systemToolProcessEnvironment()
        try proc.run()
        systemAudioMuteWatchdog = proc
    }

    private func stopSystemAudioMuteWatchdog() {
        guard let proc = systemAudioMuteWatchdog else { return }
        if proc.isRunning {
            proc.terminate()
        }
        systemAudioMuteWatchdog = nil
    }

    // Uses the synchronous SystemAudio calls deliberately: this runs
    // once from applicationDidFinishLaunching, before the event tap
    // exists, so a main-thread AppleScript round-trip cannot stall
    // keystrokes here.
    private func recoverStaleSystemAudioMuteIfNeeded() {
        let marker = systemAudioMuteMarkerURL()
        guard FileManager.default.fileExists(atPath: marker.path) else { return }

        if let text = try? String(contentsOf: marker, encoding: .utf8),
           let pid = systemAudioMuteMarkerProcessID(from: text),
           pid != getpid(),
           Darwin.kill(pid, 0) == 0 {
            log("output mute recovery deferred: marker belongs to active process \(pid)")
            return
        }

        if SystemAudio.isMuted() {
            if SystemAudio.unmute() {
                log("output unmuted after interrupted recording")
            } else {
                log("output unmute after interrupted recording failed")
            }
        } else {
            log("stale output mute marker removed")
        }
        removeSystemAudioMuteMarker(at: marker)
    }

    private func scheduleMaxDurationAutoRelease() {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRecording else { return }
            log("max recording duration reached, releasing")
            self.hotkey.resetToggleState()
            self.handleRelease()
        }
        maxDurationWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + MAX_RECORDING_SECONDS, execute: work)
    }

    private func cancelMaxDurationAutoRelease() {
        maxDurationWorkItem?.cancel()
        maxDurationWorkItem = nil
    }

    // MARK: - History

    private func importDictationUsageFromLogIfNeeded() {
        guard !settings.didImportDictationUsageLog else { return }
        defer { settings.didImportDictationUsageLog = true }
        guard settings.dailyDictationUsage.isEmpty else { return }

        let url = Logger.shared.fileURL
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              !text.isEmpty else {
            return
        }
        let createdAt = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        let imported = importedDailyDictationUsage(from: text,
                                                   fileCreatedAt: createdAt,
                                                   calendar: .current)
        guard !imported.isEmpty else { return }
        settings.dailyDictationUsage = imported
        let total = imported.reduce(0) { $0 + $1.dictationCount }
        log("usage statistics imported from local log (\(total) dictations across \(imported.count) days)")
    }

    private func recordDictationUsage(text: String,
                                      audioSeconds: Double,
                                      asrSeconds: Double,
                                      at date: Date = Date()) {
        settings.dailyDictationUsage = addingDictationUsageSample(
            to: settings.dailyDictationUsage,
            at: date,
            characterCount: text.count,
            audioSeconds: audioSeconds,
            asrSeconds: asrSeconds,
            calendar: .current
        )
    }

    private func addToHistory(_ text: String,
                              transcriptionDurationSeconds: Double?,
                              asrTiming: ASRTimingBreakdown? = nil,
                              rebuildMenuAfterPersisting: Bool = true) {
        guard settings.recentTranscriptLimit != .off else { return }
        let entry = TranscriptHistoryEntry(
            text: text,
            transcriptionDurationSeconds: transcriptionDurationSeconds,
            asrTiming: asrTiming
        )
        let next = limitedTranscriptHistoryArchive([entry] + history)
        guard next != history else { return }
        history = next
        settings.recentTranscriptEntries = history
        if rebuildMenuAfterPersisting {
            rebuildMenu()
        }
    }

    private func applyRecentTranscriptLimit() {
        guard settings.recentTranscriptLimit == .off, !history.isEmpty else { return }
        let removed = history.count
        history.removeAll()
        settings.recentTranscriptEntries = []
        log("recent transcript history disabled and cleared (\(removed) entries)")
    }

    /// 60-char preview with ellipsis. Newlines collapsed so a multi-
    /// line transcript still renders as one menu row.
    private func previewLine(for text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 60 ? String(flat.prefix(60)) + "…" : flat
    }

    @objc private func historyClicked(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String else { return }
        copyHistoryText(s)
    }

    private func copyHistoryText(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        log("history copied to clipboard (\(text.count) chars)")
    }

    @objc private func clearHistoryClicked(_ sender: NSMenuItem) {
        guard !history.isEmpty else { return }
        let count = history.count
        history.removeAll()
        settings.recentTranscriptEntries = []
        log("history cleared (\(count) entries)")
        rebuildMenu()
    }

    private func toggleHistoryOverlay() {
        if statisticsOverlayPresented {
            closeStatisticsOverlay()
            log("statistics overlay closed from hotkey")
            return
        }
        if historyOverlayPresented {
            closeHistoryOverlay()
            log("history overlay closed from hotkey")
            return
        }
        showHistoryOverlay()
    }

    private func showHistoryOverlay() {
        guard !historyOverlayPresented else {
            let panel = historyOverlayWindow ?? makeHistoryOverlayWindow()
            historyOverlayWindow = panel
            panel.contentView = makeHistoryOverlayContent()
            panel.setFrame(historyOverlayFrame(), display: true)
            panel.alphaValue = 1
            panel.makeKeyAndOrderFront(nil)
            return
        }

        let panel = historyOverlayWindow ?? makeHistoryOverlayWindow()
        historyOverlayWindow = panel
        panel.contentView = makeHistoryOverlayContent()
        let finalFrame = historyOverlayFrame()
        historyOverlayAnimationToken += 1
        historyOverlayPresented = true
        panel.alphaValue = 1
        panel.setFrame(finalFrame, display: false)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        startHistoryOverlayDismissMonitoring()
        log("history overlay shown (\(visibleHistory.count) visible, \(history.count) archived)")
    }

    private func makeHistoryOverlayWindow() -> HistoryOverlayPanel {
        let panel = HistoryOverlayPanel(contentRect: historyOverlayFrame(),
                                        styleMask: [.borderless, .fullSizeContentView],
                                        backing: .buffered,
                                        defer: false)
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.closeHistoryOverlay() }
        return panel
    }

    private func historyOverlayFrame() -> NSRect {
        let screen = screenForRecordingHUD()
        let visible = screen.visibleFrame
        let width: CGFloat = min(620, visible.width - 48)
        let displayedHistory = visibleHistory
        let rowHeight: CGFloat = displayedHistory.isEmpty ? 58 : CGFloat(min(displayedHistory.count, 7)) * 64
        let height: CGFloat = min(500, 42 + rowHeight)
        let y = visible.midY - (height / 2)
        return NSRect(x: visible.midX - (width / 2),
                      y: y,
                      width: width,
                      height: height)
    }

    private func makeHistoryOverlayContent() -> NSView {
        historyOverlayRows.removeAll(keepingCapacity: true)
        let frame = NSRect(origin: .zero, size: historyOverlayFrame().size)
        let root = NSVisualEffectView(frame: frame)
        root.material = .underWindowBackground
        root.blendingMode = .behindWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 22
        root.layer?.cornerCurve = .continuous
        root.layer?.masksToBounds = true
        root.layer?.borderWidth = 1
        root.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.16).cgColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -12),
        ])

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.alignment = .centerY
        actions.addArrangedSubview(HistoryToolbarButton(
            symbolName: "chart.xyaxis.line",
            accessibilityDescription: "Статистика",
            toolTip: "Статистика",
            target: self,
            action: #selector(showStatisticsFromHistoryOverlayClicked(_:))
        ))
        actions.addArrangedSubview(NSView())
        actions.addArrangedSubview(HistoryToolbarButton(
            symbolName: "gearshape",
            accessibilityDescription: "Настройки",
            toolTip: "Настройки",
            target: self,
            action: #selector(showSetupFromHistoryOverlayClicked(_:))
        ))
        stack.addArrangedSubview(actions)
        actions.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let displayedHistory = visibleHistory
        if displayedHistory.isEmpty {
            let empty = HistoryItemLabel("No dictations yet")
            empty.font = .systemFont(ofSize: 13)
            empty.textColor = .secondaryLabelColor
            empty.alignment = .center
            stack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        } else {
            for (index, entry) in displayedHistory.prefix(7).enumerated() {
                let row = historyOverlayRow(index: index, entry: entry)
                historyOverlayRows.append(row)
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }

        return root
    }

    private func historyOverlayRow(index: Int, entry: TranscriptHistoryEntry) -> HistoryTranscriptItemView {
        HistoryTranscriptItemView(transcript: entry.text,
                                  preview: previewLine(for: entry.text),
                                  transcriptionDurationSeconds: entry.transcriptionDurationSeconds,
                                  asrTiming: entry.asrTiming,
                                  historyIndex: index,
                                  target: self,
                                  action: #selector(historyOverlayItemClicked(_:)),
                                  onDelete: { [weak self] historyIndex in
                                      self?.deleteHistoryOverlayItem(at: historyIndex)
                                  })
    }

    @objc private func historyOverlayItemClicked(_ sender: HistoryTranscriptItemView) {
        copyHistoryText(sender.transcript)
        closeHistoryOverlay()
    }

    private func deleteHistoryOverlayItem(at historyIndex: Int) {
        let next = transcriptHistoryArchive(history, removing: historyIndex)
        guard next != history else { return }
        history = next
        settings.recentTranscriptEntries = history
        log("history entry deleted from overlay (\(visibleHistory.count) visible, \(history.count) archived)")
        rebuildMenu()
        showHistoryOverlay()
    }

    @objc private func copyLastHistoryOverlayClicked(_ sender: NSButton) {
        guard let newest = visibleHistory.first else { return }
        copyHistoryText(newest.text)
    }

    @objc private func clearHistoryOverlayClicked(_ sender: NSButton) {
        guard !history.isEmpty else { return }
        let count = history.count
        history.removeAll()
        settings.recentTranscriptEntries = []
        log("history cleared from overlay (\(count) entries)")
        rebuildMenu()
        showHistoryOverlay()
    }

    @objc private func closeHistoryOverlayClicked(_ sender: NSButton) {
        closeHistoryOverlay()
    }

    private func closeHistoryOverlay() {
        guard let panel = historyOverlayWindow, historyOverlayPresented || panel.isVisible else { return }
        historyOverlayAnimationToken += 1
        historyOverlayPresented = false
        stopHistoryOverlayDismissMonitoring()
        let token = historyOverlayAnimationToken
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.08
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self, weak panel] in
            Task { @MainActor in
                guard let self, let panel,
                      self.historyOverlayAnimationToken == token else { return }
                panel.orderOut(nil)
                panel.alphaValue = 1
            }
        }
    }

    private func startHistoryOverlayDismissMonitoring() {
        stopHistoryOverlayDismissMonitoring()

        historyOverlayGlobalDismissMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.closeHistoryOverlay()
            }
        }

        historyOverlayLocalDismissMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            let shouldConsume = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                guard let panel = self.historyOverlayWindow else { return false }
                let screenPoint = NSEvent.mouseLocation
                guard panel.frame.contains(screenPoint) else {
                    self.closeHistoryOverlay()
                    return false
                }

                let windowPoint = panel.convertPoint(fromScreen: screenPoint)
                let rows = self.historyOverlayRows
                for row in rows {
                    guard let hitAction = row.hitAction(atWindowPoint: windowPoint) else { continue }
                    switch hitAction {
                    case .copy(let transcript):
                        self.copyHistoryText(transcript)
                        DispatchQueue.main.async { [weak self] in
                            self?.closeHistoryOverlay()
                        }
                    case .delete(let historyIndex):
                        DispatchQueue.main.async { [weak self] in
                            self?.deleteHistoryOverlayItem(at: historyIndex)
                        }
                    }
                    return true
                }
                return false
            }
            return shouldConsume ? nil : event
        }
    }

    private func stopHistoryOverlayDismissMonitoring() {
        if let monitor = historyOverlayGlobalDismissMonitor {
            NSEvent.removeMonitor(monitor)
            historyOverlayGlobalDismissMonitor = nil
        }
        if let monitor = historyOverlayLocalDismissMonitor {
            NSEvent.removeMonitor(monitor)
            historyOverlayLocalDismissMonitor = nil
        }
    }

    @objc private func showStatisticsFromHistoryOverlayClicked(_ sender: Any) {
        closeHistoryOverlay()
        showStatisticsOverlay()
    }

    private func showStatisticsOverlay() {
        let panel = statisticsOverlayWindow ?? makeStatisticsOverlayWindow()
        statisticsOverlayWindow = panel
        panel.contentView = makeStatisticsOverlayContent()
        let finalFrame = statisticsOverlayFrame()
        statisticsOverlayAnimationToken += 1
        statisticsOverlayPresented = true
        panel.alphaValue = 0
        panel.setFrame(finalFrame.offsetBy(dx: 0, dy: -7), display: false)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        startStatisticsOverlayDismissMonitoring()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(finalFrame, display: true)
        }
        log("statistics overlay shown")
    }

    private func makeStatisticsOverlayWindow() -> HistoryOverlayPanel {
        let panel = HistoryOverlayPanel(contentRect: statisticsOverlayFrame(),
                                        styleMask: [.borderless, .fullSizeContentView],
                                        backing: .buffered,
                                        defer: false)
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.closeStatisticsOverlay() }
        return panel
    }

    private func statisticsOverlayFrame() -> NSRect {
        let screen = screenForRecordingHUD()
        let visible = screen.visibleFrame
        let width = min(CGFloat(1_140), visible.width - 40)
        let height = min(CGFloat(750), visible.height - 40)
        return NSRect(x: visible.midX - (width / 2),
                      y: visible.midY - (height / 2),
                      width: width,
                      height: height)
    }

    private func makeStatisticsOverlayContent() -> NSView {
        let calendar = Calendar.current
        let snapshot = lastSevenCompletedDictationUsage(
            settings.dailyDictationUsage,
            referenceDate: Date(),
            calendar: calendar
        )
        let frame = NSRect(origin: .zero, size: statisticsOverlayFrame().size)
        let root = NSVisualEffectView(frame: frame)
        root.material = .underWindowBackground
        root.blendingMode = .behindWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 26
        root.layer?.cornerCurve = .continuous
        root.layer?.masksToBounds = true
        root.layer?.borderWidth = 1
        root.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.16).cgColor

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)

        let backButton = HistoryToolbarButton(
            symbolName: "clock.arrow.circlepath",
            accessibilityDescription: "История",
            toolTip: "Вернуться к истории",
            target: self,
            action: #selector(showHistoryFromStatisticsOverlayClicked(_:))
        )
        backButton.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(backButton)

        let title = HistoryItemLabel("Статистика")
        title.font = .systemFont(ofSize: 28, weight: .bold)
        title.textColor = .labelColor
        title.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(title)

        let subtitle = HistoryItemLabel("\(russianUsageDateRange(snapshot, calendar: calendar)) · сегодня не учитывается")
        subtitle.font = .systemFont(ofSize: 14, weight: .regular)
        subtitle.textColor = .secondaryLabelColor
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(subtitle)

        let metrics = NSStackView()
        metrics.orientation = .horizontal
        metrics.alignment = .top
        metrics.distribution = .fillEqually
        metrics.spacing = 14
        metrics.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(metrics)

        let metricCards = [
            UsageMetricCard(symbolName: "textformat",
                            tint: .systemPink,
                            title: "СИМВОЛЫ",
                            value: formattedUsageInteger(snapshot.totalCharacters),
                            detail: "в готовом тексте"),
            UsageMetricCard(symbolName: "waveform",
                            tint: .systemBlue,
                            title: "ДИКТОВКИ",
                            value: formattedUsageInteger(snapshot.totalDictations),
                            detail: "завершённые записи"),
            UsageMetricCard(symbolName: "mic.fill",
                            tint: .systemOrange,
                            title: "ВРЕМЯ РЕЧИ",
                            value: formattedUsageDuration(snapshot.totalAudioSeconds),
                            detail: "суммарно"),
            UsageMetricCard(symbolName: "bolt.fill",
                            tint: .systemGreen,
                            title: "ТРАНСКРИПЦИЯ",
                            value: formattedUsageSeconds(snapshot.averageASRSeconds),
                            detail: "в среднем"),
        ]
        metricCards.forEach(metrics.addArrangedSubview)

        let charts = NSStackView()
        charts.orientation = .horizontal
        charts.alignment = .top
        charts.distribution = .fill
        charts.spacing = 14
        charts.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(charts)

        let chartContainer = NSView()
        chartContainer.wantsLayer = true
        chartContainer.layer?.cornerRadius = 16
        chartContainer.layer?.cornerCurve = .continuous
        chartContainer.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.25).cgColor
        chartContainer.layer?.borderWidth = 1
        chartContainer.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.12).cgColor
        chartContainer.translatesAutoresizingMaskIntoConstraints = false
        charts.addArrangedSubview(chartContainer)

        let chartTitle = HistoryItemLabel("Написанный текст")
        chartTitle.font = .systemFont(ofSize: 17, weight: .semibold)
        chartTitle.textColor = .labelColor
        chartTitle.translatesAutoresizingMaskIntoConstraints = false
        chartContainer.addSubview(chartTitle)

        let chartUnit = HistoryItemLabel("символы")
        chartUnit.font = .systemFont(ofSize: 13, weight: .medium)
        chartUnit.textColor = .tertiaryLabelColor
        chartUnit.alignment = .right
        chartUnit.translatesAutoresizingMaskIntoConstraints = false
        chartContainer.addSubview(chartUnit)

        let chart = DictationUsageChartView(snapshot: snapshot, calendar: calendar)
        chart.translatesAutoresizingMaskIntoConstraints = false
        chartContainer.addSubview(chart)

        let speechChartContainer = NSView()
        speechChartContainer.wantsLayer = true
        speechChartContainer.layer?.cornerRadius = 16
        speechChartContainer.layer?.cornerCurve = .continuous
        speechChartContainer.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.25).cgColor
        speechChartContainer.layer?.borderWidth = 1
        speechChartContainer.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.12).cgColor
        speechChartContainer.translatesAutoresizingMaskIntoConstraints = false
        charts.addArrangedSubview(speechChartContainer)

        let speechChartTitle = HistoryItemLabel("Время речи")
        speechChartTitle.font = .systemFont(ofSize: 17, weight: .semibold)
        speechChartTitle.textColor = .labelColor
        speechChartTitle.translatesAutoresizingMaskIntoConstraints = false
        speechChartContainer.addSubview(speechChartTitle)

        let speechChartUnit = HistoryItemLabel("минуты")
        speechChartUnit.font = .systemFont(ofSize: 13, weight: .medium)
        speechChartUnit.textColor = .tertiaryLabelColor
        speechChartUnit.alignment = .right
        speechChartUnit.translatesAutoresizingMaskIntoConstraints = false
        speechChartContainer.addSubview(speechChartUnit)

        let speechChart = DictationSpeechTimeChartView(snapshot: snapshot, calendar: calendar)
        speechChart.translatesAutoresizingMaskIntoConstraints = false
        speechChartContainer.addSubview(speechChart)

        let footerIcon = NSImageView()
        footerIcon.image = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent",
                                   accessibilityDescription: "Эффективность")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))
        footerIcon.image?.isTemplate = true
        footerIcon.contentTintColor = .systemGreen
        footerIcon.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(footerIcon)

        let footerText: String
        if snapshot.totalDictations > 0 {
            footerText = "В среднем \(formattedUsageInteger(Int(snapshot.averageCharactersPerDictation.rounded()))) символов за диктовку · обработка в \(String(format: "%.1f", snapshot.realtimeSpeedRatio).replacingOccurrences(of: ".", with: ","))× быстрее длительности речи"
        } else {
            footerText = "Статистика начнёт заполняться после завершённых диктовок"
        }
        let footer = HistoryItemLabel(footerText)
        footer.font = .systemFont(ofSize: 14, weight: .medium)
        footer.textColor = .secondaryLabelColor
        footer.lineBreakMode = .byTruncatingTail
        footer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(footer)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            header.heightAnchor.constraint(equalToConstant: 60),
            backButton.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            backButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            title.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 14),
            title.topAnchor.constraint(equalTo: header.topAnchor),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor),

            metrics.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            metrics.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            metrics.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 18),
            metrics.heightAnchor.constraint(equalToConstant: 136),

            charts.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            charts.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            charts.topAnchor.constraint(equalTo: metrics.bottomAnchor, constant: 18),
            charts.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -17),
            chartContainer.heightAnchor.constraint(equalTo: charts.heightAnchor),
            speechChartContainer.heightAnchor.constraint(equalTo: charts.heightAnchor),
            chartContainer.widthAnchor.constraint(equalTo: speechChartContainer.widthAnchor, multiplier: 1.48),

            chartTitle.leadingAnchor.constraint(equalTo: chartContainer.leadingAnchor, constant: 20),
            chartTitle.topAnchor.constraint(equalTo: chartContainer.topAnchor, constant: 18),
            chartUnit.trailingAnchor.constraint(equalTo: chartContainer.trailingAnchor, constant: -20),
            chartUnit.centerYAnchor.constraint(equalTo: chartTitle.centerYAnchor),
            chart.leadingAnchor.constraint(equalTo: chartContainer.leadingAnchor),
            chart.trailingAnchor.constraint(equalTo: chartContainer.trailingAnchor),
            chart.topAnchor.constraint(equalTo: chartTitle.bottomAnchor, constant: 8),
            chart.bottomAnchor.constraint(equalTo: chartContainer.bottomAnchor, constant: -8),

            speechChartTitle.leadingAnchor.constraint(equalTo: speechChartContainer.leadingAnchor, constant: 20),
            speechChartTitle.topAnchor.constraint(equalTo: speechChartContainer.topAnchor, constant: 18),
            speechChartUnit.trailingAnchor.constraint(equalTo: speechChartContainer.trailingAnchor, constant: -20),
            speechChartUnit.centerYAnchor.constraint(equalTo: speechChartTitle.centerYAnchor),
            speechChart.leadingAnchor.constraint(equalTo: speechChartContainer.leadingAnchor),
            speechChart.trailingAnchor.constraint(equalTo: speechChartContainer.trailingAnchor),
            speechChart.topAnchor.constraint(equalTo: speechChartTitle.bottomAnchor, constant: 8),
            speechChart.bottomAnchor.constraint(equalTo: speechChartContainer.bottomAnchor, constant: -8),

            footerIcon.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            footerIcon.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -25),
            footerIcon.widthAnchor.constraint(equalToConstant: 18),
            footerIcon.heightAnchor.constraint(equalToConstant: 18),
            footer.leadingAnchor.constraint(equalTo: footerIcon.trailingAnchor, constant: 10),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -26),
            footer.centerYAnchor.constraint(equalTo: footerIcon.centerYAnchor),
        ])
        return root
    }

    @objc private func showHistoryFromStatisticsOverlayClicked(_ sender: Any) {
        closeStatisticsOverlay()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            self?.showHistoryOverlay()
        }
    }

    private func closeStatisticsOverlay() {
        guard let panel = statisticsOverlayWindow,
              statisticsOverlayPresented || panel.isVisible else { return }
        statisticsOverlayAnimationToken += 1
        statisticsOverlayPresented = false
        stopStatisticsOverlayDismissMonitoring()
        let token = statisticsOverlayAnimationToken
        let finalFrame = statisticsOverlayFrame().offsetBy(dx: 0, dy: -5)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.10
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(finalFrame, display: true)
        } completionHandler: { [weak self, weak panel] in
            Task { @MainActor in
                guard let self, let panel,
                      self.statisticsOverlayAnimationToken == token else { return }
                panel.orderOut(nil)
                panel.alphaValue = 1
            }
        }
    }

    private func startStatisticsOverlayDismissMonitoring() {
        stopStatisticsOverlayDismissMonitoring()
        statisticsOverlayGlobalDismissMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.closeStatisticsOverlay() }
        }
        statisticsOverlayLocalDismissMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            let eventWindowNumber = event.windowNumber
            Task { @MainActor in
                guard let self,
                      self.statisticsOverlayWindow?.windowNumber != eventWindowNumber else { return }
                self.closeStatisticsOverlay()
            }
            return event
        }
    }

    private func stopStatisticsOverlayDismissMonitoring() {
        if let monitor = statisticsOverlayGlobalDismissMonitor {
            NSEvent.removeMonitor(monitor)
            statisticsOverlayGlobalDismissMonitor = nil
        }
        if let monitor = statisticsOverlayLocalDismissMonitor {
            NSEvent.removeMonitor(monitor)
            statisticsOverlayLocalDismissMonitor = nil
        }
    }

    @objc private func showSetupFromHistoryOverlayClicked(_ sender: Any) {
        closeHistoryOverlay()
        openControlPanelFromAgent()
    }

    @objc private func quitClicked(_ sender: NSMenuItem) {
        guard confirmStopDictation() else { return }
        NSApp.terminate(self)
    }

    private func confirmStopDictation() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Stop SuperDictate?"
        alert.informativeText = "The \(hotkey.hotkey.name) dictation shortcut will stop until you open SuperDictate again. Use Close to hide windows while keeping dictation running."
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Stop Dictation")
        return alert.runModal() == .alertSecondButtonReturn
    }

    @objc private func cancelRecordingClicked(_ sender: NSMenuItem) {
        cancelActiveRecording(reason: "menu")
    }

    @objc private func copyDiagnosticsClicked(_ sender: NSMenuItem) {
        copyDiagnosticsToClipboard()
    }

    private func copyDiagnosticsToClipboard() {
        let text = diagnosticsText()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        log("diagnostics copied to clipboard")
    }

    private func openDiagnosticLog() {
        NSWorkspace.shared.open(Logger.shared.fileURL)
        log("diagnostics log opened")
    }

    private func showPreviousExitNoticeIfAppropriate() {
        guard !isTerminating else { return }
        showAppForModal()
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "SuperDictate Reopened After an Unexpected Exit"
        alert.informativeText = """
            Parakey appears to have exited last time without a normal shutdown. Nothing was sent anywhere.

            You can copy a privacy-safe diagnostics report or open the local log if you want to file an issue.
            """
        alert.addButton(withTitle: "Copy Diagnostics")
        alert.addButton(withTitle: "Open Log")
        alert.addButton(withTitle: "Not Now")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            copyDiagnosticsToClipboard()
        } else if response == .alertSecondButtonReturn {
            openDiagnosticLog()
        }
    }

    @objc private func saveDiagnosticsClicked(_ sender: NSMenuItem) {
        showAppForModal()
        let panel = NSSavePanel()
        panel.title = "Save Diagnostics"
        panel.message = "Save a privacy-safe diagnostics report for a GitHub issue."
        panel.prompt = "Save"
        panel.nameFieldStringValue = "Parakey Diagnostics.txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try diagnosticsText().write(to: url, atomically: true, encoding: .utf8)
            log("diagnostics saved to \(privacySafeLogPath(url))")
        } catch {
            showDiagnosticsSaveError(error)
        }
    }

    private func showDiagnosticsSaveError(_ error: Error) {
        log("diagnostics save failed: \(error.localizedDescription)")
        showAppForModal()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Diagnostics couldn't be saved"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Menu

    private func rebuildMenu() {
        publishAgentState()
        statusItem.menu = buildMenu()
    }

    private func publishAgentState(status explicitStatus: String? = nil,
                                   detail explicitDetail: String? = nil) {
        let statusDetail = agentStateStatusDetail()
        let missing = missingPermissions().map(\.rawValue)
        AgentRuntimeStateStore.write(
            AgentRuntimeState(status: explicitStatus ?? statusDetail.status,
                              detail: explicitDetail ?? statusDetail.detail,
                              updatedAt: Date().timeIntervalSince1970,
                              pid: getpid(),
                              isReady: isReady,
                              isRecording: isRecording,
                              isTranscribing: isBusy,
                              speechModelReady: isSpeechModelReady,
                              missingPermissions: missing,
                              hotkeyName: hotkey.hotkey.name,
                              triggerMode: settings.triggerMode.rawValue)
        )
    }

    private func agentStateStatusDetail() -> (status: String, detail: String) {
        if isRecording {
            return ("recording", "Recording dictation.")
        }
        if isBusy {
            return ("transcribing", "Transcribing your last recording.")
        }
        if isReady {
            let verb = settings.triggerMode == .hold ? "Hold" : "Press"
            return ("ready", "\(verb) \(hotkey.hotkey.name) to dictate.")
        }
        if let failure = startupFailure {
            return ("error", failure.detail)
        }
        let missing = missingPermissions()
        if !missing.isEmpty {
            return ("needs_permissions", "Grant \(missing.map(\.rawValue).joined(separator: ", ")) to finish setup.")
        }
        if startupTask != nil || isRestartingAudioInput || isSwitchingSpeechModel {
            return ("starting", startupStatusTitle)
        }
        if isCoreRuntimeReady {
            return ("starting", "Starting hotkey listener.")
        }
        return ("starting", "Starting dictation service.")
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // Status row.
        let statusTitle = menuStatusTitle()
        let status = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        status.isEnabled = false
        if let failure = startupFailure {
            status.toolTip = failure.detail
        }
        menu.addItem(status)
        if shouldShowSpeechModelProgressRow {
            menu.addItem(buildSpeechModelProgressItem())
        }

        menu.addItem(.separator())

        if isRecording {
            let cancel = NSMenuItem(title: "Cancel Recording",
                                    action: #selector(cancelRecordingClicked(_:)),
                                    keyEquivalent: "")
            cancel.target = self
            menu.addItem(cancel)
            menu.addItem(.separator())
        }

        if let failure = startupFailure {
            let retry = NSMenuItem(title: failure.retryTitle,
                                   action: #selector(retryStartupClicked(_:)),
                                   keyEquivalent: "")
            retry.target = self
            retry.toolTip = failure.detail
            retry.isEnabled = startupTask == nil
            menu.addItem(retry)
            menu.addItem(.separator())
        }

        // Update submenu (lazy — only present when an update exists).
        if let release = pendingUpdate, !settings.skippedVersions.contains(release.version) {
            menu.addItem(buildUpdateItem(for: release))
            menu.addItem(.separator())
        }

        // Permission rows — visible only while something is missing.
        var addedPermRow = false
        for p in Permission.allCases where !Permissions.isGranted(p) {
            menu.addItem(buildPermissionItem(p))
            addedPermRow = true
        }
        if addedPermRow { menu.addItem(.separator()) }

        // History: keep one-click access to the last transcript, but
        // hide transcript preview text inside the submenu so the menu
        // stays stable even after long dictations.
        if let newest = visibleHistory.first {
            let inline = NSMenuItem(title: "Copy Last Transcript",
                                    action: #selector(historyClicked(_:)),
                                    keyEquivalent: "")
            inline.target = self
            inline.representedObject = newest.text
            inline.toolTip = newest.text
            menu.addItem(inline)

            menu.addItem(buildRecentTranscriptsItem())

            menu.addItem(.separator())
        }

        // Settings submenu.
        menu.addItem(buildSettingsItem())
        menu.addItem(buildSupportItem())
        menu.addItem(.separator())

        // Route through our own selector rather than `NSApp.terminate(_:)`
        // directly. macOS auto-decorates items whose action is the
        // system terminate: selector with a destructive-action glyph
        // (visible in the state-column slot), which is the *only* item
        // in the menu that gets such an indicator — every other row
        // sits flush against the left edge. The wrapper produces the
        // identical behaviour with no auto-glyph.
        let quit = NSMenuItem(title: "Quit SuperDictate",
                              action: #selector(quitClicked(_:)),
                              keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    private func buildRecentTranscriptsItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Recent Transcripts", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false

        for entry in visibleHistory {
            let item = NSMenuItem(title: previewLine(for: entry.text),
                                  action: #selector(historyClicked(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = entry.text
            item.toolTip = entry.text
            sub.addItem(item)
        }

        sub.addItem(.separator())

        let clear = NSMenuItem(title: "Clear Recent Transcripts",
                               action: #selector(clearHistoryClicked(_:)),
                               keyEquivalent: "")
        clear.target = self
        sub.addItem(clear)

        parent.submenu = sub
        return parent
    }

    private func buildSupportItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Support", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false

        let setup = NSMenuItem(title: "Setup Checklist…",
                               action: #selector(showSetupChecklistClicked(_:)),
                               keyEquivalent: "")
        setup.target = self
        sub.addItem(setup)

        sub.addItem(.separator())

        let checkUpdates = NSMenuItem(title: isCheckingForUpdates ? "Checking for Updates…" : "Check for Updates…",
                                      action: #selector(checkForUpdatesClicked(_:)),
                                      keyEquivalent: "")
        checkUpdates.target = self
        checkUpdates.isEnabled = !isCheckingForUpdates && !isTerminating
        sub.addItem(checkUpdates)

        sub.addItem(.separator())

        let about = NSMenuItem(title: "About SuperDictate",
                               action: #selector(showAboutClicked(_:)),
                               keyEquivalent: "")
        about.target = self
        sub.addItem(about)

        sub.addItem(.separator())

        let diagnostics = NSMenuItem(title: "Copy Diagnostics",
                                     action: #selector(copyDiagnosticsClicked(_:)),
                                     keyEquivalent: "")
        diagnostics.target = self
        sub.addItem(diagnostics)

        let saveDiagnostics = NSMenuItem(title: "Save Diagnostics…",
                                         action: #selector(saveDiagnosticsClicked(_:)),
                                         keyEquivalent: "")
        saveDiagnostics.target = self
        sub.addItem(saveDiagnostics)

        let resetModel = NSMenuItem(title: isResettingSpeechModelCache ? "Resetting Speech Model Cache…" : "Reset Speech Model Cache…",
                                    action: #selector(resetSpeechModelCacheClicked(_:)),
                                    keyEquivalent: "")
        resetModel.target = self
        resetModel.isEnabled = !isRecording
            && !isBusy
            && !isTerminating
            && startupTask == nil
            && !isResettingSpeechModelCache
            && !isSwitchingSpeechModel
        resetModel.toolTip = "Delete the speech model cache and download a fresh verified copy."
        sub.addItem(resetModel)

        parent.submenu = sub
        return parent
    }

    private var shouldShowSpeechModelProgressRow: Bool {
        startupFailure == nil
            && ((startupTask != nil && !isSpeechModelReady)
                || isSwitchingSpeechModel
                || isResettingSpeechModelCache)
    }

    private func buildSpeechModelProgressItem() -> NSMenuItem {
        let item = NSMenuItem()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        let progress = NSProgressIndicator(frame: NSRect(x: 14, y: 7, width: 232, height: 10))
        progress.style = .bar
        progress.controlSize = .small
        progress.minValue = 0
        progress.maxValue = 1
        progress.usesThreadedAnimation = true
        progress.toolTip = startupStatusTitle

        if let speechModelStartupProgressFraction {
            progress.isIndeterminate = false
            progress.doubleValue = speechModelStartupProgressFraction
        } else {
            progress.isIndeterminate = true
            progress.startAnimation(nil)
        }

        view.addSubview(progress)
        item.view = view
        return item
    }

    private func menuStatusTitle() -> String {
        if isRecording {
            return "Recording..."
        }
        if isBusy {
            return "Transcribing..."
        }
        if isReady {
            let hk = hotkey.hotkey.name
            let verb = settings.triggerMode == .hold ? "Hold" : "Press"
            return "\(verb) \(hk) to dictate"
        }
        if let failure = startupFailure {
            return failure.statusTitle
        }
        if startupTask != nil || isRestartingAudioInput || isSwitchingSpeechModel {
            return startupStatusTitle
        }
        if !missingPermissions().isEmpty {
            return "Grant permissions to finish setup"
        }
        if isCoreRuntimeReady {
            return "Starting hotkey listener…"
        }
        return "SuperDictate is not ready"
    }

    private func diagnosticsText() -> String {
        let generated = ISO8601DateFormatter().string(from: Date())
        let bundlePath = Bundle.main.bundlePath
        let installKind: String
        if bundlePath == "/Applications/SuperDictate.app" {
            installKind = "Applications app"
        } else if bundlePath == "/tmp/SuperDictate-dev.app" {
            installKind = "signed dev app"
        } else {
            installKind = "other"
        }

        let devices = availableAudioInputDevices()
        let savedInput = settings.inputDevice.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedInput = audioInputDevice(matching: savedInput, in: devices)
        let inputLabel: String
        if savedInput.isEmpty || isDefaultAggregateAudioInputPreference(savedInput) {
            inputLabel = "System default"
        } else if let selectedInput {
            inputLabel = "\(selectedInput.name) (available)"
        } else {
            inputLabel = "Saved device unavailable"
        }

        let startupText: String
        if let failure = startupFailure {
            startupText = "\(failure.statusTitle): \(failure.detail)"
        } else if startupTask != nil || isRestartingAudioInput || isSwitchingSpeechModel {
            startupText = startupStatusTitle
        } else {
            startupText = isCoreRuntimeReady ? "Runtime ready" : "Runtime not ready"
        }

        let permissionLines = Permission.allCases
            .map { "\($0.rawValue): \(Permissions.isGranted($0) ? "granted" : "missing")" }
        let availableInputLines = devices.isEmpty
            ? ["Available inputs: none reported"]
            : ["Available inputs (\(devices.count)):"] + devices.map { "  \($0.name)" }
        let pendingUpdateText = pendingUpdate.map { "v\($0.version)" } ?? "none"
        let lastUpdateCheckText = updateCheckDiagnosticText(
            checkedAt: settings.lastUpdateCheckAt,
            source: settings.lastUpdateCheckSource,
            result: settings.lastUpdateCheckResult,
            releaseVersion: settings.lastUpdateCheckVersion
        )
        let updateReminderText: String
        if let version = reminderPausedUpdateVersion,
           let until = reminderPausedUntil,
           Date() < until {
            updateReminderText = "v\(version) until \(ISO8601DateFormatter().string(from: until))"
        } else {
            updateReminderText = "none"
        }
        let memoryLines: [String]
        if let memory = currentAppMemoryUsage() {
            memoryLines = [
                "Resident: \(formattedByteCount(memory.residentBytes))",
                "Physical footprint: \(formattedByteCount(memory.physicalFootprintBytes))",
            ]
        } else {
            memoryLines = []
        }
        let launchAtLoginText: String
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLoginText = "enabled"
        case .requiresApproval:
            launchAtLoginText = "requires approval"
        case .notRegistered:
            launchAtLoginText = "disabled"
        case .notFound:
            launchAtLoginText = "not found"
        @unknown default:
            launchAtLoginText = "unknown"
        }

        let speechModelProfile = settings.speechModelProfile
        let languageSettingText = DICTATION_LANGUAGE_DISPLAY[settings.dictationLanguage]
            ?? settings.dictationLanguage.rawValue

        let logLines: [String]
        do {
            logLines = try recentDiagnosticLogLines()
        } catch {
            logLines = ["Unavailable: \(error.localizedDescription)"]
        }

        let snapshot = DiagnosticsReportSnapshot(
            generated: generated,
            appVersion: currentBundleVersion(),
            appBuild: currentBundleBuild(),
            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            bundleID: Bundle.main.bundleIdentifier ?? "unknown",
            bundlePath: privacySafeBundlePath(bundlePath),
            installKind: installKind,
            status: menuStatusTitle(),
            startup: startupText,
            speechModelReady: isSpeechModelReady,
            coreRuntimeReady: isCoreRuntimeReady,
            readyForDictation: isReady,
            recordingActive: isRecording,
            transcribing: isBusy,
            memoryLines: memoryLines,
            permissionLines: permissionLines,
            settingLines: [
                "Hotkey: \(hotkey.hotkey.name)",
                "Trigger mode: \(TRIGGER_DISPLAY[settings.triggerMode] ?? settings.triggerMode.rawValue)",
                "Speech model: \(speechModelProfile.displayName)",
                "Language: \(languageSettingText)",
                "Paste behavior: \(PASTE_SUFFIX_DISPLAY[settings.pasteSuffix] ?? settings.pasteSuffix.rawValue)",
                "Remove filler words: \(settings.removeFillerWords)",
                "Recent transcripts: \(RECENT_TRANSCRIPT_LIMIT_DISPLAY[settings.recentTranscriptLimit] ?? settings.recentTranscriptLimit.rawValue) (\(visibleHistory.count) visible, \(history.count) archived)",
                "Text corrections: \(settings.transcriptCorrections.count) configured",
                "Text correction sync: \(settings.transcriptCorrectionsSyncFile.isEmpty ? "off" : "configured")",
                "Text insertion: \(TextInserter.defaultStrategyDescription)",
                "Recording waveform: \(settings.showRecordingWaveform)",
                "Mute while recording: \(settings.muteWhileRecording)",
                "Feedback sounds: \(settings.playFeedbackSounds)",
                "Show in Dock: \(settings.showInDock)",
                "Launch at Login: \(launchAtLoginText)",
            ],
            updateLines: [
                "Update notifications: \(settings.checkForUpdates)",
                "Last update check: \(lastUpdateCheckText)",
                "Manual update check active: \(isCheckingForUpdates)",
                "Pending update: \(pendingUpdateText)",
                "Reminder paused: \(updateReminderText)",
                "Update helper log: \((UPDATE_HELPER_LOG_PATH as NSString).abbreviatingWithTildeInPath)",
            ],
            microphoneLines: ["Selected: \(inputLabel)"] + availableInputLines,
            logPath: (Logger.shared.fileURL.path as NSString).abbreviatingWithTildeInPath,
            recentLogLines: logLines
        )
        return diagnosticsReportText(from: snapshot)
    }

    @objc private func retryStartupClicked(_ sender: NSMenuItem) {
        startStartup(reason: "manual retry")
    }

    // MARK: - Setup checklist

    private func maybeShowSetupChecklist(reason: String) {
        guard !didOfferSetupChecklistThisLaunch else { return }
        guard startupFailure != nil
            || !missingPermissions().isEmpty else { return }
        didOfferSetupChecklistThisLaunch = true
        log("setup checklist shown (\(reason))")
        showSetupChecklist()
    }

    @objc private func showSetupChecklistClicked(_ sender: NSMenuItem) {
        showSetupChecklist()
    }

    private func showSetupChecklist() {
        NSApp.setActivationPolicy(.regular)
        showAppForModal()
        if let window = setupChecklistWindow {
            updateSetupChecklist()
            window.makeKeyAndOrderFront(nil)
            startSetupChecklistRefreshTimer()
            return
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "Set Up SuperDictate"
        window.isReleasedWhenClosed = false
        window.delegate = self
        setupChecklistWindow = window

        updateSetupChecklist()
        window.center()
        window.makeKeyAndOrderFront(nil)
        startSetupChecklistRefreshTimer()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === setupChecklistWindow else { return }
        stopSetupChecklistRefreshTimer()
        refreshActivationPolicy()
    }

    private func startSetupChecklistRefreshTimer() {
        guard setupChecklistRefreshTimer == nil else { return }
        setupChecklistRefreshTimer = Timer.scheduledTimer(timeInterval: 1,
                                                          target: self,
                                                          selector: #selector(setupChecklistTimerFired(_:)),
                                                          userInfo: nil,
                                                          repeats: true)
        setupChecklistRefreshTimer?.tolerance = 0.25
    }

    private func stopSetupChecklistRefreshTimer() {
        setupChecklistRefreshTimer?.invalidate()
        setupChecklistRefreshTimer = nil
    }

    @objc private func setupChecklistTimerFired(_ timer: Timer) {
        guard setupChecklistWindow?.isVisible == true else {
            stopSetupChecklistRefreshTimer()
            return
        }
        updateSetupChecklist()
    }

    private func updateSetupChecklist() {
        guard let window = setupChecklistWindow else { return }
        window.contentView = makeSetupChecklistView()
        rebuildMenu()
    }

    private func makeSetupChecklistView() -> NSView {
        let root = NSStackView()
        root.orientation = .vertical
        // NSStackView on macOS uses NSLayoutConstraint.Attribute for
        // alignment and has no `.fill` case (UIKit-only). With
        // `.leading` every child hugged its own content, so the
        // right-edge Status / Grant column drifted between rows and
        // the NSBox separators — which have no intrinsic width —
        // collapsed to zero. After assembly we explicitly constrain
        // each arranged subview to the inner content width so
        // everything lines up at the same right edge.
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 18, right: 22)
        root.translatesAutoresizingMaskIntoConstraints = false

        let title = setupLabel("Set Up SuperDictate", font: .systemFont(ofSize: 22, weight: .semibold))
        let subtitle = setupLabel("Finish these checks before dictating. SuperDictate keeps this setup local to your Mac.",
                                  font: .systemFont(ofSize: 13),
                                  color: .secondaryLabelColor)
        subtitle.preferredMaxLayoutWidth = 476
        root.addArrangedSubview(title)
        root.addArrangedSubview(subtitle)
        root.addArrangedSubview(setupSeparator())

        root.addArrangedSubview(makeSpeechModelSetupRow())
        root.addArrangedSubview(makeAudioInputSetupRow())

        for permission in Permission.allCases {
            root.addArrangedSubview(makePermissionSetupRow(permission))
        }

        root.addArrangedSubview(makeHotkeySetupRow())

        if !setupChecklistIsComplete {
            let tip = setupLabel("Tip: If clicking 'Grant' doesn't open a prompt or show SuperDictate in System Settings, click 'Try Again' — SuperDictate will reset its macOS privacy permission entry and re-request, which clears stuck macOS state.",
                                 font: .systemFont(ofSize: 11),
                                 color: .secondaryLabelColor)
            tip.preferredMaxLayoutWidth = 476
            root.addArrangedSubview(tip)
        }

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10
        footer.translatesAutoresizingMaskIntoConstraints = false

        let summary = setupLabel(setupChecklistSummary(),
                                 font: .systemFont(ofSize: 12),
                                 color: .secondaryLabelColor)
        let close = NSButton(title: setupChecklistIsComplete ? "Done" : "Close",
                             target: self,
                             action: #selector(closeSetupChecklistClicked(_:)))
        close.bezelStyle = .rounded

        footer.addArrangedSubview(summary)
        footer.addArrangedSubview(NSView())
        footer.addArrangedSubview(close)
        footer.setHuggingPriority(.defaultLow, for: .horizontal)
        root.addArrangedSubview(setupSeparator())
        root.addArrangedSubview(footer)

        // Force every arranged subview to fill the inner content width
        // (root width minus left + right insets). Without this the row
        // NSStackViews hug their content and the right-aligned Status /
        // Grant column drifts between rows; the NSBox separators have
        // no intrinsic width and collapse entirely.
        let innerWidthInset = -(root.edgeInsets.left + root.edgeInsets.right)
        for view in root.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: root.widthAnchor,
                                        constant: innerWidthInset).isActive = true
        }

        let container = NSView()
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: 520),
        ])
        return container
    }

    private var setupChecklistIsComplete: Bool {
        isSpeechModelReady
            && isReady
            && missingPermissions().isEmpty
    }

    private func setupChecklistSummary() -> String {
        setupChecklistIsComplete
            ? "Setup is complete. Use SuperDictate from the Dock or shortcuts."
            : "You can close this window; the menu will keep tracking setup."
    }

    private func makeSpeechModelSetupRow() -> NSView {
        let state = speechModelSetupRowState(profile: settings.speechModelProfile,
                                             isSpeechModelReady: isSpeechModelReady,
                                             isStartupInProgress: startupTask != nil || isSwitchingSpeechModel,
                                             startupStatusTitle: startupStatusTitle,
                                             failure: startupFailure)

        return makeSetupChecklistRow(title: "Speech model",
                                     detail: state.detail,
                                     status: state.status,
                                     buttonTitle: state.buttonTitle,
                                     action: state.buttonTitle == nil ? nil : #selector(retryStartupFromSetupClicked(_:)))
    }

    private func makeAudioInputSetupRow() -> NSView {
        let state = audioInputSetupRowState(isSpeechModelReady: isSpeechModelReady,
                                            isCoreRuntimeReady: isCoreRuntimeReady,
                                            isStartupInProgress: startupTask != nil || isRestartingAudioInput,
                                            startupStatusTitle: startupStatusTitle,
                                            failure: startupFailure)
        return makeSetupChecklistRow(title: "Audio input",
                                     detail: state.detail,
                                     status: state.status,
                                     buttonTitle: state.buttonTitle,
                                     action: state.buttonTitle == nil ? nil : #selector(retryStartupFromSetupClicked(_:)))
    }

    private func makePermissionSetupRow(_ permission: Permission) -> NSView {
        let granted = Permissions.isGranted(permission)
        let clicks = permClickCount[permission] ?? 0
        return makeSetupChecklistRow(title: permission.rawValue,
                                     detail: setupDetail(for: permission),
                                     status: granted ? "Granted" : "Missing",
                                     buttonTitle: granted ? nil : (clicks >= 1 ? "Try Again" : "Grant"),
                                     action: granted ? nil : #selector(grantSetupPermissionClicked(_:)),
                                     tag: Permission.allCases.firstIndex(of: permission) ?? -1)
    }

    private func makeHotkeySetupRow() -> NSView {
        let state = hotkeySetupRowState(isReady: isReady,
                                        hotkeyTestSucceeded: hotkeyTestSucceeded,
                                        triggerMode: settings.triggerMode,
                                        hotkeyName: hotkey.hotkey.name,
                                        failure: startupFailure)

        return makeSetupChecklistRow(title: "Hotkey",
                                     detail: state.detail,
                                     status: state.status,
                                     buttonTitle: state.buttonTitle,
                                     action: state.buttonTitle == nil ? nil : #selector(retryStartupFromSetupClicked(_:)))
    }

    private func setupDetail(for permission: Permission) -> String {
        switch permission {
        case .microphone:
            return "Captures your voice while dictating. Click 'Grant', then click 'OK' in the macOS prompt."
        case .accessibility:
            return "Pastes the transcript at your cursor. Click 'Grant' to open System Settings → Privacy & Security → Accessibility, then enable the toggle next to 'SuperDictate'."
        case .inputMonitoring:
            return "Lets SuperDictate detect the dictation hotkey. Click 'Grant' to open System Settings → Privacy & Security → Input Monitoring, then enable the toggle next to 'SuperDictate'."
        }
    }

    private func makeSetupChecklistRow(title: String,
                                       detail: String,
                                       status: String,
                                       buttonTitle: String? = nil,
                                       action: Selector? = nil,
                                       tag: Int = 0) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        row.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2

        textStack.addArrangedSubview(setupLabel(title, font: .systemFont(ofSize: 13, weight: .semibold)))
        
        let detailLabel = setupLabel(detail, font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
        detailLabel.preferredMaxLayoutWidth = (buttonTitle != nil) ? 310 : 380
        textStack.addArrangedSubview(detailLabel)

        let statusLabel = setupLabel(status,
                                     font: .systemFont(ofSize: 12, weight: .medium),
                                     color: setupStatusColor(status))
        statusLabel.alignment = .right
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)

        row.addArrangedSubview(textStack)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(statusLabel)

        if let buttonTitle, let action {
            let button = NSButton(title: buttonTitle, target: self, action: action)
            button.bezelStyle = .rounded
            button.tag = tag
            button.setContentHuggingPriority(.required, for: .horizontal)
            row.addArrangedSubview(button)
        }

        row.setHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    private func setupLabel(_ text: String, font: NSFont, color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        return label
    }

    private func setupStatusColor(_ status: String) -> NSColor {
        switch status {
        case "Granted", "Ready", "Detected", "Set":
            return .systemGreen
        case "Missing", "Needs retry", "Required":
            return .systemOrange
        default:
            return .secondaryLabelColor
        }
    }

    private func setupSeparator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        return separator
    }

    @objc private func closeSetupChecklistClicked(_ sender: NSButton) {
        setupChecklistWindow?.close()
    }

    @objc private func retryStartupFromSetupClicked(_ sender: NSButton) {
        startStartup(reason: "setup checklist retry")
    }

    @objc private func grantSetupPermissionClicked(_ sender: NSButton) {
        guard Permission.allCases.indices.contains(sender.tag) else { return }
        requestPermissionFromMenu(Permission.allCases[sender.tag])
    }

    // MARK: - Permission row + click-twice-to-reset

    private func buildPermissionItem(_ p: Permission) -> NSMenuItem {
        let clicks = permClickCount[p] ?? 0
        let title: String
        if clicks >= 1 {
            // First click already happened; permission still denied,
            // so signal explicitly that a second click will reset
            // any stuck TCC state and re-request.
            title = "⚠ Grant \(p.rawValue) (try again — will reset stuck state)…"
        } else {
            title = "⚠ Grant \(p.rawValue) permission…"
        }
        let item = NSMenuItem(title: title,
                              action: #selector(grantPermissionClicked(_:)),
                              keyEquivalent: "")
        item.target = self
        item.representedObject = p.rawValue
        return item
    }

    @objc private func grantPermissionClicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let p = Permission(rawValue: raw) else { return }
        requestPermissionFromMenu(p)
    }

    private func requestPermissionFromMenu(_ p: Permission) {
        if Permissions.isGranted(p) {
            permClickCount[p] = nil
            log("perm click ignored: \(p.rawValue) already granted")
            completeReadinessIfPossible(reason: "permission already granted")
            return
        }

        let clicks = (permClickCount[p] ?? 0) + 1
        permClickCount[p] = clicks
        log("perm click #\(clicks): \(p.rawValue)")

        if clicks >= 2 {
            // Click #2+: scrub TCC before re-requesting. The most
            // common cause of "I clicked Grant but nothing happened"
            // is a stuck TCC entry that survived an upgrade. The
            // re-request happens in the reset's completion — issuing
            // it before tccutil finished would race the scrub it
            // depends on.
            log("  resetting TCC for \(p.rawValue) before retry")
            TCC.reset(p, bundleID: Bundle.main.bundleIdentifier ?? "com.local.superdictate") { [weak self] in
                guard let self, !self.isTerminating else { return }
                Permissions.request(p)
                self.startPermissionReadinessMonitor(reason: "permission grant")
                self.updateSetupChecklist()
                self.rebuildMenu()
            }
            rebuildMenu()
            return
        }
        Permissions.request(p)
        startPermissionReadinessMonitor(reason: "permission grant")
        updateSetupChecklist()
        rebuildMenu()
    }

    // MARK: - Settings submenu

    private func buildSettingsItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false

        sub.addItem(buildDictationSettingsItem())
        sub.addItem(buildTextSettingsItem())
        sub.addItem(buildBehaviorSettingsItem())

        parent.submenu = sub
        return parent
    }

    private func buildDictationSettingsItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Dictation", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false

        sub.addItem(buildHotkeySettingsItem())
        sub.addItem(buildTriggerSettingsItem())
        sub.addItem(buildDictationLanguageSettingsItem())
        sub.addItem(buildInputDeviceItem())

        parent.submenu = sub
        return parent
    }

    private func buildTextSettingsItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Text", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false

        sub.addItem(buildPasteSuffixSettingsItem())
        sub.addItem(buildRecentTranscriptLimitSettingsItem())
        sub.addItem(buildCorrectionsItem())

        let filler = NSMenuItem(title: "Remove filler words (um, uh, ah, er, hmm)",
                                action: #selector(toggleRemoveFillerWords(_:)),
                                keyEquivalent: "")
        filler.target = self
        filler.state = settings.removeFillerWords ? .on : .off
        sub.addItem(filler)

        parent.submenu = sub
        return parent
    }

    private func buildBehaviorSettingsItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Behavior", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false

        let waveform = NSMenuItem(title: "Show recording waveform",
                                  action: #selector(toggleRecordingWaveform(_:)),
                                  keyEquivalent: "")
        waveform.target = self
        waveform.state = settings.showRecordingWaveform ? .on : .off
        sub.addItem(waveform)

        let mute = NSMenuItem(title: "Mute system audio while recording",
                              action: #selector(toggleMute(_:)),
                              keyEquivalent: "")
        mute.target = self
        mute.state = settings.muteWhileRecording ? .on : .off
        sub.addItem(mute)

        let sounds = NSMenuItem(title: "Play feedback sounds",
                                action: #selector(toggleFeedbackSounds(_:)),
                                keyEquivalent: "")
        sounds.target = self
        sounds.state = settings.playFeedbackSounds ? .on : .off
        sub.addItem(sounds)

        let automaticUpdates = NSMenuItem(title: "Automatically check for updates",
                                          action: #selector(toggleCheckForUpdates(_:)),
                                          keyEquivalent: "")
        automaticUpdates.target = self
        automaticUpdates.state = settings.checkForUpdates ? .on : .off
        automaticUpdates.toolTip = "Periodically checks GitHub for a newer release and only notifies you."
        sub.addItem(automaticUpdates)

        let launchAtLogin = NSMenuItem(title: "Launch at Login",
                                       action: #selector(toggleLaunchAtLogin(_:)),
                                       keyEquivalent: "")
        launchAtLogin.target = self
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLogin.state = .on
        case .requiresApproval:
            launchAtLogin.state = .mixed
            launchAtLogin.toolTip = "Approve SuperDictate in System Settings → General → Login Items."
        default:
            launchAtLogin.state = .off
        }
        sub.addItem(launchAtLogin)

        let dock = NSMenuItem(title: "Show SuperDictate in Dock",
                              action: #selector(toggleDock(_:)),
                              keyEquivalent: "")
        dock.target = self
        dock.state = settings.showInDock ? .on : .off
        sub.addItem(dock)

        parent.submenu = sub
        return parent
    }

    private func buildHotkeySettingsItem() -> NSMenuItem {
        let hkParent = NSMenuItem(title: "Hotkey", action: nil, keyEquivalent: "")
        let hkSub = NSMenu()
        hkSub.autoenablesItems = false
        let current = hotkey.hotkey

        if !HOTKEY_CHOICES.contains(current) {
            let currentItem = NSMenuItem(title: current.name,
                                         action: nil,
                                         keyEquivalent: "")
            currentItem.state = .on
            currentItem.toolTip = "Recorded custom hotkey"
            hkSub.addItem(currentItem)
            hkSub.addItem(.separator())
        }

        for choice in HOTKEY_CHOICES {
            let item = NSMenuItem(title: choice.name,
                                  action: #selector(selectHotkey(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.state = (choice == current) ? .on : .off
            item.representedObject = Int(choice.keycode)
            hkSub.addItem(item)
        }

        hkSub.addItem(.separator())

        let record = NSMenuItem(title: "Record Hotkey…",
                                action: #selector(recordHotkeyClicked(_:)),
                                keyEquivalent: "")
        record.target = self
        record.isEnabled = !isRecording && !isBusy && !isTerminating
        hkSub.addItem(record)

        let reset = NSMenuItem(title: "Reset Hotkey to Default",
                               action: #selector(resetHotkeyClicked(_:)),
                               keyEquivalent: "")
        reset.target = self
        reset.isEnabled = current != hotkeyChoice(forKeycode: DEFAULT_HOTKEY_KEYCODE)
            && !isRecording
            && !isBusy
            && !isTerminating
        reset.toolTip = "Use Right Command for dictation."
        hkSub.addItem(reset)

        hkParent.submenu = hkSub
        return hkParent
    }

    private func buildTriggerSettingsItem() -> NSMenuItem {
        let tmParent = NSMenuItem(title: "Trigger", action: nil, keyEquivalent: "")
        let tmSub = NSMenu()
        tmSub.autoenablesItems = false
        for mode in [TriggerMode.hold, .toggle] {
            let item = NSMenuItem(title: TRIGGER_DISPLAY[mode] ?? mode.rawValue,
                                  action: #selector(selectTriggerMode(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.state = (mode == settings.triggerMode) ? .on : .off
            item.representedObject = mode.rawValue
            tmSub.addItem(item)
        }
        tmParent.submenu = tmSub
        return tmParent
    }

    private func buildDictationLanguageSettingsItem() -> NSMenuItem {
        let langParent = NSMenuItem(title: "Language Hint", action: nil, keyEquivalent: "")
        let langSub = NSMenu()
        langSub.autoenablesItems = false
        for lang in DictationLanguage.allCases {
            let item = NSMenuItem(title: DICTATION_LANGUAGE_DISPLAY[lang] ?? lang.rawValue,
                                  action: #selector(selectDictationLanguage(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.state = (lang == settings.dictationLanguage) ? .on : .off
            item.representedObject = lang.rawValue
            langSub.addItem(item)
            // Auto-detect is the right default for almost everyone; only
            // pin a specific language if you see wrong-script bleed-through
            // (e.g. Cyrillic letters in Polish output).
            if lang == .auto {
                langSub.addItem(.separator())
            }
        }
        langParent.submenu = langSub
        return langParent
    }

    private func buildPasteSuffixSettingsItem() -> NSMenuItem {
        let pasteParent = NSMenuItem(title: "After Pasting", action: nil, keyEquivalent: "")
        let pasteSub = NSMenu()
        pasteSub.autoenablesItems = false
        for suffix in [PasteSuffix.appendSpace, .none, .appendNewline] {
            let item = NSMenuItem(title: PASTE_SUFFIX_DISPLAY[suffix] ?? suffix.rawValue,
                                  action: #selector(selectPasteSuffix(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.state = (suffix == settings.pasteSuffix) ? .on : .off
            item.representedObject = suffix.rawValue
            pasteSub.addItem(item)
        }
        pasteParent.submenu = pasteSub
        return pasteParent
    }

    private func buildRecentTranscriptLimitSettingsItem() -> NSMenuItem {
        let recentParent = NSMenuItem(title: "Recent Transcripts", action: nil, keyEquivalent: "")
        let recentSub = NSMenu()
        recentSub.autoenablesItems = false
        for limit in RecentTranscriptLimit.allCases {
            let item = NSMenuItem(title: RECENT_TRANSCRIPT_LIMIT_DISPLAY[limit] ?? limit.rawValue,
                                  action: #selector(selectRecentTranscriptLimit(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.state = (limit == settings.recentTranscriptLimit) ? .on : .off
            item.representedObject = limit.rawValue
            recentSub.addItem(item)
        }
        recentParent.submenu = recentSub
        return recentParent
    }

    private func buildInputDeviceItem() -> NSMenuItem {
        let devices = availableAudioInputDevices()
        let rawSavedPreference = settings.inputDevice.trimmingCharacters(in: .whitespacesAndNewlines)
        let savedPreference = isDefaultAggregateAudioInputPreference(rawSavedPreference) ? "" : rawSavedPreference
        let selectedDevice = audioInputDevice(matching: savedPreference, in: devices)
        let canSwitch = !isRecording && !isBusy && !isTerminating
        let parent = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        if !savedPreference.isEmpty && selectedDevice == nil {
            parent.toolTip = savedPreference
        }

        let sub = NSMenu()
        sub.autoenablesItems = false

        let system = NSMenuItem(title: "System default",
                                action: #selector(selectInputDevice(_:)),
                                keyEquivalent: "")
        system.target = self
        system.representedObject = ""
        system.state = (savedPreference.isEmpty || selectedDevice == nil) ? .on : .off
        system.isEnabled = canSwitch
        sub.addItem(system)

        if !savedPreference.isEmpty && selectedDevice == nil {
            let unavailable = NSMenuItem(title: "Unavailable: \(savedPreference)",
                                         action: nil,
                                         keyEquivalent: "")
            unavailable.isEnabled = false
            sub.addItem(unavailable)
        }

        if !devices.isEmpty {
            sub.addItem(.separator())
        }

        for device in devices {
            let item = NSMenuItem(title: device.name,
                                  action: #selector(selectInputDevice(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = device.uid
            item.toolTip = device.uid
            item.state = (selectedDevice?.uid == device.uid) ? .on : .off
            item.isEnabled = canSwitch
            sub.addItem(item)
        }

        parent.submenu = sub
        return parent
    }

    @objc private func selectInputDevice(_ sender: NSMenuItem) {
        guard !isRecording, !isBusy, !isTerminating,
              let preference = sender.representedObject as? String else { return }

        settings.inputDevice = preference
        let label = preference.isEmpty
            ? "system default"
            : (audioInputDevice(matching: preference)?.name ?? preference)
        log("input device selected: \(label)")
        restartAudioForInputDeviceChange()
    }

    private func restartAudioForInputDeviceChange() {
        restartAudioInput(reason: "input device change")
    }

    private func suppressAudioConfigurationChangesFromAppEngineUpdate() {
        let suppressedUntil = Date().timeIntervalSinceReferenceDate
            + AUDIO_CONFIGURATION_CHANGE_SUPPRESSION_SECONDS
        audioConfigurationChangeSuppressedUntil = max(audioConfigurationChangeSuppressedUntil ?? 0,
                                                      suppressedUntil)
    }

    private func shouldIgnoreAppOwnedAudioConfigurationChange() -> Bool {
        let now = Date().timeIntervalSinceReferenceDate
        if audioConfigurationChangeIsSuppressed(now: now,
                                                suppressedUntil: audioConfigurationChangeSuppressedUntil) {
            return true
        }
        if let suppressedUntil = audioConfigurationChangeSuppressedUntil,
           now >= suppressedUntil {
            audioConfigurationChangeSuppressedUntil = nil
        }
        return false
    }

    private func cancelAudioIdleStop() {
        audioIdleStopWorkItem?.cancel()
        audioIdleStopWorkItem = nil
    }

    private func scheduleAudioIdleStop(reason: String) {
        cancelAudioIdleStop()
        guard audio.isEngineStarted, !isRecording, !isBusy, !isTerminating else { return }

        let work = DispatchWorkItem { [weak self] in
            self?.closeIdleAudioInputIfNeeded(reason: reason)
        }
        audioIdleStopWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + AUDIO_IDLE_STOP_DELAY_SECONDS, execute: work)
    }

    private func stopAudioEngineImmediately() {
        cancelAudioIdleStop()
        if audio.isEngineStarted {
            suppressAudioConfigurationChangesFromAppEngineUpdate()
        }
        audio.stopEngine()
    }

    private func closeIdleAudioInputIfNeeded(reason: String) {
        guard !isRecording, !isBusy, !isTerminating else { return }
        let wasEngineStarted = audio.isEngineStarted
        stopAudioEngineImmediately()
        if wasEngineStarted {
            log("AudioCapture: idle audio input closed (\(reason))")
        }
    }

    private func handleAudioConfigurationChange() {
        if shouldIgnoreAppOwnedAudioConfigurationChange() {
            log("AudioCapture: app-owned audio configuration change ignored")
            return
        }

        switch audioRouteChangeAction(isTerminating: isTerminating,
                                      isRestartingAudioInput: isRestartingAudioInput,
                                      isCoreRuntimeReady: isCoreRuntimeReady,
                                      isRecording: isRecording,
                                      isBusy: isBusy,
                                      hasStartupTask: startupTask != nil) {
        case .ignore:
            return
        case .rebuildMenuOnly:
            log("AudioCapture: audio configuration changed")
            rebuildMenu()
        case .deferRefresh:
            log("AudioCapture: audio configuration changed")
            pendingAudioRouteRefresh = true
            log("AudioCapture: audio route refresh deferred")
            rebuildMenu()
        case .restartNow:
            log("AudioCapture: audio configuration changed")
            rebuildMenu()
            restartAudioInput(reason: "audio configuration change")
        }
    }

    @discardableResult
    private func runDeferredAudioRouteRefreshIfNeeded() -> Bool {
        guard pendingAudioRouteRefresh,
              !isRecording, !isBusy, startupTask == nil, isCoreRuntimeReady, !isTerminating else { return false }
        pendingAudioRouteRefresh = false
        restartAudioInput(reason: "deferred audio configuration change")
        return true
    }

    private func restartAudioInput(reason: String) {
        guard !isRestartingAudioInput else { return }
        guard isCoreRuntimeReady else {
            rebuildMenu()
            return
        }

        pendingAudioRouteRefresh = false
        isRestartingAudioInput = true
        isReady = false
        isRecording = false
        isBusy = false
        hotkey.stop()
        setMenuBarState(.loading)
        rebuildMenu()
        stopAudioEngineImmediately()

        Task { @MainActor in
            defer { isRestartingAudioInput = false }
            do {
                try await startAudioInputWithRetries(reason: reason,
                                                     initialStatusTitle: "Restarting audio input…")
                isCoreRuntimeReady = true
                completeReadinessIfPossible(reason: reason)
            } catch {
                isCoreRuntimeReady = false
                isReady = false
                isRecording = false
                isBusy = false
                hotkey.stop()
                recordStartupFailure(stage: .audioInput, error: error, reason: reason)
            }
        }
    }

    private func buildCorrectionsItem() -> NSMenuItem {
        let corrections = settings.transcriptCorrections
        let title = corrections.isEmpty ? "Text Corrections" : "Text Corrections (\(corrections.count))"
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false

        let add = NSMenuItem(title: "Add Correction…",
                             action: #selector(addCorrectionClicked(_:)),
                             keyEquivalent: "")
        add.target = self
        sub.addItem(add)

        let addFromLast = NSMenuItem(title: "Add Correction from Last Transcript…",
                                     action: #selector(addCorrectionFromLastTranscriptClicked(_:)),
                                     keyEquivalent: "")
        addFromLast.target = self
        addFromLast.isEnabled = visibleHistory.first != nil
        if let newest = visibleHistory.first {
            addFromLast.toolTip = previewLine(for: newest.text)
        }
        sub.addItem(addFromLast)

        sub.addItem(.separator())

        let importItem = NSMenuItem(title: "Import Corrections…",
                                    action: #selector(importCorrectionsClicked(_:)),
                                    keyEquivalent: "")
        importItem.target = self
        sub.addItem(importItem)

        let exportItem = NSMenuItem(title: "Export Corrections…",
                                    action: #selector(exportCorrectionsClicked(_:)),
                                    keyEquivalent: "")
        exportItem.target = self
        exportItem.isEnabled = !corrections.isEmpty
        sub.addItem(exportItem)

        let shareItem = NSMenuItem(title: "Share Corrections…",
                                   action: #selector(shareCorrectionsClicked(_:)),
                                   keyEquivalent: "")
        shareItem.target = self
        shareItem.isEnabled = !corrections.isEmpty
        sub.addItem(shareItem)

        sub.addItem(.separator())

        if let syncURL = correctionSyncFileURL() {
            let syncLabel = NSMenuItem(title: "Syncing: \(syncURL.lastPathComponent)",
                                       action: nil,
                                       keyEquivalent: "")
            syncLabel.isEnabled = false
            syncLabel.toolTip = syncURL.path
            sub.addItem(syncLabel)

            let syncNow = NSMenuItem(title: "Sync Now",
                                     action: #selector(syncCorrectionsNowClicked(_:)),
                                     keyEquivalent: "")
            syncNow.target = self
            sub.addItem(syncNow)

            let stopSync = NSMenuItem(title: "Stop Syncing…",
                                      action: #selector(stopSyncingCorrectionsClicked(_:)),
                                      keyEquivalent: "")
            stopSync.target = self
            sub.addItem(stopSync)
        } else {
            let startSync = NSMenuItem(title: "Set Up Sync…",
                                       action: #selector(setUpCorrectionsSyncClicked(_:)),
                                       keyEquivalent: "")
            startSync.target = self
            sub.addItem(startSync)
        }

        sub.addItem(.separator())

        if corrections.isEmpty {
            let empty = NSMenuItem(title: "No corrections", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            sub.addItem(empty)
            parent.submenu = sub
            return parent
        }

        for (index, correction) in corrections.enumerated() {
            let item = NSMenuItem(title: correctionMenuTitle(correction),
                                  action: nil,
                                  keyEquivalent: "")
            let itemSub = NSMenu()
            itemSub.autoenablesItems = false

            let edit = NSMenuItem(title: "Edit…",
                                  action: #selector(editCorrectionClicked(_:)),
                                  keyEquivalent: "")
            edit.target = self
            edit.representedObject = index
            itemSub.addItem(edit)

            let delete = NSMenuItem(title: "Delete",
                                    action: #selector(deleteCorrectionClicked(_:)),
                                    keyEquivalent: "")
            delete.target = self
            delete.representedObject = index
            itemSub.addItem(delete)

            item.submenu = itemSub
            sub.addItem(item)
        }

        sub.addItem(.separator())

        let removeAll = NSMenuItem(title: "Remove All Corrections…",
                                   action: #selector(removeAllCorrectionsClicked(_:)),
                                   keyEquivalent: "")
        removeAll.target = self
        sub.addItem(removeAll)

        parent.submenu = sub
        return parent
    }

    private func correctionMenuTitle(_ correction: TranscriptCorrection) -> String {
        "\(clippedCorrectionText(correction.source)) → \(clippedCorrectionText(correction.replacement))"
    }

    private func clippedCorrectionText(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 32 ? String(flat.prefix(32)) + "…" : flat
    }

    @objc private func addCorrectionClicked(_ sender: NSMenuItem) {
        guard let correction = showCorrectionEditor(existing: nil) else { return }
        saveCorrection(correction)
    }

    @objc private func addCorrectionFromLastTranscriptClicked(_ sender: NSMenuItem) {
        guard let newest = visibleHistory.first else { return }
        let prefill = correctionSourcePrefill(from: newest.text)
        guard !prefill.isEmpty else { return }
        guard let correction = showCorrectionEditor(existing: nil, prefillSource: prefill) else { return }
        saveCorrection(correction)
    }

    @objc private func editCorrectionClicked(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        let corrections = settings.transcriptCorrections
        guard corrections.indices.contains(index) else { return }
        guard let correction = showCorrectionEditor(existing: corrections[index]) else { return }
        saveCorrection(correction, replacing: index)
    }

    @objc private func deleteCorrectionClicked(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        var corrections = settings.transcriptCorrections
        guard corrections.indices.contains(index) else { return }
        corrections.remove(at: index)
        updateTranscriptCorrections(corrections)
    }

    @objc private func removeAllCorrectionsClicked(_ sender: NSMenuItem) {
        guard !settings.transcriptCorrections.isEmpty else { return }
        showAppForModal()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove All Text Corrections?"
        alert.informativeText = "This removes every saved text correction from this Mac."
        alert.addButton(withTitle: "Remove All")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        updateTranscriptCorrections([])
    }

    @objc private func importCorrectionsClicked(_ sender: NSMenuItem) {
        showAppForModal()
        let panel = NSOpenPanel()
        panel.title = "Import Text Corrections"
        panel.message = "Choose a Parakey corrections file to import."
        panel.prompt = "Import"
        panel.allowedContentTypes = [TranscriptCorrectionsTransfer.contentType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = importCorrectionsFromUserSelectedFile(url)
    }

    @objc private func exportCorrectionsClicked(_ sender: NSMenuItem) {
        showAppForModal()
        let panel = NSSavePanel()
        panel.title = "Export Text Corrections"
        panel.message = "Save a file you can AirDrop, store in iCloud Drive, or import on another Mac."
        panel.prompt = "Export"
        panel.nameFieldStringValue = CORRECTIONS_FILE_NAME
        panel.allowedContentTypes = [TranscriptCorrectionsTransfer.contentType]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try TranscriptCorrectionsTransfer.write(settings.transcriptCorrections, to: url)
            log("correction export wrote \(settings.transcriptCorrections.count) corrections")
        } catch {
            showCorrectionTransferError(title: "Export Failed", error: error)
        }
    }

    @objc private func shareCorrectionsClicked(_ sender: NSMenuItem) {
        showAppForModal()
        do {
            cleanupPendingSharedCorrections(reason: "new share")

            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("Parakey-\(UUID().uuidString)", isDirectory: true)
            let url = folder.appendingPathComponent(CORRECTIONS_FILE_NAME)
            try TranscriptCorrectionsTransfer.write(settings.transcriptCorrections, to: url)
            pendingSharedCorrectionsURL = url

            let picker = NSSharingServicePicker(items: [url])
            let cleanupDelegate = CorrectionShareCleanupDelegate { [weak self] reason in
                self?.cleanupPendingSharedCorrections(reason: reason)
            }
            picker.delegate = cleanupDelegate
            correctionSharePicker = picker
            correctionShareCleanupDelegate = cleanupDelegate
            if let button = statusItem.button {
                picker.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            } else {
                cleanupPendingSharedCorrections(reason: "missing status button")
            }
            log("correction share prepared \(settings.transcriptCorrections.count) corrections")
        } catch {
            showCorrectionTransferError(title: "Share Failed", error: error)
        }
    }

    @objc private func setUpCorrectionsSyncClicked(_ sender: NSMenuItem) {
        showAppForModal()
        let alert = NSAlert()
        alert.messageText = "Set Up Text Correction Sync"
        alert.informativeText = """
            Parakey can keep corrections in one local file. Put that file in iCloud Drive, Dropbox, Syncthing, or another synced folder to keep multiple Macs aligned without a Parakey account.

            Parakey only reads and writes the file you choose.
            """
        alert.addButton(withTitle: "Create Sync File")
        alert.addButton(withTitle: "Use Existing File")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            createCorrectionsSyncFile()
        case .alertSecondButtonReturn:
            useExistingCorrectionsSyncFile()
        default:
            return
        }
    }

    @objc private func syncCorrectionsNowClicked(_ sender: NSMenuItem) {
        guard correctionSyncFileURL() != nil else { return }
        scheduleCorrectionSyncScan(force: true, presentErrors: true)
    }

    @objc private func stopSyncingCorrectionsClicked(_ sender: NSMenuItem) {
        showAppForModal()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Stop Syncing Text Corrections?"
        alert.informativeText = "Parakey will keep the corrections already on this Mac. The sync file will not be deleted."
        alert.addButton(withTitle: "Stop Syncing")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        settings.transcriptCorrectionsSyncFile = ""
        correctionSyncTimer?.invalidate()
        correctionSyncTimer = nil
        correctionSyncFileFingerprint = nil
        correctionSyncBaselineCorrections = []
        rebuildMenu()
    }

    private func showAppForModal() {
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var shouldShowDockIcon: Bool {
        false
    }

    private func refreshActivationPolicy() {
        if shouldShowDockIcon {
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
            NSApp.hide(nil)
        }
    }

    @discardableResult
    private func importCorrectionsFromUserSelectedFile(_ url: URL) -> Bool {
        showAppForModal()
        do {
            let imported = try TranscriptCorrectionsTransfer.readCounted(from: url)
            guard let choice = chooseCorrectionImportMode(imported: imported.corrections,
                                                          originalCount: imported.originalCount,
                                                          sourceName: url.lastPathComponent,
                                                          allowsEmptyReplace: false) else {
                return false
            }
            let next = corrections(afterApplying: imported.corrections, mode: choice)
            updateTranscriptCorrections(next)
            log("correction import read \(imported.corrections.count) corrections")
            return true
        } catch {
            showCorrectionTransferError(title: "Import Failed", error: error)
            return false
        }
    }

    private func createCorrectionsSyncFile() {
        showAppForModal()
        let panel = NSSavePanel()
        panel.title = "Create Text Correction Sync File"
        panel.message = "Choose where Parakey should keep the sync file. A folder synced by iCloud Drive or another provider works best."
        panel.prompt = "Create"
        panel.nameFieldStringValue = CORRECTIONS_FILE_NAME
        panel.allowedContentTypes = [TranscriptCorrectionsTransfer.contentType]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try TranscriptCorrectionsTransfer.write(settings.transcriptCorrections, to: url)
            settings.transcriptCorrectionsSyncFile = url.path
            startCorrectionSyncIfConfigured()
            log("correction sync created file with \(settings.transcriptCorrections.count) corrections")
        } catch {
            showCorrectionTransferError(title: "Sync Setup Failed", error: error)
        }
    }

    private func useExistingCorrectionsSyncFile() {
        showAppForModal()
        let panel = NSOpenPanel()
        panel.title = "Choose Text Correction Sync File"
        panel.message = "Choose an existing Parakey corrections file."
        panel.prompt = "Use File"
        panel.allowedContentTypes = [TranscriptCorrectionsTransfer.contentType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let imported = try TranscriptCorrectionsTransfer.readCounted(from: url)
            guard let choice = chooseCorrectionImportMode(imported: imported.corrections,
                                                          originalCount: imported.originalCount,
                                                          sourceName: url.lastPathComponent,
                                                          allowsEmptyReplace: true) else {
                return
            }
            let next = corrections(afterApplying: imported.corrections, mode: choice)
            settings.transcriptCorrectionsSyncFile = url.path
            updateTranscriptCorrections(next, writeToSync: false)
            if choice == .merge {
                guard writeCorrectionsToSyncFile(presentErrors: true) else {
                    settings.transcriptCorrectionsSyncFile = ""
                    rebuildMenu()
                    return
                }
            } else {
                correctionSyncFileFingerprint = correctionSyncFingerprint(for: url)
                correctionSyncBaselineCorrections = normalizedTranscriptCorrections(next)
            }
            startCorrectionSyncIfConfigured()
            log("correction sync linked file with \(imported.corrections.count) corrections")
        } catch {
            showCorrectionTransferError(title: "Sync Setup Failed", error: error)
        }
    }

    private func chooseCorrectionImportMode(imported: [TranscriptCorrection],
                                            originalCount: Int,
                                            sourceName: String,
                                            allowsEmptyReplace: Bool) -> CorrectionImportChoice? {
        let imported = normalizedTranscriptCorrections(imported)
        showAppForModal()
        if imported.isEmpty {
            let alert = NSAlert()
            alert.messageText = "No Text Corrections Found"
            alert.informativeText = allowsEmptyReplace
                ? "\(sourceName) does not contain any corrections. You can still use it as an empty sync file."
                : "\(sourceName) does not contain any corrections to import."
            alert.addButton(withTitle: allowsEmptyReplace ? "Use Empty File" : "OK")
            if allowsEmptyReplace { alert.addButton(withTitle: "Cancel") }
            let response = alert.runModal()
            return allowsEmptyReplace && response == .alertFirstButtonReturn ? .replace : nil
        }

        let summary = correctionImportSummary(for: imported)
        let countText = correctionImportCountText(sourceName: sourceName,
                                                  originalCount: originalCount,
                                                  keptCount: summary.total)
        let mergeCapWarning = correctionImportMergeCapWarningText(
            existingCount: settings.transcriptCorrections.count,
            newCount: summary.newCount
        )
        let alert = NSAlert()
        alert.messageText = "Import Text Corrections?"
        alert.informativeText = """
            \(countText)

            \(summary.newCount) new, \(summary.updatedCount) will update existing corrections, \(summary.unchangedCount) already match.

            Merge keeps local corrections that are not in the file. Replace All makes this Mac match the file exactly.\(mergeCapWarning.map { "\n\n" + $0 } ?? "")
            """
        alert.addButton(withTitle: "Merge")
        alert.addButton(withTitle: "Replace All")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .merge
        case .alertSecondButtonReturn:
            return .replace
        default:
            return nil
        }
    }

    private func correctionImportSummary(for imported: [TranscriptCorrection]) -> CorrectionImportSummary {
        let existingBySource = Dictionary(uniqueKeysWithValues: settings.transcriptCorrections.map {
            (normalizedTranscriptCorrectionSource($0.source), $0)
        })

        var newCount = 0
        var updatedCount = 0
        var unchangedCount = 0

        for correction in imported {
            let key = normalizedTranscriptCorrectionSource(correction.source)
            guard let existing = existingBySource[key] else {
                newCount += 1
                continue
            }
            if existing == correction {
                unchangedCount += 1
            } else {
                updatedCount += 1
            }
        }

        return CorrectionImportSummary(
            total: imported.count,
            newCount: newCount,
            updatedCount: updatedCount,
            unchangedCount: unchangedCount
        )
    }

    private func corrections(afterApplying imported: [TranscriptCorrection],
                             mode: CorrectionImportChoice) -> [TranscriptCorrection] {
        let imported = normalizedTranscriptCorrections(imported)
        switch mode {
        case .replace:
            return imported
        case .merge:
            var merged = settings.transcriptCorrections
            var indexBySource = Dictionary(uniqueKeysWithValues: merged.enumerated().map {
                (normalizedTranscriptCorrectionSource($0.element.source), $0.offset)
            })

            for correction in imported {
                let key = normalizedTranscriptCorrectionSource(correction.source)
                if let index = indexBySource[key] {
                    merged[index] = correction
                } else {
                    indexBySource[key] = merged.count
                    merged.append(correction)
                }
            }
            return merged
        }
    }

    private func updateTranscriptCorrections(_ corrections: [TranscriptCorrection],
                                             writeToSync: Bool = true) {
        if let error = settings.storeTranscriptCorrections(normalizedTranscriptCorrections(corrections)) {
            // The previous value is still in place. Surface the failed
            // save like export/sync-write failures do — silently
            // dropping the user's edit looked like data loss.
            showCorrectionTransferError(title: "Saving Corrections Failed", error: error)
            rebuildMenu()
            return
        }
        if writeToSync, !isApplyingCorrectionSyncFile {
            writeCorrectionsToSyncFile(presentErrors: false)
        }
        rebuildMenu()
    }

    private func correctionSyncFileURL() -> URL? {
        let path = settings.transcriptCorrectionsSyncFile
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func startCorrectionSyncIfConfigured() {
        correctionSyncTimer?.invalidate()
        correctionSyncTimer = nil
        guard correctionSyncFileURL() != nil else {
            correctionSyncFileFingerprint = nil
            correctionSyncBaselineCorrections = []
            return
        }

        scheduleCorrectionSyncScan(force: true, presentErrors: false)
        // The timer always starts; if the initial async scan rejects
        // the path it stops the sync (and this timer) from its
        // main-actor completion.
        correctionSyncTimer = Timer.scheduledTimer(timeInterval: 4,
                                                   target: self,
                                                   selector: #selector(correctionSyncTimerFired(_:)),
                                                   userInfo: nil,
                                                   repeats: true)
        correctionSyncTimer?.tolerance = 1
    }

    @objc private func correctionSyncTimerFired(_ timer: Timer) {
        scheduleCorrectionSyncScan(force: false, presentErrors: false)
    }

    /// What a background sync-file scan found. Built off the main
    /// thread, applied on the main actor — so it must be Sendable and
    /// carry everything the apply step needs.
    private enum CorrectionSyncScanOutcome: Sendable {
        case rejectedPath(TranscriptCorrectionsSyncPathError)
        case fingerprintUnavailable
        case unchanged
        case loaded(corrections: [TranscriptCorrection], fingerprint: CorrectionSyncFileFingerprint)
        case readFailed(logDescription: String, alertMessage: String)
    }

    /// Runs on `correctionSyncScanQueue` (hence `nonisolated`). Pure
    /// with respect to app state: everything it needs arrives as
    /// parameters and the result goes back as a value.
    private nonisolated static func performCorrectionSyncScan(url: URL,
                                                  lastFingerprint: CorrectionSyncFileFingerprint?,
                                                  force: Bool) -> CorrectionSyncScanOutcome {
        do {
            try validateCorrectionSyncPath(url)
        } catch let error as TranscriptCorrectionsSyncPathError {
            return .rejectedPath(error)
        } catch {
            // validateCorrectionSyncPath only throws
            // TranscriptCorrectionsSyncPathError today; keep the
            // catch-all defensive rather than crashing the scan.
            return .readFailed(logDescription: "\(error)",
                               alertMessage: error.localizedDescription)
        }
        guard let fingerprint = correctionSyncFingerprint(for: url) else {
            return .fingerprintUnavailable
        }
        guard force || fingerprint != lastFingerprint else { return .unchanged }
        do {
            let corrections = try TranscriptCorrectionsTransfer.read(from: url)
            return .loaded(corrections: corrections, fingerprint: fingerprint)
        } catch {
            return .readFailed(logDescription: "\(error)",
                               alertMessage: error.localizedDescription)
        }
    }

    private func scheduleCorrectionSyncScan(force: Bool, presentErrors: Bool) {
        guard let url = correctionSyncFileURL() else { return }
        // Never let scans overlap — a dataless iCloud file can block
        // one scan for many timer periods. Requests that arrive while
        // a scan is in flight are coalesced (strongest flags win) and
        // re-issued when it completes, so a user's explicit
        // "Sync Corrections Now" is never silently dropped behind a
        // stalled timer scan.
        guard !correctionSyncScanInFlight else {
            let pending = pendingCorrectionSyncScan
            pendingCorrectionSyncScan = (force: (pending?.force ?? false) || force,
                                         presentErrors: (pending?.presentErrors ?? false) || presentErrors)
            return
        }
        correctionSyncScanInFlight = true
        let lastFingerprint = correctionSyncFileFingerprint
        Self.correctionSyncScanQueue.async { [weak self] in
            let outcome = Self.performCorrectionSyncScan(url: url,
                                                         lastFingerprint: lastFingerprint,
                                                         force: force)
            Task { @MainActor in
                guard let self else { return }
                self.correctionSyncScanInFlight = false
                self.applyCorrectionSyncScanOutcome(outcome,
                                                    scannedURL: url,
                                                    scanStartFingerprint: lastFingerprint,
                                                    force: force,
                                                    presentErrors: presentErrors)
                if let pending = self.pendingCorrectionSyncScan {
                    self.pendingCorrectionSyncScan = nil
                    self.scheduleCorrectionSyncScan(force: pending.force,
                                                    presentErrors: pending.presentErrors)
                }
            }
        }
    }

    private func applyCorrectionSyncScanOutcome(_ outcome: CorrectionSyncScanOutcome,
                                                scannedURL: URL,
                                                scanStartFingerprint: CorrectionSyncFileFingerprint?,
                                                force: Bool,
                                                presentErrors: Bool) {
        // The sync file may have been disconnected or repointed while
        // the scan ran; results for a stale path must not touch
        // current state.
        guard let url = correctionSyncFileURL(), url == scannedURL else { return }

        switch outcome {
        case .rejectedPath(let error):
            handleCorrectionSyncRejectedPath(error, presentErrors: presentErrors)
        case .fingerprintUnavailable:
            if presentErrors {
                showCorrectionTransferError(title: "Sync Failed",
                                            message: "Parakey could not find the selected sync file.")
            }
        case .unchanged:
            break
        case .loaded(let corrections, let fingerprint):
            // If a local edit wrote the sync file (moving the
            // fingerprint) while the scan ran, this outcome holds
            // pre-edit content; applying it would roll the edit back
            // and rewind the baseline. Drop it — a forced scan is
            // re-issued so a "Sync Now" still completes against the
            // post-edit file.
            guard correctionSyncFileFingerprint == scanStartFingerprint else {
                if force {
                    scheduleCorrectionSyncScan(force: true, presentErrors: presentErrors)
                }
                return
            }
            // Non-forced scans only apply genuinely new content
            // (forced scans deliberately re-apply even an unchanged
            // file — that is what "Sync Now" promises).
            guard force || fingerprint != correctionSyncFileFingerprint else { return }
            isApplyingCorrectionSyncFile = true
            updateTranscriptCorrections(corrections, writeToSync: false)
            isApplyingCorrectionSyncFile = false
            correctionSyncFileFingerprint = fingerprint
            correctionSyncBaselineCorrections = normalizedTranscriptCorrections(corrections)
            log("correction sync read \(corrections.count) corrections")
        case .readFailed(let logDescription, let alertMessage):
            log("correction sync read failed: \(logDescription)")
            if presentErrors {
                showCorrectionTransferError(title: "Sync Failed", message: alertMessage)
            }
        }
    }

    @discardableResult
    private func writeCorrectionsToSyncFile(presentErrors: Bool) -> Bool {
        guard let url = correctionSyncFileURL() else { return true }
        do {
            try validateCorrectionSyncPath(url)
        } catch {
            handleCorrectionSyncRejectedPath(error, presentErrors: presentErrors)
            return false
        }
        do {
            var correctionsToWrite = normalizedTranscriptCorrections(settings.transcriptCorrections)
            if let knownFingerprint = correctionSyncFileFingerprint,
               let currentFingerprint = correctionSyncFingerprint(for: url),
               currentFingerprint != knownFingerprint {
                let remoteCorrections = try TranscriptCorrectionsTransfer.read(from: url)
                let merge = mergedTranscriptCorrectionsForSync(
                    base: correctionSyncBaselineCorrections,
                    local: correctionsToWrite,
                    remote: remoteCorrections
                )
                if !merge.conflictingSources.isEmpty {
                    stopCorrectionSyncAfterConflict(conflictingSources: merge.conflictingSources)
                    log("correction sync stopped after \(merge.conflictingSources.count) conflicting corrections")
                    return false
                }
                // Normalize (cap) the merge result BEFORE it fans out:
                // file, settings, and baseline must all hold the same
                // list. A raw over-cap merge result stored as baseline
                // made capped-out entries look like local deletions on
                // the next merge, silently removing them from the file.
                correctionsToWrite = normalizedTranscriptCorrections(merge.corrections)
                if let storeError = settings.storeTranscriptCorrections(correctionsToWrite) {
                    throw storeError
                }
            }

            let writtenData = try TranscriptCorrectionsTransfer.write(correctionsToWrite, to: url)
            // Fingerprint the exact bytes written, not a re-read of the
            // file: a sync provider replacing the file in the re-read
            // window would have its change fingerprinted as ours and
            // swallowed until the next local edit.
            correctionSyncFileFingerprint = correctionSyncFingerprint(forWrittenData: writtenData, at: url)
            correctionSyncBaselineCorrections = correctionsToWrite
            log("correction sync wrote \(correctionsToWrite.count) corrections")
            return true
        } catch {
            log("correction sync write failed: \(error)")
            if presentErrors {
                showCorrectionTransferError(title: "Sync Failed", error: error)
            }
            return false
        }
    }

    private func handleCorrectionSyncRejectedPath(_ error: Error, presentErrors: Bool) {
        log("correction sync rejected path: \(error)")
        guard shouldStopCorrectionSync(afterPathValidationError: error) else {
            if presentErrors {
                showCorrectionTransferError(title: "Sync Failed", error: error)
            }
            return
        }

        stopCorrectionSyncAfterRejectedPath(error: error, presentErrors: presentErrors)
    }

    private func stopCorrectionSyncAfterConflict(conflictingSources: [String]) {
        settings.transcriptCorrectionsSyncFile = ""
        correctionSyncTimer?.invalidate()
        correctionSyncTimer = nil
        correctionSyncFileFingerprint = nil
        correctionSyncBaselineCorrections = []
        rebuildMenu()

        let exampleCount = min(conflictingSources.count, 3)
        let examples = conflictingSources.prefix(exampleCount).joined(separator: "\n")
        let remaining = conflictingSources.count - exampleCount
        let remainingText = remaining > 0 ? "\n…and \(remaining) more." : ""
        showAppForModal()
        showCorrectionTransferError(
            title: "Text Correction Sync Conflict",
            message: """
            The sync file changed before this Mac wrote its latest text correction edits. Parakey kept the corrections on this Mac and stopped syncing so it would not overwrite the file.

            Reconnect the sync file after importing or resolving the conflicting correction\(conflictingSources.count == 1 ? "" : "s"):
            \(examples)\(remainingText)
            """
        )
    }

    private func stopCorrectionSyncAfterRejectedPath(error: Error, presentErrors: Bool) {
        settings.transcriptCorrectionsSyncFile = ""
        correctionSyncTimer?.invalidate()
        correctionSyncTimer = nil
        correctionSyncFileFingerprint = nil
        correctionSyncBaselineCorrections = []
        log("correction sync stopped after rejected path")
        rebuildMenu()

        if presentErrors {
            showCorrectionTransferError(
                title: "Text Correction Sync Stopped",
                message: """
                Parakey stopped syncing because the selected corrections file is no longer safe to use.

                \(error.localizedDescription)
                """
            )
        }
    }

    private func showCorrectionTransferError(title: String, error: Error) {
        showCorrectionTransferError(title: title, message: error.localizedDescription)
    }

    private func showCorrectionTransferError(title: String, message: String) {
        showAppForModal()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showCorrectionEditor(existing: TranscriptCorrection?,
                                      prefillSource: String = "") -> TranscriptCorrection? {
        showAppForModal()
        let alert = NSAlert()
        alert.messageText = existing == nil ? "Add Text Correction" : "Edit Text Correction"
        alert.informativeText = "Add the incorrect text Parakey typed, then the text it should paste instead."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let viewWidth: CGFloat = 520
        let labelHeight: CGFloat = 18
        let fieldHeight: CGFloat = 76
        let viewHeight: CGFloat = (labelHeight * 2) + (fieldHeight * 2) + 24
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: viewWidth, height: viewHeight))

        let sourceLabel = NSTextField(labelWithString: "Typed")
        sourceLabel.font = .systemFont(ofSize: 12, weight: .medium)
        sourceLabel.frame = NSRect(x: 0, y: viewHeight - labelHeight, width: viewWidth, height: labelHeight)

        let sourceEditor = correctionTextEditor(
            frame: NSRect(x: 0, y: viewHeight - labelHeight - fieldHeight, width: viewWidth, height: fieldHeight),
            text: existing?.source ?? prefillSource.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        let replacementLabel = NSTextField(labelWithString: "Paste")
        replacementLabel.font = .systemFont(ofSize: 12, weight: .medium)
        replacementLabel.frame = NSRect(x: 0, y: fieldHeight + 6, width: viewWidth, height: labelHeight)

        let replacementEditor = correctionTextEditor(
            frame: NSRect(x: 0, y: 0, width: viewWidth, height: fieldHeight),
            text: existing?.replacement ?? ""
        )

        accessory.addSubview(sourceLabel)
        accessory.addSubview(sourceEditor.scrollView)
        accessory.addSubview(replacementLabel)
        accessory.addSubview(replacementEditor.scrollView)
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = sourceEditor.textView

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        let source = sourceEditor.textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = replacementEditor.textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !replacement.isEmpty else {
            showCorrectionValidationError()
            return nil
        }

        return TranscriptCorrection(source: source, replacement: replacement)
    }

    private func correctionTextEditor(frame: NSRect, text: String) -> (scrollView: NSScrollView, textView: NSTextView) {
        let scroll = NSScrollView(frame: frame)
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: frame.width, height: frame.height))
        textView.font = .systemFont(ofSize: 13)
        textView.string = text
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 6, height: 5)
        textView.minSize = NSSize(width: 0, height: frame.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: frame.width,
                                                       height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = textView
        return (scroll, textView)
    }

    private func showCorrectionValidationError() {
        showAppForModal()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Correction Not Saved"
        alert.informativeText = "Both fields need text."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func saveCorrection(_ correction: TranscriptCorrection, replacing index: Int? = nil) {
        var corrections = settings.transcriptCorrections
        let key = normalizedTranscriptCorrectionSource(correction.source)

        if let index, corrections.indices.contains(index) {
            corrections[index] = correction
            var keepIndex = index
            for i in corrections.indices.reversed() {
                guard i != keepIndex, normalizedTranscriptCorrectionSource(corrections[i].source) == key else { continue }
                corrections.remove(at: i)
                if i < keepIndex { keepIndex -= 1 }
            }
        } else if let duplicate = corrections.firstIndex(where: { normalizedTranscriptCorrectionSource($0.source) == key }) {
            corrections[duplicate] = correction
        } else {
            corrections.append(correction)
        }

        updateTranscriptCorrections(corrections)
    }

    @objc private func selectHotkey(_ sender: NSMenuItem) {
        guard let kc = sender.representedObject as? Int else { return }
        _ = applyHotkeyChoice(hotkeyChoice(forKeycode: CGKeyCode(kc)))
    }

    @objc private func recordHotkeyClicked(_ sender: NSMenuItem) {
        showHotkeyRecorder()
    }

    @objc private func resetHotkeyClicked(_ sender: NSMenuItem) {
        if applyHotkeyChoice(hotkeyChoice(forKeycode: DEFAULT_HOTKEY_KEYCODE)) {
            log("HotkeyListener: reset hotkey to default")
        }
    }

    private func applyHotkeyChoice(_ choice: HotkeyChoice) -> Bool {
        let previous = hotkey.hotkey

        guard let recordable = recordableHotkeyChoice(forKeycode: choice.keycode,
                                                      modifiers: choice.requiredModifiers) else {
            if case .rejected(let message) = hotkeyPreferenceUpdateResult(
                requested: choice,
                previous: previous,
                persisted: previous
            ) {
                showHotkeyRecordError(message)
            }
            return false
        }

        settings.setConfiguredHotkey(recordable)
        hotkey.setHotkey(recordable)
        hotkeyTestSucceeded = false

        switch hotkeyPreferenceUpdateResult(
            requested: recordable,
            previous: previous,
            persisted: settings.configuredHotkey
        ) {
        case .saved:
            rebuildMenu()
            updateSetupChecklist()
            return true
        case .rejected(let message):
            showHotkeyRecordError(message)
            return false
        case .rolledBack(let previous, let message):
            settings.setConfiguredHotkey(previous)
            hotkey.setHotkey(previous)
            showHotkeyRecordError(message)
            rebuildMenu()
            return false
        }
    }

    private func showHotkeyRecorder() {
        guard !isRecording, !isBusy, !isTerminating else { return }
        if let hotkeyRecorder {
            hotkeyRecorder.present()
            return
        }
        showAppForModal()

        let shouldRestoreHotkeyTap = isReady
        if shouldRestoreHotkeyTap {
            hotkey.stop()
        }

        let recorder = HotkeyRecorderController(language: settings.interfaceLanguage) { [weak self] selected in
            guard let self else { return }
            self.hotkeyRecorder = nil
            let restartSucceeded: Bool
            if shouldRestoreHotkeyTap && !self.isTerminating {
                restartSucceeded = self.hotkey.start()
            } else {
                restartSucceeded = false
            }
            switch hotkeyRecorderRestartAction(
                shouldRestoreHotkeyTap: shouldRestoreHotkeyTap,
                isTerminating: self.isTerminating,
                restartSucceeded: restartSucceeded
            ) {
            case .none, .restoredListener:
                break
            case .recordFailure:
                self.recordStartupFailure(
                    stage: .hotkeyListener,
                    error: NSError(
                        domain: "Parakey",
                        code: -5,
                        userInfo: [
                            NSLocalizedDescriptionKey: "The hotkey listener could not restart after recording a hotkey."
                        ]
                    ),
                    reason: "hotkey recorder"
                )
            }
            guard let selected else { return }
            if self.applyHotkeyChoice(selected) {
                log("HotkeyListener: recorded hotkey → \(selected.name)")
            }
        }
        hotkeyRecorder = recorder
        recorder.present()
    }

    private func showHotkeyRecordError(_ message: String) {
        showAppForModal()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Hotkey Not Changed"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func selectTriggerMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let m = TriggerMode(rawValue: raw) else { return }
        settings.triggerMode = m
        hotkey.setTriggerMode(m)
        rebuildMenu()
    }

    @objc private func selectPasteSuffix(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let suffix = PasteSuffix(rawValue: raw) else { return }
        settings.pasteSuffix = suffix
        rebuildMenu()
    }

    @objc private func selectDictationLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let lang = DictationLanguage(rawValue: raw) else { return }
        settings.dictationLanguage = lang
        rebuildMenu()
    }

    @objc private func selectRecentTranscriptLimit(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let limit = RecentTranscriptLimit(rawValue: raw) else { return }
        settings.recentTranscriptLimit = limit
        applyRecentTranscriptLimit()
        rebuildMenu()
    }

    @objc private func toggleRecordingWaveform(_ sender: NSMenuItem) {
        settings.showRecordingWaveform.toggle()
        sender.state = settings.showRecordingWaveform ? .on : .off
        if settings.showRecordingWaveform, isRecording {
            showRecordingHUD(mode: .recording, level: recordingVisualLevel)
        } else {
            hideRecordingHUD()
        }
    }

    @objc private func toggleMute(_ sender: NSMenuItem) {
        settings.muteWhileRecording.toggle()
        sender.state = settings.muteWhileRecording ? .on : .off
    }

    @objc private func toggleRemoveFillerWords(_ sender: NSMenuItem) {
        settings.removeFillerWords.toggle()
        sender.state = settings.removeFillerWords ? .on : .off
    }

    @objc private func toggleFeedbackSounds(_ sender: NSMenuItem) {
        settings.playFeedbackSounds.toggle()
        sender.state = settings.playFeedbackSounds ? .on : .off
    }

    @objc private func toggleDock(_ sender: NSMenuItem) {
        settings.showInDock.toggle()
        sender.state = settings.showInDock ? .on : .off
        refreshActivationPolicy()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            switch SMAppService.mainApp.status {
            case .enabled, .requiresApproval:
                try SMAppService.mainApp.unregister()
                log("launch at login disabled")
            default:
                try SMAppService.mainApp.register()
                log("launch at login enabled")
            }
        } catch {
            showLaunchAtLoginError(error)
        }
        rebuildMenu()
    }

    private func ensureLaunchAtLoginEnabled() {
        switch SMAppService.mainApp.status {
        case .enabled:
            return
        case .requiresApproval:
            log("launch at login requires user approval")
        default:
            do {
                try SMAppService.mainApp.register()
                log("launch at login auto-enabled")
            } catch {
                log("launch at login auto-enable failed: \(error.localizedDescription)")
            }
        }
    }

    private func showLaunchAtLoginError(_ error: Error) {
        showAppForModal()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Launch at Login couldn't be changed"
        alert.informativeText = "\(error)"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func toggleCheckForUpdates(_ sender: NSMenuItem) {
        settings.checkForUpdates.toggle()
        sender.state = settings.checkForUpdates ? .on : .off
        log("update notifications \(settings.checkForUpdates ? "enabled" : "disabled")")
        if settings.checkForUpdates {
            Task { [weak self] in
                await self?.tickUpdateCheck(source: .settingsToggle)
            }
        } else {
            pendingUpdate = nil
            clearUpdateReminderPause()
            rebuildMenu()
        }
    }

    @objc private func resetSpeechModelCacheClicked(_ sender: NSMenuItem) {
        guard !isRecording,
              !isBusy,
              startupTask == nil,
              !isResettingSpeechModelCache,
              !isSwitchingSpeechModel,
              !isTerminating else { return }

        showAppForModal()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Reset Speech Model Cache?"
        let profile = settings.speechModelProfile
        alert.informativeText = profile.cacheResetDetail
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        isResettingSpeechModelCache = true
        prepareForStartupAttempt()
        startupStatusTitle = "Resetting speech model cache…"
        log("ASR: \(profile.shortName) cache reset started")
        rebuildMenu()

        Task { @MainActor in
            await asr.unload()
            let cacheDir = speechModelCacheDirectory(for: profile)
            do {
                let didRemoveCache = try await removeSpeechModelCacheDirectory(cacheDir)
                if didRemoveCache {
                    log("ASR: removed \(profile.shortName) cache \(privacySafeLogPath(cacheDir))")
                } else {
                    log("ASR: \(profile.shortName) cache reset requested; cache was already absent")
                }
                isResettingSpeechModelCache = false
                startStartup(reason: "speech model cache reset")
            } catch {
                isResettingSpeechModelCache = false
                log("ASR: speech model cache reset failed: \(error)")
                showSpeechModelCacheResetError(error)
                startStartup(reason: "speech model cache reset recovery")
            }
        }
    }

    private func showSpeechModelCacheResetError(_ error: Error) {
        showAppForModal()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Speech model cache couldn't be reset"
        alert.informativeText = "\(error)"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - About dialog

    @objc private func showAboutClicked(_ sender: NSMenuItem) {
        showAppForModal()
        let alert = NSAlert()
        alert.messageText = "SuperDictate \(currentBundleVersion())"
        alert.informativeText = """
            Lightweight push-to-talk dictation for Apple Silicon Macs.

            Hotkey:  \(hotkey.hotkey.name)
            Mode:    \(TRIGGER_DISPLAY[settings.triggerMode] ?? settings.triggerMode.rawValue)
            Model:   \(settings.speechModelProfile.aboutModelText)

            Local-only dictation. No cloud transcription, no telemetry.
            Network: model download, optional update check and install.
            Permissions: microphone audio, paste-at-cursor, push-to-talk hotkey.

            Open source, based on Parakey by Richard Courtman.
            github.com/shlgd/SuperDictate · MIT licensed
            """
        // Use our app icon instead of NSAlert's default exclamation
        // mark. .icns lives in Contents/Resources/Parakey.icns;
        // NSImage(named:) on Bundle.main resolves it by filename
        // sans extension.
        if let icon = NSImage(named: "Parakey") {
            alert.icon = icon
        }
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "View on GitHub")
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(GITHUB_REPOSITORY_PAGE)
        }
    }

    // MARK: - Update flow

    private func startUpdateCheckLoop() {
        guard updateCheckLoopTask == nil else { return }
        updateCheckLoopTask = Task.detached { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(UPDATE_CHECK_FIRST_DELAY_SECONDS * 1_000_000_000))
            while !Task.isCancelled {
                await self?.tickUpdateCheck()
                try? await Task.sleep(nanoseconds: UInt64(UPDATE_CHECK_INTERVAL_SECONDS * 1_000_000_000))
            }
        }
    }

    /// Silent update check: failures are recorded in diagnostics but
    /// never alerted. `source` distinguishes the periodic timer tick
    /// from the user re-enabling the settings toggle.
    private func tickUpdateCheck(source: UpdateCheckSource = .automatic) async {
        guard settings.checkForUpdates else { return }
        let outcome = await UpdateCheck.fetchLatest()
        await MainActor.run {
            self.recordUpdateCheck(release: try? outcome.get(), source: source)
            guard let release = try? outcome.get() else { return }
            self.handleFetchedRelease(release)
        }
    }

    private func recordUpdateCheck(release: GitHubRelease?, source: UpdateCheckSource) {
        let skippedVersions = source == .manual ? [] : settings.skippedVersions
        let result = updateCheckResult(
            for: release,
            currentVersion: currentBundleVersion(),
            skippedVersions: skippedVersions
        )
        settings.lastUpdateCheckAt = Date()
        settings.lastUpdateCheckSource = source
        settings.lastUpdateCheckResult = result
        settings.lastUpdateCheckVersion = release?.version ?? ""

        let versionText = release.map { " v\($0.version)" } ?? ""
        log("update check \(source.rawValue): \(result.rawValue)\(versionText)")
    }

    private func handleFetchedRelease(_ release: GitHubRelease) {
        let current = currentBundleVersion()
        guard isNewer(release.version, than: current) else { return }
        if settings.skippedVersions.contains(release.version) {
            log("update available (v\(release.version)) but user skipped — staying quiet")
            return
        }
        let now = Date()
        if shouldSuppressUpdateForReminder(version: release.version,
                                           reminderVersion: reminderPausedUpdateVersion,
                                           reminderUntil: reminderPausedUntil,
                                           now: now) {
            if let reminderPausedUntil {
                log("update available (v\(release.version)) but reminder is paused until \(ISO8601DateFormatter().string(from: reminderPausedUntil))")
            }
            return
        }
        // Same version → the pause expired and the update is re-shown.
        // Newer version → it supersedes the paused one, so the stale
        // pause must not linger in diagnostics alongside the new
        // pending update. (An ACTIVE pause for this exact version
        // already returned above.)
        if shouldClearUpdateReminderPause(fetchedVersion: release.version,
                                          pausedVersion: reminderPausedUpdateVersion) {
            clearUpdateReminderPause()
        }
        log("update available: \(current) → v\(release.version)")
        pendingUpdate = release
        rebuildMenu()
    }


    private func buildUpdateItem(for release: GitHubRelease) -> NSMenuItem {
        let parent = NSMenuItem(title: "Update to v\(release.version)",
                                action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false

        let whatsNew = NSMenuItem(title: "What's new…",
                                  action: #selector(whatsNewClicked(_:)),
                                  keyEquivalent: "")
        whatsNew.target = self
        sub.addItem(whatsNew)

        let updateNow = NSMenuItem(title: "Update now…",
                                   action: #selector(updateNowClicked(_:)),
                                   keyEquivalent: "")
        updateNow.target = self
        sub.addItem(updateNow)

        let remindLater = NSMenuItem(title: "Remind me in 24 hours",
                                     action: #selector(remindMeLaterClicked(_:)),
                                     keyEquivalent: "")
        remindLater.target = self
        sub.addItem(remindLater)

        let skip = NSMenuItem(title: "Skip v\(release.version)",
                              action: #selector(skipVersionClicked(_:)),
                              keyEquivalent: "")
        skip.target = self
        sub.addItem(skip)

        parent.submenu = sub
        return parent
    }

    private func showReleaseNotes(for release: GitHubRelease) {
        showAppForModal()
        let alert = NSAlert()
        alert.messageText = "Parakey v\(release.version)"
        var body = release.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty { body = "(No release notes available for this version.)" }
        else if body.count > 1500 { body = String(body.prefix(1500)) + "\n\n…" }
        alert.informativeText = body
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Open in Browser")
        let response = alert.runModal()
        if response == .alertSecondButtonReturn,
           let url = URL(string: release.htmlURL) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func whatsNewClicked(_ sender: NSMenuItem) {
        guard let release = pendingUpdate else { return }
        showReleaseNotes(for: release)
    }

    @objc private func updateNowClicked(_ sender: NSMenuItem) {
        guard let release = pendingUpdate else { return }
        startUpdate(for: release)
    }

    @objc private func remindMeLaterClicked(_ sender: NSMenuItem) {
        guard let release = pendingUpdate else { return }
        pauseUpdateReminder(for: release)
    }

    @objc private func skipVersionClicked(_ sender: NSMenuItem) {
        guard let release = pendingUpdate else { return }
        var skipped = settings.skippedVersions
        if !skipped.contains(release.version) {
            skipped.append(release.version)
            settings.skippedVersions = skipped
            log("user skipped v\(release.version); suppressing until a newer release")
        }
        pendingUpdate = nil
        clearUpdateReminderPause()
        rebuildMenu()
    }

    @objc private func checkForUpdatesClicked(_ sender: NSMenuItem) {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        rebuildMenu()
        manualUpdateCheckTask = Task { [weak self] in
            let outcome = await UpdateCheck.fetchLatest()
            guard !Task.isCancelled,
                  let self,
                  !self.isTerminating else { return }
            self.manualUpdateCheckTask = nil
            self.recordUpdateCheck(release: try? outcome.get(), source: .manual)
            self.finishManualUpdateCheck(outcome)
        }
    }

    private func finishManualUpdateCheck(_ outcome: Result<GitHubRelease, UpdateCheckFailure>) {
        manualUpdateCheckTask = nil
        isCheckingForUpdates = false
        let release: GitHubRelease
        switch outcome {
        case .failure(let failure):
            rebuildMenu()
            showUpdateCheckFailedAlert(failure)
            return
        case .success(let fetched):
            release = fetched
        }

        let current = currentBundleVersion()
        guard isNewer(release.version, than: current) else {
            if pendingUpdate?.version == release.version {
                pendingUpdate = nil
            }
            rebuildMenu()
            showUpToDateAlert(currentVersion: current)
            return
        }

        if settings.skippedVersions.contains(release.version) {
            settings.skippedVersions = settings.skippedVersions.filter { $0 != release.version }
        }
        clearUpdateReminderPause()
        pendingUpdate = release
        rebuildMenu()
        showUpdateAvailableAlert(for: release, currentVersion: current)
    }

    private func showUpdateAvailableAlert(for release: GitHubRelease, currentVersion: String) {
        showAppForModal()
        let alert = NSAlert()
        alert.messageText = "Parakey v\(release.version) is available"
        alert.informativeText = "You're running v\(currentVersion). Nothing is installed unless you choose Update Now."
        alert.addButton(withTitle: "Update Now")
        alert.addButton(withTitle: "What's New")
        // Dismissing pauses reminders for 24 h (and hides the update
        // menu item), so the button must say so — "Later" implied a
        // consequence-free dismissal.
        alert.addButton(withTitle: "Remind Me in 24 Hours")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            startUpdate(for: release)
        } else if response == .alertSecondButtonReturn {
            showReleaseNotes(for: release)
        } else {
            pauseUpdateReminder(for: release)
        }
    }

    private func pauseUpdateReminder(for release: GitHubRelease) {
        setUpdateReminderPause(version: release.version,
                               until: Date().addingTimeInterval(UPDATE_REMIND_LATER_SECONDS))
        pendingUpdate = nil
        if let reminderPausedUntil {
            log("user chose remind later for v\(release.version); paused until \(ISO8601DateFormatter().string(from: reminderPausedUntil))")
        }
        rebuildMenu()
    }

    // MARK: "Remind me later" pause state
    //
    // The in-memory fields drive menu/diagnostics decisions; the
    // Settings copies survive relaunches. The pause used to be
    // memory-only, so quitting inside the 24 h window re-prompted the
    // user ~30 s after the next launch. These two helpers are the ONLY
    // write paths so memory and defaults can never disagree.

    private func setUpdateReminderPause(version: String, until: Date) {
        reminderPausedUpdateVersion = version
        reminderPausedUntil = until
        settings.updateReminderPausedVersion = version
        settings.updateReminderPausedUntil = until
    }

    private func clearUpdateReminderPause() {
        reminderPausedUpdateVersion = nil
        reminderPausedUntil = nil
        settings.updateReminderPausedVersion = nil
        settings.updateReminderPausedUntil = nil
    }

    /// Restores a persisted pause at launch. Either half missing or
    /// corrupt (the validated Settings accessors degrade those to nil)
    /// means no pause: clear the leftover half rather than carrying
    /// incoherent state.
    private func restoreUpdateReminderPause() {
        guard let version = settings.updateReminderPausedVersion,
              let until = settings.updateReminderPausedUntil else {
            clearUpdateReminderPause()
            return
        }
        reminderPausedUpdateVersion = version
        reminderPausedUntil = until
    }

    private func showUpToDateAlert(currentVersion: String) {
        showAppForModal()
        let alert = NSAlert()
        alert.messageText = "Parakey is up to date"
        alert.informativeText = "You're running v\(currentVersion)."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showUpdateCheckFailedAlert(_ failure: UpdateCheckFailure) {
        showAppForModal()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't check for updates"
        alert.informativeText = manualUpdateCheckFailureText(failure)
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func startUpdate(for release: GitHubRelease) {
        showManualUpdateRequired(
            for: release,
            reason: "The public source build updates by running the installer again."
        )
    }

    private func showManualUpdateRequired(for release: GitHubRelease, reason: String) {
        log("update click: manual update required: \(reason)")
        showAppForModal()
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Manual update needed"
        alert.informativeText = """
        \(reason)

        To update, run this command in Terminal:

        curl -fsSL https://raw.githubusercontent.com/shlgd/SuperDictate/main/install.sh | bash
        """
        alert.addButton(withTitle: "Open Release Page")
        alert.addButton(withTitle: "Close")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn,
           let url = URL(string: release.htmlURL) {
            NSWorkspace.shared.open(url)
        }
    }

    private func showUpdateCouldNotStart(detail: String) {
        log("update: could not start helper: \(detail)")
        showAppForModal()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Update couldn't start"
        alert.informativeText = """
        \(detail)

        You can update from Terminal:

        curl -fsSL https://raw.githubusercontent.com/shlgd/SuperDictate/main/install.sh | bash
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// `brew list --cask` routinely takes seconds. With the active
    /// session-wide event tap on the main run loop, a synchronous
    /// waitUntilExit() here would stall every keystroke system-wide
    /// (and a >1 s stall makes macOS disable the tap), so the check
    /// runs on a background queue and reports back to the main actor.
    private static let brewPreflightQueue = DispatchQueue(label: "ParakeyBrewPreflight",
                                                          qos: .userInitiated)

    private func isBrewInstall(brewPath: String,
                               completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard Bundle.main.bundlePath == INSTALLED_APP_BUNDLE_PATH else {
            completion(false)
            return
        }

        Self.brewPreflightQueue.async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: brewPath)
            proc.arguments = ["list", "--cask", "--versions", HOMEBREW_CASK_INSTALLED_TOKEN]
            proc.environment = updateProcessEnvironment()
            proc.standardOutput = Pipe()
            proc.standardError = Pipe()
            let isBrewManaged: Bool
            do {
                try proc.run()
                proc.waitUntilExit()
                isBrewManaged = proc.terminationStatus == 0
            } catch {
                log("update: brew install check failed: \(error)")
                isBrewManaged = false
            }
            Task { @MainActor in completion(isBrewManaged) }
        }
    }

    private func findBrew() -> String? {
        for path in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    private func launchUpdateProgressApp(statePath: String,
                                         logPath: String,
                                         targetVersion: String) throws -> String {
        let sourceAppURL = Bundle.main.bundleURL
        guard sourceAppURL.pathExtension == "app",
              let executableName = Bundle.main.executableURL?.lastPathComponent else {
            throw posixError(EINVAL)
        }

        let progressAppURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("\(UPDATE_PROGRESS_APP_PREFIX)\(UUID().uuidString).app",
                                    isDirectory: true)
        try FileManager.default.copyItem(at: sourceAppURL, to: progressAppURL)

        let executableURL = progressAppURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent(executableName)

        let proc = Process()
        proc.executableURL = executableURL
        proc.arguments = [
            UPDATE_PROGRESS_ARGUMENT,
            statePath,
            logPath,
            targetVersion,
            progressAppURL.path,
        ]
        proc.environment = systemToolProcessEnvironment()

        do {
            try proc.run()
            return progressAppURL.path
        } catch {
            try? FileManager.default.removeItem(at: progressAppURL)
            throw error
        }
    }

    private func spawnUpdateHelper(brewPath: String, targetVersion: String) {
        let statePath: String
        do {
            statePath = try createPrivateUpdateProgressStateFile()
        } catch {
            log("update: creating progress state failed: \(error.localizedDescription)")
            showUpdateCouldNotStart(detail: "Parakey couldn't prepare the update progress window.")
            return
        }

        // Detached shell helper refreshes Homebrew, downloads the cask,
        // waits for THIS process to exit, upgrades/reinstalls the app,
        // verifies the installed bundle version, then re-opens
        // /Applications/SuperDictate.app. We can't run the install step
        // in-process because it replaces the bundle we're executing from.
        let script = updateHelperScript(pid: getpid(),
                                        brewPath: brewPath,
                                        targetVersion: targetVersion,
                                        statePath: statePath)
        // Use NSTemporaryDirectory() (per-user, typically /var/folders/…/T/)
        // instead of /tmp, and create the script with O_EXCL/O_NOFOLLOW at
        // mode 0600 so an existing leaf path is never overwritten or followed.
        // bash is invoked as `/bin/bash <path>` so the execute bit is not
        // required.
        let helperPath: String
        do {
            helperPath = try writePrivateUpdateHelperScript(script)
        } catch {
            try? FileManager.default.removeItem(atPath: statePath)
            log("update: writing helper failed: \(error.localizedDescription)")
            showUpdateCouldNotStart(detail: "Parakey couldn't write the update helper script.")
            return
        }
        let helperLog: PrivateOutputFile
        do {
            helperLog = try openPrivateUpdateHelperLog()
        } catch {
            try? FileManager.default.removeItem(atPath: helperPath)
            try? FileManager.default.removeItem(atPath: statePath)
            log("update: opening helper log failed: \(error.localizedDescription)")
            showUpdateCouldNotStart(detail: "Parakey couldn't open the update helper log.")
            return
        }

        let progressAppPath: String
        do {
            progressAppPath = try launchUpdateProgressApp(statePath: statePath,
                                                          logPath: helperLog.path,
                                                          targetVersion: targetVersion)
        } catch {
            try? FileManager.default.removeItem(atPath: helperPath)
            try? FileManager.default.removeItem(atPath: statePath)
            helperLog.handle.closeFile()
            log("update: launching progress app failed: \(error.localizedDescription)")
            showUpdateCouldNotStart(detail: "Parakey couldn't open the update progress window.")
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [helperPath]
        proc.environment = updateProcessEnvironment()
        proc.standardOutput = helperLog.handle
        proc.standardError = helperLog.handle
        do {
            try proc.run()
        } catch {
            try? FileManager.default.removeItem(atPath: helperPath)
            helperLog.handle.closeFile()
            try? writePrivateUpdateProgressState(phase: "failed",
                                                 message: "Parakey couldn't launch the update helper.",
                                                 to: statePath)
            showUpdateCouldNotStart(detail: "Parakey couldn't launch the update helper.")
            return
        }
        log("update helper spawned \(privacySafeLogPath(helperPath)), progress app \(privacySafeLogPath(progressAppPath)), logging to \(privacySafeLogPath(helperLog.path)); quitting for upgrade")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
    }

    // MARK: - TCC stale-state recovery on upgrade

    private func recoverStaleTCCAfterUpgrade() {
        let last = settings.lastSeenVersion
        let current = currentBundleVersion()
        guard !last.isEmpty else {
            // First-ever launch — just record the version. No state
            // to recover.
            settings.lastSeenVersion = current
            return
        }
        guard last != current else { return }
        log("upgrade detected: \(last) → \(current); checking for stale TCC state")
        let bundleID = Bundle.main.bundleIdentifier ?? "com.local.superdictate"
        for p in Permission.allCases {
            if Permissions.isGranted(p) { continue }
            // Fire-and-forget on TCC's serial queue: these resets are
            // best-effort scrubbing of stale DENIED entries, nothing
            // at launch depends on their completion, and the user's
            // first Grant click has its own reset-and-retry path.
            TCC.reset(p, bundleID: bundleID)
        }
        settings.lastSeenVersion = current
    }
}

// MARK: - Entry point

#if DEBUG
private enum SelfTestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

private enum ParakeySelfTest {
    static func run(arguments: [String]) -> Int32? {
        guard arguments.count >= 2, arguments[0] == "--self-test" else { return nil }
        guard arguments.count == 2 else { return fail("usage") }

        switch arguments[1] {
        case "hotkey":
            return runSuite("hotkey", testHotkey)
        case "readiness":
            return runSuite("readiness", testReadiness)
        case "paste":
            return runSuite("paste", testPasteSuffixFormatting)
        case "history":
            return runSuite("history", testRecentTranscriptLimit)
        case "statistics":
            return runSuite("statistics", testDictationUsageStatistics)
        case "corrections":
            return runSuite("corrections", testTranscriptCorrections)
        case "fillers":
            return runSuite("fillers", testFillerWordRemoval)
        case "audio-level":
            return runSuite("audio-level", testAudioLevelMetering)
        case "audio-conversion":
            return runSuite("audio-conversion", testAudioConversion)
        case "audio-input":
            return runSuite("audio-input", testAudioInputDeviceFiltering)
        case "model-status":
            return runSuite("model-status", testSpeechModelStartupStatus)
        case "audio-route":
            return runSuite("audio-route", testAudioRouteChangeDecision)
        case "recording-lifecycle":
            return runSuite("recording-lifecycle", testRecordingLifecycle)
        case "power-state":
            return runSuite("power-state", testPowerStateRecoveryDecision)
        case "model-integrity":
            return runSuite("model-integrity", testModelIntegrity)
        case "update":
            return runSuite("update", testUpdate)
        case "hostile-env":
            return runSuite("hostile-env", testHostileRegistryEnvDetection)
        case "logging":
            return runSuite("logging", testPrivateLogAppend)
        case "diagnostics":
            return runSuite("diagnostics", testDiagnostics)
        case "insertion-target":
            return runSuite("insertion-target", testInsertionTargetTracking)
        case "insertion-target-live":
            return runSuite("insertion-target-live", testLiveInsertionTargetProbe)
        case "all":
            return runSuite("all", testAll)
        default:
            return fail("unknown")
        }
    }

    private static func runSuite(_ name: String, _ body: () throws -> Void) -> Int32 {
        do {
            try body()
            print("PASS \(name)")
            return EXIT_SUCCESS
        } catch {
            print("FAIL \(name): \(error)")
            return EXIT_FAILURE
        }
    }

    private static func fail(_ message: String) -> Int32 {
        print("FAIL self-test: \(message)")
        return EXIT_FAILURE
    }

    private static func testAll() throws {
        try testHotkey()
        try testReadiness()
        try testPasteSuffixFormatting()
        try testRecentTranscriptLimit()
        try testDictationUsageStatistics()
        try testTranscriptCorrections()
        try testFillerWordRemoval()
        try testAudioLevelMetering()
        try testAudioConversion()
        try testAudioInputDeviceFiltering()
        try testSpeechModelStartupStatus()
        try testAudioRouteChangeDecision()
        try testRecordingLifecycle()
        try testPowerStateRecoveryDecision()
        try testModelIntegrity()
        try testUpdate()
        try testHostileRegistryEnvDetection()
        try testPrivateLogAppend()
        try testDiagnostics()
        try testInsertionTargetTracking()
    }

    private static func testInsertionTargetTracking() throws {
        func target(pid: pid_t, window: UInt, element: UInt) -> FocusedInsertionTargetFrame {
            FocusedInsertionTargetFrame(
                frame: NSRect(x: 100, y: 100, width: 2, height: 18),
                visualFrame: NSRect(x: 80, y: 80, width: 300, height: 48),
                resolutionKind: "self-test",
                identity: FocusedInsertionTargetIdentity(
                    applicationPID: pid,
                    windowToken: window,
                    elementToken: element
                )
            )
        }

        let first = target(pid: 10, window: 1, element: 1)
        let secondField = target(pid: 10, window: 1, element: 2)
        let otherApp = target(pid: 20, window: 2, element: 1)
        var stabilizer = RecordingHUDTargetStabilizer()
        stabilizer.reset(initialApplicationPID: 10)

        switch stabilizer.observe(first) {
        case .switchTarget(let accepted):
            try expect(accepted.identity, equals: first.identity,
                       "initial target from the starting app should be accepted immediately")
        default:
            throw SelfTestFailure.failed("initial insertion target was not accepted")
        }

        switch stabilizer.observe(first) {
        case .update(let accepted):
            try expect(accepted.identity, equals: first.identity,
                       "the confirmed insertion target should update without another switch")
        default:
            throw SelfTestFailure.failed("confirmed insertion target did not produce an update")
        }

        if case .none = stabilizer.observe(secondField) {
            // Expected: a new field in the same app needs two matching observations.
        } else {
            throw SelfTestFailure.failed("same-app target switched without confirmation")
        }
        switch stabilizer.observe(secondField) {
        case .switchTarget(let accepted):
            try expect(accepted.identity, equals: secondField.identity,
                       "same-app target should switch after confirmation")
        default:
            throw SelfTestFailure.failed("same-app target did not switch after confirmation")
        }

        for attempt in 1...2 {
            if case .none = stabilizer.observe(otherApp) {
                continue
            }
            throw SelfTestFailure.failed("cross-app target switched on observation \(attempt)")
        }
        switch stabilizer.observe(otherApp) {
        case .switchTarget(let accepted):
            try expect(accepted.identity, equals: otherApp.identity,
                       "cross-app target should switch after three stable observations")
        default:
            throw SelfTestFailure.failed("cross-app target did not switch after confirmation")
        }

        if case .none = stabilizer.observe(nil) {
            // A missing AX sample must not discard the confirmed target.
        } else {
            throw SelfTestFailure.failed("missing target unexpectedly changed HUD ownership")
        }
        switch stabilizer.observe(otherApp) {
        case .update:
            break
        default:
            throw SelfTestFailure.failed("confirmed target was lost after one missing AX sample")
        }

        let screen = InsertionTargetScreenGeometry(
            frame: NSRect(x: 0, y: 0, width: 1_920, height: 1_080),
            visibleFrame: NSRect(x: 0, y: 0, width: 1_920, height: 1_055)
        )
        let context = InsertionTargetQueryContext(
            applicationPID: 10,
            applicationName: "self-test",
            bundleIdentifier: "self-test",
            screens: [screen],
            coordinateReferenceMaxY: screen.frame.maxY,
            lastClickPoint: nil
        )
        let documentFrame = NSRect(x: 560, y: 150, width: 946, height: 698)
        let caretFrame = NSRect(x: 582, y: 419, width: 2, height: 17)
        let documentVisualFrame = FocusedInsertionTargetLocator.visualTargetFrame(
            elementFrame: documentFrame,
            caretFrame: caretFrame,
            context: context
        )
        try expect(documentVisualFrame.minX, equals: documentFrame.minX,
                   "large editors should retain their block's left edge")
        try expect(documentVisualFrame.minY, equals: caretFrame.minY,
                   "large editors should anchor vertically to the caret line")
        try expect(documentVisualFrame.height, equals: caretFrame.height,
                   "large editors should not place the HUD above the whole document")

        let compactFrame = NSRect(x: 700, y: 120, width: 720, height: 96)
        try expect(
            FocusedInsertionTargetLocator.visualTargetFrame(
                elementFrame: compactFrame,
                caretFrame: NSRect(x: 720, y: 150, width: 2, height: 18),
                context: context
            ),
            equals: compactFrame,
            "compact composers should keep the HUD above the whole input block"
        )
    }

    private static func testLiveInsertionTargetProbe() throws {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw SelfTestFailure.failed("frontmost application unavailable")
        }
        let screens = NSScreen.screens.map {
            InsertionTargetScreenGeometry(frame: $0.frame, visibleFrame: $0.visibleFrame)
        }
        let context = InsertionTargetQueryContext(
            applicationPID: app.processIdentifier,
            applicationName: app.localizedName ?? "unknown",
            bundleIdentifier: app.bundleIdentifier ?? "unknown",
            screens: screens,
            coordinateReferenceMaxY: screens.first?.frame.maxY ?? 0,
            lastClickPoint: nil
        )
        let result = FocusedInsertionTargetLocator.query(context: context)
        try expect(result.applicationPID, equals: app.processIdentifier,
                   "live target query should preserve the requested application")
        try expect(result.diagnostic.isEmpty, equals: false,
                   "live target query should always explain its result")
        let targetSummary = result.target.map {
            "\($0.resolutionKind) frame=\(NSStringFromRect($0.frame)) visual=\(NSStringFromRect($0.visualFrame))"
        } ?? "unavailable"
        print("AX_PROBE \(result.applicationName) (\(result.bundleIdentifier)): \(targetSummary); \(result.diagnostic)")
    }

    private static func testPrivateLogAppend() throws {
        try expect(
            privacySafeLogPath("/Users/example/Documents/Parakey Diagnostics.txt"),
            equals: "Parakey Diagnostics.txt",
            "log path labels should omit parent directories"
        )
        try expect(
            privacySafeLogPath("/"),
            equals: "<local path>",
            "log path labels should fall back when no filename is available"
        )
        try expect(
            privacySafeBundlePath("/Applications/SuperDictate.app"),
            equals: "/Applications/SuperDictate.app",
            "bundle path labels should keep the canonical install path"
        )
        try expect(
            privacySafeBundlePath("/Users/example/Downloads/SuperDictate.app"),
            equals: "SuperDictate.app",
            "bundle path labels should omit parent directories for nonstandard installs"
        )

        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("parakey-log-test-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }

        let logFile = root.appendingPathComponent("SuperDictate.log")
        try appendPrivateLogData(Data("one\n".utf8), to: logFile)
        try appendPrivateLogData(Data("two\n".utf8), to: logFile)

        let attrs = try fm.attributesOfItem(atPath: logFile.path)
        let permissions = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
        try expect(permissions & 0o777,
                   equals: 0o600,
                   "log file should be private to the current user")
        try expect(
            String(data: try Data(contentsOf: logFile), encoding: .utf8),
            equals: "one\ntwo\n",
            "log appends should preserve existing content"
        )

        let target = root.appendingPathComponent("target.log")
        try Data("target\n".utf8).write(to: target)
        let link = root.appendingPathComponent("link.log")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)

        var symlinkRejected = false
        do {
            try appendPrivateLogData(Data("bad\n".utf8), to: link)
        } catch {
            symlinkRejected = true
        }
        try expect(symlinkRejected,
                   equals: true,
                   "log appends should reject leaf symlinks")
        try expect(
            String(data: try Data(contentsOf: target), encoding: .utf8),
            equals: "target\n",
            "log symlink rejection should leave the target untouched"
        )

        let hardlinkTarget = root.appendingPathComponent("hardlink-target.log")
        try Data("hardlink target\n".utf8).write(to: hardlinkTarget)
        let hardlink = root.appendingPathComponent("hardlink.log")
        guard Darwin.link(hardlinkTarget.path, hardlink.path) == 0 else {
            throw currentPOSIXError()
        }

        var hardlinkRejected = false
        do {
            try appendPrivateLogData(Data("bad\n".utf8), to: hardlink)
        } catch {
            hardlinkRejected = true
        }
        try expect(hardlinkRejected,
                   equals: true,
                   "log appends should reject hard-linked files")
        try expect(
            String(data: try Data(contentsOf: hardlinkTarget), encoding: .utf8),
            equals: "hardlink target\n",
            "log hard-link rejection should leave the target untouched"
        )
    }

    private static func testDiagnostics() throws {
        let transcriptSecret = "secret dictated phrase 58A03D"
        let correctionSecret = "private correction replacement 9F42"
        let report = diagnosticsReportText(
            from: DiagnosticsReportSnapshot(
                generated: "2026-05-28T10:00:00Z",
                appVersion: "9.8.7",
                appBuild: "123",
                macOS: "Version 26.0",
                bundleID: "com.local.superdictate",
                bundlePath: "/Applications/SuperDictate.app",
                installKind: "Applications app",
                status: "Hold Right Option to dictate",
                startup: "Runtime ready",
                speechModelReady: true,
                coreRuntimeReady: true,
                readyForDictation: true,
                recordingActive: false,
                transcribing: false,
                memoryLines: ["Resident: 100 MB"],
                permissionLines: ["Microphone: granted", "Accessibility: granted", "Input Monitoring: granted"],
                settingLines: [
                    "Speech model: Multilingual (Parakeet TDT v3)",
                    "Language: Auto-detect",
                    "Recent transcripts: Last 5 (1 in memory)",
                    "Text corrections: 1 configured",
                    "Text correction sync: configured",
                ],
                updateLines: ["Pending update: none"],
                microphoneLines: ["Selected: System default", "Available inputs: none reported"],
                logPath: "~/Library/Logs/SuperDictate.log",
                recentLogLines: ["[10:00:00] release: 1.23 s captured, transcribing"]
            )
        )
        try expect(report.contains(transcriptSecret), equals: false,
                   "diagnostics report should not include transcript contents")
        try expect(report.contains(correctionSecret), equals: false,
                   "diagnostics report should not include text correction contents")
        try expect(report.contains("Text corrections: 1 configured"), equals: true,
                   "diagnostics report should include correction counts")
        try expect(report.contains("Speech model: Multilingual (Parakeet TDT v3)"), equals: true,
                   "diagnostics report should include the speech model")
        try expect(report.contains("Recent log lines:"), equals: true,
                   "diagnostics report should include the recent log section")
        try expect(report.contains("Privacy: transcript text and text-correction contents are not included."),
                   equals: true,
                   "diagnostics report should state the privacy boundary")

        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("parakey-diagnostics-test-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }

        let logFile = root.appendingPathComponent("SuperDictate.log")
        for line in 1...6 {
            try appendPrivateLogData(Data("[10:00:0\(line)] line \(line)\n".utf8), to: logFile)
        }
        try expect(
            try recentDiagnosticLogLines(from: logFile, maxBytes: 4096, maxLines: 3),
            equals: ["[10:00:04] line 4", "[10:00:05] line 5", "[10:00:06] line 6"],
            "diagnostic log tail should return the newest bounded lines"
        )

        let target = root.appendingPathComponent("target.log")
        try Data("[10:00:00] target\n".utf8).write(to: target)
        let symlink = root.appendingPathComponent("symlink.log")
        try fm.createSymbolicLink(at: symlink, withDestinationURL: target)
        var symlinkRejected = false
        do {
            _ = try recentDiagnosticLogLines(from: symlink, maxBytes: 4096, maxLines: 3)
        } catch {
            symlinkRejected = true
        }
        try expect(symlinkRejected, equals: true,
                   "diagnostic log tail should reject leaf symlinks")

        let hardlink = root.appendingPathComponent("hardlink.log")
        guard Darwin.link(target.path, hardlink.path) == 0 else {
            throw currentPOSIXError()
        }
        var hardlinkRejected = false
        do {
            _ = try recentDiagnosticLogLines(from: hardlink, maxBytes: 4096, maxLines: 3)
        } catch {
            hardlinkRejected = true
        }
        try expect(hardlinkRejected, equals: true,
                   "diagnostic log tail should reject hard-linked files")
    }

    private static func testHotkey() throws {
        try testHotkeyPreferenceNormalization()
        try testHotkeyPreferenceUpdateResults()
        try testHotkeyRecorderCaptureFlow()
        try testHotkeyRecorderRestartActions()
        try testHandledHotkeySuppression()
        try testCustomShortcutMatching()
        try testModifierOnlyChordMatching()
        try testConfigurableEnterShortcut()
        try testFKeyAutoRepeatSuppressesWithoutAction()
        try testRightModifierReleaseWithLeftFlagStillSet()
        try testHistoryChordShowsOverlay()
        try testConfigurableHistoryShortcut()
        try testOptionCommandEnterChordStopsWithEnter()
        try testEnterShortcutModeSelection()
        try testTogglePressFlipsOnceAndReleaseIsNoOp()
        try testToggleGatedPressDoesNotFlipToggleState()
        try testEscapePassesThroughWhenNotRecording()
        try testEscapeSuppressesCancelRepeatAndKeyUpWhileRecording()
    }

    private static func testHotkeyPreferenceNormalization() throws {
        try expect(
            normalizedHotkeyKeycode(storedValue: NSNumber(value: Int(DEFAULT_HOTKEY_KEYCODE))),
            equals: DEFAULT_HOTKEY_KEYCODE,
            "stored hotkey normalization should keep supported numeric keycodes"
        )
        try expect(
            normalizedHotkeyKeycode(storedValue: " 96\n"),
            equals: CGKeyCode(96),
            "stored hotkey normalization should accept legacy string keycodes"
        )
        try expect(
            normalizedHotkeyKeycode(storedValue: NSNumber(value: 98)),
            equals: CGKeyCode(98),
            "stored hotkey normalization should accept recorded F-key keycodes"
        )
        try expect(
            hotkeyChoice(forKeycode: CGKeyCode(98)),
            equals: HotkeyChoice(name: "F7", keycode: 98, isModifier: false, modifierFlag: nil),
            "recorded F-key choices should get a stable display name"
        )
        try expect(
            localizedHotkeyName(hotkeyChoice(forKeycode: RIGHT_COMMAND_KEYCODE),
                                language: .russian),
            equals: "Правый Command",
            "Russian UI should localize a modifier-only shortcut"
        )
        try expect(
            localizedHotkeyName(hotkeyChoice(forKeycode: 49, modifiers: .maskAlternate),
                                language: .russian),
            equals: "⌥Пробел",
            "Russian UI should localize a chord key name"
        )
        try expect(
            normalizedHotkeyKeycode(storedValue: NSNumber(value: 999)),
            equals: nil,
            "stored hotkey normalization should reject unsupported keycodes"
        )
        try expect(
            normalizedHotkeyKeycode(storedValue: NSNumber(value: -1)),
            equals: nil,
            "stored hotkey normalization should reject negative keycodes"
        )
        try expect(
            hotkeyChoice(forKeycode: CGKeyCode(999)),
            equals: hotkeyChoice(forKeycode: DEFAULT_HOTKEY_KEYCODE),
            "unknown hotkey choices should fall back to the default"
        )

        try expect(
            hotkeyRecordingDecision(for: event(.keyDown, keycode: 98)),
            equals: .accept(HotkeyChoice(name: "F7", keycode: 98, isModifier: false, modifierFlag: nil)),
            "hotkey recorder should accept F-key presses outside the quick-pick list"
        )
        try expect(
            hotkeyRecordingDecision(for: event(.keyDown, keycode: 0)),
            equals: .accept(HotkeyChoice(name: "A", keycode: 0, isModifier: false, modifierFlag: nil)),
            "hotkey recorder should accept a single typing key"
        )
        try expect(
            hotkeyRecordingDecision(for: event(.keyDown,
                                               keycode: 40,
                                               flags: CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue)),
            equals: .accept(HotkeyChoice(name: "⇧⌘K",
                                         keycode: 40,
                                         isModifier: false,
                                         modifierFlag: nil,
                                         requiredModifiers: [.maskCommand, .maskShift])),
            "hotkey recorder should accept multi-key shortcuts"
        )
        try expect(
            hotkeyRecordingDecision(for: event(.keyDown, keycode: 98, isAutoRepeat: true)),
            equals: .ignore,
            "hotkey recorder should ignore auto-repeat"
        )
        try expect(
            hotkeyRecordingDecision(for: event(.flagsChanged,
                                               keycode: 61,
                                               flags: CGEventFlags.maskAlternate.rawValue)),
            equals: .accept(HotkeyChoice(name: "Right Option",
                                         keycode: 61,
                                         isModifier: true,
                                         modifierFlag: .maskAlternate)),
            "hotkey recorder should accept right-side modifier presses"
        )
        try expect(
            hotkeyRecordingDecision(for: event(
                .flagsChanged,
                keycode: RIGHT_COMMAND_KEYCODE,
                flags: CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskCommand.rawValue
            )),
            equals: .accept(hotkeyChoice(forKeycode: RIGHT_COMMAND_KEYCODE,
                                         modifiers: [.maskAlternate, .maskCommand])),
            "hotkey recorder should accept modifier-only chords"
        )
    }

    private static func testHotkeyPreferenceUpdateResults() throws {
        let f5 = hotkeyChoice(forKeycode: 96)
        let f7 = hotkeyChoice(forKeycode: 98)
        let invalid = HotkeyChoice(name: "Escape", keycode: ESCAPE_KEYCODE, isModifier: false, modifierFlag: nil)

        try expect(
            hotkeyPreferenceUpdateResult(
                requested: f7,
                previous: f5,
                persisted: f7
            ),
            equals: .saved(f7),
            "hotkey preference update should save supported keys after persistence confirms them"
        )
        try expect(
            hotkeyPreferenceUpdateResult(
                requested: invalid,
                previous: f5,
                persisted: f5
            ),
            equals: .rejected("That key cannot be used for dictation."),
            "hotkey preference update should reject unsupported keys before mutating settings"
        )
        try expect(
            hotkeyPreferenceUpdateResult(
                requested: f7,
                previous: f5,
                persisted: f5
            ),
            equals: .rolledBack(
                previous: f5,
                message: "Parakey could not save that hotkey, so it kept F5."
            ),
            "hotkey preference update should roll back when persisted settings disagree"
        )
    }

    private static func testHotkeyRecorderCaptureFlow() throws {
        try expect(
            hotkeyFlags(from: [.command, .option]),
            equals: [.maskCommand, .maskAlternate],
            "recorder should translate AppKit modifier flags without relying on an optional CGEvent"
        )

        var singleCommand = HotkeyRecorderCaptureState()
        let commandDown = event(.flagsChanged,
                                keycode: RIGHT_COMMAND_KEYCODE,
                                flags: CGEventFlags.maskCommand.rawValue)
        let rightCommand = hotkeyChoice(forKeycode: RIGHT_COMMAND_KEYCODE)
        try expect(
            singleCommand.consume(commandDown),
            equals: .candidate(rightCommand),
            "pressing Right Command should select it immediately as a one-key shortcut"
        )
        try expect(
            singleCommand.consume(event(.flagsChanged, keycode: RIGHT_COMMAND_KEYCODE)),
            equals: .ignore,
            "releasing Right Command should not be required to preserve its selection"
        )

        var singleModifier = HotkeyRecorderCaptureState()
        let optionDown = event(.flagsChanged,
                               keycode: 58,
                               flags: CGEventFlags.maskAlternate.rawValue)
        let leftOption = hotkeyChoice(forKeycode: 58)
        try expect(
            singleModifier.consume(optionDown),
            equals: .candidate(leftOption),
            "pressing Option should select it immediately as a one-key shortcut"
        )
        try expect(
            singleModifier.consume(event(.flagsChanged, keycode: 58)),
            equals: .ignore,
            "releasing Option should not change the selected shortcut"
        )

        for (keycode, flags, label) in [
            (CGKeyCode(55), CGEventFlags.maskCommand, "Left Command"),
            (CGKeyCode(59), CGEventFlags.maskControl, "Left Control"),
            (FN_KEYCODE, CGEventFlags.maskSecondaryFn, "Fn"),
        ] {
            var modifier = HotkeyRecorderCaptureState()
            try expect(
                modifier.consume(event(.flagsChanged,
                                       keycode: keycode,
                                       flags: flags.rawValue)),
                equals: .candidate(hotkeyChoice(forKeycode: keycode)),
                "pressing \(label) should select it immediately"
            )
        }

        var chord = HotkeyRecorderCaptureState()
        _ = chord.consume(optionDown)
        try expect(
            chord.consume(event(.keyDown,
                                keycode: 40,
                                flags: CGEventFlags.maskAlternate.rawValue)),
            equals: .candidate(hotkeyChoice(forKeycode: 40,
                                            modifiers: .maskAlternate)),
            "pressing a regular key while a modifier is held should select the full chord"
        )

        var modifierChord = HotkeyRecorderCaptureState()
        _ = modifierChord.consume(optionDown)
        try expect(
            modifierChord.consume(event(
                .flagsChanged,
                keycode: RIGHT_COMMAND_KEYCODE,
                flags: CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskCommand.rawValue
            )),
            equals: .candidate(hotkeyChoice(forKeycode: RIGHT_COMMAND_KEYCODE,
                                            modifiers: [.maskAlternate, .maskCommand])),
            "pressing a second modifier should select a modifier-only chord"
        )

        var singleKey = HotkeyRecorderCaptureState()
        try expect(
            singleKey.consume(event(.keyDown, keycode: 96)),
            equals: .candidate(hotkeyChoice(forKeycode: 96)),
            "pressing one regular key should select it for confirmation"
        )

        var canceled = HotkeyRecorderCaptureState()
        try expect(
            canceled.consume(event(.keyDown, keycode: ESCAPE_KEYCODE)),
            equals: .cancel,
            "Escape should cancel shortcut recording"
        )
    }

    private static func testHotkeyRecorderRestartActions() throws {
        try expect(
            hotkeyRecorderRestartAction(
                shouldRestoreHotkeyTap: false,
                isTerminating: false,
                restartSucceeded: false
            ),
            equals: .none,
            "hotkey recorder should not start a listener that was not active"
        )
        try expect(
            hotkeyRecorderRestartAction(
                shouldRestoreHotkeyTap: true,
                isTerminating: true,
                restartSucceeded: false
            ),
            equals: .none,
            "hotkey recorder should not restart the listener during termination"
        )
        try expect(
            hotkeyRecorderRestartAction(
                shouldRestoreHotkeyTap: true,
                isTerminating: false,
                restartSucceeded: true
            ),
            equals: .restoredListener,
            "hotkey recorder should treat a successful restart as recovered"
        )
        try expect(
            hotkeyRecorderRestartAction(
                shouldRestoreHotkeyTap: true,
                isTerminating: false,
                restartSucceeded: false
            ),
            equals: .recordFailure,
            "hotkey recorder should surface restart failure after an active listener was paused"
        )
    }

    private static func testReadiness() throws {
        try expect(
            readinessTransition(isReady: false,
                                isCoreRuntimeReady: false,
                                missingPermissions: []),
            equals: .rebuildMenuOnly,
            "not-ready app without core runtime should wait and rebuild only"
        )
        try expect(
            readinessTransition(isReady: false,
                                isCoreRuntimeReady: true,
                                missingPermissions: [.microphone]),
            equals: .blockForPermissions([.microphone]),
            "core-ready app with missing microphone should block"
        )
        try expect(
            readinessTransition(isReady: true,
                                isCoreRuntimeReady: true,
                                missingPermissions: [.accessibility]),
            equals: .blockForPermissions([.accessibility]),
            "ready app with missing accessibility should block"
        )
        try expect(
            readinessTransition(isReady: false,
                                isCoreRuntimeReady: true,
                                missingPermissions: []),
            equals: .startHotkeyListener,
            "core-ready app with all permissions should start hotkey"
        )
        try expect(
            readinessTransition(isReady: true,
                                isCoreRuntimeReady: true,
                                missingPermissions: []),
            equals: .rebuildMenuOnly,
            "ready app with all permissions should remain ready and rebuild only"
        )

        try expect(
            productionSpeechModelProfile(rawValue: nil),
            equals: .multilingualV3,
            "missing speech model setting should use the production default"
        )
        try expect(
            productionSpeechModelProfile(rawValue: SpeechModelProfile.multilingualV3.rawValue),
            equals: .multilingualV3,
            "stored v3 speech model should remain valid"
        )
        try expect(
            productionSpeechModelProfile(rawValue: SpeechModelProfile.englishUnified.rawValue),
            equals: .multilingualV3,
            "deprecated Unified speech model setting should migrate back to v3"
        )
        try expect(
            productionSpeechModelProfile(rawValue: "unknown_model"),
            equals: .multilingualV3,
            "unknown speech model setting should migrate back to v3"
        )

        try expect(
            speechModelSetupRowState(profile: .multilingualV3,
                                     isSpeechModelReady: false,
                                     isStartupInProgress: true,
                                     startupStatusTitle: "Downloading speech model… 50%",
                                     failure: nil),
            equals: SetupChecklistRowState(detail: "Downloading speech model… 50%",
                                           status: "Loading",
                                           buttonTitle: nil),
            "setup checklist should show speech model progress"
        )
        try expect(
            speechModelSetupRowState(profile: .multilingualV3,
                                     isSpeechModelReady: false,
                                     isStartupInProgress: false,
                                     startupStatusTitle: "Loading speech model…",
                                     failure: StartupFailure(stage: .speechModel, detail: "download failed")),
            equals: SetupChecklistRowState(detail: "download failed",
                                           status: "Needs retry",
                                           buttonTitle: "Retry"),
            "setup checklist should offer retry for speech model failures"
        )
        try expect(
            speechModelSetupRowState(profile: .multilingualV3,
                                     isSpeechModelReady: true,
                                     isStartupInProgress: false,
                                     startupStatusTitle: "Loading speech model…",
                                     failure: nil),
            equals: SetupChecklistRowState(detail: "Parakeet TDT v3 is loaded locally.",
                                           status: "Ready",
                                           buttonTitle: nil),
            "setup checklist should show the speech model when ready"
        )
        try expect(
            audioInputSetupRowState(isSpeechModelReady: true,
                                    isCoreRuntimeReady: false,
                                    isStartupInProgress: false,
                                    failure: StartupFailure(stage: .audioInput, detail: "no input device")),
            equals: SetupChecklistRowState(detail: "no input device",
                                           status: "Needs retry",
                                           buttonTitle: "Retry"),
            "setup checklist should offer retry for audio input failures"
        )
        try expect(
            audioInputSetupRowState(isSpeechModelReady: false,
                                    isCoreRuntimeReady: false,
                                    isStartupInProgress: true,
                                    failure: nil),
            equals: SetupChecklistRowState(detail: "Available after the speech model loads.",
                                           status: "Waiting",
                                           buttonTitle: nil),
            "setup checklist should not start audio before the speech model is ready"
        )
        try expect(
            hotkeySetupRowState(isReady: false,
                                hotkeyTestSucceeded: false,
                                triggerMode: .hold,
                                hotkeyName: "Right Option",
                                failure: StartupFailure(stage: .hotkeyListener, detail: "event tap failed")),
            equals: SetupChecklistRowState(detail: "event tap failed",
                                           status: "Needs retry",
                                           buttonTitle: "Retry"),
            "setup checklist should offer retry for hotkey listener failures"
        )
        try expect(
            hotkeySetupRowState(isReady: true,
                                hotkeyTestSucceeded: true,
                                triggerMode: .toggle,
                                hotkeyName: "F5",
                                failure: nil),
            equals: SetupChecklistRowState(detail: "Press F5 to dictate.",
                                           status: "Detected",
                                           buttonTitle: nil),
            "setup checklist should show detected hotkey state"
        )

        try expect(
            previousExitNoticeAction(previousRunWasActive: false),
            equals: .none,
            "clean previous exits should not show the abnormal-exit notice"
        )
        try expect(
            previousExitNoticeAction(previousRunWasActive: true),
            equals: .showNotice,
            "active run markers should show the abnormal-exit notice on next launch"
        )
        try expect(
            speechModelFailureDetail(errorDescription: "SHA-256 mismatch").contains("Reset Speech Model Cache"),
            equals: true,
            "speech model integrity failures should point to cache reset"
        )
        try expect(
            speechModelFailureDetail(errorDescription: "download timed out").contains("audio is not uploaded"),
            equals: true,
            "speech model download failures should preserve the local-audio privacy boundary"
        )
        try expect(
            speechModelFailureDetail(errorDescription: "Free some disk space, then retry loading the speech model."),
            equals: "Free some disk space, then retry loading the speech model.",
            "disk-space failures should not add unrelated reset-cache guidance"
        )
        try expect(
            startupFailureDetail(stage: .audioInput, errorDescription: "no input device"),
            equals: "no input device",
            "non-model startup failures should keep their original detail"
        )

        let coreAudioStopError = NSError(
            domain: "com.apple.coreaudio.avfaudio",
            code: 1_937_010_544,
            userInfo: ["failed call": "PerformCommand(*ioNode, kAUStartIO, NULL, 0)"]
        )
        let coreAudioErrorDescription = audioStartupErrorDescription(coreAudioStopError)
        try expect(
            coreAudioErrorDescription.contains("OSStatus 1937010544"),
            equals: true,
            "CoreAudio startup errors should include the decimal OSStatus"
        )
        try expect(
            coreAudioErrorDescription.contains("0x73746f70"),
            equals: true,
            "CoreAudio startup errors should include the hex OSStatus"
        )
        try expect(
            coreAudioErrorDescription.contains("'stop'"),
            equals: true,
            "CoreAudio startup errors should include printable four-character codes"
        )
        try expect(
            coreAudioErrorDescription.contains("PerformCommand(*ioNode, kAUStartIO, NULL, 0)"),
            equals: true,
            "CoreAudio startup errors should preserve the failed AVFAudio call"
        )
        try expect(
            startupFailureDetail(stage: .audioInput, error: coreAudioStopError).contains("restart CoreAudio"),
            equals: true,
            "exhausted CoreAudio startup failures should give OS recovery guidance"
        )
    }

    private static func testPasteSuffixFormatting() throws {
        try expect(
            pastedText(from: "hello world", suffix: .appendSpace),
            equals: "hello world ",
            "append-space suffix should preserve the existing default"
        )
        try expect(
            pastedText(from: "hello world", suffix: .none),
            equals: "hello world",
            "no suffix should paste corrected transcript unchanged"
        )
        try expect(
            pastedText(from: "hello world", suffix: .appendNewline),
            equals: "hello world\n",
            "append-newline suffix should add a single newline"
        )
        try expect(
            pastedText(from: "hello world ", suffix: .appendSpace),
            equals: "hello world  ",
            "suffix formatting should not trim or rewrite corrected text"
        )
        try expect(
            TextInserter.defaultStrategy,
            equals: .clipboardPaste,
            "clipboard paste should remain the default insertion strategy"
        )
        try expect(
            textInsertionStrategyChain(primary: .clipboardPaste),
            equals: [.clipboardPaste, .directUnicode],
            "clipboard paste should fall back to direct Unicode insertion"
        )
        try expect(
            textInsertionStrategyChain(primary: .directUnicode),
            equals: [.directUnicode],
            "direct Unicode insertion should not loop back to clipboard paste"
        )
        try expect(
            TextInserter.defaultStrategyDescription,
            equals: "Clipboard paste with Direct Unicode typing fallback",
            "diagnostics should describe the insertion fallback chain"
        )
        let unicodeChunks = unicodeInsertionChunks(for: "ab👩‍💻cd", maxUTF16UnitsPerEvent: 4)
            .map { String(decoding: $0, as: UTF16.self) }
        try expect(
            unicodeChunks,
            equals: ["ab", "👩‍💻", "cd"],
            "direct Unicode insertion should keep extended grapheme clusters together while chunking"
        )
        try expect(
            unicodeInsertionChunks(for: "abc", maxUTF16UnitsPerEvent: 0),
            equals: [],
            "direct Unicode chunking should reject invalid chunk sizes"
        )
        try expect(
            clipboardPasteKeyboardEventSteps(commandKey: 0x37, pasteKey: 0x09),
            equals: [
                KeyboardEventStep(virtualKey: 0x37, keyDown: true, flags: .maskCommand),
                KeyboardEventStep(virtualKey: 0x09, keyDown: true, flags: .maskCommand),
                KeyboardEventStep(virtualKey: 0x09, keyDown: false, flags: .maskCommand),
                KeyboardEventStep(virtualKey: 0x37, keyDown: false, flags: []),
            ],
            "clipboard paste should synthesize a full Command+V key sequence"
        )

        let pasteboardProbe = MainActor.assumeIsolated {
            let pasteboardName = NSPasteboard.Name("com.local.superdictate.self-test.\(UUID().uuidString)")
            let pasteboard = NSPasteboard(name: pasteboardName)
            let wrote = ClipboardPasteInserter.write("pasteboard probe", to: pasteboard)
            let snapshot = PasteboardSnapshot.capture(from: pasteboard)
            _ = ClipboardPasteInserter.write("temporary dictation", to: pasteboard)
            snapshot.restore(to: pasteboard)
            return (wrote: wrote, stored: pasteboard.string(forType: .string))
        }
        try expect(
            pasteboardProbe.wrote,
            equals: true,
            "clipboard paste should report pasteboard write success"
        )
        try expect(
            pasteboardProbe.stored,
            equals: "pasteboard probe",
            "clipboard paste should write the intended string before posting Cmd+V"
        )
    }

    private static func testRecentTranscriptLimit() throws {
        let transcripts = ["newest", "second", "third", "fourth", "fifth", "sixth"]

        try expect(
            limitedRecentTranscripts(transcripts, limit: .off),
            equals: [],
            "off should keep no recent transcripts"
        )
        try expect(
            limitedRecentTranscripts(transcripts, limit: .last1),
            equals: ["newest"],
            "last-one history should keep only the newest transcript"
        )
        try expect(
            limitedRecentTranscripts(transcripts, limit: .last5),
            equals: ["newest", "second", "third", "fourth", "fifth"],
            "last-five history should preserve the current default cap"
        )
        try expect(
            parseRecentTranscriptLimit(storedValue: NSNumber(value: 1)),
            equals: .last1,
            "numeric defaults writes should be accepted for last-one history"
        )

        let timedEntries = transcripts.enumerated().map { index, text in
            TranscriptHistoryEntry(
                text: text,
                transcriptionDurationSeconds: Double(index + 1) / 10
            )
        }
        try expect(
            limitedRecentTranscriptEntries(timedEntries, limit: .last1),
            equals: [TranscriptHistoryEntry(text: "newest", transcriptionDurationSeconds: 0.1)],
            "history trimming should preserve transcription timing metadata"
        )

        let archivedEntries = limitedTranscriptHistoryArchive(timedEntries, maximumCount: 6)
        try expect(
            archivedEntries.count,
            equals: 6,
            "the archive should retain entries beyond the visible history limit"
        )
        let archiveAfterDeletion = transcriptHistoryArchive(archivedEntries, removing: 2)
        try expect(
            limitedRecentTranscriptEntries(archiveAfterDeletion, limit: .last5).map(\.text),
            equals: ["newest", "second", "fourth", "fifth", "sixth"],
            "deleting a visible history entry should backfill it from the archive"
        )
        try expect(
            transcriptHistoryArchive(archivedEntries, removing: 99),
            equals: archivedEntries,
            "an invalid history deletion index should leave the archive unchanged"
        )

        let historyRowHitTargets = MainActor.assumeIsolated { () -> (delete: Bool, row: Bool, deleteAction: Bool, copyAction: Bool) in
            let row = HistoryTranscriptItemView(
                transcript: "test",
                preview: "test",
                transcriptionDurationSeconds: 0.1,
                asrTiming: nil,
                historyIndex: 0,
                target: nil,
                action: NSSelectorFromString("noop:"),
                onDelete: { _ in }
            )
            row.frame = NSRect(x: 0, y: 0, width: 600, height: 56)
            guard let deleteButton = row.subviews.compactMap({ $0 as? HistoryDeleteButton }).first else {
                return (false, false, false, false)
            }
            deleteButton.frame = NSRect(x: 560, y: 14, width: 28, height: 28)
            let deleteAction: Bool
            if case .delete(0) = row.hitAction(atWindowPoint: NSPoint(x: 574, y: 28)) {
                deleteAction = true
            } else {
                deleteAction = false
            }
            let copyAction: Bool
            if case .copy("test") = row.hitAction(atWindowPoint: NSPoint(x: 200, y: 28)) {
                copyAction = true
            } else {
                copyAction = false
            }
            return (
                row.hitTest(NSPoint(x: 574, y: 28)) === row,
                row.hitTest(NSPoint(x: 200, y: 28)) === row,
                deleteAction,
                copyAction
            )
        }
        try expect(
            historyRowHitTargets.delete,
            equals: true,
            "history rows should own delete-zone clicks"
        )
        try expect(
            historyRowHitTargets.row,
            equals: true,
            "history rows should keep transcript clicks on the copy action"
        )
        try expect(
            historyRowHitTargets.deleteAction,
            equals: true,
            "history delete zones should resolve to deletion"
        )
        try expect(
            historyRowHitTargets.copyAction,
            equals: true,
            "history transcript bodies should resolve to clipboard copy"
        )
        try expect(
            transcriptionDurationLabel(0.1234),
            equals: "0.123 s",
            "history timing should be displayed in seconds with millisecond precision"
        )
        try expect(
            transcriptionDurationLabel(nil),
            equals: "\u{2014}",
            "legacy history entries should not invent transcription timing"
        )

        let timing = ASRTimingBreakdown(
            totalSeconds: 0.295,
            workerQueueSeconds: 0.001,
            decoderPreparationSeconds: 0.002,
            fluidCallSeconds: 0.290,
            fluidProcessingSeconds: 0.286
        )
        let entriesWithBreakdown = [
            TranscriptHistoryEntry(
                text: "timed",
                transcriptionDurationSeconds: timing.totalSeconds,
                asrTiming: timing
            )
        ]
        let encodedEntries = try JSONEncoder().encode(entriesWithBreakdown)
        try expect(
            try JSONDecoder().decode([TranscriptHistoryEntry].self, from: encodedEntries),
            equals: entriesWithBreakdown,
            "history timing metadata should survive persistence"
        )
        try expect(
            asrTimingTooltip(timing)?.contains("FluidAudio  286.0 ms"),
            equals: true,
            "history timing tooltip should expose FluidAudio's own processing time"
        )

        let legacyEntryData = Data(
            #"[{"text":"legacy","transcriptionDurationSeconds":0.25}]"#.utf8
        )
        try expect(
            try JSONDecoder().decode([TranscriptHistoryEntry].self, from: legacyEntryData),
            equals: [TranscriptHistoryEntry(text: "legacy", transcriptionDurationSeconds: 0.25)],
            "history entries saved before detailed metrics should remain decodable"
        )

        let metricLine = DictationLatencyMetrics(
            audioSeconds: 2,
            hotkeyDispatchSeconds: 0.0005,
            releasePreparationSeconds: 0.001,
            settingsRefreshSeconds: 0.0002,
            releasePermissionCheckSeconds: 0.0003,
            audioFinalizeSeconds: 0.002,
            audioDetachSeconds: 0.0001,
            journalFlushSeconds: 0.0015,
            audioFlattenSeconds: 0.0004,
            transcribingUISeconds: 0.003,
            taskQueueSeconds: 0.004,
            releaseToASRSeconds: 0.010,
            asrTiming: timing,
            postprocessingSeconds: 0.005,
            historyPersistenceSeconds: 0.006,
            journalCleanupSeconds: 0.007,
            permissionRecheckSeconds: 0.008,
            insertionDispatchSeconds: 0.009,
            releaseToPasteDispatchSeconds: 0.330,
            enterDelaySeconds: nil,
            pasteSucceeded: true
        ).logLine
        try expect(
            metricLine.contains("hotkey_dispatch=0.5 ms")
                && metricLine.contains("journal_flush=1.5 ms")
                && metricLine.contains("fluid_processing=286.0 ms")
                && metricLine.contains("release_to_paste=330.0 ms")
                && metricLine.contains("paste=ok"),
            equals: true,
            "latency log should expose model, end-to-end, and insertion outcomes"
        )
    }

    private static func testDictationUsageStatistics() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let reference = calendar.date(from: DateComponents(year: 2026, month: 7, day: 18, hour: 12))!
        let july10 = calendar.date(from: DateComponents(year: 2026, month: 7, day: 10, hour: 10))!
        let july11 = calendar.date(from: DateComponents(year: 2026, month: 7, day: 11, hour: 10))!
        let july17 = calendar.date(from: DateComponents(year: 2026, month: 7, day: 17, hour: 10))!
        let july18 = calendar.date(from: DateComponents(year: 2026, month: 7, day: 18, hour: 10))!

        var stats: [DailyDictationUsage] = []
        stats = addingDictationUsageSample(to: stats,
                                           at: july10,
                                           characterCount: 40,
                                           audioSeconds: 4,
                                           asrSeconds: 0.4,
                                           calendar: calendar)
        stats = addingDictationUsageSample(to: stats,
                                           at: july11,
                                           characterCount: 100,
                                           audioSeconds: 10,
                                           asrSeconds: 0.5,
                                           calendar: calendar)
        stats = addingDictationUsageSample(to: stats,
                                           at: july17,
                                           characterCount: 300,
                                           audioSeconds: 30,
                                           asrSeconds: 0.75,
                                           calendar: calendar)
        stats = addingDictationUsageSample(to: stats,
                                           at: july18,
                                           characterCount: 900,
                                           audioSeconds: 90,
                                           asrSeconds: 1.2,
                                           calendar: calendar)

        let snapshot = lastSevenCompletedDictationUsage(stats,
                                                         referenceDate: reference,
                                                         calendar: calendar)
        try expect(snapshot.days.count, equals: 7,
                   "statistics should always contain seven completed calendar days")
        try expect(snapshot.days.first?.usage.day, equals: "2026-07-11",
                   "statistics should begin seven days before today")
        try expect(snapshot.days.last?.usage.day, equals: "2026-07-17",
                   "statistics should end yesterday")
        try expect(snapshot.totalCharacters, equals: 400,
                   "statistics should exclude both older data and today's dictations")
        try expect(snapshot.totalDictations, equals: 2,
                   "statistics should aggregate completed dictations")
        try expect(snapshot.totalAudioSeconds, equals: 40,
                   "statistics should aggregate recorded audio duration")
        try expect(snapshot.totalASRSeconds, equals: 1.25,
                   "statistics should aggregate ASR duration")

        let log = """
        [23:59:58] 2.00 s audio → 0.20 s → 20 chars
        [00:00:01] HotkeyListener: tap active
        [00:00:02] 3.00 s audio → 0.30 s → 30 chars
        [00:00:03] 1.00 s audio → 0.10 s → 0 chars
        """
        let imported = importedDailyDictationUsage(
            from: log,
            fileCreatedAt: calendar.date(from: DateComponents(year: 2026, month: 7, day: 3))!,
            calendar: calendar
        )
        try expect(imported.count, equals: 2,
                   "log import should infer a new day when timestamps cross midnight")
        try expect(imported.first?.characterCount, equals: 20,
                   "log import should preserve the first day's characters")
        try expect(imported.last?.characterCount, equals: 30,
                   "log import should ignore empty transcripts")
    }

    private static func testAudioLevelMetering() throws {
        var accumulator = AudioSampleAccumulator()
        accumulator.append([])
        accumulator.append([1, 2])
        accumulator.append([3, 4, 5])
        try expect(
            accumulator.sampleCount,
            equals: 5,
            "segmented audio accumulator should track total sample count"
        )
        let captured = accumulator.drain()
        try expect(
            accumulator.sampleCount,
            equals: 0,
            "segmented audio accumulator should reset after drain"
        )
        try expect(
            captured.flattened(),
            equals: [1, 2, 3, 4, 5],
            "segmented audio accumulator should preserve sample order when flattened"
        )

        try expect(
            normalizedAudioLevel(from: Array(repeating: 0, count: 128)),
            equals: 0,
            "silence should map to zero recording level"
        )

        let lowVoice = normalizedAudioLevel(from: Array(repeating: 0.004, count: 128))
        let quiet = normalizedAudioLevel(from: Array(repeating: 0.01, count: 128))
        let normal = normalizedAudioLevel(from: Array(repeating: 0.12, count: 128))
        let loud = normalizedAudioLevel(from: Array(repeating: 4.0, count: 128))

        guard lowVoice > 0 else {
            throw SelfTestFailure.failed("low close-mic voice should rise above the visual gate")
        }
        guard quiet > 0 else {
            throw SelfTestFailure.failed("quiet speech-like input should rise above zero")
        }
        guard normal > quiet else {
            throw SelfTestFailure.failed("higher RMS should produce a higher visual level")
        }
        try expect(
            loud,
            equals: 1,
            "out-of-range samples should clamp to maximum visual level"
        )

        try expect(
            normalizedAudioLevel(from: [.nan, .infinity, -.infinity]),
            equals: 0,
            "non-finite samples should not produce a visible level"
        )
        try expect(
            visibleRecordingLevel(rawLevel: .nan),
            equals: 0,
            "visible recording level should ignore non-finite input"
        )
        try expect(
            visibleRecordingLevel(rawLevel: 0.8),
            equals: 0.8,
            "visible recording level should pass through normal input immediately"
        )
        try expect(
            visibleRecordingLevel(rawLevel: 1.2),
            equals: 1,
            "visible recording level should clamp high input"
        )

        let idlePhaseSpeed = recordingHUDPhaseSpeed(mode: .recording, level: 0)
        let voicePhaseSpeed = recordingHUDPhaseSpeed(mode: .recording, level: 0.8)
        guard voicePhaseSpeed > idlePhaseSpeed else {
            throw SelfTestFailure.failed("voice should visibly accelerate the recording waveform")
        }
        try expect(
            recordingHUDPhaseSpeed(mode: .transcribing, level: 1),
            equals: RECORDING_HUD_TRANSCRIBING_PHASE_SPEED,
            "transcribing animation speed should not depend on stale microphone level"
        )
        try expect(
            recordingHUDPhaseSpeed(mode: .error, level: 0),
            equals: 0,
            "error HUD should be static (zero phase speed)"
        )
    }

    private static func testAudioConversion() throws {
        guard let stereoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: 48_000,
                                               channels: 2,
                                               interleaved: false),
              let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 48_000,
                                             channels: 1,
                                             interleaved: false),
              let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: 16_000,
                                               channels: 1,
                                               interleaved: false),
              let stereo = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: 480),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: 480),
              let stereoChannels = stereo.floatChannelData,
              let monoChannel = mono.floatChannelData?[0] else {
            throw SelfTestFailure.failed("could not create audio conversion test buffers")
        }
        stereo.frameLength = 480
        for i in 0..<480 {
            stereoChannels[0][i] = 0.5
            stereoChannels[1][i] = 0.02
        }

        let rms = channelRMSValues(channels: stereoChannels, channelCount: 2, frameCount: 480)
        try expect(
            selectedMonoMixChannelIndices(channelRMS: rms),
            equals: [0],
            "manual mono mix should select the active close-mic channel when another channel is near-silent"
        )
        writeMonoMix(channels: stereoChannels,
                     selectedChannels: selectedMonoMixChannelIndices(channelRMS: rms),
                     frameCount: 480,
                     to: monoChannel)
        mono.frameLength = 480
        try expect(
            monoChannel[0],
            equals: 0.5,
            "manual mono mix should preserve the selected active channel"
        )

        for i in 0..<480 {
            stereoChannels[0][i] = 0.5
            stereoChannels[1][i] = -0.5
        }
        let balancedRMS = channelRMSValues(channels: stereoChannels, channelCount: 2, frameCount: 480)
        try expect(
            selectedMonoMixChannelIndices(channelRMS: balancedRMS),
            equals: [0, 1],
            "manual mono mix should average multiple similarly active channels"
        )
        writeMonoMix(channels: stereoChannels,
                     selectedChannels: selectedMonoMixChannelIndices(channelRMS: balancedRMS),
                     frameCount: 480,
                     to: monoChannel)
        try expect(
            monoChannel[0],
            equals: 0,
            "manual mono mix should average selected channels with equal weight"
        )

        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 320),
              let converter = AVAudioConverter(from: monoFormat, to: targetFormat) else {
            throw SelfTestFailure.failed("could not create audio converter")
        }
        var error: NSError?
        let inputProvider = AudioConverterInputProvider(buffer: mono)
        let status = converter.convert(to: converted, error: &error) { _, outStatus in
            inputProvider.provide(outStatus: outStatus)
        }
        if status == .error {
            throw SelfTestFailure.failed("audio conversion failed: \(error?.localizedDescription ?? "?")")
        }
        guard converted.format.channelCount == 1,
              Int(converted.format.sampleRate) == 16_000,
              converted.frameLength > 0 else {
            throw SelfTestFailure.failed("audio conversion should produce 16 kHz mono samples")
        }
    }

    private static func testTranscriptCorrections() throws {
        try expect(
            correctionSourcePrefill(from: "  first line\n\nsecond\tline  "),
            equals: "first line second line",
            "correction source prefill should collapse transcript whitespace"
        )
        try expect(
            correctionSourcePrefill(from: String(repeating: "a", count: MAX_TRANSCRIPT_CORRECTION_SOURCE_BYTES + 4)).utf8.count,
            equals: MAX_TRANSCRIPT_CORRECTION_SOURCE_BYTES,
            "correction source prefill should stay inside correction source byte limits"
        )
        try expect(
            correctionSourcePrefill(from: String(repeating: "é", count: MAX_TRANSCRIPT_CORRECTION_SOURCE_BYTES)).utf8.count,
            equals: MAX_TRANSCRIPT_CORRECTION_SOURCE_BYTES,
            "correction source prefill should clip at character boundaries"
        )

        let normalized = normalizedTranscriptCorrections([
            TranscriptCorrection(source: "  Yeti   Nano  ", replacement: "  Blue mic  "),
            TranscriptCorrection(source: "yeti nano", replacement: "USB mic"),
            TranscriptCorrection(source: "", replacement: "ignored"),
            TranscriptCorrection(source: "empty replacement", replacement: "   ")
        ])
        try expect(
            normalized,
            equals: [TranscriptCorrection(source: "yeti nano", replacement: "USB mic")],
            "normalization should trim, drop incomplete entries, collapse duplicate sources, and keep the latest replacement"
        )

        let boundedCorrections = normalizedTranscriptCorrections(
            [
                TranscriptCorrection(source: String(repeating: "s", count: MAX_TRANSCRIPT_CORRECTION_SOURCE_BYTES + 1),
                                     replacement: "replacement"),
                TranscriptCorrection(source: "source",
                                     replacement: String(repeating: "r", count: MAX_TRANSCRIPT_CORRECTION_REPLACEMENT_BYTES + 1)),
                TranscriptCorrection(source: "nul\u{0}source", replacement: "replacement"),
                TranscriptCorrection(source: "valid", replacement: "replacement")
            ]
            + (0..<(MAX_TRANSCRIPT_CORRECTIONS + 3)).map {
                TranscriptCorrection(source: "source-\($0)", replacement: "replacement-\($0)")
            }
            + [
                TranscriptCorrection(source: "source-0", replacement: "updated")
            ]
        )
        try expect(
            boundedCorrections.count,
            equals: MAX_TRANSCRIPT_CORRECTIONS,
            "normalization should cap stored correction count"
        )
        try expect(
            boundedCorrections.first,
            equals: TranscriptCorrection(source: "valid", replacement: "replacement"),
            "normalization should keep valid corrections while dropping oversized and NUL-containing entries"
        )
        try expect(
            boundedCorrections.dropFirst().first,
            equals: TranscriptCorrection(source: "source-0", replacement: "updated"),
            "normalization should still let later duplicates update retained corrections"
        )
        try expect(
            boundedCorrections.contains(where: { $0.source == "source-\(MAX_TRANSCRIPT_CORRECTIONS)" }),
            equals: false,
            "normalization should drop new unique corrections after the cap"
        )

        let applied = TranscriptCorrector.apply(
            to: "parakeet tdt and parakeetish and PARakeet",
            corrections: [
                TranscriptCorrection(source: "parakeet", replacement: "Parakey"),
                TranscriptCorrection(source: "parakeet tdt", replacement: "Parakeet TDT")
            ]
        )
        try expect(
            applied.text,
            equals: "Parakeet TDT and parakeetish and Parakey",
            "corrections should prefer longer phrases and respect word boundaries"
        )
        try expect(
            applied.appliedCount,
            equals: 2,
            "correction count should track applied non-overlapping replacements"
        )

        let transferred = try TranscriptCorrectionsTransfer.decode(
            TranscriptCorrectionsTransfer.encode([
                TranscriptCorrection(source: "  Right Option  ", replacement: "R-Option")
            ])
        )
        try expect(
            transferred,
            equals: [TranscriptCorrection(source: "Right Option", replacement: "R-Option")],
            "document transfer should round-trip normalized corrections"
        )

        let legacyData = try JSONEncoder().encode([
            TranscriptCorrection(source: "  old phrase  ", replacement: "new phrase")
        ])
        try expect(
            try TranscriptCorrectionsTransfer.decode(legacyData),
            equals: [TranscriptCorrection(source: "old phrase", replacement: "new phrase")],
            "legacy bare-array correction files should remain importable"
        )

        var oversizedDecodeRejected = false
        do {
            _ = try TranscriptCorrectionsTransfer.decode(
                Data(repeating: 0x20, count: TranscriptCorrectionsTransfer.maxFileBytes + 1)
            )
        } catch let error as TranscriptCorrectionsTransferError {
            if case .fileTooLarge = error {
                oversizedDecodeRejected = true
            }
        }
        try expect(oversizedDecodeRejected, equals: true,
                   "correction transfer should reject oversized in-memory data before decoding")

        let transferTmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
        let transferFileManager = FileManager.default
        let oversized = transferTmpDir
            .appendingPathComponent("parakey-corrections-oversized-\(UUID().uuidString).json")
        try Data(repeating: 0x20, count: TranscriptCorrectionsTransfer.maxFileBytes + 1)
            .write(to: oversized)
        defer { try? transferFileManager.removeItem(at: oversized) }
        var oversizedRejected = false
        do {
            _ = try TranscriptCorrectionsTransfer.read(from: oversized)
        } catch let error as TranscriptCorrectionsTransferError {
            if case .fileTooLarge = error {
                oversizedRejected = true
            }
        }
        try expect(oversizedRejected, equals: true,
                   "correction transfer should reject oversized files before decoding")

        let nonFile = transferTmpDir
            .appendingPathComponent("parakey-corrections-directory-\(UUID().uuidString)")
        try transferFileManager.createDirectory(at: nonFile, withIntermediateDirectories: false)
        defer { try? transferFileManager.removeItem(at: nonFile) }
        var nonFileRejected = false
        do {
            _ = try TranscriptCorrectionsTransfer.read(from: nonFile)
        } catch let error as TranscriptCorrectionsTransferError {
            if case .notRegularFile = error {
                nonFileRejected = true
            }
        }
        try expect(nonFileRejected, equals: true,
                   "correction transfer should reject non-file paths")

        let readTarget = transferTmpDir
            .appendingPathComponent("parakey-corrections-read-target-\(UUID().uuidString).json")
        try TranscriptCorrectionsTransfer.write(
            [TranscriptCorrection(source: "source", replacement: "replacement")],
            to: readTarget
        )
        defer { try? transferFileManager.removeItem(at: readTarget) }
        let readLink = transferTmpDir
            .appendingPathComponent("parakey-corrections-read-link-\(UUID().uuidString).json")
        try transferFileManager.createSymbolicLink(at: readLink, withDestinationURL: readTarget)
        defer { try? transferFileManager.removeItem(at: readLink) }
        var symlinkReadRejected = false
        do {
            _ = try TranscriptCorrectionsTransfer.read(from: readLink)
        } catch let error as TranscriptCorrectionsTransferError {
            if case .notRegularFile = error {
                symlinkReadRejected = true
            }
        }
        try expect(symlinkReadRejected, equals: true,
                   "correction transfer should reject reads through leaf symlinks")

        let writeTarget = transferTmpDir
            .appendingPathComponent("parakey-corrections-write-target-\(UUID().uuidString).json")
        try Data("target\n".utf8).write(to: writeTarget)
        defer { try? transferFileManager.removeItem(at: writeTarget) }
        let writeLink = transferTmpDir
            .appendingPathComponent("parakey-corrections-write-link-\(UUID().uuidString).json")
        try transferFileManager.createSymbolicLink(at: writeLink, withDestinationURL: writeTarget)
        defer { try? transferFileManager.removeItem(at: writeLink) }
        var symlinkWriteRejected = false
        do {
            try TranscriptCorrectionsTransfer.write(
                [TranscriptCorrection(source: "source", replacement: "replacement")],
                to: writeLink
            )
        } catch let error as TranscriptCorrectionsTransferError {
            if case .notRegularFile = error {
                symlinkWriteRejected = true
            }
        }
        try expect(symlinkWriteRejected, equals: true,
                   "correction transfer should reject writes through leaf symlinks")
        try expect(
            String(data: try Data(contentsOf: writeTarget), encoding: .utf8),
            equals: "target\n",
            "correction transfer symlink rejection should leave the target untouched"
        )

        let remoteOnlyChange = mergedTranscriptCorrectionsForSync(
            base: [TranscriptCorrection(source: "old phrase", replacement: "old")],
            local: [TranscriptCorrection(source: "old phrase", replacement: "old")],
            remote: [TranscriptCorrection(source: "old phrase", replacement: "remote")]
        )
        try expect(
            remoteOnlyChange,
            equals: TranscriptCorrectionSyncMergeResult(
                corrections: [TranscriptCorrection(source: "old phrase", replacement: "remote")],
                conflictingSources: []
            ),
            "sync merge should accept remote changes when local has not changed"
        )

        let nonConflictingMerge = mergedTranscriptCorrectionsForSync(
            base: [
                TranscriptCorrection(source: "shared", replacement: "old"),
                TranscriptCorrection(source: "removed locally", replacement: "old")
            ],
            local: [TranscriptCorrection(source: "shared", replacement: "local")],
            remote: [
                TranscriptCorrection(source: "shared", replacement: "old"),
                TranscriptCorrection(source: "removed locally", replacement: "old"),
                TranscriptCorrection(source: "remote only", replacement: "remote")
            ]
        )
        try expect(
            nonConflictingMerge,
            equals: TranscriptCorrectionSyncMergeResult(
                corrections: [
                    TranscriptCorrection(source: "shared", replacement: "local"),
                    TranscriptCorrection(source: "remote only", replacement: "remote")
                ],
                conflictingSources: []
            ),
            "sync merge should combine non-conflicting local edits, local deletes, and remote additions"
        )

        let conflictingMerge = mergedTranscriptCorrectionsForSync(
            base: [TranscriptCorrection(source: "same source", replacement: "old")],
            local: [TranscriptCorrection(source: "same source", replacement: "local")],
            remote: [TranscriptCorrection(source: "same source", replacement: "remote")]
        )
        try expect(
            conflictingMerge,
            equals: TranscriptCorrectionSyncMergeResult(corrections: [],
                                                        conflictingSources: ["same source"]),
            "sync merge should report same-source edits that changed differently on both sides"
        )

        let normalizedSyncPath = normalizedCorrectionSyncFilePath(" /tmp/superdictate/../SuperDictate Corrections.superdictate-corrections\n")
        try expect(
            normalizedSyncPath,
            equals: "/tmp/SuperDictate Corrections.superdictate-corrections",
            "correction sync path normalization should trim and standardize absolute paths"
        )
        try expect(
            normalizedCorrectionSyncFilePath("relative/path.superdictate-corrections"),
            equals: nil,
            "correction sync path normalization should reject relative paths"
        )
        try expect(
            normalizedCorrectionSyncFilePath("/tmp/\u{0}superdictate.superdictate-corrections"),
            equals: nil,
            "correction sync path normalization should reject NUL bytes"
        )
        try expect(
            normalizedCorrectionSyncFilePath("/" + String(repeating: "x", count: MAX_CORRECTION_SYNC_PATH_BYTES)),
            equals: nil,
            "correction sync path normalization should reject oversized paths"
        )

        // Reject leaf-symlinks at the sync path so an attacker who can
        // plant a symlink at the persisted sync-file location cannot use
        // the periodic auto-write to overwrite an unrelated file.
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
        let fm = FileManager.default
        let nonexistent = tmpDir.appendingPathComponent("parakey-sync-test-missing-\(UUID().uuidString).json")
        try validateCorrectionSyncPath(nonexistent) // missing files are allowed (first-time write)

        let regular = tmpDir.appendingPathComponent("parakey-sync-test-regular-\(UUID().uuidString).json")
        try Data("{}".utf8).write(to: regular)
        defer { try? fm.removeItem(at: regular) }
        try validateCorrectionSyncPath(regular)

        let target = tmpDir.appendingPathComponent("parakey-sync-test-target-\(UUID().uuidString).json")
        try Data("{}".utf8).write(to: target)
        defer { try? fm.removeItem(at: target) }
        let link = tmpDir.appendingPathComponent("parakey-sync-test-link-\(UUID().uuidString).json")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        defer { try? fm.removeItem(at: link) }
        var rejected = false
        do {
            try validateCorrectionSyncPath(link)
        } catch is TranscriptCorrectionsSyncPathError {
            rejected = true
        }
        try expect(rejected, equals: true,
                   "validateCorrectionSyncPath should reject a leaf symlink")
        try expect(
            shouldStopCorrectionSync(afterPathValidationError: TranscriptCorrectionsSyncPathError.isSymbolicLink),
            equals: true,
            "unsafe sync paths should stop configured correction sync"
        )
        try expect(
            shouldStopCorrectionSync(afterPathValidationError: NSError(domain: "ParakeyTest", code: 1)),
            equals: false,
            "unrelated sync errors should not clear the configured correction sync path"
        )
        try expect(
            correctionSyncFingerprint(for: link),
            equals: nil,
            "correction sync fingerprinting should not follow leaf symlinks"
        )

        let sameSizeA = tmpDir.appendingPathComponent("parakey-sync-fingerprint-a-\(UUID().uuidString).json")
        let sameSizeB = tmpDir.appendingPathComponent("parakey-sync-fingerprint-b-\(UUID().uuidString).json")
        try Data("aaaa".utf8).write(to: sameSizeA)
        try Data("bbbb".utf8).write(to: sameSizeB)
        defer {
            try? fm.removeItem(at: sameSizeA)
            try? fm.removeItem(at: sameSizeB)
        }
        let sharedModifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try fm.setAttributes([.modificationDate: sharedModifiedAt], ofItemAtPath: sameSizeA.path)
        try fm.setAttributes([.modificationDate: sharedModifiedAt], ofItemAtPath: sameSizeB.path)

        guard let fingerprintA = correctionSyncFingerprint(for: sameSizeA),
              let fingerprintB = correctionSyncFingerprint(for: sameSizeB) else {
            throw SelfTestFailure.failed("correction sync fingerprint should read regular files")
        }
        try expect(
            fingerprintA.size,
            equals: fingerprintB.size,
            "same-size sync files should have equal size metadata in the fingerprint"
        )
        try expect(
            fingerprintA == fingerprintB,
            equals: false,
            "correction sync fingerprint should detect content changes even when file size matches"
        )

        // The full legal correction set must encode within the
        // transfer cap: 512 entries at the per-field caps is ~2.4 MB
        // encoded, which silently failed to save under the old 2 MiB
        // cap. Also pin that it really is over 2 MiB, documenting why
        // the cap moved to 4 MiB.
        let worstCaseSet = (0..<MAX_TRANSCRIPT_CORRECTIONS).map { index in
            TranscriptCorrection(
                source: String(format: "%06d-", index)
                    + String(repeating: "s", count: MAX_TRANSCRIPT_CORRECTION_SOURCE_BYTES - 7),
                replacement: String(repeating: "r", count: MAX_TRANSCRIPT_CORRECTION_REPLACEMENT_BYTES)
            )
        }
        let worstCaseData = try TranscriptCorrectionsTransfer.encode(worstCaseSet)
        try expect(
            worstCaseData.count > 2 * 1024 * 1024,
            equals: true,
            "worst-case legal correction set should exceed the old 2 MiB cap (why the cap is now larger)"
        )
        try expect(
            worstCaseData.count <= TranscriptCorrectionsTransfer.maxFileBytes,
            equals: true,
            "worst-case legal correction set must fit the transfer cap with JSON-overhead headroom"
        )
        try expect(
            try TranscriptCorrectionsTransfer.decode(worstCaseData).count,
            equals: MAX_TRANSCRIPT_CORRECTIONS,
            "worst-case legal correction set should round-trip through the transfer cap"
        )

        // Near the correction cap a merge can briefly exceed it. The
        // sync baseline must store the same normalized (capped) list
        // that is written to the file — a raw over-cap baseline makes
        // the capped-out entry look like a local deletion later.
        let sharedNearCap = (0..<(MAX_TRANSCRIPT_CORRECTIONS - 1)).map {
            TranscriptCorrection(source: "shared-\($0)", replacement: "same")
        }
        let nearCapMerge = mergedTranscriptCorrectionsForSync(
            base: sharedNearCap,
            local: sharedNearCap + [TranscriptCorrection(source: "local-extra", replacement: "local")],
            remote: sharedNearCap + [TranscriptCorrection(source: "remote-extra", replacement: "remote")]
        )
        try expect(
            nearCapMerge.conflictingSources,
            equals: [],
            "near-cap merge with disjoint additions should not conflict"
        )
        try expect(
            nearCapMerge.corrections.count,
            equals: MAX_TRANSCRIPT_CORRECTIONS + 1,
            "near-cap merge result can exceed the cap before normalization"
        )
        let nearCapNormalized = normalizedTranscriptCorrections(nearCapMerge.corrections)
        try expect(
            nearCapNormalized.count,
            equals: MAX_TRANSCRIPT_CORRECTIONS,
            "normalizing the near-cap merge result should drop the over-cap entry"
        )
        try expect(
            nearCapNormalized.contains(TranscriptCorrection(source: "local-extra", replacement: "local")),
            equals: true,
            "normalization keeps the earlier (local) addition at the cap"
        )
        try expect(
            nearCapNormalized.contains(TranscriptCorrection(source: "remote-extra", replacement: "remote")),
            equals: false,
            "the capped-out remote addition is exactly what the baseline must also drop"
        )

        // Fingerprinting the bytes we wrote must agree with a fresh
        // disk fingerprint when nobody touched the file in between —
        // the sync path uses the in-memory form so a provider replacing
        // the file in the write-to-fingerprint window is still detected
        // by the next scan.
        let fingerprintWriteTarget = tmpDir
            .appendingPathComponent("parakey-sync-written-fingerprint-\(UUID().uuidString).json")
        let fingerprintWrittenData = try TranscriptCorrectionsTransfer.write(
            [TranscriptCorrection(source: "fingerprint", replacement: "match")],
            to: fingerprintWriteTarget
        )
        defer { try? fm.removeItem(at: fingerprintWriteTarget) }
        guard let fingerprintFromDisk = correctionSyncFingerprint(for: fingerprintWriteTarget) else {
            throw SelfTestFailure.failed("disk fingerprint should be readable right after a write")
        }
        try expect(
            correctionSyncFingerprint(forWrittenData: fingerprintWrittenData, at: fingerprintWriteTarget),
            equals: fingerprintFromDisk,
            "fingerprint of written bytes should match the disk fingerprint of an untouched file"
        )

        // Counted decode keeps the file's pre-normalization entry count
        // so the import dialog can disclose truncation.
        let countedOriginal = (0..<(MAX_TRANSCRIPT_CORRECTIONS + 5)).map {
            TranscriptCorrection(source: "counted-\($0)", replacement: "kept")
        }
        let countedEncoder = JSONEncoder()
        countedEncoder.dateEncodingStrategy = .iso8601
        let countedDocument = TranscriptCorrectionsDocument(
            schemaVersion: TranscriptCorrectionsTransfer.schemaVersion,
            exportedAt: Date(),
            appVersion: currentBundleVersion(),
            corrections: countedOriginal
        )
        let counted = try TranscriptCorrectionsTransfer.decodeCounted(countedEncoder.encode(countedDocument))
        try expect(
            counted.originalCount,
            equals: MAX_TRANSCRIPT_CORRECTIONS + 5,
            "counted decode should report the file's pre-normalization entry count"
        )
        try expect(
            counted.corrections.count,
            equals: MAX_TRANSCRIPT_CORRECTIONS,
            "counted decode should still normalize down to the correction cap"
        )
        let countedLegacy = try TranscriptCorrectionsTransfer.decodeCounted(
            try JSONEncoder().encode([TranscriptCorrection(source: "  legacy  ", replacement: "entry")])
        )
        try expect(
            countedLegacy,
            equals: TranscriptCorrectionsTransfer.CountedDecodeResult(
                corrections: [TranscriptCorrection(source: "legacy", replacement: "entry")],
                originalCount: 1
            ),
            "counted decode should support legacy bare-array files"
        )

        // Import dialog copy: state the original count when entries
        // will be dropped, and warn before a cap-overflowing merge.
        try expect(
            correctionImportCountText(sourceName: "file.superdictate-corrections",
                                      originalCount: 3,
                                      keptCount: 3),
            equals: "file.superdictate-corrections contains 3 corrections.",
            "import count text should stay simple when nothing is dropped"
        )
        let truncatedImportText = correctionImportCountText(
            sourceName: "big.superdictate-corrections",
            originalCount: MAX_TRANSCRIPT_CORRECTIONS + 88,
            keptCount: MAX_TRANSCRIPT_CORRECTIONS
        )
        try expect(
            truncatedImportText.contains("contains \(MAX_TRANSCRIPT_CORRECTIONS + 88) entries"),
            equals: true,
            "import count text should state the file's original entry count when entries are dropped"
        )
        try expect(
            truncatedImportText.contains("first \(MAX_TRANSCRIPT_CORRECTIONS)"),
            equals: true,
            "import count text should state how many corrections will actually be kept"
        )
        try expect(
            correctionImportMergeCapWarningText(existingCount: 10, newCount: 10),
            equals: nil,
            "merge cap warning should stay silent when the merged set fits"
        )
        try expect(
            correctionImportMergeCapWarningText(existingCount: MAX_TRANSCRIPT_CORRECTIONS,
                                                newCount: 8)?.contains("8 would be dropped"),
            equals: true,
            "merge cap warning should state how many corrections a merge would drop"
        )
    }

    private static func testFillerWordRemoval() throws {
        // Mid-sentence filler with surrounding commas → orphan comma
        // gets collapsed.
        let mid = FillerWordRemover.apply(to: "So, um, I was going.")
        try expect(mid.text, equals: "So, I was going.", "mid-sentence filler should leave a single comma")
        try expect(mid.removedCount, equals: 1, "mid-sentence filler removal count")

        // Sentence-initial filler with leading-comma cleanup AND
        // capitalisation restored (the original 'U' was uppercase).
        let initial = FillerWordRemover.apply(to: "Um, hello.")
        try expect(initial.text, equals: "Hello.", "sentence-initial filler should re-capitalise the next word")
        try expect(initial.removedCount, equals: 1, "sentence-initial filler removal count")

        let secondSentence = FillerWordRemover.apply(to: "This is the first sentence. Um this is the second sentence.")
        try expect(
            secondSentence.text,
            equals: "This is the first sentence. This is the second sentence.",
            "sentence-initial filler after a period should re-capitalise the next word"
        )
        try expect(secondSentence.removedCount, equals: 1, "second-sentence filler removal count")

        let secondSentenceWithComma = FillerWordRemover.apply(to: "This is the first sentence. Um, this is the second sentence.")
        try expect(
            secondSentenceWithComma.text,
            equals: "This is the first sentence. This is the second sentence.",
            "sentence-initial filler after a period should not leave an orphan comma"
        )
        try expect(secondSentenceWithComma.removedCount, equals: 1, "second-sentence comma filler removal count")

        let secondSentenceQuestion = FillerWordRemover.apply(to: "This is the first sentence. Um? this is the second sentence.")
        try expect(
            secondSentenceQuestion.text,
            equals: "This is the first sentence. This is the second sentence.",
            "sentence-initial filler with its own punctuation should take that punctuation with it"
        )
        try expect(secondSentenceQuestion.removedCount, equals: 1, "second-sentence question filler removal count")

        let capitalizedMidSentence = FillerWordRemover.apply(to: "This is not a sentence boundary Um this stays lowercase.")
        try expect(
            capitalizedMidSentence.text,
            equals: "This is not a sentence boundary this stays lowercase.",
            "capitalized fillers away from sentence starts should not force capitalization"
        )
        try expect(capitalizedMidSentence.removedCount, equals: 1, "capitalized mid-sentence filler removal count")

        // Bare filler with adjacent punctuation collapses to empty.
        let bare = FillerWordRemover.apply(to: "Um.")
        try expect(bare.text, equals: "", "bare filler with trailing punctuation should leave empty string")
        try expect(bare.removedCount, equals: 1, "bare filler removal count")

        // Filler with no surrounding punctuation just leaves a space
        // that gets collapsed away.
        let inline = FillerWordRemover.apply(to: "I'm uh going to the store.")
        try expect(inline.text, equals: "I'm going to the store.", "inline filler should collapse the leftover whitespace")
        try expect(inline.removedCount, equals: 1, "inline filler removal count")

        // Compound interjection "uh-huh" must NOT match — the hyphen is
        // part of the boundary class.
        let uhHuh = FillerWordRemover.apply(to: "Yeah, uh-huh.")
        try expect(uhHuh.text, equals: "Yeah, uh-huh.", "uh-huh must not be stripped")
        try expect(uhHuh.removedCount, equals: 0, "uh-huh removal count")

        // Words that *contain* a filler substring must not match. "her"
        // contains "er", "sum" contains "um", "exercise" contains "er".
        let contains = FillerWordRemover.apply(to: "Her sum exercise is harder.")
        try expect(contains.text, equals: "Her sum exercise is harder.", "filler substrings inside larger words must be preserved")
        try expect(contains.removedCount, equals: 0, "no removals when fillers are embedded in real words")

        // Multiple fillers in one utterance all get stripped.
        let multi = FillerWordRemover.apply(to: "Um, ah, I uh think so.")
        try expect(multi.text, equals: "I think so.", "multiple fillers should all be removed and artifacts cleaned up")
        try expect(multi.removedCount, equals: 3, "multi-filler removal count")

        // Empty input should be a no-op.
        let empty = FillerWordRemover.apply(to: "")
        try expect(empty.text, equals: "", "empty input passes through unchanged")
        try expect(empty.removedCount, equals: 0, "empty input has zero removals")

        // No fillers present → identical text, zero removals.
        let clean = FillerWordRemover.apply(to: "Hello world.")
        try expect(clean.text, equals: "Hello world.", "filler-free input passes through unchanged")
        try expect(clean.removedCount, equals: 0, "filler-free input has zero removals")

        // Elongated fillers — common in real dictation. The word-
        // boundary lookahead would have rejected these without the
        // per-pattern trailing-repeat allowance.
        let elongatedUm = FillerWordRemover.apply(to: "Ummm, hello.")
        try expect(elongatedUm.text, equals: "Hello.", "ummm should be stripped like um")
        try expect(elongatedUm.removedCount, equals: 1, "elongated um removal count")

        let elongatedUh = FillerWordRemover.apply(to: "Uhhh I think so.")
        try expect(elongatedUh.text, equals: "I think so.", "uhhh should be stripped like uh")
        try expect(elongatedUh.removedCount, equals: 1, "elongated uh removal count")

        let elongatedAh = FillerWordRemover.apply(to: "Ahhh, that makes sense.")
        try expect(elongatedAh.text, equals: "That makes sense.", "ahhh should be stripped like ah")
        try expect(elongatedAh.removedCount, equals: 1, "elongated ah removal count")

        // `hm+` covers both "hm" (single m) and "hmmm" (extended). The
        // earlier fixed-list "hmm" entry rejected the single-m form.
        let shortHm = FillerWordRemover.apply(to: "Hm, interesting.")
        try expect(shortHm.text, equals: "Interesting.", "short hm should be stripped like hmm")
        try expect(shortHm.removedCount, equals: 1, "short hm removal count")

        // Words containing the new repeat-friendly patterns must still
        // pass through. "ohm" embeds "hm" but has a leading letter.
        let embedded = FillerWordRemover.apply(to: "An ohm is a unit.")
        try expect(embedded.text, equals: "An ohm is a unit.", "ohm must not match hm")
        try expect(embedded.removedCount, equals: 0, "ohm should produce zero removals")

        // Two consecutive fillers used to leave ",," because the
        // comma-collapse pass was single-pass/non-overlapping: it
        // consumed one ", ," pair and the whitespace-before-punctuation
        // pass then glued the leftover " ," into ",,".
        let consecutive = FillerWordRemover.apply(to: "So, um, uh, yes.")
        try expect(consecutive.text, equals: "So, yes.", "consecutive fillers should collapse to a single comma")
        try expect(consecutive.removedCount, equals: 2, "consecutive filler removal count")

        // Three consecutive fillers exercise runs longer than one
        // collapse step.
        let tripleRun = FillerWordRemover.apply(to: "He said, um, uh, er, no.")
        try expect(tripleRun.text, equals: "He said, no.", "a run of three fillers should collapse to a single comma")
        try expect(tripleRun.removedCount, equals: 3, "triple filler removal count")

        // Consecutive fillers mid-sentence keep exactly one comma,
        // matching the single-filler behavior above.
        let midRun = FillerWordRemover.apply(to: "I think, um, uh, we should go.")
        try expect(midRun.text, equals: "I think, we should go.", "mid-sentence consecutive fillers should keep one comma")
        try expect(midRun.removedCount, equals: 2, "mid-sentence consecutive filler removal count")

        // Trailing filler before terminal punctuation used to leave
        // ",." because no pass cleaned a comma glued onto a period.
        let trailing = FillerWordRemover.apply(to: "That's all, um.")
        try expect(trailing.text, equals: "That's all.", "trailing filler should not leave a comma before the period")
        try expect(trailing.removedCount, equals: 1, "trailing filler removal count")

        let beforeQuestion = FillerWordRemover.apply(to: "Is that right, um?")
        try expect(beforeQuestion.text, equals: "Is that right?", "filler before a question mark should not leave a comma")
        try expect(beforeQuestion.removedCount, equals: 1, "filler before question mark removal count")

        let beforeBang = FillerWordRemover.apply(to: "Stop, um!")
        try expect(beforeBang.text, equals: "Stop!", "filler before an exclamation mark should not leave a comma")
        try expect(beforeBang.removedCount, equals: 1, "filler before exclamation mark removal count")

        // Sentence-initial filler with its own terminal punctuation:
        // the leading-strip class must include "?" and "!" or the
        // orphaned punctuation survives ("Um? What?" → "? What?").
        let leadingQuestion = FillerWordRemover.apply(to: "Um? What?")
        try expect(leadingQuestion.text, equals: "What?", "leading filler question should take its punctuation with it")
        try expect(leadingQuestion.removedCount, equals: 1, "leading filler question removal count")

        let leadingBang = FillerWordRemover.apply(to: "Ah! Careful.")
        try expect(leadingBang.text, equals: "Careful.", "leading filler exclamation should take its punctuation with it")
        try expect(leadingBang.removedCount, equals: 1, "leading filler exclamation removal count")
    }

    private static func testAudioInputDeviceFiltering() throws {
        let pseudo = AudioInputDevice(id: 1,
                                      uid: "CADefaultDeviceAggregate-42159-0",
                                      name: "CADefaultDeviceAggregate-42159-0")
        let real = AudioInputDevice(id: 2,
                                    uid: "real-yeti-nano",
                                    name: "Yeti Nano")

        try expect(
            isDefaultAggregateAudioInputDevice(pseudo),
            equals: true,
            "CoreAudio default aggregate devices should be recognized"
        )
        try expect(
            isDefaultAggregateAudioInputDevice(real),
            equals: false,
            "named microphones should remain selectable"
        )
        try expect(
            normalizedInputDevicePreference(" Yeti Nano\n"),
            equals: "Yeti Nano",
            "input device preferences should be trimmed before storing"
        )
        try expect(
            normalizedInputDevicePreference(pseudo.uid),
            equals: nil,
            "input device preferences should reject CoreAudio default aggregates"
        )
        try expect(
            normalizedInputDevicePreference("real\u{0}device"),
            equals: nil,
            "input device preferences should reject NUL bytes"
        )
        try expect(
            normalizedInputDevicePreference(String(repeating: "x", count: MAX_INPUT_DEVICE_PREFERENCE_BYTES + 1)),
            equals: nil,
            "input device preferences should reject oversized values"
        )
        try expect(
            audioInputDevice(matching: pseudo.uid, in: [pseudo, real])?.uid,
            equals: nil,
            "CoreAudio default aggregate preferences should fall back to system default"
        )
        try expect(
            audioInputDevice(matching: " real-yeti-nano\n", in: [real])?.uid,
            equals: "real-yeti-nano",
            "input device preferences should resolve after trimming"
        )
        try expect(
            audioInputDevice(matching: "Yeti Nano", in: [real])?.uid,
            equals: "real-yeti-nano",
            "named microphone preferences should still resolve by display name"
        )
    }

    private static func testSpeechModelStartupStatus() throws {
        try expect(
            speechModelStartupStatusTitle(.init(fractionCompleted: 0,
                                                phase: .listing)),
            equals: "Checking speech model files…",
            "listing phase should be visible during first-launch model setup"
        )
        try expect(
            speechModelStartupStatusTitle(.init(fractionCompleted: 0.25,
                                                phase: .downloading(completedFiles: 2, totalFiles: 4))),
            equals: "Downloading speech model… 50% (2/4)",
            "download phase should show quantized progress"
        )
        try expect(
            speechModelStartupStatusTitle(.init(fractionCompleted: 0.5,
                                                phase: .downloading(completedFiles: 0, totalFiles: 0))),
            equals: "Loading cached speech model…",
            "cached model load should not pretend to download files"
        )
        try expect(
            speechModelStartupStatusTitle(.init(fractionCompleted: 1,
                                                phase: .compiling(modelName: "Encoder.mlmodelc"))),
            equals: "Preparing speech model…",
            "compile phase should be visible without exposing model internals"
        )
        try expect(
            speechModelStartupProgressValue(.init(fractionCompleted: 0,
                                                  phase: .listing)),
            equals: nil,
            "listing phase should show indeterminate model progress"
        )
        try expect(
            speechModelStartupProgressValue(.init(fractionCompleted: 0.25,
                                                  phase: .downloading(completedFiles: 2, totalFiles: 4))),
            equals: 0.5,
            "download phase should expose normalized model progress"
        )
        try expect(
            speechModelStartupProgressValue(.init(fractionCompleted: 0.5,
                                                  phase: .downloading(completedFiles: 0, totalFiles: 0))),
            equals: nil,
            "cached model load should show indeterminate model progress"
        )
        try expect(
            speechModelStartupProgressValue(.init(fractionCompleted: 1,
                                                  phase: .compiling(modelName: "Encoder.mlmodelc"))),
            equals: nil,
            "compile phase should show indeterminate model progress"
        )
        let requiredBytes = speechModelDownloadRequiredBytes(for: .multilingualV3,
                                                             headroomBytes: 100)
        try expect(
            requiredBytes,
            equals: 700 * 1024 * 1024 + 100,
            "speech model download requirement should include model estimate plus headroom"
        )
        try expect(
            speechModelDiskSpaceFailureDetail(profile: .multilingualV3,
                                              availableBytes: requiredBytes - 1,
                                              requiredBytes: requiredBytes)?.contains("Free some disk space"),
            equals: true,
            "low disk-space failures should explain how to recover"
        )
        try expect(
            speechModelDiskSpaceFailureDetail(profile: .multilingualV3,
                                              availableBytes: requiredBytes,
                                              requiredBytes: requiredBytes),
            equals: nil,
            "disk-space check should pass once required space is available"
        )
        try expect(
            speechModelDiskSpaceFailureDetail(profile: .multilingualV3,
                                              availableBytes: nil,
                                              requiredBytes: requiredBytes),
            equals: nil,
            "unknown disk-space readings should not block model startup"
        )
    }

    private static func testModelIntegrity() throws {
        try testSpeechModelCachePathSafety()

        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("parakey-model-integrity-\(UUID().uuidString)",
                                    isDirectory: true)
        let modelDir = root.appendingPathComponent("Toy.mlmodelc", isDirectory: true)
        try fm.createDirectory(at: modelDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let modelFile = modelDir.appendingPathComponent("model.mil")
        try Data("hello".utf8).write(to: modelFile)
        let expected = [
            ModelFileDigest(
                relativePath: "Toy.mlmodelc/model.mil",
                sha256: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
            )
        ]
        try ModelIntegrity.verifyFiles(root: root,
                                       expectedFiles: expected,
                                       strictDirectories: ["Toy.mlmodelc"])

        var rejectedMismatch = false
        do {
            try ModelIntegrity.verifyFiles(
                root: root,
                expectedFiles: [
                    ModelFileDigest(relativePath: "Toy.mlmodelc/model.mil",
                                    sha256: String(repeating: "0", count: 64))
                ],
                strictDirectories: ["Toy.mlmodelc"]
            )
        } catch is ModelIntegrityError {
            rejectedMismatch = true
        }
        try expect(rejectedMismatch, equals: true,
                   "model integrity should reject digest mismatches")

        try Data("extra".utf8).write(to: modelDir.appendingPathComponent("extra.bin"))
        var rejectedUnexpectedFile = false
        do {
            try ModelIntegrity.verifyFiles(root: root,
                                           expectedFiles: expected,
                                           strictDirectories: ["Toy.mlmodelc"])
        } catch is ModelIntegrityError {
            rejectedUnexpectedFile = true
        }
        try expect(rejectedUnexpectedFile, equals: true,
                   "model integrity should reject unpinned files in strict model bundles")

        try fm.removeItem(at: modelDir.appendingPathComponent("extra.bin"))
        try fm.createDirectory(at: modelDir.appendingPathComponent("empty-extra", isDirectory: true),
                               withIntermediateDirectories: true)
        var rejectedUnexpectedDirectory = false
        do {
            try ModelIntegrity.verifyFiles(root: root,
                                           expectedFiles: expected,
                                           strictDirectories: ["Toy.mlmodelc"])
        } catch is ModelIntegrityError {
            rejectedUnexpectedDirectory = true
        }
        try expect(rejectedUnexpectedDirectory, equals: true,
                   "model integrity should reject unpinned directories in strict model bundles")

        var rejectedBadDigest = false
        do {
            try ModelIntegrity.verifyFiles(
                root: root,
                expectedFiles: [
                    ModelFileDigest(relativePath: "Toy.mlmodelc/model.mil",
                                    sha256: "not-a-sha256")
                ],
                strictDirectories: ["Toy.mlmodelc"]
            )
        } catch is ModelIntegrityError {
            rejectedBadDigest = true
        }
        try expect(rejectedBadDigest, equals: true,
                   "model integrity should reject malformed manifest digests")

        var rejectedDotSegment = false
        do {
            try ModelIntegrity.verifyFiles(
                root: root,
                expectedFiles: [
                    ModelFileDigest(
                        relativePath: "Toy.mlmodelc/./model.mil",
                        sha256: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
                    )
                ],
                strictDirectories: ["Toy.mlmodelc"]
            )
        } catch is ModelIntegrityError {
            rejectedDotSegment = true
        }
        try expect(rejectedDotSegment, equals: true,
                   "model integrity should reject dot path segments")

        let symlinkedModelFile = modelDir.appendingPathComponent("model-link.mil")
        try fm.createSymbolicLink(at: symlinkedModelFile, withDestinationURL: modelFile)
        var rejectedSymlinkHashRead = false
        do {
            _ = try ModelIntegrity.sha256Hex(of: symlinkedModelFile,
                                             relativePath: "Toy.mlmodelc/model-link.mil")
        } catch is ModelIntegrityError {
            rejectedSymlinkHashRead = true
        }
        try expect(rejectedSymlinkHashRead, equals: true,
                   "model integrity hashing should not follow leaf symlinks")

        let localParakeetV3Cache = speechModelCacheDirectory(for: .multilingualV3)
        if fm.fileExists(atPath: localParakeetV3Cache.path) {
            try ModelIntegrity.verifyParakeetV3Model(at: localParakeetV3Cache)
        }
    }

    private static func testSpeechModelCachePathSafety() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("parakey-cache-safety-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("FluidAudio", isDirectory: true)
        let cache = support.appendingPathComponent("Models/parakeet-v3", isDirectory: true)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try expect(
            isSafeSpeechModelCacheDirectory(
                cache,
                fluidAudioSupportDirectory: support
            ),
            equals: true,
            "speech model cache reset should allow nested FluidAudio cache paths"
        )
        try expect(
            isExistingSpeechModelCacheDirectorySafeForRemoval(cache,
                                                             fluidAudioSupportDirectory: support),
            equals: true,
            "speech model cache reset should allow existing plain cache directories"
        )
        try expect(
            isSafeSpeechModelCacheDirectory(support, fluidAudioSupportDirectory: support),
            equals: false,
            "speech model cache reset should not remove the FluidAudio support root"
        )
        try expect(
            isSafeSpeechModelCacheDirectory(
                support.deletingLastPathComponent().appendingPathComponent("FluidAudioBackup/parakeet-v3", isDirectory: true),
                fluidAudioSupportDirectory: support
            ),
            equals: false,
            "speech model cache reset should reject sibling support directories"
        )
        try expect(
            isSafeSpeechModelCacheDirectory(
                support.appendingPathComponent("../Outside/parakeet-v3", isDirectory: true),
                fluidAudioSupportDirectory: support
            ),
            equals: false,
            "speech model cache reset should reject paths that normalize outside FluidAudio support"
        )

        let outside = root.appendingPathComponent("Outside", isDirectory: true)
        let outsideCache = outside.appendingPathComponent("parakeet-v3", isDirectory: true)
        try fm.createDirectory(at: outsideCache, withIntermediateDirectories: true)

        let leafLink = support.appendingPathComponent("Models/link-cache", isDirectory: true)
        try fm.createSymbolicLink(at: leafLink, withDestinationURL: outsideCache)
        try expect(
            isSafeSpeechModelCacheDirectory(leafLink, fluidAudioSupportDirectory: support),
            equals: true,
            "speech model cache reset path check should remain string-only"
        )
        try expect(
            isExistingSpeechModelCacheDirectorySafeForRemoval(leafLink,
                                                             fluidAudioSupportDirectory: support),
            equals: false,
            "speech model cache reset should reject leaf symlink directories before deletion"
        )

        let linkedParent = support.appendingPathComponent("LinkedModels", isDirectory: true)
        try fm.createSymbolicLink(at: linkedParent, withDestinationURL: outside)
        try expect(
            isExistingSpeechModelCacheDirectorySafeForRemoval(
                linkedParent.appendingPathComponent("parakeet-v3", isDirectory: true),
                fluidAudioSupportDirectory: support
            ),
            equals: false,
            "speech model cache reset should reject symlinked parent directories before deletion"
        )
        try expect(
            isSafeSpeechModelCacheDirectory(speechModelCacheDirectory(for: .multilingualV3)),
            equals: true,
            "FluidAudio v3 cache path should remain inside FluidAudio Application Support"
        )
        let defaultV3Cache = speechModelCacheDirectory(for: .multilingualV3)
        if fm.fileExists(atPath: defaultV3Cache.path) {
            try expect(
                isExistingSpeechModelCacheDirectorySafeForRemoval(defaultV3Cache),
                equals: true,
                "existing FluidAudio v3 cache path should remain removable"
            )
        }
    }

    private static func testUpdate() throws {
        try testUpdateCheckParsing()
        try testUpdateCheckState()
        try testDirectUpdateManifest()
        try testUpdateHelperScript()
        try testDirectUpdateReplacement()
        try testUpdateProgressState()
    }

    private static func testDirectUpdateManifest() throws {
        let checksum = String(repeating: "a", count: 64)
        let validData = Data("{\"version\":\"9.8.7\",\"sha256\":\"\(checksum)\"}".utf8)
        try expect(
            try SuperDictateUpdateInstaller.parseManifest(validData,
                                                           expectedVersion: "9.8.7"),
            equals: SuperDictateUpdateManifest(version: "9.8.7", sha256: checksum),
            "direct update manifest should parse a canonical version and SHA-256"
        )

        do {
            _ = try SuperDictateUpdateInstaller.parseManifest(validData,
                                                               expectedVersion: "9.8.8")
            throw SelfTestFailure.failed("direct update manifest should reject version disagreement")
        } catch let error as SuperDictateUpdateInstallerError {
            try expect(error,
                       equals: .manifestVersionMismatch(expected: "9.8.8", actual: "9.8.7"),
                       "direct update manifest should describe version disagreement")
        }

        let invalidChecksum = Data(#"{"version":"9.8.7","sha256":"not-a-checksum"}"#.utf8)
        do {
            _ = try SuperDictateUpdateInstaller.parseManifest(invalidChecksum,
                                                               expectedVersion: "9.8.7")
            throw SelfTestFailure.failed("direct update manifest should reject malformed checksums")
        } catch let error as SuperDictateUpdateInstallerError {
            try expect(error, equals: .invalidManifest,
                       "direct update manifest should reject malformed checksums")
        }
    }

    private static func testUpdateCheckParsing() throws {
        let ok = HTTPURLResponse(url: GITHUB_LATEST_RELEASE_URL,
                                 statusCode: 200,
                                 httpVersion: nil,
                                 headerFields: nil)!
        let notFound = HTTPURLResponse(url: GITHUB_LATEST_RELEASE_URL,
                                       statusCode: 404,
                                       httpVersion: nil,
                                       headerFields: nil)!
        let releaseData = Data(
            #"{"tag_name":"v9.8.7","body":"Notes","html_url":"https://github.com/shlgd/SuperDictate/releases/tag/v9.8.7"}"#.utf8
        )

        try expect(
            UpdateCheck.parseLatest(data: releaseData, response: ok),
            equals: .success(GitHubRelease(tagName: "v9.8.7",
                                           version: "9.8.7",
                                           body: "Notes",
                                           htmlURL: "https://github.com/shlgd/SuperDictate/releases/tag/v9.8.7")),
            "update parsing should decode typed GitHub release payloads"
        )
        try expect(
            UpdateCheck.parseLatest(data: releaseData, response: notFound),
            equals: .failure(.httpStatus(404)),
            "update parsing should reject non-2xx HTTP responses with the status code"
        )
        let rateLimited = HTTPURLResponse(url: GITHUB_LATEST_RELEASE_URL,
                                          statusCode: 403,
                                          httpVersion: nil,
                                          headerFields: nil)!
        try expect(
            UpdateCheck.parseLatest(data: releaseData, response: rateLimited),
            equals: .failure(.httpStatus(403)),
            "update parsing should surface HTTP 403 distinctly (GitHub rate limiting)"
        )
        let oversizedReleaseData = Data(
            """
            {"tag_name":"v9.8.7","body":"\(String(repeating: "x", count: UpdateCheck.maxReleaseResponseBytes))","html_url":"https://github.com/shlgd/SuperDictate/releases/tag/v9.8.7"}
            """.utf8
        )
        try expect(
            oversizedReleaseData.count > UpdateCheck.maxReleaseResponseBytes,
            equals: true,
            "oversized release response fixture should exceed the parser limit"
        )
        try expect(
            UpdateCheck.parseLatest(data: oversizedReleaseData, response: ok),
            equals: .failure(.unexpectedResponse),
            "update parsing should reject oversized release responses before decoding"
        )
        try expect(
            UpdateCheck.parseLatest(data: Data(#"{"tag_name":""}"#.utf8), response: ok),
            equals: .failure(.unexpectedResponse),
            "update parsing should reject empty release tags"
        )
        try expect(
            UpdateCheck.parseLatest(data: Data(#"{"tag_name":"latest"}"#.utf8), response: ok),
            equals: .failure(.unexpectedResponse),
            "update parsing should reject non-version release tags"
        )
        try expect(
            UpdateCheck.parseLatest(data: Data(#"{"tag_name":"v01.2.3"}"#.utf8), response: ok),
            equals: .failure(.unexpectedResponse),
            "update parsing should reject non-normal semver tags"
        )
        try expect(
            UpdateCheck.parseLatest(
                data: Data(#"{"tag_name":"v999999999999999999999999.2.3"}"#.utf8),
                response: ok
            ),
            equals: .failure(.unexpectedResponse),
            "update parsing should reject oversized numeric version parts"
        )
        try expect(
            parseSemver("999999999999999999999999.2.3"),
            equals: [Int.max, 2, 3],
            "tolerant version parsing should not overflow on oversized components"
        )
        try expect(
            normalizedSkippedUpdateVersions([
                "junk",
                "v1.2.3",
                "1.2.3",
                " V2.0.0\n",
                "01.2.3",
                "3.999999999999999999999999.0"
            ]),
            equals: ["1.2.3", "2.0.0"],
            "skipped update versions should normalize valid versions and discard malformed entries"
        )
        try expect(
            normalizedSkippedUpdateVersions((0..<(MAX_SKIPPED_UPDATE_VERSIONS + 3)).map { "1.0.\($0)" }),
            equals: (3..<(MAX_SKIPPED_UPDATE_VERSIONS + 3)).map { "1.0.\($0)" },
            "skipped update versions should keep only the most recent bounded entries"
        )
        try expect(
            UpdateCheck.parseLatest(
                data: Data(#"{"tag_name":"9.8.7","html_url":"https://example.test/v9.8.7"}"#.utf8),
                response: ok
            ),
            equals: .success(GitHubRelease(tagName: "9.8.7",
                                           version: "9.8.7",
                                           body: "",
                                           htmlURL: GITHUB_RELEASES_PAGE.absoluteString)),
            "update parsing should fall back from non-project release URLs"
        )
        try expect(
            UpdateCheck.parseLatest(
                data: Data(#"{"tag_name":"v9.8.7","html_url":"https://github.com/shlgd/SuperDictate/releases/tag/v9.8.8"}"#.utf8),
                response: ok
            ),
            equals: .success(GitHubRelease(tagName: "v9.8.7",
                                           version: "9.8.7",
                                           body: "",
                                           htmlURL: GITHUB_RELEASES_PAGE.absoluteString)),
            "update parsing should fall back when release URL tag does not match the payload tag"
        )
        // Manual-check alert copy: each failure kind gets its own
        // explanation instead of blaming the network for everything.
        try expect(
            manualUpdateCheckFailureText(.network).contains("internet connection"),
            equals: true,
            "network failure text should point at connectivity"
        )
        try expect(
            manualUpdateCheckFailureText(.httpStatus(403)).contains("rate limiting"),
            equals: true,
            "HTTP 403 failure text should mention rate limiting"
        )
        try expect(
            manualUpdateCheckFailureText(.httpStatus(500)).contains("HTTP 500"),
            equals: true,
            "HTTP failure text should include the status code"
        )
        try expect(
            manualUpdateCheckFailureText(.unexpectedResponse).contains("couldn't read"),
            equals: true,
            "unexpected-response failure text should describe an unreadable response"
        )
        try expect(
            UpdateCheck.normalizedReleaseVersion(from: " V1.2.3\n"),
            equals: "1.2.3",
            "release version normalization should allow one leading v"
        )
        try expect(
            normalizedStoredAppVersion(" v2.3.4\n"),
            equals: "2.3.4",
            "stored app version normalization should canonicalize release-style versions"
        )
        try expect(
            normalizedStoredAppVersion("2.3"),
            equals: nil,
            "stored app version normalization should reject incomplete versions"
        )
        try expect(
            normalizedStoredAppVersion("v999999999999999999999999.2.3"),
            equals: nil,
            "stored app version normalization should reject oversized numeric components"
        )
        try expect(
            UpdateCheck.sanitizedReleaseURL("http://github.com/shlgd/SuperDictate/releases/tag/v9.8.7",
                                            expectedTag: "v9.8.7"),
            equals: GITHUB_RELEASES_PAGE.absoluteString,
            "release URL sanitizing should require HTTPS"
        )
        try expect(
            UpdateCheck.sanitizedReleaseURL("https://user@github.com/shlgd/SuperDictate/releases/tag/v9.8.7",
                                            expectedTag: "v9.8.7"),
            equals: GITHUB_RELEASES_PAGE.absoluteString,
            "release URL sanitizing should reject userinfo"
        )
        try expect(
            UpdateCheck.sanitizedReleaseURL("https://github.com/shlgd/SuperDictate/releases/tag/v9.8.7?download=1",
                                            expectedTag: "v9.8.7"),
            equals: GITHUB_RELEASES_PAGE.absoluteString,
            "release URL sanitizing should reject query strings"
        )
    }

    private static func testUpdateCheckState() throws {
        let release = GitHubRelease(tagName: "v1.2.4",
                                    version: "1.2.4",
                                    body: "",
                                    htmlURL: GITHUB_RELEASES_PAGE.absoluteString)
        try expect(
            updateCheckResult(for: nil, currentVersion: "1.2.3", skippedVersions: []),
            equals: .failed,
            "nil update checks should be recorded as failed or unavailable"
        )
        try expect(
            updateCheckResult(for: release, currentVersion: "1.2.4", skippedVersions: []),
            equals: .upToDate,
            "equal release versions should be recorded as up to date"
        )
        try expect(
            updateCheckResult(for: release, currentVersion: "1.2.3", skippedVersions: []),
            equals: .available,
            "newer releases should be recorded as available"
        )
        try expect(
            updateCheckResult(for: release, currentVersion: "1.2.3", skippedVersions: ["1.2.4"]),
            equals: .skipped,
            "skipped newer releases should be recorded distinctly"
        )

        let now = Date(timeIntervalSince1970: 1_000)
        try expect(
            shouldSuppressUpdateForReminder(version: "1.2.4",
                                            reminderVersion: "1.2.4",
                                            reminderUntil: now.addingTimeInterval(60),
                                            now: now),
            equals: true,
            "active reminders should suppress the matching update version"
        )
        try expect(
            shouldSuppressUpdateForReminder(version: "1.2.5",
                                            reminderVersion: "1.2.4",
                                            reminderUntil: now.addingTimeInterval(60),
                                            now: now),
            equals: false,
            "reminders should not suppress newer versions"
        )
        try expect(
            shouldSuppressUpdateForReminder(version: "1.2.4",
                                            reminderVersion: "1.2.4",
                                            reminderUntil: now.addingTimeInterval(-1),
                                            now: now),
            equals: false,
            "expired reminders should not suppress updates"
        )
        try expect(
            updateCheckDiagnosticText(checkedAt: nil,
                                      source: nil,
                                      result: nil,
                                      releaseVersion: ""),
            equals: "never",
            "missing update-check metadata should render as never"
        )

        // Stale-pause clearing: equal version (expired pause about to
        // be re-shown) and a newer superseding release both clear; an
        // older fetched version or no pause leaves things alone.
        try expect(
            shouldClearUpdateReminderPause(fetchedVersion: "1.2.4", pausedVersion: "1.2.4"),
            equals: true,
            "a fetched release matching the paused version should clear the pause"
        )
        try expect(
            shouldClearUpdateReminderPause(fetchedVersion: "1.2.5", pausedVersion: "1.2.4"),
            equals: true,
            "a newer fetched release should clear a stale pause for the superseded version"
        )
        try expect(
            shouldClearUpdateReminderPause(fetchedVersion: "1.2.3", pausedVersion: "1.2.4"),
            equals: false,
            "an older fetched release should keep the existing pause"
        )
        try expect(
            shouldClearUpdateReminderPause(fetchedVersion: "1.2.4", pausedVersion: nil),
            equals: false,
            "no pause means nothing to clear"
        )

        // Persisted pause expiry validation, mirroring the
        // lastUpdateCheck* pattern: corrupt → nil, in-range round-trip,
        // cleared/missing → nil.
        let pauseNow = Date(timeIntervalSince1970: 2_000)
        let validPauseUntil = pauseNow.addingTimeInterval(UPDATE_REMIND_LATER_SECONDS)
        try expect(
            normalizedUpdateReminderPauseExpiry(storedValue: validPauseUntil, now: pauseNow),
            equals: validPauseUntil,
            "a stored pause expiry inside the pause window should round-trip"
        )
        try expect(
            normalizedUpdateReminderPauseExpiry(storedValue: pauseNow.addingTimeInterval(-60), now: pauseNow),
            equals: pauseNow.addingTimeInterval(-60),
            "an already-expired stored pause expiry is legitimate state and should round-trip"
        )
        try expect(
            normalizedUpdateReminderPauseExpiry(storedValue: "not a date", now: pauseNow),
            equals: nil,
            "a corrupt (non-Date) stored pause expiry should degrade to nil"
        )
        try expect(
            normalizedUpdateReminderPauseExpiry(storedValue: nil, now: pauseNow),
            equals: nil,
            "a cleared pause expiry should read back as nil"
        )
        try expect(
            normalizedUpdateReminderPauseExpiry(
                storedValue: pauseNow.addingTimeInterval(UPDATE_REMIND_LATER_SECONDS + 60),
                now: pauseNow
            ),
            equals: nil,
            "an out-of-range future pause expiry should degrade to nil instead of suppressing indefinitely"
        )
        // The paused-version half persists through the same validated
        // app-version normalization tested in testUpdateCheckParsing
        // (normalizedStoredAppVersion: corrupt → nil, round-trip).

        try expect(
            UpdateCheckSource(rawValue: "settings_toggle"),
            equals: .settingsToggle,
            "settings-toggle update checks should round-trip through their persisted raw value"
        )
        try expect(
            UpdateCheckSource.settingsToggle.diagnosticLabel,
            equals: "settings toggle",
            "settings-toggle update checks should label themselves distinctly in diagnostics"
        )
    }

    private static func testUpdateHelperScript() throws {
        try expect(
            shellSingleQuoted("a'b"),
            equals: "'a'\"'\"'b'",
            "shell quoting should preserve embedded single quotes"
        )
        try expect(
            (UPDATE_HELPER_LOG_PATH as NSString).deletingLastPathComponent,
            equals: (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs"),
            "update helper log should live in the user's log directory"
        )
        let updateEnv = updateProcessEnvironment(current: [
            "LANG": "C\nbad",
            "USER": "parakey-user",
            "LOGNAME": "parakey-logname",
            "__CF_USER_TEXT_ENCODING": "0x1F5:0x0:0x0",
            "BASH_ENV": "/tmp/pwn.sh",
            "ENV": "/tmp/pwn.sh",
            "SHELLOPTS": "xtrace",
            "RUBYOPT": "-r/tmp/pwn.rb",
            "HOMEBREW_BOTTLE_DOMAIN": "https://example.test",
        ])
        try expect(updateEnv["HOME"], equals: Optional(NSHomeDirectory()),
                   "update environment should set HOME explicitly")
        try expect(updateEnv["PATH"],
                   equals: Optional("/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"),
                   "update environment should use a deterministic PATH")
        try expect(updateEnv["LANG"], equals: Optional("en_US.UTF-8"),
                   "update environment should reject unsafe locale values")
        try expect(updateEnv["USER"], equals: Optional("parakey-user"),
                   "update environment should preserve a safe USER value")
        try expect(updateEnv["LOGNAME"], equals: Optional("parakey-logname"),
                   "update environment should preserve a safe LOGNAME value")
        for key in ["BASH_ENV", "ENV", "SHELLOPTS", "RUBYOPT", "HOMEBREW_BOTTLE_DOMAIN"] {
            try expect(updateEnv[key], equals: String?.none,
                       "update environment should not inherit \(key)")
        }
        let systemEnv = systemToolProcessEnvironment(current: [
            "LANG": "en_GB.UTF-8",
            "USER": "parakey-user",
            "BASH_ENV": "/tmp/pwn.sh",
            "DYLD_INSERT_LIBRARIES": "/tmp/pwn.dylib",
            "PATH": "/tmp/bin",
        ])
        try expect(systemEnv["PATH"], equals: Optional("/usr/bin:/bin:/usr/sbin:/sbin"),
                   "system tool environment should not include Homebrew or inherited PATH entries")
        try expect(systemEnv["LANG"], equals: Optional("en_GB.UTF-8"),
                   "system tool environment should preserve a safe locale")
        try expect(systemEnv["USER"], equals: Optional("parakey-user"),
                   "system tool environment should preserve a safe USER value")
        for key in ["BASH_ENV", "DYLD_INSERT_LIBRARIES"] {
            try expect(systemEnv[key], equals: String?.none,
                       "system tool environment should not inherit \(key)")
        }

        let script = updateHelperScript(pid: 123,
                                        brewPath: "/opt/homebrew/bin/brew",
                                        targetVersion: "9.8.7",
                                        statePath: "/tmp/parakey-update.state",
                                        appPath: "/Applications/SuperDictate.app",
                                        releasesPageURL: "https://example.test/releases")
        for fragment in [
            "umask 077",
            "TARGET_VERSION='9.8.7'",
            "STATE_PATH='/tmp/parakey-update.state'",
            "PARAKEY_PID=123",
            "SCRIPT_PATH=\"$0\"",
            "trap cleanup EXIT",
            "/bin/rm -f \"$SCRIPT_PATH\"",
            "printf '[%s] %s\\n' \"$(timestamp)\" \"$*\"",
            "printf '%s\\t%s\\n' \"$phase\" \"$message\" >\"$tmp\"",
            "CASK_TAP='shlgd/superdictate'",
            "CASK_TOKEN='shlgd/superdictate/superdictate'",
            "CASK_INSTALLED_TOKEN='parakey'",
            "PlistBuddy -c \"Print :CFBundleShortVersionString\"",
            "version_at_least \"$installed\" \"$TARGET_VERSION\"",
            "state \"preparing\" \"Preparing Homebrew for Parakey v$TARGET_VERSION...\"",
            "state \"downloading\" \"Downloading Parakey v$TARGET_VERSION...\"",
            "state \"installing\" \"Installing Parakey v$TARGET_VERSION...\"",
            "run_brew tap \"$CASK_TAP\"",
            "run_brew update --force",
            "run_brew fetch --cask --force \"$CASK_TOKEN\"",
            "run_brew upgrade --cask --force --appdir=\"$APP_DIR\" \"$CASK_TOKEN\"",
            "run_brew reinstall --cask --force --appdir=\"$APP_DIR\" \"$CASK_TOKEN\"",
            "installed_target_version",
            "sleep 2",
            "state \"complete\" \"Parakey v$TARGET_VERSION is installed.\"",
            "/usr/bin/open \"$APP_PATH\""
        ] {
            guard script.contains(fragment) else {
                throw SelfTestFailure.failed("update helper script missing fragment: \(fragment)")
            }
        }
        for fragment in ["LOG=", ">>\"$LOG\"", ">\"$LOG\"", "prepare_log"] {
            guard !script.contains(fragment) else {
                throw SelfTestFailure.failed("update helper script should not reopen a log path: \(fragment)")
            }
        }

        let directScript = superDictateDirectUpdateHelperScript(
            pid: 123,
            targetVersion: "9.8.7",
            statePath: "/tmp/superdictate-update.state",
            stagedAppPath: "/tmp/work/release/SuperDictate.app",
            workDirectory: "/tmp/work",
            backupAppPath: "/Applications/.SuperDictate-update-backup-test.app",
            appPath: "/Applications/SuperDictate.app",
            language: .english
        )
        for fragment in [
            "PANEL_PID=123",
            "TARGET_VERSION='9.8.7'",
            "STAGED_APP='/tmp/work/release/SuperDictate.app'",
            "BACKUP_APP='/Applications/.SuperDictate-update-backup-test.app'",
            "wait_for_panel_exit || rollback",
            "launchctl bootout \"$SERVICE\"",
            "/bin/mv \"$APP_PATH\" \"$BACKUP_APP\" || rollback",
            "/usr/bin/ditto \"$STAGED_APP\" \"$APP_PATH\" || rollback",
            "/usr/bin/codesign --verify --deep --strict \"$APP_PATH\"",
            "if [ -d \"$BACKUP_APP\" ]; then",
            "state \"complete\" 'SuperDictate v9.8.7 is installed.'",
        ] {
            guard directScript.contains(fragment) else {
                throw SelfTestFailure.failed("direct update helper missing fragment: \(fragment)")
            }
        }
        let directTmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("superdictate-direct-update-self-test-\(UUID().uuidString).sh")
        try directScript.write(to: directTmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: directTmp) }
        let directProc = Process()
        directProc.executableURL = URL(fileURLWithPath: "/bin/bash")
        directProc.arguments = ["-n", directTmp.path]
        directProc.standardOutput = Pipe()
        directProc.standardError = Pipe()
        try directProc.run()
        directProc.waitUntilExit()
        guard directProc.terminationStatus == 0 else {
            throw SelfTestFailure.failed("direct update helper script should pass bash -n")
        }

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("parakey-update-self-test-\(UUID().uuidString).sh")
        try script.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-n", tmp.path]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw SelfTestFailure.failed("update helper script should pass bash -n")
        }

        let fm = FileManager.default
        let helperRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("parakey-update-helper-test-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: helperRoot, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: helperRoot) }

        let helperPath = try writePrivateUpdateHelperScript(script,
                                                            directory: helperRoot.path,
                                                            fileName: "helper.sh")
        var createdStat = stat()
        guard lstat(helperPath, &createdStat) == 0 else {
            throw SelfTestFailure.failed("update helper script file should exist")
        }
        try expect((createdStat.st_mode & S_IFMT) == S_IFREG,
                   equals: true,
                   "update helper script should be a regular file")
        try expect(Int(createdStat.st_mode & mode_t(0o777)),
                   equals: 0o600,
                   "update helper script should be private to the current user")
        try expect(Int(createdStat.st_nlink),
                   equals: 1,
                   "update helper script should not be hard-linked")
        try expect(
            String(data: try Data(contentsOf: URL(fileURLWithPath: helperPath)), encoding: .utf8),
            equals: script,
            "update helper script file should contain the generated script"
        )

        let existing = helperRoot.appendingPathComponent("existing.sh")
        try Data("existing\n".utf8).write(to: existing)
        var existingRejected = false
        do {
            _ = try writePrivateUpdateHelperScript("bad",
                                                   directory: helperRoot.path,
                                                   fileName: "existing.sh")
        } catch {
            existingRejected = true
        }
        try expect(existingRejected, equals: true,
                   "update helper script writer should reject existing files")
        try expect(
            String(data: try Data(contentsOf: existing), encoding: .utf8),
            equals: "existing\n",
            "update helper script writer should leave existing files untouched"
        )

        let target = helperRoot.appendingPathComponent("target.sh")
        try Data("target\n".utf8).write(to: target)
        let link = helperRoot.appendingPathComponent("linked.sh")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        var symlinkRejected = false
        do {
            _ = try writePrivateUpdateHelperScript("bad",
                                                   directory: helperRoot.path,
                                                   fileName: "linked.sh")
        } catch {
            symlinkRejected = true
        }
        try expect(symlinkRejected, equals: true,
                   "update helper script writer should reject leaf symlinks")
        try expect(
            String(data: try Data(contentsOf: target), encoding: .utf8),
            equals: "target\n",
            "update helper script writer should leave symlink targets untouched"
        )

        let preferredLog = helperRoot.appendingPathComponent("SuperDictate-update.log")
        let helperLog = try openPrivateUpdateHelperLog(preferredPath: preferredLog.path,
                                                       fallbackDirectory: helperRoot.path)
        helperLog.handle.write(Data("log\n".utf8))
        helperLog.handle.closeFile()
        try expect(helperLog.path, equals: preferredLog.path,
                   "update helper log should use the preferred path when safe")
        var logStat = stat()
        guard lstat(preferredLog.path, &logStat) == 0 else {
            throw SelfTestFailure.failed("update helper log file should exist")
        }
        try expect((logStat.st_mode & S_IFMT) == S_IFREG,
                   equals: true,
                   "update helper log should be a regular file")
        try expect(Int(logStat.st_mode & mode_t(0o777)),
                   equals: 0o600,
                   "update helper log should be private to the current user")
        try expect(Int(logStat.st_nlink),
                   equals: 1,
                   "update helper log should not be hard-linked")
        try expect(
            String(data: try Data(contentsOf: preferredLog), encoding: .utf8),
            equals: "log\n",
            "update helper log should receive helper output"
        )

        let linkedLogTarget = helperRoot.appendingPathComponent("linked-log-target.log")
        try Data("target log\n".utf8).write(to: linkedLogTarget)
        let linkedLog = helperRoot.appendingPathComponent("linked-log.log")
        try fm.createSymbolicLink(at: linkedLog, withDestinationURL: linkedLogTarget)
        let fallbackForSymlink = try openPrivateUpdateHelperLog(preferredPath: linkedLog.path,
                                                                fallbackDirectory: helperRoot.path)
        fallbackForSymlink.handle.write(Data("fallback\n".utf8))
        fallbackForSymlink.handle.closeFile()
        try expect(fallbackForSymlink.path == linkedLog.path,
                   equals: false,
                   "update helper log should fall back when preferred path is a symlink")
        try expect(
            String(data: try Data(contentsOf: linkedLogTarget), encoding: .utf8),
            equals: "target log\n",
            "update helper log fallback should leave symlink targets untouched"
        )

        let hardLogTarget = helperRoot.appendingPathComponent("hard-log-target.log")
        try Data("hard target\n".utf8).write(to: hardLogTarget)
        let hardLog = helperRoot.appendingPathComponent("hard-log.log")
        try fm.linkItem(at: hardLogTarget, to: hardLog)
        let fallbackForHardLink = try openPrivateUpdateHelperLog(preferredPath: hardLog.path,
                                                                 fallbackDirectory: helperRoot.path)
        fallbackForHardLink.handle.write(Data("hard fallback\n".utf8))
        fallbackForHardLink.handle.closeFile()
        try expect(fallbackForHardLink.path == hardLog.path,
                   equals: false,
                   "update helper log should fall back when preferred path is hard-linked")
        try expect(
            String(data: try Data(contentsOf: hardLogTarget), encoding: .utf8),
            equals: "hard target\n",
            "update helper log fallback should leave hard-linked targets untouched"
        )
    }

    private static func testDirectUpdateReplacement() throws {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("superdictate-update-replacement-test-\(UUID().uuidString)",
                                    isDirectory: true)
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        let currentApp = applications.appendingPathComponent("SuperDictate.app", isDirectory: true)
        let workDirectory = root.appendingPathComponent("work", isDirectory: true)
        let stagedApp = workDirectory
            .appendingPathComponent("release", isDirectory: true)
            .appendingPathComponent("SuperDictate.app", isDirectory: true)
        let backupApp = applications.appendingPathComponent(".SuperDictate-update-backup.app",
                                                             isDirectory: true)
        let statePath = root.appendingPathComponent("state.txt")
        let helperPath = root.appendingPathComponent("helper.sh")
        try fileManager.createDirectory(at: applications, withIntermediateDirectories: true)
        try makeSyntheticSignedUpdateApp(at: currentApp, version: "1.0.0")
        try makeSyntheticSignedUpdateApp(at: stagedApp, version: "9.8.7")
        try Data("starting\tStarting update…\n".utf8).write(to: statePath)
        defer { try? fileManager.removeItem(at: root) }

        let script = superDictateDirectUpdateHelperScript(
            pid: Int32.max,
            targetVersion: "9.8.7",
            statePath: statePath.path,
            stagedAppPath: stagedApp.path,
            workDirectory: workDirectory.path,
            backupAppPath: backupApp.path,
            appPath: currentApp.path,
            language: .english,
            relaunch: false
        )
        try script.write(to: helperPath, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [helperPath.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let processOutput = String(data: output.fileHandleForReading.readDataToEndOfFile(),
                                   encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw SelfTestFailure.failed("direct update replacement failed: \(processOutput)")
        }

        try SuperDictateUpdateInstaller.validateApp(at: currentApp,
                                                     expectedVersion: "9.8.7")
        try expect(fileManager.fileExists(atPath: backupApp.path), equals: false,
                   "successful direct update should remove its backup")
        try expect(fileManager.fileExists(atPath: workDirectory.path), equals: false,
                   "successful direct update should remove staged files")
        try expect(UpdateProgressState.read(from: statePath.path)?.phase,
                   equals: Optional("complete"),
                   "successful direct update should report completion")
    }

    private static func makeSyntheticSignedUpdateApp(at appURL: URL,
                                                     version: String) throws {
        guard let sourceExecutable = Bundle.main.executableURL else {
            throw SelfTestFailure.failed("self-test executable URL is unavailable")
        }
        let fileManager = FileManager.default
        let executableDirectory = appURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try fileManager.createDirectory(at: executableDirectory, withIntermediateDirectories: true)
        let executableURL = executableDirectory.appendingPathComponent("SuperDictate")
        try fileManager.copyItem(at: sourceExecutable, to: executableURL)
        try fileManager.setAttributes([.posixPermissions: 0o755],
                                      ofItemAtPath: executableURL.path)
        let info: [String: Any] = [
            "CFBundleExecutable": "SuperDictate",
            "CFBundleIdentifier": "com.local.superdictate",
            "CFBundleName": "SuperDictate",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": "1",
        ]
        let infoData = try PropertyListSerialization.data(fromPropertyList: info,
                                                          format: .xml,
                                                          options: 0)
        try infoData.write(to: appURL.appendingPathComponent("Contents/Info.plist"))
        let signing = SuperDictateAgentService.run("/usr/bin/codesign",
                                                   ["--force", "--deep", "--sign", "-", appURL.path])
        guard signing.status == 0 else {
            throw SelfTestFailure.failed("could not sign synthetic update app: \(signing.output)")
        }
    }

    private static func testUpdateProgressState() throws {
        let launch = UpdateProgressLaunch(arguments: [
            UPDATE_PROGRESS_ARGUMENT,
            "/tmp/parakey.state",
            "/tmp/parakey.log",
            "9.8.7",
            "/tmp/\(UPDATE_PROGRESS_APP_PREFIX)test.app",
        ])
        try expect(launch != nil, equals: true,
                   "update progress launch arguments should parse")
        try expect(launch?.targetVersion, equals: Optional("9.8.7"),
                   "update progress launch should retain target version")
        try expect(
            UpdateProgressLaunch(arguments: [UPDATE_PROGRESS_ARGUMENT, "", "/tmp/parakey.log", "9.8.7", "/tmp/app"]) != nil,
            equals: false,
            "update progress launch should reject empty paths"
        )

        let statePath = try createPrivateUpdateProgressStateFile()
        defer { try? FileManager.default.removeItem(atPath: statePath) }

        var st = stat()
        guard lstat(statePath, &st) == 0 else {
            throw SelfTestFailure.failed("update progress state file should exist")
        }
        try expect((st.st_mode & S_IFMT) == S_IFREG, equals: true,
                   "update progress state file should be regular")
        try expect(Int(st.st_nlink), equals: 1,
                   "update progress state file should not be hard-linked")
        try expect(Int(st.st_mode & mode_t(0o777)), equals: 0o600,
                   "update progress state file should be private to the current user")

        let initial = UpdateProgressState.read(from: statePath)
        try expect(initial?.phase, equals: Optional("starting"),
                   "update progress state should default to starting")
        try expect(initial?.message, equals: Optional("Starting update..."),
                   "update progress state should default to the startup message")

        try writePrivateUpdateProgressState(phase: "failed\tbad",
                                            message: "Line 1\nLine 2",
                                            to: statePath)
        let failed = UpdateProgressState.read(from: statePath)
        try expect(failed?.phase, equals: Optional("failed bad"),
                   "update progress state should sanitize tab characters in phases")
        try expect(failed?.message, equals: Optional("Line 1 Line 2"),
                   "update progress state should sanitize newlines in messages")

        let safeCleanupPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("\(UPDATE_PROGRESS_APP_PREFIX)test.app")
        try expect(isSafeUpdateProgressCleanupPath(safeCleanupPath), equals: true,
                   "update progress cleanup should allow copied temp app bundles")
        try expect(isSafeUpdateProgressCleanupPath("/Applications/SuperDictate.app"), equals: false,
                   "update progress cleanup should reject non-temp app bundles")
        let unsafeTempPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("Parakey.app")
        try expect(isSafeUpdateProgressCleanupPath(unsafeTempPath), equals: false,
                   "update progress cleanup should reject temp app bundles without the copied-helper prefix")
    }

    private static func testHostileRegistryEnvDetection() throws {
        try expect(
            detectedHostileRegistryEnvVars(in: [:]),
            equals: [],
            "empty environment should not flag any registry override"
        )
        try expect(
            detectedHostileRegistryEnvVars(in: ["HF_TOKEN": "redacted",
                                                "PATH": "/usr/bin"]),
            equals: [],
            "unrelated env vars (incl. HF_TOKEN) must not flag as hostile"
        )
        try expect(
            detectedHostileRegistryEnvVars(in: ["REGISTRY_URL": "https://evil.example/"]),
            equals: ["REGISTRY_URL"],
            "REGISTRY_URL must be flagged"
        )
        try expect(
            detectedHostileRegistryEnvVars(in: ["MODEL_REGISTRY_URL": "https://evil.example/"]),
            equals: ["MODEL_REGISTRY_URL"],
            "MODEL_REGISTRY_URL must be flagged"
        )
        try expect(
            detectedHostileRegistryEnvVars(in: ["REGISTRY_URL": "",
                                                "MODEL_REGISTRY_URL": ""]),
            equals: ["MODEL_REGISTRY_URL", "REGISTRY_URL"],
            "an empty-string value still represents a tampered launch env"
        )
    }

    private static func testAudioRouteChangeDecision() throws {
        try expect(
            audioStartupRetryDelaySeconds(afterFailedAttempt: 1),
            equals: Optional(1 as UInt64),
            "first audio startup failure should retry after one second"
        )
        try expect(
            audioStartupRetryDelaySeconds(afterFailedAttempt: 2),
            equals: Optional(3 as UInt64),
            "second audio startup failure should retry after three seconds"
        )
        try expect(
            audioStartupRetryDelaySeconds(afterFailedAttempt: 3),
            equals: Optional(8 as UInt64),
            "third audio startup failure should retry after eight seconds"
        )
        try expect(
            audioStartupRetryDelaySeconds(afterFailedAttempt: 4),
            equals: UInt64?.none,
            "audio startup should stop retrying after the configured backoff schedule"
        )
        try expect(
            audioRouteChangeAction(isTerminating: true,
                                   isRestartingAudioInput: false,
                                   isCoreRuntimeReady: true,
                                   isRecording: false,
                                   isBusy: false,
                                   hasStartupTask: false),
            equals: .ignore,
            "route changes during termination should be ignored"
        )
        try expect(
            audioRouteChangeAction(isTerminating: false,
                                   isRestartingAudioInput: false,
                                   isCoreRuntimeReady: false,
                                   isRecording: false,
                                   isBusy: false,
                                   hasStartupTask: false),
            equals: .rebuildMenuOnly,
            "route changes before runtime readiness should only refresh the menu"
        )
        try expect(
            audioRouteChangeAction(isTerminating: false,
                                   isRestartingAudioInput: false,
                                   isCoreRuntimeReady: true,
                                   isRecording: true,
                                   isBusy: false,
                                   hasStartupTask: false),
            equals: .deferRefresh,
            "route changes during recording should defer the restart"
        )
        try expect(
            audioRouteChangeAction(isTerminating: false,
                                   isRestartingAudioInput: false,
                                   isCoreRuntimeReady: true,
                                   isRecording: false,
                                   isBusy: false,
                                   hasStartupTask: false),
            equals: .restartNow,
            "idle ready route changes should restart audio immediately"
        )
        try expect(
            audioConfigurationChangeIsSuppressed(now: 10, suppressedUntil: nil),
            equals: false,
            "configuration changes should not be suppressed without a suppression deadline"
        )
        try expect(
            audioConfigurationChangeIsSuppressed(now: 10, suppressedUntil: 11),
            equals: true,
            "configuration changes before the app-owned deadline should be ignored"
        )
        try expect(
            audioConfigurationChangeIsSuppressed(now: 11, suppressedUntil: 11),
            equals: false,
            "configuration changes at the suppression deadline should be handled normally"
        )
    }

    private static func testRecordingLifecycle() throws {
        try expect(
            recordingReleaseAction(capturedSampleCount: 3_999,
                                   sampleRate: 16_000,
                                   minimumClipSeconds: 0.25),
            equals: .discardTooShort(duration: 0.2499375),
            "release decision should discard clips under the minimum duration"
        )
        try expect(
            recordingReleaseAction(capturedSampleCount: 4_000,
                                   sampleRate: 16_000,
                                   minimumClipSeconds: 0.25),
            equals: .transcribe(duration: 0.25),
            "release decision should transcribe clips at the minimum duration"
        )
        try expect(
            recordingReleaseAction(capturedSampleCount: 4_000,
                                   sampleRate: 0,
                                   minimumClipSeconds: 0.25),
            equals: .discardTooShort(duration: 0),
            "release decision should handle invalid sample rates defensively"
        )

        let recoveryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("superdictate-recovery-test-\(UUID().uuidString)")
            .appendingPathExtension("sdaudio")
        defer { try? FileManager.default.removeItem(at: recoveryURL) }
        let expectedSamples: [Float] = [-0.75, -0.125, 0, 0.25, 0.875]
        let journal = try PendingDictationJournal(url: recoveryURL)
        journal.append(Array(expectedSamples.prefix(2)))
        journal.append(Array(expectedSamples.dropFirst(2)))
        journal.finish()
        try expect(
            try PendingDictationRecovery.loadSamples(from: recoveryURL),
            equals: expectedSamples,
            "pending dictation journal should round-trip captured samples"
        )
        let recoveryHandle = try FileHandle(forWritingTo: recoveryURL)
        try recoveryHandle.seekToEnd()
        try recoveryHandle.write(contentsOf: Data([0x7f]))
        try recoveryHandle.close()
        try expect(
            try PendingDictationRecovery.loadSamples(from: recoveryURL),
            equals: expectedSamples,
            "pending dictation recovery should ignore a partial trailing sample after a crash"
        )
        let recoveryAttributes = try FileManager.default.attributesOfItem(atPath: recoveryURL.path)
        guard let recoveryMode = recoveryAttributes[.posixPermissions] as? NSNumber else {
            throw SelfTestFailure.failed("pending dictation journal should expose POSIX permissions")
        }
        try expect(
            recoveryMode.intValue,
            equals: 0o600,
            "pending dictation journal should be private"
        )

        let processed = processedDictationText(
            rawTranscript: "  Um, parakeet is fast.  ",
            corrections: [TranscriptCorrection(source: "parakeet", replacement: "Parakey")],
            removeFillerWords: true
        )
        try expect(
            processed,
            equals: DictationTextProcessingResult(text: "Parakey is fast.",
                                                  appliedCorrectionCount: 1,
                                                  removedFillerWordCount: 1),
            "dictation text processing should trim, apply corrections, then remove fillers"
        )

        let preservedFillers = processedDictationText(
            rawTranscript: "  Um, parakeet is fast.  ",
            corrections: [TranscriptCorrection(source: "parakeet", replacement: "Parakey")],
            removeFillerWords: false
        )
        try expect(
            preservedFillers,
            equals: DictationTextProcessingResult(text: "Um, Parakey is fast.",
                                                  appliedCorrectionCount: 1,
                                                  removedFillerWordCount: 0),
            "dictation text processing should preserve fillers when the setting is off"
        )

        let repairedYo = processedDictationText(
            rawTranscript: "  <unk>лка, мо<UNK> и е<unk>. Потом <unk>жик.  ",
            corrections: [],
            removeFillerWords: false
        )
        try expect(
            repairedYo.text,
            equals: "Ёлка, моё и её. Потом ёжик.",
            "dictation text processing should repair Parakeet unknown tokens used for Cyrillic yo"
        )

        let repairedYoRussian = processedDictationText(
            rawTranscript: "  <unk>лка.  ",
            corrections: [],
            removeFillerWords: false,
            language: .russian
        )
        try expect(
            repairedYoRussian.text,
            equals: "Ёлка.",
            "explicit Russian language should repair <unk> to ё"
        )

        let removedUnkEnglish = processedDictationText(
            rawTranscript: "  Hello <unk> world.  ",
            corrections: [],
            removeFillerWords: false,
            language: .english
        )
        try expect(
            removedUnkEnglish.text,
            equals: "Hello world.",
            "non-Russian language should remove <unk> tokens, not replace with Cyrillic ё"
        )

        let removedUnkFrench = SpeechModelTextRepair.apply(
            to: "Bonjour <unk> le monde.",
            language: .french
        )
        try expect(
            removedUnkFrench,
            equals: "Bonjour le monde.",
            "SpeechModelTextRepair should strip <unk> for French"
        )

        let autoYo = SpeechModelTextRepair.apply(
            to: "<unk>лка",
            language: .auto
        )
        try expect(
            autoYo,
            equals: "Ёлка",
            "auto-detect language should preserve the ё repair for the default audience"
        )

        let markerText = systemAudioMuteMarkerText(pid: 12345,
                                                   date: Date(timeIntervalSince1970: 0))
        try expect(
            systemAudioMuteMarkerProcessID(from: markerText),
            equals: Optional(pid_t(12345)),
            "system audio mute marker should preserve the owning pid"
        )
        try expect(
            systemAudioMuteMarkerProcessID(from: "created=bad\n"),
            equals: pid_t?.none,
            "system audio mute marker parsing should ignore missing pids"
        )

        let script = systemAudioMuteWatchdogScript()
        for fragment in [
            #"PID="$1""#,
            #"MARKER="$2""#,
            #"/bin/kill -0 "$PID""#,
            "/usr/bin/osascript -e 'set volume without output muted'",
            #"/bin/rm -f "$MARKER""#,
        ] {
            guard script.contains(fragment) else {
                throw SelfTestFailure.failed("system audio mute watchdog script missing fragment: \(fragment)")
            }
        }

        // Mute command outcome: command failure and verified-unmuted
        // are definitive "not muted"; an ambiguous verification after
        // a successful command must be assumed muted so the recovery
        // marker + watchdog stay armed.
        try expect(
            systemAudioMuteCommandOutcome(commandSucceeded: true, verifiedMuted: true),
            equals: .muted,
            "verified mute should report muted"
        )
        try expect(
            systemAudioMuteCommandOutcome(commandSucceeded: true, verifiedMuted: nil),
            equals: .assumedMuted,
            "successful command with failed verification must assume muted"
        )
        try expect(
            systemAudioMuteCommandOutcome(commandSucceeded: true, verifiedMuted: false),
            equals: .failed,
            "verified-unmuted after the command is a definitive failure"
        )
        try expect(
            systemAudioMuteCommandOutcome(commandSucceeded: false, verifiedMuted: true),
            equals: .failed,
            "a failed command is not muted regardless of verification"
        )

        // Probe decision: only a definitive "output is live" while the
        // recording still wants the mute arms recovery and mutes.
        try expect(
            systemAudioMuteProbeDecision(mutedState: false, unmuteAlreadyRequested: false),
            equals: .armRecoveryAndMute,
            "live output during an active recording should mute"
        )
        try expect(
            systemAudioMuteProbeDecision(mutedState: true, unmuteAlreadyRequested: false),
            equals: .standDown,
            "a user-set mute must not be stomped"
        )
        try expect(
            systemAudioMuteProbeDecision(mutedState: nil, unmuteAlreadyRequested: false),
            equals: .standDown,
            "a failed probe must not risk stomping an unseen user mute"
        )
        try expect(
            systemAudioMuteProbeDecision(mutedState: false, unmuteAlreadyRequested: true),
            equals: .standDown,
            "a recording that already ended should not mute"
        )

        // Mute completion decision: assumed mutes behave exactly like
        // verified mutes (recovery stays armed); a definitive failure
        // disarms; a release that raced the command unmutes at once.
        try expect(
            systemAudioMuteCommandDecision(outcome: .muted, unmuteAlreadyRequested: false),
            equals: .stayMuted,
            "verified mute during recording should hold"
        )
        try expect(
            systemAudioMuteCommandDecision(outcome: .assumedMuted, unmuteAlreadyRequested: false),
            equals: .stayMuted,
            "assumed mute must keep recovery armed, not disarm it"
        )
        try expect(
            systemAudioMuteCommandDecision(outcome: .failed, unmuteAlreadyRequested: false),
            equals: .disarmRecovery,
            "definitive mute failure should disarm marker and watchdog"
        )
        try expect(
            systemAudioMuteCommandDecision(outcome: .muted, unmuteAlreadyRequested: true),
            equals: .beginUnmute,
            "release during the mute command should unmute immediately"
        )
        try expect(
            systemAudioMuteCommandDecision(outcome: .assumedMuted, unmuteAlreadyRequested: true),
            equals: .beginUnmute,
            "release during an assumed mute should also unmute immediately"
        )

        // Unmute request routing per lifecycle phase.
        try expect(
            systemAudioUnmuteRequestDecision(phase: .idle),
            equals: .nothingToDo,
            "no lifecycle → nothing to unmute"
        )
        try expect(
            systemAudioUnmuteRequestDecision(phase: .probing),
            equals: .deferUntilCommandSettles,
            "release during the probe defers to the probe completion"
        )
        try expect(
            systemAudioUnmuteRequestDecision(phase: .muting),
            equals: .deferUntilCommandSettles,
            "release during the mute command defers to its completion"
        )
        try expect(
            systemAudioUnmuteRequestDecision(phase: .muted),
            equals: .beginUnmute,
            "release while muted unmutes immediately"
        )
        try expect(
            systemAudioUnmuteRequestDecision(phase: .unmuting),
            equals: .nothingToDo,
            "release while an unmute is in flight should not double-issue"
        )

        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("parakey-mute-marker-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }

        let marker = root.appendingPathComponent("system-audio-muted")
        try writeSystemAudioMuteMarker(to: marker, text: markerText)
        var markerStat = stat()
        guard lstat(marker.path, &markerStat) == 0 else {
            throw SelfTestFailure.failed("system audio mute marker should exist")
        }
        try expect((markerStat.st_mode & S_IFMT) == S_IFREG,
                   equals: true,
                   "system audio mute marker should be a regular file")
        try expect(Int(markerStat.st_mode & mode_t(0o777)),
                   equals: 0o600,
                   "system audio mute marker should be private")
        try expect(
            String(data: try Data(contentsOf: marker), encoding: .utf8),
            equals: markerText,
            "system audio mute marker should contain the expected pid"
        )

        let target = root.appendingPathComponent("target-marker")
        try Data("target\n".utf8).write(to: target)
        let symlink = root.appendingPathComponent("linked-marker")
        try fm.createSymbolicLink(at: symlink, withDestinationURL: target)
        var symlinkRejected = false
        do {
            try writeSystemAudioMuteMarker(to: symlink, text: "bad\n")
        } catch {
            symlinkRejected = true
        }
        try expect(symlinkRejected,
                   equals: true,
                   "system audio mute marker should reject leaf symlinks")
        try expect(
            String(data: try Data(contentsOf: target), encoding: .utf8),
            equals: "target\n",
            "system audio mute marker should leave symlink targets untouched"
        )
    }

    private static func testPowerStateRecoveryDecision() throws {
        try expect(
            shouldResumeRuntimeAfterSystemSleep(isTerminating: true,
                                                isCoreRuntimeReady: true,
                                                isReady: true,
                                                isRecording: true,
                                                audioIsRunning: true),
            equals: false,
            "sleep during termination should not schedule wake recovery"
        )
        try expect(
            shouldResumeRuntimeAfterSystemSleep(isTerminating: false,
                                                isCoreRuntimeReady: false,
                                                isReady: false,
                                                isRecording: false,
                                                audioIsRunning: false),
            equals: false,
            "sleep before runtime startup should not schedule wake recovery"
        )
        try expect(
            shouldResumeRuntimeAfterSystemSleep(isTerminating: false,
                                                isCoreRuntimeReady: false,
                                                isReady: false,
                                                isRecording: true,
                                                audioIsRunning: true),
            equals: true,
            "active recording should schedule wake recovery even if readiness is already down"
        )
        try expect(
            wakeRuntimeRecoveryAction(shouldResumeAfterWake: false,
                                      isTerminating: false,
                                      hasStartupTask: false,
                                      isBusy: false,
                                      isSpeechModelReady: true),
            equals: .ignore,
            "wake without a sleep-paused runtime should do nothing"
        )
        try expect(
            wakeRuntimeRecoveryAction(shouldResumeAfterWake: true,
                                      isTerminating: false,
                                      hasStartupTask: false,
                                      isBusy: true,
                                      isSpeechModelReady: true),
            equals: .deferUntilIdle,
            "wake during transcription should defer runtime recovery"
        )
        try expect(
            wakeRuntimeRecoveryAction(shouldResumeAfterWake: true,
                                      isTerminating: false,
                                      hasStartupTask: true,
                                      isBusy: false,
                                      isSpeechModelReady: true),
            equals: .deferUntilIdle,
            "wake during startup should defer runtime recovery"
        )
        try expect(
            wakeRuntimeRecoveryAction(shouldResumeAfterWake: true,
                                      isTerminating: false,
                                      hasStartupTask: false,
                                      isBusy: false,
                                      isSpeechModelReady: true),
            equals: .startAudioRuntime,
            "wake after a loaded model should restart audio without reloading the model"
        )
        try expect(
            wakeRuntimeRecoveryAction(shouldResumeAfterWake: true,
                                      isTerminating: false,
                                      hasStartupTask: false,
                                      isBusy: false,
                                      isSpeechModelReady: false),
            equals: .startFullStartup,
            "wake without a loaded model should fall back to full startup"
        )
    }

    private static func testHandledHotkeySuppression() throws {
        var state = HotkeyTransitionState()
        let f5 = hotkeyChoice(forKeycode: 96)
        let f7 = hotkeyChoice(forKeycode: 98)

        try expect(
            state.transition(for: event(.keyDown, keycode: f5.keycode), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "F-key keyDown should suppress and press"
        )
        try expect(
            state.transition(for: event(.keyDown, keycode: 97), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: .pass,
            "non-hotkey keyDown should pass through"
        )
        try expect(
            state.transition(for: event(.keyUp, keycode: f5.keycode), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.release]),
            "F-key keyUp should suppress and release"
        )

        try expect(
            state.transition(for: event(.keyDown, keycode: f7.keycode), hotkey: f7, triggerMode: .hold, isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "recorded F-key keyDown should suppress and press"
        )
    }

    private static func testCustomShortcutMatching() throws {
        var state = HotkeyTransitionState()
        let shortcut = hotkeyChoice(forKeycode: 40,
                                    modifiers: [.maskCommand, .maskShift])
        let commandShift = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue

        try expect(
            state.transition(for: event(.keyDown, keycode: 40, flags: commandShift),
                             hotkey: shortcut,
                             triggerMode: .hold,
                             isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "custom shortcut should trigger when its exact modifiers are held"
        )
        try expect(
            state.transition(for: event(.keyUp, keycode: 40),
                             hotkey: shortcut,
                             triggerMode: .hold,
                             isRecording: true),
            equals: HotkeyTransitionResult(suppress: true, actions: [.release]),
            "custom shortcut release should not depend on modifier release order"
        )
        try expect(
            state.transition(for: event(.keyDown,
                                        keycode: 40,
                                        flags: CGEventFlags.maskCommand.rawValue),
                             hotkey: shortcut,
                             triggerMode: .hold,
                             isRecording: false),
            equals: .pass,
            "custom shortcut should ignore incomplete modifier combinations"
        )
    }

    private static func testModifierOnlyChordMatching() throws {
        var state = HotkeyTransitionState()
        let shortcut = hotkeyChoice(forKeycode: RIGHT_COMMAND_KEYCODE,
                                    modifiers: [.maskAlternate, .maskCommand])
        let unrelatedEnterShortcut = hotkeyChoice(forKeycode: 80)
        let alternate = CGEventFlags.maskAlternate.rawValue
        let commandAlternate = alternate | CGEventFlags.maskCommand.rawValue

        try expect(
            state.transition(for: event(.flagsChanged,
                                        keycode: RIGHT_OPTION_KEYCODE,
                                        flags: alternate),
                             hotkey: shortcut,
                             enterHotkey: unrelatedEnterShortcut,
                             triggerMode: .toggle,
                             isRecording: false),
            equals: .suppressOnly,
            "the first modifier in a configured chord should be reserved"
        )
        try expect(
            state.transition(for: event(.flagsChanged,
                                        keycode: RIGHT_COMMAND_KEYCODE,
                                        flags: commandAlternate),
                             hotkey: shortcut,
                             enterHotkey: unrelatedEnterShortcut,
                             triggerMode: .toggle,
                             isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "Option+Command should start dictation when configured as the main shortcut"
        )
        _ = state.transition(for: event(.flagsChanged,
                                        keycode: RIGHT_COMMAND_KEYCODE,
                                        flags: alternate),
                             hotkey: shortcut,
                             enterHotkey: unrelatedEnterShortcut,
                             triggerMode: .toggle,
                             isRecording: true)
        _ = state.transition(for: event(.flagsChanged,
                                        keycode: RIGHT_OPTION_KEYCODE),
                             hotkey: shortcut,
                             enterHotkey: unrelatedEnterShortcut,
                             triggerMode: .toggle,
                             isRecording: true)
        _ = state.transition(for: event(.flagsChanged,
                                        keycode: RIGHT_COMMAND_KEYCODE,
                                        flags: CGEventFlags.maskCommand.rawValue),
                             hotkey: shortcut,
                             enterHotkey: unrelatedEnterShortcut,
                             triggerMode: .toggle,
                             isRecording: true)
        try expect(
            state.transition(for: event(.flagsChanged,
                                        keycode: RIGHT_OPTION_KEYCODE,
                                        flags: commandAlternate),
                             hotkey: shortcut,
                             enterHotkey: unrelatedEnterShortcut,
                             triggerMode: .toggle,
                             isRecording: true),
            equals: HotkeyTransitionResult(suppress: true, actions: [.release]),
            "the same modifier chord should stop dictation on its next activation"
        )
    }

    private static func testConfigurableEnterShortcut() throws {
        var state = HotkeyTransitionState()
        let standard = hotkeyChoice(forKeycode: 96)
        let enterShortcut = hotkeyChoice(forKeycode: 40,
                                         modifiers: [.maskCommand, .maskShift])
        let commandShift = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue

        try expect(
            state.transition(for: event(.keyDown,
                                        keycode: 40,
                                        flags: commandShift),
                             hotkey: standard,
                             enterHotkey: enterShortcut,
                             triggerMode: .toggle,
                             isRecording: true),
            equals: HotkeyTransitionResult(suppress: true, actions: [.releaseAlternate]),
            "a user-configured Enter shortcut should use the Enter completion path"
        )
    }

    private static func testFKeyAutoRepeatSuppressesWithoutAction() throws {
        var state = HotkeyTransitionState()
        let f5 = hotkeyChoice(forKeycode: 96)

        try expect(
            state.transition(for: event(.keyDown, keycode: f5.keycode), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "initial F-key keyDown should press"
        )
        try expect(
            state.transition(for: event(.keyDown, keycode: f5.keycode, isAutoRepeat: true), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: .suppressOnly,
            "F-key autorepeat keyDown should suppress without action"
        )
    }

    private static func testRightModifierReleaseWithLeftFlagStillSet() throws {
        var state = HotkeyTransitionState()
        let rightOption = hotkeyChoice(forKeycode: 61)
        let alternate = CGEventFlags.maskAlternate.rawValue

        try expect(
            state.transition(for: event(.flagsChanged, keycode: rightOption.keycode, flags: alternate), hotkey: rightOption, triggerMode: .hold, isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "right modifier flagsChanged should press"
        )
        try expect(
            state.transition(for: event(.flagsChanged, keycode: rightOption.keycode, flags: alternate), hotkey: rightOption, triggerMode: .hold, isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.release]),
            "right modifier release should be recognized while left-side flag remains set"
        )

        var toggleState = HotkeyTransitionState()
        try expect(
            toggleState.transition(for: event(.flagsChanged,
                                              keycode: rightOption.keycode,
                                              flags: alternate),
                                   hotkey: rightOption,
                                   triggerMode: .toggle,
                                   isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "right Option should start when it is the configured toggle hotkey"
        )
        _ = toggleState.transition(for: event(.flagsChanged,
                                              keycode: rightOption.keycode),
                                   hotkey: rightOption,
                                   triggerMode: .toggle,
                                   isRecording: true)
        try expect(
            toggleState.transition(for: event(.flagsChanged,
                                              keycode: rightOption.keycode,
                                              flags: alternate),
                                   hotkey: rightOption,
                                   triggerMode: .toggle,
                                   isRecording: true),
            equals: HotkeyTransitionResult(suppress: true, actions: [.release]),
            "right Option should stop instead of being swallowed by the Enter chord"
        )
    }

    private static func testHistoryChordShowsOverlay() throws {
        let rightCommand = hotkeyChoice(forKeycode: RIGHT_COMMAND_KEYCODE)
        let commandShift = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue

        var shiftFirst = HotkeyTransitionState()
        try expect(
            shiftFirst.transition(for: event(.flagsChanged,
                                             keycode: RIGHT_SHIFT_KEYCODE,
                                             flags: CGEventFlags.maskShift.rawValue),
                                  hotkey: rightCommand,
                                  triggerMode: .toggle,
                                  isRecording: false),
            equals: .suppressOnly,
            "the first key of the history chord should be reserved until the chord completes"
        )
        try expect(
            shiftFirst.transition(for: event(.flagsChanged,
                                             keycode: RIGHT_COMMAND_KEYCODE,
                                             flags: commandShift),
                                  hotkey: rightCommand,
                                  triggerMode: .toggle,
                                  isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.showHistory]),
            "right shift then right command should show history without starting dictation"
        )
        try expect(
            shiftFirst.transition(for: event(.flagsChanged,
                                             keycode: RIGHT_COMMAND_KEYCODE,
                                             flags: CGEventFlags.maskShift.rawValue),
                                  hotkey: rightCommand,
                                  triggerMode: .toggle,
                                  isRecording: false),
            equals: .suppressOnly,
            "history chord should suppress the paired right command release"
        )
        try expect(
            shiftFirst.transition(for: event(.flagsChanged,
                                             keycode: RIGHT_SHIFT_KEYCODE,
                                             flags: 0),
                                  hotkey: rightCommand,
                                  triggerMode: .toggle,
                                  isRecording: false),
            equals: .suppressOnly,
            "history chord should suppress the paired right shift release"
        )

        var requiredModifierReleasedFirst = HotkeyTransitionState()
        _ = requiredModifierReleasedFirst.transition(
            for: event(.flagsChanged,
                       keycode: RIGHT_SHIFT_KEYCODE,
                       flags: CGEventFlags.maskShift.rawValue),
            hotkey: rightCommand,
            triggerMode: .toggle,
            isRecording: false
        )
        _ = requiredModifierReleasedFirst.transition(
            for: event(.flagsChanged,
                       keycode: RIGHT_COMMAND_KEYCODE,
                       flags: commandShift),
            hotkey: rightCommand,
            triggerMode: .toggle,
            isRecording: false
        )
        try expect(
            requiredModifierReleasedFirst.transition(
                for: event(.flagsChanged,
                           keycode: RIGHT_SHIFT_KEYCODE,
                           flags: CGEventFlags.maskCommand.rawValue),
                hotkey: rightCommand,
                triggerMode: .toggle,
                isRecording: false
            ),
            equals: .suppressOnly,
            "releasing Shift first should begin suppressing the history chord release"
        )
        try expect(
            requiredModifierReleasedFirst.transition(
                for: event(.flagsChanged,
                           keycode: RIGHT_COMMAND_KEYCODE,
                           flags: 0),
                hotkey: rightCommand,
                triggerMode: .toggle,
                isRecording: false
            ),
            equals: .suppressOnly,
            "releasing right Command last should clear the history chord state"
        )
        try expect(
            requiredModifierReleasedFirst.transition(
                for: event(.flagsChanged,
                           keycode: LEFT_COMMAND_KEYCODE,
                           flags: CGEventFlags.maskCommand.rawValue),
                hotkey: rightCommand,
                triggerMode: .toggle,
                isRecording: false
            ),
            equals: .pass,
            "left Command must not reuse stale right Command state"
        )
        try expect(
            requiredModifierReleasedFirst.transition(
                for: event(.flagsChanged,
                           keycode: RIGHT_SHIFT_KEYCODE,
                           flags: commandShift),
                hotkey: rightCommand,
                triggerMode: .toggle,
                isRecording: false
            ),
            equals: .suppressOnly,
            "left Command plus Shift must not trigger right Command history"
        )

        var commandFirst = HotkeyTransitionState()
        try expect(
            commandFirst.transition(for: event(.flagsChanged,
                                               keycode: RIGHT_COMMAND_KEYCODE,
                                               flags: CGEventFlags.maskCommand.rawValue),
                                    hotkey: rightCommand,
                                    triggerMode: .toggle,
                                    isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "right command alone should still start toggle dictation"
        )
        try expect(
            commandFirst.transition(for: event(.flagsChanged,
                                               keycode: RIGHT_SHIFT_KEYCODE,
                                               flags: commandShift),
                                    hotkey: rightCommand,
                                    triggerMode: .toggle,
                                    isRecording: true),
            equals: HotkeyTransitionResult(suppress: true, actions: [.showHistory]),
            "history chord should show history without canceling active dictation"
        )
        try expect(
            commandFirst.transition(for: event(.flagsChanged,
                                               keycode: RIGHT_COMMAND_KEYCODE,
                                               flags: CGEventFlags.maskShift.rawValue),
                                    hotkey: rightCommand,
                                    triggerMode: .toggle,
                                    isRecording: true),
            equals: .suppressOnly,
            "history chord should suppress the paired right command release while recording"
        )
        try expect(
            commandFirst.transition(for: event(.flagsChanged,
                                               keycode: RIGHT_SHIFT_KEYCODE,
                                               flags: 0),
                                    hotkey: rightCommand,
                                    triggerMode: .toggle,
                                    isRecording: true),
            equals: .suppressOnly,
            "history chord should suppress the paired right shift release"
        )
        try expect(
            commandFirst.transition(for: event(.flagsChanged,
                                               keycode: RIGHT_COMMAND_KEYCODE,
                                               flags: CGEventFlags.maskCommand.rawValue),
                                    hotkey: rightCommand,
                                    triggerMode: .toggle,
                                    isRecording: true),
            equals: HotkeyTransitionResult(suppress: true, actions: [.release]),
            "right command after the history chord should still stop active dictation"
        )
    }

    private static func testConfigurableHistoryShortcut() throws {
        var state = HotkeyTransitionState()
        let standard = hotkeyChoice(forKeycode: 96)
        let history = hotkeyChoice(forKeycode: 40,
                                   modifiers: [.maskCommand, .maskShift])
        let commandShift = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue

        try expect(
            state.transition(for: event(.keyDown,
                                        keycode: 40,
                                        flags: commandShift),
                             hotkey: standard,
                             historyHotkey: history,
                             triggerMode: .toggle,
                             isRecording: true),
            equals: HotkeyTransitionResult(suppress: true, actions: [.showHistory]),
            "a user-configured history shortcut should open history without stopping recording"
        )
        try expect(
            state.transition(for: event(.keyUp, keycode: 40),
                             hotkey: standard,
                             historyHotkey: history,
                             triggerMode: .toggle,
                             isRecording: true),
            equals: .suppressOnly,
            "a configurable history shortcut should suppress its paired release"
        )
    }

    private static func testOptionCommandEnterChordStopsWithEnter() throws {
        let rightCommand = hotkeyChoice(forKeycode: RIGHT_COMMAND_KEYCODE)
        let alternate = CGEventFlags.maskAlternate.rawValue
        let commandAlternate = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlternate.rawValue

        var state = HotkeyTransitionState()
        try expect(
            state.transition(for: event(.flagsChanged,
                                        keycode: RIGHT_OPTION_KEYCODE,
                                        flags: alternate),
                             hotkey: rightCommand,
                             triggerMode: .toggle,
                             isRecording: true),
            equals: .suppressOnly,
            "right option should be held for the enter chord while recording"
        )
        try expect(
            state.transition(for: event(.flagsChanged,
                                        keycode: RIGHT_COMMAND_KEYCODE,
                                        flags: commandAlternate),
                             hotkey: rightCommand,
                             triggerMode: .toggle,
                             isRecording: true),
            equals: HotkeyTransitionResult(suppress: true, actions: [.releaseAlternate]),
            "right option + right command should stop dictation through the alternate release path"
        )
        try expect(
            state.transition(for: event(.flagsChanged,
                                        keycode: RIGHT_COMMAND_KEYCODE,
                                        flags: alternate),
                             hotkey: rightCommand,
                             triggerMode: .toggle,
                             isRecording: false),
            equals: .suppressOnly,
            "enter chord should suppress the paired right command release"
        )
        try expect(
            state.transition(for: event(.flagsChanged,
                                        keycode: RIGHT_OPTION_KEYCODE,
                                        flags: 0),
                             hotkey: rightCommand,
                             triggerMode: .toggle,
                             isRecording: false),
            equals: .suppressOnly,
            "enter chord should suppress the paired right option release"
        )

    }

    private static func testEnterShortcutModeSelection() throws {
        try expect(
            shouldPressEnterAfterDictation(shortcut: .standard,
                                           primaryBehavior: .insert),
            equals: false,
            "insert mode should make the primary shortcut finish without Enter"
        )
        try expect(
            shouldPressEnterAfterDictation(shortcut: .alternate,
                                           primaryBehavior: .insert),
            equals: true,
            "the alternate shortcut should invert insert mode"
        )
        try expect(
            shouldPressEnterAfterDictation(shortcut: .standard,
                                           primaryBehavior: .insertAndEnter),
            equals: true,
            "insert-and-Enter mode should make the primary shortcut press Enter"
        )
        try expect(
            shouldPressEnterAfterDictation(shortcut: .alternate,
                                           primaryBehavior: .insertAndEnter),
            equals: false,
            "the alternate shortcut should invert insert-and-Enter mode"
        )

        var state = HotkeyTransitionState()
        let primary = hotkeyChoice(forKeycode: RIGHT_COMMAND_KEYCODE)
        let alternate = hotkeyChoice(forKeycode: 96)
        try expect(
            state.transition(for: event(.keyDown, keycode: alternate.keycode),
                             hotkey: primary,
                             enterHotkey: alternate,
                             alternateCompletionEnabled: false,
                             triggerMode: .toggle,
                             isRecording: true),
            equals: .pass,
            "a disabled alternate shortcut should not be intercepted"
        )
    }

    private static func testTogglePressFlipsOnceAndReleaseIsNoOp() throws {
        var state = HotkeyTransitionState()
        let f5 = hotkeyChoice(forKeycode: 96)

        try expect(
            state.transition(for: event(.keyDown, keycode: f5.keycode), hotkey: f5, triggerMode: .toggle, isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "first toggle press should start"
        )
        try expect(
            state.transition(for: event(.keyUp, keycode: f5.keycode), hotkey: f5, triggerMode: .toggle, isRecording: false),
            equals: .suppressOnly,
            "toggle release should be a no-op"
        )
        try expect(
            state.transition(for: event(.keyDown, keycode: f5.keycode), hotkey: f5, triggerMode: .toggle, isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.release]),
            "second toggle press should stop"
        )
    }

    private static func testToggleGatedPressDoesNotFlipToggleState() throws {
        var state = HotkeyTransitionState()
        let f5 = hotkeyChoice(forKeycode: 96)

        // A press the app would reject (e.g. a transcription in
        // flight) must suppress the key but not flip the toggle —
        // otherwise the next press emits a swallowed .release and
        // only the third press records.
        try expect(
            state.transition(for: event(.keyDown, keycode: f5.keycode), hotkey: f5, triggerMode: .toggle, isRecording: false, canStartRecording: false),
            equals: .suppressOnly,
            "gated toggle press should suppress without flipping state"
        )
        try expect(
            state.transition(for: event(.keyDown, keycode: f5.keycode), hotkey: f5, triggerMode: .toggle, isRecording: false, canStartRecording: true),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "press after a gated press should start immediately"
        )
        // The stop-side press must NOT be gated: once a recording is
        // active (canStartRecording is false by definition), the
        // press still has to stop it.
        try expect(
            state.transition(for: event(.keyDown, keycode: f5.keycode), hotkey: f5, triggerMode: .toggle, isRecording: true, canStartRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.release]),
            "gate must not block the toggle press that stops a recording"
        )
        // Hold mode ignores the gate entirely — handlePress discarding
        // the press leaves no state behind in hold mode.
        try expect(
            state.transition(for: event(.keyDown, keycode: f5.keycode), hotkey: f5, triggerMode: .hold, isRecording: false, canStartRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "hold-mode press should be unaffected by the gate"
        )
    }

    private static func testEscapePassesThroughWhenNotRecording() throws {
        var state = HotkeyTransitionState()
        let f5 = hotkeyChoice(forKeycode: 96)

        try expect(
            state.transition(for: event(.keyDown, keycode: ESCAPE_KEYCODE), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: .pass,
            "Escape keyDown should pass through when not recording"
        )
        try expect(
            state.transition(for: event(.keyDown, keycode: ESCAPE_KEYCODE, isAutoRepeat: true), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: .pass,
            "Escape autorepeat should pass through when not recording"
        )
        try expect(
            state.transition(for: event(.keyUp, keycode: ESCAPE_KEYCODE), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: .pass,
            "Escape keyUp should pass through when not recording"
        )
    }

    private static func testEscapeSuppressesCancelRepeatAndKeyUpWhileRecording() throws {
        var state = HotkeyTransitionState()
        let f5 = hotkeyChoice(forKeycode: 96)

        try expect(
            state.transition(for: event(.keyDown, keycode: ESCAPE_KEYCODE), hotkey: f5, triggerMode: .hold, isRecording: true),
            equals: HotkeyTransitionResult(suppress: true, actions: [.cancel]),
            "Escape keyDown should suppress and cancel while recording"
        )
        try expect(
            state.transition(for: event(.keyDown, keycode: ESCAPE_KEYCODE, isAutoRepeat: true), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: .suppressOnly,
            "Escape autorepeat from a canceled press should stay suppressed"
        )
        try expect(
            state.transition(for: event(.keyUp, keycode: ESCAPE_KEYCODE), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: .suppressOnly,
            "paired Escape keyUp should stay suppressed after cancel"
        )
        try expect(
            state.transition(for: event(.keyUp, keycode: ESCAPE_KEYCODE), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: .pass,
            "later Escape keyUp should pass through once the canceled press is complete"
        )
    }

    private static func event(
        _ type: CGEventType,
        keycode: CGKeyCode,
        flags: UInt64 = 0,
        isAutoRepeat: Bool = false
    ) -> HotkeyEventSnapshot {
        HotkeyEventSnapshot(
            typeRawValue: type.rawValue,
            keycode: keycode,
            flagsRawValue: flags,
            isAutoRepeat: isAutoRepeat
        )
    }

    private static func expect<T: Equatable>(
        _ actual: T,
        equals expected: T,
        _ message: String
    ) throws {
        guard actual == expected else {
            throw SelfTestFailure.failed("\(message): got \(actual), expected \(expected)")
        }
    }
}

if let status = ParakeySelfTest.run(arguments: Array(CommandLine.arguments.dropFirst())) {
    exit(status)
}
#endif

private enum ControlPanelServiceOperation: String, Sendable {
    case starting
    case restarting
    case stopping
    case applyingSettings
}

private enum ControlPanelShortcutKind: Int {
    case dictation = 0
    case alternateCompletion = 1
    case history = 2
}

private struct ControlPanelSettingsDraft: Equatable {
    var dictationHotkey: HotkeyChoice
    var alternateCompletionHotkey: HotkeyChoice
    var historyHotkey: HotkeyChoice
    var primaryCompletionBehavior: DictationCompletionBehavior
    var alternateCompletionEnabled: Bool
    var recordingColor: RecordingHUDAccentColor
    var transcribingColor: RecordingHUDAccentColor
    var backgroundStyle: RecordingHUDBackgroundStyle
    var hudSize: RecordingHUDSize

    init(settings: Settings) {
        dictationHotkey = settings.configuredHotkey
        alternateCompletionHotkey = settings.configuredEnterHotkey
        historyHotkey = settings.configuredHistoryHotkey
        primaryCompletionBehavior = settings.primaryCompletionBehavior
        alternateCompletionEnabled = settings.alternateCompletionEnabled
        recordingColor = settings.recordingHUDRecordingColor
        transcribingColor = settings.recordingHUDTranscribingColor
        backgroundStyle = settings.recordingHUDBackgroundStyle
        hudSize = settings.recordingHUDSize
    }
}

private func hotkeysConflict(_ lhs: HotkeyChoice, _ rhs: HotkeyChoice) -> Bool {
    lhs.keycode == rhs.keycode && lhs.requiredModifiers == rhs.requiredModifiers
}

private func hotkeyIsModifierPrefix(_ prefix: HotkeyChoice,
                                    of shortcut: HotkeyChoice) -> Bool {
    guard prefix.isModifier,
          prefix.requiredModifiers.isEmpty,
          let prefixMask = prefix.modifierFlag else { return false }
    if shortcut.isModifier {
        return shortcut.requiredModifiers.contains(prefixMask)
    }
    return shortcut.requiredModifiers.contains(prefixMask)
}

private enum ControlPanelUpdateState: Equatable, Sendable {
    case checking
    case upToDate(String)
    case available(GitHubRelease)
    case preparing(version: String, phase: String)
    case failed(String)
}

@MainActor
private final class SuperDictateControlPanelApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var settingsWindow: NSWindow?
    private var refreshTimer: Timer?
    private var serviceOperation: ControlPanelServiceOperation?
    private var updateTask: Task<Void, Never>?
    private var updateState: ControlPanelUpdateState = .checking
    private var lastRenderFingerprint = ""
    private let settings = Settings.shared
    private var permissionClickCount: [Permission: Int] = [:]
    private var settingsDraft: ControlPanelSettingsDraft?
    private var hotkeyRecorder: HotkeyRecorderController?

    private var language: InterfaceLanguage { settings.interfaceLanguage }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if SuperDictateControlPanelRegistry.activateExistingPanelIfPresent() {
            NSApp.terminate(nil)
            return
        }
        SuperDictateControlPanelRegistry.claimCurrentPanel()
        showWindow()
        startRefreshTimer()
        checkForUpdates()
        if settings.agentEnabled && !SuperDictateAgentService.isAgentRunning() {
            beginServiceOperation(.starting)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyRecorder?.cancel()
        hotkeyRecorder = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        updateTask?.cancel()
        updateTask = nil
        SuperDictateControlPanelRegistry.clearCurrentPanel()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow else { return }
        if closingWindow === settingsWindow {
            hotkeyRecorder?.cancel()
            hotkeyRecorder = nil
            settingsWindow = nil
            settingsDraft = nil
            return
        }
        if closingWindow === window {
            settingsWindow?.orderOut(nil)
            settingsWindow = nil
            NSApp.terminate(nil)
        }
    }

    private func t(_ russian: String, _ english: String) -> String {
        localizedText(russian, english, language: language)
    }

    private func showWindow() {
        if let window {
            refresh(force: true)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 310),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered,
                              defer: false)
        window.title = "SuperDictate"
        window.contentMinSize = NSSize(width: 520, height: 310)
        window.contentMaxSize = NSSize(width: 520, height: 310)
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        refresh(force: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(timeInterval: 0.75,
                                            target: self,
                                            selector: #selector(refreshTimerFired(_:)),
                                            userInfo: nil,
                                            repeats: true)
        refreshTimer?.tolerance = 0.15
    }

    @objc private func refreshTimerFired(_ timer: Timer) {
        refresh()
    }

    private func refresh(force: Bool = false) {
        guard let window else { return }
        let fingerprint = renderFingerprint()
        guard force || fingerprint != lastRenderFingerprint else { return }
        lastRenderFingerprint = fingerprint
        resizeCompactPanel(window)
        window.title = t("SuperDictate — панель управления", "SuperDictate — Control Panel")
        window.contentView = makeContentView()
        if let settingsWindow, settingsWindow.isVisible {
            settingsWindow.title = t("Настройки SuperDictate", "SuperDictate Settings")
            settingsWindow.contentView = makeSettingsContentView()
        }
    }

    private func resizeCompactPanel(_ window: NSWindow) {
        let missingCount = Permission.allCases.filter { !Permissions.isGranted($0) }.count
        let height = CGFloat(310 + max(0, missingCount - 1) * 28)
        let oldTop = window.frame.maxY
        let size = NSSize(width: 520, height: height)
        window.contentMinSize = size
        window.contentMaxSize = size
        window.setContentSize(size)
        var frame = window.frame
        frame.origin.y = oldTop - frame.height
        window.setFrame(frame, display: false)
    }

    private func renderFingerprint() -> String {
        let state = AgentRuntimeStateStore.read()
        let permissions = Permission.allCases.map { Permissions.isGranted($0) ? "1" : "0" }.joined()
        let stateToken: String
        if serviceOperation != nil {
            stateToken = "operation"
        } else {
            let rawStatus = state?.status ?? "none"
            let isHealthyRuntimeState = ["ready", "recording", "transcribing"].contains(rawStatus)
            stateToken = [isHealthyRuntimeState ? "ready" : rawStatus,
                          isHealthyRuntimeState ? "" : state?.detail ?? "",
                          String(state?.pid ?? 0),
                          state?.speechModelReady == true ? "1" : "0"].joined(separator: "|")
        }
        return [language.rawValue,
                serviceOperation?.rawValue ?? "idle",
                updateStateFingerprint(),
                SuperDictateAgentService.isAgentRunning() ? "running" : "stopped",
                stateToken,
                permissions,
                settings.configuredHotkey.name,
                settings.configuredEnterHotkey.name,
                settings.configuredHistoryHotkey.name,
                settings.primaryCompletionBehavior.rawValue,
                settings.alternateCompletionEnabled ? "alternate-on" : "alternate-off",
                settings.triggerMode.rawValue,
                settings.recordingHUDRecordingColor.rawValue,
                settings.recordingHUDTranscribingColor.rawValue,
                settings.recordingHUDBackgroundStyle.rawValue,
                settings.recordingHUDSize.rawValue,
                permissionClickCount.description].joined(separator: "::")
    }

    private func updateStateFingerprint() -> String {
        switch updateState {
        case .checking:
            return "checking"
        case .upToDate(let version):
            return "current:\(version)"
        case .available(let release):
            return "available:\(release.version)"
        case .preparing(let version, let phase):
            return "preparing:\(version):\(phase)"
        case .failed(let message):
            return "failed:\(message)"
        }
    }

    private func makeContentView() -> NSView {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false

        root.addArrangedSubview(compactHeaderView())
        root.addArrangedSubview(compactServiceCard())
        root.addArrangedSubview(compactPermissionsCard())
        root.addArrangedSubview(compactUpdateCard())
        root.addArrangedSubview(compactPrivacyFooter())

        let background = NSVisualEffectView()
        background.material = .underWindowBackground
        background.blendingMode = .behindWindow
        background.state = .active
        background.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            root.topAnchor.constraint(equalTo: background.topAnchor),
            root.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])

        let innerWidthInset = -(root.edgeInsets.left + root.edgeInsets.right)
        for view in root.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: root.widthAnchor,
                                        constant: innerWidthInset).isActive = true
        }
        return background
    }

    private func makeSettingsContentView() -> NSView {
        let draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 11
        root.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false

        root.addArrangedSubview(settingsHeaderView())
        root.addArrangedSubview(separator())
        root.addArrangedSubview(hotkeyRow(
            title: t("Диктовка", "Dictation"),
            shortcut: draft.dictationHotkey,
            kind: .dictation,
            toolTip: t("Начать запись. Повторное нажатие завершает её выбранным способом.",
                       "Start recording. Press again to finish using the selected action.")
        ))
        root.addArrangedSubview(primaryCompletionBehaviorRow(draft))
        root.addArrangedSubview(alternateCompletionRow(draft))
        root.addArrangedSubview(hotkeyRow(
            title: t("История", "History"),
            shortcut: draft.historyHotkey,
            kind: .history,
            toolTip: t("Открыть или закрыть последние транскрипции.",
                       "Open or close recent transcriptions.")
        ))
        root.addArrangedSubview(separator())
        root.addArrangedSubview(popupRow(
            title: t("Размер капсулы", "Capsule size"),
            detail: t("Размер плавающего индикатора записи.",
                      "Size of the floating recording indicator."),
            selectedValue: draft.hudSize.rawValue,
            options: RecordingHUDSize.allCases.map { (localizedHUDSizeName($0), $0.rawValue) },
            action: #selector(selectRecordingHUDSize(_:)),
            toolTip: t("Выбрать компактную, обычную или крупную капсулу.",
                       "Choose a compact, standard, or large capsule.")
        ))
        root.addArrangedSubview(popupRow(
            title: t("Цвет записи", "Recording color"),
            detail: t("Цвет аудиоволн, пока микрофон слушает.",
                      "Color used while the microphone is listening."),
            selectedValue: draft.recordingColor.rawValue,
            options: RecordingHUDAccentColor.allCases.map { (localizedColorName($0), $0.rawValue) },
            action: #selector(selectRecordingHUDRecordingColor(_:)),
            toolTip: t("Цвет индикатора во время записи.", "Indicator color while recording.")
        ))
        root.addArrangedSubview(popupRow(
            title: t("Цвет транскрибации", "Transcribing color"),
            detail: t("Цвет анимации во время распознавания речи.",
                      "Color used while speech is being converted to text."),
            selectedValue: draft.transcribingColor.rawValue,
            options: RecordingHUDAccentColor.allCases.map { (localizedColorName($0), $0.rawValue) },
            action: #selector(selectRecordingHUDTranscribingColor(_:)),
            toolTip: t("Цвет индикатора во время распознавания речи.",
                       "Indicator color while speech is being transcribed.")
        ))
        root.addArrangedSubview(popupRow(
            title: t("Фон капсулы", "HUD background"),
            detail: t("Системная тема или постоянный светлый/тёмный фон.",
                      "Follow the system appearance or use a fixed background."),
            selectedValue: draft.backgroundStyle.rawValue,
            options: RecordingHUDBackgroundStyle.allCases.map { (localizedBackgroundName($0), $0.rawValue) },
            action: #selector(selectRecordingHUDBackgroundStyle(_:)),
            toolTip: t("Выбрать фон плавающего индикатора диктовки.",
                       "Choose the floating dictation indicator background.")
        ))
        root.addArrangedSubview(settingsActionsRow(draft: draft))
        root.addArrangedSubview(privacyInfoView())

        let background = NSVisualEffectView()
        background.material = .underWindowBackground
        background.blendingMode = .behindWindow
        background.state = .active
        background.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            root.topAnchor.constraint(equalTo: background.topAnchor),
            root.bottomAnchor.constraint(lessThanOrEqualTo: background.bottomAnchor),
        ])

        let innerWidthInset = -(root.edgeInsets.left + root.edgeInsets.right)
        for view in root.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: root.widthAnchor,
                                        constant: innerWidthInset).isActive = true
        }
        return background
    }

    private func compactHeaderView() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.addArrangedSubview(panelLabel("SuperDictate", size: 20, weight: .semibold))
        text.addArrangedSubview(panelLabel(
            t("Локальная диктовка · работает в фоне", "Local dictation · runs in the background"),
            size: 11.5,
            color: .secondaryLabelColor
        ))

        let version = panelLabel("v\(currentBundleVersion())", size: 11, color: .tertiaryLabelColor)
        version.setContentHuggingPriority(.required, for: .horizontal)
        version.toolTip = t("Установленная версия SuperDictate", "Installed SuperDictate version")

        let languageControl = NSSegmentedControl(labels: ["RU", "EN"],
                                                 trackingMode: .selectOne,
                                                 target: self,
                                                 action: #selector(selectInterfaceLanguage(_:)))
        languageControl.selectedSegment = language == .russian ? 0 : 1
        languageControl.controlSize = .small
        languageControl.toolTip = t("Язык панели и настроек", "Panel and settings language")
        languageControl.setContentHuggingPriority(.required, for: .horizontal)

        let settingsButton = compactIconButton(
            symbol: "gearshape.fill",
            accessibilityTitle: t("Открыть настройки", "Open Settings"),
            toolTip: t("Открыть настройки диктовки и внешний вид индикатора",
                       "Open dictation and indicator appearance settings"),
            action: #selector(openSettingsClicked(_:))
        )

        row.addArrangedSubview(text)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(version)
        row.addArrangedSubview(languageControl)
        row.addArrangedSubview(settingsButton)
        return row
    }

    private func settingsHeaderView() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.addArrangedSubview(panelLabel(t("Настройки", "Settings"), size: 20, weight: .semibold))
        text.addArrangedSubview(panelLabel(
            t("Изменения применятся вместе после сохранения и перезапуска службы.",
              "Changes are applied together after saving and restarting the service."),
            size: 11.5,
            color: .secondaryLabelColor
        ))
        row.addArrangedSubview(text)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(panelLabel("v\(currentBundleVersion())", size: 11, color: .tertiaryLabelColor))
        return row
    }

    private func compactServiceCard() -> NSView {
        let running = SuperDictateAgentService.isAgentRunning()
        let state = AgentRuntimeStateStore.read()
        let presentation = servicePresentation(running: running, state: state)
        let card = compactCard()
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false

        let icon = panelSymbol(running ? "waveform.circle.fill" : "waveform.circle",
                               color: presentation.color,
                               description: t("Состояние службы", "Service status"),
                               pointSize: 25)
        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.addArrangedSubview(panelLabel(presentation.status, size: 14, weight: .semibold))
        let primaryShortcut = "\(t("Диктовка", "Dictation")): \(localizedHotkeyName(settings.configuredHotkey, language: language))"
        let historyShortcut = "\(t("История", "History")): \(localizedHotkeyName(settings.configuredHistoryHotkey, language: language))"
        let primaryBehavior = localizedCompletionBehavior(settings.primaryCompletionBehavior)
        let primaryAction = "\(t("Повторное нажатие", "Press again")): \(primaryBehavior)"
        let alternateAction = localizedCompletionBehavior(settings.primaryCompletionBehavior.opposite)
        let alternateShortcut = settings.alternateCompletionEnabled
            ? "\(t("Альтернативно", "Alternative")): \(localizedHotkeyName(settings.configuredEnterHotkey, language: language)) — \(alternateAction)"
            : t("Альтернативное завершение выключено", "Alternative finish is disabled")
        let detail = panelLabel(
            "\(presentation.detail)\n\(primaryShortcut) · \(historyShortcut)",
            size: 11.5,
            color: .secondaryLabelColor
        )
        detail.maximumNumberOfLines = 2
        detail.lineBreakMode = .byTruncatingTail
        detail.toolTip = "\(presentation.detail)\n\(primaryShortcut)\n\(primaryAction)\n\(alternateShortcut)\n\(historyShortcut)"
        text.addArrangedSubview(detail)

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 5
        let enabled = serviceOperation == nil
        if running {
            actions.addArrangedSubview(compactIconButton(
                symbol: "arrow.clockwise",
                accessibilityTitle: t("Перезапустить службу", "Restart Service"),
                toolTip: t("Перезапустить фоновую службу, не закрывая панель",
                           "Restart the background service without closing the panel"),
                action: #selector(restartAgentClicked(_:)),
                enabled: enabled
            ))
            actions.addArrangedSubview(compactIconButton(
                symbol: "stop.fill",
                accessibilityTitle: t("Остановить службу", "Stop Service"),
                toolTip: t("Остановить диктовку до следующего ручного запуска",
                           "Stop dictation until it is started manually"),
                action: #selector(stopAgentClicked(_:)),
                enabled: enabled
            ))
        } else {
            actions.addArrangedSubview(compactIconButton(
                symbol: "play.fill",
                accessibilityTitle: t("Запустить службу", "Start Service"),
                toolTip: t("Запустить фоновую службу диктовки",
                           "Start the background dictation service"),
                action: #selector(startAgentClicked(_:)),
                enabled: enabled
            ))
        }

        row.addArrangedSubview(icon)
        row.addArrangedSubview(text)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(actions)
        pin(row, inside: card, horizontal: 14, vertical: 11)
        card.toolTip = presentation.detail
        return card
    }

    private func compactPermissionsCard() -> NSView {
        let missing = Permission.allCases.filter { !Permissions.isGranted($0) }
        let card = compactCard()
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 7
        content.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        let color: NSColor = missing.isEmpty ? .systemGreen : .systemOrange
        header.addArrangedSubview(panelSymbol(missing.isEmpty ? "checkmark.shield.fill" : "exclamationmark.shield.fill",
                                              color: color,
                                              description: t("Разрешения macOS", "macOS permissions"),
                                              pointSize: 15))
        header.addArrangedSubview(panelLabel(t("Разрешения macOS", "macOS permissions"),
                                             size: 12.5,
                                             weight: .semibold))
        header.addArrangedSubview(NSView())
        header.addArrangedSubview(panelLabel(
            missing.isEmpty ? t("Все выданы", "All granted")
                            : t("Нужно: \(missing.count)", "Missing: \(missing.count)"),
            size: 11.5,
            weight: .medium,
            color: color
        ))
        content.addArrangedSubview(header)

        if missing.isEmpty {
            let ready = panelLabel(
                t("Микрофон, вставка текста и глобальный хоткей доступны.",
                  "Microphone, text insertion, and the global shortcut are available."),
                size: 11,
                color: .secondaryLabelColor
            )
            ready.toolTip = t("SuperDictate получил все три необходимых разрешения macOS.",
                              "SuperDictate has all three required macOS permissions.")
            content.addArrangedSubview(ready)
        } else {
            for permission in missing {
                content.addArrangedSubview(compactPermissionRow(permission))
            }
        }
        pin(content, inside: card, horizontal: 13, vertical: 10)
        return card
    }

    private func compactPermissionRow(_ permission: Permission) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        let title = panelLabel(permissionTitle(permission), size: 11.5, weight: .medium)
        title.toolTip = permissionDetail(permission)
        let buttonTitle = (permissionClickCount[permission] ?? 0) >= 1
            ? t("Повторить", "Try Again") : t("Разрешить", "Grant")
        let button = panelButton(buttonTitle,
                                 action: #selector(grantPermissionClicked(_:)),
                                 enabled: serviceOperation == nil,
                                 toolTip: t("Открыть системное разрешение: \(permissionTitle(permission))",
                                            "Open the system permission: \(permissionTitle(permission))"))
        button.controlSize = .small
        button.tag = Permission.allCases.firstIndex(of: permission) ?? -1
        row.addArrangedSubview(title)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(button)
        return row
    }

    private func compactUpdateCard() -> NSView {
        let card = compactCard()
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 11
        row.translatesAutoresizingMaskIntoConstraints = false

        let presentation = compactUpdatePresentation()
        row.addArrangedSubview(panelSymbol(presentation.symbol,
                                           color: presentation.color,
                                           description: t("Обновления", "Updates"),
                                           pointSize: 17))
        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.addArrangedSubview(panelLabel(presentation.title, size: 12.5, weight: .semibold))
        let detail = panelLabel(presentation.detail, size: 11, color: .secondaryLabelColor)
        detail.maximumNumberOfLines = 1
        detail.lineBreakMode = .byTruncatingTail
        detail.toolTip = presentation.detail
        text.addArrangedSubview(detail)
        row.addArrangedSubview(text)
        row.addArrangedSubview(NSView())
        if let buttonTitle = presentation.buttonTitle,
           let action = presentation.action {
            let button = panelButton(buttonTitle,
                                     action: action,
                                     enabled: presentation.buttonEnabled,
                                     toolTip: presentation.buttonToolTip)
            button.controlSize = .small
            row.addArrangedSubview(button)
        }
        pin(row, inside: card, horizontal: 13, vertical: 9)
        return card
    }

    private func compactUpdatePresentation() -> (symbol: String,
                                                   color: NSColor,
                                                   title: String,
                                                   detail: String,
                                                   buttonTitle: String?,
                                                   action: Selector?,
                                                   buttonEnabled: Bool,
                                                   buttonToolTip: String?) {
        switch updateState {
        case .checking:
            return ("arrow.triangle.2.circlepath", .systemBlue,
                    t("Проверяю обновления", "Checking for updates"),
                    t("Установлена v\(currentBundleVersion())", "Installed v\(currentBundleVersion())"),
                    nil, nil, false, nil)
        case .upToDate:
            return ("checkmark.circle.fill", .systemGreen,
                    t("SuperDictate актуален", "SuperDictate is up to date"),
                    t("Установлена последняя версия v\(currentBundleVersion())",
                      "Latest version v\(currentBundleVersion()) is installed"),
                    t("Проверить", "Check"), #selector(updateButtonClicked(_:)), true,
                    t("Проверить GitHub Releases ещё раз", "Check GitHub Releases again"))
        case .available(let release):
            return ("arrow.down.circle.fill", .systemBlue,
                    t("Доступна версия v\(release.version)", "Version v\(release.version) is available"),
                    t("Скачается, проверится и установится автоматически",
                      "Downloads, verifies, and installs automatically"),
                    t("Обновить", "Update"), #selector(updateButtonClicked(_:)), serviceOperation == nil,
                    t("Обновить SuperDictate до v\(release.version) одной кнопкой",
                      "Update SuperDictate to v\(release.version) with one click"))
        case .preparing(let version, let phase):
            return ("arrow.down.circle", .systemBlue,
                    t("Обновляю до v\(version)", "Updating to v\(version)"),
                    phase, nil, nil, false, nil)
        case .failed(let message):
            return ("exclamationmark.triangle.fill", .systemRed,
                    t("Обновление не проверено", "Update check failed"),
                    message,
                    t("Повторить", "Retry"), #selector(updateButtonClicked(_:)), true,
                    t("Повторить проверку обновлений", "Retry the update check"))
        }
    }

    private func compactPrivacyFooter() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 7
        row.addArrangedSubview(panelSymbol("xmark.circle",
                                           color: .tertiaryLabelColor,
                                           description: nil,
                                           pointSize: 10))
        let label = panelLabel(
            t("Панель можно закрыть — диктовка продолжит работать в фоне.",
              "You can close this panel — dictation keeps running in the background."),
            size: 10.5,
            color: .tertiaryLabelColor
        )
        label.toolTip = t("Это только панель управления. Аудио и распознавание остаются на Mac.",
                          "This is only the control panel. Audio and transcription stay on this Mac.")
        row.addArrangedSubview(label)
        row.addArrangedSubview(NSView())
        return row
    }

    private func operationTitle(_ operation: ControlPanelServiceOperation) -> String {
        switch operation {
        case .starting: return t("Запускаю службу диктовки", "Starting dictation service")
        case .restarting: return t("Перезапускаю фоновую службу", "Restarting background service")
        case .stopping: return t("Останавливаю фоновую службу", "Stopping background service")
        case .applyingSettings: return t("Применяю настройки и перезапускаю службу",
                                         "Applying settings and restarting service")
        }
    }

    private func operationDetail(_ operation: ControlPanelServiceOperation) -> String {
        switch operation {
        case .starting:
            return t("Подключаю глобальный хоткей и локальную модель. Обычно 1–3 секунды; при первой загрузке дольше.",
                     "Enabling the global shortcut and local model. Usually 1–3 seconds; the first download takes longer.")
        case .restarting, .applyingSettings:
            return t("Диктовка временно недоступна. Панель не зависла — новый воркер уже запускается.",
                     "Dictation is temporarily unavailable. The panel is responsive while the new worker starts.")
        case .stopping:
            return t("Хоткей перестанет работать, но настройки и история сохранятся.",
                     "The shortcut will stop; settings and history remain saved.")
        }
    }

    private func servicePresentation(running: Bool,
                                     state: AgentRuntimeState?) -> (status: String, detail: String, color: NSColor) {
        if let operation = serviceOperation {
            return (operationTitle(operation), operationDetail(operation), .systemBlue)
        }
        if running, let state {
            if ["ready", "recording", "transcribing"].contains(state.status) {
                return (t("Работает", "Running"),
                        t("Фоновая служба включена.", "The background service is running."),
                        .systemGreen)
            }
            return (displayStatus(state.status), localizedServiceDetail(state), colorForStatus(state.status))
        }
        if running {
            return (t("Запускается", "Starting"),
                    t("Фоновый процесс запущен и готовит модель.", "The background process is preparing the model."),
                    .systemOrange)
        }
        return (settings.agentEnabled ? t("Остановлена", "Stopped") : t("Выключена", "Off"),
                t("Хоткей не работает, пока служба не запущена.",
                  "The shortcut is unavailable until the service starts."),
                settings.agentEnabled ? .systemRed : .secondaryLabelColor)
    }

    private func checkForUpdates() {
        updateTask?.cancel()
        updateState = .checking
        refresh(force: true)
        updateTask = Task { [weak self] in
            let outcome = await UpdateCheck.fetchLatest()
            guard !Task.isCancelled, let self else { return }
            self.updateTask = nil
            switch outcome {
            case .success(let release):
                self.settings.lastUpdateCheckAt = Date()
                self.settings.lastUpdateCheckSource = .manual
                self.settings.lastUpdateCheckVersion = release.version
                if isNewer(release.version, than: currentBundleVersion()) {
                    self.settings.lastUpdateCheckResult = .available
                    self.updateState = .available(release)
                } else {
                    self.settings.lastUpdateCheckResult = .upToDate
                    self.updateState = .upToDate(currentBundleVersion())
                }
            case .failure(let failure):
                self.settings.lastUpdateCheckAt = Date()
                self.settings.lastUpdateCheckSource = .manual
                self.settings.lastUpdateCheckResult = .failed
                self.updateState = .failed(self.localizedUpdateFailure(failure))
            }
            self.lastRenderFingerprint = ""
            self.refresh(force: true)
        }
    }

    private func localizedUpdateFailure(_ failure: UpdateCheckFailure) -> String {
        guard language == .russian else { return manualUpdateCheckFailureText(failure) }
        switch failure {
        case .network:
            return "Не удалось связаться с GitHub. Проверьте интернет и повторите попытку."
        case .httpStatus(403):
            return "GitHub временно ограничил проверку обновлений. Повторите через несколько минут."
        case .httpStatus(let code):
            return "GitHub вернул ошибку HTTP \(code). Повторите попытку позже."
        case .unexpectedResponse:
            return "GitHub вернул ответ, который SuperDictate не смог проверить."
        }
    }

    private func beginInAppUpdate(for release: GitHubRelease) {
        guard updateTask == nil else { return }
        let version = release.version
        updateState = .preparing(
            version: version,
            phase: t("Получаю защищённый манифест обновления…",
                     "Fetching the verified update manifest…")
        )
        refresh(force: true)
        updateTask = Task { [weak self] in
            guard let self else { return }
            do {
                let manifest = try await SuperDictateUpdateInstaller.fetchManifest(
                    expectedVersion: version
                )
                guard !Task.isCancelled else { return }
                self.updateState = .preparing(
                    version: version,
                    phase: self.t("Скачиваю архив и проверяю SHA-256…",
                                  "Downloading the archive and verifying SHA-256…")
                )
                self.refresh(force: true)
                let prepared = try await SuperDictateUpdateInstaller.prepare(manifest: manifest)
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: prepared.workDirectory)
                    return
                }
                self.updateState = .preparing(
                    version: version,
                    phase: self.t("Архив проверен. Запускаю установку…",
                                  "The archive is verified. Starting installation…")
                )
                self.refresh(force: true)
                try self.launchPreparedUpdate(prepared)
            } catch {
                self.updateTask = nil
                let message = (error as? SuperDictateUpdateInstallerError)?
                    .message(language: self.language) ?? error.localizedDescription
                self.updateState = .failed(message)
                self.lastRenderFingerprint = ""
                self.refresh(force: true)
            }
        }
    }

    private func launchPreparedUpdate(_ prepared: PreparedSuperDictateUpdate) throws {
        let statePath = try createPrivateUpdateProgressStateFile()
        let helperLog = try openPrivateUpdateHelperLog()
        let appURL = Bundle.main.bundleURL
        let backupURL = appURL.deletingLastPathComponent()
            .appendingPathComponent(".SuperDictate-update-backup-\(UUID().uuidString).app",
                                    isDirectory: true)
        let script = superDictateDirectUpdateHelperScript(
            pid: getpid(),
            targetVersion: prepared.version,
            statePath: statePath,
            stagedAppPath: prepared.stagedAppURL.path,
            workDirectory: prepared.workDirectory.path,
            backupAppPath: backupURL.path,
            appPath: appURL.path,
            language: language
        )
        let helperPath = try writePrivateUpdateHelperScript(script)

        let progressAppPath: String
        do {
            progressAppPath = try launchUpdateProgressApp(
                statePath: statePath,
                logPath: helperLog.path,
                targetVersion: prepared.version
            )
        } catch {
            try? FileManager.default.removeItem(atPath: helperPath)
            try? FileManager.default.removeItem(atPath: statePath)
            try? FileManager.default.removeItem(at: prepared.workDirectory)
            helperLog.handle.closeFile()
            throw error
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [helperPath]
        process.environment = systemToolProcessEnvironment()
        process.standardOutput = helperLog.handle
        process.standardError = helperLog.handle
        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(atPath: helperPath)
            try? FileManager.default.removeItem(atPath: statePath)
            try? FileManager.default.removeItem(at: prepared.workDirectory)
            try? FileManager.default.removeItem(atPath: progressAppPath)
            helperLog.handle.closeFile()
            throw error
        }

        updateTask = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            NSApp.terminate(nil)
        }
    }

    private func launchUpdateProgressApp(statePath: String,
                                         logPath: String,
                                         targetVersion: String) throws -> String {
        let sourceAppURL = Bundle.main.bundleURL
        guard sourceAppURL.pathExtension == "app",
              let executableName = Bundle.main.executableURL?.lastPathComponent else {
            throw posixError(EINVAL)
        }
        let progressAppURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("\(UPDATE_PROGRESS_APP_PREFIX)\(UUID().uuidString).app",
                                    isDirectory: true)
        try FileManager.default.copyItem(at: sourceAppURL, to: progressAppURL)
        let executableURL = progressAppURL
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(executableName)
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            UPDATE_PROGRESS_ARGUMENT,
            statePath,
            logPath,
            targetVersion,
            progressAppURL.path,
        ]
        process.environment = systemToolProcessEnvironment()
        do {
            try process.run()
            return progressAppURL.path
        } catch {
            try? FileManager.default.removeItem(at: progressAppURL)
            throw error
        }
    }

    private func statusRow(title: String,
                           detail: String,
                           status: String,
                           statusColor: NSColor,
                           buttonTitle: String? = nil,
                           action: Selector? = nil,
                           tag: Int = 0,
                           buttonEnabled: Bool = true,
                           toolTip: String? = nil) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.addArrangedSubview(panelLabel(title, size: 13, weight: .semibold))
        let detailLabel = panelLabel(detail, size: 12, color: .secondaryLabelColor)
        detailLabel.preferredMaxLayoutWidth = 440
        text.addArrangedSubview(detailLabel)

        let statusLabel = panelLabel(status, size: 12, weight: .medium, color: statusColor)
        statusLabel.alignment = .right
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)

        row.addArrangedSubview(text)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(statusLabel)
        if let buttonTitle, let action {
            let button = panelButton(buttonTitle,
                                     action: action,
                                     enabled: buttonEnabled,
                                     toolTip: toolTip)
            button.tag = tag
            row.addArrangedSubview(button)
        }
        return row
    }

    private func hotkeyRow(title: String,
                           shortcut: HotkeyChoice,
                           kind: ControlPanelShortcutKind,
                           toolTip: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14

        row.addArrangedSubview(panelLabel(title, size: 13, weight: .semibold))
        row.addArrangedSubview(NSView())
        let button = panelButton(localizedHotkeyName(shortcut, language: language),
                                 action: #selector(recordDictationShortcutClicked(_:)),
                                 enabled: serviceOperation == nil,
                                 toolTip: toolTip)
        button.tag = kind.rawValue
        button.controlSize = .regular
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.widthAnchor.constraint(equalToConstant: 200).isActive = true
        row.addArrangedSubview(button)
        return row
    }

    private func primaryCompletionBehaviorRow(_ draft: ControlPanelSettingsDraft) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.addArrangedSubview(panelLabel(t("Повторное нажатие", "Press again"),
                                           size: 13,
                                           weight: .semibold))
        text.addArrangedSubview(panelLabel(
            t("Что сделать после вставки распознанного текста.",
              "What to do after inserting the transcribed text."),
            size: 12,
            color: .secondaryLabelColor
        ))

        let control = NSSegmentedControl(
            labels: [t("Вставить", "Insert"), t("Вставить + Enter", "Insert + Enter")],
            trackingMode: .selectOne,
            target: self,
            action: #selector(selectPrimaryCompletionBehavior(_:))
        )
        control.selectedSegment = draft.primaryCompletionBehavior == .insert ? 0 : 1
        control.isEnabled = serviceOperation == nil
        control.toolTip = t("Выберите действие при повторном нажатии основного хоткея.",
                            "Choose what the main shortcut does when pressed again.")
        control.setContentHuggingPriority(.required, for: .horizontal)

        row.addArrangedSubview(text)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(control)
        return row
    }

    private func alternateCompletionRow(_ draft: ControlPanelSettingsDraft) -> NSView {
        let behavior = draft.primaryCompletionBehavior.opposite
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.addArrangedSubview(panelLabel(
            behavior == .insert
                ? t("Завершить без Enter", "Finish without Enter")
                : t("Завершить + Enter", "Finish + Enter"),
            size: 13,
            weight: .semibold
        ))
        text.addArrangedSubview(panelLabel(
            t("Дополнительный хоткей работает только во время записи.",
              "The alternative shortcut only works while recording."),
            size: 12,
            color: .secondaryLabelColor
        ))

        let toggle = NSSwitch()
        toggle.target = self
        toggle.action = #selector(toggleAlternateCompletion(_:))
        toggle.state = draft.alternateCompletionEnabled ? .on : .off
        toggle.isEnabled = serviceOperation == nil
        toggle.toolTip = t("Включить дополнительный способ завершения записи.",
                           "Enable the alternative way to finish recording.")
        toggle.setContentHuggingPriority(.required, for: .horizontal)

        let button = panelButton(
            localizedHotkeyName(draft.alternateCompletionHotkey, language: language),
            action: #selector(recordDictationShortcutClicked(_:)),
            enabled: draft.alternateCompletionEnabled && serviceOperation == nil,
            toolTip: t("Изменить дополнительный хоткей завершения.",
                       "Change the alternative finish shortcut.")
        )
        button.tag = ControlPanelShortcutKind.alternateCompletion.rawValue
        button.controlSize = .regular
        button.widthAnchor.constraint(equalToConstant: 200).isActive = true

        row.addArrangedSubview(text)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(toggle)
        row.addArrangedSubview(button)
        return row
    }

    private func popupRow(title: String,
                          detail: String,
                          selectedValue: String,
                          options: [(title: String, value: String)],
                          action: Selector,
                          toolTip: String? = nil) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.addArrangedSubview(panelLabel(title, size: 13, weight: .semibold))
        text.addArrangedSubview(panelLabel(detail, size: 12, color: .secondaryLabelColor))

        let popup = NSPopUpButton()
        popup.target = self
        popup.action = action
        popup.toolTip = toolTip
        for option in options {
            popup.addItem(withTitle: option.title)
            popup.lastItem?.representedObject = option.value
        }
        if let item = popup.itemArray.first(where: { $0.representedObject as? String == selectedValue }) {
            popup.select(item)
        }
        popup.setContentHuggingPriority(.required, for: .horizontal)
        row.addArrangedSubview(text)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(popup)
        return row
    }

    private func settingsActionsRow(draft: ControlPanelSettingsDraft) -> NSView {
        let persisted = ControlPanelSettingsDraft(settings: settings)
        let hasChanges = draft != persisted
        let validation = settingsValidationMessage(draft)
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        let message = panelLabel(
            validation ?? (hasChanges
                ? t("Есть несохранённые изменения", "You have unsaved changes")
                : t("Все изменения сохранены", "All changes are saved")),
            size: 11.5,
            weight: .medium,
            color: validation == nil ? .secondaryLabelColor : .systemRed
        )
        message.toolTip = validation
        row.addArrangedSubview(message)
        row.addArrangedSubview(NSView())

        row.addArrangedSubview(panelButton(
            t("Отменить", "Discard"),
            action: #selector(discardSettingsClicked(_:)),
            enabled: hasChanges && serviceOperation == nil,
            toolTip: t("Отменить несохранённые изменения.", "Discard unsaved changes.")
        ))
        let save = panelButton(
            t("Сохранить и перезапустить", "Save & Restart"),
            action: #selector(saveSettingsClicked(_:)),
            enabled: hasChanges && validation == nil && serviceOperation == nil,
            toolTip: t("Сохранить настройки и перезапустить фоновую службу.",
                       "Save settings and restart the background service.")
        )
        save.keyEquivalent = "\r"
        row.addArrangedSubview(save)
        return row
    }

    private func settingsValidationMessage(_ draft: ControlPanelSettingsDraft) -> String? {
        let shortcuts = draft.alternateCompletionEnabled
            ? [draft.dictationHotkey, draft.alternateCompletionHotkey, draft.historyHotkey]
            : [draft.dictationHotkey, draft.historyHotkey]
        for firstIndex in shortcuts.indices {
            for secondIndex in shortcuts.indices where secondIndex > firstIndex {
                let first = shortcuts[firstIndex]
                let second = shortcuts[secondIndex]
                if hotkeysConflict(first, second) {
                    return t("Сочетания для диктовки, завершения и истории должны отличаться.",
                             "Dictation, finish, and history shortcuts must be different.")
                }
                if hotkeyIsModifierPrefix(first, of: second)
                    || hotkeyIsModifierPrefix(second, of: first) {
                    return t("Одна активная комбинация не должна быть частью другой.",
                             "One active shortcut cannot be a prefix of another.")
                }
            }
        }
        return nil
    }

    private func privacyInfoView() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        let icon = NSImageView(image: NSImage(systemSymbolName: "lock.shield.fill",
                                              accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        row.addArrangedSubview(icon)
        let label = panelLabel(
            t("Аудио и распознавание остаются на Mac. Интернет нужен только для первой загрузки модели и обновлений.",
              "Audio and transcription stay on this Mac. Internet is only used for the first model download and updates."),
            size: 11.5,
            color: .secondaryLabelColor
        )
        label.preferredMaxLayoutWidth = 600
        row.addArrangedSubview(label)
        return row
    }

    private func panelLabel(_ text: String,
                            size: CGFloat,
                            weight: NSFont.Weight = .regular,
                            color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        return label
    }

    private func panelButton(_ title: String,
                             action: Selector,
                             enabled: Bool = true,
                             toolTip: String? = nil) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.isEnabled = enabled
        button.toolTip = toolTip
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    private func compactIconButton(symbol: String,
                                   accessibilityTitle: String,
                                   toolTip: String,
                                   action: Selector,
                                   enabled: Bool = true) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol,
                                             accessibilityDescription: accessibilityTitle) ?? NSImage(),
                              target: self,
                              action: action)
        button.bezelStyle = .texturedRounded
        button.controlSize = .small
        button.isEnabled = enabled
        button.toolTip = toolTip
        button.setAccessibilityLabel(accessibilityTitle)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 30),
            button.heightAnchor.constraint(equalToConstant: 26),
        ])
        return button
    }

    private func compactCard() -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 8
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.70).cgColor
        card.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.42).cgColor
        card.layer?.borderWidth = 1
        card.setContentHuggingPriority(.required, for: .vertical)
        card.setContentCompressionResistancePriority(.required, for: .vertical)
        return card
    }

    private func panelSymbol(_ name: String,
                             color: NSColor,
                             description: String?,
                             pointSize: CGFloat) -> NSImageView {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description) ?? NSImage()
        let view = NSImageView(image: image)
        view.contentTintColor = color
        view.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        view.setContentHuggingPriority(.required, for: .horizontal)
        return view
    }

    private func pin(_ view: NSView,
                     inside container: NSView,
                     horizontal: CGFloat,
                     vertical: CGFloat) {
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: horizontal),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -horizontal),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: vertical),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -vertical),
        ])
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func triggerModeText() -> String {
        switch settings.triggerMode {
        case .hold: return t("Удерживать", "Press and hold")
        case .toggle: return t("Нажать для старта и ещё раз для остановки", "Press to start, press again to stop")
        }
    }

    private func localizedCompletionBehavior(_ behavior: DictationCompletionBehavior) -> String {
        switch behavior {
        case .insert:
            return t("Вставить", "Insert")
        case .insertAndEnter:
            return t("Вставить + Enter", "Insert + Enter")
        }
    }

    private func displayStatus(_ raw: String) -> String {
        switch raw {
        case "ready": return t("Работает", "Running")
        case "recording", "transcribing": return t("Работает", "Running")
        case "starting": return t("Запускается", "Starting")
        case "needs_permissions": return t("Нужен доступ", "Needs Access")
        case "error": return t("Ошибка", "Error")
        case "stopping": return t("Останавливается", "Stopping")
        case "stopped": return t("Остановлена", "Stopped")
        default: return raw.capitalized
        }
    }

    private func localizedServiceDetail(_ state: AgentRuntimeState) -> String {
        switch state.status {
        case "ready", "recording", "transcribing":
            return t("Фоновая служба готова к диктовке.",
                     "The background service is ready for dictation.")
        case "starting": return t("Загружаю модель и подключаю глобальный хоткей.", "Loading the model and enabling the global shortcut.")
        case "needs_permissions": return t("Выдайте недостающие разрешения ниже.", "Grant the missing permissions below.")
        case "stopped": return t("Фоновая служба остановлена.", "The background service is stopped.")
        case "error": return t("Служба сообщила об ошибке: \(state.detail)", "Service error: \(state.detail)")
        default: return state.detail
        }
    }

    private func colorForStatus(_ raw: String) -> NSColor {
        switch raw {
        case "ready", "recording", "transcribing": return .systemGreen
        case "starting", "needs_permissions", "stopping": return .systemOrange
        case "error", "stopped": return .systemRed
        default: return .secondaryLabelColor
        }
    }

    private func permissionTitle(_ permission: Permission) -> String {
        switch permission {
        case .microphone: return t("Микрофон", "Microphone")
        case .accessibility: return t("Универсальный доступ", "Accessibility")
        case .inputMonitoring: return t("Мониторинг ввода", "Input Monitoring")
        }
    }

    private func permissionDetail(_ permission: Permission) -> String {
        switch permission {
        case .microphone:
            return t("Запись голоса только во время активной диктовки.",
                     "Lets the service hear your voice while dictation is active.")
        case .accessibility:
            return t("Поиск активного поля и вставка готового текста.",
                     "Lets the service find the active field and insert text.")
        case .inputMonitoring:
            return t("Глобальное распознавание выбранного сочетания клавиш.",
                     "Lets the service detect your shortcut globally.")
        }
    }

    private func localizedColorName(_ color: RecordingHUDAccentColor) -> String {
        guard language == .russian else { return color.displayName }
        switch color {
        case .red: return "Красный"
        case .orange: return "Оранжевый"
        case .pink: return "Розовый"
        case .purple: return "Фиолетовый"
        case .blue: return "Синий"
        case .cyan: return "Голубой"
        case .green: return "Зелёный"
        case .white: return "Белый"
        }
    }

    private func localizedBackgroundName(_ style: RecordingHUDBackgroundStyle) -> String {
        guard language == .russian else { return style.displayName }
        switch style {
        case .system: return "Как в системе"
        case .dark: return "Тёмный"
        case .light: return "Светлый"
        }
    }

    private func localizedHUDSizeName(_ size: RecordingHUDSize) -> String {
        guard language == .russian else { return size.displayName }
        switch size {
        case .compact: return "Компактная"
        case .standard: return "Обычная"
        case .large: return "Крупная"
        }
    }

    private func beginServiceOperation(_ operation: ControlPanelServiceOperation) {
        guard serviceOperation == nil else { return }
        serviceOperation = operation
        lastRenderFingerprint = ""
        refresh(force: true)
        let operationStartedAt = Date().timeIntervalSince1970

        Task { [weak self] in
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    switch operation {
                    case .starting:
                        try SuperDictateAgentService.installAndStart()
                    case .restarting, .applyingSettings:
                        try SuperDictateAgentService.restart()
                    case .stopping:
                        SuperDictateAgentService.stop()
                    }
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value

            guard let self else { return }
            if failure == nil {
                await self.waitForServiceResult(operation: operation, startedAt: operationStartedAt)
            }
            self.serviceOperation = nil
            self.lastRenderFingerprint = ""
            self.refresh(force: true)
            if let failure {
                self.showError(
                    title: self.t("Не удалось изменить состояние службы", "Service operation failed"),
                    detail: failure
                )
            }
        }
    }

    private func waitForServiceResult(operation: ControlPanelServiceOperation,
                                      startedAt: TimeInterval) async {
        for _ in 0..<80 {
            let state = AgentRuntimeStateStore.read()
            if operation == .stopping {
                if state?.status == "stopped" { return }
            } else if let state,
                      state.updatedAt >= startedAt,
                      ["ready", "error", "needs_permissions"].contains(state.status) {
                return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    @objc private func updateButtonClicked(_ sender: NSButton) {
        switch updateState {
        case .available(let release):
            beginInAppUpdate(for: release)
        case .checking, .preparing:
            return
        case .upToDate, .failed:
            checkForUpdates()
        }
    }

    @objc private func startAgentClicked(_ sender: NSButton) {
        settings.agentEnabled = true
        _ = settings.refreshFromDisk()
        beginServiceOperation(.starting)
    }

    @objc private func restartAgentClicked(_ sender: NSButton) {
        settings.agentEnabled = true
        _ = settings.refreshFromDisk()
        beginServiceOperation(.restarting)
    }

    @objc private func stopAgentClicked(_ sender: NSButton) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = t("Остановить службу диктовки?", "Stop Dictation Service?")
        alert.informativeText = t("Хоткей перестанет работать, но история, модель и настройки сохранятся.",
                                  "The shortcut will stop, but history, model, and settings remain saved.")
        alert.addButton(withTitle: t("Оставить включённой", "Keep Running"))
        alert.addButton(withTitle: t("Остановить", "Stop Service"))
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        settings.agentEnabled = false
        _ = settings.refreshFromDisk()
        beginServiceOperation(.stopping)
    }

    @objc private func openSettingsClicked(_ sender: NSButton) {
        if let settingsWindow {
            settingsWindow.contentView = makeSettingsContentView()
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        settingsDraft = ControlPanelSettingsDraft(settings: settings)

        let settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 590),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        settingsWindow.title = t("Настройки SuperDictate", "SuperDictate Settings")
        settingsWindow.contentMinSize = NSSize(width: 680, height: 590)
        settingsWindow.contentMaxSize = NSSize(width: 680, height: 590)
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.delegate = self
        settingsWindow.contentView = makeSettingsContentView()
        if let mainWindow = window, let visibleFrame = mainWindow.screen?.visibleFrame {
            let mainFrame = mainWindow.frame
            let preferredRight = mainFrame.maxX + 14
            let preferredLeft = mainFrame.minX - settingsWindow.frame.width - 14
            let x = preferredRight + settingsWindow.frame.width <= visibleFrame.maxX
                ? preferredRight
                : max(visibleFrame.minX, preferredLeft)
            let y = min(max(visibleFrame.minY,
                            mainFrame.maxY - settingsWindow.frame.height),
                        visibleFrame.maxY - settingsWindow.frame.height)
            settingsWindow.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            settingsWindow.center()
        }
        self.settingsWindow = settingsWindow
        settingsWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func recordDictationShortcutClicked(_ sender: NSButton) {
        guard serviceOperation == nil,
              let kind = ControlPanelShortcutKind(rawValue: sender.tag) else { return }
        if let hotkeyRecorder {
            hotkeyRecorder.present(relativeTo: settingsWindow)
            return
        }
        let state = AgentRuntimeStateStore.read()
        if state?.isRecording == true || state?.isTranscribing == true {
            showError(
                title: t("Сначала завершите диктовку", "Finish Dictation First"),
                detail: t("Сочетание нельзя менять во время записи или распознавания.",
                          "Shortcuts cannot be changed while recording or transcribing.")
            )
            return
        }
        if SuperDictateAgentService.isAgentRunning(), state?.isReady != true {
            showError(
                title: t("Служба ещё запускается", "Service Is Still Starting"),
                detail: t("Дождитесь статуса «Работает» и попробуйте изменить сочетание ещё раз.",
                          "Wait for the Running status, then try changing the shortcut again.")
            )
            return
        }

        DistributedNotificationCenter.default().postNotificationName(
            HOTKEY_CAPTURE_BEGIN_NOTIFICATION,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        let recorderTitle: String
        switch kind {
        case .dictation:
            recorderTitle = t("Новое сочетание для диктовки", "New Dictation Shortcut")
        case .alternateCompletion:
            recorderTitle = t("Дополнительное сочетание завершения", "Alternative Finish Shortcut")
        case .history:
            recorderTitle = t("Новое сочетание для истории", "New History Shortcut")
        }
        let recorder = HotkeyRecorderController(language: language,
                                                titleOverride: recorderTitle) { [weak self] selected in
            DistributedNotificationCenter.default().postNotificationName(
                HOTKEY_CAPTURE_END_NOTIFICATION,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
            guard let self else { return }
            self.hotkeyRecorder = nil
            guard let selected else { return }
            var draft = self.settingsDraft ?? ControlPanelSettingsDraft(settings: self.settings)
            switch kind {
            case .dictation: draft.dictationHotkey = selected
            case .alternateCompletion: draft.alternateCompletionHotkey = selected
            case .history: draft.historyHotkey = selected
            }
            self.settingsDraft = draft
            self.refreshSettingsWindow()
        }
        hotkeyRecorder = recorder
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self, weak recorder] in
            guard self?.hotkeyRecorder === recorder else { return }
            recorder?.present(relativeTo: self?.settingsWindow)
        }
    }

    @objc private func selectInterfaceLanguage(_ sender: NSSegmentedControl) {
        settings.interfaceLanguage = sender.selectedSegment == 1 ? .english : .russian
        _ = settings.refreshFromDisk()
        lastRenderFingerprint = ""
        refresh(force: true)
    }

    @objc private func selectPrimaryCompletionBehavior(_ sender: NSSegmentedControl) {
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        draft.primaryCompletionBehavior = sender.selectedSegment == 1 ? .insertAndEnter : .insert
        settingsDraft = draft
        refreshSettingsWindow()
    }

    @objc private func toggleAlternateCompletion(_ sender: NSSwitch) {
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        draft.alternateCompletionEnabled = sender.state == .on
        settingsDraft = draft
        refreshSettingsWindow()
    }

    @objc private func selectRecordingHUDRecordingColor(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let color = RecordingHUDAccentColor(rawValue: raw) else { return }
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        draft.recordingColor = color
        settingsDraft = draft
        refreshSettingsWindow()
    }

    @objc private func selectRecordingHUDTranscribingColor(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let color = RecordingHUDAccentColor(rawValue: raw) else { return }
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        draft.transcribingColor = color
        settingsDraft = draft
        refreshSettingsWindow()
    }

    @objc private func selectRecordingHUDBackgroundStyle(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let style = RecordingHUDBackgroundStyle(rawValue: raw) else { return }
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        draft.backgroundStyle = style
        settingsDraft = draft
        refreshSettingsWindow()
    }

    @objc private func selectRecordingHUDSize(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let size = RecordingHUDSize(rawValue: raw) else { return }
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        draft.hudSize = size
        settingsDraft = draft
        refreshSettingsWindow()
    }

    @objc private func discardSettingsClicked(_ sender: NSButton) {
        settingsDraft = ControlPanelSettingsDraft(settings: settings)
        refreshSettingsWindow()
    }

    @objc private func saveSettingsClicked(_ sender: NSButton) {
        guard let draft = settingsDraft,
              settingsValidationMessage(draft) == nil else { return }
        settings.setConfiguredHotkey(draft.dictationHotkey)
        settings.setConfiguredEnterHotkey(draft.alternateCompletionHotkey)
        settings.setConfiguredHistoryHotkey(draft.historyHotkey)
        settings.primaryCompletionBehavior = draft.primaryCompletionBehavior
        settings.alternateCompletionEnabled = draft.alternateCompletionEnabled
        settings.recordingHUDRecordingColor = draft.recordingColor
        settings.recordingHUDTranscribingColor = draft.transcribingColor
        settings.recordingHUDBackgroundStyle = draft.backgroundStyle
        settings.recordingHUDSize = draft.hudSize
        settings.agentEnabled = true
        _ = settings.refreshFromDisk()
        settingsDraft = ControlPanelSettingsDraft(settings: settings)
        beginServiceOperation(.applyingSettings)
    }

    private func refreshSettingsWindow() {
        guard let settingsWindow else { return }
        settingsWindow.contentView = makeSettingsContentView()
    }

    @objc private func grantPermissionClicked(_ sender: NSButton) {
        guard Permission.allCases.indices.contains(sender.tag) else { return }
        let permission = Permission.allCases[sender.tag]
        if Permissions.isGranted(permission) {
            permissionClickCount[permission] = nil
            refresh(force: true)
            return
        }

        let clicks = (permissionClickCount[permission] ?? 0) + 1
        permissionClickCount[permission] = clicks
        if clicks >= 2 {
            TCC.reset(permission, bundleID: Bundle.main.bundleIdentifier ?? SETTINGS_SUITE) { [weak self] in
                guard let self else { return }
                Permissions.request(permission)
                self.refresh(force: true)
            }
        } else {
            Permissions.request(permission)
        }
        refresh(force: true)
    }

    private func showError(title: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: t("ОК", "OK"))
        alert.runModal()
    }
}

let app = NSApplication.shared
let launchArguments = Array(CommandLine.arguments.dropFirst())
if launchArguments.first == RECORDING_HUD_EXPORT_ARGUMENT {
    guard launchArguments.count == 2 else {
        fputs("usage: SuperDictate --export-hud-animation <frames-directory>\n", stderr)
        exit(EXIT_FAILURE)
    }
    do {
        try exportRecordingHUDAnimationFrames(to: URL(fileURLWithPath: launchArguments[1],
                                                       isDirectory: true))
        exit(EXIT_SUCCESS)
    } catch {
        fputs("HUD export failed: \(error.localizedDescription)\n", stderr)
        exit(EXIT_FAILURE)
    }
} else if let launch = UpdateProgressLaunch(arguments: launchArguments) {
    let delegate = UpdateProgressAppDelegate(launch: launch)
    app.delegate = delegate
    app.run()
} else if launchArguments.contains(AGENT_ARGUMENT) {
    app.setActivationPolicy(.accessory)
    let delegate = ParakeyApp()
    app.delegate = delegate
    // Refuse to start under a tampered launch environment that would
    // redirect FluidAudio's model download to an attacker-controlled host.
    // Runs after NSApplication.shared is initialised so NSAlert.runModal
    // has its event loop.
    refuseHostileRegistryEnvironmentAndExit()
    app.run()
} else {
    let delegate = SuperDictateControlPanelApp()
    app.delegate = delegate
    app.run()
}
