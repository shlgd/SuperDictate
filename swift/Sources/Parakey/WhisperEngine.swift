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
    // `OpaquePointer` doesn't conform to `Sendable`, which under Swift 6
    // strict concurrency would otherwise block reading this property from
    // `deinit` (always nonisolated) and from the C interop calls below.
    // Safety is still provided by the actor: `context` is only ever mutated
    // once (in `init`) and every other access is serialized through
    // `WhisperEngine`'s actor isolation — `nonisolated(unsafe)` just tells
    // the compiler what's already true.
    private nonisolated(unsafe) let context: OpaquePointer

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
        let result = Self.runWhisperFull(context: context, params: params, samples: samples)
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

    /// A `static` (hence non-actor-isolated) helper so the `withUnsafeBufferPointer`
    /// closure below isn't treated as capturing actor-isolated state — under Swift 6
    /// strict concurrency, a closure defined inside an actor-isolated instance method
    /// that captures a `whisper_full_params` value is flagged as "sending" a
    /// non-Sendable value across isolation even though the closure is synchronous
    /// and non-escaping. Moving the call into a plain (non-isolated) static function
    /// sidesteps that false positive; `context` stays safe to read here because it
    /// is `nonisolated(unsafe)` and, per the actor's own contract, never mutated
    /// after `init` and never called concurrently (see the doc comment above this
    /// actor and above `TranscriptionWorker` in main.swift).
    private static func runWhisperFull(context: OpaquePointer,
                                       params: whisper_full_params,
                                       samples: [Float]) -> Int32 {
        samples.withUnsafeBufferPointer { buffer in
            whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
        }
    }
}
