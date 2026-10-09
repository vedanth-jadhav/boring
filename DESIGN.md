---
name: "Boring Notch Octave — Windows island"
description: "The original compact black desktop island, restored in Electron."
colors:
  ink: "#f5f5f7"
  muted: "#a1a1a8"
  line: "#ffffff16"
  hover: "#ffffff0d"
  accent: "#70d8ef"
  amber: "#ffbd3d"
  danger: "#ffb4a5"
  opaque-island: "#050505"
  glass-bottom: "#080e18"
  surface: "#111"
  selected-surface: "#242428"
  white: "#fff"
  primary-action: "#bcdeff"
  field: "#ffffff09"
  control-blue: "#78bbff"
  control-ink: "#081522"
  primary-action-hover: "#d4eaff"
  control-hover: "#13263a"
  control-hover-ink: "#d7eaff"
  nav-selection: "#122033"
  nav-selection-ink: "#b9dcff"
  segment-selection: "#1a2b41"
  segment-selection-ink: "#cee7ff"
typography:
  onboarding:
    fontFamily: "Inter, \"Segoe UI\", sans-serif"
    fontSize: "26px"
    fontWeight: 600
    lineHeight: 1.22
    letterSpacing: "-0.025em"
  title:
    fontFamily: "Inter, \"Segoe UI\", sans-serif"
    fontSize: "15px"
    fontWeight: 600
    letterSpacing: "-0.015em"
  track:
    fontFamily: "Inter, \"Segoe UI\", sans-serif"
    fontSize: "14px"
    fontWeight: 600
    lineHeight: "19px"
  artist:
    fontFamily: "Inter, \"Segoe UI\", sans-serif"
    fontSize: "13px"
    fontWeight: 500
    lineHeight: "19px"
  body:
    fontFamily: "Inter, \"Segoe UI\", sans-serif"
    fontSize: "12px"
    fontWeight: 400
    lineHeight: 1.6
  control:
    fontFamily: "Inter, \"Segoe UI\", sans-serif"
    fontSize: "11px"
    fontWeight: 400
  compact:
    fontFamily: "Inter, \"Segoe UI\", sans-serif"
    fontSize: "10px"
    fontWeight: 500
  time:
    fontFamily: "Inter, \"Segoe UI\", sans-serif"
    fontSize: "9px"
    fontWeight: 400
  focus-clock:
    fontFamily: "Inter, \"Segoe UI\", sans-serif"
    fontSize: "29px"
    fontWeight: 400
    letterSpacing: "-0.035em"
  usage-total:
    fontFamily: "Inter, \"Segoe UI\", sans-serif"
    fontSize: "31px"
    fontWeight: 500
    letterSpacing: "-0.04em"
  primary-action:
    fontFamily: "Inter, \"Segoe UI\", sans-serif"
    fontSize: "11px"
    fontWeight: 600
rounded:
  artwork-compact: "4px"
  transport: "7px"
  field: "8px"
  artwork-open: "13px"
  action: "15px"
  segment: "16px"
  island-compact: "17px"
  segmented-container: "19px"
  island-open: "24px"
spacing:
  micro: "3px"
  fine: "5px"
  tight: "7px"
  small: "8px"
  row: "12px"
  section: "14px"
  inset-narrow: "18px"
  inset: "22px"
