#!/bin/bash
# Sources the signing environment, if any. Looked up in order:
#   ~/.config/simpledisplay/signing.env
#   ~/.config/remotedisplay/signing.env   (shared with Remote Display: same Developer ID)
# Variables (either SD_ or RD_ prefix): *_SIGNING_KEYCHAIN, *_SIGNING_KEYCHAIN_PASSWORD,
# *_NOTARY_PROFILE. Nothing here is required: without it, signing is ad hoc.
for f in "$HOME/.config/simpledisplay/signing.env" "$HOME/.config/remotedisplay/signing.env"; do
  if [ -f "$f" ]; then . "$f"; break; fi
done
SIGNING_KEYCHAIN="${SD_SIGNING_KEYCHAIN:-${RD_SIGNING_KEYCHAIN:-}}"
SIGNING_KEYCHAIN_PASSWORD="${SD_SIGNING_KEYCHAIN_PASSWORD:-${RD_SIGNING_KEYCHAIN_PASSWORD:-}}"
NOTARY_PROFILE="${NOTARY_PROFILE:-${SD_NOTARY_PROFILE:-${RD_NOTARY_PROFILE:-remotedisplay-notary}}}"
