#!/usr/bin/env python3
"""Synthesize the game's SFX set into assets/sfx/*.wav.

Cartoon-friendly sounds built from first principles — noise bursts, damped
sines, Karplus-Strong plucks — tuned for the WW look: soft, woody, playful.
Deterministic (seeded), CC0-by-construction, regenerate any time with:

    python3 tools/make_sfx.py
"""

import wave
from pathlib import Path

import numpy as np
from scipy import signal

SR = 44100
OUT = Path(__file__).resolve().parents[1] / "assets" / "sfx"
rng = np.random.default_rng(7)


def t(dur):
	return np.linspace(0, dur, int(SR * dur), endpoint=False)


def env(n, attack=0.004, decay=0.12):
	"""Exponential attack-decay envelope over n samples."""
	a = int(SR * attack)
	e = np.ones(n)
	e[:a] = np.linspace(0, 1, a) if a > 0 else 1
	d = np.exp(-np.arange(n - a) / (SR * decay))
	e[a:] = d
	return e


def lowpass(x, hz, order=4):
	b, a = signal.butter(order, hz / (SR / 2), "low")
	return signal.lfilter(b, a, x)


def highpass(x, hz, order=4):
	b, a = signal.butter(order, hz / (SR / 2), "high")
	return signal.lfilter(b, a, x)


def bandpass(x, lo, hi, order=3):
	b, a = signal.butter(order, [lo / (SR / 2), hi / (SR / 2)], "band")
	return signal.lfilter(b, a, x)


def knock(freq, dur=0.09, noise_amt=0.4, decay=0.035):
	"""Woodblock-ish knock: resonant sine + filtered noise transient."""
	n = int(SR * dur)
	tt = np.arange(n) / SR
	tone = np.sin(2 * np.pi * freq * tt) * np.exp(-tt / decay)
	nz = bandpass(rng.normal(0, 1, n), freq * 0.7, freq * 2.5) * np.exp(-tt / 0.012)
	return tone + nz * noise_amt


def karplus(freq, dur=0.6, bright=0.5):
	"""Karplus-Strong plucked string."""
	n = int(SR * dur)
	period = int(SR / freq)
	buf = rng.normal(0, 1, period)
	out = np.zeros(n)
	for i in range(n):
		out[i] = buf[i % period]
		buf[i % period] = (buf[i % period] + buf[(i + 1) % period]) * 0.5 * (0.994 + 0.006 * bright)
	return out * env(n, 0.001, dur * 0.4)


def pitch_sweep(f0, f1, dur):
	tt = t(dur)
	freq = np.linspace(f0, f1, len(tt))
	phase = 2 * np.pi * np.cumsum(freq) / SR
	return np.sin(phase)


def add_at(x, start, d):
	"""Overlay d into x at start, clipping to x's length."""
	end = min(len(x), start + len(d))
	x[start:end] += d[: end - start]


def normalize(x, peak=0.85):
	m = np.max(np.abs(x))
	return x * (peak / m) if m > 0 else x


def save(name, x, peak=0.85):
	x = normalize(np.asarray(x, dtype=np.float64), peak)
	data = (x * 32767).astype(np.int16)
	OUT.mkdir(parents=True, exist_ok=True)
	with wave.open(str(OUT / f"{name}.wav"), "wb") as w:
		w.setnchannels(1)
		w.setsampwidth(2)
		w.setframerate(SR)
		w.writeframes(data.tobytes())
	print(f"  {name}.wav  ({len(x) / SR:.2f}s)")