components:
  button-primary:
    backgroundColor: "{colors.primary-action}"
    textColor: "{colors.control-ink}"
    typography: "{typography.primary-action}"
    rounded: "{rounded.action}"
    padding: "7px 12px"
  button-primary-hover:
    backgroundColor: "{colors.primary-action-hover}"
  button-secondary:
    backgroundColor: "{colors.hover}"
    textColor: "{colors.ink}"
    typography: "{typography.control}"
    rounded: "{rounded.action}"
    padding: "7px 12px"
  button-danger:
    backgroundColor: "{colors.hover}"
    textColor: "{colors.danger}"
    typography: "{typography.control}"
    rounded: "{rounded.action}"
    padding: "7px 12px"
  icon-navigation:
    rounded: "{rounded.action}"
    width: "36px"
    height: "27px"
  field:
    backgroundColor: "{colors.field}"
    textColor: "{colors.ink}"
    typography: "{typography.control}"
    rounded: "{rounded.field}"
    padding: "7px 9px"
  segmented-container:
    backgroundColor: "{colors.surface}"
    rounded: "{rounded.segmented-container}"
    padding: "3px"
  segment-selected:
    backgroundColor: "{colors.segment-selection}"
    textColor: "{colors.segment-selection-ink}"
    typography: "{typography.control}"
    rounded: "{rounded.segment}"
    padding: "6px 13px"
  transport:
    rounded: "{rounded.transport}"
    width: "28px"
    height: "27px"
  island-open:
    rounded: "{rounded.island-open}"
    width: "640px"
    height: "190px"
  island-compact:
    rounded: "{rounded.island-compact}"
    width: "204px"
    height: "34px"
  artwork-open:
    rounded: "{rounded.artwork-open}"
    size: "118px"
  settings-switch:
    backgroundColor: "#3c3c41"
    width: "27px"
    height: "16px"
  shelf-drop:
    rounded: "{rounded.artwork-open}"
    height: "85px"
  button-secondary-hover:
    backgroundColor: "{colors.control-hover}"
    textColor: "{colors.control-hover-ink}"
  icon-navigation-selected:
    backgroundColor: "{colors.nav-selection}"
    textColor: "{colors.nav-selection-ink}"
    rounded: "{rounded.action}"
  settings-switch-checked:
    backgroundColor: "{colors.control-blue}"
    width: "27px"
    height: "16px"
---

# Design System: Boring Notch Octave — Windows island

## Overview

**Creative North Star: "The Original Desktop Island"**

The Original Desktop Island preserves the incumbent Boring Notch Octave demo: a compact black silhouette, photographic artwork, restrained sans lettering and a lower glass field. The Windows edition adapts the placement and supporting tools while keeping the original visual identity. This document records the finished Electron surface in `windows/electron/renderer/`; it does not replace the native macOS world or prescribe changes to its SwiftUI implementation.

Density serves an overlay used above ordinary desktop work. A quiet icon header leads into a single focused tool; music keeps the artwork beside metadata, lyrics, a fine timeline and transport. Floating, original-edge and corner placement support displays with or without a physical notch.

The user-requested Windows blue refinement gives interactive elements pale-blue primary actions, blue selected and hover surfaces, fine inset reflections and soft offset depth. This material belongs to controls; photographic artwork and playback retain the cover-derived accent within the original black island.

**Key Characteristics:**

- Compact black-to-glass island with an opaque fallback.
- Photographic artwork and authored SVG icons.
- Inter lettering, fine dividers and polished blue action controls.
- Shared artwork geometry, interruptible spring transitions and reduced-motion support.

## Colors

Neutral black and near-white frame the photographic cover; the artwork accent communicates playback and Windows blue identifies interaction.

### Primary

- **Artwork Accent** (`accent`): the default cyan supplies artist text, seek progress, spectrum and compact playback bars, plus the caret and focus ruler. Artwork sampling replaces it at runtime with the averaged cover color, brightened until relative luminance reaches at least 0.32.

### Secondary

- **Windows Control Blue** (`control-blue`): button/input keyboard focus, checked switches and native form accent.
- **Pale Blue Action** (`primary-action`) with **Control Ink** (`control-ink`): high-contrast primary actions; `primary-action-hover` brightens the hover state.
- **Blue Hover Material** (`control-hover`, `control-hover-ink`): secondary/icon/transport hover surfaces and lettering.
- **Blue Navigation Selection** (`nav-selection`, `nav-selection-ink`): selected and hovered icon tabs.
- **Blue Segment Selection** (`segment-selection`, `segment-selection-ink`): selected non-amber settings/focus segments.

- **Stay-awake Amber** (`amber`): active stay-awake status and the caffeine tool's local accent.
- **Notice Peach** (`danger`): runtime notices and destructive-action lettering.

### Neutral

- **Soft White** (`ink`) and **Quiet Gray** (`muted`): primary labels and supporting explanations.
- **Opaque Island** (`opaque-island`) and **Glass Bottom** (`glass-bottom`): the solid fallback and the lower SVG glass gradient stop.
- **Inset Black** (`surface`) and **Selected Charcoal** (`selected-surface`): mirror/segmented containers and the unplayed timeline.
- **Fine Line** (`line`), **Hover Veil** (`hover`) and **Field Veil** (`field`): dividers, quiet actions and fields on the dark island.
- **White** (`white`): neutral glyphs and remaining highlighted details.

