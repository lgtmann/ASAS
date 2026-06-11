#!/usr/bin/env python3
"""Generate ASAS art via the Gemini image API (Nano Banana Pro).

Reads prompts from tools/art_prompts.json, composes shared style + subject,
calls generateContent with optional style-reference images, and writes the
result to assets/cards/raw/<name>.png ready for tools/remove_bg.py.

Usage:
    python3 tools/generate_asset.py earth                  # one asset by name
    python3 tools/generate_asset.py earth tree_1 unit_wolf # several
    python3 tools/generate_asset.py earth --ref assets/cards/raw/anchor.png
    python3 tools/generate_asset.py --prompt "..." --out raw/test.png

The API key comes from $GEMINI_API_KEY or the .env file at the repo root.
Aspect ratio is inferred from the prompt text ("Portrait 2:3" -> 2:3, else
1:1); override with --aspect.
"""

import argparse
import base64
import json
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RAW = ROOT / "assets" / "cards" / "raw"
PROMPTS = ROOT / "tools" / "art_prompts.json"
DEFAULT_MODEL = "gemini-3-pro-image"
API = "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"


def api_key() -> str:
	import os
	key = os.environ.get("GEMINI_API_KEY", "")
	if not key:
		env = ROOT / ".env"
		if env.exists():
			for line in env.read_text().splitlines():
				if line.startswith("GEMINI_API_KEY="):
					key = line.split("=", 1)[1].strip()
	if not key:
		sys.exit("No GEMINI_API_KEY in environment or .env")
	return key


def load_prompt(name: str) -> str:
	data = json.loads(PROMPTS.read_text())
	for a in data["assets"]:
		if a["name"] == name:
			return data["_shared_style"] + "\n\n" + a["prompt"]
	sys.exit(f"Asset '{name}' not found in {PROMPTS.name}")


def infer_aspect(prompt: str) -> str:
	return "2:3" if "2:3" in prompt else "1:1"


def image_part(path: Path) -> dict:
	mime = "image/png" if path.suffix.lower() == ".png" else "image/jpeg"
	return {"inline_data": {"mime_type": mime,
		"data": base64.b64encode(path.read_bytes()).decode()}}


def generate(prompt: str, out_path: Path, aspect: str, refs: list,
		model: str, key: str, attempts: int = 4) -> bool:
	parts = []
	if refs:
		for r in refs:
			parts.append(image_part(Path(r)))
		parts.append({"text":
			"Match the exact art style of the reference image(s) above — same "
			"rendering, same palette family, same outline weight, same cel "
			"shading. Then generate:\n\n" + prompt})
	else:
		parts.append({"text": prompt})

	body = {
		"contents": [{"parts": parts}],
		"generationConfig": {
			"responseModalities": ["IMAGE"],
			"imageConfig": {"aspectRatio": aspect},
		},
	}
	url = API.format(model=model) + f"?key={key}"
	payload = json.dumps(body).encode()

	for attempt in range(attempts):
		req = urllib.request.Request(url, data=payload,
			headers={"Content-Type": "application/json"})
		try:
			with urllib.request.urlopen(req, timeout=180) as resp:
				data = json.loads(resp.read())
		except urllib.error.HTTPError as e:
			detail = e.read().decode()[:300]
			# Unknown-field fallback: retry once without imageConfig.
			if e.code == 400 and "imageConfig" in detail and "imageConfig" in json.dumps(body):
				del body["generationConfig"]["imageConfig"]
				payload = json.dumps(body).encode()
				print(f"    (aspect config rejected; retrying without)")
				continue
			if e.code in (429, 500, 503) and attempt < attempts - 1:
				wait = 2 ** (attempt + 2)
				print(f"    HTTP {e.code}; retrying in {wait}s")
				time.sleep(wait)
				continue
			print(f"    FAILED: HTTP {e.code}: {detail}")
			return False
		except Exception as e:  # timeouts etc.
			if attempt < attempts - 1:
				print(f"    {type(e).__name__}; retrying")
				time.sleep(5)
				continue
			print(f"    FAILED: {e}")
			return False

		for cand in data.get("candidates", []):
			for part in cand.get("content", {}).get("parts", []):
				inline = part.get("inlineData") or part.get("inline_data")
				if inline and inline.get("data"):
					out_path.parent.mkdir(parents=True, exist_ok=True)
					out_path.write_bytes(base64.b64decode(inline["data"]))
					return True
		print(f"    no image in response (attempt {attempt + 1}); retrying")
		time.sleep(3)
	return False


def main() -> int:
	ap = argparse.ArgumentParser()
	ap.add_argument("names", nargs="*", help="asset names from art_prompts.json")
	ap.add_argument("--prompt", help="ad-hoc prompt instead of a named asset")
	ap.add_argument("--out", help="output path (ad-hoc mode)")
	ap.add_argument("--ref", action="append", default=[],
		help="style reference image path (repeatable)")
	ap.add_argument("--aspect", help="override aspect ratio, e.g. 2:3")
	ap.add_argument("--model", default=DEFAULT_MODEL)
	args = ap.parse_args()
	key = api_key()

	jobs = []
	if args.prompt:
		out = Path(args.out) if args.out else RAW / "adhoc.png"
		jobs.append((args.prompt, out))
	for n in args.names:
		jobs.append((load_prompt(n), RAW / f"{n}.png"))
	if not jobs:
		ap.error("give asset names or --prompt")

	failed = []
	for prompt, out in jobs:
		aspect = args.aspect or infer_aspect(prompt)
		print(f"  {out.stem} [{aspect}] ...", flush=True)
		t0 = time.time()
		if generate(prompt, out, aspect, args.ref, args.model, key):
			print(f"    -> {out.relative_to(ROOT)} ({time.time() - t0:.1f}s)")
		else:
			failed.append(out.stem)
	if failed:
		print(f"FAILED: {', '.join(failed)}")
		return 1
	print("All done.")
	return 0


if __name__ == "__main__":
	sys.exit(main())
