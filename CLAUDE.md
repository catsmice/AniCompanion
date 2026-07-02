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
- **TTS**: Pluggable provider (`TTSProvider`) — **MiniMax** Speech-02-Turbo (streaming SSE,
  hex-encoded MP3, cloud), **OpenAI** Speech API (`POST /v1/audio/speech`, WAV), or a local
  **BlueMagpie-TTS** HTTP server (`POST /v1/tts`, WAV). User supplies the cloud provider key, or
  runs the BlueMagpie server (see `Tools/blue_magpie_tts_server.py`)
- **STT**: Apple Speech Framework (on-device)
- **Audio**: AVAudioEngine + AVAudioPlayerNode
- **Dependencies**: no SPM packages — three-vrm + three.js load via CDN import maps; networking via
  URLSession, audio via AVFoundation. See `ATTRIBUTION.md`.

## Project Structure

```
AniCompanion/
├── AniCompanion/
│   ├── App/             # App entry (AniCompanionApp), AppDelegate (owns the NSWindow + pet mode), AppState, AppLanguage, Log
│   ├── Views/           # SwiftUI views (Main, Chat, Settings) + DesktopPet (PetDragView)
│   ├── Services/        # ChatTransport + HTTPChatService (Hermes), TTS (TTSProvider: MiniMax + OpenAI + BlueMagpie), STT, AudioPlayer, ObjCSupport
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
- **TTSProvider** (enum registry): the voice analogue of `ChatBackend`. `miniMax` (cloud
  Speech-02-Turbo, hex-encoded MP3 over SSE) + `openAI` (cloud `POST /v1/audio/speech`,
  WAV output) + `blueMagpie` (local `POST /v1/tts`, WAV).
  `AppState.makeTTSService()` builds the selected `any TTSServiceProtocol`; the Settings **TTS
  Provider** picker swaps providers and shows per-provider fields. `AudioPlayerService` sniffs the
  RIFF/`WAVE` magic bytes to choose the temp-file extension, so OpenAI/BlueMagpie WAV and MiniMax
  MP3 both decode through one `AVAudioFile` path. Adding a provider = implement
  `TTSServiceProtocol` + add a case (mirrors the agent-backend seam).

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

- **STTService** (@MainActor): SFSpeechRecognizer, on-device recognition (default zh-Hant-TW)
- **STTAudioCapture** (non-isolated): Separate helper for AVAudioEngine + installTap to avoid a Swift 6 @MainActor isolation crash on the audio thread
- Auto-stop on 2s silence via Timer

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
- **Enable TTS Voice** + **TTS Provider** (`MiniMax` | `OpenAI` | `BlueMagpie`):
  - MiniMax: **API Key**, **Group ID**, **Voice ID**
  - OpenAI: **API Key**, **TTS Model**, **Voice**, **Voice Instructions**, **Speed**
  - BlueMagpie: **Server** URL (default `http://127.0.0.1:8765`) + **Inference Timesteps**
- **Language** (interface + character + STT)

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

## Status

Implemented: VRM rendering + spring bones, streaming chat via Hermes, pluggable TTS (MiniMax +
OpenAI + local BlueMagpie) with lip sync, STT voice input, live streaming chat UI, 16 emotions,
skeletal animation clips, 60-min proactive idle timer, configurable VRM model (Settings), desktop
pet mode (borderless/transparent draggable overlay with resize + speech bubble).

Not yet done / deferred:
- Cron-scheduled proactive push (needs polling Hermes' jobs API or a delivery adapter)
