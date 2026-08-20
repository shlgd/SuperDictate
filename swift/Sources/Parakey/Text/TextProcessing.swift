// Parakey — push-to-talk dictation for macOS Apple Silicon.
// Text / TextProcessing.swift

import Foundation

enum SpeechModelTextRepair {
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
                .replacingOccurrences(of: #"\s+([.,!?;:])"#, with: "$1", options: .regularExpression)
                .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
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

enum FillerWordRemover {
    private enum CapitalizationRepairTarget: Hashable {
        case start
        case afterSentenceTerminator(Int)
    }

    private static let fillerPatterns = ["um+", "uh+", "ah+", "er", "erm", "hm+"]

    static func apply(to text: String) -> (text: String, removedCount: Int) {
        guard !text.isEmpty else { return (text, 0) }

        let alternation = fillerPatterns.joined(separator: "|")
        let pattern = #"(?i)(?<![\p{L}\p{N}'\-])("# + alternation + #")(?![\p{L}\p{N}'\-])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return (text, 0)
        }

        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: fullRange)
        guard !matches.isEmpty else { return (text, 0) }

        let capitalizationRepairTargets = capitalizationRepairTargets(for: matches, in: text)

        let mutable = NSMutableString(string: text)
        for match in matches.reversed() {
            mutable.replaceCharacters(in: match.range, with: "")
        }
        var result = mutable as String

        result = result.replacingOccurrences(of: #"\s*,(?:\s*,)+"#, with: ",", options: .regularExpression)
        result = result.replacingOccurrences(of: #"([.!?])\s+[,.;:!?]+\s*"#, with: "$1 ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s+([.,!?;:])"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #",+([.!?;:])"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"^[\s,.;:!?]+"#, with: "", options: .regularExpression)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        result = restoringCapitalization(in: result, targets: capitalizationRepairTargets)

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
            return .afterSentenceTerminator(sentenceTerminatorOrdinal(at: previous, in: text))
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

func removeTrailingPeriod(from text: String) -> String {
    guard text.hasSuffix(".") else { return text }
    // Only strip single trailing period, keep ellipsis like "..."
    if text.hasSuffix("...") || text.hasSuffix("…") { return text }
    return String(text.dropLast())
}

struct DictationTextProcessingResult: Equatable {
    let text: String
    let appliedCorrectionCount: Int
    let removedFillerWordCount: Int
}

func removingFinalPeriod(from text: String) -> String {
    removeTrailingPeriod(from: text)
}

func finalizedDictationText(_ text: String, removeFinalPeriod: Bool) -> String {
    removeFinalPeriod ? removingFinalPeriod(from: text) : text
}

func processedDictationText(rawTranscript: String,
                            corrections: [TranscriptCorrection],
                            removeFillerWords: Bool,
                            removeFinalPeriod: Bool = false,
                            language: DictationLanguage = .auto) -> DictationTextProcessingResult {
    let trimmed = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    let repaired = SpeechModelTextRepair.apply(to: trimmed, language: language)
    let corrected = TranscriptCorrector.apply(to: repaired, corrections: corrections)

    let textAfterFillers: String
    let removedFillerWordCount: Int
    if removeFillerWords {
        let stripped = FillerWordRemover.apply(to: corrected.text)
        textAfterFillers = stripped.text
        removedFillerWordCount = stripped.removedCount
    } else {
        textAfterFillers = corrected.text
        removedFillerWordCount = 0
    }

    let finalText = finalizedDictationText(textAfterFillers,
                                           removeFinalPeriod: removeFinalPeriod)
    return DictationTextProcessingResult(text: finalText,
                                         appliedCorrectionCount: corrected.appliedCount,
                                         removedFillerWordCount: removedFillerWordCount)
}
