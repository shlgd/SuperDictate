import Foundation
import whisper_cpp

enum WhisperEngineError: LocalizedError {
    case modelLoadFailed(path: String)
    case transcriptionFailed(code: Int32)

    var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let path):
            return "Failed to load whisper.cpp model at \(path)"
        case .transcriptionFailed(let code):
            return "whisper_full failed with code \(code)"
        }
    }
}

struct WhisperTranscription: Sendable {
    let text: String
    let encodeSeconds: Double
    let totalSeconds: Double
}

/// Owns one loaded whisper.cpp context. Not re-entrant — `TranscriptionWorker`
/// (main.swift) is the single caller and already serializes transcribe calls;
/// see the comment above that actor for why re-entrancy would corrupt state.
actor WhisperEngine {
    private let context: OpaquePointer

    init(modelPath: String) throws {
        var params = whisper_context_default_params()
        params.use_gpu = false
        guard let ctx = whisper_init_from_file_with_params(modelPath, params) else {
            throw WhisperEngineError.modelLoadFailed(path: modelPath)
        }
        context = ctx
    }

    func transcribe(samples: [Float], languageCode: String?) throws -> WhisperTranscription {
        let requestedAt = ProcessInfo.processInfo.systemUptime
        var params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
        params.print_progress = false
        params.print_realtime = false
        params.print_special = false
        params.no_timestamps = true
        params.n_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount))

        let languageCString: UnsafeMutablePointer<CChar>? = languageCode.map { strdup($0) }
        defer { languageCString.map { free($0) } }
        if let languageCString {
            params.language = UnsafePointer(languageCString)
        }

        let encodeStartedAt = ProcessInfo.processInfo.systemUptime
        let result = samples.withUnsafeBufferPointer { buffer in
            whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
        }
        let encodeCompletedAt = ProcessInfo.processInfo.systemUptime
        guard result == 0 else {
            throw WhisperEngineError.transcriptionFailed(code: result)
        }

        var text = ""
        let segmentCount = whisper_full_n_segments(context)
        for i in 0..<segmentCount {
            if let segmentText = whisper_full_get_segment_text(context, i) {
                text += String(cString: segmentText)
            }
        }

        return WhisperTranscription(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            encodeSeconds: encodeCompletedAt - encodeStartedAt,
            totalSeconds: ProcessInfo.processInfo.systemUptime - requestedAt
        )
    }

    deinit {
        whisper_free(context)
    }
}
