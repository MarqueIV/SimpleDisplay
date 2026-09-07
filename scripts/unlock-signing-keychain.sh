#!/bin/bash
# Unlocks the dedicated keychain that holds the Developer ID identity. A custom keychain
# stays locked after a reboot or logout; without this, codesign pops a keychain password
# dialog and the build hangs. No-op when no signing environment is configured.
. "$(dirname "$0")/signing-env.sh"
[ -n "$SIGNING_KEYCHAIN" ] && [ -n "$SIGNING_KEYCHAIN_PASSWORD" ] || exit 0
security unlock-keychain -p "$SIGNING_KEYCHAIN_PASSWORD" "$SIGNING_KEYCHAIN"
