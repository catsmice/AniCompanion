# Live captions & translation

小光 can **listen to the audio playing on your Mac** — a video, a stream, a meeting, a podcast — and
show it as **live captions** in real time, optionally **translating** it as you watch. It captures
**system audio** (what's coming out of your speakers), not your microphone, so it's separate from the
[voice conversation modes](voice.md).

Everything runs **on-device** with the defaults (Apple's speech and translation engines) — nothing
leaves your Mac unless you choose the LLM translation engine. It's **off by default** and, like screen
vision, needs macOS **Screen Recording** permission (that's how macOS gates system-audio capture).

## Turn it on

**Settings → Live Transcription → "Live captions of your Mac's audio."** A consent prompt explains
what's captured, then macOS asks for Screen Recording permission. Pick a **Source language** (the
language being *spoken* — independent of the app's interface language), play something, and captions
appear under the character (or in her **speech bubble** in [Desktop Pet mode](../README.md#desktop-pet-mode)).

Captions are **display-only** — 小光 never speaks them back (that would talk over your video).

## Source language & the speech model

| Source | On-device (macOS 26+) | On macOS 15 |
|--------|-----------------------|-------------|
| Japanese, Korean | ✅ after a one-time model download | Apple's speech **servers** |
| Mandarin (zh-TW), English | ✅ installed | ✅ on-device |

On **macOS 26+** the app uses Apple's long-form on-device transcriber (the engine behind Live
Captions). The first time you pick a language that isn't installed, it downloads the model
automatically — you'll see a progress indicator — and it's private and offline after that. The
Settings row tells you the current status (installed / downloads on first use / uses Apple's servers /
unsupported).

On **macOS 15**, languages without an on-device model (Japanese, Korean) are transcribed by Apple's
speech servers instead — audio leaves your Mac for those. zh-TW and English stay on-device.

## Translate mode *(opt-in)*

Turn on **Translate captions** and choose a **target language** (Traditional Chinese, Simplified
Chinese, or English). Each finished sentence is translated and shown as the caption, with the original
in a smaller line above it. Two engines:

- **Apple Translation (on-device)** — fully local, fast, no key. Needs the language pair's pack
  installed (the app checks and tells you; add packs in **System Settings → General → Language &
  Region → Translation Languages** if missing). Japanese/Korean → Chinese are commonly pre-installed.
- **Agent backend (LLM)** — routes each sentence through the [agent backend](../README.md#bring-your-own-agent)
  you've configured. It keeps a few recent lines as context, so names, honorifics, and terminology
  stay consistent across subtitles — usually **more accurate**, at the cost of some latency (and cost,
  if your backend is a paid cloud model). The transcript is sent to that backend.

If the chosen engine isn't available (pack missing, backend down), captions gracefully fall back to
the untranslated original rather than breaking.

## "Watching together"

While captions are running, the recent transcript (original + translation) rides along as hidden
context on your chat turns — so you can just **ask 小光 about what's playing**: *"她剛剛說什麼？"*,
*"summarize the last minute,"* *"what does that word mean?"* She answers from the transcript. It never
appears in the chat log or her long-term history — it's context for the moment, not conversation.

## Notes & limitations

- **Hands-free voice mode pauses automatically** while captions run, so 小光 doesn't hear the video and
  reply to it (they'd otherwise fight over the mic and audio device). It resumes when you stop captions.
- **Her own voice is never captured** — AniCompanion excludes its own audio from the capture, so she
  can't transcribe herself, even if she speaks a reply.
- **Latency** is roughly 1–2 seconds for captions and a bit more for LLM translation — a sentence
  can't be translated until it's been spoken (especially Japanese → Chinese, where the verb comes
  last). This is normal for live captioning.
- **Accuracy** tracks the audio: clean, clear speech transcribes near-perfectly; heavy background
  music, overlapping speakers, or very fast casual speech are harder (true of any speech recognizer).

## Privacy

With the defaults (Apple on-device transcription + Apple on-device translation on macOS 26), **nothing
leaves your Mac**. The exceptions, both opt-in choices you make:

- **macOS 15 + Japanese/Korean** → transcription uses Apple's speech servers.
- **LLM translation engine** → the transcript is sent to your configured agent backend (local if you
  run a local model; a cloud provider if you point it at one).

See [Privacy](privacy.md) for the whole picture.