**The Artwork Accent Rule.** Use the cover-derived accent for the artist, playback progress and activity details; the default cyan remains the fallback. Keep the island and primary lettering neutral.

**The Control Blue Rule.** Use Windows blue for button/input focus, primary actions and selected or hovered control surfaces. Preserve the artwork-derived playback accent and the amber stay-awake variant.

## Typography

**Body and control font:** self-hosted Inter (400, 500 and 600), with Segoe UI and sans-serif fallback. The system uses no expressive display face or separate mono family. Numeric timing and allowance labels use tabular figures.

### Hierarchy

- **Onboarding:** the onboarding token gives the brief opening heading; it contracts to 23 px at the small-desktop breakpoint.
- **Title:** compact tool headings use the title token; the broader heading style is 21 px with the same weight and the onboarding letter-spacing.
- **Track / artist:** the track and artist tokens preserve the music title/artist hierarchy. Artist text contracts to 12 px on small desktops.
- **Body / control / compact / time:** prose, actions and fields, the closed label, and playback timestamps respectively. Lyrics use 12 px type with 17 px leading in a single clipped line.
- **Focus clock / usage total:** large tabular time and the token total are functional numerals, not a page-level display style.

**The Small Control Rule.** Keep routine controls at the implemented control and label sizes; reserve large numerals for time and usage totals.

## Layout

The normal expanded music island is 640 × 190 px; its compact state is 204 × 34 px. The renderer uses a transparent canvas and limits open width to the smaller of 640 px and the viewport minus 40 px, with a 280 px floor. Onboarding caps its width at 490 px. Supporting tools grow within a viewport-height cap of 14 px below the canvas edge; settings, calendar and file lists use bounded scrolling.

The expanded inset is 9 px top, 22 px sides and 18 px bottom. The header is 30 px tall with a 14 px following gap. Music begins beside the artwork with a 144 px left offset; the open artwork starts at (22, 52) relative to the shell and measures 118 px square. Its closed anchor is (7, 7), with a 20 px square image; original-edge placement shifts that compact anchor to clear the concave ear. The compact label leaves 37 px at the left for artwork.

At the 540 px CSS breakpoint the side inset becomes 18 px, header/nav gaps tighten, nav buttons become 30 px wide and transport gaps become 12 px. The source selects 76 px artwork below 540 px canvas width, with a 94 px metadata offset. The reviewed 390 px small-desktop captures preserve the same composition; they do not establish a phone design. With a 390 px renderer viewport the open-width formula yields 350 px.

The native Electron window adds an 8 px top gap for floating/corner placement and no gap for original-edge placement. Corner placement aligns the island toward the right; other modes center it. Keep spacing at the extracted small scale for rows and controls rather than expanding the overlay into a page grid.

## Elevation & Depth

The silhouette carries a diffuse drop shadow (`0 12px 16px #00000024`). The SVG glass field starts at opaque black, remains 96% black at 58% height, and ends at the glass-bottom color with 68% opacity. Native Windows acrylic composition is requested behind the clipped island; when glass is switched off or material application reports failure, the renderer selects the opaque-island fill. This records implemented behavior; native Windows composition and hardware remain unverified on the Linux validation host.

Controls add fine inset top reflections and soft offset shadows. Primary actions use `inset 0 1px 0 #ffffff40, 0 3px 8px #00000028`; secondary/icon/transport hover uses `inset 0 1px 0 #9bd0ff29, 0 3px 8px #00000035`. Navigation selection uses `inset 0 1px 0 #8bc6ff24`, and selected non-amber segments use `inset 0 1px 0 #96ccff21`. These small, diffuse shadows provide control depth without changing the island silhouette.

**The Platform Material Rule.** Use native Windows composition when available and retain the opaque island when glass is disabled or unavailable.

## Shapes

