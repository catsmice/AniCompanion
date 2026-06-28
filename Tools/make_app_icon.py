#!/usr/bin/env python3
"""Generate an original, MIT-clean AniCompanion app icon.

Concept: a friendly companion mascot (a simple kawaii face) on a soft violet
gradient squircle — evokes an AI character chat companion.
Fully original geometry, no character likeness, no third-party assets.
"""
import os, math
from PIL import Image, ImageDraw

# Default to the app's icon set; override with ICON_OUT=/some/dir.
_DEFAULT_OUT = os.path.normpath(os.path.join(
    os.path.dirname(__file__), "..",
    "AniCompanion/Resources/Assets.xcassets/AppIcon.appiconset"))
OUT_DIR = os.environ.get("ICON_OUT", _DEFAULT_OUT)
BASE = 1024
SS = 4                      # supersample factor for crisp anti-aliasing
S = BASE * SS

def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(len(a)))

def rounded_mask(size, radius):
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return m

# ---- Canvas ----
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

# ---- Gradient background (diagonal) ----
top = (143, 124, 255)      # #8F7CFF
bot = (84, 56, 214)        # #5438D6
grad = Image.new("RGBA", (S, S))
gp = grad.load()
for y in range(S):
    # diagonal-ish: blend mostly by y with a slight x influence
    row = lerp(top, bot, y / (S - 1))
    for x in range(S):
        gp[x, y] = row + (255,)

# soft radial highlight in the upper-left for depth
hl = Image.new("L", (S, S), 0)
hd = ImageDraw.Draw(hl)
hcx, hcy, hr = S * 0.34, S * 0.28, S * 0.62
hd.ellipse([hcx - hr, hcy - hr, hcx + hr, hcy + hr], fill=70)
hl = hl.resize((S, S))
white = Image.new("RGBA", (S, S), (255, 255, 255, 255))
grad = Image.composite(Image.blend(grad, white, 0.18), grad, hl)

# ---- Squircle: macOS-style rounded rect with margin ----
# Apple macOS grid: artwork ~824/1024 wide, ~100px margin, corner ~22.37%.
margin = int(S * (100 / 1024))
inner = S - 2 * margin
radius = int(inner * 0.2237)
mask = rounded_mask(inner, radius)

squircle = Image.new("RGBA", (S, S), (0, 0, 0, 0))
squircle.paste(grad.crop((0, 0, inner, inner)), (margin, margin), mask)

# subtle drop shadow under the squircle
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
sd = ImageDraw.Draw(shadow)
soff = int(S * 0.012)
sd.rounded_rectangle(
    [margin, margin + soff, margin + inner, margin + inner + soff],
    radius=radius, fill=(30, 20, 70, 90),
)
try:
    from PIL import ImageFilter
    shadow = shadow.filter(ImageFilter.GaussianBlur(S * 0.012))
except Exception:
    pass
img = Image.alpha_composite(img, shadow)
img = Image.alpha_composite(img, squircle)

draw = ImageDraw.Draw(img)

# ---- Mascot face ----
# white rounded "head" centered, slightly above middle
cx = S * 0.5
cy = S * 0.535
hw = S * 0.30          # half-width of head
hh = S * 0.275         # half-height
hrad = int(hw * 0.62)
head_box = [cx - hw, cy - hh, cx + hw, cy + hh]

# head soft shadow
hs = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(hs).rounded_rectangle(
    [head_box[0], head_box[1] + S * 0.012, head_box[2], head_box[3] + S * 0.012],
    radius=hrad, fill=(40, 25, 90, 70))
try:
    hs = hs.filter(ImageFilter.GaussianBlur(S * 0.010))
except Exception:
    pass
img = Image.alpha_composite(img, hs)
draw = ImageDraw.Draw(img)

HEAD = (252, 251, 255, 255)
draw.rounded_rectangle(head_box, radius=hrad, fill=HEAD)

INK = (74, 58, 150, 255)

# ---- Eyes ----
eye_dx = S * 0.115
eye_y = cy - S * 0.01
eye_rx = S * 0.034
eye_ry = S * 0.050
for sgn in (-1, 1):
    ex = cx + sgn * eye_dx
    draw.ellipse([ex - eye_rx, eye_y - eye_ry, ex + eye_rx, eye_y + eye_ry], fill=INK)
    # eye glint
    gr = eye_rx * 0.42
    draw.ellipse([ex - eye_rx * 0.1, eye_y - eye_ry * 0.55,
                  ex - eye_rx * 0.1 + gr, eye_y - eye_ry * 0.55 + gr],
                 fill=(255, 255, 255, 235))

# ---- Cheeks ----
cheek = Image.new("RGBA", (S, S), (0, 0, 0, 0))
cd = ImageDraw.Draw(cheek)
chk_dx = S * 0.175
chk_y = cy + S * 0.055
chk_r = S * 0.030
for sgn in (-1, 1):
    chx = cx + sgn * chk_dx
    cd.ellipse([chx - chk_r, chk_y - chk_r * 0.7, chx + chk_r, chk_y + chk_r * 0.7],
               fill=(255, 150, 175, 150))
img = Image.alpha_composite(img, cheek)
draw = ImageDraw.Draw(img)

# ---- Smile (gentle arc) ----
sm_w = S * 0.075
sm_y = cy + S * 0.045
draw.arc([cx - sm_w, sm_y - sm_w * 0.6, cx + sm_w, sm_y + sm_w * 0.9],
         start=20, end=160, fill=INK, width=int(S * 0.015))

# ---- Downscale master + export all sizes ----
master = img.resize((BASE, BASE), Image.LANCZOS)

sizes = {
    "icon_16x16.png": 16, "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32, "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128, "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256, "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512, "icon_512x512@2x.png": 1024,
}
for name, px in sizes.items():
    master.resize((px, px), Image.LANCZOS).save(os.path.join(OUT_DIR, name))
# also a preview master
master.save(os.path.join(os.environ.get("PREVIEW_DIR", OUT_DIR), "icon_master_1024.png"))
print("wrote", len(sizes), "icon sizes to", OUT_DIR)
