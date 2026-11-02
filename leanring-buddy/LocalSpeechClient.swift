import AVFoundation
import Foundation

@MainActor
final class LocalSpeechClient {
    private var audioPlayer: AVAudioPlayer?
    private let nativeSynthesizer = AVSpeechSynthesizer()
    private var playbackGeneration = UUID()

    var isPlaying: Bool { (audioPlayer?.isPlaying ?? false) || nativeSynthesizer.isSpeaking }

    // FluidAudio documents a process-level BNNS crash on macOS 26.4–26.5.
    // A Swift catch cannot recover from that crash, so choose native speech up front.
    nonisolated static func supportsKokoro(on version: OperatingSystemVersion) -> Bool {
        version.majorVersion >= 15 && !(version.majorVersion == 26 && (4...5).contains(version.minorVersion))
    }

    func speakText(_ text: String) async throws {
        stopPlayback()
        let generation = playbackGeneration
        if Self.supportsKokoro(on: ProcessInfo.processInfo.operatingSystemVersion) {
            do {
                let data = try await LocalSpeechModels.shared.synthesize(text)
                try Task.checkCancellation()
                guard generation == playbackGeneration else { throw CancellationError() }
                let player = try AVAudioPlayer(data: data)
                audioPlayer = player
                guard player.play() else { throw CocoaError(.fileReadCorruptFile) }
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                guard generation == playbackGeneration else { throw CancellationError() }
                print("Local Kokoro unavailable; using macOS speech.")
            }
        }
        try Task.checkCancellation()
        nativeSynthesizer.speak(AVSpeechUtterance(string: text))
    }

    func speakNativeText(_ text: String) {
        stopPlayback()
        nativeSynthesizer.speak(AVSpeechUtterance(string: text))
    }

    func stopPlayback() {
        playbackGeneration = UUID()
        audioPlayer?.stop()
        audioPlayer = nil
        nativeSynthesizer.stopSpeaking(at: .immediate)
    }
}
