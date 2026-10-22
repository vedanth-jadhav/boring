# Credential broker identity

macOS login Keychain can tie locally signed executables to their code hash. A
matching certificate and bundle identifier alone do not preserve that access.
The broker owns the secret; the main app accesses it through authenticated XPC.

`Scripts/package_lyrics_keychain.sh` preserves the installed, signed v1 broker
in `~/Library/Application Support/Boring Notch/Credential Helper/`, separated by
certificate and CPU architecture. App builds, shared-source edits, compiler
updates, and deleting `.build` reuse this exact executable and signed metadata.
The persistent copy contains code only. API keys remain in macOS Keychain.

The packager checks the signature, certificate, identifier, protocol version,
architecture, and login-session configuration before reuse. It stages copies
before publishing them, serializes concurrent packaging, and stops explicitly
if a pinned broker is damaged or conflicts with the installed broker.

Treat v1 as an immutable storage protocol. Editing helper source changes fresh
installations only. Updating an existing broker requires an explicit versioned
migration that lets the old broker read and transfer its credential before it
is replaced. Never reset its identity as a cache invalidation strategy. Keep the
original Keychain item during migration; never delete it to repair permissions.

Saving is local and verifies a prompt-free readback. Network validation is a
separate settings action. Closing settings must let an already-sent storage
operation finish updating app state. Background reads never present a macOS
password dialog; pre-existing inaccessible credentials need the explicit
“Authorize saved key” action once. Keychain lock, user denial, and revoked API
keys remain recoverable errors, not reasons to erase a credential.

Checks:

- `bash Scripts/test_lyrics_credential.sh`
- `bash Scripts/test_lyrics_keychain_helper.sh`
- `bash Scripts/test_lyrics_settings.sh`
- `bash Scripts/check_lyrics_storage.sh` (installed key status only; value withheld)
