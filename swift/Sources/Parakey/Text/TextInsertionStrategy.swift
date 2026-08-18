// Parakey — push-to-talk dictation for macOS Apple Silicon.
// Text / TextInsertionStrategy.swift

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

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

enum FocusedInsertionTargetLocator {
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

struct KeyboardEventStep: Equatable {
    let virtualKey: CGKeyCode
    let keyDown: Bool
    let flags: CGEventFlags
}

func clipboardPasteKeyboardEventSteps(commandKey: CGKeyCode,
                                      pasteKey: CGKeyCode) -> [KeyboardEventStep] {
    [
        KeyboardEventStep(virtualKey: commandKey, keyDown: true, flags: .maskCommand),
        KeyboardEventStep(virtualKey: pasteKey, keyDown: true, flags: .maskCommand),
        KeyboardEventStep(virtualKey: pasteKey, keyDown: false, flags: .maskCommand),
        KeyboardEventStep(virtualKey: commandKey, keyDown: false, flags: []),
    ]
}

func postKeyboardEventSteps(_ steps: [KeyboardEventStep]) -> Bool {
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
enum KeyboardShortcutPoster {
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
enum ClipboardPasteInserter {
    static let virtualKeyCommand: CGKeyCode = 0x37  // left Command
    static let virtualKeyV: CGKeyCode = 0x09  // ANSI 'v'
    private static let restoreDelayAfterRead: TimeInterval = 0.12
    private static let restoreTimeout: TimeInterval = 10
    private static var pendingTransaction: ClipboardPasteTransaction?

    static func write(_ text: String, to pb: NSPasteboard) -> Bool {
        pb.clearContents()
        return pb.setString(text, forType: .string)
    }

    static func insert(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pendingTransaction?.restoreNowIfCurrent(reason: "superseded by another dictation")
        let previous = PasteboardSnapshot.capture(from: pasteboard)
        let transaction = ClipboardPasteTransaction(
            text: text,
            pasteboard: pasteboard,
            previousSnapshot: previous,
            restoreDelay: restoreDelayAfterRead,
            restoreTimeout: restoreTimeout
        )
        transaction.onFinished = { [weak transaction] in
            guard let transaction, pendingTransaction === transaction else { return }
            pendingTransaction = nil
        }
        pendingTransaction = transaction
        guard transaction.install() else {
            pendingTransaction = nil
            log("pasteboard write failed")
            return false
        }

        let steps = clipboardPasteKeyboardEventSteps(commandKey: virtualKeyCommand,
                                                     pasteKey: virtualKeyV)
        guard post(steps) else {
            log("paste event creation failed")
            transaction.restoreNowIfCurrent(reason: "paste event creation failed")
            return false
        }
        return true
    }

    private static func post(_ steps: [KeyboardEventStep]) -> Bool {
        postKeyboardEventSteps(steps)
    }
}

@MainActor
struct PasteboardSnapshot {
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
final class ClipboardPasteTransaction: NSObject, NSPasteboardItemDataProvider {
    nonisolated let text: String
    let pasteboard: NSPasteboard
    let previousSnapshot: PasteboardSnapshot
    let restoreDelay: TimeInterval
    let restoreTimeout: TimeInterval
    var onFinished: (() -> Void)?

    private let startedAt = ProcessInfo.processInfo.systemUptime
    private var transientChangeCount: Int?
    private var restoreWorkItem: DispatchWorkItem?
    private var didProvideText = false
    private var isFinished = false

    init(text: String,
         pasteboard: NSPasteboard,
         previousSnapshot: PasteboardSnapshot,
         restoreDelay: TimeInterval,
         restoreTimeout: TimeInterval,
         onFinished: (() -> Void)? = nil) {
        self.text = text
        self.pasteboard = pasteboard
        self.previousSnapshot = previousSnapshot
        self.restoreDelay = restoreDelay
        self.restoreTimeout = restoreTimeout
        self.onFinished = onFinished
    }

    func install() -> Bool {
        let item = NSPasteboardItem()
        guard item.setDataProvider(self, forTypes: [.string]) else {
            finish()
            return false
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            previousSnapshot.restore(to: pasteboard)
            finish()
            return false
        }
        transientChangeCount = pasteboard.changeCount
        scheduleRestore(after: restoreTimeout, reason: "target did not request dictation text")
        return true
    }

    nonisolated func pasteboard(_ pasteboard: NSPasteboard?,
                                item: NSPasteboardItem,
                                provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .string else { return }
        item.setString(text, forType: type)
        Task { @MainActor [weak self] in
            self?.textWasProvided()
        }
    }

    private func textWasProvided() {
        guard !isFinished, !didProvideText else { return }
        didProvideText = true
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        log("pasteboard target requested dictation text after \(millisecondsLabel(elapsed))")
        scheduleRestore(after: restoreDelay, reason: "target consumed dictation text")
    }

    func restoreNowIfCurrent(reason: String) {
        restore(reason: reason)
    }

    private func scheduleRestore(after delay: TimeInterval, reason: String) {
        restoreWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.restore(reason: reason)
        }
        restoreWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: work)
    }

    private func restore(reason: String) {
        guard !isFinished else { return }
        restoreWorkItem?.cancel()
        restoreWorkItem = nil
        if let transientChangeCount,
           pasteboard.changeCount == transientChangeCount {
            previousSnapshot.restore(to: pasteboard)
            log("pasteboard restored after \(reason)")
        } else {
            log("pasteboard restore skipped after \(reason): clipboard changed externally")
        }
        finish()
    }

    private func finish() {
        guard !isFinished else { return }
        isFinished = true
        restoreWorkItem?.cancel()
        restoreWorkItem = nil
        let completion = onFinished
        onFinished = nil
        completion?()
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
