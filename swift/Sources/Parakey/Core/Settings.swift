// Parakey — push-to-talk dictation for macOS Apple Silicon.
// Core / Settings.swift

import AppKit
import CoreAudio
import CoreGraphics
import FluidAudio
import Foundation

// MARK: - Hotkey Choices & Shortcuts

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

func hotkeyChoice(for event: NSEvent) -> HotkeyChoice? {
    if event.type == .flagsChanged {
        let code = event.keyCode
        if code == RIGHT_COMMAND_KEYCODE || code == LEFT_COMMAND_KEYCODE ||
           code == RIGHT_OPTION_KEYCODE || code == RIGHT_SHIFT_KEYCODE ||
           code == FN_KEYCODE {
            return recordableHotkeyChoice(forKeycode: code, modifiers: [])
        }
        return nil
    } else if event.type == .keyDown {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        var cgFlags: CGEventFlags = []
        if flags.contains(.command) { cgFlags.insert(.maskCommand) }
        if flags.contains(.shift) { cgFlags.insert(.maskShift) }
        if flags.contains(.option) { cgFlags.insert(.maskAlternate) }
        if flags.contains(.control) { cgFlags.insert(.maskControl) }
        return recordableHotkeyChoice(forKeycode: event.keyCode, modifiers: cgFlags)
    }
    return nil
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
          MODIFIER_HOTKEY_CHOICES.contains(where: { $0.keycode == CGKeyCode(raw) })
            || FUNCTION_KEY_NAMES_BY_KEYCODE[CGKeyCode(raw)] != nil
            || HOTKEY_KEY_NAMES_BY_KEYCODE[CGKeyCode(raw)] != nil else {
        return nil
    }
    return CGKeyCode(raw)
}

enum TriggerMode: String {
    case hold
    case toggle
}

enum DictationCompletionBehavior: String, CaseIterable {
    case insert = "insert"
    case insertAndEnter = "insert_and_enter"

    var opposite: DictationCompletionBehavior {
        switch self {
        case .insert: return .insertAndEnter
        case .insertAndEnter: return .insert
        }
    }

    var pressesEnter: Bool {
        self == .insertAndEnter
    }
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

enum PasteSuffix: String {
    case appendSpace = "space"
    case none
    case appendNewline = "newline"
}

let PASTE_SUFFIX_DISPLAY: [PasteSuffix: String] = [
    .appendSpace: "Append space",
    .none: "No suffix",
    .appendNewline: "Append newline",
]

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

    var expectedTransferBytes: Int64 {
        switch self {
        case .multilingualV3, .englishUnified:
            return 483_256_769
        }
    }

    var downloadSizeText: String {
        "about 500-700 MB"
    }

    var readyDetail: String {
        switch self {
        case .multilingualV3, .englishUnified:
            return "Fast 0.6B multilingual speech model (~475 MB, Apple Neural Engine)."
        }
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

    var color: NSColor {
        switch self {
        case .red: return NSColor(srgbRed: 0.98, green: 0.24, blue: 0.27, alpha: 1.0)
        case .orange: return NSColor(srgbRed: 1.00, green: 0.58, blue: 0.00, alpha: 1.0)
        case .pink: return NSColor(srgbRed: 1.00, green: 0.18, blue: 0.57, alpha: 1.0)
        case .purple: return NSColor(srgbRed: 0.69, green: 0.32, blue: 0.87, alpha: 1.0)
        case .blue: return NSColor(srgbRed: 0.12, green: 0.53, blue: 0.98, alpha: 1.0)
        case .cyan: return NSColor(srgbRed: 0.20, green: 0.78, blue: 0.88, alpha: 1.0)
        case .green: return NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1.0)
        case .white: return NSColor(srgbRed: 0.95, green: 0.95, blue: 0.97, alpha: 1.0)
        }
    }

