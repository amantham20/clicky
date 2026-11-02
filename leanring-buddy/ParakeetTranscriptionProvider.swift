import AVFoundation
import Foundation
import Speech

final class ParakeetTranscriptionProvider: BuddyTranscriptionProvider {
    let displayName = "Local Parakeet (Apple Speech fallback)"
    let requiresSpeechRecognitionPermission = false
    let isConfigured = true
    let unavailableExplanation: String? = nil

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        ParakeetTranscriptionSession(onFinalTranscriptReady: onFinalTranscriptReady, onError: onError)
    }
}

// AVAudioEngine owns the incoming buffers; copy samples before its tap returns.
// The lock protects capture versus key-up/cancel. No inference runs on the audio thread.
nonisolated final class ParakeetTranscriptionSession: BuddyStreamingTranscriptionSession, @unchecked Sendable {
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 600
    private let lock = NSLock()
    private let converter = BuddyPCM16AudioConverter(targetSampleRate: 16_000)
    private var audioData = Data()
    private var hasStopped = false
    private var hasExceededLimit = false
    private var transcriptionTask: Task<Void, Never>?
    private var fallbackSession: (any BuddyStreamingTranscriptionSession)?
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    init(onFinalTranscriptReady: @escaping (String) -> Void, onError: @escaping (Error) -> Void) {
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !hasStopped else { return }
        guard let convertedData = converter.convertToPCM16Data(from: audioBuffer) else { return }
        // Bound memory and inference latency on the fanless M1. Never silently truncate.
        guard audioData.count + convertedData.count <= 16_000 * 2 * 60 else {
            hasExceededLimit = true
            return
        }
        audioData.append(convertedData)
    }

    func requestFinalTranscript() {
        lock.lock()
        guard !hasStopped else { lock.unlock(); return }
        hasStopped = true
        let capturedData = audioData
        let exceededLimit = hasExceededLimit
        audioData.removeAll()
        lock.unlock()
        transcriptionTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            if exceededLimit {
                onError(AppleSpeechTranscriptionProviderError(message: "Please keep each push-to-talk recording under 60 seconds."))
                return
            }
            guard !capturedData.isEmpty else { onFinalTranscriptReady(""); return }
            let samples = capturedData.withUnsafeBytes { bytes in
                bytes.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32768 }
            }
            do {
                let transcript = try await LocalSpeechModels.shared.transcribe(samples)
                try Task.checkCancellation()
                onFinalTranscriptReady(transcript)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                print("Local Parakeet unavailable; trying on-device Apple Speech.")
                do {
                    let authorization = await withCheckedContinuation { continuation in
                        SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
                    }
                    guard authorization == .authorized else {
                        throw AppleSpeechTranscriptionProviderError(message: "Parakeet is unavailable and Apple Speech permission was denied. Restore the model download or allow Speech Recognition for Clicky.")
                    }
                    try Task.checkCancellation()
                    let session = try await AppleSpeechTranscriptionProvider().startStreamingSession(
                        keyterms: [], onTranscriptUpdate: { _ in },
                        onFinalTranscriptReady: onFinalTranscriptReady, onError: onError)
                    try Task.checkCancellation()
                    fallbackSession = session
                    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
                    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
                    buffer.frameLength = buffer.frameCapacity
                    samples.withUnsafeBufferPointer { source in
                        buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
                    }
                    session.appendAudioBuffer(buffer)
                    session.requestFinalTranscript()
                } catch {
                    guard !Task.isCancelled else { return }
                    onError(error)
                }
            }
        }
    }

    func cancel() {
        lock.lock()
        hasStopped = true
        audioData.removeAll()
        lock.unlock()
        transcriptionTask?.cancel()
        transcriptionTask = nil
        Task { @MainActor [weak self] in
            self?.fallbackSession?.cancel()
            self?.fallbackSession = nil
        }
    }
}
