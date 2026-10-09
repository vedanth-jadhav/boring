# Boring Notch Octave

<!-- impeccable:product-schema 1 -->

## Platform

web

The Windows edition is an Electron desktop app; the existing macOS app remains native SwiftUI.

## Stack

User-directed replacement of the rejected Avalonia interface with Electron. A compiled .NET helper supplies Windows APIs and portable local processing. No server account is required.

## Product Purpose

Keep music, lyrics, focus, calendar, files and small system tools within a compact desktop island that opens under the pointer and recedes when it leaves.

## Users and Operating Context

Windows PC users, including PCs without a physical notch. Specific audience demographics are undecided. The app lives above ordinary desktop work, supports multiple monitors and display scaling, and should consume little work when idle.

## Capabilities and Constraints

The requested port includes music and exact provider-supplied lyrics, focus and stay-awake, local calendar and reminders, file shelf and conversions, screenshots, Windows sharing, volume/brightness/power, camera mirror and Codex usage. Onboarding groups these into Music, Productivity, Files and System. Windows replaces Apple-only APIs; local ICS imports replace native macOS calendar account access. Linux cloud QA cannot certify Windows hardware integrations. The distribution must be built, tested and accompanied by a recording of the full running demo.

## Brand Commitments

The user explicitly requires fidelity to the original demo, smooth cursor-triggered opening and closing, pristine UI, and an appropriate replacement for Apple Liquid Glass. The generic branded header, big rounded button tabs and stacked card layout in the rejected prototype are not the design reference. Preserve the existing Boring Notch Octave name and original identity.

## Evidence on Hand

`assets/boring-notch-octave-demo.mp4`, the SwiftUI components in `boringNotch/components/`, and exact dimensions in `boringNotch/sizing/matters.swift`. The original expanded island is 640 × 190. The user has delegated implementation and setup choices and requested no intervention.

## Product Principles

- The original interaction and visual identity lead the port.
- Windows features use real platform APIs and report unavailable devices plainly.
- Personal data stays local except explicitly chosen metadata/account requests.
- A desktop overlay must let users interact with the desktop outside its visible shape.
- Verify the actual running interface and label demonstration fixtures honestly.
