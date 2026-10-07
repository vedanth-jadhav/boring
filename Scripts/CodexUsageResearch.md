# Codex usage tab

Researched 2026-10-06. This implementation adds native Swift code; it does not
install a tracker, run an npm package, or depend on another menu bar app.

## Source decisions

- [OpenAI Codex](https://github.com/openai/codex): the CLI's session JSONL schema
  supplies `turn_context.model`, cumulative `token_count` snapshots, and observed
  rate-limit windows. Read only metadata and usage records; never upload logs.
- [CodexBar's provider documentation](https://github.com/steipete/CodexBar/blob/main/docs/codex.md)
  and [OAuth fetcher](https://github.com/steipete/CodexBar/blob/main/Sources/CodexBarCore/Providers/Codex/CodexOAuth/CodexOAuthUsageFetcher.swift):
  authenticated GETs to OpenAI's `wham/usage` and `wham/rate-limit-reset-credits`
  give current allowance, actual window durations, reset dates, credit balance,
  additional model limits, and available reset credits. These backend endpoints
  are not a stable public API. Schema changes fail visibly; they never turn into
  a fabricated zero or a replenished allowance. No credential refresh writes,
  browser cookies, Keychain scraping, or reset redemption.
- [ccusage's Codex parser](https://github.com/ccusage/ccusage/blob/main/rust/adapters/codex/src/parser.rs)
  and [duplicate-snapshot report](https://github.com/ccusage/ccusage/issues/1288):
  repeated snapshots and replayed fork prefixes require deduplication. Our own
  parser uses cumulative deltas, tracks counter resets, deduplicates session IDs,
  and excludes inherited timestamps / dense leading fork replay. Like a log-based
  tracker, it cannot reconstruct missing usage records. Remote compaction-only
  `token_usage_record` entries are not included; token totals reflect cumulative
  `token_count` records, not an authoritative billing ledger.
- [Official API pricing](https://developers.openai.com/api/docs/pricing): parse
  the full embedded Standard catalog (including collapsed model rows), then
  visible tables for specialized models. Match exact model names or dated
  snapshots only. Refresh daily, retain the last successful catalog offline,
  expose its fetch date and stale state, and link to the original source.
- [Official plan pricing](https://learn.chatgpt.com/docs/pricing): plan allowance
  is shared and task-dependent. Local token counts cannot be converted to an
  account's remaining token budget. API equivalent is explicitly an estimate at
  current Standard short-context rates, including cached input and cache writes;
  reasoning is already part of output. Fast/long-context/tool charges and historic
  rate changes can differ. Never present the estimate as subscription billing.

## UI and lifecycle

Extends the app's established dark notch, system rounded numerals, quiet surface
fills, SF Symbols, capsule selection, and existing tab spring. White measurements and neutral opacity levels follow the user’s monochrome
Codex direction. Selected controls use weight and contrast; old readings are
identified with explicit text and a quieter indicator. The primary
view shows remaining allowance and reset timing. Model rows disclose token kinds
and exact rates on demand. Today / 7 days / 30 days use the user's local calendar.
The native menu offers dashboards and a custom Codex home without a new settings
screen. In compact mode, the app menu can explicitly open the full Codex tab.

Work is scoped to the visible tab: incremental log scans every 15 seconds,
quota reads at most once per minute (15 seconds at an expired window), and a
daily pricing cache. Closing the notch cancels its task. Actor-isolated scanning
streams bounded chunks, checkpoints complete JSONL rows, and persists only counts,
offsets, models, and quota readings in an owner-only cache. A first 30-day scan
does more work; following scans read changed tails only. Auth tokens remain in
memory, are sent only to the exact HTTPS usage host, and are never logged or saved.
Account and folder changes invalidate prior quota; in-flight results are rejected
when their source changes. Reduced Motion removes movement from new controls.

## Verification

`bash Scripts/test_codex_usage.sh` exercises counting, model attribution,
incremental / persistent cache, partial writes, forks, archives, truncation,
pricing arithmetic / unknown rates, and reset boundaries. `--live` additionally
checks authenticated read-only usage and official pricing, and times cold/warm
scans without printing identity or credentials.

Deliver with `bash Scripts/install_local.sh release` and inspect the installed
app. The installer preserves signing, archives old builds, launches the new
bundle, and verifies the running executable against the release build.

## Visual simplification

The white Codex surface now uses a plain plan label, one period menu, and a
model-details path with a back control. Refresh and secondary destinations live
in the options menu. The overview prioritizes allowance and local tokens rather
than an unavailable aggregate cost. Model rows retain individual API estimates
and disclose token counts with rates in aligned columns; reasoning stays within
output, and zero cache-write counts no longer occupy a line. A quiet source-age
label replaces repeated status/source text, and the panel is 20 points shorter.
Model scrolling remains native, with indicators suppressed to keep columns
aligned and preserve the uncluttered presentation. Reduced Motion and explicit
unknown/reset/stale states remain supported.

## Focused Codex interaction

The latest refinement changes the composition to two full-width allowance
runways rather than dashboard columns. The segmented vector tracks animate only
when real remaining percentages change, with no continuous effect or extra
polling. Models now open into a focused detail pane. The model name, token total,
and API estimate share geometry between the list and detail pane, while back
navigation restores the selected model in the list. Token categories and prices
remain aligned, and reasoning remains explicitly part of output. The composition
uses the same monochrome system and honors Reduced Motion.
