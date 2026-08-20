// Parakey — push-to-talk dictation for macOS Apple Silicon.
// Audio / AudioDeviceManager.swift

import AudioToolbox
import CoreAudio
import Foundation

func audioObjectStringProperty(_ objectID: AudioObjectID,
                               selector: AudioObjectPropertySelector) -> String? {
    var address = AudioObjectPropertyAddress(mSelector: selector,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var rawValue: UnsafeRawPointer?
    var size = UInt32(MemoryLayout<UnsafeRawPointer?>.size)
    let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &rawValue)
    guard status == noErr, let rawValue else { return nil }
    let string = Unmanaged<CFString>.fromOpaque(rawValue).takeUnretainedValue() as String
    return string.isEmpty ? nil : string
}

func audioDeviceHasInputChannels(_ deviceID: AudioDeviceID) -> Bool {
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                             mScope: kAudioDevicePropertyScopeInput,
                                             mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
          size > 0 else { return false }

    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                               alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    let bufferList = raw.assumingMemoryBound(to: AudioBufferList.self)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferList) == noErr else {
        return false
    }

    let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
    return buffers.contains { $0.mNumberChannels > 0 }
}

func isDefaultAggregateAudioInputPreference(_ preference: String) -> Bool {
    let trimmed = preference.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.range(of: CORE_AUDIO_DEFAULT_AGGREGATE_PREFIX,
                         options: [.anchored, .caseInsensitive]) != nil
}

func normalizedInputDevicePreference(_ preference: String) -> String? {
    let trimmed = preference.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          trimmed.utf8.count <= MAX_INPUT_DEVICE_PREFERENCE_BYTES,
          !trimmed.unicodeScalars.contains(where: { $0.value == 0 }),
          !isDefaultAggregateAudioInputPreference(trimmed) else {
        return nil
    }
    return trimmed
}

func isDefaultAggregateAudioInputDevice(_ device: AudioInputDevice) -> Bool {
    isDefaultAggregateAudioInputPreference(device.uid)
        || isDefaultAggregateAudioInputPreference(device.name)
}

func availableAudioInputDevices() -> [AudioInputDevice] {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size) == noErr,
          size >= UInt32(MemoryLayout<AudioDeviceID>.size) else { return [] }

    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var ids = Array(repeating: AudioDeviceID(0), count: count)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                     &address, 0, nil, &size, &ids) == noErr else { return [] }

    return ids.compactMap { id in
        guard audioDeviceHasInputChannels(id),
              let uid = audioObjectStringProperty(id, selector: kAudioDevicePropertyDeviceUID),
              let name = audioObjectStringProperty(id, selector: kAudioObjectPropertyName) else {
            return nil
        }
        let device = AudioInputDevice(id: id, uid: uid, name: name)
        return isDefaultAggregateAudioInputDevice(device) ? nil : device
    }
    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
}

func audioInputDevice(matching preference: String,
                      in devices: [AudioInputDevice] = availableAudioInputDevices()) -> AudioInputDevice? {
    guard let trimmed = normalizedInputDevicePreference(preference) else { return nil }
    return devices.first { $0.uid == trimmed }
        ?? devices.first { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
}

func currentAudioInputDeviceID(for unit: AudioUnit) -> AudioDeviceID? {
    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioUnitGetProperty(unit,
                                      kAudioOutputUnitProperty_CurrentDevice,
                                      kAudioUnitScope_Global,
                                      0,
                                      &deviceID,
                                      &size)
    guard status == noErr, size == UInt32(MemoryLayout<AudioDeviceID>.size) else {
        return nil
    }
    return deviceID
}

func audioInputDeviceNominalSampleRate(_ deviceID: AudioDeviceID) -> Double? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var sampleRate = Float64(0)
    var size = UInt32(MemoryLayout<Float64>.size)
    let status = AudioObjectGetPropertyData(deviceID,
                                            &address,
                                            0,
                                            nil,
                                            &size,
                                            &sampleRate)
    guard status == noErr, sampleRate > 0 else { return nil }
    return sampleRate
}

func shouldRestartAudioInputForSettingsChange(previousPreference: String,
                                               nextPreference: String,
                                               isCoreRuntimeReady: Bool) -> Bool {
    isCoreRuntimeReady && previousPreference != nextPreference
}
