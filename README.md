<p align="center">
  <img src="icon-preview.png" width="160" alt="Converterator icon">
  <img src="icon-preview-dark.png" width="160" alt="Converterator icon in dark mode">
</p>

# Converterator

A small native macOS app for turning PlayStation-era disc images into compressed **CHD** files, the format preferred by RetroArch, DuckStation, PCSX2, PPSSPP, MAME and most modern emulators. It can also turn a CHD back into BIN/CUE, GDI or ISO.

Drop files or whole folders in, click **Convert**, and you're done.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/screenshot-dark.png">
    <source media="(prefers-color-scheme: light)" srcset="docs/screenshot-light.png">
    <img src="docs/screenshot-light.png" width="640" alt="Converterator window with five disc images queued for conversion">
  </picture>
</p>

## What it converts

| Input | How it's converted |
|---|---|
| `.pbp` (PSP / PS1 Classics EBOOT) | Unpacked to BIN/CUE with [PSXPackager](https://github.com/RupertAvery/PSXPackager), then compressed with `chdman`. Temporary files are deleted afterwards. |
| `.cue` + `.bin` | Compressed straight to CHD with `chdman`. |
| `.gdi` | Compressed straight to CHD with `chdman`. |
| `.iso` | Compressed straight to CHD with `chdman`, as a DVD or CD image (see below). |
| `.zip`, `.7z` | Unpacked to a temporary folder, then every `.pbp`, `.cue`, `.gdi` or `.iso` inside is converted as above. The temporary files are deleted afterwards. `.7z` needs 7-Zip (`brew install sevenzip`). |
| `.chd` | Extracted back to `.cue` + `.bin` (CDs), `.gdi` + tracks (Dreamcast) or `.iso` (DVDs). |

Dropping a `.bin` on its own uses the `.cue` with the same name next to it.

**ISO images: CD or DVD.** PS2 and PSP games need DVD-type CHDs (`chdman createdvd`, made with 2048-byte hunks as PPSSPP and PCSX2 recommend; chdman's own default since 0.263 is 4096), and most other systems need CD-type ones. With **ISO images: Automatic**, Converterator looks inside each ISO: a PSP game (`PSP_GAME`) or a PS2 game (`SYSTEM.CNF` with `BOOT2`) becomes a DVD CHD, as does anything too big to fit on a CD. Everything else becomes a CD CHD. The log says which was chosen and why. Choose **Always CD** or **Always DVD** to override it. PS2 games that came on CD are best kept as BIN/CUE, which always becomes a CD CHD.

**Archives.** Dropping a `.zip` or `.7z` always adds it. A folder scan only picks up archives with a disc image inside, so a folder of zipped cartridge games doesn't fill the list. CHDs are named after the disc image inside, and saved next to the archive (or in your **Save to:** folder).

**Extracting CHDs.** `.chd` files are only picked up when you add them one by one, never from a folder scan, so re-adding a folder you already converted doesn't unpack everything in it.

## Features

- **Batch conversion.** Add any number of files or folders. Folders are searched recursively, and everything is converted one file at a time, with a status and progress bar for each. An overall bar shows progress through the whole batch ("Converting file 3 of 10") with an estimate of the time left, and the Dock icon shows the batch percentage. When the batch ends, a summary of converted, failed and not-started files, the total time taken and the space saved stays up, and if you're in another app a notification tells you it's done. The Mac won't idle-sleep while a batch runs (the display still can, and closing a laptop's lid still sleeps it). Progress is weighted by file size, so big discs count for more than small ones, and CHDs that already exist don't throw off the estimate.
- **Missing track files are caught early.** If a `.cue` or `.gdi` lists a track file that isn't there, it's marked failed with the missing file's name as soon as it's added.
- **Drag and drop.** Drop files on the window or on the Dock icon, or use **Open With → Converterator** in Finder.
- **Convert from Finder.** Select files or folders in Finder, right-click, and choose **Convert with Converterator** (under **Quick Actions** or **Services**, depending on your macOS version). They're added to the list and converted straight away; turn that off in **Settings** (⌘,) to only add them. If it doesn't appear, open Converterator once, or turn it on in **System Settings → Keyboard → Keyboard Shortcuts → Services → Files and Folders**. The app never makes itself the default for these file types.
- **Space saved.** Each finished file shows its CHD's size and how much smaller it is than the original, for example "412 MB, saved 260 MB (39%)". PBPs are already compressed, so their CHDs often aren't smaller.
- **Verify.** Turn on **Verify CHDs after writing** to check each CHD's checksums with `chdman verify`. A new CHD that fails is deleted and the originals are kept. CHDs that already exist are verified too, so adding a folder again with Verify on checks everything in it. If `chdman` stops making progress for 3 minutes (it can hang on a badly damaged CHD), the file is marked failed and the batch moves on.
- **Multi-disc games get playlists.** Each disc of a multi-disc PBP becomes its own `.chd`, with an `.m3u` playlist so emulators can swap discs. Separate disc files get one too: after a batch, CHDs named like `Game (USA) (Disc 1).chd` and `Game (USA) (Disc 2).chd` in the same folder get `Game (USA).m3u` ("Disc 2 of 3", " - Disc 2" and "CD2" are recognised too). A playlist that already lists those discs is left alone, and one Converterator wrote earlier is updated when a later disc arrives. Turn off **Make .m3u playlist for multi-disc games** to skip all of this.
- **Output location.** Files are saved next to each source file by default, or all in one folder you choose with **Save to:**.
- **Skips existing CHDs.** Re-running a folder only converts what's new. Turn on **Overwrite existing CHDs** to replace them instead.
- **Check dumps against Redump.** [Redump](http://redump.org) publishes the checksums of known good disc dumps. Each BIN/CUE, GDI or ISO is checked before it's compressed, and its status line shows **✓ Redump**, **⚠ partial Redump match** (some tracks differ) or **⚠ not in Redump**. The log names the matching game. With **Move source files to Trash** on, the originals of dumps that don't match are kept. PBPs are a repackaged format, so they can't be checked.
  - **DAT files download themselves.** When Converterator opens, it checks redump.org (at most once a day) and downloads newer DATs for the systems chosen in **Settings** (⌘,): PlayStation, PS2, PSP, Sega CD, Saturn and Dreamcast to start with. Only the request for the file goes out; nothing about you or your files is sent. redump.org only offers plain HTTP, so the app allows that for redump.org alone. Turn downloading off, pick other systems, or add your own DAT files in Settings. Downloaded DATs are kept in `~/Library/Application Support/Converterator/Redump`.
  - **Name CHDs after Redump.** Turn on **Name CHDs after the matching Redump game** in Settings, and a dump that matches gets Redump's exact title, like `Armored Core (USA).chd`, instead of the original file's name.
- **Check CHDs you already have.** **File → Check CHDs Against Redump…** takes CHDs or folders of them, unpacks each to a temporary folder (one file per track, as Redump lists them), checks it, and deletes the temporary files. It needs free space for one disc at a time. Afterwards, **Rename to Redump Names** gives each matching CHD its Redump title and fixes any `.m3u` next to it. Results are remembered: a CHD that hasn't changed (same size and date) isn't unpacked again the next time, unless you turn on **Check again if checked before**. A "no match" is rechecked automatically when newer DATs are loaded. CHDs converted with the Redump check on are remembered from the start.
  - **Dreamcast** GD-ROM CHDs are unpacked in Redump's layout, so CHDs made from Redump sets match. A CHD made from a GDI (TOSEC) image matches too if the game has three tracks, which most do. GDI files leave out the gaps between later tracks, so games with more tracks may show as a partial match.
- **Library report.** **File → Library Report…** looks over a whole folder (your ROMs folder, say) without changing anything, and lists:
  - disc images not converted yet, with **Add All to Converter**
  - originals that already have CHDs, with **Clean Up…**
  - multi-disc games with a disc missing ("has disc 1, 3; missing 2"), using "Disc 2 of 3" in the name or Redump's disc count when it knows the game
  - multi-disc games without a playlist, with **Make Playlists**
  - how many CHDs match Redump, don't match, or haven't been checked yet (from remembered results, so nothing is unpacked), with **Check Unchecked…**
- **Clean up originals.** For folders you converted without the Trash option: choose **File → Clean Up Originals…**, pick a folder, and Converterator lists every disc image (and zip or 7z of them) that already has its CHD next to it, or in your **Save to:** folder. A multi-disc PBP counts when every CHD in its `.m3u` is there. CHDs renamed after Redump are found too, from a record Converterator keeps of what it converted. Untick anything you want to keep and click **Move to Trash**. With **Verify each CHD before moving its originals** on (the default), each CHD is checked with `chdman verify` first, and anything whose CHD fails stays. If two files would share one CHD name (say, many `Disc 1.cue` files and one shared **Save to:** folder), they're left out, since it's unclear which one the CHD came from.
- **Optional cleanup.** Turn on **Move source files to Trash after a successful conversion** to clear out the originals. That's the `.pbp`, `.cue`, `.gdi` or `.iso`, plus any `.bin` or track files a `.cue` or `.gdi` lists. When extracting, it's the `.chd`. Files go to the Trash, so they can be restored, and only after every CHD for that game was newly written. If a CHD already existed and was skipped, the originals stay. The option turns itself off each time the app starts.
- **Cancel and retry.** **Cancel** asks you to confirm, then stops the current file and deletes its unfinished CHD. Finished CHDs and your original files are kept, and files not yet started stay in the list. **Clear → Retry Failed** re-queues only the failures.
- **Keyboard shortcuts.** ⌘O Add Files, ⌘Return Convert, ⌘. Stop Converting, ⌘K Clear Finished, ⇧⌘K Clear All, ⌘R Retry Failed, ⌘L show or hide the log. Select files in the list (⌘-click or Shift-click for several) and press Delete to remove them.
- **Log.** **Show Log** displays the full output from PSXPackager and `chdman` for troubleshooting.
- **Check for updates.** Click **Check for Updates** under the version number, or choose **Converterator → Check for Updates…**. The app asks GitHub for the latest release and, if it's newer, offers **Install and Relaunch**: it downloads the release, checks that it's signed with the same Developer ID and approved by Gatekeeper, replaces itself, and reopens. If anything doesn't check out, nothing is changed and you can download it from GitHub instead. It only checks when you ask and sends nothing about you. (The only other automatic connection is the once-a-day Redump DAT check, which you can turn off.) (Updating from 1.6.0 or earlier still goes through the download page; one-click install works from 1.7.0 on.)
- Your output folder and option settings are remembered between launches.

## Download

Get `Converterator.zip` from the [latest release](https://github.com/nickgudauskas/Converterator/releases/latest), unzip it, and move **Converterator.app** to your Applications folder. The app is **universal**: the same download runs natively on both Apple Silicon and Intel Macs.

Release builds from 1.2.1 on are signed with a Developer ID and **notarized by Apple**, so they open with a normal double-click. (Releases 1.0–1.2.0 weren't notarized and needed **System Settings → Privacy & Security → Open Anyway** the first time.)

You still need to install `chdman`. See the requirements below.

## Requirements

- macOS 14 (Sonoma) or later. Apple Silicon or Intel.
- **chdman**, from Homebrew:
  ```bash
  brew install rom-tools
  ```
  If you don't have Homebrew, install it first from [brew.sh](https://brew.sh).

Nothing else is needed. PSXPackager is built into the app and carries its own copy of .NET, so you don't need to install .NET.

If `chdman` can't be found, a banner at the top of the window explains how to install it, with buttons to copy the command and open Terminal. It disappears by itself once `chdman` is installed.

## Building

You need Xcode or the Xcode Command Line Tools (for `swiftc` and `codesign`).

```bash
git clone https://github.com/nickgudauskas/Converterator.git
cd Converterator
./build.sh
```

The first build downloads PSXPackager v1.8.0 (the Apple Silicon and Intel builds) from its GitHub releases into `vendor/`. The script compiles the app for both architectures, merges them with `lipo` into one universal app, and bundles both PSXPackager builds. The app uses the one that matches the Mac it's running on. (PSXPackager is a .NET single-file app and can't be merged with `lipo`.) The result is `Converterator.app` in the same folder. Move it to `/Applications` to install it. You can build on either kind of Mac.

`./build.sh` signs the app ad-hoc, which is fine on your own Mac. A copy moved to another Mac would be blocked by Gatekeeper until allowed with **System Settings → Privacy & Security → Open Anyway**.

### Testing

```bash
./tests/test.sh
```

It makes small sample disc images (CD, PS2/PSP/plain ISOs, a Dreamcast GD-ROM, zips, a damaged CHD and a Redump DAT that knows some of them), compiles the app's code with `tests/Tests.swift`, and checks conversion, verify, extraction, archives, playlists, Redump matching and renaming, CHD checks and remembered results, Clean Up Originals, the Library Report and the updater's signature checks. It takes about half a minute and needs `chdman`. Add `--network` to also download one real DAT from redump.org. Everything happens in a temporary folder; your settings, Application Support folder and Trash aren't touched.

### Signing and notarizing a release

You need an Apple Developer account with a **Developer ID Application** certificate in your Keychain. Save your notarization login once (it asks for an [app-specific password](https://account.apple.com)):

```bash
xcrun notarytool store-credentials converterator-notary --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
```

Then run:

```bash
./notarize.sh
```

The script:
1. builds and signs every executable with your Developer ID, hardened runtime, and a secure timestamp. PSXPackager also gets the .NET permissions listed in `psxpackager.entitlements`.
2. submits the app to Apple.
3. staples Apple's ticket to the app.
4. writes `dist/Converterator.zip`, ready to upload.

To use a profile with a different name, set `NOTARY_PROFILE`.

### Changing the icon

The icon is drawn in code by `make_icon.swift`. It writes `AppIcon.icon`, an [Icon Composer](https://developer.apple.com/icon-composer/) icon with a purple background in light mode, a graphite one in dark mode, and the disc artwork as a layer. On macOS 26 and later, the system uses the matching version for **System Settings → Appearance → Icon & widget style** (Default, Dark, Clear or Tinted). Earlier versions of macOS show the light icon. `build.sh` compiles it with `actool`.

Edit `make_icon.swift`, then regenerate and rebuild:

```bash
swift make_icon.swift
./build.sh
```

## Project layout

| File | Purpose |
|---|---|
| `Sources/` | The app's Swift code, one file per area: `Converter.swift` (the conversion queue, PSXPackager and `chdman`), `Redump.swift` (DATs, matching, downloads, remembered results), `Cleanup.swift`, `CHDCheck.swift`, `LibraryReport.swift`, `Playlist.swift`, `Updates.swift`, the windows (`ContentView.swift`, `SettingsView.swift`) and `App.swift` (entry point, menus, Finder service). |
| `tests/test.sh`, `tests/Tests.swift` | The tests (see below). |
| `build.sh` | Downloads PSXPackager if needed, compiles, and assembles and signs `Converterator.app`. |
| `notarize.sh` | Builds with Developer ID signing, notarizes with Apple, staples, and zips into `dist/`. |
| `psxpackager.entitlements` | Hardened-runtime permissions the bundled .NET PSXPackager needs. |
| `make_icon.swift` | Draws the app icon in light and dark versions. |
| `AppIcon.icon` | The generated Icon Composer icon that `build.sh` compiles into the app. |
| `icon-preview.png`, `icon-preview-dark.png` | Full-size previews of the light and dark icons. |

## Credits

- [PSXPackager](https://github.com/RupertAvery/PSXPackager) by RupertAvery, for PBP extraction.
- [chdman](https://docs.mamedev.org/tools/chdman.html) from the MAME project, for CHD compression.

Converterator doesn't modify either tool. It runs them as separate programs. `chdman` isn't included; you install it yourself. The built app includes an unmodified copy of PSXPackager, which `build.sh` downloads.

## License

Converterator is released under the [MIT License](LICENSE). PSXPackager, bundled inside the app, is also MIT-licensed. Its license is included in the app at `Contents/Resources/psxpackager/LICENSE`. chdman is part of MAME and keeps its own license.
