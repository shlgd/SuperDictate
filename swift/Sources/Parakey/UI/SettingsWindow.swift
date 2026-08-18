// Parakey — push-to-talk dictation for macOS Apple Silicon.
// UI / SettingsWindow.swift

import Foundation
import CoreGraphics
import AppKit

private enum ControlPanelServiceOperation: String, Sendable {
    case starting
    case restarting
    case stopping
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
    var enterDelayMilliseconds: Int
    var aiCleanupEnabled: Bool
    var aiCleanupBaseURL: String
    var aiCleanupModel: String
    var inputDevicePreference: String
    var removeFinalPeriod: Bool
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
        enterDelayMilliseconds = settings.enterDelayMilliseconds
        aiCleanupEnabled = settings.aiCleanupEnabled && AIKeyStore.read() != nil
        aiCleanupBaseURL = settings.aiCleanupBaseURL
        aiCleanupModel = settings.aiCleanupModel
        let savedInput = settings.inputDevice
        inputDevicePreference = audioInputDevice(matching: savedInput)?.uid ?? savedInput
        removeFinalPeriod = settings.removeFinalPeriod
        recordingColor = settings.recordingHUDRecordingColor
        transcribingColor = settings.recordingHUDTranscribingColor
        backgroundStyle = settings.recordingHUDBackgroundStyle
        hudSize = settings.recordingHUDSize
    }
}

private func hotkeysConflict(_ lhs: HotkeyChoice, _ rhs: HotkeyChoice) -> Bool {
    lhs.keycode == rhs.keycode && lhs.requiredModifiers == rhs.requiredModifiers
}

