#!/usr/bin/env python3
"""Sanity checks for processed (background-removed) art in assets/cards/.

The art pipeline runs this after remove_bg.py to catch silent failures
before an asset ever reaches the game:
  - subject erased (the U^2-Net-ate-the-trunk failure): opaque % too low
  - background NOT removed: opaque % too high / leftover chroma green
  - subject clipped at the frame edge
  - subject badly off-centre

Usage:
    python3 tools/check_asset.py earth.png tree_1.png      # named assets
    python3 tools/check_asset.py --all                     # everything

Exit code 0 = all pass; 1 = any fail. Prints one JSON line per asset.
"""

import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "assets" / "cards"

# Outside these bounds something is wrong for a floating game asset.
MIN_OPAQUE_FRAC = 0.04     # below: subject got erased
MAX_OPAQUE_FRAC = 0.80     # above: background didn't key out
MAX_GREEN_FRAC = 0.005     # leftover chroma-green among the opaque pixels
MAX_CENTROID_DRIFT = 0.22  # fraction of width the subject may sit off-centre
EDGE_TOUCH_LIMIT = 0.25    # fraction of an edge the subject may touch
                           # (tall trees legitimately touch top/bottom a bit)


def check(path: Path) -> dict:
	img = Image.open(path).convert("RGBA")
	arr = np.array(img)
	h, w = arr.shape[:2]
	alpha = arr[:, :, 3]
	opaque = alpha > 32
	result = {"asset": path.name, "size": [w, h], "checks": {}, "pass": True}

	def fail(name: str, detail: str) -> None:
		result["checks"][name] = detail
		result["pass"] = False

	def ok(name: str) -> None:
		result["checks"][name] = "ok"

	frac = float(opaque.mean())
	result["opaque_frac"] = round(frac, 4)
	if frac < MIN_OPAQUE_FRAC:
		fail("subject_present", f"only {frac:.1%} opaque — subject likely erased")
	elif frac > MAX_OPAQUE_FRAC:
		fail("background_removed", f"{frac:.1%} opaque — background likely intact")
	else:
		ok("subject_present")
		ok("background_removed")

	# Leftover chroma green among opaque pixels (halo / failed key).
	rgb = arr[:, :, :3].astype(int)
	greenish = (rgb[:, :, 1] > 180) & (rgb[:, :, 0] < 100) & (rgb[:, :, 2] < 100)
	green_frac = float((greenish & opaque).sum()) / max(1, int(opaque.sum()))
	result["green_frac"] = round(green_frac, 5)
	if green_frac > MAX_GREEN_FRAC:
		fail("no_green_halo", f"{green_frac:.2%} of subject is chroma green")
	else:
		ok("no_green_halo")

	if opaque.any():
		ys, xs = np.where(opaque)
		bbox = [int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max())]
		result["bbox"] = bbox
		# Centroid drift from frame centre.
		cx = float(xs.mean()) / w - 0.5
		result["centroid_dx"] = round(cx, 3)
		if abs(cx) > MAX_CENTROID_DRIFT:
			fail("centred", f"subject centroid {cx:+.0%} off-centre horizontally")
		else:
			ok("centred")
		# Clipping: how much of each frame edge does the subject touch?
		touches = {
			"left": float((xs <= 1).sum()) / h,
			"right": float((xs >= w - 2).sum()) / h,
			"top": float((ys <= 1).sum()) / w,
			"bottom": float((ys >= h - 2).sum()) / w,
		}
		clipped = [e for e, v in touches.items() if v > EDGE_TOUCH_LIMIT]
		if clipped:
			fail("not_clipped", f"subject clipped at: {', '.join(clipped)}")
		else:
			ok("not_clipped")
	return result


def main() -> int:
	args = sys.argv[1:]
	if "--all" in args:
		targets = sorted(p for p in OUT.glob("*.png") if not p.name.startswith("_"))
	else:
		targets = [OUT / a for a in args]
	all_pass = True
	for t in targets:
		if not t.exists():
			print(json.dumps({"asset": t.name, "pass": False,
					"checks": {"exists": "file not found"}}))
			all_pass = False
			continue
		r = check(t)
		print(json.dumps(r))
		all_pass = all_pass and r["pass"]
	return 0 if all_pass else 1


if __name__ == "__main__":
	sys.exit(main())
