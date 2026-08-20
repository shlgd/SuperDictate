// Parakey — push-to-talk dictation for macOS Apple Silicon.
// Audio / AudioCapture.swift
//
// AVAudioEngine tap on the input node, downmix to mono / 16 kHz /
// Float32 if needed, append to a buffer while recording.
//
// Deliberately NOT @MainActor. AVAudioEngine's installTap delivers
// callbacks on an audio worker thread.

import AVFoundation
import AudioToolbox
import Foundation

struct CapturedAudioSegments {
    let segments: [[Float]]
    let sampleCount: Int

    func flattened() -> [Float] {
        guard sampleCount > 0 else { return [] }
        var out: [Float] = []
        out.reserveCapacity(sampleCount)
        for segment in segments {
            out.append(contentsOf: segment)
        }
        return out
    }
}

struct CapturedRecording {
    let samples: [Float]
    let recoveryURL: URL?
    let detachSeconds: TimeInterval
    let journalFlushSeconds: TimeInterval
    let flattenSeconds: TimeInterval
}

enum PendingDictationRecovery {
    private static let directoryName = "PendingDictations"
    private static let fileExtension = "sdaudio"
    private static let magic = Data("SDAR".utf8)

    static func directoryURL() throws -> URL {
        let url = try superDictateApplicationSupportDirectory()
            .appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                              ofItemAtPath: url.path)
        return url
    }

    static func createJournal() throws -> PendingDictationJournal {
        try PendingDictationJournal(url: directoryURL()
            .appendingPathComponent("pending-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension))
    }

    static func pendingURLs() -> [URL] {
        guard let directory = try? directoryURL(),
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.creationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else { return [] }

        return urls
            .filter { $0.pathExtension == fileExtension && $0.lastPathComponent.hasPrefix("pending-") }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return left < right
            }
    }

    static func loadSamples(from url: URL) throws -> [Float] {
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw currentPOSIXError() }
        defer { _ = Darwin.close(fd) }

        try validateSingleLinkRegularFileDescriptor(fd)
        var st = stat()
        guard Darwin.fstat(fd, &st) == 0 else { throw currentPOSIXError() }
        guard st.st_size >= PENDING_DICTATION_HEADER_SIZE,
              st.st_size <= PENDING_DICTATION_MAX_BYTES else {
            throw posixError(EFBIG)
        }

        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.readToEnd() ?? Data()
        guard data.count >= PENDING_DICTATION_HEADER_SIZE,
              data.prefix(4) == magic,
              readUInt32LE(data, offset: 4) == PENDING_DICTATION_FILE_VERSION,
              readUInt32LE(data, offset: 8) == UInt32(SAMPLE_RATE),
              readUInt32LE(data, offset: 12) == UInt32(MemoryLayout<Float>.size) else {
            throw posixError(EINVAL)
        }

        let payload = data.dropFirst(PENDING_DICTATION_HEADER_SIZE)
        let usablePayloadCount = payload.count - (payload.count % MemoryLayout<Float>.size)
        let usablePayload = payload.prefix(usablePayloadCount)
        var samples = [Float](repeating: 0,
                              count: usablePayload.count / MemoryLayout<Float>.size)
        samples.withUnsafeMutableBytes { destination in
            usablePayload.withUnsafeBytes { source in
                destination.copyBytes(from: source)
            }
        }
        return samples
    }

    static func remove(_ url: URL?) {
        guard let url else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch where (error as NSError).code == NSFileNoSuchFileError {
            return
        } catch {
            log("pending dictation cleanup failed: \(error.localizedDescription)")
        }
    }

    static func headerData() -> Data {
        var data = magic
        appendUInt32LE(PENDING_DICTATION_FILE_VERSION, to: &data)
        appendUInt32LE(UInt32(SAMPLE_RATE), to: &data)
        appendUInt32LE(UInt32(MemoryLayout<Float>.size), to: &data)
        return data
    }

    private static func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    private static func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        return data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            return UInt32(bytes[offset])
                | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24)
        }
    }
}

