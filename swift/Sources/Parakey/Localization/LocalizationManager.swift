// Parakey — push-to-talk dictation for macOS Apple Silicon.
// Localization / LocalizationManager.swift

import Foundation

enum LocalizationKey: String {
    // Menu Bar & Status
    case menuReady = "menu.ready"
    case menuRecording = "menu.recording"
    case menuTranscribing = "menu.transcribing"
    case menuError = "menu.error"
    case menuLoading = "menu.loading"
    case menuSettings = "menu.settings"
    case menuHistory = "menu.history"
    case menuQuit = "menu.quit"

    // Diagnostics & Errors
    case micPermissionMissing = "error.mic_permission_missing"
    case axPermissionMissing = "error.ax_permission_missing"
    case modelNotFound = "error.model_not_found"

    // Settings
    case hotkey = "settings.hotkey"
    case language = "settings.language"
    case soundFeedback = "settings.sound_feedback"
    case removeFillerWords = "settings.remove_filler_words"
    case removeTrailingPeriod = "settings.remove_trailing_period"
}

final class LocalizationManager: @unchecked Sendable {
    static let shared = LocalizationManager()

    var currentLanguage: InterfaceLanguage {
        Settings.shared.interfaceLanguage
    }

    private let strings: [InterfaceLanguage: [LocalizationKey: String]] = [
        .russian: [
            .menuReady: "Готов к диктовке",
            .menuRecording: "Запись…",
            .menuTranscribing: "Распознавание…",
            .menuError: "Ошибка диктовки",
            .menuLoading: "Загрузка модели…",
            .menuSettings: "Настройки…",
            .menuHistory: "История…",
            .menuQuit: "Завершить SuperDictate",
            .micPermissionMissing: "Требуется доступ к микрофону",
            .axPermissionMissing: "Требуется доступ к Универсальному доступу",
            .modelNotFound: "Модель не найдена",
            .hotkey: "Горячая клавиша",
            .language: "Язык интерфейса",
            .soundFeedback: "Звуковые сигналы",
            .removeFillerWords: "Удалять слова-паразиты",
            .removeTrailingPeriod: "Удалять точку в конце",
        ],
        .english: [
            .menuReady: "Ready to dictate",
            .menuRecording: "Recording…",
            .menuTranscribing: "Transcribing…",
            .menuError: "Dictation error",
            .menuLoading: "Loading model…",
            .menuSettings: "Settings…",
            .menuHistory: "History…",
            .menuQuit: "Quit SuperDictate",
            .micPermissionMissing: "Microphone access required",
            .axPermissionMissing: "Accessibility access required",
            .modelNotFound: "Model not found",
            .hotkey: "Hotkey",
            .language: "Interface Language",
            .soundFeedback: "Sound Feedback",
            .removeFillerWords: "Remove filler words",
            .removeTrailingPeriod: "Remove trailing period",
        ]
    ]

    func string(for key: LocalizationKey, language: InterfaceLanguage? = nil) -> String {
        let lang = language ?? currentLanguage
        return strings[lang]?[key] ?? strings[.english]?[key] ?? key.rawValue
    }
}
