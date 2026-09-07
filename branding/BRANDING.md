# SimpleDisplay — Brand Assets

## Source

`logo.svg` is the single source of truth for the app icon and the website.
`menubar-icon.svg` is the menu bar status item: the same monitor, with the two resize
marks knocked out, as a black-on-transparent **template image** (macOS tints it to the
menu bar's foreground, so it works on light and dark bars). Nominal size 18x18 pt.

## Generate

```bash
python3 branding/generate_assets.py
```

Requires: `rsvg-convert` (`brew install librsvg`) and `Pillow` (`pip3 install pillow`).

## Files

```
branding/
├── logo.svg               ← edit this (app icon, website)
├── menubar-icon.svg       ← edit this (menu bar status item)
├── generate_assets.py     ← run to regenerate
├── BRANDING.md
└── assets/
    ├── logo.svg           ← copy of source
    ├── logo-512.png       ← rasterized
    ├── menubar-icon@2x.png ← preview of the menu bar glyph
    └── favicon.ico        ← multi-size ico
```

## Where they go

| Asset | Destination | Used by |
|-------|-------------|---------|
| `logo.svg` | `website/assets/logo.svg` | Nav bar, og image |
| `logo-512.png` | `website/assets/logo.png` | Fallback |
| `favicon.ico` | `website/favicon.ico` | Browser tab |
| `MenuBarIcon.tiff` | `Sources/SimpleDisplay/Resources/` | Menu bar status item, 1x + 2x reps (`BrandAssets.swift`) |
| `AppIcon.icns` | `.app/Contents/Resources/` via Makefile | Dock/Finder, and the popover + Settings headers (`AppIconView`) |

## Colors

| Hex | Usage |
|-----|-------|
| `#1E90FF` | Gradient start (blue) |
| `#6C5CE7` | Gradient end (purple) |
| `#2563EB` | Resize mark top-left |
| `#7C3AED` | Resize mark bottom-right |
