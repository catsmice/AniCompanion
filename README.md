<div align="center">

<img src="assets/logo.png" width="120" alt="AniCompanion app icon">

# AniCompanion

**A face for your AI agent.**<br>
A desktop VRM character that chats, speaks, listens, lip-syncs, and emotes — on macOS.

![License](https://img.shields.io/badge/license-MIT-green)
&nbsp;![Platform](https://img.shields.io/badge/platform-macOS%2015%2B-blue)
&nbsp;![Swift](https://img.shields.io/badge/Swift-6.0-orange)
&nbsp;![Status](https://img.shields.io/badge/status-early--stage-yellow)

**English** · [繁體中文](README.zh-Hant.md)

</div>

**小光** lives on your desktop as a 3D VRM avatar — she chats with you, **speaks and listens**
(hands-free, and you can talk right over her), lip-syncs and emotes, and proactively strikes up
conversations when you've been quiet.

AniCompanion doesn't ship an LLM; it's the **character, voice, and presence** layer in front of an
agent **you** run. Any gateway that streams chat completions can drive it — backends are pluggable
([Bring your own agent](#bring-your-own-agent)). **[Hermes Agent](https://github.com/NousResearch/hermes-agent)**
is the reference backend, validated end-to-end and runnable locally.

<div align="center">

| English | 繁體中文 |
|:---:|:---:|
| <img src="assets/en_screenshot.png" height="290" alt="AniCompanion with an English interface — the 小光 VRM avatar beside a chat panel"> | <img src="assets/tw_screenshot.png" height="290" alt="AniCompanion 的繁體中文介面 — 小光 VRM 虛擬角色與聊天面板"> |

</div>

> **Status:** functional, early-stage. Built and tested on macOS 26; runs on macOS 15+. Contributions welcome.

## Features

- **3D VRM character** via [three-vrm](https://github.com/pixiv/three-vrm) (WebGL in a WKWebView) —
  spring-bone physics (hair/skirt), idle breathing/blink, and skeletal gesture clips.
- **Streaming chat** through a pluggable agent backend: **Hermes Agent** (the validated reference) or
  a generic **OpenAI-compatible** one (Ollama, LM Studio, vLLM, OpenRouter, …).
- **Talk & be talked to** — she speaks with **amplitude-driven lip sync**, and you reply by voice:
  push-to-talk, **hands-free** (just talk), or **full-duplex** (interrupt her mid-sentence). See
  [Voice setup](docs/voice.md).
- **Pluggable voice providers** — TTS: **Apple on-device** (default, no key), **MiniMax**, **OpenAI**,
  or local **BlueMagpie**. STT: **Apple on-device** (default) or cloud **Whisper** (Groq / OpenAI /
  OpenAI-compatible).
- **Screen vision** *(opt-in, off by default)* — let 小光 see your focused window (or whole screen) so
  she can react to what you're working on. Needs a **vision-capable model** + Screen Recording permission.
- **Live captions** *(opt-in, off by default)* — 小光 captions the audio playing on your Mac (a video, a
  meeting) and can **translate** it on-device as you watch (e.g. Japanese/Korean → Chinese).
  Display-only. See [Live captions](docs/live-captions.md).
- **16 emotions** — emotion tags from the LLM drive the avatar's facial expressions.
- **Proactive companion** — greets you on launch and speaks up after a quiet spell.
- **Desktop Pet mode** — pop 小光 out into a transparent, always-on-top desktop overlay; drag to move,
  scroll/pinch to resize. See [Desktop Pet mode](#desktop-pet-mode).
- **Multilingual** — ships in **English** and **Traditional Chinese (繁體中文)**, switchable in Settings
  (interface *and* the language 小光 speaks).

## What's new in v0.6.0 — live captions & translation

小光 can now **caption the audio playing on your Mac** — a Japanese or Korean video, a meeting, a
podcast — and optionally **translate** it as you watch. It listens to your system audio, not your mic.

- **📺 Live captions of system audio.** She transcribes what's playing with Apple's on-device speech
  engine, shown under the character or in her pet-mode speech bubble. Display-only.
- **🌏 On-device translation** *(opt-in)* — translate captions as they appear (e.g. Japanese/Korean →
  Traditional Chinese) with Apple's on-device translator, or route them through your agent backend's
  **LLM** for context-aware quality.
- **👀 Watching together** — while captions run, ask 小光 about what's playing and she answers from the
  recent transcript.

Off by default; needs macOS Screen Recording permission. With the defaults it's fully on-device. See
[Live captions](docs/live-captions.md).

Full history: [CHANGELOG.md](CHANGELOG.md) · [Releases](https://github.com/catsmice/AniCompanion/releases).

## Requirements

- **macOS 15.0+**, Apple Silicon to run — *live captions & on-device translation are best on macOS 26*
  (on macOS 15 some languages use Apple's speech servers and on-device translation is unavailable; see
  [Live captions](docs/live-captions.md))
- **Xcode 26** to build (Swift 6 toolchain) — the live-caption APIs are compiled against the macOS 26 SDK
- **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** — `brew install xcodegen`
- A running **agent gateway** — [Hermes Agent](#bring-your-own-agent) is the validated path
- *Voice and vision work with the defaults (on-device, no accounts).* Cloud providers are optional —
  see [Voice setup](docs/voice.md).

## Quick start

```bash
# 1. Generate the Xcode project
xcodegen generate

# 2. Download the default VRM character model (not bundled — see ATTRIBUTION.md)
./scripts/download-model.sh

# 3. Build & run
open AniCompanion.xcodeproj      # then Run (⌘R) in Xcode
# …or: xcodebuild -project AniCompanion.xcodeproj -scheme AniCompanion -destination 'platform=macOS' build
```

On first launch, open **Settings (⚙️)** and set your **Agent backend** — its **Endpoint** (default
`http://127.0.0.1:8642`) and **API Key** — pointing at a gateway that's **already running** (see below).
Voice works out of the box on Apple's on-device engines; to use a cloud voice provider or tune the voice
modes, see [**Voice setup**](docs/voice.md).

> **First launch needs internet** — the three-vrm runtime loads from a CDN once, then caches. When it
> works you'll see 小光 appear and greet you. If she never shows, see [Troubleshooting](#troubleshooting).

## Bring your own agent

AniCompanion talks to an agent gateway you run yourself. Two backends are built in, under
**Settings → Agent backend**:

- **Hermes Agent** — the reference backend, validated end-to-end.
- **OpenAI-compatible** — any gateway speaking `/v1/chat/completions` SSE: Ollama, LM Studio, vLLM,
  OpenRouter, and friends.

Hermes in brief — in `~/.hermes/.env` set `API_SERVER_ENABLED=true` and `API_SERVER_KEY=<your-key>`
(`openssl rand -hex 32`), run `hermes gateway` (→ `http://127.0.0.1:8642`), and put the same
endpoint + key in Settings. Full walkthrough (incl. optional MCP tools):
[`docs/hermes-setup.md`](docs/hermes-setup.md). Adding a new backend is a one-`case` change —
[`CONTRIBUTING.md`](CONTRIBUTING.md#adding-an-agent-backend-).

## Desktop Pet mode

Detach 小光 into a borderless, transparent, always-on-top companion that floats over your other apps.
There's no chat panel — a small **speech bubble** shows what she's saying. Toggle with the **🐾**
toolbar button, **Character ▸ Desktop Pet Mode**, or **⌘⇧D**; **double-click** her to return.
Drag to move, scroll/pinch to resize. Your conversation is untouched while she's out.

<div align="center">

<img src="assets/pet_mode_en.png" width="680" alt="小光 in Desktop Pet mode — the VRM avatar floating on top of a browser window, with a speech bubble greeting the user">

</div>

## Learn more

- [**Voice setup**](docs/voice.md) — TTS & STT providers, hands-free & full-duplex modes, downloading better voices
- [**Live captions**](docs/live-captions.md) — caption & translate the audio playing on your Mac
- [**VRM model guide**](docs/vrm.md) — the default model, using your own, what a model needs
- [**Hermes setup**](docs/hermes-setup.md) — the reference agent gateway, MCP tools, diagnostics
- [**Privacy**](docs/privacy.md) — exactly what stays local and what a cloud option sends
- [**Contributing**](CONTRIBUTING.md) — add a backend, a voice provider, or a language
- [**Architecture & developer notes**](CLAUDE.md) — how the streaming voice pipeline fits together
- [**Changelog**](CHANGELOG.md)

## Troubleshooting

| Symptom | Likely cause / fix |
|---------|--------------------|
| `xcodegen: command not found` | `brew install xcodegen`. |
| Window opens but the character never appears | First launch needs **internet** (three-vrm loads from a CDN); also confirm `./scripts/download-model.sh` ran and a `.vrm` is in `AniCompanion/Resources/VRMModel/`. |
| You type and nothing happens | Your **agent gateway isn't running / reachable**. Start it and check the Settings connection indicator. For Hermes, a 401 means the **API Key** doesn't match `API_SERVER_KEY`. |
| She replies in text but doesn't speak | TTS is off, or her voice sounds robotic — both covered in [Voice setup](docs/voice.md). |
| Voice input does nothing | Allow **Microphone** + **Speech Recognition** on first use (System Settings → Privacy & Security). Cloud Whisper: check endpoint/key/model. More in [Voice setup](docs/voice.md). |

## License

Application source code: **MIT** — see [`LICENSE`](LICENSE). Bundled/downloaded **assets** (VRM model,
animation clips) are third-party works under their own terms — see [`ATTRIBUTION.md`](ATTRIBUTION.md).
The default VRM model is **not** MIT-licensed and is not redistributed by this project.
