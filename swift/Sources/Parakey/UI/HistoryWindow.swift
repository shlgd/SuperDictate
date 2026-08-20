// Parakey — push-to-talk dictation for macOS Apple Silicon.
// UI / HistoryWindow.swift

import AppKit
import Foundation

@MainActor
final class HistoryOverlayPanel: NSPanel {
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
final class HistoryItemLabel: NSTextField {
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
final class HistoryDeleteButton: NSButton {
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
final class HistoryTranscriptItemView: NSControl {
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
final class HistoryToolbarButton: NSControl {
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
