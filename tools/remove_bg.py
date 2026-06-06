#!/usr/bin/env python3
"""Background removal for ASAS card art.

Reads raw PNGs from assets/cards/raw/, removes their background, and writes
transparent PNGs to assets/cards/ (the in-game asset folder).

Card art (`spade_blade.png`, `operator.png`, ...) uses U^2-Net (via rembg)
for ML-based subject extraction — handles painterly soft edges cleanly.

`_frame.png` runs the same ML pass to strip the off-white margins, then keys
out the pure-magenta center (#FF00FF) so the art window becomes transparent.

Usage:
    python3 tools/remove_bg.py                  # process every PNG in raw/
    python3 tools/remove_bg.py spade_blade.png  # process one file by name
"""

import sys
from io import BytesIO
from pathlib import Path

import numpy as np
from PIL import Image
from rembg import new_session, remove

ROOT = Path(__file__).resolve().parents[1]
RAW = ROOT / "assets" / "cards" / "raw"
OUT = ROOT / "assets" / "cards"


def remove_magenta(img: Image.Image) -> Image.Image:
	"""Make pixels in the pure-magenta range fully transparent. Used to punch
	out the frame's center art window placeholder (#FF00FF)."""
	img = img.convert("RGBA")
	arr = np.array(img)
	# Tolerant key: r,b high and g low covers anti-aliasing fringes too.
	mask = (arr[:, :, 0] > 200) & (arr[:, :, 1] < 60) & (arr[:, :, 2] > 200)
	arr[mask, 3] = 0
	return Image.fromarray(arr)


def process_one(path: Path, session) -> None:
	print(f"  {path.name}", end=" ... ", flush=True)
	raw_bytes = path.read_bytes()
	out_bytes = remove(raw_bytes, session=session)
	img = Image.open(BytesIO(out_bytes))
	if path.name == "_frame.png":
		img = remove_magenta(img)
	out_path = OUT / path.name
	img.save(out_path, format="PNG")
	print(f"-> {out_path.relative_to(ROOT)} ({img.width}x{img.height})")


def main() -> int:
	OUT.mkdir(parents=True, exist_ok=True)
	RAW.mkdir(parents=True, exist_ok=True)

	args = sys.argv[1:]
	if args:
		targets = []
		for a in args:
			p = Path(a)
			if not p.is_absolute():
				p = RAW / a
			if not p.exists():
				print(f"  not found: {p}", file=sys.stderr)
				return 1
			targets.append(p)
	else:
		targets = sorted(RAW.glob("*.png"))

	if not targets:
		print(f"No PNGs in {RAW.relative_to(ROOT)}. Drop generated images there and re-run.")
		return 0

	# u2net is the general-purpose default; ~170MB ONNX model downloads on first
	# use, then is cached under ~/.u2net/.
	session = new_session("u2net")
	print(f"Processing {len(targets)} file(s):")
	for t in targets:
		process_one(t, session)
	print("Done.")
	return 0


if __name__ == "__main__":
	sys.exit(main())
