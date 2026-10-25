#!/usr/bin/env python3
"""Validate visual outcomes of XtendSwipeUITests screenshots from xcresulttool.

Usage:
  xcrun xcresulttool export attachments --path .build/SwipeEvidence.xcresult \\
    --output-path .build/SwipeEvidenceAttachments
  python3 scripts/verify-swipe-evidence.py .build/SwipeEvidenceAttachments

Pillow is required locally; screenshots must come from the iPhone 17 Pro
390/402pt mobile home layout with the X light theme.
"""
import json
import sys
from pathlib import Path
from PIL import Image


def snapshots(path: Path):
    data = json.loads((path / "manifest.json").read_text())
    entries = data[0]["attachments"]
    return {
        item["suggestedHumanReadableName"].split("_")[0]: Image.open(
            path / item["exportedFileName"]
        ).convert("RGB")
        for item in entries
    }


def underline(image: Image.Image) -> float | None:
    w, h = image.size
    matches = []
    for y in range(int(h * .107), int(h * .126)):
        for x in range(int(w * .03), int(w * .78)):
            r, g, b = image.getpixel((x, y))
            if 10 <= r < 70 and 125 < g < 195 and b > 215 and b > g + 40:
                matches.append(x)
    return sum(matches) / len(matches) / w if len(matches) >= 20 else None


def overlay_luminance(image: Image.Image) -> float:
    # X mobile profile drawer dims the otherwise white upper-right X header.
    w, h = image.size
    points = [
        image.getpixel((x, y))
        for y in range(int(h * .045), int(h * .073))
        for x in range(int(w * .72), int(w * .80))
    ]
    return sum(sum(rgb) / 3 for rgb in points) / len(points)


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: verify-swipe-evidence.py ATTACHMENTS_DIR")
    images = snapshots(Path(sys.argv[1]))
    labels = ("01-before", "02-timeline-left", "03-timeline-right", "04-menu-open", "05-menu-close")
    missing = set(labels) - images.keys()
    if missing:
        raise SystemExit(f"Missing screenshots: {sorted(missing)}")

    first, following, back = (underline(images[name]) for name in labels[:3])
    opened, closed = (overlay_luminance(images[name]) for name in labels[3:])
    print(f"Timeline underline (normalized x): before={first}, left={following}, right={back}")
    print(f"Drawer overlay brightness: open={opened:.1f}, closed={closed:.1f}")
    checks = {
        "For you initially selected": first is not None and first < .20,
        "left swipe selects Following": following is not None and following > .22,
        "right swipe selects For you": back is not None and back < .20,
        "right edge gesture opens drawer": opened < 210,
        "left swipe closes drawer": closed > 220,
    }
    for label, passed in checks.items():
        print(("PASS" if passed else "FAIL") + " " + label)
    if not all(checks.values()):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
