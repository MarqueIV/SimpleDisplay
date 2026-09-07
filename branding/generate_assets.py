#!/usr/bin/env python3
"""
SimpleDisplay — Brand Asset Generator

Generates assets from logo.svg and copies them to where they're used.

Usage:
    python3 branding/generate_assets.py

Requirements:
    - rsvg-convert (brew install librsvg)
    - Pillow (pip3 install pillow)
"""

import subprocess
import shutil
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
LOGO_SVG = ROOT / "branding" / "logo.svg"
MENUBAR_SVG = ROOT / "branding" / "menubar-icon.svg"
APP_RESOURCES = ROOT / "Sources" / "SimpleDisplay" / "Resources"
ASSETS = ROOT / "branding" / "assets"
WEBSITE = ROOT / "website"
WEBSITE_ASSETS = WEBSITE / "assets"


def svg_to_png(svg: Path, out: Path, size: int):
    subprocess.run(
        ["rsvg-convert", str(svg), "-o", str(out), "-w", str(size), "-h", str(size)],
        check=True,
    )


def create_hidpi_tiff(svg: Path, out: Path, points: int):
    """Multi-resolution TIFF (1x + 2x) for an NSImage; NSImage picks the rep for
    the screen's scale. Rasterized on purpose: rsvg turns the SVG mask into a PDF
    soft mask that NSImage renders almost blank."""
    tmp = out.parent / f"{out.stem}.png"
    tmp2x = out.parent / f"{out.stem}@2x.png"
    svg_to_png(svg, tmp, points)
    svg_to_png(svg, tmp2x, points * 2)
    subprocess.run(["tiffutil", "-cathidpicheck", str(tmp), str(tmp2x), "-out", str(out)], check=True)
    tmp.unlink()
    tmp2x.unlink()


def create_favicon(png: Path, out: Path):
    img = Image.open(png)
    sizes = [(16, 16), (32, 32), (48, 48)]
    icons = [img.resize(s, Image.LANCZOS) for s in sizes]
    icons[0].save(out, format="ICO", sizes=sizes, append_images=icons[1:])


def create_icns(png: Path, out: Path):
    iconset = out.with_suffix(".iconset")
    iconset.mkdir(exist_ok=True)
    img = Image.open(png)
    for s in [16, 32, 64, 128, 256, 512]:
        img.resize((s, s), Image.LANCZOS).save(iconset / f"icon_{s}x{s}.png")
        s2 = s * 2
        if s2 <= 1024:
            img.resize((s2, s2), Image.LANCZOS).save(iconset / f"icon_{s}x{s}@2x.png")
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(out)], check=True)
    shutil.rmtree(iconset)


def main():
    if not LOGO_SVG.exists():
        print(f"Error: {LOGO_SVG} not found")
        return

    ASSETS.mkdir(exist_ok=True)
    WEBSITE_ASSETS.mkdir(parents=True, exist_ok=True)

    print("Generating assets from logo.svg...")

    # PNG + favicon + icns
    svg_to_png(LOGO_SVG, ASSETS / "logo-512.png", 512)
    create_favicon(ASSETS / "logo-512.png", ASSETS / "favicon.ico")
    create_icns(ASSETS / "logo-512.png", ASSETS / "AppIcon.icns")
    shutil.copy2(LOGO_SVG, ASSETS / "logo.svg")
    print("  assets/logo.svg")
    print("  assets/logo-512.png")
    print("  assets/favicon.ico")
    print("  assets/AppIcon.icns")

    # Menu bar status item glyph (template image, bundled with the app)
    create_hidpi_tiff(MENUBAR_SVG, APP_RESOURCES / "MenuBarIcon.tiff", 18)
    svg_to_png(MENUBAR_SVG, ASSETS / "menubar-icon@2x.png", 36)
    print("  Sources/SimpleDisplay/Resources/MenuBarIcon.tiff (18 + 36 px)")
    print("  assets/menubar-icon@2x.png (preview)")

    # Copy to destinations
    print("\nCopying...")
    copies = [
        (ASSETS / "logo.svg",     WEBSITE_ASSETS / "logo.svg"),
        (ASSETS / "logo-512.png", WEBSITE_ASSETS / "logo.png"),
        (ASSETS / "favicon.ico",  WEBSITE / "favicon.ico"),
    ]
    for src, dst in copies:
        shutil.copy2(src, dst)
        print(f"  → {dst.relative_to(ROOT)}")

    print(f"  → AppIcon.icns copied to .app bundle via Makefile")
    print("\nDone.")


if __name__ == "__main__":
    main()
