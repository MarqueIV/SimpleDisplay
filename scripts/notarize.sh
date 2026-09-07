#!/usr/bin/env bash
# Notarize with Apple and staple, so Gatekeeper opens the app without the "unidentified
# developer" block. Requires a Developer ID signature (hardened runtime, secure timestamp)
# and a notarytool keychain profile (`xcrun notarytool store-credentials`), see
# scripts/signing-env.sh. Fails on any verdict other than Accepted and prints Apple's log.
#
#   notarize.sh app <App.app>              zip the bundle, submit, staple the bundle
#   notarize.sh dmg <file.dmg> <SIGN_ID>   sign the image, submit, staple, assess with spctl
set -euo pipefail
. "$(dirname "$0")/signing-env.sh"

submit() { # submit <file>
  local f="$1" out id status
  out=$(xcrun notarytool submit "$f" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1) || true
  id=$(echo "$out" | sed -n 's/^ *id: //p' | head -1)
  status=$(echo "$out" | sed -n 's/^ *status: //p' | tail -1)
  echo "notarization of $(basename "$f"): ${status:-no answer} (id ${id:-?})"
  if [ "$status" != "Accepted" ]; then
    echo "$out"
    [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" || true
    return 1
  fi
}

case "${1:-}" in
  app)
    app="$2"
    codesign --verify --deep --strict "$app"
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    /usr/bin/ditto -c -k --keepParent "$app" "$tmp/app.zip"
    submit "$tmp/app.zip"
    xcrun stapler staple -q "$app"; echo "stapled: $app"
    ;;
  dmg)
    dmg="$2"; sign_id="$3"
    codesign --force --timestamp --sign "$sign_id" "$dmg"
    submit "$dmg"
    xcrun stapler staple -q "$dmg"; echo "stapled: $dmg"
    spctl -a -vv --type open --context context:primary-signature "$dmg" 2>&1 | sed 's/^/  gatekeeper: /'
    ;;
  *)
    echo "usage: notarize.sh app <App.app> | dmg <file.dmg> <SIGN_ID>" >&2; exit 2
    ;;
esac
