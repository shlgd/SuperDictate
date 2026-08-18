// Parakey — push-to-talk dictation for macOS Apple Silicon.
// UI / RecordingHUDView.swift

import AppKit
import Foundation
import QuartzCore

enum RecordingHUDMode {
    case recording
    case transcribing
    case error
}

final class RecordingHUDView: NSView {
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

@MainActor
func exportRecordingHUDAnimationFrames(to directory: URL) throws {
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