    var nsColor: NSColor { color }
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
        case .compact: return 0.85
        case .standard: return 1.0
        case .large: return 1.2
        }
    }

    var size: NSSize {
        switch self {
        case .compact: return NSSize(width: 54, height: 32)
        case .standard: return RECORDING_HUD_BASE_SIZE
        case .large: return NSSize(width: 76, height: 44)
        }
    }

    var expandedSize: NSSize {
        NSSize(width: size.width * 1.5, height: size.height)
    }
}

enum RecordingHUDBackgroundStyle: String, CaseIterable {
    case system
    case dark
    case light

    var displayName: String {
        switch self {
        case .system: return "Match System"
        case .dark: return "Dark"
        case .light: return "Light"
        }
    }
}

func parseRecentTranscriptLimit(storedValue value: Any?) -> RecentTranscriptLimit? {
    if let string = value as? String, let limit = RecentTranscriptLimit(rawValue: string) {
        return limit
    }
    if let number = value as? NSNumber, let limit = RecentTranscriptLimit(rawValue: number.stringValue) {
        return limit
    }
    return nil
}

func limitedRecentTranscripts(_ transcripts: [String], limit: RecentTranscriptLimit) -> [String] {
    let clean = transcripts
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    return Array(clean.prefix(limit.count))
}

struct ASRTimingBreakdown: Codable, Equatable, Sendable {
    let totalSeconds: Double
    let workerQueueSeconds: Double
    let decoderPreparationSeconds: Double
    let fluidCallSeconds: Double
    let fluidProcessingSeconds: Double?

    var unmeasuredSeconds: Double {
        max(0, totalSeconds - (workerQueueSeconds + decoderPreparationSeconds + fluidCallSeconds))
    }

    var fluidUnmeasuredSeconds: Double? {
        guard let fluidProcessingSeconds else { return nil }
        return max(0, fluidCallSeconds - fluidProcessingSeconds)
    }

    var frameworkOverheadSeconds: Double {
        guard let fluidProcessingSeconds else { return 0 }
        return max(0, fluidCallSeconds - fluidProcessingSeconds)
    }

    var isZero: Bool {
        totalSeconds == 0
            && workerQueueSeconds == 0
            && decoderPreparationSeconds == 0
            && fluidCallSeconds == 0
            && (fluidProcessingSeconds == nil || fluidProcessingSeconds == 0)
    }
}

