# Clicky local speech fork

This fork keeps Claude as the only chat and screenshot reasoning backend. Parakeet TDT v3 runs through FluidAudio 0.18.2; Kokoro-82M uses FluidAudio's ANE-v3 hybrid Core ML pipeline. No local LLM is configured or downloaded. Existing overlay, model picker, Control+Option push-to-talk and multi-monitor POINT tags are retained.

## Requirements

- Apple Silicon, target M1 MacBook Air / 16 GB RAM. Runtime performance on that exact machine still needs measurement.
- macOS 15+ for Kokoro ANE-v3. On macOS 14, or 26.4–26.5, native macOS speech is selected before loading Kokoro. FluidAudio documents an unrecoverable BNNS crash on 26.4–26.5; macOS 26.6 is the documented fix. See https://github.com/FluidInference/FluidAudio/blob/v0.18.2/Documentation/TTS/KokoroAne.md.
- Xcode 26+ (the code uses Swift 6.2 nonisolated type syntax); Python 3.9+ for the standard-library local Claude relay.
- Company-approved Claude API access. A Claude company workspace login, SSO session or Claude Code subscription is not an API key. This fork never reads browser, workspace, Claude Code or Keychain authentication tokens.

## Start the Claude relay

From the repository root, in Terminal:

```sh
export CLICKY_ANTHROPIC_MESSAGES_URL='https://api.anthropic.com/v1/messages'
# Replace the URL with your company's approved Anthropic Messages-compatible URL.
# Enter the API credential privately; do not put it in source, Info.plist or a shared scheme.
read -s 'CLICKY_ANTHROPIC_API_KEY?Approved Claude API key: '
export CLICKY_ANTHROPIC_API_KEY
python3 local-proxy/server.py
```

The `read` command above is for the Mac's default zsh. Leave the relay running. Stop it with Control+C and `unset CLICKY_ANTHROPIC_API_KEY` afterward. Credentials exist only in that process environment; other processes running as your user may be able to inspect it. Use company credential-management policy on shared machines.

The relay binds only `127.0.0.1:8787`. It forwards only `/chat` to the configured HTTPS endpoint, rejects browser origins and non-Claude model names, validates TLS, refuses redirects, and does not log payloads, credentials or upstream error bodies. Default authentication is `x-api-key`; for an approved API gateway requiring a Bearer API credential, set `CLICKY_AUTH_HEADER=authorization`. This is still an API credential supplied by your company, not an extracted SSO token. The endpoint must accept Anthropic Messages request and SSE response formats. AWS Bedrock / Vertex request signing and interactive enterprise OAuth are not implemented.

Only transcripts, conversation context and screenshots are sent to this Claude endpoint. Audio is processed locally. Initial speech model and voice downloads contact FluidInference's model hosting on Hugging Face; later inference uses cached files. Upstream PostHog transcript analytics and email signup submission are disabled. Automatic upstream updates and login registration are inactive.

## Build and run

```sh
open leanring-buddy.xcodeproj
```

1. Select `leanring-buddy` and `My Mac` in Xcode.
2. Press Command+B to build or Command+R to run. Local builds use ad-hoc signing (`-`); no company signing identity is embedded. For your own distribution, configure your own signing identity and bundle ID.
3. Click Clicky's menu bar icon. Review and grant Microphone, Accessibility and Screen Recording permissions manually. Relaunch after changing Screen Recording access if macOS requires it.
4. Hold Control+Option, speak, then release. Keep each recording below 60 seconds. The waveform remains live; Parakeet produces a final transcript on release rather than cloud partial transcripts.
5. First transcription downloads and compiles the Parakeet models. Keep the first recording short and allow several minutes with an internet connection. The finalization budget is ten minutes; subsequent turns use the cached manager. Failure tries Apple Speech strictly on device and requests Speech Recognition permission then. If an on-device language is unavailable it reports an error instead of using cloud recognition.
6. Kokoro downloads/compiles and preloads only English `af_bella` on first eligible playback. If unavailable, the actual response is spoken through AVSpeechSynthesizer. New push-to-talk stops playback and invalidates pending speech so an old response cannot play later.

Default Claude relay URL is `http://127.0.0.1:8787/chat`. To use an explicitly approved compatible relay elsewhere, add `ClickyClaudeProxyURL` to Xcode's Run environment or Info.plist. No credentials belong in either place. To force Apple Speech, set `VoiceTranscriptionProvider=apple` in the Run environment. No cloud STT/TTS providers are selectable in this fork.

Do not use terminal `xcodebuild`: repository instructions require builds through Xcode to preserve permission identity. Changing signing or copying the app may require permission grants again.

## Tests

- `python3 -m unittest discover -s local-proxy -v` tests streaming, API credential forwarding without response exposure, rejection of browser origins, unsafe endpoints and non-Claude models. It uses a fake upstream and spends no API credits.
- Xcode `leanring-buddy` scheme, Command+U: existing permission tests, multi-monitor pointing tag regression, Kokoro OS safety policy.
- Xcode `Local Speech Integration` scheme, Command+U: additionally downloads/caches Parakeet and checks it recognizes “blue button” in a generated macOS speech fixture. No microphone, screenshot or Claude request is needed. The regular scheme skips this download test.
- Full end-to-end voice + screenshot + Claude + pointing needs your approved endpoint credential and your manual permission grants. It cannot be verified without those.

## Resource behavior and limits

There is no Python model service or local reasoning model. One Parakeet manager and one Kokoro manager are loaded lazily and cached per app launch. Microphone data is bounded to 60 seconds (about 1.9 MB PCM16); inference also holds a temporary float conversion. Short turns reduce latency and heat on the fanless M1. Model caches can use multiple GB including compiled and source Core ML assets; do not assume model parameter size equals RAM or disk use. M1 Air latency, thermals and peak memory remain to be measured under representative use. English voice output is the default; Parakeet v3 supports multilingual recognition, but Apple fallback depends on installed on-device language support.
