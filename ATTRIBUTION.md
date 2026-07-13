# Attribution & Third-Party Assets

AniCompanion's source code is licensed under the MIT License (see `LICENSE`). The bundled
and downloaded **assets** below are third-party works under their own terms, **not** MIT.

## Code dependencies

| Dependency | License | Author | How it's used |
| ---------- | ------- | ------ | ------------- |
| [@pixiv/three-vrm](https://github.com/pixiv/three-vrm) | MIT | pixiv | VRM loading/rendering in the WKWebView scene; loaded via CDN (jsDelivr) in `vrm_scene.js`. |
| [three.js](https://github.com/mrdoob/three.js) | MIT | three.js authors | WebGL engine underlying three-vrm; loaded via CDN (jsDelivr). |

Runtime services the app talks to (not bundled): a local **[Hermes Agent](https://github.com/NousResearch/hermes-agent)**
gateway (MIT) for chat, and **MiniMax** Speech-02-Turbo for TTS (the user supplies their own
API key). Speech-to-text uses Apple's on-device Speech framework.

## Default character model — AvatarSample_A (VRoid)

- **Author:** VRoid (pixiv Inc.) — bundled as `AniCompanion/Resources/VRMModel/AvatarSample_A.vrm`,
  the default avatar shown out of the box.
- **Source:** VRoid Studio sample models · file mirror: https://github.com/madjin/vrm-samples
- **License (authoritative):** VRoid sample-model terms —
  https://vroid.pixiv.help/hc/en-us/articles/4402394424089-VRoidPreset-A-Z
  (embedded VRM meta: allowed user = *Everyone*, commercial use = *Allow*).
- **Terms in brief:** free use (incl. commercial) as an avatar in apps, **free redistribution
  permitted** — which is why it *can* be bundled here. **Restrictions we comply with:** it must not
  be redistributed for a fee, its license must not be changed to CC0, and it may not power a
  character-creation service. **Consequence for forks:** keep any redistribution of this file free.
- The model file is under VRoid's terms, **not** the app's MIT license.

## Optional character model — Alicia Solid (ニコニ立体ちゃん)

- **Copyright:** © DWANGO Co., Ltd.
- **Source:** https://3d.nicovideo.jp/alicia/
- **License (authoritative):** https://3d.nicovideo.jp/alicia/rule.html
- **Redistribution: NOT permitted.** Commercial use allowed for individuals / non-corporate
  groups only (corporations excluded). Modification allowed. Attribution not required.
- **Notes:** Because the model may not be redistributed, it is **not committed to this repo
  and not bundled in any release**. It is an *optional* alternative to the default: each user
  obtains it themselves (official download, or the `scripts/download-model.sh` convenience for
  their own local use). Full terms in `AniCompanion/Resources/VRMModel/LICENSE-AliciaSolid.md`.
  The project is effectively dual-licensed: code MIT, models under their own terms.

## App icon — `AniCompanion/Resources/Assets.xcassets/AppIcon.appiconset/`

Original artwork created for this project (a generated mascot mark) — **MIT**, no
third-party assets or character likenesses. Reproducible via `Tools/make_app_icon.py`
(requires Python + Pillow). The previous icon, derived from a purchased proprietary
character, was removed for the open-source release.

## Animation clips — `AniCompanion/Resources/Animations/*.json`

Files: `idle.json`, `nod.json`, `talk_gesture.json`, `think.json`, `wave.json`.

- **Provenance:** Retargeted from **Adobe Mixamo** animations onto the VRM skeleton, then
  baked to AniCompanion's JSON keyframe format via `Tools/export_animation.py` (Blender).
  The committed files are derived keyframe data (per-bone rotation tracks), not the
  original Mixamo `.fbx` source files.
- **Source:** https://www.mixamo.com — Adobe Mixamo.
- **Terms:** Mixamo animations are royalty-free for use in creative/commercial projects
  under Adobe's Mixamo terms. Adobe restricts redistribution of the *raw* Mixamo content
  as a standalone asset library; here the data is integrated into the application as
  retargeted, baked motion clips.
- **Regenerating:** To produce clips from a different (e.g. CC0) motion-capture source,
  retarget onto the VRM armature in Blender and run `Tools/export_animation.py` with
  `ANICOMPANION_ANIM_OUTPUT` pointing at this folder.
