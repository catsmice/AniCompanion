<div align="center">

<img src="assets/logo.png" width="120" alt="AniCompanion 應用程式圖示">

# AniCompanion

**為你的 AI 代理，賦予一張臉。**<br>
一個在 macOS 桌面上會聊天、說話、聆聽、對嘴，還會表達情緒的 VRM 虛擬角色。

![License](https://img.shields.io/badge/license-MIT-green)
&nbsp;![Platform](https://img.shields.io/badge/platform-macOS%2015%2B-blue)
&nbsp;![Swift](https://img.shields.io/badge/Swift-6.0-orange)
&nbsp;![Status](https://img.shields.io/badge/status-early--stage-yellow)

[English](README.md) · **繁體中文**

</div>

**小光** 以 3D VRM 虛擬角色的形象住在你的桌面上。她會和你聊天、**開口說話也會聆聽**（直接開口就能說，還能直接
打斷她）、對嘴、表達情緒，還會在你安靜一陣子後主動找你聊天。

AniCompanion 本身不含 LLM；它是你自行執行的 agent 前方那一層**角色、聲音與存在感**。任何能串流
chat completions 的服務都能驅動它，後端也可以抽換（見 [自備 agent](#自備-agent)）。
最快的方式是直接用你已登入的 **Claude Code** 或 **Codex** CLI；**[Hermes Agent](https://github.com/NousResearch/hermes-agent)**
則是經過完整驗證、可在本機執行的參考後端。

<div align="center">

| 英文介面 | 繁體中文介面 |
|:---:|:---:|
| <img src="assets/en_screenshot.png" height="290" alt="AniCompanion 英文介面，小光 VRM 虛擬角色與聊天面板"> | <img src="assets/tw_screenshot.png" height="290" alt="AniCompanion 繁體中文介面，小光 VRM 虛擬角色與聊天面板"> |

</div>

> **狀態：** 可運作、早期階段。於 macOS 26 開發與測試，可在 macOS 15+ 執行。歡迎貢獻。

## 特色

- **3D VRM 角色**，以 [three-vrm](https://github.com/pixiv/three-vrm)（在 WKWebView 中以 WebGL）渲染，
  具備彈簧骨骼物理（頭髮、裙擺）、待機呼吸與眨眼，以及骨架手勢動畫。
- **串流聊天**，透過可抽換的 agent 後端，讓你**用已經有的 AI**：你已登入的 **Claude Code** 或
  **Codex** CLI（免 API 金鑰）、**Hermes Agent**（已驗證的參考後端），或任何 **OpenAI 相容**的服務
  （Ollama、LM Studio、vLLM、OpenRouter 等）。**首次啟動精靈**會找出你已安裝的項目並自動設定。
- **能說，也能被你打斷。** 她開口時搭配**由音量驅動的對嘴**，你則用語音回覆：按鍵說話、**直接開口**（開口
  就能說），或**全雙工**（說話中直接插話打斷她）。見 [語音設定](docs/voice.md)。
- **可抽換的語音供應商。** 語音合成可選 **Apple 裝置端**（預設，免金鑰）、**MiniMax**、**OpenAI**，或
  本機的 **BlueMagpie**；語音辨識可選 **Apple 裝置端**（預設）或雲端 **Whisper**（透過 Groq、OpenAI 或
  任何 OpenAI 相容端點）。
- **螢幕視覺**（*選用，預設關閉*）。讓小光看見你目前的視窗（或整個螢幕），對你正在做的事做出反應。
  需要**支援視覺的模型**與螢幕錄製權限。
- **即時字幕**（*選用，預設關閉*）。小光為你 Mac 上正在播放的聲音（例如影片或會議）加上字幕，還能在你
  觀看時於裝置端**翻譯**（例如日文或韓文翻成中文）。只顯示文字，她不會開口。見 [即時字幕](docs/live-captions.md)。
- **16 種情緒。** 模型回覆中的情緒標籤會驅動角色的臉部表情。
- **主動陪伴。** 啟動時會打招呼，並在你安靜一段時間後主動開口。
- **桌面寵物模式。** 把小光從視窗中拉出，變成透明、永遠置頂的桌面小夥伴；拖曳移動，捲動或捏合縮放。
  見 [桌面寵物模式](#桌面寵物模式)。
- **多語言。** 內建**英文**與**繁體中文**，可在設定中切換；切換會同時影響介面*以及*小光說話的語言。

## v0.7.0 有什麼新功能：輕鬆設定，用你已經有的 AI

現在你可以**直接下載執行**：不需要 Xcode，也不用編輯設定檔，而首次啟動精靈還會把小光連接到你已經有的 AI。

- **📦 下載即用，不需要 Xcode。** [Releases](https://github.com/catsmice/AniCompanion/releases) 頁面
  現在提供**已簽章、經 Apple 公證的 `.dmg`**；把小光拖到應用程式再開啟即可。完整步驟見
  [下載與安裝](#下載與安裝)。
- **🧙 首次啟動設定精靈。** 首次啟動時，小光會找出你可以使用的後端：已登入的 **Claude Code** 或
  **Codex**、正在執行的 **Hermes**，或 **Ollama／LM Studio**。她會進行一次即時連線測試（讓「已安裝但
  未登入」的 CLI 在*這裡*就露出問題，而非聊到一半才出錯），再儲存你的選擇。全程無需輸入任何東西。之後
  隨時可從設定，或從「尚未連接 AI 模型」提示重新開啟。
- **🔌 用你已經有的 AI。** 用你已經登入的 **Claude Code** 或 **Codex** CLI 來驅動小光：**免 API 金鑰，
  也不必額外執行任何服務。** 它以本機子程序執行，設定畫面也會自動隱藏用不到的連線欄位。
- **🎚️ 麥克風靈敏度。** 新增滑桿可提高輕聲說話的音量，讓她在你小聲說話時也聽得見。

完整紀錄：[CHANGELOG.md](CHANGELOG.md) · [Releases](https://github.com/catsmice/AniCompanion/releases)。

## 下載與安裝

想略過建置？直接取得現成的 App：

1. 從 [**Releases**](https://github.com/catsmice/AniCompanion/releases) 頁面下載最新的
   **`AniCompanion-*.dmg`**。
2. 開啟 `.dmg`，把 **AniCompanion** 拖到 **應用程式**。
3. 啟動它。它已**簽章並經 Apple 公證**，因此 macOS 不會跳出安全性警告即可開啟。

首次啟動時，**設定精靈**會把小光連接到你的 AI（例如你已登入的 **Claude Code** 或 **Codex** CLI，見
[自備 agent](#自備-agent)）。需要 **macOS 15+**（Apple 晶片）；即時字幕與裝置端翻譯建議 macOS 26。想改用
原始碼自行建置？見 [快速開始](#快速開始)。

## 系統需求

*（預先建置的下載版只需要 macOS 15+ 與一個 [能對話的 agent](#自備-agent)；以下其餘項目是**自行建置**時才需要。）*

- **macOS 15.0+**、Apple 晶片即可執行。*即時字幕與裝置端翻譯在 macOS 26 效果最佳*；在 macOS 15 上，
  部分語言會改用 Apple 語音伺服器，裝置端翻譯也無法使用（見 [即時字幕](docs/live-captions.md)）。
- **Xcode 26** 才能建置（Swift 6 工具鏈）；即時字幕相關 API 以 macOS 26 SDK 編譯。
- **[XcodeGen](https://github.com/yonaskolb/XcodeGen)**，以 `brew install xcodegen` 安裝。
- 一個能對話的 **agent**：已登入的 **Claude Code** 或 **Codex** CLI（無需額外執行任何東西），或執行中的
  gateway，例如 **[Hermes Agent](#自備-agent)**（已驗證的路徑）、Ollama 或 LM Studio。
- *語音與視覺使用預設值即可運作（裝置端、免帳號）。* 雲端供應商為選用；見 [語音設定](docs/voice.md)。

## 快速開始

```bash
# 1. 產生 Xcode 專案
xcodegen generate

# 2. 建置並執行。已內建預設角色（小光），可立即使用
open AniCompanion.xcodeproj      # 然後在 Xcode 按 Run（⌘R）
# …或：xcodebuild -project AniCompanion.xcodeproj -scheme AniCompanion -destination 'platform=macOS' build
```

首次啟動時，**設定精靈**會掃描你 Mac 上可用的後端：已登入的 **Claude Code** 或 **Codex** CLI、正在執行的
**Hermes**，或 **Ollama／LM Studio**，並直接完成連線，你無需輸入任何東西。你也可以填入雲端 API 金鑰，或先
略過、之後再從**設定（⚙️）→ Agent 後端**設定（見[下方](#自備-agent)）。語音預設使用 Apple 裝置端引擎即可
運作；若要改用雲端語音供應商或調整語音模式，見 [**語音設定**](docs/voice.md)。想換一個虛擬角色？
**設定 → 角色**可以匯入你自己的 VRM 或下載其他模型，詳見 [VRM 模型指南](docs/vrm.md)。

> **首次啟動需要網路。** three-vrm 執行環境會從 CDN 載入一次，之後便快取。運作正常時，小光就會出現並向你
> 打招呼。若她始終沒出現，見 [疑難排解](#疑難排解)。

## 自備 agent

AniCompanion 會與你自行執行的 agent 溝通。在 **設定 → Agent 後端** 選一個，或讓首次啟動精靈幫你設定：

- **Claude Code**／**Codex**：用你已經在使用的程式設計 CLI 來驅動小光。**免 API 金鑰**，它使用你既有的
  登入，並以本機子程序執行。若你已安裝其中之一，這是最快的開始方式。
- **Hermes Agent**：已完整驗證的參考後端。
- **OpenAI 相容**：任何以 `/v1/chat/completions` SSE 溝通的服務，包含 Ollama、LM Studio、vLLM 與
  OpenRouter。
- **Gemini**：Gemini CLI（需要 `GEMINI_API_KEY`）。

新增後端只需改一個 `case`，見 [`CONTRIBUTING.md`](CONTRIBUTING.md#adding-an-agent-backend-)。

Hermes 簡述：在 `~/.hermes/.env` 設定 `API_SERVER_ENABLED=true` 與 `API_SERVER_KEY=<你的金鑰>`
（可用 `openssl rand -hex 32` 產生），執行 `hermes gateway`（它會監聽 `http://127.0.0.1:8642`），再把相同
的端點與金鑰填入設定。完整教學（含選用的 MCP 工具）見 [`docs/hermes-setup.md`](docs/hermes-setup.md)。

## 桌面寵物模式

把小光拉成一個無邊框、透明、永遠置頂、漂浮在其他 App 之上的小夥伴。這個模式沒有聊天面板，改以一個小型
**對話泡泡**顯示她正在說的話。用工具列的 **🐾** 按鈕、**角色 ▸ 桌面寵物模式**，或 **⌘⇧D** 切換，
**雙擊**她即可回到視窗。拖曳移動，捲動或捏合縮放。她離開視窗時，你的對話原封不動。

<div align="center">

<img src="assets/pet_mode_tw.png" width="680" alt="小光的桌面寵物模式，VRM 虛擬角色漂浮在瀏覽器視窗之上，並帶有一個向使用者打招呼的對話泡泡">

</div>

## 深入了解

- [**語音設定**](docs/voice.md)：TTS 與 STT 供應商、直接開口與全雙工模式、下載更好的語音
- [**即時字幕**](docs/live-captions.md)：為你 Mac 上播放的聲音加上字幕並翻譯
- [**VRM 模型指南**](docs/vrm.md)：預設模型、使用你自己的模型、模型需要具備什麼
- [**Hermes 設定**](docs/hermes-setup.md)：參考 agent gateway、MCP 工具、診斷
- [**隱私說明**](docs/privacy.md)：哪些留在本機、雲端選項各自會送出什麼
- [**貢獻指南**](CONTRIBUTING.md)：新增後端、語音供應商或語言
- [**架構與開發者筆記**](CLAUDE.md)：串流語音管線如何組合在一起
- [**更新紀錄**](CHANGELOG.md)

## 疑難排解

| 症狀 | 可能原因／解法 |
|------|----------------|
| `xcodegen: command not found` | `brew install xcodegen`。 |
| 視窗開啟但角色始終沒出現 | 首次啟動需要**網路**（three-vrm 從 CDN 載入）。預設模型已內建；若你在設定中換成自訂模型，請確認該 `.vrm` 位於 `AniCompanion/Resources/VRMModel/`。 |
| 打字後沒有反應 | 你的 **agent gateway 未執行或無法連線**。啟動它並檢查設定中的連線指示。Hermes 出現 401 表示 **API 金鑰**與 `API_SERVER_KEY` 不符。 |
| 她只回文字、不開口 | TTS 關閉，或她的聲音聽起來很機械；兩種情況都在 [語音設定](docs/voice.md) 說明。 |
| 語音輸入沒反應 | 首次使用時請允許**麥克風**與**語音辨識**（系統設定 → 隱私權與安全性）。使用雲端 Whisper 時，檢查端點、金鑰與模型。更多見 [語音設定](docs/voice.md)。 |

## 授權

應用程式原始碼採用 **MIT** 授權（見 [`LICENSE`](LICENSE)）。內建與下載的**素材**（VRM 模型、動畫）為第三方
作品，依其各自條款（見 [`ATTRIBUTION.md`](ATTRIBUTION.md)）。內建的預設角色（**AvatarSample_A**，VRoid）
不在 MIT 授權範圍內，而是依 VRoid 範例模型條款散布，允許自由轉散布；選用的 **Alicia Solid** 模型則僅供
下載，本專案不會轉散布。
