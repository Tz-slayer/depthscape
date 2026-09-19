#!/usr/bin/env python3
"""Render a self-contained HTML preview of the depth occlusion effect.

Running the DMS shell to look at a mask is a slow feedback loop, and it is the
only way to see the real compositing. This tool approximates the same layering
in a browser so a wallpaper can be checked in one command:

    tools/make-preview.py --wallpaper ~/Pictures/Wallpapers/some.png

The approximation is faithful in the part that matters — the foreground is the
wallpaper drawn again on top of the widget layer, cut out by the mask's alpha
channel, which is exactly what DepthForeground.qml does with MultiEffect.
"""

from __future__ import annotations

import argparse
import base64
import io
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

PREVIEW_MAX_WIDTH = 1400


def find_engine(explicit: str | None) -> Path:
    if explicit:
        return Path(explicit).expanduser().resolve()
    from_env = os.environ.get("DEPTHSCAPE_ENGINE")
    if from_env and Path(from_env).is_file():
        return Path(from_env)
    repo_root = Path(__file__).resolve().parent.parent
    for candidate in (
        repo_root / "engine/target/release/depthscape-engine",
        repo_root / "engine/target/debug/depthscape-engine",
    ):
        if candidate.is_file():
            return candidate
    found = shutil.which("depthscape-engine")
    if found:
        return Path(found)
    sys.exit("depthscape-engine not found; build it with `cargo build --release` in engine/")


