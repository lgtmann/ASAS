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


def remove_green(img: Image.Image) -> Image.Image:
	"""Make pixels in the pure-chroma-green range fully transparent. Used as a
	cleanup pass on terrain art generated with a #00FF00 background — catches
	whatever fringe halo rembg's U^2-Net leaves behind."""
	img = img.convert("RGBA")
	arr = np.array(img)
	# Chroma key: g dominant, r and b both low. Same tolerance shape as magenta.
	mask = (arr[:, :, 1] > 180) & (arr[:, :, 0] < 100) & (arr[:, :, 2] < 100)
	arr[mask, 3] = 0
	return Image.fromarray(arr)


def is_clean_chroma_bg(img: Image.Image, threshold: float = 0.25) -> bool:
	"""True when at least `threshold` fraction of pixels are pure chroma green
	(#00FF00 family). Such inputs don't need U^2-Net — the chroma keyer alone
	produces a much cleaner result, and avoids U^2-Net's failure mode where
	thin subjects (tree trunks, ladders) get classified as background."""
	arr = np.array(img.convert("RGB"))
	mask = (arr[:, :, 1] > 180) & (arr[:, :, 0] < 100) & (arr[:, :, 2] < 100)
	return float(mask.mean()) > threshold


def process_one(path: Path, session) -> None:
	print(f"  {path.name}", end=" ... ", flush=True)
	raw_img = Image.open(path)
	if is_clean_chroma_bg(raw_img):
		# Skip the ML pass — let remove_green do all the work.
		print("[chroma-key path]", end=" ", flush=True)
		img = raw_img.convert("RGBA")
	else:
		raw_bytes = path.read_bytes()
		out_bytes = remove(raw_bytes, session=session)
		img = Image.open(BytesIO(out_bytes))
	if path.stem == "_frame":
		img = remove_magenta(img)
	else:
		# Terrain art is generated against a chroma-green background; scrub
		# any green fringe rembg left behind. Harmless on portraits — Grok
		# rarely paints subjects in saturated #00FF00.
		img = remove_green(img)
	# Always write PNG (alpha channel); rename .jpg/.jpeg sources accordingly.
	out_path = OUT / (path.stem + ".png")
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
		targets = sorted(
			p for ext in ("*.png", "*.jpg", "*.jpeg") for p in RAW.glob(ext)
		)

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