def main():
	print("Synthesizing SFX:")

	# Dig: soft soil thud + scatter.
	n = int(SR * 0.22)
	thud = np.sin(2 * np.pi * 85 * t(0.22)) * env(n, 0.002, 0.06)
	soil = lowpass(rng.normal(0, 1, n), 900) * env(n, 0.01, 0.09) * 0.5
	save("dig", thud + soil)

	# Chop: two woody knocks.
	gap = np.zeros(int(SR * 0.05))
	save("chop", np.concatenate([knock(720), gap, knock(520, dur=0.12) * 1.1]))

	# Stone: lower, harder knock.
	save("stone", knock(310, dur=0.16, noise_amt=0.7, decay=0.05))

	# Swing: whoosh (bandpass noise, mid sweep via two stages).
	n = int(SR * 0.24)
	nz = rng.normal(0, 1, n)
	wh = bandpass(nz, 350, 900) * env(n, 0.05, 0.08)
	wh += bandpass(nz, 700, 1600) * env(n, 0.10, 0.06) * 0.7
	save("swing", wh)

	# Throw: rising whoosh.
	n = int(SR * 0.28)
	nz = bandpass(rng.normal(0, 1, n), 400, 2400)
	lfo = np.linspace(0.3, 1.0, n)
	save("throw", nz * env(n, 0.03, 0.12) * lfo)

	# Hit: punchy pitch-drop + click.
	body = pitch_sweep(190, 55, 0.13) * env(int(SR * 0.13), 0.001, 0.05)
	click = highpass(rng.normal(0, 1, int(SR * 0.02)), 2000) * env(int(SR * 0.02), 0.0005, 0.006)
	x = np.zeros(int(SR * 0.15))
	x[: len(body)] += body
	x[: len(click)] += click * 0.6
	save("hit", x)

	# Splash: shimmer burst + droplets.
	n = int(SR * 0.5)
	sh = highpass(rng.normal(0, 1, n), 1200) * env(n, 0.004, 0.16)
	for i in range(4):
		f = 900 - i * 140
		st = int(SR * (0.10 + i * 0.07))
		d = pitch_sweep(f, f * 0.6, 0.07) * env(int(SR * 0.07), 0.002, 0.025) * 0.35
		add_at(sh, st, d)
	save("splash", sh)

	# Card: paper flick.
	n = int(SR * 0.09)
	save("card", bandpass(rng.normal(0, 1, n), 1800, 6000) * env(n, 0.004, 0.025))

	# Build: hammer double-knock, low and friendly.
	gap = np.zeros(int(SR * 0.09))
	save("build", np.concatenate([knock(240, dur=0.13, decay=0.05),
		gap, knock(300, dur=0.15, decay=0.06) * 1.1]))

	# Ballista: string pluck (Karplus-Strong) + frame thunk.
	pluck = karplus(82, 0.55, bright=0.8)
	thunk = knock(150, dur=0.12, noise_amt=0.8, decay=0.045)
	x = pluck.copy()
	x[: len(thunk)] += thunk * 0.9
	save("ballista", x)

	# Death: descending womp.
	n = int(SR * 0.45)
	save("death", lowpass(pitch_sweep(260, 70, 0.45), 800) * env(n, 0.01, 0.18))

	# Reward: little chime arpeggio.
	notes = [1046.5, 1318.5, 1568.0]
	n = int(SR * 0.45)
	x = np.zeros(n)
	for i, f in enumerate(notes):
		st = int(SR * 0.08 * i)
		d = np.sin(2 * np.pi * f * t(0.3)) * env(int(SR * 0.3), 0.002, 0.10) * 0.5
		add_at(x, st, d)
	save("reward", x)

	# Victory: major sting.
	chord = [523.25, 659.25, 783.99, 1046.5]
	n = int(SR * 1.1)
	x = np.zeros(n)
	for i, f in enumerate(chord):
		st = int(SR * 0.09 * i)
		d = np.sin(2 * np.pi * f * t(0.9)) * env(int(SR * 0.9), 0.004, 0.35) * 0.4
		add_at(x, st, d)
	save("victory", x)

	# Quake: long low rumble with tremolo.
	n = int(SR * 1.3)
	rum = lowpass(rng.normal(0, 1, n), 140)
	trem = 0.6 + 0.4 * np.sin(2 * np.pi * 9 * t(1.3))
	save("quake", rum * trem * env(n, 0.08, 0.5))

	# Step: tiny soft tick.
	n = int(SR * 0.05)
	save("step", lowpass(rng.normal(0, 1, n), 600) * env(n, 0.002, 0.015), peak=0.5)

	# UI click.
	save("click", knock(950, dur=0.05, noise_amt=0.3, decay=0.012), peak=0.6)

	# Ambient: 14s seamless wind loop (crossfaded tail).
	n = int(SR * 14.0)
	wind = lowpass(rng.normal(0, 1, n), 420, order=2)
	lfo = 0.55 + 0.45 * np.sin(2 * np.pi * 0.11 * t(14.0) + 1.3) * np.sin(2 * np.pi * 0.043 * t(14.0))
	wind *= lfo
	xf = int(SR * 1.5)
	fade = np.linspace(0, 1, xf)
	wind[:xf] = wind[:xf] * fade + wind[-xf:] * (1 - fade)
	wind = wind[:-xf]
	save("ambient", wind, peak=0.30)

	print("Done.")


if __name__ == "__main__":
	main()