func millisecondsLabel(_ duration: Double?) -> String {
    guard let duration, duration.isFinite else { return "off" }
    return String(format: "%.1f ms", max(0, duration) * 1_000)
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
    let aiCleanupSeconds: Double?
    let historyPersistenceSeconds: Double
    let journalCleanupSeconds: Double
    let permissionRecheckSeconds: Double
    let insertionDispatchSeconds: Double
    let releaseToPasteDispatchSeconds: Double
    let enterDelaySeconds: Double?
    let pasteSucceeded: Bool

    var logLine: String {
        let enter = enterDelaySeconds.map { millisecondsLabel($0) } ?? "off"
        let hotkeyDispatch = hotkeyDispatchSeconds.map { millisecondsLabel($0) } ?? "off"
        let aiCleanup = aiCleanupSeconds.map { millisecondsLabel($0) } ?? "off"
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
            "ai_cleanup=\(aiCleanup)",
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
    let clean = entries.filter {
        !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    return Array(clean.prefix(limit.count))
}

func limitedTranscriptHistoryArchive(_ entries: [TranscriptHistoryEntry],
                                     maxEntries: Int = TRANSCRIPT_HISTORY_ARCHIVE_MAX_ENTRIES) -> [TranscriptHistoryEntry] {
    let clean = entries.filter {
        !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    return Array(clean.prefix(maxEntries))
}

func limitedTranscriptHistoryArchive(_ entries: [TranscriptHistoryEntry],
                                     maximumCount: Int) -> [TranscriptHistoryEntry] {
    limitedTranscriptHistoryArchive(entries, maxEntries: maximumCount)
}

func transcriptHistoryArchive(_ entries: [TranscriptHistoryEntry],
                              inserting entry: TranscriptHistoryEntry,
                              maxEntries: Int = TRANSCRIPT_HISTORY_ARCHIVE_MAX_ENTRIES) -> [TranscriptHistoryEntry] {
    guard !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return limitedTranscriptHistoryArchive(entries, maxEntries: maxEntries)
    }
    var updated = [entry]
    updated.append(contentsOf: entries.filter {
        !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    })
    return limitedTranscriptHistoryArchive(updated, maxEntries: maxEntries)
}

func transcriptHistoryArchive(_ entries: [TranscriptHistoryEntry],
                              removing index: Int) -> [TranscriptHistoryEntry] {
    guard index >= 0, index < entries.count else { return entries }
    var updated = entries
    updated.remove(at: index)
    return updated
}

struct DailyDictationUsage: Codable, Equatable {
    let day: String
    let characterCount: Int
    let dictationCount: Int
    let audioSeconds: Double
    let asrSeconds: Double
}

struct DictationUsageDaySlot: Equatable {
    let date: Date
    let usage: DailyDictationUsage
}

struct DictationUsageWeekSnapshot: Equatable {
    let days: [DictationUsageDaySlot]
    let totalCharacters: Int
    let totalDictations: Int
    let totalAudioSeconds: Double
    let totalASRSeconds: Double

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

func dictationUsageDayKey(for date: Date, calendar: Calendar = .current) -> String {
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d",
                  components.year ?? 0,
                  components.month ?? 0,
                  components.day ?? 0)
}

func mergedDailyDictationUsage(_ stats: [DailyDictationUsage],
                               maxDays: Int = 365) -> [DailyDictationUsage] {
    var byDay: [String: (charCount: Int, dictCount: Int, audioSec: Double, asrSec: Double)] = [:]
    for entry in stats {
        guard !entry.day.isEmpty else { continue }
        let existing = byDay[entry.day, default: (0, 0, 0, 0)]
        byDay[entry.day] = (
            existing.charCount + max(0, entry.characterCount),
            existing.dictCount + max(0, entry.dictationCount),
            existing.audioSec + max(0, entry.audioSeconds),
            existing.asrSec + max(0, entry.asrSeconds)
        )
    }
    return byDay.keys.sorted().suffix(maxDays).map { day in
        let (charCount, dictCount, audioSec, asrSec) = byDay[day]!
        return DailyDictationUsage(day: day,
                                   characterCount: charCount,
                                   dictationCount: dictCount,
                                   audioSeconds: audioSec,
                                   asrSeconds: asrSec)
    }
}

func addingDictationUsageSample(to stats: [DailyDictationUsage],
                                at date: Date = Date(),
                                characterCount: Int,
                                audioSeconds: Double,
                                asrSeconds: Double,
                                calendar: Calendar = .current,
                                maxDays: Int = 365) -> [DailyDictationUsage] {
    let key = dictationUsageDayKey(for: date, calendar: calendar)
    var updated = stats
    if let index = updated.firstIndex(where: { $0.day == key }) {
        let existing = updated[index]
        updated[index] = DailyDictationUsage(
            day: key,
            characterCount: existing.characterCount + max(0, characterCount),
            dictationCount: existing.dictationCount + 1,
            audioSeconds: existing.audioSeconds + max(0, audioSeconds),
            asrSeconds: existing.asrSeconds + max(0, asrSeconds)
        )
    } else {
        updated.append(DailyDictationUsage(
            day: key,
            characterCount: max(0, characterCount),
            dictationCount: 1,
            audioSeconds: max(0, audioSeconds),
            asrSeconds: max(0, asrSeconds)
        ))
    }
    return mergedDailyDictationUsage(updated, maxDays: maxDays)
}

func lastSevenCompletedDictationUsage(_ stats: [DailyDictationUsage],
                                     referenceDate: Date = Date(),
                                     calendar: Calendar = .current) -> DictationUsageWeekSnapshot {
    let statsByDay = Dictionary(uniqueKeysWithValues: stats.map { ($0.day, $0) })
    var completed: [DictationUsageDaySlot] = []

    for offset in (1...7).reversed() {
        guard let slotDate = calendar.date(byAdding: .day, value: -offset, to: referenceDate) else { continue }
        let key = dictationUsageDayKey(for: slotDate, calendar: calendar)
        let usage = statsByDay[key] ?? DailyDictationUsage(day: key,
                                                           characterCount: 0,
                                                           dictationCount: 0,
                                                           audioSeconds: 0,
                                                           asrSeconds: 0)
        completed.append(DictationUsageDaySlot(date: slotDate, usage: usage))
    }

    let totalChars = completed.reduce(0) { $0 + $1.usage.characterCount }
    let totalDicts = completed.reduce(0) { $0 + $1.usage.dictationCount }
    let totalAudio = completed.reduce(0.0) { $0 + $1.usage.audioSeconds }
    let totalASR = completed.reduce(0.0) { $0 + $1.usage.asrSeconds }

    return DictationUsageWeekSnapshot(
        days: completed,
        totalCharacters: totalChars,
        totalDictations: totalDicts,
        totalAudioSeconds: totalAudio,
        totalASRSeconds: totalASR
    )
}

func importedDailyDictationUsage(from logText: String,
                                 fileCreatedAt: Date = Date(),
                                 calendar: Calendar = .current) -> [DailyDictationUsage] {
    var result: [DailyDictationUsage] = []
    let lines = logText.components(separatedBy: .newlines)
    var currentDate = fileCreatedAt
    var lastHour = calendar.component(.hour, from: fileCreatedAt)

    let regex = try? NSRegularExpression(
        pattern: #"\[(\d{2}):(\d{2}):(\d{2})\]\s+([0-9.]+)\s*s\s+audio\s+→\s+([0-9.]+)\s*s\s+→\s+(\d+)\s+chars"#
    )

    for line in lines {
        let range = NSRange(location: 0, length: line.utf16.count)
        guard let match = regex?.firstMatch(in: line, range: range),
              let hourRange = Range(match.range(at: 1), in: line),
              let hour = Int(line[hourRange]),
              let audioRange = Range(match.range(at: 4), in: line),
              let audioSeconds = Double(line[audioRange]),
              let asrRange = Range(match.range(at: 5), in: line),
              let asrSeconds = Double(line[asrRange]),
              let charsRange = Range(match.range(at: 6), in: line),
              let chars = Int(line[charsRange]) else {
            continue
        }

        if hour < lastHour && (lastHour - hour) > 12 {
            currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate) ?? currentDate
        }
        lastHour = hour

        guard chars > 0 else { continue }
        result = addingDictationUsageSample(
            to: result,
            at: currentDate,
            characterCount: chars,
            audioSeconds: audioSeconds,
            asrSeconds: asrSeconds,
            calendar: calendar
        )
    }

    return result
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
        "FluidAudio  \(millisecondsLabel(timing.fluidProcessingSeconds ?? 0))",
        "Decoder setup  \(millisecondsLabel(timing.decoderPreparationSeconds))",
        "Actor + framework  \(millisecondsLabel(timing.workerQueueSeconds + timing.frameworkOverheadSeconds))",
    ].joined(separator: "\n")
}

