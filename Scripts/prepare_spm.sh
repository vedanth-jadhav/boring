#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/toolchain.sh
mkdir -p .spm-generated/helper
# Keep unchanged helper inputs' timestamps so incremental builds can reuse them.
for source in BoringNotchXPCHelper/*.swift Shared/*.swift; do
  target=".spm-generated/helper/$(basename "$source")"
  if [[ ! -f "$target" ]] || ! cmp -s "$source" "$target"; then
    cp -p "$source" "$target"
  fi
done
# Swift build resolves changed manifests itself. Existing checkouts and the
# build graph can be reused without a redundant resolution pass.
if [[ ! -f .build/workspace-state.json ]]; then
  apple_swift package resolve --skip-update >/dev/null
fi
python3 - <<'PY'
from pathlib import Path
import re
# These pinned dependencies use the State spelling that SDK 27 resolves to
# a macro unavailable in standalone CLT. Select the public wrapper explicitly.
for package in ('KeyboardShortcuts', 'Defaults', 'SkyLightWindow', 'swiftui-introspect'):
    sources = Path('.build/checkouts') / package / 'Sources'
    for source in sources.rglob('*.swift'):
        text = source.read_text()
        updated = re.sub(r'@State\b', '@CLIViewState', text)
        if updated != text:
            source.chmod(source.stat().st_mode | 0o200)
            source.write_text(updated)
    module = sources if package == 'swiftui-introspect' else sources / package
    if module.exists():
        alias = module / 'CLIViewState.swift'
        text = 'import SwiftUI\n\ntypealias CLIViewState<Value> = SwiftUI.State<Value>\n'
        if not alias.exists() or alias.read_text() != text:
            alias.write_text(text)
path = Path('.build/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/ConflictPolicy.swift')
if path.exists():
    path.chmod(path.stat().st_mode | 0o200)
    text = path.read_text()
    old = '''extension EnvironmentValues {
\t@Entry
\tvar keyboardShortcutsConflictPolicy = KeyboardShortcuts.ConflictPolicy.default
}'''
    new = '''private struct KeyboardShortcutsConflictPolicyKey: EnvironmentKey {
    static let defaultValue = KeyboardShortcuts.ConflictPolicy.default
}

extension EnvironmentValues {
    var keyboardShortcutsConflictPolicy: KeyboardShortcuts.ConflictPolicy {
        get { self[KeyboardShortcutsConflictPolicyKey.self] }
        set { self[KeyboardShortcutsConflictPolicyKey.self] = newValue }
    }
}'''
    if old in text:
        path.write_text(text.replace(old, new))
path = Path('.build/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/Recorder.swift')
if path.exists():
    path.chmod(path.stat().st_mode | 0o200)
    text = path.read_text()
    marker = '#Preview {'
    while marker in text:
        start = text.index(marker)
        depth = 0
        end = None
        for index in range(start + len('#Preview '), len(text)):
            if text[index] == '{': depth += 1
            elif text[index] == '}':
                depth -= 1
                if depth == 0:
                    end = index + 1
                    break
        if end is None: raise RuntimeError('Unclosed KeyboardShortcuts preview')
        text = text[:start] + text[end:]
    if text != path.read_text():
        path.write_text(text)
PY
