// Parakey — push-to-talk dictation for macOS Apple Silicon.
// UI / StatisticsView.swift

import AppKit
import Foundation

func formattedUsageInteger(_ value: Int) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "ru_RU")
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = 0
    return formatter.string(from: NSNumber(value: max(0, value))) ?? String(max(0, value))
}

func formattedUsageDuration(_ seconds: Double) -> String {
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

func formattedUsageSeconds(_ seconds: Double) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "ru_RU")
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2
    return "\(formatter.string(from: NSNumber(value: max(0, seconds))) ?? "0,00") с"
}

func compactUsageInteger(_ value: Int) -> String {
    guard value >= 1_000 else { return String(max(0, value)) }
    let scaled = Double(value) / 1_000
    let digits = scaled >= 10 ? 0 : 1
    return String(format: "%.*fк", digits, scaled).replacingOccurrences(of: ".", with: ",")
}

func russianUsageDateRange(_ snapshot: DictationUsageWeekSnapshot,
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
final class UsageMetricCard: NSView {
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
final class DictationUsageChartView: NSView {
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
final class DictationSpeechTimeChartView: NSView {
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

        var points: [NSPoint] = []
        for (index, value) in values.enumerated() {
            let x = plot.minX + (slotWidth * (CGFloat(index) + 0.5))
            let yRatio = CGFloat(value / maximum)
            let y = plot.maxY - (plot.height * yRatio)
            points.append(NSPoint(x: x, y: y))
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
