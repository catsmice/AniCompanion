# MiniMax T2A v2 (Text-to-Speech) — Integration Reference

A self-contained guide to MiniMax's streaming **Text-to-Audio v2** API, written so it can be
lifted into any project. Distilled from a working Swift client (`AniCompanion/Services/TTSService.swift`),
but the protocol details are language-agnostic.

> **TL;DR:** `POST https://api.minimax.io/v1/t2a_v2` with a Bearer token and a JSON body.
> With `"stream": true` the response is **SSE** (`data: {json}` lines); each event carries an
> **audio chunk as a hex-encoded string** at `data.audio` (NOT base64). Concatenate the decoded
> bytes to get the audio file (MP3 by default).

---

## 1. Endpoint & auth

| | |
|---|---|
| **Method** | `POST` |
| **URL (global)** | `https://api.minimax.io/v1/t2a_v2` |
| **URL (mainland China)** | `https://api.minimaxi.com/v1/t2a_v2` |
| **Auth** | `Authorization: Bearer <API_KEY>` |
| **Content-Type** | `application/json` |

### Credentials
- **API key** — from the MiniMax console. Sent as the Bearer token.
- **Group ID** — some MiniMax APIs/regions require it as a **query parameter**: `?GroupId=<id>`.
  The global `api.minimax.io/v1/t2a_v2` path authenticates via Bearer alone in practice — the
  reference client collects a Group ID but does **not** append it to this call. If you hit
  `1004`/auth errors, add `?GroupId=<id>` to the URL.

---

## 2. Request body

```jsonc
{
  "model": "speech-02-turbo",     // also: speech-02-hd, speech-01-turbo, speech-01-hd
  "text": "你好，今天過得如何？",   // the text to speak
  "stream": true,                  // true → SSE streaming; false → single JSON response
  "voice_setting": {
    "voice_id": "Chinese (Mandarin)_Crisp_Girl",  // a system voice name or your cloned-voice id
    "speed": 1.0,                  // 0.5–2.0
    // optional emotional voice — weight the voice's own timbre:
    "timber_weights": [
      { "timber_id": "Chinese (Mandarin)_Crisp_Girl", "weight": 100 }
    ]
  },
  "audio_setting": {
    "sample_rate": 32000,          // 8000 / 16000 / 22050 / 24000 / 32000 / 44100
    "bitrate": 128000,             // mp3 bitrate
    "format": "mp3"                // mp3 (default) | wav | pcm | flac
  }
}
```

**Minimum viable body:** `model`, `text`, `voice_setting.voice_id`. Everything else has defaults.

### Voice IDs
- **System voices** are referenced by name, e.g. `Chinese (Mandarin)_Crisp_Girl`,
  `Chinese (Mandarin)_Warm_Girl`, `English_Trustworthy_Man`. See MiniMax's voice catalog.
- **Cloned / custom voices** use the id returned by the voice-cloning API.