struct DictationDurationSummary: Equatable {
    let count: Int
    let minSeconds: Double
    let averageSeconds: Double
    let medianSeconds: Double
    let p95Seconds: Double
    let maxSeconds: Double

    init?(samples: [Double]) {
        let clean = samples.filter { $0.isFinite && $0 >= 0 }.sorted()
        guard !clean.isEmpty else { return nil }
        count = clean.count
        minSeconds = clean.first!
        maxSeconds = clean.last!
        averageSeconds = clean.reduce(0, +) / Double(clean.count)

        if clean.count % 2 == 0 {
            medianSeconds = (clean[clean.count / 2 - 1] + clean[clean.count / 2]) / 2
        } else {
            medianSeconds = clean[clean.count / 2]
        }

        let p95Index = min(clean.count - 1, Int(ceil(Double(clean.count) * 0.95)) - 1)
        p95Seconds = clean[max(0, p95Index)]
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

enum MenuBarState: Equatable {
    case idle
    case recording
    case transcribing
    case busy
    case loading
    case error
    case disabled
}

let TRIGGER_DISPLAY: [TriggerMode: String] = [
    .hold: "Hold",
    .toggle: "Toggle",
]

enum UpdateCheckSource: String, Equatable {
    case automatic
    case manual
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
                       currentVersion: String = currentBundleVersion(),
                       skippedVersions: [String] = []) -> UpdateCheckResult {
    guard let release else { return .failed }
    if !isNewer(release.version, than: currentVersion) {
        return .upToDate
    }
    if skippedVersions.contains(release.version) {
        return .skipped
    }
    return .available
}

func shouldSuppressUpdateForReminder(version: String,
                                     reminderVersion: String?,
                                     reminderUntil: Date?,
                                     now: Date = Date()) -> Bool {
    guard let reminderVersion,
          let reminderUntil,
          reminderVersion == version else { return false }
    return now < reminderUntil
}

func shouldClearUpdateReminderPause(fetchedVersion: String,
                                     pausedVersion: String?) -> Bool {
    guard let pausedVersion else { return false }
    return fetchedVersion == pausedVersion || isNewer(fetchedVersion, than: pausedVersion)
}

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
                               releaseVersion: String = "") -> String {
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

// MARK: - Settings Class

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
    private static let keyAICleanupEnabled = "ai_cleanup_enabled"
    private static let keyAICleanupBaseURL = "ai_cleanup_base_url"
    private static let keyAICleanupModel = "ai_cleanup_model"
    private static let keyRemoveFinalPeriod = "remove_final_period_v1"
    private static let keyEnterDelayMilliseconds = "enter_delay_milliseconds_v1"
    private static let keyActiveRunMarker = "active_run_marker"
    private static let keyAgentEnabled = "agent_enabled"

    private let defaults: UserDefaults

    static let shared = Settings()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
                return .insert
            }
            return behavior
        }
        set { defaults.set(newValue.rawValue, forKey: Self.keyPrimaryCompletionBehavior) }
    }

    var alternateCompletionEnabled: Bool {
        get {
            guard defaults.object(forKey: Self.keyAlternateCompletionEnabled) != nil else {
                return true
            }
            return defaults.bool(forKey: Self.keyAlternateCompletionEnabled)
        }
        set { defaults.set(newValue, forKey: Self.keyAlternateCompletionEnabled) }
    }

    var enterDelayMilliseconds: Int {
        get {
            guard defaults.object(forKey: Self.keyEnterDelayMilliseconds) != nil else {
                return 120
            }
            return max(0, min(500, defaults.integer(forKey: Self.keyEnterDelayMilliseconds)))
        }
        set { defaults.set(max(0, min(500, newValue)), forKey: Self.keyEnterDelayMilliseconds) }
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

    var aiCleanupEnabled: Bool {
        get { defaults.bool(forKey: Self.keyAICleanupEnabled) }
        set { defaults.set(newValue, forKey: Self.keyAICleanupEnabled) }
    }

    var aiCleanupBaseURL: String {
        get {
            let stored = defaults.string(forKey: Self.keyAICleanupBaseURL)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return stored.isEmpty ? AICleanupSettings.defaultBaseURL : stored
        }
        set { defaults.set(newValue, forKey: Self.keyAICleanupBaseURL) }
    }

    var aiCleanupModel: String {
        get {
            let stored = defaults.string(forKey: Self.keyAICleanupModel)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if stored.isEmpty || AICleanupSettings.legacyDefaultModels.contains(stored) {
                return AICleanupSettings.defaultModel
            }
            return stored
        }
        set { defaults.set(newValue, forKey: Self.keyAICleanupModel) }
    }

    var removeFinalPeriod: Bool {
        get { defaults.bool(forKey: Self.keyRemoveFinalPeriod) }
        set { defaults.set(newValue, forKey: Self.keyRemoveFinalPeriod) }
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