final class PendingDictationJournal: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "SuperDictate.PendingDictationJournal",
                                      qos: .utility)
    private var fileDescriptor: Int32
    private var didLogWriteFailure = false

    init(url: URL) throws {
        self.url = url
        fileDescriptor = -1
        let flags = O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW
        let fd = Darwin.open(url.path, flags, PRIVATE_LOG_FILE_MODE)
        guard fd >= 0 else { throw currentPOSIXError() }
        do {
            try validateSingleLinkRegularFileDescriptor(fd)
            guard Darwin.fchmod(fd, PRIVATE_LOG_FILE_MODE) == 0 else {
                throw currentPOSIXError()
            }
            try writeAllData(PendingDictationRecovery.headerData(), to: fd)
            fileDescriptor = fd
        } catch {
            _ = Darwin.close(fd)
            _ = Darwin.unlink(url.path)
            throw error
        }
    }

    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let data = samples.withUnsafeBytes { Data($0) }
        queue.async { [self] in
            guard fileDescriptor >= 0 else { return }
            do {
                try writeAllData(data, to: fileDescriptor)
            } catch where !didLogWriteFailure {
                didLogWriteFailure = true
                log("pending dictation write failed: \(error.localizedDescription)")
            } catch {}
        }
    }

    func finish() {
        queue.sync { [self] in
            guard fileDescriptor >= 0 else { return }
            if Darwin.fsync(fileDescriptor) != 0, !didLogWriteFailure {
                didLogWriteFailure = true
                log("pending dictation sync failed: \(currentPOSIXError().localizedDescription)")
            }
            _ = Darwin.close(fileDescriptor)
            fileDescriptor = -1
        }
    }
}

struct AudioSampleAccumulator {
    private var segments: [[Float]] = []
    private(set) var sampleCount = 0

    mutating func append(_ segment: [Float]) {
        guard !segment.isEmpty else { return }
        segments.append(segment)
        sampleCount += segment.count
    }

    mutating func removeAll(keepingCapacity: Bool) {
        segments.removeAll(keepingCapacity: keepingCapacity)
        sampleCount = 0
    }

    mutating func drain() -> CapturedAudioSegments {
        let captured = CapturedAudioSegments(segments: segments,
                                             sampleCount: sampleCount)
        segments.removeAll(keepingCapacity: true)
        sampleCount = 0
        return captured
    }
}

final class AudioCapture: @unchecked Sendable {
    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var manuallyMixInputToMono = false
    private let lock = NSLock()
    private var samples = AudioSampleAccumulator()
    private var _isRunning = false
    private var latestLevel: Float = 0
    private var latestLevelSequence: UInt64 = 0
    private var recordingGeneration: UInt64 = 0
    private var recoveryJournal: PendingDictationJournal?
    private var engineStarted = false
    private var configurationObserver: NSObjectProtocol?