### Emotion (optional)
The reference client maps its own emotion set to MiniMax by adding `timber_weights` (weighting the
voice's own timbre) only when the turn has an emotion; neutral turns omit it. MiniMax also supports
an explicit `"emotion"` field on some models (`happy`, `sad`, `angry`, `fearful`, `disgusted`,
`surprised`, `neutral`) — check your model's support.

---

## 3. Streaming response (`stream: true`)

Server-Sent Events. Lines look like:

```
data: {"data":{"audio":"fffb90c4...","status":1},"trace_id":"...","base_resp":{"status_code":0,"status_msg":"success"}}
data: {"data":{"audio":"fffb90c4...","status":1}, ...}
data: {"data":{"audio":""},"extra_info":{"audio_length":1234,"audio_size":5678, ...},"base_resp":{...}}
```

**Parsing rules:**
1. Keep only lines beginning with `data:` (tolerate both `data: {` and `data:{`).
2. JSON-parse the payload.
3. **Error check:** if `base_resp.status_code != 0`, fail with `base_resp.status_msg`.
   (Errors can also arrive as a bare JSON line **without** the `data:` prefix — handle both.)
4. **Skip the final event:** the last event carries top-level `extra_info` and a **complete**
   audio blob (or empty audio). If you already streamed the incremental chunks, **skip any event
   that has `extra_info`** to avoid doubling the audio.
5. Extract `data.audio` — a **hex-encoded** string. Skip if empty.
6. **Hex-decode** it to raw audio bytes (see §5) and append/emit.

Concatenating all decoded chunks yields a valid audio file in the requested `format`.

### Non-streaming response (`stream: false`)
A single JSON object with the full hex audio at `data.audio` plus `extra_info`. Same hex decode.

---

## 4. Errors

| Where | How to detect |
|---|---|
| HTTP layer | non-200 status (e.g. `401` → bad/missing key) |
| API layer | `base_resp.status_code != 0` → message in `base_resp.status_msg` |
| Bare-JSON error | some errors arrive as a JSON line with no `data:` prefix — parse `base_resp` there too |

Common `status_code`s: `0` success, `1004` auth failed, `1002` rate limit, `2013` invalid params.

---

## 5. Hex decode (the key gotcha)

`data.audio` is **hex**, not base64. Each pair of hex chars is one byte:

```
"fffb90c4" → [0xFF, 0xFB, 0x90, 0xC4]
```

Reference implementation (Swift), portable to any language — walk the string two chars at a time,
convert each nibble (`0–9`, `a–f`, `A–F`), require even length:

```swift
init?(hexString: String) {
    let chars = Array(hexString)
    guard chars.count % 2 == 0 else { return nil }
    var bytes = [UInt8](); bytes.reserveCapacity(chars.count / 2)
    var i = 0
    while i < chars.count {
        guard let hi = chars[i].hexDigitValue, let lo = chars[i+1].hexDigitValue else { return nil }
        bytes.append(UInt8(hi << 4 | lo)); i += 2
    }
    self.init(bytes)
}
```

Python one-liner: `bytes.fromhex(hex_string)`. JS: `Buffer.from(hexString, "hex")`.

---

## 6. Minimal `curl` example

```bash
curl -N -X POST "https://api.minimax.io/v1/t2a_v2" \
  -H "Authorization: Bearer $MINIMAX_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "speech-02-turbo",
    "text": "你好，今天過得如何？",
    "stream": true,
    "voice_setting": { "voice_id": "Chinese (Mandarin)_Crisp_Girl", "speed": 1.0 },
    "audio_setting": { "sample_rate": 32000, "bitrate": 128000, "format": "mp3" }
  }'
# → stream of `data: {...}` lines; hex-decode each data.audio, skip the extra_info event,
#   concatenate → out.mp3
```

---

## 7. Client pseudocode (streaming)

```
request = POST url, headers{Authorization, Content-Type}, body(json above with stream=true)
for line in response.lines:
    line = trim(line)
    if line is empty: continue
    if line starts with "{" and not "data:":            # bare-JSON error
        if json(line).base_resp.status_code != 0: fail(status_msg)
        continue
    if not line.startsWith("data:"): continue
    json = parse(line without "data:" prefix)
    if json.base_resp.status_code != 0: fail(json.base_resp.status_msg)
    if json.extra_info != null: continue                # final complete-audio event → skip
    hex = json.data.audio
    if hex is empty: continue
    emit( hexDecode(hex) )                              # raw MP3 bytes
```

---

## 8. Gotchas checklist

- **Hex, not base64.** The #1 mistake — `data.audio` decodes with `fromhex`, not base64.
- **Skip the `extra_info` event** or you'll append the full audio twice (stutter/echo at the end).
- **Errors can bypass the `data:` prefix** — check `base_resp` on bare JSON lines too.
- **Group ID** may be needed as `?GroupId=` on some regions/endpoints even though the global
  t2a_v2 path works with Bearer alone.
- **Region endpoints differ:** `api.minimax.io` (global) vs `api.minimaxi.com` (mainland). Keys are
  region-scoped — use the endpoint matching where your key was issued.
- **`format` drives the bytes:** default `mp3`. Request `wav`/`pcm` if your player needs a specific
  container (e.g. to avoid an MP3 decode step).
- **Streaming vs. one-shot:** `stream: true` lowers time-to-first-audio (start playing chunk 1 while
  the rest synthesizes); `stream: false` is simpler if you just want the whole file.

---

*Source of truth for this doc: `AniCompanion/Services/TTSService.swift` (the `TTSService` class and
the `Data(hexString:)` extension). Model default `speech-02-turbo`; default voice
`Chinese (Mandarin)_Crisp_Girl`.*
