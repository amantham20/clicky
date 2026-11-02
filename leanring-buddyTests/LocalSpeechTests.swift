import Foundation
import AVFoundation
import FluidAudio
import Testing
@testable import leanring_buddy

struct LocalSpeechTests {
    @Test @MainActor func cancelledCaptureCannotPublishAStaleTranscript() async {
        var callbackCount = 0
        let session = ParakeetTranscriptionSession(
            onFinalTranscriptReady: { _ in callbackCount += 1 },
            onError: { _ in callbackCount += 1 })
        session.requestFinalTranscript()
        session.cancel()
        await Task.yield()
        #expect(callbackCount == 0)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLICKY_RUN_MODEL_TESTS"] == "1"
                  && LocalSpeechClient.supportsKokoro(on: ProcessInfo.processInfo.operatingSystemVersion)))
    func kokoroProducesLocalWAV() async throws {
        let audio = try await LocalSpeechModels.shared.synthesize("Hello Clicky.")
        #expect(audio.starts(with: Data("RIFF".utf8)))
        #expect(audio.count > 44)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLICKY_RUN_MODEL_TESTS"] == "1"))
    func parakeetTranscribesLocalFixture() async throws {
        let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/speech-fixture.aiff")
        let audioFile = try AVAudioFile(forReading: fixtureURL)
        let audioBuffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: AVAudioFrameCount(audioFile.length))!
        try audioFile.read(into: audioBuffer)
        let samples = try AudioConverter().resampleBuffer(audioBuffer)
        let transcript = try await LocalSpeechModels.shared.transcribe(samples).lowercased()
        #expect(transcript.contains("blue button"))
    }

    @Test @MainActor func kokoroAvoidsKnownCrashingOSVersions() {
        for minorVersion in [4, 5] {
            #expect(!LocalSpeechClient.supportsKokoro(on: OperatingSystemVersion(majorVersion: 26, minorVersion: minorVersion, patchVersion: 2)))
        }
        #expect(LocalSpeechClient.supportsKokoro(on: OperatingSystemVersion(majorVersion: 26, minorVersion: 6, patchVersion: 0)))
        #expect(LocalSpeechClient.supportsKokoro(on: OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)))
        #expect(!LocalSpeechClient.supportsKokoro(on: OperatingSystemVersion(majorVersion: 14, minorVersion: 2, patchVersion: 0)))
    }

    @Test @MainActor func pointingStillMapsScreenTagAndRemovesItFromSpeech() {
        let parsed = CompanionManager.parsePointingCoordinates(from: "Use this button. [POINT:123,456:run button:screen2]")
        #expect(parsed.coordinate == CGPoint(x: 123, y: 456))
        #expect(parsed.screenNumber == 2)
        #expect(parsed.spokenText == "Use this button.")
    }
}
