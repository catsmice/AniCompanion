# Privacy — what stays local, what leaves your Mac

AniCompanion is **local-first**. It ships no LLM and no telemetry; it talks only to the services **you**
configure. With the defaults, **nothing leaves your Mac**. This page spells out exactly what each option
sends, so you can make an informed choice.

## With the defaults → fully local

| Piece | Default | Where it runs |
|-------|---------|---------------|
| **Speech-to-text** (your voice → text) | Apple Speech framework | **On-device** |
| **Text-to-speech** (her voice) | Apple `AVSpeechSynthesizer` | **On-device** |
| **Screen vision** | **Off** | — |
| **Live captions / translation** | **Off** | **On-device** when on (macOS 26; see note) |
| **The LLM / agent** | a gateway **you run** (e.g. Hermes locally) | Wherever *you* point it |

The one network dependency of a default install is **first launch** loading the three-vrm runtime from a
CDN (cached afterward) — no personal data, just JavaScript.

## What each opt-in sends

You only send data off your Mac if you deliberately turn one of these on:

- **Cloud TTS** (MiniMax or OpenAI) — the **reply text** 小光 is about to speak is sent to that provider
  to synthesize audio.
- **Cloud STT** (Groq / OpenAI / OpenAI-compatible Whisper) — your **microphone audio** (as a WAV clip)
  is sent to that endpoint to transcribe.
- **Screen vision** *(off by default)* — a **screenshot** of your focused window (or the whole screen) is
  attached to the chat turn and sent to your **chat model** so 小光 can see it. If that model is a cloud
  provider, the screenshot goes there. Enabling it requires an in-app consent prompt **and** macOS Screen
  Recording permission.
- **Live captions** *(off by default)* — captures your Mac's **system audio** (what's playing) and
  transcribes it. With the defaults this is **on-device** (Apple's transcriber on macOS 26+). Two
  exceptions send audio/text off your Mac, both your choice: on **macOS 15**, Japanese/Korean use
  Apple's speech **servers** (zh-TW/English stay local); and the optional **LLM translation engine**
  sends the transcript to your configured agent backend (local or cloud, per your setup). Apple's
  on-device translation stays local. Enabling captures requires consent + Screen Recording permission.
- **Your agent gateway** — everything you type or say (as text) goes to the gateway you configured, and
  onward to whatever model provider *you* set up behind it. Point it at a local model and the whole
  conversation stays on your machine; point it at a cloud model and your prompts go there. That choice is
  entirely yours.

## Notes

- **Full-duplex voice barge-in** does its echo cancellation **on-device** — enabling it sends nothing new;
  it just changes how the mic/speaker are handled locally.
- AniCompanion itself collects **no analytics** and phones home to **nothing**. The only outbound traffic
  is to the providers/gateway you configure (and the one-time CDN fetch above).
- Local, on-device options exist for both speech directions (Apple STT + Apple TTS, both defaults) and
  for TTS you can also run [BlueMagpie](voice.md#bluemagpie-local-experimental) locally.
