import Foundation
import FluidAudio

// Keep inference away from the UI actor. Only speech models are loaded.
actor LocalSpeechModels {
    static let shared = LocalSpeechModels()
    private var recognitionManager: AsrManager?
    private var synthesisManager: KokoroAneManager?

    func transcribe(_ samples: [Float]) async throws -> String {
        if recognitionManager == nil {
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            recognitionManager = manager
        }
        try Task.checkCancellation()
        var decoderState = TdtDecoderState.make(decoderLayers: await recognitionManager!.decoderLayerCount)
        let result = try await recognitionManager!.transcribe(samples, decoderState: &decoderState)
        try Task.checkCancellation()
        return result.text
    }

    func synthesize(_ text: String) async throws -> Data {
        if synthesisManager == nil {
            let manager = KokoroAneManager(version: .v3)
            try await manager.initialize(preloadVoices: ["af_bella"])
            synthesisManager = manager
        }
        try Task.checkCancellation()
        let audio = try await synthesisManager!.synthesize(text: text, voice: "af_bella")
        try Task.checkCancellation()
        return audio
    }
}