def run_engine(engine: Path, wallpaper: Path, threshold: float, feather: float) -> dict:
    result = subprocess.run(
        [
            str(engine),
            "analyze",
            "--wallpaper",
            str(wallpaper),
            "--threshold",
            str(threshold),
            "--feather",
            str(feather),
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        sys.exit(f"engine failed: {result.stderr.strip()}")
    return json.loads(result.stdout.strip())


def to_data_uri(image, fmt: str, **kwargs) -> str:
    buffer = io.BytesIO()
    image.save(buffer, format=fmt, **kwargs)
    mime = "image/png" if fmt == "PNG" else "image/jpeg"
    return f"data:{mime};base64," + base64.b64encode(buffer.getvalue()).decode("ascii")


def scaled(image, max_width: int):
    from PIL import Image

    if image.width <= max_width:
        return image
    height = round(image.height * max_width / image.width)
    return image.resize((max_width, height), Image.Resampling.LANCZOS)


HTML = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Depthscape preview — {name}</title>
<style>
  :root {{ color-scheme: dark; }}
  * {{ box-sizing: border-box; }}
  body {{
    margin: 0; padding: 28px; background: #16161a; color: #e6e6ea;
    font-family: system-ui, -apple-system, "Segoe UI", sans-serif;
  }}
  h1 {{ font-size: 17px; font-weight: 500; margin: 0 0 4px; }}
  .meta {{ font-size: 13px; color: #9a9aa5; margin-bottom: 20px; }}
  .stage {{
    position: relative; width: 100%; max-width: {width_px}px; aspect-ratio: {ratio};
    border-radius: 14px; overflow: hidden; background: #000;
    box-shadow: 0 18px 50px rgba(0,0,0,.5);
  }}
  .layer {{ position: absolute; inset: 0; }}
  .wallpaper {{ background-image: url("{wallpaper}"); background-size: cover; background-position: center; }}
  .widgets {{ display: flex; flex-direction: column; align-items: center; padding-top: 7%; gap: 14px; }}
  .clock {{ font-size: clamp(38px, 7vw, 92px); font-weight: 300; letter-spacing: -0.02em; text-shadow: 0 2px 22px rgba(0,0,0,.55); }}
  .date {{ font-size: clamp(13px, 1.5vw, 19px); opacity: .88; text-shadow: 0 2px 14px rgba(0,0,0,.55); }}
  .cards {{ display: flex; gap: 14px; margin-top: 6px; }}
  .card {{
    min-width: 150px; padding: 13px 16px; border-radius: 14px;
    background: rgba(22,22,28,.42); border: 1px solid rgba(255,255,255,.16);
    backdrop-filter: blur(14px); text-shadow: 0 1px 10px rgba(0,0,0,.5);
  }}
  .card .k {{ font-size: 11px; letter-spacing: .08em; text-transform: uppercase; opacity: .68; }}
  .card .v {{ font-size: 21px; font-weight: 500; margin-top: 3px; }}
  .foreground {{
    background-image: url("{wallpaper}"); background-size: cover; background-position: center;
    -webkit-mask-image: url("{mask}"); mask-image: url("{mask}");
    -webkit-mask-size: cover; mask-size: cover;
    -webkit-mask-position: center; mask-position: center;
    -webkit-mask-mode: alpha; mask-mode: alpha;
    transition: opacity .18s ease;
  }}
  .stage.hide-foreground .foreground {{ opacity: 0; }}
  .stage.hide-widgets .widgets {{ opacity: 0; }}
  .controls {{ display: flex; flex-wrap: wrap; gap: 10px; margin-top: 18px; align-items: center; }}
  button {{
    font: inherit; font-size: 13px; padding: 8px 15px; border-radius: 9px; cursor: pointer;
    background: #26262e; color: #e6e6ea; border: 1px solid #3a3a44;
  }}
  button:hover {{ background: #30303a; }}
  button.on {{ background: #4c5bd4; border-color: #4c5bd4; }}
  .masks {{ display: flex; gap: 18px; margin-top: 22px; flex-wrap: wrap; }}
  .masks figure {{ margin: 0; }}
  .masks figcaption {{ font-size: 12px; color: #9a9aa5; margin-bottom: 7px; }}
  .masks img {{ width: 300px; border-radius: 9px; border: 1px solid #3a3a44; display: block; }}
  .checker {{
    background-image:
      linear-gradient(45deg, #2a2a32 25%, transparent 25%),
      linear-gradient(-45deg, #2a2a32 25%, transparent 25%),
      linear-gradient(45deg, transparent 75%, #2a2a32 75%),
      linear-gradient(-45deg, transparent 75%, #2a2a32 75%);
    background-size: 16px 16px;
    background-position: 0 0, 0 8px, 8px -8px, -8px 0;
    border-radius: 9px; display: inline-block; line-height: 0;
  }}
</style>
</head>
<body>
  <h1>Depthscape preview</h1>
  <div class="meta">
    {name} · {width}&times;{height} · threshold {threshold} · feather {feather}
    · analysis {elapsed} ms{cached}
  </div>

  <div class="stage" id="stage">
    <div class="layer wallpaper"></div>
    <div class="layer widgets">
      <div class="clock">14:32</div>
      <div class="date">Saturday, 19 September</div>
      <div class="cards">
        <div class="card"><div class="k">Weather</div><div class="v">26 &deg;C</div></div>
        <div class="card"><div class="k">Media</div><div class="v">Paused</div></div>
      </div>
    </div>
    <div class="layer foreground"></div>
  </div>

  <div class="controls">
    <button id="toggleForeground" class="on">Foreground layer</button>
    <button id="toggleWidgets" class="on">Widget layer</button>
    <span class="meta" style="margin:0">Toggle the foreground to see which widgets it covers.</span>
  </div>

  <div class="masks">
    <figure>
      <figcaption>Generated mask (alpha channel)</figcaption>
      <div class="checker"><img src="{mask}" alt="mask"></div>
    </figure>
  </div>

<script>
  const stage = document.getElementById('stage');
  const foreground = document.getElementById('toggleForeground');
  const widgets = document.getElementById('toggleWidgets');
  foreground.addEventListener('click', () => {{
    stage.classList.toggle('hide-foreground');
    foreground.classList.toggle('on', !stage.classList.contains('hide-foreground'));
  }});
  widgets.addEventListener('click', () => {{
    stage.classList.toggle('hide-widgets');
    widgets.classList.toggle('on', !stage.classList.contains('hide-widgets'));
  }});
</script>
</body>
</html>
"""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--wallpaper", required=True, type=Path)
    parser.add_argument("--threshold", type=float, default=0.30)
    parser.add_argument("--feather", type=float, default=0.08)
    parser.add_argument("--engine", default=None)
    parser.add_argument("--out", type=Path, default=Path("preview.html"))
    parser.add_argument("--max-width", type=int, default=PREVIEW_MAX_WIDTH)
    args = parser.parse_args()

    from PIL import Image

    wallpaper = args.wallpaper.expanduser().resolve()
    if not wallpaper.is_file():
        sys.exit(f"wallpaper not found: {wallpaper}")

    engine = find_engine(args.engine)
    outcome = run_engine(engine, wallpaper, args.threshold, args.feather)

    source = Image.open(wallpaper).convert("RGB")
    preview = scaled(source, args.max_width)
    mask = Image.open(outcome["maskPath"]).convert("RGBA")
    mask_preview = scaled(mask, args.max_width)

    html = HTML.format(
        name=wallpaper.name,
        width=outcome["width"],
        height=outcome["height"],
        ratio=f"{preview.width} / {preview.height}",
        width_px=preview.width,
        threshold=f"{args.threshold:.2f}",
        feather=f"{args.feather:.2f}",
        elapsed=outcome["elapsedMs"],
        cached=" · from cache" if outcome["maskCacheHit"] else "",
        wallpaper=to_data_uri(preview, "JPEG", quality=88),
        mask=to_data_uri(mask_preview, "PNG", optimize=True),
    )

    args.out.write_text(html, encoding="utf-8")
    size_mb = args.out.stat().st_size / 1024 / 1024
    print(f"wrote {args.out} ({size_mb:.1f} MB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