func hotkeyIsModifierPrefix(_ prefix: HotkeyChoice,
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

func settingsWindowContentHeight(visibleScreenHeight: CGFloat?) -> CGFloat {
    guard let visibleScreenHeight else { return 760 }
    return max(520, min(760, visibleScreenHeight - 80))
}

@MainActor
private final class SettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class SuperDictateControlPanelApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
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
    private weak var aiKeyField: NSSecureTextField?
    private weak var aiBaseURLField: NSTextField?
    private weak var aiModelField: NSTextField?
    private weak var settingsScrollView: NSScrollView?
    private var pendingAIKey = ""

    private var language: InterfaceLanguage { settings.interfaceLanguage }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard SuperDictateControlPanelRegistry.claimCurrentPanel() else {
            _ = SuperDictateControlPanelRegistry.activateExistingPanelIfPresent()
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.regular)
        showWindow()
        startRefreshTimer()
        checkForUpdates()
        if settings.agentEnabled && !SuperDictateAgentService.isAgentLoadedOrRunning() {
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
            aiKeyField = nil
            aiBaseURLField = nil
            aiModelField = nil
            settingsScrollView = nil
            pendingAIKey = ""
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
        }
    }

    private func resizeCompactPanel(_ window: NSWindow) {
        let missingCount = Permission.allCases.filter { !Permissions.isGranted($0) }.count
        let state = AgentRuntimeStateStore.read()
        let showsModelProgress = SuperDictateAgentService.isAgentRunning()
            && state?.status == "starting"
            && state?.modelDownloadPhase != nil
        let modelProgressHeight = showsModelProgress ? 26 : 0
        let height = CGFloat(310 + max(0, missingCount - 1) * 28 + modelProgressHeight)
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
        let inputDevices = settingsWindow?.isVisible == true
            ? availableAudioInputDevices()
                .map { "\($0.uid)=\($0.name)" }
                .joined(separator: "|")
            : ""
        let stateToken: String
        if serviceOperation != nil {
            stateToken = "operation"
        } else {
            let rawStatus = state?.status ?? "none"
            let isHealthyRuntimeState = ["ready", "recording", "transcribing"].contains(rawStatus)
            let phase = state?.modelDownloadPhase ?? ""
            let startupProgressClock = rawStatus == "starting"
                && (phase == "listing" || phase == "downloading" || phase == "preparing")
                ? String(Int(Date().timeIntervalSince1970 / 3))
                : ""
            let detailToken = isHealthyRuntimeState ? "" : (state?.detail ?? "")
            let progressToken = state?.downloadProgressFraction
                .map { String(format: "%.2f", $0) } ?? ""
            let downloadedToken = state?.modelDownloadedBytes.map { String($0) } ?? ""
            let totalToken = state?.modelDownloadTotalBytes.map { String($0) } ?? ""
            let speedToken = state?.modelDownloadBytesPerSecond
                .map { String(format: "%.0f", $0) } ?? ""
            let etaToken = state?.modelDownloadEstimatedSecondsRemaining
                .map { String(format: "%.0f", $0) } ?? ""
            stateToken = [isHealthyRuntimeState ? "ready" : rawStatus,
                          detailToken,
                          progressToken,
                          phase,
                          downloadedToken,
                          totalToken,
                          speedToken,
                          etaToken,
                          startupProgressClock,
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
                settings.inputDevice,
                inputDevices,
                settings.primaryCompletionBehavior.rawValue,
                settings.alternateCompletionEnabled ? "alternate-on" : "alternate-off",
                settings.removeFinalPeriod ? "remove-period-on" : "remove-period-off",
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
        root.addArrangedSubview(enterDelayRow(draft))
        root.addArrangedSubview(separator())
        root.addArrangedSubview(aiCleanupSection(draft))
        root.addArrangedSubview(separator())
        root.addArrangedSubview(hotkeyRow(
            title: t("История", "History"),
            shortcut: draft.historyHotkey,
            kind: .history,
            toolTip: t("Открыть или закрыть последние транскрипции.",
                       "Open or close recent transcriptions.")
        ))
        root.addArrangedSubview(separator())
        root.addArrangedSubview(microphoneSettingsRow(draft))
        root.addArrangedSubview(separator())
        root.addArrangedSubview(panelLabel(t("Обработка текста", "Text processing"),
                                           size: 12,
                                           weight: .semibold,
                                           color: .secondaryLabelColor))
        root.addArrangedSubview(removeFinalPeriodRow(draft))
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
        root.addArrangedSubview(separator())
        root.addArrangedSubview(permissionsRecoveryRow())
        root.addArrangedSubview(settingsActionsRow(draft: draft))
        root.addArrangedSubview(privacyInfoView())

        let background = NSVisualEffectView()
        background.material = .underWindowBackground
        background.blendingMode = .behindWindow
        background.state = .active

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        settingsScrollView = scroll

        let document = SettingsDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(root)
        scroll.documentView = document
        background.addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: background.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            root.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            root.topAnchor.constraint(equalTo: document.topAnchor),
            root.bottomAnchor.constraint(equalTo: document.bottomAnchor),
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
            t("Изменения применяются после сохранения — перезапуск модели не нужен.",
              "Changes apply after saving; the speech model does not need to restart."),
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
        let showsModelProgress = running
            && state?.status == "starting"
            && state?.modelDownloadPhase != nil
        let detailText = showsModelProgress
            ? presentation.detail
            : "\(presentation.detail)\n\(primaryShortcut) · \(historyShortcut)"
        let detail = panelLabel(
            detailText,
            size: 11.5,
            color: .secondaryLabelColor
        )
        detail.maximumNumberOfLines = showsModelProgress ? 3 : 2
        detail.lineBreakMode = showsModelProgress ? .byWordWrapping : .byTruncatingTail
        detail.toolTip = "\(presentation.detail)\n\(primaryShortcut)\n\(primaryAction)\n\(alternateShortcut)\n\(historyShortcut)"
        text.addArrangedSubview(detail)

        // Progress bar for download
        if running, state?.status == "starting", let fraction = state?.downloadProgressFraction {
            let progressBar = NSProgressIndicator()
            progressBar.style = .bar
            progressBar.controlSize = .small
            progressBar.isIndeterminate = false
            progressBar.minValue = 0
            progressBar.maxValue = 1
            progressBar.doubleValue = fraction
            progressBar.translatesAutoresizingMaskIntoConstraints = false
            progressBar.heightAnchor.constraint(equalToConstant: 6).isActive = true
            text.addArrangedSubview(progressBar)
            progressBar.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
        } else if running, state?.status == "starting" {
            let progressBar = NSProgressIndicator()
            progressBar.style = .bar
            progressBar.controlSize = .small
            progressBar.isIndeterminate = true
            progressBar.startAnimation(nil)
            progressBar.translatesAutoresizingMaskIntoConstraints = false
            progressBar.heightAnchor.constraint(equalToConstant: 6).isActive = true
            text.addArrangedSubview(progressBar)
            progressBar.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
        }

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 5
        let enabled = serviceOperation == nil
        let restartEnabled = enabled && state?.status != "starting"
        if running {
            actions.addArrangedSubview(compactIconButton(
                symbol: "arrow.clockwise",
                accessibilityTitle: t("Перезапустить службу", "Restart Service"),
                toolTip: restartEnabled
                    ? t("Перезапустить фоновую службу, не закрывая панель",
                        "Restart the background service without closing the panel")
                    : t("Дождитесь завершения подготовки модели.",
                        "Wait for model preparation to finish."),
                action: #selector(restartAgentClicked(_:)),
                enabled: restartEnabled
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
            ? t("Открыть настройки", "Open Settings") : t("Разрешить", "Grant")
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
        }
    }

    private func operationDetail(_ operation: ControlPanelServiceOperation) -> String {
        switch operation {
        case .starting:
            return t("Подключаю глобальный хоткей и локальную модель.\nОбычно 1–3 секунды; при первой загрузке дольше.",
                     "Enabling the global shortcut and local model.\nUsually 1–3 seconds; the first download takes longer.")
        case .restarting:
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
            if operation != .stopping,
               running,
               let state,
               state.status == "starting",
               state.modelDownloadPhase != nil {
                return (localizedStartupStatus(state),
                        localizedServiceDetail(state),
                        colorForStatus(state.status))
            }
            return (operationTitle(operation), operationDetail(operation), .systemBlue)
        }
        if running, let state {
            if ["ready", "recording", "transcribing"].contains(state.status) {
                return (t("Работает", "Running"),
                        t("Фоновая служба включена.", "The background service is running."),
                        .systemGreen)
            }
            if state.status == "starting" {
                return (localizedStartupStatus(state),
                        localizedServiceDetail(state),
                        colorForStatus(state.status))
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

    private static let enterDelayOptions: [(title: String, value: String)] = [
        ("0 ms", "0"),
        ("50 ms", "50"),
        ("80 ms", "80"),
        ("120 ms", "120"),
        ("200 ms", "200"),
        ("300 ms", "300"),
    ]

    private func enterDelayRow(_ draft: ControlPanelSettingsDraft) -> NSView {
        popupRow(
            title: t("Задержка Enter", "Enter delay"),
            detail: t("Пауза между вставкой текста и нажатием Enter.",
                      "Pause between inserting text and pressing Enter."),
            selectedValue: String(draft.enterDelayMilliseconds),
            options: Self.enterDelayOptions,
            action: #selector(selectEnterDelay(_:)),
            toolTip: t("Некоторым приложениям (Electron, VM) нужна пауза после вставки. Уменьшите для быстрых приложений.",
                       "Some apps (Electron, VMs) need a pause after paste. Lower for fast native apps.")
        )
    }

    private func aiCleanupSection(_ draft: ControlPanelSettingsDraft) -> NSView {
        let section = NSStackView()
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8

        section.addArrangedSubview(panelLabel(t("AI-чистка текста", "AI Cleanup"),
                                              size: 13,
                                              weight: .semibold))
        let detail = panelLabel(
            t("Необязательно: после распознавания текст отправляется на OpenAI-совместимый сервер для исправления грамматики и пунктуации. По умолчанию выключено.",
              "Optional: after transcription the text is sent to an OpenAI-compatible endpoint to fix grammar and punctuation. Off by default."),
            size: 12,
            color: .secondaryLabelColor
        )
        detail.preferredMaxLayoutWidth = 620
        section.addArrangedSubview(detail)

        let hasKey = AIKeyStore.read() != nil
        let enableRow = NSStackView()
        enableRow.orientation = .horizontal
        enableRow.alignment = .centerY
        enableRow.spacing = 10
        let toggle = NSSwitch()
        toggle.target = self
        toggle.action = #selector(toggleAICleanupDraft(_:))
        toggle.state = draft.aiCleanupEnabled ? .on : .off
        toggle.isEnabled = hasKey
        toggle.toolTip = hasKey
            ? t("Включить AI-чистку после распознавания.",
                "Enable AI cleanup after transcription.")
            : t("Сначала сохраните API-ключ.", "Save an API key first.")
        toggle.setContentHuggingPriority(.required, for: .horizontal)
        enableRow.addArrangedSubview(toggle)
        enableRow.addArrangedSubview(panelLabel(
            t("Включить AI-чистку", "Enable AI cleanup"),
            size: 12
        ))
        section.addArrangedSubview(enableRow)

        let urlField = NSTextField(string: draft.aiCleanupBaseURL)
        urlField.placeholderString = AICleanupSettings.defaultBaseURL
        urlField.font = .systemFont(ofSize: 12)
        urlField.target = self
        urlField.action = #selector(aiCleanupBaseURLChanged(_:))
        urlField.toolTip = t("Базовый URL OpenAI-совместимого API (без /chat/completions).",
                             "Base URL of the OpenAI-compatible API (without /chat/completions).")
        urlField.widthAnchor.constraint(equalToConstant: 420).isActive = true
        aiBaseURLField = urlField
        section.addArrangedSubview(urlField)

        let modelField = NSTextField(string: draft.aiCleanupModel)
        modelField.placeholderString = AICleanupSettings.defaultModel
        modelField.font = .systemFont(ofSize: 12)
        modelField.target = self
        modelField.action = #selector(aiCleanupModelChanged(_:))
        modelField.toolTip = t("Имя модели на выбранном сервере.",
                               "Model name on the configured endpoint.")
        modelField.widthAnchor.constraint(equalToConstant: 420).isActive = true
        aiModelField = modelField
        section.addArrangedSubview(modelField)

        let keyRow = NSStackView()
        keyRow.orientation = .horizontal
        keyRow.alignment = .centerY
        keyRow.spacing = 8
        let keyField = NSSecureTextField()
        keyField.stringValue = pendingAIKey
        keyField.placeholderString = hasKey
            ? t("•••• сохранён", "•••• saved")
            : t("API-ключ", "API key")
        keyField.font = .systemFont(ofSize: 12)
        keyField.toolTip = t("Ключ хранится только в Связке ключей macOS.",
                             "The key is stored only in the macOS Keychain.")
        keyField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        aiKeyField = keyField
        keyRow.addArrangedSubview(keyField)
        keyRow.addArrangedSubview(panelButton(
            t("Сохранить ключ", "Save Key"),
            action: #selector(saveAIKeyClicked(_:)),
            toolTip: t("Записать ключ в Связку ключей macOS.",
                       "Write the key to the macOS Keychain.")
        ))
        keyRow.addArrangedSubview(panelButton(
            t("Удалить ключ", "Remove Key"),
            action: #selector(removeAIKeyClicked(_:)),
            enabled: hasKey,
            toolTip: t("Удалить сохранённый ключ из Связки ключей.",
                       "Delete the saved key from the Keychain.")
        ))
        keyRow.addArrangedSubview(panelButton(
            t("Проверить подключение", "Test Connection"),
            action: #selector(testAICleanupConnectionClicked(_:)),
            enabled: hasKey,
            toolTip: t("Отправить тестовый запрос к {базовый URL}/models.",
                       "Send a test request to {base URL}/models.")
        ))
        section.addArrangedSubview(keyRow)

        let privacyNote = panelLabel(
            t("Внимание: продиктованный текст отправляется выбранному провайдеру. Бесплатные тарифы (например, OpenCode Zen) могут сохранять отправленный текст для улучшения модели — перед диктовкой личных текстов проверьте политику данных провайдера.",
              "Note: dictated text is sent to the configured provider. Free tiers (e.g. OpenCode Zen) may retain submitted text for model improvement — check your provider's data policy before dictating personal content."),
            size: 11.5,
            color: .secondaryLabelColor
        )
        privacyNote.preferredMaxLayoutWidth = 620
        section.addArrangedSubview(privacyNote)

        let docsLink = NSButton(title: "console.groq.com",
                                target: self,
                                action: #selector(openAIProviderDocsClicked(_:)))
        docsLink.isBordered = false
        docsLink.font = .systemFont(ofSize: 11.5)
        docsLink.contentTintColor = .systemBlue
        docsLink.toolTip = "https://console.groq.com/keys"
        docsLink.setContentHuggingPriority(.required, for: .horizontal)
        section.addArrangedSubview(docsLink)

        return section
    }

    private func microphoneSettingsRow(_ draft: ControlPanelSettingsDraft) -> NSView {
        let devices = availableAudioInputDevices()
        let preference = draft.inputDevicePreference
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedDevice = audioInputDevice(matching: preference, in: devices)
        let unavailable = !preference.isEmpty && selectedDevice == nil

        let detailText: String
        if unavailable {
            detailText = t(
                "Устройство сейчас недоступно — временно используется системный микрофон.",
                "The device is unavailable; the system microphone is used temporarily."
            )
        } else if let selectedDevice {
            detailText = t(
                "Выбран: \(selectedDevice.name). Применится без перезапуска модели.",
                "Selected: \(selectedDevice.name). Applies without restarting the model."
            )
        } else {
            detailText = t(
                "Следовать выбору входа в настройках macOS.",
                "Follow the input selected in macOS settings."
            )
        }

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.addArrangedSubview(panelLabel(t("Микрофон", "Microphone"),
                                           size: 13,
                                           weight: .semibold))
        let detail = panelLabel(detailText, size: 12, color: .secondaryLabelColor)
        detail.maximumNumberOfLines = 2
        detail.lineBreakMode = .byWordWrapping
        text.addArrangedSubview(detail)

        let popup = NSPopUpButton()
        popup.target = self
        popup.action = #selector(selectInputDeviceDraft(_:))
        popup.toolTip = t(
            "Выберите микрофон для диктовки. Отключённое устройство автоматически заменяется системным до его возвращения.",
            "Choose the dictation microphone. A disconnected device falls back to the system input until it returns."
        )
        popup.addItem(withTitle: t("Системный по умолчанию", "System default"))
        popup.lastItem?.representedObject = ""

        if unavailable {
            popup.addItem(withTitle: t("Недоступен: \(preference)", "Unavailable: \(preference)"))
            popup.lastItem?.representedObject = preference
            popup.lastItem?.isEnabled = false
        }
        if !devices.isEmpty {
            popup.menu?.addItem(.separator())
        }
        for device in devices {
            popup.addItem(withTitle: device.name)
            popup.lastItem?.representedObject = device.uid
            popup.lastItem?.toolTip = device.uid
        }

        let selectedValue = selectedDevice?.uid ?? (unavailable ? preference : "")
        if let item = popup.itemArray.first(where: {
            ($0.representedObject as? String) == selectedValue
        }) {
            popup.select(item)
        }
        popup.setContentHuggingPriority(.required, for: .horizontal)

        row.addArrangedSubview(text)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(popup)
        return row
    }

    private func removeFinalPeriodRow(_ draft: ControlPanelSettingsDraft) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.addArrangedSubview(panelLabel(t("Убирать точку в конце", "Remove final period"),
                                           size: 13,
                                           weight: .semibold))
        let detail = panelLabel(
            t("Убирает только последнюю точку. !, ?, многоточия и точки внутри текста сохраняются.",
              "Removes only the final period. !, ?, ellipses, and periods inside the text remain."),
            size: 12,
            color: .secondaryLabelColor
        )
        detail.maximumNumberOfLines = 2
        detail.lineBreakMode = .byWordWrapping
        detail.preferredMaxLayoutWidth = 500
        text.addArrangedSubview(detail)

        let toggle = NSSwitch()
        toggle.target = self
        toggle.action = #selector(toggleRemoveFinalPeriod(_:))
        toggle.state = draft.removeFinalPeriod ? .on : .off
        toggle.isEnabled = serviceOperation == nil
        toggle.toolTip = t("Убрать один символ . только в самом конце распознанного текста.",
                           "Remove one . character only at the very end of transcribed text.")
        toggle.setContentHuggingPriority(.required, for: .horizontal)

        row.addArrangedSubview(text)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(toggle)
        return row
    }

    private func permissionsRecoveryRow() -> NSView {
        let runtime = AgentRuntimeStateStore.read()
        let dictationInProgress = runtime?.isRecording == true
            || runtime?.isTranscribing == true
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.addArrangedSubview(panelLabel(
            t("Восстановление разрешений", "Permission recovery"),
            size: 13,
            weight: .semibold
        ))
        let detail = panelLabel(
            t("Только если доступы macOS сломались после переустановки. Все три разрешения придётся выдать заново.",
              "Use only when macOS permissions became stuck after reinstalling. All three permissions must be granted again."),
            size: 12,
            color: .secondaryLabelColor
        )
        detail.maximumNumberOfLines = 2
        detail.preferredMaxLayoutWidth = 470
        text.addArrangedSubview(detail)

        let reset = panelButton(
            t("Сбросить…", "Reset…"),
            action: #selector(resetPermissionsClicked(_:)),
            enabled: serviceOperation == nil && !dictationInProgress,
            toolTip: dictationInProgress
                ? t("Сначала завершите текущую диктовку.", "Finish the current dictation first.")
                : t("Отозвать разрешения SuperDictate после дополнительного подтверждения.",
                    "Revoke SuperDictate permissions after an additional confirmation.")
        )
        reset.setContentHuggingPriority(.required, for: .horizontal)

        row.addArrangedSubview(text)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(reset)
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
        let agentState = AgentRuntimeStateStore.read()
        let dictationInProgress = agentState?.isRecording == true
            || agentState?.isTranscribing == true
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        let unsavedMessage = dictationInProgress
            ? t("Завершите текущую диктовку, чтобы сохранить",
                "Finish the current dictation before saving")
            : t("Есть несохранённые изменения", "You have unsaved changes")
        let message = panelLabel(
            validation ?? (hasChanges
                ? unsavedMessage
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
            t("Сохранить", "Save"),
            action: #selector(saveSettingsClicked(_:)),
            enabled: hasChanges
                && validation == nil
                && serviceOperation == nil
                && !dictationInProgress,
            toolTip: dictationInProgress
                ? t("Сначала завершите текущую диктовку.",
                    "Finish the current dictation first.")
                : t("Сохранить и применить настройки без перезапуска модели.",
                    "Save and apply settings without restarting the speech model.")
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
        switch aiCleanupConfigurationIssue(enabled: draft.aiCleanupEnabled,
                                           baseURL: draft.aiCleanupBaseURL,
                                           model: draft.aiCleanupModel) {
        case .baseURL:
            return t("Для AI-чистки нужен корректный HTTPS-адрес сервера.",
                     "AI cleanup requires a valid HTTPS endpoint.")
        case .model:
            return t("Укажите корректное имя модели для AI-чистки.",
                     "Enter a valid model name for AI cleanup.")
        case nil:
            break
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
            t("Аудио и распознавание остаются на Mac. Интернет нужен для первой загрузки модели, обновлений и — если включена AI-чистка — для отправки текста на выбранный вами сервер.",
              "Audio and transcription stay on this Mac. Internet is used for the first model download, updates, and — only if AI cleanup is enabled — to send text to the endpoint you configured."),
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

    private func localizedStartupStatus(_ state: AgentRuntimeState) -> String {
        switch state.modelDownloadPhase {
        case "checking", "listing":
            return t("Проверяю модель", "Checking model")
        case "downloading":
            if (state.modelDownloadTotalBytes ?? 0) > 0 {
                return t("Скачиваю модель", "Downloading model")
            }
            return t("Загружаю локальную модель", "Loading local model")
        case "preparing":
            return t("Готовлю Neural Engine", "Preparing Neural Engine")
        case "recovering":
            return t("Восстанавливаю диктовку", "Recovering dictation")
        case "audio":
            return t("Подключаю микрофон", "Starting microphone")
        case "finishing":
            return t("Почти готово", "Almost ready")
        default:
            return t("Запускаю службу", "Starting service")
        }
    }

    private func localizedServiceDetail(_ state: AgentRuntimeState) -> String {
        switch state.status {
        case "ready", "recording", "transcribing":
            return t("Фоновая служба готова к диктовке.",
                     "The background service is ready for dictation.")
        case "starting":
            let now = Date().timeIntervalSince1970
            let stalled = speechModelNetworkProgressIsStalled(
                phase: state.modelDownloadPhase,
                progressUpdatedAt: state.modelDownloadProgressUpdatedAt,
                now: now
            )
            if state.modelDownloadPhase == "checking" {
                return t(
                    "Сначала ищу модель на этом Mac. Если локальные файлы целы, ничего скачиваться не будет.",
                    "Looking for the model on this Mac first. Nothing will download when the local files are intact."
                )
            } else if state.modelDownloadPhase == "listing" {
                let title = t(
                    "Проверяю наличие и целостность файлов модели…",
                    "Checking model file availability and integrity…"
                )
                if stalled {
                    return "\(title)\n\(localizedModelDownloadNetworkHint(stalled: true))"
                }
                return title
            } else if state.modelDownloadPhase == "downloading",
                      let downloaded = state.modelDownloadedBytes,
                      let total = state.modelDownloadTotalBytes {
                var parts = [
                    t("Скачано \(localizedModelByteCount(downloaded)) из \(localizedModelByteCount(total))",
                      "Downloaded \(localizedModelByteCount(downloaded)) of \(localizedModelByteCount(total))")
                ]
                if stalled {
                    parts.append(t("0 КБ/с", "0 KB/s"))
                } else if let speed = state.modelDownloadBytesPerSecond, speed > 0 {
                    parts.append(localizedModelDownloadSpeed(speed))
                } else {
                    parts.append(t("измеряю скорость…", "measuring speed…"))
                }
                if !stalled,
                   let remaining = state.modelDownloadEstimatedSecondsRemaining,
                   remaining.isFinite,
                   remaining >= 0 {
                    parts.append(t("осталось ≈ \(localizedModelDuration(remaining))",
                                   "≈ \(localizedModelDuration(remaining)) left"))
                }
                let summary = parts.joined(separator: " · ")
                let slow = (state.modelDownloadBytesPerSecond ?? .infinity) < 1_000_000
                if stalled || slow {
                    return "\(summary)\n\(localizedModelDownloadNetworkHint(stalled: stalled))"
                }
                return summary
            } else if state.modelDownloadPhase == "preparing"
                        || state.detail.hasPrefix("Preparing speech model") {
                let elapsed = state.modelDownloadProgressUpdatedAt
                    .map { max(0, Int((now - $0).rounded(.down))) }
                let elapsedText = elapsed.map {
                    t(" \($0) с", " \($0)s")
                } ?? ""
                return t(
                    "Файлы уже на Mac — это не скачивание. Подготавливаю модель для Neural Engine…\(elapsedText)\nОбычно 20–45 секунд. Не перезапускайте службу: ожидание начнётся заново.",
                    "The files are already on this Mac; this is not a download. Preparing the model for Neural Engine…\(elapsedText)\nUsually 20–45 seconds. Do not restart the service or the wait starts over."
                )
            } else if state.modelDownloadPhase == "recovering" {
                return t("Модель готова. Сохраняю незавершённую диктовку в историю…",
                         "The model is ready. Recovering an interrupted dictation into history…")
            } else if state.modelDownloadPhase == "audio" {
                return t("Модель готова. Подключаю микрофон и глобальные сочетания…",
                         "The model is ready. Starting the microphone and global shortcuts…")
            } else if state.modelDownloadPhase == "finishing" {
                return t("Все компоненты готовы. Завершаю запуск…",
                         "All components are ready. Finishing startup…")
            } else if state.detail.hasPrefix("Loading cached speech model") {
                return t("Модель уже на Mac. Загружаю её с диска — ничего не скачивается.",
                         "The model is already on this Mac. Loading it from disk; nothing is downloading.")
            } else if state.detail.hasPrefix("Loading speech model") {
                return t("Загружаю языковую модель…", "Loading speech model…")
            }
            return t("Запускаю службу диктовки…", "Starting dictation service…")
        case "needs_permissions": return t("Выдайте недостающие разрешения ниже.", "Grant the missing permissions below.")
        case "stopped": return t("Фоновая служба остановлена.", "The background service is stopped.")
        case "error": return t("Служба сообщила об ошибке: \(state.detail)", "Service error: \(state.detail)")
        default: return state.detail
        }
    }

    private func localizedModelByteCount(_ bytes: Int64) -> String {
        let value: Double
        let unit: String
        if bytes >= 1_000_000_000 {
            value = Double(bytes) / 1_000_000_000
            unit = t("ГБ", "GB")
        } else if bytes >= 1_000_000 {
            value = Double(bytes) / 1_000_000
            unit = t("МБ", "MB")
        } else {
            value = Double(bytes) / 1_000
            unit = t("КБ", "KB")
        }
        let digits = value < 10 ? 1 : 0
        return "\(localizedModelDecimal(value, digits: digits)) \(unit)"
    }

    private func localizedModelDownloadSpeed(_ bytesPerSecond: Double) -> String {
        let value: Double
        let unit: String
        if bytesPerSecond >= 1_000_000 {
            value = bytesPerSecond / 1_000_000
            unit = t("МБ/с", "MB/s")
        } else {
            value = bytesPerSecond / 1_000
            unit = t("КБ/с", "KB/s")
        }
        let digits = value < 10 ? 1 : 0
        return "\(localizedModelDecimal(value, digits: digits)) \(unit)"
    }

    private func localizedModelDuration(_ seconds: Double) -> String {
        let rounded = max(1, Int(seconds.rounded()))
        if rounded < 60 {
            return t("\(rounded) с", "\(rounded)s")
        }
        let minutes = rounded / 60
        let remainder = rounded % 60
        if remainder == 0 {
            return t("\(minutes) мин", "\(minutes)m")
        }
        return t("\(minutes) мин \(remainder) с", "\(minutes)m \(remainder)s")
    }

    private func localizedModelDecimal(_ value: Double, digits: Int) -> String {
        let result = String(format: "%.\(digits)f", value)
        return language == .russian ? result.replacingOccurrences(of: ".", with: ",") : result
    }

    private func localizedModelDownloadNetworkHint(stalled: Bool) -> String {
        if stalled {
            return t("Прогресс остановился. Включите или выключите VPN, попробуйте другой VPN либо сеть.",
                     "Progress has stopped. Toggle VPN, try another VPN, or switch networks.")
        }
        return t("Медленно? Включите или выключите VPN, попробуйте другой VPN либо сеть.",
                 "Slow? Toggle VPN, try another VPN, or switch networks.")
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
                    case .restarting:
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
        guard AgentRuntimeStateStore.read()?.status != "starting" else {
            refresh(force: true)
            return
        }
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
            refreshSettingsWindow()
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        settingsDraft = ControlPanelSettingsDraft(settings: settings)
        let visibleFrame = (window?.screen ?? NSScreen.main)?.visibleFrame
        let contentHeight = settingsWindowContentHeight(
            visibleScreenHeight: visibleFrame?.height
        )

        let settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: contentHeight),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        settingsWindow.title = t("Настройки SuperDictate", "SuperDictate Settings")
        settingsWindow.contentMinSize = NSSize(width: 680, height: contentHeight)
        settingsWindow.contentMaxSize = NSSize(width: 680, height: contentHeight)
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.delegate = self
        settingsWindow.contentView = makeSettingsContentView()
        if let mainWindow = window, let visibleFrame {
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
        DistributedNotificationCenter.default().postNotificationName(
            SETTINGS_CHANGED_NOTIFICATION,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        lastRenderFingerprint = ""
        refresh(force: true)
        refreshSettingsWindow()
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

    @objc private func toggleRemoveFinalPeriod(_ sender: NSSwitch) {
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        draft.removeFinalPeriod = sender.state == .on
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

    @objc private func selectEnterDelay(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let ms = Int(raw) else { return }
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        draft.enterDelayMilliseconds = ms
        settingsDraft = draft
        refreshSettingsWindow()
    }

    @objc private func selectInputDeviceDraft(_ sender: NSPopUpButton) {
        guard let preference = sender.selectedItem?.representedObject as? String else { return }
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        draft.inputDevicePreference = preference
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
        pendingAIKey = ""
        refreshSettingsWindow(captureFields: false)
    }

    @objc private func toggleAICleanupDraft(_ sender: NSSwitch) {
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        draft.aiCleanupEnabled = sender.state == .on
        settingsDraft = draft
        refreshSettingsWindow()
    }

    @objc private func aiCleanupBaseURLChanged(_ sender: NSTextField) {
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        draft.aiCleanupBaseURL = sender.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        settingsDraft = draft
        refreshSettingsWindow()
    }

    @objc private func aiCleanupModelChanged(_ sender: NSTextField) {
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        draft.aiCleanupModel = sender.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        settingsDraft = draft
        refreshSettingsWindow()
    }

    @objc private func saveAIKeyClicked(_ sender: NSButton) {
        captureAISettingsFields()
        let key = pendingAIKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try AIKeyStore.write(key)
            pendingAIKey = ""
            refreshSettingsWindow(captureFields: false)
        } catch {
            showError(
                title: t("Не удалось сохранить ключ", "Couldn’t Save Key"),
                detail: error.localizedDescription
            )
        }
    }

    @objc private func removeAIKeyClicked(_ sender: NSButton) {
        captureAISettingsFields()
        do {
            try AIKeyStore.delete()
            pendingAIKey = ""
            // Without a key every dictation would fail with noAPIKey — turn the feature off.
            settings.aiCleanupEnabled = false
            if var draft = settingsDraft {
                draft.aiCleanupEnabled = false
                settingsDraft = draft
            }
            DistributedNotificationCenter.default().postNotificationName(
                SETTINGS_CHANGED_NOTIFICATION,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
            refreshSettingsWindow(captureFields: false)
        } catch {
            showError(
                title: t("Не удалось удалить ключ", "Couldn’t Remove Key"),
                detail: error.localizedDescription
            )
        }
    }

    @objc private func testAICleanupConnectionClicked(_ sender: NSButton) {
        captureAISettingsFields()
        let draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        guard let key = AIKeyStore.read() else {
            showError(
                title: t("Нет API-ключа", "No API Key"),
                detail: t("Сначала сохраните API-ключ.", "Save an API key first.")
            )
            return
        }
        sender.isEnabled = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await AICleanupService.probeModels(baseURL: draft.aiCleanupBaseURL,
                                                            apiKey: key,
                                                            model: draft.aiCleanupModel)
            switch result {
            case .success:
                let alert = NSAlert()
                alert.alertStyle = .informational
                alert.messageText = t("Подключение успешно", "Connection OK")
                alert.informativeText = t("Сервер доступен, и выбранная модель найдена.",
                                          "The endpoint is reachable and the configured model is available.")
                alert.addButton(withTitle: t("ОК", "OK"))
                alert.runModal()
            case .failure(let error):
                self.showError(
                    title: t("Проверка не удалась", "Connection Failed"),
                    detail: self.aiCleanupProbeErrorMessage(error)
                )
            }
            self.refreshSettingsWindow()
        }
    }

    private func aiCleanupProbeErrorMessage(_ error: AICleanupError) -> String {
        switch error {
        case .noAPIKey:
            return t("API-ключ не сохранён.", "No API key is stored.")
        case .network(let underlying):
            return t("Ошибка сети: \(underlying.localizedDescription)",
                     "Network error: \(underlying.localizedDescription)")
        case .httpStatus(let code):
            return t("Сервер ответил с ошибкой HTTP \(code).",
                     "The endpoint returned HTTP \(code).")
        case .unexpectedResponse:
            return t("Сервер вернул неожиданный ответ.",
                     "The endpoint returned an unexpected response.")
        case .emptyResult:
            return t("Сервер вернул пустой ответ.", "The endpoint returned an empty response.")
        case .modelUnavailable(let model):
            return t("Модель \(model) недоступна для этого ключа.",
                     "Model \(model) is unavailable for this API key.")
        }
    }

    @objc private func openAIProviderDocsClicked(_ sender: NSButton) {
        if let url = URL(string: "https://console.groq.com/keys") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func saveSettingsClicked(_ sender: NSButton) {
        captureAISettingsFields()
        guard let draft = settingsDraft,
              settingsValidationMessage(draft) == nil else { return }
        let agentState = AgentRuntimeStateStore.read()
        guard agentState?.isRecording != true,
              agentState?.isTranscribing != true else {
            showError(
                title: t("Диктовка ещё не завершена", "Dictation Is Still Active"),
                detail: t("Завершите запись или распознавание, затем сохраните настройки.",
                          "Finish recording or transcription, then save the settings.")
            )
            return
        }
        settings.setConfiguredHotkey(draft.dictationHotkey)
        settings.setConfiguredEnterHotkey(draft.alternateCompletionHotkey)
        settings.setConfiguredHistoryHotkey(draft.historyHotkey)
        settings.primaryCompletionBehavior = draft.primaryCompletionBehavior
        settings.alternateCompletionEnabled = draft.alternateCompletionEnabled
        settings.enterDelayMilliseconds = draft.enterDelayMilliseconds
        settings.aiCleanupEnabled = draft.aiCleanupEnabled
        settings.aiCleanupBaseURL = draft.aiCleanupBaseURL
        settings.aiCleanupModel = draft.aiCleanupModel
        settings.inputDevice = draft.inputDevicePreference
        settings.removeFinalPeriod = draft.removeFinalPeriod
        settings.recordingHUDRecordingColor = draft.recordingColor
        settings.recordingHUDTranscribingColor = draft.transcribingColor
        settings.recordingHUDBackgroundStyle = draft.backgroundStyle
        settings.recordingHUDSize = draft.hudSize
        settings.agentEnabled = true
        _ = settings.refreshFromDisk()
        settingsDraft = ControlPanelSettingsDraft(settings: settings)
        DistributedNotificationCenter.default().postNotificationName(
            SETTINGS_CHANGED_NOTIFICATION,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        lastRenderFingerprint = ""
        refresh(force: true)
    }

    private func captureAISettingsFields() {
        guard var draft = settingsDraft else { return }
        if let aiBaseURLField {
            draft.aiCleanupBaseURL = aiBaseURLField.stringValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let aiModelField {
            draft.aiCleanupModel = aiModelField.stringValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let aiKeyField {
            pendingAIKey = aiKeyField.stringValue
        }
        settingsDraft = draft
    }

    private func refreshSettingsWindow(captureFields: Bool = true) {
        guard let settingsWindow else { return }
        let previousOffset = settingsScrollView?.contentView.bounds.origin.y ?? 0
        if captureFields {
            captureAISettingsFields()
        }
        settingsWindow.contentView = makeSettingsContentView()
        settingsWindow.contentView?.layoutSubtreeIfNeeded()
        guard previousOffset > 0,
              let scroll = settingsScrollView,
              let document = scroll.documentView else { return }
        let maximumOffset = max(0, document.bounds.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(previousOffset, maximumOffset)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    @objc private func resetPermissionsClicked(_ sender: NSButton) {
        guard serviceOperation == nil else { return }
        let runtime = AgentRuntimeStateStore.read()
        guard runtime?.isRecording != true,
              runtime?.isTranscribing != true else {
            showError(
                title: t("Сначала завершите диктовку", "Finish Dictation First"),
                detail: t("Разрешения нельзя сбрасывать во время записи или транскрибации.",
                          "Permissions cannot be reset while recording or transcribing.")
            )
            return
        }

        let confirmation = NSAlert()
        confirmation.alertStyle = .critical
        confirmation.messageText = t("Сбросить разрешения SuperDictate?",
                                     "Reset SuperDictate Permissions?")
        confirmation.informativeText = t(
            "Микрофон, Универсальный доступ и Мониторинг ввода будут отозваны. Используйте это только для восстановления сломанных разрешений; затем их нужно выдать заново.",
            "Microphone, Accessibility, and Input Monitoring access will be revoked. Use this only to recover stuck permissions; all three must then be granted again."
        )
        confirmation.addButton(withTitle: t("Отмена", "Cancel"))
        confirmation.addButton(withTitle: t("Сбросить", "Reset"))
        guard confirmation.runModal() == .alertSecondButtonReturn else { return }

        sender.isEnabled = false
        Task { @MainActor [weak self, weak sender] in
            let failures = await Task.detached(priority: .userInitiated) {
                Permissions.resetAll()
            }.value
            guard let self else { return }
            sender?.isEnabled = true
            self.permissionClickCount = [:]
            self.refresh(force: true)

            if failures.isEmpty {
                let result = NSAlert()
                result.alertStyle = .informational
                result.messageText = self.t("Разрешения сброшены", "Permissions Reset")
                result.informativeText = self.t(
                    "Вернитесь в панель управления и выдайте три разрешения заново.",
                    "Return to the control panel and grant all three permissions again."
                )
                result.addButton(withTitle: self.t("ОК", "OK"))
                result.runModal()
            } else {
                self.showError(
                    title: self.t("Сброс выполнен не полностью", "Reset Was Incomplete"),
                    detail: self.t("Не удалось сбросить: \(failures.joined(separator: ", ")).",
                                   "Could not reset: \(failures.joined(separator: ", ")).")
                )
            }
        }
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
            Permissions.openSettings(for: permission)
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

