# Contributing to AniCompanion

Thanks for your interest! Contributions — code, bug reports, and especially **translations** —
are welcome.

## Building

```bash
xcodegen generate                 # regenerate the Xcode project (run after editing project.yml)
./scripts/download-model.sh       # fetch the default VRM model
open AniCompanion.xcodeproj       # build & run in Xcode
```

See `CLAUDE.md` for architecture notes and `README.md` for first-run setup.

## Testing screen vision (macOS Screen Recording)

Screen vision (**Settings → Screen Vision → "Let her see your screen"**, off by default) needs macOS
**Screen Recording** permission — macOS prompts on first capture, or you can grant it under **System
Settings → Privacy & Security → Screen Recording**.

⚠️ **Dev caveat:** local builds are ad-hoc signed ("Sign to Run Locally"), and macOS ties Screen
Recording to the exact code signature — which changes on every rebuild. So macOS **revokes the grant
after each rebuild**, and you'll re-grant while iterating. (Microphone and Speech Recognition don't do
this; Screen Recording is a higher-security permission bound to the *signature* rather than the bundle
ID.) Properly-signed release builds are unaffected — this is a dev-only annoyance.

**Optional — make the grant survive rebuilds** by signing your dev build with a stable self-signed
code-signing certificate:

1. **Keychain Access → Certificate Assistant → Create a Certificate…** → name it (e.g.
   `AniCompanion Dev`), **Identity Type: Self Signed Root**, **Certificate Type: Code Signing**.
2. Build, then re-sign the built `.app` before launching (the fixed certificate gives a fixed
   *designated requirement*, which is what Screen Recording keeps across rebuilds):
   ```bash
   codesign --force --deep --sign "AniCompanion Dev" \
     --entitlements AniCompanion/AniCompanion.entitlements --timestamp=none \
     /path/to/AniCompanion.app   # Xcode → Product → Show Build Folder in Finder
   ```
3. Grant Screen Recording **once** — it now persists across rebuilds.

This is entirely local; it doesn't touch the project or affect releases.

## Localization 🌍

The app is **English-first**; Traditional Chinese (`zh-Hant`) ships as a second language. A language
is made of **two independent layers**, and it helps to know which is which before you start:

| Layer | What it covers | Where it lives | Read by |
|-------|----------------|----------------|---------|
| **Interface** | Buttons, labels, settings, emotion names, window title — every on-screen string | `AniCompanion/Resources/Localizable.xcstrings` (String Catalog) | Apple's `String(localized:)` / SwiftUI `Text` via `AppleLanguages` + the app bundle's `.lproj` |
| **Persona** | What 小光 *says* — system prompt, greeting, idle prompts | `AniCompanion/Resources/Persona/<code>/` (`system_prompt.txt` + `proactive.json`) | `Persona.load(language:)`, keyed off our own `app_language` default |

`AppLanguage` (`AniCompanion/App/AppLanguage.swift`) is the single source of truth tying both layers
to one user choice (plus the STT locale). The two layers switch independently: the **persona** updates
the moment you pick a language in Settings; the **interface** applies on the next app launch (standard
macOS behaviour — see the dev-language note below for why).

### Adding a language

Example uses Japanese, `ja`:

1. **Register the language** — in `AniCompanion/App/AppLanguage.swift`:
   - Add a case: `case japanese = "ja"`
   - Add its endonym to `displayName` (e.g. `"日本語"`) — write each language's name *in that language*.
   - Map a speech-recognition locale in `sttLocaleIdentifier` (e.g. `"ja-JP"`).

2. **Translate the interface** — open `AniCompanion/Resources/Localizable.xcstrings` in Xcode's
   String Catalog editor, add the new language, and fill in the translations. (You can also edit the
   JSON directly — copy a `"zh-Hant"` block to `"ja"` and translate the values.) The window title
   key `"AI Agent | Xiaoguang"` is localized here too — render the name however reads best in your
   language.

3. **Declare it in the bundle** — in `AniCompanion/Info.plist`, add the code to the
   `CFBundleLocalizations` array (alongside `en` and `zh-Hant`). This is required for English to be
   selectable at all (see the dev-language note), and keeps the bundle's advertised localizations
   honest.

