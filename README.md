# Mac Key Switcher

A native menu-bar app for Apple Silicon Macs (macOS 13+) that fixes text typed in
the wrong keyboard layout (EN ↔ RU). If you type a Russian word while the English
layout is active (or vice versa), Mac Key Switcher converts it — automatically as
you type, or on demand with **Double Shift**. Every replacement is reversible, and
in any context it cannot verify as safe the app **changes nothing** (fail-closed).

## Features

- **Automatic correction** — detects a word typed in the wrong layout and fixes it
  in place as you finish typing (can be toggled off).
- **Manual conversion (Double Shift)** — press Shift twice to convert the last
  completed word; press again to toggle the replacement back to the original.
- **Custom shortcut** — instead of Double Shift, record your own key combination
  for manual conversion.
- **Reversible replacements** — the last change can always be rolled back, so a
  wrong guess never costs you your text.
- **Language detector** — an offline EN/RU frequency dictionary is bundled in the
  app; no system dictionary, no network, no external word source.
- **Technical-token awareness** — identifiers, URLs and code-like tokens
  (`user_name`, `a/b`, `x=1`, `http://…`, `k=v&x=y`) are recognized and left alone.
- **Per-app exclusions** — exclude any application from automatic correction, with
  a one-click **"Exclude current application"** menu item.
- **Word exceptions** — maintain a list of words that should never be converted.
- **User-selected layout pair** — you pick the English and Russian layouts the app
  works with.
- **Guided onboarding** — a single first-run flow: choose layouts → privacy
  explanation → grant the two required permissions one at a time → done.
- **Native settings** — a grouped SwiftUI `Form` with sections for status,
  permissions, layouts, automation and exclusions; errors shown in context.
- **Accessibility** — state is never conveyed by color alone; full VoiceOver
  labels on controls, buttons and status.
- **Menu-bar status** — shows the active input language and current app state.

## Privacy

- **No network.** The app contains no networking code; the detector dictionary is
  compiled into the build.
- **No stored input.** Typed text, clipboard contents, hashes and telemetry are
  never persisted or transmitted.
- **Fail-closed.** Any doubt about whether the input context is safe ends the
  session without modifying text.

The privacy boundary is enforced by an automated audit test suite.

## Requirements

- Apple Silicon Mac, macOS 13 (Ventura) or later.
- Swift 6 toolchain to build from source.

## Build from source

```sh
swift build --configuration release --arch arm64
swift test
Scripts/package-app.sh      # produces .build/MacKeySwitcher.app (ad-hoc signed)
```

After first launch, grant **Accessibility** and **Input Monitoring** in
System Settings → Privacy & Security.

## Install a prebuilt release

Prebuilt builds are published under [Releases](../../releases) as `.dmg` and `.zip`.

> **This app is distributed without the Apple Developer Program**, so it is not
> notarized and is ad-hoc signed. On first launch macOS shows a Gatekeeper
> warning. This is expected — bypass it one of these ways:

1. **Right-click → "Open"** on the app in Applications, then "Open" again in the
   dialog.
2. If it says "damaged", clear the quarantine attribute:
   ```sh
   xattr -dr com.apple.quarantine "/Applications/Mac Key Switcher.app"
   ```
3. Or System Settings → Privacy & Security → **"Open Anyway"** after the first
   launch attempt.

You can verify download integrity against the `*.sha256` file attached to the
release.

## Licenses

- The detector's language data is derived from
  [FrequencyWords](https://github.com/hermitdave/FrequencyWords) under
  **CC BY-SA 4.0**; see
  [ATTRIBUTION](Resources/LanguageDetector/source/ATTRIBUTION.md) and
  [LICENSE](Resources/LanguageDetector/source/LICENSE.md).
- The application source license is at the repository owner's discretion (add a
  `LICENSE` file if required).
