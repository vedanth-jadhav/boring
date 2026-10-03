# Native notification mirroring

The feature now captures macOS notifications, queues them, and opens their native
application on click. All reply providers, inline reply UI, service webviews,
browser Connect/Disconnect settings, Messages database access and reply XPC methods
have been removed. A one-time migration clears only the two former feature-specific
WebKit profiles and their connection preferences; other browser data is untouched.

The helper reads usernoted's notification SQLite store read-only. Database/WAL and
directory events trigger a bounded recent-record scan, with a 16ms coalescing delay.
The app publishes bursts in one 16ms batch. UUID identity, semantic change detection,
restart checkpoints, app filters and the bounded 32-item queue remain separate from
SwiftUI. AX window-created events provide optional early rescan hints, including
bounded retries while macOS commits the record; they do not scrape notification
text or supply UI data. A three-second recovery scan handles missed events and
Notification Center/store restarts. macOS can still delay saving notification data.

At rest the newest notification is shown. Hover reveals the scrollable recent
queue. Rows retain their IDs, and the existing notch spring animates height and
content downward with the window fixed. Clicking a row activates/opens its native
application, removes that row from the mirrored queue, and leaves the other rows
available. Failed app launches retain the notification. No notification UI receives
raw AX actions or debugging details.

Native banner dismissal happens only after the mirrored queue accepts the record.
The separate suppressor requires one exact app/title/body match and uses AXCancel,
a uniquely exposed native Close/Dismiss action, or a genuine Close/Dismiss button.
It never presses generic notification actions or uses coordinates. Short bounded
retries handle banners which appear just after capture. Bundle identity comparisons
ignore case. Ambiguous matches, missing permission and unsupported controls are
left alone. Complete prevention of duplicate desktop banners still requires
turning off Desktop in macOS notification settings while keeping Notification Center
and Allow Notifications enabled; the app never silently changes those preferences.

Permissions: Full Disk Access for store access; optional Accessibility for early
event hints and safe native-banner dismissal. No notification generation, Screen
Recording, account login, Messages Automation or Contacts permission is required
by this feature.

Validation:

- 13 focused checks: read-only SQLite/plist parsing, stable occurrence IDs, five-item
  bursts and newest-first ordering, updates and queue cap, retired-row deduplication,
  filters/priority, safe native dismiss matching, wire payloads, permission failure
  and recovery, native-app click routing, bounded dismissal retries, and 32 fixed-
  window queue/hover/music layout frames.
- Real SQLite/WAL harness captures five identical messages with five stable IDs and
  verifies no replay after source restart. It uses the production watcher.
- A local macOS test notification was captured from the real store. Live WhatsApp
  capture was confirmed by the user; exact native WhatsApp dismissal and physical
  display/fullscreen interactions still need live verification.
- Current app and helper are built and installed through Scripts/install_local.sh.
  Logs and frames are in build/validation/notifications-native/.

No messaging service send transport or reaction transport exists in this version.
