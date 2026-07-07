# VRM model guide

AniCompanion renders any humanoid **VRM** avatar with [three-vrm](https://github.com/pixiv/three-vrm)
(VRM 0.x and 1.0). This covers the default model, using your own, and what a model needs for each feature.

## The default character

The default is **Alicia Solid (ニコニ立体ちゃん)**, © DWANGO Co., Ltd. Its license does **not** permit
redistribution, so it is **not bundled** — `scripts/download-model.sh` fetches it for your own local
use. See [`ATTRIBUTION.md`](../ATTRIBUTION.md) and
`AniCompanion/Resources/VRMModel/LICENSE-AliciaSolid.md`.

## Using your own VRM

1. Drop your `.vrm` file into `AniCompanion/Resources/VRMModel/`.
2. Open **Settings → Character** and set **VRM Model Filename** to your file name, e.g. `YourModel.vrm`.
   (Name the file `AliciaSolid.vrm` and you can skip this step.)
3. If the framing is off for your model's proportions, tune the camera live with the
   `W/S/A/D/Q/E/R/F` keys and set the result as the default in `ThreeVRMRenderView`.

## What a model needs

Every VRM is humanoid by spec, so posing, idle motion, and the skeletal gesture clips work with **any
valid model**. The rest degrades gracefully:

| Feature | Requires | If the model lacks it |
|---------|----------|-----------------------|
| Emotions (16 tags → expressions) | Standard expression presets **happy / angry / sad / relaxed** | Face stays neutral; everything else still works |
| Lip sync | The **`aa`** mouth viseme (optional ARKit / `jawOpen` PerfectSync gives finer motion) | Mouth doesn't move while speaking |
| Idle blink | The **blink** expression preset | No blinking |
| Hair / skirt physics | **Spring bones** | Hair and cloth stay static |

In short: **any humanoid VRM loads and animates**; the standard expression presets plus the `aa` viseme
unlock emotions and lip-sync. Richer models (more expressions, PerfectSync) can be given finer mappings
in the three-vrm scene (`AniCompanion/Resources/ThreeVRM/vrm_scene.js`).
