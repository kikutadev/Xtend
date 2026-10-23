#!/usr/bin/env python3
"""Build promotional screenshots from genuine Xtend UI captures."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "docs/images/app-store"
SRC = OUT / "source"
FONT_REG = "/System/Library/Fonts/ヒラギノ角ゴシック W3.ttc"
FONT_BOLD = "/System/Library/Fonts/ヒラギノ角ゴシック W7.ttc"
W, H = 1206, 2622

def font(size, bold=False):
    return ImageFont.truetype(FONT_BOLD if bold else FONT_REG, size)

def mask(size, radius):
    image = Image.new("L", size)
    ImageDraw.Draw(image).rounded_rectangle(
        (0, 0, size[0] - 1, size[1] - 1), radius=radius, fill=255)
    return image

designs = [
    ("02-add-extensions.png", "extension-install.png", "#E9F6F2", "#12243B",
     "#486579", "#238E86", ["Chrome拡張機能を", "iPhoneに追加"], "Web Store・ZIPからインストール"),
    ("03-manage-extensions.png", "extension-manager.png", "#E9EDF6", "#12243B",
     "#52627B", "#258E95", ["追加した拡張機能を", "設定・管理"], "一覧表示・削除・再読み込み"),
]
logo = Image.open(ROOT / "Xtend/Resources/Assets.xcassets/XtendBrand.imageset/Icon.png").convert("RGB")
logo = logo.resize((78, 78), Image.Resampling.LANCZOS)

for filename, source, bg, ink, muted, accent, lines, note in designs:
    canvas = Image.new("RGB", (W, H), bg)
    d = ImageDraw.Draw(canvas)
    canvas.paste(logo, (93, 80), mask(logo.size, 17))
    d.text((192, 91), "Xtend", font=font(46, True), fill=ink)
    y = 212
    for line in lines:
        d.text((94, y), line, font=font(106 if len(lines) == 1 else 80, True), fill=ink)
        y += 113
    d.text((95, 372 if len(lines) == 1 else 454), note, font=font(40), fill=muted)
    d.rounded_rectangle((95, 559, 195, 571), radius=6, fill=accent)

    original = Image.open(SRC / source).convert("RGB")
    assert original.size == (W, H), (source, original.size)
    screen_width = 1004
    screen_height = round(screen_width * H / W)
    screen = original.resize((screen_width, screen_height), Image.Resampling.LANCZOS)
    x, top = (W - screen_width) // 2, 622

    shadow = Image.new("RGBA", (W, H))
    backdrop = Image.new("RGBA", (screen_width + 32, screen_height + 32),
                         (8, 13, 29, 105))
    shadow.paste(backdrop, (x - 16, top + 25), mask(backdrop.size, 104))
    shadow = shadow.filter(ImageFilter.GaussianBlur(34))
    composite = Image.alpha_composite(canvas.convert("RGBA"), shadow)
    frame = Image.new("RGBA", (screen_width + 12, screen_height + 12),
                       (18, 25, 38, 255))
    composite.paste(frame, (x - 6, top - 6), mask(frame.size, 99))
    composite.paste(screen, (x, top), mask(screen.size, 90))
    output = composite.convert("RGB")
    output.save(OUT / filename, optimize=True)
    print(filename, output.size, (OUT / filename).stat().st_size)

preview = Image.new("RGB", (17 + 392 * len(designs) + 3, 846), "#E7EAF0")
for i, item in enumerate(designs):
    thumb = Image.open(OUT / item[0]).convert("RGB")
    thumb.thumbnail((370, 804), Image.Resampling.LANCZOS)
    preview.paste(thumb, (17 + i * 392, 20))
preview.save(OUT / "preview.jpg", quality=86)
print("preview.jpg")
