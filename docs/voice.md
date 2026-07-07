# Voice setup

小光 speaks (TTS) and listens (STT), and both are **pluggable**. With the defaults everything runs
**on-device** — no keys, nothing leaves your Mac. Cloud options are opt-in per provider. Configure it
all under **Settings → Voice** (output) and **Settings → Speech Input** (input).

- [Text-to-speech (how she speaks)](#text-to-speech)
- [Speech-to-text (how she hears you)](#speech-to-text)
- [Voice modes (how you talk to her)](#voice-modes)

---

## Text-to-speech

Choose a provider under **Settings → Voice → TTS Provider**. Every provider decodes through the same
playback + lip-sync pipeline. Use the **Test Voice** button to preview any of them.

### Apple (on-device, default)

Runs entirely on-device using the voices installed in macOS — **no API key, no network, private**, and
it works out of the box. Set the **Voice** (or leave it on **Auto**, which picks the best installed
voice for your language) and a **Rate**.

**Get a much better voice (recommended).** The voices pre-installed with macOS sound robotic. macOS
offers far more natural *Enhanced* / *Premium* voices as a one-time, on-device download:

1. **System Settings → Accessibility → Spoken Content → System Voice → Manage Voices…**
2. Download a higher-quality voice, then **relaunch AniCompanion** — it appears in the Voice list, and
   **Auto** will prefer it automatically.

> **Note for 繁體中文 / Mandarin:** Apple ships its Premium/Siri **Mandarin** voices only as
> **中文（中國大陸）/ zh-CN** (e.g. **月 / Yue**) — there is no downloadable Premium **zh-TW** voice for
> third-party apps. A zh-CN Mandarin voice reads Traditional-Chinese text fine (only the accent differs
> slightly), so it's the way to get a high-quality Mandarin voice. AniCompanion's picker lists both
> zh-TW and zh-CN Mandarin voices (and excludes Cantonese).

### MiniMax

Cloud voice via MiniMax Speech-02-Turbo. Enter your **API Key**, **Group ID**, and **Voice ID**.

### OpenAI

Route speech through OpenAI's `/v1/audio/speech` (WAV output). Settings:

- **API Key**
- **TTS Model** — defaults to `gpt-4o-mini-tts`
- **Voice** — built-in OpenAI voices such as `coral`, `marin`, `cedar`
- **Voice Instructions** — promptable style/tone guidance (for models that support it)
- **Speed** — `0.25x`–`4.0x`

### BlueMagpie (local, experimental)

Route speech to a local [BlueMagpie-TTS](https://github.com/OpenFormosa/BlueMagpie-TTS) HTTP server
(`POST /v1/tts`, WAV) — select **BlueMagpie** and point it at the server URL.

> ⚠️ **Experimental — not verified end-to-end yet.** The provider and a reference server
> (`Tools/blue_magpie_tts_server.py`) are wired up but pending validation against BlueMagpie's next
> release. Until then, use **Apple** (default) or a cloud provider. Contributed by
> [@hlb](https://github.com/hlb).

---

## Speech-to-text

Voice input transcribes your speech before it reaches the agent. Choose under
**Settings → Speech Input → STT Provider**.

- **Apple** *(default)* — on-device via Apple's Speech framework. **No key, nothing leaves your Mac.**
  macOS prompts for **Microphone** + **Speech Recognition** permission on first use. Prefers on-device
  recognition where the locale supports it.
- **Groq / OpenAI / OpenAI-compatible** — records your mic and sends WAV to a Whisper
  `POST /v1/audio/transcriptions` endpoint. Enter the **Endpoint**, **API Key**, and **Model**
  (e.g. `whisper-large-v3-turbo` on Groq, `whisper-1` on OpenAI). Any self-hosted Whisper-compatible
  server works via **OpenAI-compatible**. Contributed by [@canyugs](https://github.com/canyugs).

---

## Voice modes

How you *talk to her*, from simplest to most conversational. Set these under **Settings → Speech Input**.

### Push-to-talk (default)

Click the **🎙️ mic button**, speak, and it auto-stops on a short silence. No configuration.

### Hands-free

Turn on **Hands-free mode** and the mic **re-arms automatically after each reply** — just talk, no
clicking. She listens only while idle (you take turns); to cut her off mid-sentence, use the mic
button — or enable full-duplex below.

### Full-duplex (voice barge-in)

Under Hands-free, enable **"Let me interrupt her by voice."** Now you can **talk over her** and she
stops to listen — a real back-and-forth conversation. It uses **acoustic echo cancellation** so she
doesn't hear her own voice.

- **Trade-off:** while she's *actively speaking*, macOS routes audio through a voice-processing engine,
  which briefly **quiets other apps' audio** (e.g. a YouTube video) for those few seconds. It engages
  only during her responses, so the rest of the time other audio plays normally.
- **Provider note:** barge-in capture always uses **Apple on-device recognition** (the only engine that
  streams live audio), even if you selected a cloud Whisper provider for regular input.

> **Tip:** all three modes are far nicer with a good voice and headphones — but full-duplex is designed
> to work on your Mac's built-in speaker + mic thanks to the echo cancellation.
