#!/usr/bin/env python3
"""Draw kbflash's README/site media as animated SVGs, with kbflash's real timing.
python3 scripts/make-media.py   ->  docs/banner.svg, docs/media/{lit,dark,idle}.svg
"""
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "docs"

# MacBook-ish layout: rows of key widths in key units (1u = 44px incl. gap).
ROWS = [
    [1.5] + [1.0] * 12 + [1.0],                    # esc, F1-F12, Touch ID
    [1.0] * 13 + [1.5],                            # ` 1-0 - = delete
    [1.5] + [1.0] * 12 + [1.0],                    # tab q-p [ ] \
    [1.75] + [1.0] * 11 + [1.75],                  # caps a-l ; ' return
    [2.25] + [1.0] * 10 + [2.25],                  # shift z-/ shift
    [1.0, 1.0, 1.0, 1.25, 5.0, 1.25, 1.0, 1.0, 1.0],  # fn ctrl opt cmd space cmd opt arrows
]
U, GAP = 44, 6


def keyboard(x0, y0, scale=1.0):
    u, gap, parts = U * scale, GAP * scale, []
    for r, row in enumerate(ROWS):
        x, h = x0, (u - gap) * (0.62 if r == 0 else 1.0)
        y = y0 + (0 if r == 0 else (u - gap) * 0.62 + gap + (r - 1) * u)
        fit = 15.0 / sum(row)  # every row spans the same width, like the real thing
        for w in row:
            parts.append((x, y, w * fit * u - gap, h))
            x += w * fit * u
    return parts


def keys_svg(parts, cls):
    rects = "".join(f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" rx="{5:.0f}"/>' for x, y, w, h in parts)
    # legend glow: a small bar on each key, plus a blurred copy for the halo
    glyphs = "".join(f'<rect x="{x + w / 2 - 5:.1f}" y="{y + h / 2 - 2:.1f}" width="10" height="4" rx="2"/>' for x, y, w, h in parts)
    halo = "".join(f'<rect x="{x + 3:.1f}" y="{y + 3:.1f}" width="{w - 6:.1f}" height="{h - 6:.1f}" rx="4"/>' for x, y, w, h in parts)
    return (f'<g fill="#232327" stroke="#36363c" stroke-width="1">{rects}</g>'
            f'<g class="{cls}"><g fill="#ffe7c2" opacity=".55" filter="url(#blur)">{halo}</g>'
            f'<g fill="#fff6e6">{glyphs}</g></g>')


def keyframes(name, steps):
    """steps: [(level 0-1, seconds held)] -> CSS keyframes with instant switches (fadeSpeed 0)."""
    total = sum(s for _, s in steps)
    t, frames = 0.0, []
    for lvl, s in steps:
        a, b = 100 * t / total, 100 * (t + s) / total
        frames.append(f"{a:.2f}%,{max(a, b - 0.01):.2f}%{{opacity:{lvl}}}")
        t += s
    return f"@keyframes {name}{{{''.join(frames)}}}", total


def flash(lvl, n=3, on=0.15, off=0.15):
    hi = lvl if lvl >= 0.5 else 1.0
    seq = [(0, off), (hi, on)] * n
    return seq + ([(0, off)] if hi != lvl else []) + [(lvl, 0.01)]


SCENES = {  # what each scene's keyboard does, start to loop
    "lit": [(0.7, 1.6)] + flash(0.7) + [(0.7, 1.6)],
    "dark": [(0.0, 1.6)] + flash(0.0) + [(0.0, 1.6)],
    "idle": [(0.0, 1.6), (0.7, 0.4)] + flash(0.7) + [(0.7, 0.5), (0.35, 0.3), (0.0, 1.4)],
}
LABELS = {
    "lit": "Lit: dips off and back to your level",
    "dark": "Dark: pulses to 100% and back to dark",
    "idle": "Timed out: wakes at your level, flashes, then sleeps",
}

DEFS = '<defs><filter id="blur" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="5"/></filter></defs>'
FONT = "-apple-system,BlinkMacSystemFont,'SF Pro Text','Helvetica Neue',sans-serif"


def scene(name):
    css, total = keyframes(name, SCENES[name])
    parts = keyboard(28, 28)
    w = max(x + pw for x, _, pw, _ in parts) + 28
    h = max(y + ph for _, y, _, ph in parts) + 28
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w:.0f} {h:.0f}" width="{w:.0f}" height="{h:.0f}" role="img" aria-label="{LABELS[name]}">'
            f'<style>{css}.k{{animation:{name} {total:.2f}s linear infinite}}</style>{DEFS}'
            f'<rect width="100%" height="100%" rx="22" fill="#141417"/>{keys_svg(parts, "k")}</svg>')


def banner():
    css, total = keyframes("b", SCENES["lit"])
    parts = keyboard(664, 96, 0.82)
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1280 400" width="1280" height="400" role="img" '
            f'aria-label="kbflash: your MacBook keyboard, as a status light. It flashes when your agent, build or script is done">'
            f'<style>{css}.k{{animation:b {total:.2f}s linear infinite}}</style>{DEFS}'
            f'<defs><radialGradient id="g" cx="78%" cy="55%" r="55%"><stop offset="0" stop-color="#3a2f22"/><stop offset="1" stop-color="#111114"/></radialGradient></defs>'
            f'<rect width="1280" height="400" rx="28" fill="url(#g)"/>'
            f'<text x="72" y="168" font-family="{FONT}" font-size="76" font-weight="700" fill="#f5f5f7" letter-spacing="-2">kbflash</text>'
            f'<text x="74" y="222" font-family="{FONT}" font-size="26" fill="#b8b8c0">Your keyboard, as a status light.</text>'
            f'<text x="74" y="258" font-family="{FONT}" font-size="26" fill="#b8b8c0">Flashes when Claude, Codex or a long build is done.</text>'
            f'<text x="74" y="330" font-family="{FONT}" font-size="18" fill="#8a8a94">Free and open source · Your own patterns · No app to run</text>'
            f'<rect x="640" y="72" width="588" height="256" rx="20" fill="#141417" opacity=".85"/>'
            f'{keys_svg(parts, "k")}</svg>')


if __name__ == "__main__":
    (OUT / "media").mkdir(parents=True, exist_ok=True)
    (OUT / "banner.svg").write_text(banner())
    for name in SCENES:
        (OUT / "media" / f"{name}.svg").write_text(scene(name))
    # self-check: every scene ends where it started (a flash always puts your level back)
    for name, seq in SCENES.items():
        assert seq[0][0] == seq[-1][0] or name == "idle", name
    print("wrote", sorted(p.name for p in OUT.rglob("*.svg")))
