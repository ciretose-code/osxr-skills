---
name: screenshots
description: Use when capturing or updating README / GitHub release screenshots for a macOS open-source app — menu bar apps, main windows, preference panes — not App Store Connect screenshot sets (use asc:screenshots for those).
---

# macOS README / GitHub screenshots

## Overview

Lightweight shot pipeline for OSS GitHub pages. Not App Store canvases — for
ASC sizes and upload, use **asc:screenshots**. Requires osxr:setup only if you
want paths declared in `osxr.json`; otherwise agree a folder with the user
(commonly `docs/` or `Assets/Screenshots/`).

## Workflow

### 1. Plan

- Ordered shot list (3–6 is enough for a menu-bar utility). Frame 1 = the
  differentiator.
- Deterministic state: same menu contents, same sample data, hide personal
  desktop clutter.
- Write the list to `docs/screenshots.md` or a README section if the repo
  doesn't have one.

### 2. Capture — choose one

| Method | Best for |
|---|---|
| **A. `screencapture`** | Menu bar extras, floating panels, one-offs |
| **B. SwiftUI `ImageRenderer` / snapshot test** | Exact views, CI-friendly |
| **C. Manual** (⇧⌘4 / ⇧⌘5) | Rare shots |

Menu bar apps:

```sh
# Interactive crosshair selection
screencapture -i docs/01-menu.png

# Specific window (get window id via Cmd+⇧+⌘+4 then space, or CGWindowList)
screencapture -l <windowid> docs/02-window.png
```

Tips:

- Retina: capture at native scale; don't upscale.
- Prefer a clean wallpaper / hide desktop icons for marketing shots.
- For menu-only shots, open the menu first, then capture the menu region.
- Strip the cursor unless it teaches a click target: `screencapture -C` includes
  it; default usually omits for `-l`.

### 3. Place in the repo

Suggested layout (commit these; they are product docs, not secrets):

```
docs/
  01-menu.png
  02-idle.png
  03-running.png
```

Reference them from README with relative paths. Optional: add
`"screenshots": "docs"` to `osxr.json` so later release notes can find them.

### 4. Optional — attach to a GitHub release

After osxr:release has created the tag:

```sh
gh release upload <tag> docs/*.png --clobber
```

Only when the user asks for screenshots on the release, not by default.

## Out of scope

- App Store screenshot families, caption canvases, `asc.json` devices — use
  **asc:screenshots**.
- DMG background art (that's `dmgBackground` in `osxr.json` / Pixelmator source
  next to `Assets/DMGBackground.png`).