4. **Translate the persona** — copy `AniCompanion/Resources/Persona/en/` to
   `AniCompanion/Resources/Persona/ja/` and translate:
   - `system_prompt.txt` — the character's personality, speaking style, emotion-tag rules. Keep the
     `[emotion]` tags (`[happy]`, `[sad]`, …) **in English** — they're language-neutral markers the
     app parses. Update the "speak in …" line and the examples.
   - `proactive.json` — the greeting / idle templates. Keep the `{time}` and `{task}` placeholders.

5. **Run `xcodegen generate`** so the new persona folder is picked up, then build and test by
   choosing your language in **Settings → Language** (restart to see the interface change).

Missing pieces fall back to English, so a partial translation is still safe to ship.

### Adding a UI string (no new language)

Any new user-facing text must go through the String Catalog so it's translatable — never hardcode:

- SwiftUI: `Text("Save")` (a `LocalizedStringKey`); for a value you build, `Text(verbatim:)` opts out.
- Non-View code: `String(localized: "Speech recognition failed: %@")`.
- Add a `comment:` when the meaning is ambiguous (e.g. emotion names, the window title).
- Build once — Xcode auto-extracts new keys into `Localizable.xcstrings`; then add translations.

### Choosing the language when testing

The app never hardcodes a launch language. It's resolved at runtime from **two UserDefaults keys**,
falling back to the macOS system language — matching the two layers above:

| Layer | Override key | If unset, falls back to |
|-------|--------------|-------------------------|
| **Interface** (read by CFBundle at process start) | `AppleLanguages` | macOS system language ∩ `CFBundleLocalizations` |
| **Persona + STT** (read by app code: `AppLanguage.current`) | `app_language` | `AppLanguage.systemDefault` — zh-Hant if the system's first preferred language is a Traditional-Chinese variant, else English |

So a fresh install follows the user's Mac language; a Traditional-Chinese Mac launches in Chinese,
anything else in English. **Settings → Language** writes *both* keys together (interface on next
launch, persona immediately) — that's the path a real user takes, and the one to prefer when testing.

To force a specific language without changing your system settings:

1. **In-app** — Settings → Language. Simplest; keeps both layers in sync.
2. **Xcode scheme** — Edit Scheme → Run → Options → *App Language*. This injects `-AppleLanguages`
   for that run. ⚠️ It drives the **interface**, and the **persona** too *only if `app_language` is
   unset* (a previously persisted `app_language` wins and you get an interface/persona mismatch).
   For a clean run, delete the app's saved defaults first so both layers follow the scheme.
3. **CLI** — set both keys to the same value. The non-sandboxed app reads the global plist, but the
   `defaults` command may redirect to a stale sandbox container, so write the plist directly:
   ```bash
   PLIST="$HOME/Library/Preferences/com.anicompanion.app.plist"
   /usr/libexec/PlistBuddy -c "Delete :AppleLanguages" "$PLIST" 2>/dev/null
   /usr/libexec/PlistBuddy -c "Add :AppleLanguages array" "$PLIST"
   /usr/libexec/PlistBuddy -c "Add :AppleLanguages:0 string en" "$PLIST"
   /usr/libexec/PlistBuddy -c "Set :app_language en" "$PLIST" || \
     /usr/libexec/PlistBuddy -c "Add :app_language string en" "$PLIST"
   killall cfprefsd     # discard cfprefsd's cached copy
   ```

**The one rule:** the two keys must move together. Set only one and you'll get a half-switched UI
(English chrome with a Chinese persona, or vice versa) — the most common localization confusion here.

### Notes

- **Locale identifiers** follow BCP-47 and Apple's convention: Traditional Chinese is `zh-Hant`
  (script-based), Simplified is `zh-Hans`. Speech recognition can use a regional variant
  (e.g. `zh-Hant-TW`).
- **Why English has no `en.lproj`** — `en` is the *development language*
  (`CFBundleDevelopmentRegion`), so its strings *are* the keys in `Localizable.xcstrings`; Xcode emits
  an `.lproj` only for non-source languages (e.g. `zh-Hant.lproj`). For CFBundle to even consider
  English, the dev region **and** `CFBundleLocalizations` must be declared in `Info.plist` (the
  project's `Info.plist` is hand-maintained with `GENERATE_INFOPLIST_FILE: false`, so this isn't
  auto-injected). If the interface won't switch to a language, this is the first thing to check.
- Changing the language in Settings switches the **character** immediately; the **interface**
  applies after an app restart.
- Keep persona translations faithful to the character (cheerful, curious, a little mischievous) —
  adapt idioms rather than translating word-for-word.

