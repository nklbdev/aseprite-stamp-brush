# Stamp Brush

A clone-stamp brush extension for [Aseprite](https://www.aseprite.org/) — select a source area and paint with it like a stamp. With tiled canvas, smoothstep brush mask, max-alpha blending, pan/zoom, selection masking, and local undo/redo.

<p align="center">
<img src="https://img.shields.io/badge/Aseprite-1.3+-brightgreen" alt="Aseprite 1.3+">
<img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT License">
<img src="https://img.shields.io/badge/version-1.0.0-orange" alt="Version 1.0.0">
</p>

## 📜 Table of contents

- [Features](#-features)
- [How to install](#-how-to-install)
- [How to use](#-how-to-use)
- [Controls](#-controls)
- [FAQ](#-faq)

## 🎯 Features

- **Clone-stamp brush** — paint by sampling color from any part of a cel or its tiled copies.
- **Soft brush** — smoothstep brush mask with adjustable radius (1-64), softness, and opacity.
- **Tiled canvas** — display 1×1, 3×1, 1×3, or 3×3 tiles with boundary lines. Tiling works as both a visual reference and a source-wrapping mode.
- **Max-alpha accumulator** — no blending artifacts on overlapping strokes. Each stroke collects the maximum alpha per pixel and flushes once.
- **Pan and zoom** — middle-click drag to pan, mouse wheel to zoom (powers of two: 0.5× to 32×). Pinch-to-zoom on trackpad is not supported.
- **Selection masking** — the brush only paints inside the active selection. Selection outline is rendered with marching-ants-style alternating colors via `BlendMode.DIFFERENCE` for visibility on any background.
- **Dynamic preview** — see what will be painted before you click, updated in real time.
- **Stamp spacing** — stamps are interpolated along mouse movement with configurable spacing (25% of radius) for smooth strokes.
- **Local undo/redo** — Ctrl+Z / Ctrl+Shift+Z with full stroke history. Redo history is cleared on new strokes. Keyboard shortcuts are handled by the canvas widget — they may not work if the canvas loses focus. Click the canvas to restore focus.
- **Continue editing** — save your work, discard, or continue editing if you close the dialog accidentally.
- **Auto-expanding cel** — when painting outside the cel bounds, the cel automatically grows to include new pixels. Works exactly like Aseprite's native `PatchCel` command.
- **Source snapshot** — clone source is captured from the current cel state. Updated after each stroke and on undo/redo, so you can clone from your own modifications.
- **Full-window dialog** — opens to fill the entire Aseprite window for maximum workspace.
- **Auto-zoom** — initial zoom level is automatically calculated to fit the content in the available canvas area.
- **Fixed canvas size** — `workImg` is the full sprite canvas. The cel is drawn onto it at its position. Painting happens in absolute canvas coordinates — no mid-stroke image expansion needed.

## 💽 How to install

1. Download the `.aseprite-extension` file from the [Releases](https://github.com/nklbdev/aseprite-stamp-brush/releases) page.
2. Double-click the file, or install via _Edit > Preferences > Extensions > Add Extension_.
3. The "Clone Stamp" command will appear in the _Edit_ menu.
   You can assign a keyboard shortcut via _Edit > Keyboard Shortcuts_ — search for "Edit > Clone Stamp".

Alternatively, clone this repository and copy the folder to your Aseprite extensions directory:
- **macOS**: `~/Library/Application Support/Aseprite/extensions/`
- **Windows**: `%AppData%/Aseprite/extensions/`
- **Linux**: `~/.config/aseprite/extensions/`

## 👷 How to use

1. Open an image in Aseprite and select the cel you want to modify (if it is not selected yet).
2. _(Optional)_ Make a selection if you want to paint only within specific bounds.
3. Run _Edit > Clone Stamp_.
4. **Left-click** or **Right-click** on the area you want to clone FROM (sets the source point).
5. **Left-click and drag** to paint with the clone stamp.
6. **Right-click** to set a new source point (captures the current canvas state, including your previous strokes).
7. Use sliders to adjust **Tiled Mode**, **Radius**, **Opacity**, and **Softness**.
8. Close the dialog — choose **Apply** to commit changes, **Discard** to cancel, or **Continue Editing** to keep working.

### Mouse controls

| Action | Button |
|---|---|
| Set source point | Left click (only first time) or Right click (always) |
| Paint | Left click and drag |
| Cancel stroke | Right click while drawing |
| Pan | Middle click and drag |
| Zoom | Mouse wheel (powers of two) |
| Brush size | Shift + mouse wheel |

### Keyboard controls

| Action | Shortcut |
|---|---|
| Undo | Ctrl+Z (Cmd+Z on macOS) |
| Redo | Ctrl+Shift+Z or Ctrl+Y (Cmd+Shift+Z or Cmd+Y on macOS) |
| Apply and close | Enter |

## ❓ FAQ

### The brush doesn't paint outside the cel

Make sure **Tiled Mode** is set to **Both** (value 3). In other modes, source wrapping is disabled in one or both directions.

### Keyboard shortcuts and Shift+scroll don't work

Keyboard events (undo/redo, Shift+scroll) are only received by the canvas widget, not the whole dialog. If the canvas loses focus — e.g., after an `app.alert` popup or clicking outside the canvas — these stop working. Click anywhere on the canvas to restore focus. This is a limitation of the Dialog canvas API architecture.

### Shift+scroll changes brush size unpredictably (macOS)

If Shift+scroll doesn't change brush size, or the size changes disproportionately (e.g., only decreases), and you use [Linear Mouse](https://linearmouse.app/) on macOS — set **Scrolling Mode** to **By Pixels** and all **Modifier Keys** to **Default Action**.

### The dialog opens too small

The dialog is set to fill the entire Aseprite window on open. If it appears small, try resizing it manually — the next session will remember the size.
