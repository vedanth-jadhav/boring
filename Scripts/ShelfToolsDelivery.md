# Shelf tools

## Overview

This page documents the native macOS file tools available from Shelf, including their behavior and layout details for future maintenance.

## Colors

White labels sit on dark surfaces. Action accents follow the source: WhatsApp green, Save cyan, Compress orange, image conversion indigo, and PDF tools red. Hover and drag targeting tint the glass with the action's color.

## Typography

Use native system typography: shelf tool labels (11 pt, semibold), radial labels (10 pt, semibold), radial center labels (12 pt, semibold), and supporting radial instructions (9 pt). SF Symbols provide tool icons; WhatsApp uses the installed app icon when available.

## Layout

| Surface token | Source value and use |
| --- | --- |
| Open notch | 640 × 190 pt, existing app size |
| Shelf action rail | 122 pt wide; 23 pt rows with 4 pt gaps |
| Save area | Rounded rectangle with 16 pt corners; 8 pt content inset |
| Radial canvas | 420 × 420 pt, positioned near the cursor and clamped to the visible screen |
| Radial ring | 128 pt radius; 148 pt when a branch has more than five children |
| Radial targets | 86 × 66 pt; center surface 112 × 100 pt |

Sources: [notch sizing](../boringNotch/sizing/matters.swift), [ShelfView](../boringNotch/components/Shelf/Views/ShelfView.swift), [CursorShelfView](../boringNotch/components/Shelf/Views/CursorShelfView.swift), and [CursorShelfModel](../boringNotch/components/Shelf/ViewModels/CursorShelfModel.swift).

## Elevation & Depth

[ShelfGlass](../boringNotch/components/Shelf/Views/ShelfGlass.swift) uses native macOS 27 regular interactive glass. Reduced transparency, reduced glass, and earlier macOS versions use an opaque base (white level 0.16). Active tint opacity is 0.28. Reduce Motion removes radial and drag-target scale effects and their animations. Preserve these accessibility alternatives when extending the surface.

## Components

- **Shake radial:** Shake an active file or screenshot drag to reveal exactly five primary actions: WhatsApp, Save to Shelf, Compress, Convert, and Copy Path. The radial opens only through the drag shake gesture. Hover Compress or Convert for 450 ms to enter its compatible submenu; move to the center to go back. Drop on a supported action to execute it. [CursorShelfDropView](../boringNotch/components/Shelf/Views/CursorShelfDropView.swift) is a real AppKit drag destination: releasing elsewhere does not execute an action.
- **Shelf rail:** Click a tool to use selected shelf files or choose files; drop files directly onto a tool. The larger Save to Shelf area stores dropped items. Capture opens the macOS screenshot toolbar.
- **Media tools:** Compress creates smaller image, PDF, and video copies with Balanced, Smaller, or Smallest presets; ZIP remains a separately named archive action in the context menu. PDF compression requires confirmation because flattening turns selectable text, links, forms, and annotations into images. Originals remain available, and a larger compressed result is discarded. Convert supports PNG, JPEG, HEIC, Make PDF, PDF merge, one PDF per split page, PDF-to-PNG rendering, and native Preview markup/editing. Results are saved to Shelf. See [ShelfToolService](../boringNotch/components/Shelf/Services/ShelfToolService.swift) and [ShelfMediaProcessor](../boringNotch/components/Shelf/Services/ShelfMediaProcessor.swift).
- **Screenshot library:** Screenshot retention is off by default. When enabled in Shelf settings, newly captured screenshots are copied into the persistent `~/Library/Application Support/Boring Notch/Shelf Library/Screenshots` library. Content hashes prevent duplicate imports across launches; discovered floating screenshot files and ephemeral drags are copied out of temporary storage. Directory events trigger early capture, with polling as a fallback. Turning retention off stops future imports but leaves saved files in the library. See [ScreenshotShelfService](../boringNotch/components/Shelf/Services/ScreenshotShelfService.swift).
- **Forced app sharing:** Choosing WhatsApp explicitly targets WhatsApp. [WhatsAppShareService](../boringNotch/components/Shelf/Services/WhatsAppShareService.swift) prefers an available native share extension; otherwise it preserves safe attachment copies, places them on the pasteboard, and opens WhatsApp. The user chooses a chat and pastes (⌘V). If the app is unavailable, WhatsApp Web opens with an attachment instruction. The fallback never automatically sends a message.
