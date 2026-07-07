# Changelog

Notable changes per release. Format loosely follows [Keep a Changelog](https://keepachangelog.com/).
Release downloads and exact dates are on the [Releases](https://github.com/catsmice/AniCompanion/releases) page.

## v0.5.0 — speech-to-speech

Hands-free, interruptible voice conversation.

- **Apple on-device TTS — the new default.** No API key, no network, private, works out of the box.
  Includes an in-app guide to downloading higher-quality system voices.
- **Hands-free mode** — the mic re-arms after each reply; just talk, no button.
- **Full-duplex voice barge-in** *(opt-in)* — talk over her and she stops to listen, using on-device
  acoustic echo cancellation (engaged only while she's speaking, so other apps aren't muted otherwise).

## v0.4.0

- **Screen vision** *(opt-in, off by default)* — 小光 can see your focused window (or the whole screen)
  and react to it; needs a vision-capable model + macOS Screen Recording permission.

## v0.3.0

- **OpenAI text-to-speech** — route speech through OpenAI's `/v1/audio/speech`, with promptable voice
  instructions and adjustable speed, plus a **Test Voice** preview for any provider.
  Contributed by [@canyugs](https://github.com/canyugs).
- **Pluggable speech-to-text** — choose Apple on-device (default) or cloud Whisper via Groq / OpenAI /
  any OpenAI-compatible endpoint. Contributed by [@canyugs](https://github.com/canyugs).

## v0.2.1

- **Pet-mode speech bubble** — shown beside 小光's face, auto-flipping to stay on-screen.

## v0.2.0

- **Desktop Pet mode** — a transparent, always-on-top desktop overlay you can drag and resize.
- **Pluggable text-to-speech** — cloud **MiniMax**, plus an experimental local **BlueMagpie-TTS** option.
  Contributed by [@hlb](https://github.com/hlb).
- **Configurable character model** — switch VRM models from Settings instead of editing source.
  Contributed by [@hlb](https://github.com/hlb).
- Clearer language setting (interface language applies after restart; character switches immediately).

## v0.1.0

- Initial release: 3D VRM character (three-vrm + spring bones), streaming chat via a Hermes gateway,
  MiniMax TTS with amplitude-driven lip sync, Apple on-device speech input, 16 emotions, skeletal
  gesture clips, and a proactive idle greeting.
