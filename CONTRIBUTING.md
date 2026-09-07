# Contributing to SimpleDisplay

Thank you for your interest in contributing!

## Prerequisites

- macOS 14.0+
- Xcode Command Line Tools (`xcode-select --install`)
- Swift 5.9+

## Build Instructions

```bash
git clone https://github.com/SamuelRioTz/SimpleDisplay.git
cd SimpleDisplay
make run        # Debug build and launch
make run-release # Release build and launch
make dmg        # Build, sign, and create DMG
```

## Project Structure

```
Sources/
  SimpleDisplay/
    SimpleDisplayApp.swift          # App entry point (MenuBarExtra)
    Models/
      DisplayInfo.swift             # Display and DisplayMode models
    Services/
      DisplayService.swift          # Physical display management (CG APIs)
      VirtualDisplayService.swift   # Virtual display creation (private API)
    ViewModels/
      DisplayManagerViewModel.swift # Main app state
    Views/
      MenuBarContentView.swift      # Root menu bar popover
      DisplayRowView.swift          # Individual display row
      VirtualDisplayEditorView.swift # Create/edit virtual displays
      SettingsView.swift            # App settings
      DisplayConfigView.swift       # Device presets data
  VirtualDisplayBridge/
    VirtualDisplayWrapper.m         # ObjC bridge for CGVirtualDisplay
    include/
      VirtualDisplayBridge.h        # Bridge header
```

## Code Signing

`make sign` always applies the Hardened Runtime. The identity is picked by
`scripts/sign-identity.sh`: the maintainer's team **Developer ID Application**
certificate when the Mac has it, otherwise ad-hoc (`-`). Contributors and CI get
ad-hoc builds, which is fine for development but makes Gatekeeper block the app on
first launch (System Settings → Privacy & Security → Open Anyway).

```bash
make sign        # bundle + codesign (Developer ID if available, else ad hoc)
make dmg         # signed DMG
make notarize    # Developer ID only: notarize + staple the app and the DMG
```

The Developer ID lives in a dedicated keychain whose password, together with the
`notarytool` profile name, is read from `~/.config/simpledisplay/signing.env` (or
`~/.config/remotedisplay/signing.env`, shared with Remote Display) by
`scripts/signing-env.sh`. Nothing of it is in the repository.

> **Note:** SimpleDisplay uses private Apple APIs (`CGVirtualDisplay`,
> `CGSConfigureDisplayEnabled`). It cannot be distributed via the Mac App Store, but
> notarization is an automated malware scan and accepts them.

## Releasing

The git tag is the single source of truth for the version (`git describe`).

1. `git tag -a vX.Y.Z -m "..."` and `git push origin main vX.Y.Z`.
2. The **Release** workflow builds an ad-hoc DMG on a GitHub runner and creates the
   GitHub release with it (about a minute).
3. On the maintainer's Mac, `make release` builds, signs with the Developer ID,
   notarizes and staples the app and the DMG, and replaces the workflow's DMG on the
   release (`gh release upload --clobber`). `spctl` must report
   `source=Notarized Developer ID`.
4. Write the release notes by hand (`gh release edit vX.Y.Z --notes-file ...`); the
   generated ones are empty because commits land on `main` without pull requests.

## Guidelines

- Open an issue first for significant changes
- Keep PRs focused on a single change
- Match existing code style
- Test on both Apple Silicon and Intel if possible
- Don't add features beyond what was discussed in the issue

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
