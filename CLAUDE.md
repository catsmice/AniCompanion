# AniCompanion

macOS desktop AI character app with VRM 3D character rendering, LLM chat, TTS speech, and STT voice input.

> The character (小光) talks to you, speaks with a synthesized voice, lip-syncs and emotes a
> VRM avatar, and can proactively start conversations. The LLM runs through a local
> **[Hermes Agent](https://github.com/NousResearch/hermes-agent)** gateway you run yourself
> ("bring your own Hermes"). See `README.md` for setup.

## Tech Stack

- **Language**: Swift 6.0, macOS 15.0+
- **UI**: SwiftUI
- **Character rendering**: VRM via three-vrm (pixiv) in WKWebView + WebGL
- **LLM**: Local **Hermes Agent** gateway — OpenAI-compatible HTTP API (`POST
  http://127.0.0.1:8642/v1/chat/completions`, `stream:true` SSE, Bearer auth). Bring your own.
- **TTS**: Pluggable provider (`TTSProvider`) — **Apple** on-device `AVSpeechSynthesizer` (no key,
  no network, WAV; **default**), **MiniMax** Speech-02-Turbo (streaming SSE, hex-encoded MP3, cloud), **OpenAI**
  Speech API (`POST /v1/audio/speech`, WAV), or a local **BlueMagpie-TTS** HTTP server (`POST
  /v1/tts`, WAV). User supplies the cloud provider key, or runs the BlueMagpie server (see
  `Tools/blue_magpie_tts_server.py`)
- **STT**: Pluggable provider (`STTProvider`) — **Apple** Speech Framework (on-device, default) or
  cloud **Whisper** (`POST /v1/audio/transcriptions`) via **Groq**, **OpenAI**, or any
  **OpenAI-compatible** endpoint. User supplies the cloud key.
- **Screen Vision** *(opt-in, off by default)*: `ScreenVisionService` (ScreenCaptureKit) captures the
  user's focused window (or whole screen) and attaches it as an OpenAI `image_url` content-part to the
  chat turn, so a multimodal model can "see the screen." Needs a vision-capable model + macOS Screen
  Recording permission.
- **Audio**: AVAudioEngine + AVAudioPlayerNode
- **Dependencies**: no SPM packages — three-vrm + three.js load via CDN import maps; networking via
  URLSession, audio via AVFoundation. See `ATTRIBUTION.md`.

## Project Structure

```
AniCompanion/
├── AniCompanion/
│   ├── App/             # App entry (AniCompanionApp), AppDelegate (owns the NSWindow + pet mode), AppState, AppLanguage, Log
│   ├── Views/           # SwiftUI views (Main, Chat, Settings) + DesktopPet (PetDragView)
│   ├── Services/        # ChatTransport + HTTPChatService (Hermes), TTS (TTSProvider: MiniMax + OpenAI + BlueMagpie), STT, ScreenVision, AudioPlayer, ObjCSupport
│   ├── Character/       # ThreeVRMCharacterManager, ThreeVRMRenderView (WKWebView bridge to three-vrm)
│   ├── Pipeline/        # Orchestration (ConversationController, SentenceParser, AudioQueue)
│   ├── Models/          # Data models (ChatMessage, Emotion, ConversationHistory, AnimationClip)
│   └── Resources/       # Persona/<lang>/ (system_prompt.txt + proactive.json), Localizable.xcstrings, VRMModel/, Animations/ (JSON keyframe clips), ThreeVRM/ (HTML+JS scene)
├── Tools/               # Blender animation export + app-icon generator
├── scripts/             # download-model.sh (fetches the default VRM)
├── project.yml          # XcodeGen project spec
└── AniCompanion.xcodeproj
```

## Key Commands

```bash
# Regenerate Xcode project after changing project.yml (run from repo root, where project.yml lives)
xcodegen generate

# Build
xcodebuild -project AniCompanion.xcodeproj -scheme AniCompanion -destination 'platform=macOS' build

# Fetch the default VRM model (not committed — see ATTRIBUTION.md)
./scripts/download-model.sh

# Open in Xcode
open AniCompanion.xcodeproj
```

## Architecture

### Streaming Pipeline (critical path)

```
User input (text or voice) → HTTP chat (Hermes) → SentenceParser → parallel TTS → AudioQueue → ordered playback + lip sync
```

- **ChatTransport** (protocol) + **HTTPChatService** (@MainActor): `POST /v1/chat/completions`
  with `stream:true`; parses OpenAI-standard SSE (`data: {json}` lines, `data: [DONE]` terminator)
  into an `AsyncStream<WSIncoming>` of token/done/error events. `connect()` = `GET /health` (no
  persistent socket, heartbeat, or reconnect). Cancel → URLSession task cancel.
- **ChatBackend** (enum registry): "bring your own agent" seam. Each `case` registers a backend
  (`displayName`/`defaultEndpoint`/`defaultModel`/`configHint` + a `makeTransport(_:)` arm returning
  an `any ChatTransport`). `AppState` builds `ChatBackend.current.makeTransport(BackendConfig(...))`;
  the Settings **Agent backend** picker lists all `allCases`. Adding a backend = implement a
  transport + add a case. The selected backend is stored under `chat_backend`; each backend persists
  its **own** endpoint + key under per-backend keys (`chat_endpoint_<rawValue>` /
  `chat_api_key_<rawValue>`) via `savedEndpoint()`/`savedAPIKey()`/`saveConnection()`. A one-time
  migration (`migrateLegacyConnectionDefaults`) folds the older single-connection keys
  (`chat_endpoint`/`chat_api_key`, and before that `hermes_*`) into Hermes' per-backend keys.
  See `CONTRIBUTING.md` → "Adding an agent backend".
- **SentenceParser** (actor): Buffers LLM chunks, detects Chinese sentence boundaries, extracts emotion tags
- **AudioQueue** (actor): FIFO queue ensuring ordered playback even when TTS responses arrive out of order
- **ConversationController** (@MainActor): Orchestrates the full pipeline; consumes transport events
  via a long-lived listener; bridge-stream pattern (tokens → AsyncThrowingStream continuation);
  60-min proactive idle timer. (A dormant `notify`/`runNotificationPipeline`/`ack` path remains for a
  future cron-push integration; nothing emits `notify` today.)
- **TTSProvider** (enum registry): the voice analogue of `ChatBackend`. `apple` (on-device
  `AVSpeechSynthesizer`, no key/network, WAV) + `miniMax` (cloud Speech-02-Turbo, hex-encoded MP3
  over SSE) + `openAI` (cloud `POST /v1/audio/speech`, WAV output) + `blueMagpie` (local `POST
  /v1/tts`, WAV). `AppState.makeTTSService()` builds the selected `any TTSServiceProtocol`; the
  Settings **TTS Provider** picker swaps providers and shows per-provider fields.
  `AudioPlayerService` sniffs the RIFF/`WAVE` magic bytes to choose the temp-file extension, so
  Apple/OpenAI/BlueMagpie WAV and MiniMax MP3 both decode through one `AVAudioFile` path. Adding a
  provider = implement `TTSServiceProtocol` + add a case (mirrors the agent-backend seam).
  - Voice matching for the zh-Hant persona spans **all Mandarin** (`zh-TW` *and* `zh-CN`) and
    **excludes Cantonese** (`zh-HK`/`yue-*`): Apple ships premium/Siri Mandarin voices only as
    `zh-CN` (e.g. 月/Yue), so a Taiwan user's only path to a high-quality voice is a Mainland
    Mandarin one — it reads Traditional text fine. The dropdown tags each voice with its region.
- **AppleTTSService** (`apple`): renders offline via `AVSpeechSynthesizer.write(_:toBufferCallback:)`
  (which produces PCM buffers *without* playing), written out as WAV `Data` so lip-sync + `AudioQueue`
  work unchanged. Voice = empty string means auto-pick the best installed voice for the current
  `AppLanguage` (prefers `.premium`/`.enhanced`/`.compact` identifiers, so novelty voices like Bells
  are excluded; Meijia is the zh-TW baseline). Emotion maps to a subtle `pitchMultiplier` only —
  `AVSpeechUtterance` has no real emotional TTS. Compact voices sound robotic; Enhanced/Premium are a
  one-time OS download in System Settings → Accessibility → Spoken Content → Manage Voices.

### VRM Character Rendering (three-vrm + WKWebView)

- **ThreeVRMCharacterManager** (@MainActor): Swift bridge implementing `CharacterControllerProtocol`,
  sends commands to JS via `WKWebView.evaluateJavaScript()`, receives events via `WKScriptMessageHandler`
- **ThreeVRMRenderView**: SwiftUI `NSViewRepresentable` wrapping WKWebView, keyboard camera controls (W/S/A/D/Q/E/R/F)
- **vrm_scene.js**: three.js + @pixiv/three-vrm scene; WebGL rendering, idle animations, animation player, expression/lip-sync control
- **Spring bones**: Work via three-vrm's `vrm.update(delta)` — hair/skirt physics with gravity and colliders
- **Emotion → expressions**: The 16 emotions map onto the standard VRM expression presets that
  three-vrm normalizes from any model (`happy`/`angry`/`sad`/`relaxed`), via
  `vrm.expressionManager.setValue()`. Models with richer expressions can be given finer mappings.
- **Lip sync**: Driven by audio RMS amplitude (EMA-smoothed in Swift, value sent to JS) → the `aa`
  viseme (plus `jawOpen` on ARKit/VRM-1.0 PerfectSync models that define it)
- **Idle animations**: Spine rotation (breathing), head sway, preset blink — all in JS
- **Skeletal animation clips**: Pre-baked JSON keyframes sent from Swift to JS, binary search + slerp in JS, 0.25s blend-in

### VRM Model

- Default model is **Alicia Solid** (download-only — see `ATTRIBUTION.md`); any VRM works. Set the
  filename in Settings (**VRM Model Filename**) after placing it in `Resources/VRMModel/`.
- Only standard VRM expression presets are required (happy/sad/angry/relaxed + `aa` viseme + blink);
  ARKit Perfect Sync is optional.
- Default camera: X:0.0, Y:1.0, Z:4.7, LookAtY:0.8 (three-vrm uses +Z forward); tune live with W/S/A/D/Q/E/R/F.

### STT Voice Input

- **STTProvider** (enum registry): the voice-input analogue of `ChatBackend`/`TTSProvider`. `apple`
  (on-device, default) + `groq` / `openAI` / `openAICompatible` (Whisper `POST
  /v1/audio/transcriptions`). `AppState.makeSTTService()` builds the selected `any
  STTServiceProtocol`; the Settings **Speech Input** section swaps providers and shows per-provider
  fields (endpoint/key/model). Apple stays the default. Adding a provider = implement
  `STTServiceProtocol` + add a case (mirrors the agent-backend seam).
- **STTService** (@MainActor): SFSpeechRecognizer, on-device recognition (default zh-Hant-TW). Forces
  `requiresOnDeviceRecognition = true` when the locale supports it — private, offline, and (key for
  hands-free continuous listening) not subject to server rate limits.
- **STTAudioCapture** (non-isolated): Separate helper for AVAudioEngine + installTap to avoid a Swift 6 @MainActor isolation crash on the audio thread
- **WhisperSTTService** (@MainActor): records mic → WAV, then `POST /v1/audio/transcriptions`
  (multipart) to a Whisper endpoint. Uses its own non-`@MainActor` `WhisperAudioCapture` for the tap
  (same Swift-6 fix as `STTAudioCapture`); auto-stops on silence via an RMS-driven Timer.
- Auto-stop on 2s silence via Timer
- **Hands-free mode** (`ConversationController.configureVoiceMode` + `voice_hands_free_enabled`): opt-in
  continuous-listen loop (Settings → Speech Input). A generation-tokened background task re-arms the mic
  after every turn (`listenOnceAndRespond` → `sendMessage` awaits the full pipeline → re-arm), so the
  user talks hands-free. **Half-duplex** — the loop opens the mic *only while idle* (guards on
  `isProcessing || isSpeaking || isListening`), never during her own TTS, so she can't capture herself
  (no AEC needed). Voice barge-in *mid-speech* uses the mic button (`startVoiceInput` → `cancelInternal`)
  — or full-duplex (below). A fatal STT error stops the loop (no spin); benign no-speech/cancellation
  just re-arm.
- **Full-duplex voice barge-in** (`FullDuplexVoiceService` + `voice_full_duplex_enabled`, a sub-option
  of hands-free): the user can talk *over* her. It uses one shared **Voice-Processing I/O (VPIO)**
  `AVAudioEngine` that both plays her TTS (replacing `AudioPlayerService`; `runTTSPlayback` routes to
  `fdService.play`, lip-sync observes its `$currentAmplitude`) **and** taps the mic — echo-cancelled by
  VPIO. An **RMS gate** on the mic tap fires barge-in (`stopPlayback` + `onBargeIn`→`cancelInternal`);
  a **continuous `SFSpeechRecognizer`** (results ignored while `isSpeaking`, so her residual can't
  self-transcribe) captures the interrupting words → `onUserUtterance`→`sendMessage`.
  - **Lazy VPIO** (important): VPIO puts the audio device into communication mode, which *ducks other
    apps' audio* (YouTube goes silent) and holds the mic. So it runs **only while she's actually
    speaking a turn**, not all session: `configureVoiceMode` keeps the half-duplex loop for *idle*
    listening (no ducking, mic free), `runTTSPlayback` calls `ensureFullDuplexEngine()` (awaited) to
    bring VPIO up for the spoken turn, and `cleanupPipeline` calls `scheduleFullDuplexStop()` — a
    debounce that tears VPIO down when idle (it waits on `isCapturingUtterance` so a barge-in's
    recognition isn't cut off, and stays warm across chained turns). Net: other audio ducks *only
    during her responses*, and the hands-free loop guards on `fullDuplexService != nil` so STT and
    VPIO never fight over the mic.
  - **Why not software AEC** (tried + reverted): a speexdsp echo canceller on a plain engine avoids
    ducking entirely, but needs the mic + playback reference *sample-synchronized*; two independent
    `AVAudioEngine` taps drift (jittery timing + separate mic/speaker clocks) so the canceller can't
    lock → she self-transcribes. Sample-sync is the classic hard AEC problem VPIO solves in hardware.
    See [[anicompanion-vpio-fullduplex]] in memory.

### Live Transcription (opt-in, off by default)

- **SystemAudioCaptureService** (@MainActor + non-isolated `SCStreamOutput` helper): continuous
  `SCStream` with `capturesAudio=true` and **no video output attached** — captures what's *playing*
  on the Mac (a video, a meeting; NOT the mic). `excludesCurrentProcessAudio=true` means 小光's own
  TTS is never captured, so the self-transcription feedback loop can't happen by construction. Same
  Screen Recording TCC permission as `ScreenVisionService`. Buffers are deep-copied out of the
  `CMSampleBuffer` (`CMSampleBufferCopyPCMDataIntoAudioBufferList`) — the callback's backing memory
  isn't valid after return.
- **LiveTranscriptionController** (@MainActor; `AppState.liveTranscription`, long-lived — a Settings
  save/`reinitializeServices()` doesn't cut a running session; `apply(enabled:locale:)` reconciles):
  SCK audio → `StreamingTranscriptionEngine` → rolling caption (finalized tail + volatile partial,
  ~72-char window, auto-hide after 5 s of silence). **Display-only** (Phase 1): captions go to the
  pet speech bubble (`setSpeechText`, deferring while `isCharacterSpeaking`) and a caption overlay in
  `MainView` that doubles as the "Listening to your Mac's audio" privacy indicator.
- **Engines** (`StreamingTranscriptionEngine`): `SpeechTranscriber`/`SpeechAnalyzer` (macOS 26+ —
  Apple's long-form on-device streaming engine behind Live Captions; no ~1-min request limit;
  per-language model auto-downloaded in-app via `AssetInventory` with progress) with an
  `SFSpeechRecognizer` fallback (macOS 15; cycle-per-utterance like `FullDuplexVoiceService`;
  **Apple-server-based** for languages without on-device support, surfaced in Settings). Source
  language (`LiveCaptionSourceLanguage`: ja-JP / ko-KR / zh-TW / en-US) is independent of the app
  language — you watch a Japanese video while the UI runs in zh-Hant.
- Runtime probe (this Mac, macOS 26.5, 2026-07-07): SpeechTranscriber supports ja/ko/zh/en (ja + ko
  need a one-time model download; zh-TW/en installed); `SFSpeechRecognizer` has **no** on-device
  ja/ko. Apple **Translation** packs ja→zh-Hant and ko→zh-Hant were *already installed* — the Phase 2
  translate step can be fully on-device via `TranslationSession` (LLM as fallback).

### Screen Vision (opt-in, off by default)

- **ScreenVisionService** (@MainActor): ScreenCaptureKit (`SCScreenshotManager`, macOS 14+). Two scopes
  (`ScreenVisionScope`): `focusedWindow` (default) captures the frontmost window of the **last-activated
  non-self app** (tracked via `NSWorkspace` activation) so talking to 小光 never captures *her*;
  `entireScreen` captures the display excluding our own windows. Output is a downscaled JPEG; permission
  via `CGPreflight`/`CGRequestScreenCaptureAccess`. Long-lived on `AppState` (tracks the active app all
  session). Enabling it goes through a Settings consent alert, then the macOS permission prompt.
- **Multimodal transport**: `WSOutgoing.chat` carries `images: [Data]`; `HTTPChatService.encodeMessages`
  rebuilds the final user message's content into OpenAI content-parts (text + `image_url` base64-JPEG
  data URL) only when images are present (the text-only path is unchanged). `runPipeline` captures one
  frame per turn when enabled + permitted (non-fatal on failure), on both user and proactive turns.
- **Smart proactive glances**: while vision is on, the proactive timer uses a shorter, Settings-
  configurable interval (`visionProactiveIntervalSeconds`, default 5 min) and swaps the idle-task prompt
  for `Persona.visionGlanceTemplate` — she looks at the attached frame and speaks only if it's
  worthwhile, else emits a `[silent]` sentinel. `ConversationController.isSilentResponse` suppresses
  `[silent]` / empty / a lone bracketed aside (no history, speech, or bubble) — attentive, not chatty.

## Conventions

- All UI state managed through `AppState` (@MainActor, ObservableObject)
- Settings persisted via @AppStorage
- Strict Swift 6 concurrency: actors for shared state, @Sendable closures
- **Localization**: English-first (development language `en`), with `zh-Hant` shipped. UI strings
  live in `Resources/Localizable.xcstrings` (String Catalog); the character persona lives in
  `Resources/Persona/<lang>/` (`system_prompt.txt` + `proactive.json`), loaded by `Persona.load`.
  `AppLanguage` is the single source of truth (UI + persona + STT locale). New user-facing strings
  must go through `Text("…")` / `String(localized:)`, never hardcoded. Adding a language: see
  `CONTRIBUTING.md`.
- Emotion tags in LLM output (language-neutral, kept in English): `[neutral]`, `[happy]`, `[sad]`, `[angry]`, `[surprised]`, `[curious]`, `[excited]`, `[shy]`, `[love]`, `[smirk]`, `[sleepy]`, `[proud]`, `[disgusted]`, `[pain]`, `[laugh]`, `[bored]`
- Transport vocabulary types still use the historical `WS` prefix (`WSIncoming`/`WSOutgoing`) — they are transport-neutral now

## Settings (via Settings UI)

- **Agent backend** — which gateway to talk to (registered in `ChatBackend`: `hermes` default +
  `openAICompatible` for Ollama/LM Studio/vLLM/OpenRouter)
- **Endpoint** — selected backend's base URL (Hermes default `http://127.0.0.1:8642`)
- **API Key** — Bearer token for the gateway (for Hermes, its `API_SERVER_KEY`)
- **Character → VRM Model Filename** — file under `Resources/VRMModel/` to load (default
  `AliciaSolid.vrm`); changing it reloads the three-vrm scene live (via `loadModel` →
  `loadPendingModelIfPossible`, gated on `isWebViewReady`)
- **Enable TTS Voice** + **TTS Provider** (`Apple (on-device)` default | `MiniMax` | `OpenAI` | `BlueMagpie`):
  - Apple *(default)*: **Voice** (Auto / installed voices) + **Rate** — no key, no network
  - MiniMax: **API Key**, **Group ID**, **Voice ID**
  - OpenAI: **API Key**, **TTS Model**, **Voice**, **Voice Instructions**, **Speed**
  - BlueMagpie: **Server** URL (default `http://127.0.0.1:8765`) + **Inference Timesteps**
- **Speech Input → Hands-free mode** *(off by default)* — continuous listening: the mic auto re-arms
  after each reply so you just talk (half-duplex; interrupt mid-speech with the mic button)
  - **↳ Let me interrupt her by voice** *(sub-option, off by default)* — lazy-VPIO full-duplex barge-in:
    talk over her and she stops to listen. VPIO (echo cancellation) runs only while she's speaking, so
    other apps' audio is ducked *only during her responses*, not the whole session.
- **Speech Input → STT Provider** (`Apple` | `Groq` | `OpenAI` | `OpenAI-compatible`):
  - Apple: on-device, no key
  - Groq / OpenAI / OpenAI-compatible: **Endpoint**, **API Key**, **Model** (Whisper)
- **Language** (interface + character + STT)
- **Screen Vision** *(off by default)* — **Let her see your screen** toggle (consent alert → Screen
  Recording permission), **Capture** scope (Focused window | Entire screen), **Glance interval** (how
  often she proactively glances while vision is on), and a **Test: capture now** preview.
- **Live Transcription** *(off by default)* — **Live captions of your Mac's audio** toggle (consent
  alert → Screen Recording permission, shared with vision), **Source language** (ja/ko/zh-TW/en) and
  a live model-availability row (installed on-device / downloads on first use / Apple servers /
  unsupported). Display-only captions; translate is Phase 2.

Desktop Pet mode is not in this panel — toggle it from the 🐾 toolbar button, the **Character**
menu, or **⌘⇧D**.

## Running Hermes (bring your own)

In `~/.hermes/.env`: set `API_SERVER_ENABLED=true` and `API_SERVER_KEY=<your-key>`, then run
`hermes gateway` (listens on `127.0.0.1:8642`). Put the same key in the app's Settings. The
`model` field the app sends is cosmetic — Hermes' own config picks the actual LLM. Idle/proactive
prompts are tool-agnostic: if you configure MCP servers in Hermes, the agent uses them; otherwise
it answers from the model.

## Gotchas

- **Swift 6 + AVAudioEngine installTap**: The tap callback inherits @MainActor isolation if created inside a @MainActor class → AVFAudio's RealtimeMessenger asserts main queue → crash. Fix: a non-isolated helper class (`STTAudioCapture`) for the engine + tap.
- **AVFAudio Sendable warnings**: `AVAudioConverterInputBlock` is `@Sendable` but we capture a non-Sendable `AVAudioPCMBuffer` (safe — synchronous). `AudioPlayerService` uses `@preconcurrency import AVFoundation` to keep it warning-free.
- **SFSpeechRecognizer.requestAuthorization**: Crashes from a Swift async/@MainActor context on macOS. Fix: dispatch to `DispatchQueue.global()`.
- **App Sandbox + ad-hoc signing**: TCC permission dialogs crash with sandbox enabled and "Sign to Run Locally". Fix: disable App Sandbox for development.
- **Recognition cancellation errors**: macOS uses `kLSRErrorDomain` code 301 (not just `kAFAssistantErrorDomain` code 216). Handle both as cancellation.
- **three-vrm CDN**: Import maps load three.js and @pixiv/three-vrm from cdn.jsdelivr.net — requires internet on first load (browser caches thereafter).
- **WKWebView file access**: Must set `allowFileAccessFromFileURLs` and grant `allowingReadAccessTo:` the bundle Resources directory for JS to load the VRM via file:// URLs.
- **LazyVStack + conditional view types**: Switching view types with the same `.id()` inside a `LazyVStack` fails to re-render. Fix: one view type that handles both states.
- **Proactive messages must use `user` role**: A trailing `system` message gets ignored (empty response). Fix: send as `user` role with `isHidden: true`.
- **macOS App Nap kills Timer**: `Timer.scheduledTimer` doesn't fire when napped. Fix: `DispatchSource.makeTimerSource(flags: .strict)`.
- **Pipeline cancellation on new input**: `sendMessage()` must not guard on `isProcessing` — cancel the active pipeline and start a new one. A `pipelineGeneration` counter prevents stale cleanup from clobbering the new pipeline.
- **macOS app-icon caching**: After changing the icon, set `CFBundleIconName` + do a Clean Build Folder; the Dock/Finder cache may need `lsregister -f <app>` + `killall Dock`.
- **i18n needs `CFBundleDevelopmentRegion` in Info.plist**: With a hand-maintained `Info.plist` (`GENERATE_INFOPLIST_FILE: false`), `developmentLanguage: en` in `project.yml` does *not* inject `CFBundleDevelopmentRegion`. Without it, the build ships only `zh-Hant.lproj` (the source language `en` emits no `.lproj`), so CFBundle's only available localization is Chinese and the UI never switches to English regardless of `AppleLanguages`. Fix: declare `CFBundleDevelopmentRegion = en` (and `CFBundleLocalizations = [en, zh-Hant]`) in `Info.plist`. The character **persona** switching is independent — it reads our own `app_language` default, not CFBundle.
- **Testing the language switch from the CLI is unreliable**: the app is non-sandboxed (reads `~/Library/Preferences/com.anicompanion.app.plist`), but a leftover sandbox **container** makes `defaults read/write com.anicompanion.app` silently redirect to `~/Library/Containers/com.anicompanion.app/...`, which the app never reads. Verify the real language switch via **Settings → Language** in-app, or write directly to the global plist with `PlistBuddy` + `killall cfprefsd`.
- **`OptionSet.contains(.borderless)` is ALWAYS true**: `.borderless` is rawValue `0` (the empty set), so `styleMask.contains(.borderless)` is a tautology. Detecting "is the window in pet mode?" this way made the whole transition dead code (Desktop Pet "did nothing"). Detect window state via a non-zero member (`!styleMask.contains(.titled)`) or, better, an explicit tracked `Bool` you own — don't re-derive state you already hold (`AppDelegate.isPetActive`). General trap: any `static let foo: T = []` makes `.contains(foo)` constant.
- **Transparent windows: bypass SwiftUI, use the bare WKWebView as `contentView`**: SwiftUI `WindowGroup` / `NSHostingController` re-assert an opaque window background, and `ThreeVRMRenderView` has its own opaque `RadialGradient` behind the WebView — both block desktop-through transparency. Desktop Pet mode (`AppDelegate.enterPet`) puts the **bare** `WKWebView` (already transparent via `drawsBackground=false` + three.js `alpha:true`) directly as a borderless `isOpaque=false` window's `contentView`. The persistent webView is reused (no reload); resize the window to the pet size **before** installing the webView and dispatch a JS `resize` so three.js re-frames.
- **NSPanel pet mode vs. `applicationShouldTerminateAfterLastWindowClosed`**: the main window is an `NSPanel` (so pet mode can use `.nonactivatingPanel` — she floats over your work without stealing focus). AppKit does **not** count panels toward the "last window closed" check, so returning `true` there quit the whole app whenever an auxiliary window (Settings) closed. Fix: return `false` and quit explicitly in `windowWillClose` only when the *main* window closes; also `hidesOnDeactivate = false` (panels hide on deactivate by default).
- **Screen Recording permission resets on every rebuild**: ad-hoc "Sign to Run Locally" changes the code signature (cdhash) each build, and Screen Recording is a high-security TCC permission bound to the *signature* — so the grant drops on every rebuild (Mic/Speech survive because they key on the bundle id). Dev workaround: sign the dev build with a stable self-signed code-signing cert; `run-app.sh` re-signs automatically when a gitignored `scripts/dev-signing-identity` file holds the identity hash — see `CONTRIBUTING.md` → *Testing screen vision & live transcription*. **If the cert "disappears" from `security find-identity -v`, it likely just lost its trust flag** (`CSSMERR_TP_NOT_TRUSTED`, hidden by `-v`) — repair with `security add-trusted-cert -p codeSign`, do NOT create a new cert (new key = new designated requirement = grant lost).
- **LaunchServices bundle-id collision**: if another build with the same bundle id is registered (a second checkout, an installed copy), `open <path>` can launch a stale copy that exits. `scripts/run-app.sh` runs `lsregister -f` on the freshly-built app before `open` to force the right one.
- **Vision glance "stay silent" leaks as text**: told to "say nothing," models narrate their silence (`(nothing worth adding…)`) instead of returning empty. Fix: a `[silent]` sentinel in `Persona.visionGlanceTemplate` + `ConversationController.isSilentResponse` (also catches empty and a lone bracketed aside) to suppress the whole turn.
- **`AVSpeechSynthesizer.write` needs a live run loop on the *calling* thread**: its buffer callbacks are delivered on the run loop of whatever thread called `write`. Calling it from a background `Task` (no run loop) hangs forever — the completion never fires. `AppleTTSService`/`AppleSpeechRenderer` issues the `write` from `DispatchQueue.main.async` (the main run loop is always live in a GUI app), then resumes its `CheckedContinuation` from the callback. Verified: without this, a CLI test that blocks the main thread never gets a callback; with a running run loop it produces a valid RIFF/WAVE WAV (22050 Hz mono). A zero-length terminal buffer signals end-of-utterance.
- **VPIO acoustic echo cancellation (full-duplex) — four hard-won constraints** (`FullDuplexVoiceService`): (1) **AEC needs one engine**: VPIO's echo canceller references *the same engine's output*, so TTS playback and the mic tap MUST share one `AVAudioEngine` with `inputNode.setVoiceProcessingEnabled(true)` — there's no API to feed a reference from a separate engine. (2) **Format-pin to the VPIO rate**: enabling VPIO forces a 48 kHz hardware rate; the mixer defaults to 44.1 kHz and `engine.start()` then fails with **-10875**. Fix: connect mixer→output *and* player→mixer explicitly at `outputNode.inputFormat` (48 kHz). (3) **The VPIO input node is MULTI-CHANNEL** (9ch mic-array here). Appending that raw buffer to `SFSpeechRecognizer` yields a permanent **err 1110 "no speech detected"** — it needs mono. Extract channel 0 (the echo-cancelled voice channel) into a fresh mono buffer before `request.append`. This was the root cause of "barge-in stops her but no text." (4) **Feed recognition continuously, ignore results while speaking**: stop-during-speech loses the barge-in's opening words (user has to repeat); a restart-on-`isFinal` loop *thrashes*. Keep one recognizer alive, append audio always, and gate result *acceptance* on `!isSpeaking` — the interrupting words are already buffered and surface the instant the RMS gate flips `isSpeaking` false. **Calibration** (logged on-device): her voice post-AEC floors at ~0.003 RMS, the user's voice hits 0.16–0.25 → `bargeInRMSThreshold = 0.05` with wide margin.

## Status

Implemented: VRM rendering + spring bones, streaming chat via Hermes, pluggable TTS (Apple
on-device + MiniMax + OpenAI + local BlueMagpie) with lip sync, pluggable STT voice input (Apple
on-device + Groq/OpenAI Whisper), opt-in **hands-free mode** (half-duplex continuous-listen loop) with
an opt-in **full-duplex** sub-mode (lazy-VPIO echo-cancelled voice barge-in — talk over her; VPIO runs
only while she speaks so other audio ducks just during her responses),
opt-in **screen vision** (ScreenCaptureKit capture → multimodal
model, with smart
self-gating proactive glances), live streaming chat UI, 16 emotions, skeletal animation clips,
proactive idle timer (60 min, or a shorter configurable interval when screen vision is on),
configurable VRM model (Settings), desktop pet mode (non-activating transparent draggable overlay
with resize + speech bubble), opt-in **live transcription** Phase 1 (system audio → on-device Apple
STT → live captions in the pet bubble / a caption overlay; display-only).

Not yet done / deferred:
- Live transcription Phase 2 (translate toggle: Apple `TranslationSession` on-device for ja/ko→zh,
  LLM fallback) and Phase 3 (opt-in spoken dubbing with capture-gating; per-app capture scope)
- Cron-scheduled proactive push (needs polling Hermes' jobs API or a delivery adapter)
