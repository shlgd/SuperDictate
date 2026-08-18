// Parakey — push-to-talk dictation for macOS Apple Silicon.
// Core / HotkeyListener.swift

import Foundation
import CoreGraphics
import AppKit

// MARK: - Hotkey listener
//
// Global event tap on the keyDown / keyUp / flagsChanged stream.
// Right Option is a modifier so it doesn't fire keyDown — we watch
// flagsChanged and diff the .option flag.

struct HotkeyEventSnapshot: Sendable {
    let typeRawValue: UInt32
    let keycode: CGKeyCode
    let flagsRawValue: UInt64
    let isAutoRepeat: Bool

    var flags: CGEventFlags {
        CGEventFlags(rawValue: flagsRawValue)
    }
}

enum HotkeyRecordingDecision: Equatable {
    case accept(HotkeyChoice)
    case reject(String)
    case ignore
}

enum HotkeyPreferenceUpdateResult: Equatable {
    case saved(HotkeyChoice)
    case rejected(String)
    case rolledBack(previous: HotkeyChoice, message: String)
}

func hotkeyPreferenceUpdateResult(
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

enum HotkeyRecorderRestartAction: Equatable {
    case none
    case restoredListener
    case recordFailure
}

func hotkeyRecorderRestartAction(
    shouldRestoreHotkeyTap: Bool,
    isTerminating: Bool,
    restartSucceeded: Bool
) -> HotkeyRecorderRestartAction {
    guard shouldRestoreHotkeyTap, !isTerminating else { return .none }
    return restartSucceeded ? .restoredListener : .recordFailure
}

func hotkeyRecordingDecision(for event: HotkeyEventSnapshot) -> HotkeyRecordingDecision {
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

enum HotkeyRecorderCaptureResult: Equatable {
    case candidate(HotkeyChoice)
    case reject(String)
    case cancel
    case ignore
}

struct HotkeyRecorderCaptureState {
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
final class HotkeyRecorderController: NSObject, NSWindowDelegate {
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

func hotkeyFlags(from modifiers: NSEvent.ModifierFlags) -> CGEventFlags {
    var result: CGEventFlags = []
    if modifiers.contains(.control) { result.insert(.maskControl) }
    if modifiers.contains(.option) { result.insert(.maskAlternate) }
    if modifiers.contains(.shift) { result.insert(.maskShift) }
    if modifiers.contains(.command) { result.insert(.maskCommand) }
    if modifiers.contains(.function) { result.insert(.maskSecondaryFn) }
    return result
}

enum HotkeyTransitionAction: Equatable, Sendable {
    case press
    case release
    case releaseAlternate
    case cancel
    case showHistory
    /// Toggle mode: the press was suppressed because the app is busy
    /// (transcription in flight). Does NOT flip toggle state. Lets the
    /// app play feedback so the user knows the press was received.
    case rejectedBusyPress
}

struct HotkeyTransitionResult: Equatable, Sendable {
    let suppress: Bool
    let actions: [HotkeyTransitionAction]

    static let pass = HotkeyTransitionResult(suppress: false, actions: [])
    static let suppressOnly = HotkeyTransitionResult(suppress: true, actions: [])
}

enum HotkeyShortcutEdge: Equatable {
    case press
    case release
    case suppress
    case pass
}

struct HotkeyShortcutResult: Equatable {
    let edge: HotkeyShortcutEdge
    let suppress: Bool

    static let pass = HotkeyShortcutResult(edge: .pass, suppress: false)
    static let suppressOnly = HotkeyShortcutResult(edge: .suppress, suppress: true)

    static func press(suppress: Bool) -> HotkeyShortcutResult {
        HotkeyShortcutResult(edge: .press, suppress: suppress)
    }

    static func release(suppress: Bool) -> HotkeyShortcutResult {
        HotkeyShortcutResult(edge: .release, suppress: suppress)
    }
}

private struct HotkeyShortcutState {
    private var primaryModifierDown = false
    private var shortcutDown = false

    var isEngaged: Bool { primaryModifierDown || shortcutDown }

    mutating func reset() {
        primaryModifierDown = false
        shortcutDown = false
    }

    mutating func consume(_ event: HotkeyEventSnapshot,
                          shortcut: HotkeyChoice) -> HotkeyShortcutResult {
        if !shortcut.isModifier {
            guard event.keycode == shortcut.keycode else { return .pass }
            if event.typeRawValue == CGEventType.keyDown.rawValue {
                guard !event.isAutoRepeat else { return shortcutDown ? .suppressOnly : .pass }
                let modifiers = event.flags.intersection(HOTKEY_SHORTCUT_MODIFIER_MASK)
                guard modifiers == shortcut.requiredModifiers else { return .pass }
                shortcutDown = true
                return .press(suppress: true)
            }
            if event.typeRawValue == CGEventType.keyUp.rawValue, shortcutDown {
                shortcutDown = false
                return .release(suppress: true)
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
            // Modifier-only chords are observed rather than consumed so
            // incomplete prefixes such as Shift keep working in the frontmost
            // app. A single-modifier shortcut remains fully intercepted.
            return .press(suppress: shortcut.requiredModifiers.isEmpty)
        }
        if shortcutDown, !isNowDown {
            shortcutDown = false
            return .release(suppress: shortcut.requiredModifiers.isEmpty)
        }
        if shortcutDown, shortcut.requiredModifiers.isEmpty {
            return .suppressOnly
        }
        return .pass
    }
}

struct HotkeyTransitionState {
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

        let shortcutResult = standardShortcutState.consume(event, shortcut: hotkey)

        switch triggerMode {
        case .hold:
            var actions: [HotkeyTransitionAction] = []
            if shortcutResult.edge == .press { actions.append(.press) }
            if shortcutResult.edge == .release { actions.append(.release) }
            guard shortcutResult.edge != .pass || shortcutResult.suppress else { return .pass }
            return HotkeyTransitionResult(suppress: shortcutResult.suppress, actions: actions)
        case .toggle:
            // Toggle mode: every press flips between "start recording"
            // and "stop recording". Releases are no-ops.
            guard shortcutResult.edge != .pass else {
                return shortcutResult.suppress ? .suppressOnly : .pass
            }
            guard shortcutResult.edge == .press else {
                return shortcutResult.suppress ? .suppressOnly : .pass
            }
            if toggleActive {
                toggleActive = false
                return HotkeyTransitionResult(suppress: shortcutResult.suppress, actions: [.release])
            }
            // A press the app will reject (model loading, a
            // transcription in flight, terminating) must not flip the
            // toggle. Otherwise the rejected press strands
            // toggleActive at true, the NEXT press emits a .release
            // the app discards, and only the third press records —
            // with zero feedback in between. Same gate-callback
            // pattern Escape uses via isRecording.
            // .rejectedBusyPress lets the app play feedback without
            // flipping toggle state — handlePress() is never reached
            // in toggle mode because the state machine gates it here.
            guard canStartRecording else {
                return HotkeyTransitionResult(suppress: shortcutResult.suppress,
                                              actions: [.rejectedBusyPress])
            }
            toggleActive = true
            return HotkeyTransitionResult(suppress: shortcutResult.suppress, actions: [.press])
        }
    }

    private mutating func transitionHistoryShortcut(
        for event: HotkeyEventSnapshot,
        isRecording: Bool,
        historyHotkey: HotkeyChoice
    ) -> HotkeyTransitionResult? {
        let shortcutResult = historyShortcutState.consume(event, shortcut: historyHotkey)
        switch shortcutResult.edge {
        case .press:
            standardShortcutState.reset()
            enterShortcutState.reset()
            if !isRecording {
                toggleActive = false
            }
            return HotkeyTransitionResult(suppress: shortcutResult.suppress,
                                          actions: [.showHistory])
        case .release, .suppress:
            return shortcutResult.suppress ? .suppressOnly : nil
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
        let shortcutResult = enterShortcutState.consume(event, shortcut: enterHotkey)
        switch shortcutResult.edge {
        case .press where isRecording:
            standardShortcutState.reset()
            toggleActive = false
            return HotkeyTransitionResult(suppress: shortcutResult.suppress,
                                          actions: [.releaseAlternate])
        case .press, .release, .suppress:
            return shortcutResult.suppress ? .suppressOnly : nil
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
    /// Toggle mode: a press arrived while the app is busy (transcription
    /// in flight). The toggle did NOT flip. Play feedback so the user
    /// knows the press was received but rejected.
    var onRejectedBusyPress: (() -> Void)?
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
        guard choice != hotkey else { return }
        self.hotkey = choice
        self.transitionState.resetAll()
        log("HotkeyListener: hotkey changed → \(choice.name)")
    }

    func setEnterHotkey(_ choice: HotkeyChoice) {
        guard choice != enterHotkey else { return }
        enterHotkey = choice
        transitionState.resetAll()
        log("HotkeyListener: alternate completion hotkey changed → \(choice.name)")
    }

    func setAlternateCompletionEnabled(_ enabled: Bool) {
        guard enabled != alternateCompletionEnabled else { return }
        alternateCompletionEnabled = enabled
        transitionState.resetAll()
        log("HotkeyListener: alternate completion → \(enabled ? "enabled" : "disabled")")
    }

    func setHistoryHotkey(_ choice: HotkeyChoice) {
        guard choice != historyHotkey else { return }
        historyHotkey = choice
        transitionState.resetAll()
        log("HotkeyListener: history hotkey changed → \(choice.name)")
    }

    func setTriggerMode(_ mode: TriggerMode) {
        guard mode != triggerMode else { return }
        // Reset toggle state when switching modes so we don't get
        // stuck in mid-toggle from a previous session.
        transitionState.resetToggleState()
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
            case .rejectedBusyPress: onRejectedBusyPress?()
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