## Adding an agent backend 🤖

AniCompanion is a **face for an LLM agent** — it renders a VRM character, speaks, listens, and runs
the streaming chat → sentence → TTS → lip-sync pipeline. A backend's only job is to turn a list of
role/content messages into a **stream of tokens**. Everything else (character, audio, UI) is backend-
agnostic, so adding support for a new agent is a small, self-contained change.

[Hermes Agent](https://github.com/NousResearch/hermes-agent) is the reference backend, validated
end-to-end. Any gateway that can stream chat completions can be added the same way.

### The contract: `ChatTransport`

Every backend implements `ChatTransport` (`AniCompanion/Services/ChatTransport.swift`):

| Member | Responsibility |
|--------|----------------|
| `events: AsyncStream<WSIncoming>` | Emits `.token(String)` per chunk, then `.done`, or `.error`. (The `WS` prefix is historical — the transport is protocol-neutral; HTTP/SSE is fine.) |
| `connectionState` / `connectionStatePublisher` | Drives the "Connected — Settings" status dot. |
| `connect()` / `disconnect()` | `connect()` is a cheap reachability check (Hermes does `GET /health`); no persistent socket is required. |
| `send(_ message: WSOutgoing) async throws` | Sends the conversation and starts streaming the reply into `events`. |

`HTTPChatService` (`AniCompanion/Services/HTTPChatService.swift`) is a complete, copy-able example for
any **OpenAI-compatible** gateway: it POSTs `/v1/chat/completions` with `stream:true` and parses the
standard SSE shape (`data: {json}` lines, `choices[0].delta.content`, `data: [DONE]` terminator). If
your agent speaks that dialect, you may be able to reuse it as-is and only add a registry entry.

> **Worked example in the repo:** the `openAICompatible` case in `ChatBackend.swift` is a real second
> backend (Ollama / LM Studio / vLLM / OpenRouter). Read its `makeTransport` arm next to `hermes`' —
> they differ only in `serviceName` and opting out of the `/health` probe (`healthCheckPath: nil`),
> reusing `HTTPChatService` wholesale. It's the shortest path to seeing what a new `case` looks like.

### Steps

1. **Implement the transport** (skip if an existing one fits). Add e.g.
   `AniCompanion/Services/MyAgentChatService.swift` conforming to `ChatTransport`. Model it on
   `HTTPChatService` — the SSE parsing, cancellation, and connection-state plumbing are all there.

2. **Register it** in `AniCompanion/Services/ChatBackend.swift` — this is the single place the app
   learns about backends:
   - Add a `case`: `case myAgent`
   - Fill in the `switch` arms: `displayName`, `defaultEndpoint`, `defaultModel`, `configHint`
     (one-line help shown under the connection fields — a `LocalizedStringKey`, so add it to the
     String Catalog), and a `makeTransport(_:)` branch returning your service.

   ```swift
   case .myAgent:
       return MyAgentChatService(
           endpoint: config.endpoint, apiKey: config.apiKey, model: config.model
       )
   ```

   `BackendConfig` carries `endpoint` / `apiKey` / `model` — enough for most gateways. If yours needs
   more (an org ID, a region), read it from `@AppStorage` inside your `makeTransport(_:)` arm.

3. **That's all.** `AppState` builds whatever backend `ChatBackend.current` resolves to, and the
   Settings **Agent backend** picker lists every `case` automatically (`CaseIterable`). The pipeline,
   character, and UI don't change. Run `xcodegen generate` only if you added new files.

### Notes

- **Token streaming matters.** The pipeline splits on sentence boundaries to start TTS early, so a
  backend that streams incrementally feels far more responsive than one that returns the whole reply
  at once. Emit `.token` as chunks arrive.
- **Emotion tags pass straight through.** The persona prompt asks the model to emit `[happy]`, `[sad]`,
  … inline; `SentenceParser` extracts them. A backend needs to do nothing special — just stream the
  text the model produced.
- **Don't rename the `WS*` vocabulary types.** `WSIncoming` / `WSOutgoing` are transport-neutral
  despite the prefix; renaming them is a wide, mechanical churn that's out of scope for a backend PR.

## Code style

- Swift 6, strict concurrency (actors for shared state, `@Sendable` closures).
- Keep new user-facing strings in the String Catalog (`Text("…")` or `String(localized:)`), not
  hardcoded.
- Run a build before opening a PR; keep it warning-free.
