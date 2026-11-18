<p align="center"><img src="icon-preview.png" width="160" alt="Converterator icon"></p>

# Converterator

A small native macOS app for turning PlayStation-era disc images into compressed **CHD** files, the format preferred by RetroArch, DuckStation, MAME and most modern emulators.

Drop files or whole folders in, click **Convert**, and you're done.

## What it converts

| Input | How it's converted |
|---|---|
| `.pbp` (PSP / PS1 Classics EBOOT) | Unpacked to BIN/CUE with [PSXPackager](https://github.com/RupertAvery/PSXPackager), then compressed with `chdman`. Temporary files are deleted afterwards. |
| `.cue` + `.bin` | Compressed straight to CHD with `chdman`. |
| `.gdi` | Compressed straight to CHD with `chdman`. |
| `.iso` | Compressed straight to CHD with `chdman`. |

Dropping a `.bin` on its own uses the `.cue` with the same name next to it.

## Features

- **Batch conversion.** Add any number of files or folders. Folders are searched recursively, and everything is converted one file at a time, with a status and progress bar for each.
- **Drag and drop.** Drop files on the window or on the Dock icon, or use **Open With → Converterator** in Finder. The app never makes itself the default for these file types.
- **Multi-disc PBPs.** Each disc becomes its own `.chd`. An `.m3u` playlist is written so emulators can swap discs (this can be turned off).
- **Output location.** CHDs are saved next to each source file by default, or all in one folder you choose with **Save CHDs to:**.
- **Skips existing CHDs.** Re-running a folder only converts what's new. Turn on **Overwrite existing CHDs** to replace them instead.
- **Cancel and retry.** **Cancel** stops after cleaning up the current file. **Clear → Retry Failed** re-queues only the failures.
- **Log.** **Show Log** displays the full output from PSXPackager and `chdman` for troubleshooting.
- Your output folder and option settings are remembered between launches.

## Requirements

- macOS 14 (Sonoma) or later. Apple Silicon or Intel.
- **chdman**, from Homebrew:
  ```bash
  brew install rom-tools
  ```
- PSXPackager needs the **.NET 10 runtime** to unpack `.pbp` files:
  ```bash
  brew install dotnet
  ```
  This is only needed for `.pbp` input. CUE, GDI and ISO conversion works without it.

If `chdman` or PSXPackager can't be found, the app shows a warning banner at the top of the window.

## Building

You need Xcode or the Xcode Command Line Tools (for `swiftc` and `codesign`).

```bash
git clone https://github.com/nickgudauskas/Converterator.git
cd Converterator
./build.sh
```

The first build downloads PSXPackager v1.8.0 from its GitHub releases into `vendor/` and bundles it inside the app. The result is `Converterator.app` in the same folder. Move it to `/Applications` to install it.

The app is ad-hoc signed for your own Mac. It isn't notarized, so copies sent to other Macs will be blocked by Gatekeeper until they're allowed in **System Settings → Privacy & Security**.

### Changing the icon

The icon is drawn in code by `make_icon.swift`. Edit it, then regenerate `icon.icns` and `icon-preview.png` and rebuild:

```bash
swift make_icon.swift
iconutil -c icns AppIcon.iconset -o icon.icns && rm -rf AppIcon.iconset
./build.sh
```

## Project layout

| File | Purpose |
|---|---|
| `main.swift` | The whole app: SwiftUI interface, the conversion queue, and running PSXPackager and `chdman`. |
| `build.sh` | Downloads PSXPackager if needed, compiles, and assembles and signs `Converterator.app`. |
| `make_icon.swift` | Draws the app icon. |
| `icon.icns`, `icon-preview.png` | The generated icon. |

## Credits

- [PSXPackager](https://github.com/RupertAvery/PSXPackager) by RupertAvery, for PBP extraction.
- [chdman](https://docs.mamedev.org/tools/chdman.html) from the MAME project, for CHD compression.

Converterator only runs these tools. It doesn't include or modify their code.