Floating/corner placement uses the expanded island radius and the compact island radius. Original-edge placement uses concave top ears with a 19 px maximum ear radius and a 32 px maximum lower radius, clamped to the available geometry. Artwork interpolates between the compact and open artwork radii. Small controls use the transport, action, field and segment radii; rounded geometry is native to this inherited world.

The shell and shared artwork layer are clipped to the same SVG path. The thin seek track is 3 px tall with a 2 px radius; focus ruler ticks and allowance blocks remain fine geometric marks. Dividers are translucent 1 px lines, not prominent card boundaries.

## Components

### Buttons

Quiet secondary actions use the hover veil, action radius and compact padding; primary actions use pale-blue fill with control ink and weight 600. Hover applies the blue hover material and soft reflected depth to secondary/icon/transport controls, while primary fill brightens. Active actions and segments scale to 0.965; transport retains its separate 1.12 hover and 0.89 press response. Danger is a peach text-color variant at rest and takes the shared blue hover lettering. Disabled buttons reduce opacity to 0.34; busy actions reduce it to 0.6 and pause interaction. Button/input keyboard focus is a 2 px Windows control-blue outline with 3 px offset.

### Inputs / Fields

Fields use a low-opacity veil, fine translucent border, field radius and compact padding. Placeholder lettering stays muted; focus changes the border to half-opacity Windows blue in addition to the visible control-blue focus outline. Fields allow text selection and retain the artwork-accent caret. Switches measure 27 × 16 px, with a 12 px thumb that moves 11 px when checked. Checked switches and native ranges/checkboxes use Windows control blue; the authored music timeline retains its artwork accent.

### Navigation

Authored SVG navigation icons sit in 36 × 27 px quiet capsules, with 18 px glyphs. Selected and hovered icons use the blue navigation material with a fine reflected top edge. The small-desktop adaptation reduces width while keeping the icon header. Supporting settings and placement choices use the small segmented control, with 3 px outer padding/gap and blue selected segments. The amber caffeine variant preserves its own selected treatment. Onboarding feature checkmarks use pale blue; feature-row hover adds a faint blue veil, and placement preview hover reveals a blue-dark inset.

### Containers and supporting tools

The island itself is the shared container. Supporting tools use compact divided rows and scrollable lists rather than a new dashboard-card hierarchy. The shelf drop area has a dashed border and artwork-open radius; mirror uses the same radius and a dark inset. Focus retains the centered segments, fine ruler and right-aligned clock. Codex allowance uses 24 short blocks, right-aligned percentages and the separate token total.

### Music island and shared artwork

One shared photographic artwork element persists through open, close and interrupted transitions. The timeline, small timestamps and centered SVG transport retain the original music topology. Singing words use text-clipped progress gradients; the optional spectrum changes bar transforms from actual audio levels. Compact playback bars animate only in a playing state.

Geometry uses exact critically damped, time-based springs: shell/artwork frequency 28 when opening and 34 when closing; content openness uses 32. The pointer rests for 160 ms before opening, and leaving begins a 420 ms close grace period. Active requests and focused text entry defer closing. Spatial targets snap when reduced motion is enabled, and CSS animations/transitions are suppressed. Control material changes use 160 ms ease-out transitions, and spatial press feedback uses 130 ms ease-out transitions. Reduced motion also suppresses hover/press transforms. Live Electron QA on Linux exercised pointer opening, reversal and reduced-motion behavior and checked the 2 px blue keyboard ring. Still screenshots alone do not establish animation quality; Windows native hardware remains unverified.

## Do's and Don'ts

### Do:

- **Do** retain the original compact island identity and the music artwork/metadata relationship.
- **Do** use real artwork, SVG icons, thin timelines and bounded scrolling for longer lists.
- **Do** preserve floating and original-edge options for displays with and without a physical notch.
- **Do** maintain visible keyboard focus and honor both the system and in-app reduced-motion preference.
- **Do** keep native Windows availability and demonstration fixtures plainly labeled.

### Don't:

- **Don't** introduce a branded dashboard header or oversized text-button navigation into the music island.
- **Don't** mount separate artwork elements for open and closed states; the shared element carries the transition.
- **Don't** turn the transparent canvas outside the island into a visible panel or a click target.
- **Don't** treat still-image fidelity as evidence of smooth motion or verified Windows hardware behavior.
