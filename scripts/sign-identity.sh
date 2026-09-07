#!/bin/bash
# Prints the code-signing identity for SimpleDisplay, chosen by TEAM, never by name:
# this Mac can hold several "Samuel Rioja" certificates from different teams. Only the
# personal team may sign this project. A "Developer ID Application" certificate of that
# team wins (distribution outside the App Store, notarizable); otherwise its
# "Apple Development" one. Exit 0 with the name on stdout, 1 if the team has no identity
# (the Makefile then falls back to ad-hoc signing, which is what CI does).
# Usage: sign-identity.sh [TEAM_ID]   (default K45698KZ4W)
TEAM="${1:-K45698KZ4W}"
pick() { # $1 = certificate kind; no pipe into `while` (a `return` there only leaves the subshell)
  local name ou
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    ou=$(security find-certificate -c "$name" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU *= *\([A-Z0-9]*\).*/\1/p')
    if [ "$ou" = "$TEAM" ]; then echo "$name"; return 0; fi
  done < <(security find-identity -v -p codesigning 2>/dev/null | grep -o "\"$1: [^\"]*\"" | tr -d '"')
  return 1
}
pick "Developer ID Application" || pick "Apple Development"