    var onConfigurationChange: (@Sendable () -> Void)?

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isRunning
    }

    var isEngineStarted: Bool {
        lock.lock(); defer { lock.unlock() }
        return engineStarted
    }

    func startEngine(inputDevicePreference: String = "",
                     recordingImmediately: Bool = false,
                     recoveryJournal: PendingDictationJournal? = nil) throws {
        if isEngineStarted {
            if recordingImmediately {
                beginRecording(recoveryJournal: recoveryJournal)
            }
            return
        }

        let input = engine.inputNode
        let selectedDevice = applyInputDevicePreference(inputDevicePreference, to: input)
        if let selectedDevice {
            waitForSelectedInputDevice(selectedDevice, on: input)
        }
        _ = try installCaptureTap(on: input)
        lock.lock()
        if recordingImmediately {
            recordingGeneration &+= 1
            samples.removeAll(keepingCapacity: true)
            latestLevel = 0
            latestLevelSequence &+= 1
            _isRunning = true
            self.recoveryJournal = recoveryJournal
        }
        lock.unlock()

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            clearStoppedCaptureState()
            resetEngineInstance()
            throw error
        }
        lock.lock()
        engineStarted = true
        lock.unlock()
        installConfigurationObserver()
        log("AudioCapture: engine started")
    }

    func startRecording(inputDevicePreference: String = "",
                        recoveryJournal: PendingDictationJournal? = nil) throws {
        if isEngineStarted {
            beginRecording(recoveryJournal: recoveryJournal)
            return
        }
        try startEngine(inputDevicePreference: inputDevicePreference,
                        recordingImmediately: true,
                        recoveryJournal: recoveryJournal)
    }

    func recoverAfterConfigurationChange() throws -> Bool {
        guard isEngineStarted else { return false }

        let input = engine.inputNode
        input.removeTap(onBus: 0)
        engine.stop()

        var didInstallTap = false
        do {
            let inputFormat = try installCaptureTap(on: input)
            didInstallTap = true
            engine.prepare()
            try engine.start()
            log("AudioCapture: graph recovered at \(inputFormat.sampleRate) Hz \(inputFormat.channelCount)ch")
            return true
        } catch {
            if didInstallTap {
                input.removeTap(onBus: 0)
            }
            lock.lock()
            converter = nil
            converterInputFormat = nil
            manuallyMixInputToMono = false
            engineStarted = false
            lock.unlock()
            throw error
        }
    }

    func stopEngine() {
        removeConfigurationObserver()

        let wasEngineStarted = isEngineStarted
        clearStoppedCaptureState()

        guard wasEngineStarted else { return }
        engine.inputNode.removeTap(onBus: 0)
        resetEngineInstance()
    }

    private func clearStoppedCaptureState() {
        lock.lock()
        _isRunning = false
        latestLevel = 0
        latestLevelSequence &+= 1
        recordingGeneration &+= 1
        samples.removeAll(keepingCapacity: true)
        let recoveryJournal = self.recoveryJournal
        self.recoveryJournal = nil
        engineStarted = false
        converter = nil
        converterInputFormat = nil
        manuallyMixInputToMono = false
        lock.unlock()
        recoveryJournal?.finish()
    }

    private func resetEngineInstance() {
        engine.stop()
        engine.reset()
        engine = AVAudioEngine()
    }

    func beginRecording(recoveryJournal: PendingDictationJournal? = nil) {
        lock.lock()
        let previousJournal = self.recoveryJournal
        recordingGeneration &+= 1
        samples.removeAll(keepingCapacity: true)
        latestLevel = 0
        latestLevelSequence &+= 1
        _isRunning = true
        self.recoveryJournal = recoveryJournal
        lock.unlock()
        previousJournal?.finish()
    }

    private func installConfigurationObserver() {
        removeConfigurationObserver()
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.onConfigurationChange?()
        }
    }

    private func removeConfigurationObserver() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
    }

    func endRecording() -> CapturedRecording {
        let startedAt = ProcessInfo.processInfo.systemUptime
        lock.lock()
        _isRunning = false
        latestLevel = 0
        latestLevelSequence &+= 1
        recordingGeneration &+= 1
        let captured = samples.drain()
        let recoveryJournal = self.recoveryJournal
        self.recoveryJournal = nil
        lock.unlock()
        let detachedAt = ProcessInfo.processInfo.systemUptime
        recoveryJournal?.finish()
        let journalFlushedAt = ProcessInfo.processInfo.systemUptime
        let flattened = captured.flattened()
        let flattenedAt = ProcessInfo.processInfo.systemUptime
        return CapturedRecording(
            samples: flattened,
            recoveryURL: recoveryJournal?.url,
            detachSeconds: detachedAt - startedAt,
            journalFlushSeconds: journalFlushedAt - detachedAt,
            flattenSeconds: flattenedAt - journalFlushedAt
        )
    }

    func latestRecordingLevelSnapshot() -> (level: Float, sequence: UInt64) {
        lock.lock(); defer { lock.unlock() }
        return _isRunning
            ? (latestLevel, latestLevelSequence)
            : (0, latestLevelSequence)
    }

    private func installCaptureTap(on input: AVAudioInputNode) throws -> AVAudioFormat {
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(
                domain: "SuperDictate.AudioCapture",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "The selected microphone has no active audio stream."]
            )
        }
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: SAMPLE_RATE,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(
                domain: "SuperDictate.AudioCapture",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Could not create the transcription audio format."]
            )
        }

        let sourceFormat = converterSourceFormat(for: inputFormat)
        let mixToMono = inputFormat.channelCount > 1 && sourceFormat.channelCount == 1
        guard let newConverter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw NSError(
                domain: "SuperDictate.AudioCapture",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "Could not convert audio from the selected microphone."]
            )
        }

        lock.lock()
        converterInputFormat = sourceFormat
        manuallyMixInputToMono = mixToMono
        converter = newConverter
        lock.unlock()

        input.installTap(onBus: 0, bufferSize: 512, format: inputFormat) { [weak self] buffer, _ in
            self?.handleTap(buffer: buffer, target: targetFormat)
        }

        let mixLabel = mixToMono ? " via manual mono mix" : ""
        log("AudioCapture: input \(inputFormat.sampleRate) Hz \(inputFormat.channelCount)ch\(mixLabel) → \(targetFormat.sampleRate) Hz mono")
        return inputFormat
    }

    private func handleTap(buffer: AVAudioPCMBuffer, target: AVAudioFormat) {
        lock.lock()
        let running = _isRunning
        let generation = recordingGeneration
        let converter = self.converter
        let monoMixFormat = converterInputFormat
        let mixToMono = manuallyMixInputToMono
        lock.unlock()
        guard running, let converter else { return }

        let converterInput = preparedConverterInputBuffer(from: buffer,
                                                          mixToMono: mixToMono,
                                                          monoFormat: monoMixFormat) ?? buffer
        let ratio = target.sampleRate / converterInput.format.sampleRate
        let outCap = AVAudioFrameCount(Double(converterInput.frameLength) * ratio + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCap) else { return }

        let inputProvider = AudioConverterInputProvider(buffer: converterInput)
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            inputProvider.provide(outStatus: outStatus)
        }
        if status == .error {
            log("AudioCapture: convert error: \(error?.localizedDescription ?? "?")")
            return
        }
        guard let ch = out.floatChannelData?[0] else { return }
        let frameCount = Int(out.frameLength)
        var arr: [Float] = []
        arr.reserveCapacity(frameCount)
        var sumSquares: Double = 0
        var finiteSampleCount = 0
        for sample in UnsafeBufferPointer(start: ch, count: frameCount) {
            arr.append(sample)
            guard sample.isFinite else { continue }
            let clamped = max(-1, min(1, sample))
            sumSquares += Double(clamped * clamped)
            finiteSampleCount += 1
        }
        let level = normalizedAudioLevel(sumSquares: sumSquares,
                                         sampleCount: finiteSampleCount)
        lock.lock()
        if _isRunning && recordingGeneration == generation {
            samples.append(arr)
            recoveryJournal?.append(arr)
            latestLevel = level
            latestLevelSequence &+= 1
        }
        lock.unlock()
    }

    private func converterSourceFormat(for inputFormat: AVAudioFormat) -> AVAudioFormat {
        guard inputFormat.channelCount > 1,
              let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: inputFormat.sampleRate,
                                             channels: 1,
                                             interleaved: false) else {
            return inputFormat
        }
        return monoFormat
    }

    private func preparedConverterInputBuffer(from buffer: AVAudioPCMBuffer,
                                              mixToMono: Bool,
                                              monoFormat: AVAudioFormat?) -> AVAudioPCMBuffer? {
        guard mixToMono else { return buffer }
        guard let monoFormat,
              let channels = buffer.floatChannelData else {
            return nil
        }

        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        guard channelCount > 1, frameCount > 0 else { return buffer }
        guard let out = AVAudioPCMBuffer(pcmFormat: monoFormat,
                                         frameCapacity: AVAudioFrameCount(frameCount)),
              let mono = out.floatChannelData?[0] else {
            return nil
        }

        let rms = channelRMSValues(channels: channels,
                                   channelCount: channelCount,
                                   frameCount: frameCount)
        writeMonoMix(channels: channels,
                     selectedChannels: selectedMonoMixChannelIndices(channelRMS: rms),
                     frameCount: frameCount,
                     to: mono)
        out.frameLength = AVAudioFrameCount(frameCount)
        return out
    }

    private func applyInputDevicePreference(_ preference: String,
                                            to input: AVAudioInputNode) -> AudioInputDevice? {
        let trimmed = preference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !isDefaultAggregateAudioInputPreference(trimmed) else { return nil }

        guard let device = audioInputDevice(matching: trimmed) else {
            log("AudioCapture: saved input device unavailable, using system default")
            return nil
        }
        guard let unit = input.audioUnit else {
            log("AudioCapture: input audio unit unavailable, using system default")
            return nil
        }

        if currentAudioInputDeviceID(for: unit) == device.id {
            log("AudioCapture: selected input \(device.name) already active")
            return device
        }

        var deviceID = device.id
        let status = AudioUnitSetProperty(unit,
                                          kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global,
                                          0,
                                          &deviceID,
                                          UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            log("AudioCapture: input device switch failed (\(formattedOSStatus(status))), using system default")
            return nil
        }
        log("AudioCapture: selected input \(device.name)")
        return device
    }

    private func waitForSelectedInputDevice(_ device: AudioInputDevice,
                                            on input: AVAudioInputNode) {
        guard let unit = input.audioUnit else { return }

        let expectedRate = audioInputDeviceNominalSampleRate(device.id)
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        var lastDeviceID = currentAudioInputDeviceID(for: unit)
        var lastFormat = input.inputFormat(forBus: 0)

        while ProcessInfo.processInfo.systemUptime < deadline {
            lastDeviceID = currentAudioInputDeviceID(for: unit)
            lastFormat = input.inputFormat(forBus: 0)
            let rateIsReady = expectedRate.map {
                abs(lastFormat.sampleRate - $0) < 0.5
            } ?? (lastFormat.sampleRate > 0)

            if lastDeviceID == device.id,
               lastFormat.channelCount > 0,
               rateIsReady {
                log("AudioCapture: selected input ready at \(lastFormat.sampleRate) Hz \(lastFormat.channelCount)ch")
                return
            }
            Thread.sleep(forTimeInterval: 0.025)
        }

        let expected = expectedRate.map { "\($0) Hz" } ?? "an active format"
        log("AudioCapture: selected input route still settling; device=\(lastDeviceID ?? 0), format=\(lastFormat.sampleRate) Hz \(lastFormat.channelCount)ch, expected \(expected)")
    }
}

enum RecordingReleaseAction: Equatable {
    case discardTooShort(duration: Double)
    case transcribe(duration: Double)
}

func recordingReleaseAction(capturedSampleCount: Int,
                            sampleRate: Double = SAMPLE_RATE,
                            minimumClipSeconds: Double = MIN_CLIP_SECONDS) -> RecordingReleaseAction {
    let duration = sampleRate > 0 ? Double(max(0, capturedSampleCount)) / sampleRate : 0
    return duration < minimumClipSeconds
        ? .discardTooShort(duration: duration)
        : .transcribe(duration: duration)
}
