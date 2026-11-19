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
- **Patches (translations, fixes).** A patch is applied to a copy of the game before it's compressed, so the CHD is the patched game and your original files are never changed. IPS, BPS, PPF and xdelta patches all work (xdelta is the usual format for disc translations).
  - **Attaching a patch:** put it next to the game with the same name (`Game.xdelta` beside `Game.cue`) and it's picked up automatically; or drop the patch together with its game; or right-click a file in the list → **Add Patch…**. The list shows each file's patch and the CHD it will make. **Remove Patch** takes it off again.
  - **Several patches:** some games need more than one, such as a translation plus a bug fix. Right-click → **Add Another Patch…** adds one to apply after the others, in order, each onto the result of the one before (it may change a different track). Several patches dropped with one game are applied in name order. The CHD is named after the first patch, and the list shows them all.
  - **Patching a CHD you already have:** right-click a `.chd` → **Add Patch…** and, instead of being extracted, it's unpacked to a temporary folder, patched and compressed into a new, patched CHD next to it (e.g. `Racing Lagoon (Japan).chd` → `Racing Lagoon (English).chd`). The original CHD isn't touched. (A CHD you add on its own is still extracted: patches next to it or in the patches folder aren't picked up for CHDs automatically.)
  - **Zipped patches:** patches can stay in the `.zip` they were downloaded in, wherever a patch file works. If the zip holds several patches (versions, or versions for different releases of the game), each is tried and the first that fits is used, newest-looking first (`v1.1` before `v1.0`). A zip of patches is never mistaken for a zipped game.
  - **Patches folder:** in **Settings** (⌘,), choose a folder where you keep all your patches, loose or in their zips, in any subfolders. With **Find patches for games automatically** on, each game you add gets the patch made for it, shown in the list as "Patch from your patches folder". BPS and PPF patches are matched by checksum, so their names don't matter. xdelta and IPS patches are matched by the game's name (a patch whose name contains the game's title, such as `racinglagoonenglish.xdelta` for `Racing Lagoon (Japan).cue`), preferring your Mac's language when there are several. If a patch matched by name turns out not to fit, the game is converted without it and the log says so. You can always remove or change a found patch.
  - **Which track:** BPS and PPF patches say which file they were made for, and xdelta checks its own result, so on a disc with several tracks the right one is found and patched; the other tracks are used as they are (linked, not copied). IPS patches can't tell, so they're applied to the first track. A patch made for a different version or region of the game is refused with a message instead of producing a broken disc. Most translation patches expect the Redump dump, and the Redump check (on the original, before patching) tells you if you have it.
  - **Naming:** the CHD gets a readable name: the game's title plus what the patch is for, e.g. `racinglagoonenglish.xdelta` on `Racing Lagoon (Japan).cue` → `Racing Lagoon (English).chd`. The title comes from Redump's name for your original dump when it matches, otherwise from the original file's name, without its region and other tags. The language is spotted in the patch's name (`english`, `eng`, `en`, `T-En`, `spanish`, `ptbr`…); an undub patch gives `(Undub)`, and anything else `(Patched)`. A patch file that's already named like a title, with spaces and capitals (`Tengai Makyou Zero (English) v1.1.xdelta`), keeps its own name. The list shows the name before you convert. Only the patched CHD is made, and **Move source files to Trash** never applies to a patched game.
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
  - **patches available:** games here, converted or not, including CHDs on their own, that have a patch waiting in your patches folder, with **Convert Patched Versions** (games whose patched CHD already exists, and CHDs that are themselves patched, are left out)
  - how many CHDs match Redump, don't match, or haven't been checked yet (from remembered results, so nothing is unpacked), with **Check Unchecked…**
- **Clean up originals.** For folders you converted without the Trash option: choose **File → Clean Up Originals…**, pick a folder, and Converterator lists every disc image (and zip or 7z of them) that already has its CHD next to it, or in your **Save to:** folder. A multi-disc PBP counts when every CHD in its `.m3u` is there. CHDs renamed after Redump are found too, from a record Converterator keeps of what it converted. Untick anything you want to keep and click **Move to Trash**. With **Verify each CHD before moving its originals** on (the default), each CHD is checked with `chdman verify` first, and anything whose CHD fails stays. If two files would share one CHD name (say, many `Disc 1.cue` files and one shared **Save to:** folder), they're left out, since it's unclear which one the CHD came from.
- **Optional cleanup.** Turn on **Move source files to Trash after a successful conversion** to clear out the originals. That's the `.pbp`, `.cue`, `.gdi` or `.iso`, plus any `.bin` or track files a `.cue` or `.gdi` lists. When extracting, it's the `.chd`. Files go to the Trash, so they can be restored, and only after every CHD for that game was newly written. If a CHD already existed and was skipped, the originals stay. The option turns itself off each time the app starts.
- **Pause and resume.** While converting, **Pause** stops after the current file; **Pause → Pause Now** stops straight away and does that file again from the start when you click **Resume**. The time-remaining estimate leaves the pause out.
- **The list survives quitting.** The list of files is saved as it changes. If the app is quit, crashes or the Mac restarts mid-batch, it comes back next time with finished files still marked done and the rest waiting (including the one that was interrupted). Click **Convert** to carry on. A file on a drive that isn't connected fails with a note to connect it and use **Clear → Retry Failed**.
- **Free-space checks.** Before a batch starts, Converterator adds up what the waiting files may need on each disk and warns you if it may not fit, with **Convert Anyway** if you'd like to go ahead. Each file is checked again just before it starts, so one that doesn't fit fails with a clear message ("Not enough free space on EASYROMS: needs up to 4.2 GB, 1.1 GB free") instead of a `chdman` error partway through. Unpacking a PBP, archive or CHD also checks for room for temporary files on your Mac's disk. The estimates are upper limits; CHDs usually take much less.
- **Cancel and retry.** **Cancel** asks you to confirm, then stops the current file and deletes its unfinished CHD. Finished CHDs and your original files are kept, and files not yet started stay in the list. **Clear → Retry Failed** re-queues only the failures.
- **Keyboard shortcuts.** ⌘O Add Files, ⌘Return Convert or Resume, ⌘P Pause After This File, ⌘. Stop Converting, ⌘K Clear Finished, ⇧⌘K Clear All, ⌘R Retry Failed, ⌘L show or hide the log. Select files in the list (⌘-click or Shift-click for several) and press Delete to remove them.
- **Log.** **Show Log** displays the full output from PSXPackager and `chdman` for troubleshooting.
- **Check for updates.** Click **Check for Updates** under the version number, or choose **Converterator → Check for Updates…**. The app asks GitHub for the latest release and, if it's newer, offers **Install and Relaunch**: it downloads the release, checks that it's signed with the same Developer ID and approved by Gatekeeper, replaces itself, and reopens. If anything doesn't check out, nothing is changed and you can download it from GitHub instead. It only checks when you ask and sends nothing about you. (The only other automatic connection is the once-a-day Redump DAT check, which you can turn off.) (Updating from 1.6.0 or earlier still goes through the download page; one-click install works from 1.7.0 on.)
- Your output folder and option settings are remembered between launches.

## Download

Get `Converterator.zip` from the [latest release](https://github.com/nickgudauskas/Converterator/releases/latest), unzip it, and move **Converterator.app** to your Applications folder. The app is **universal**: the same download runs natively on both Apple Silicon and Intel Macs.

Release builds from 1.2.1 on are signed with a Developer ID and **notarized by Apple**, so they open with a normal double-click. (Releases 1.0–1.2.0 weren't notarized and needed **System Settings → Privacy & Security → Open Anyway** the first time.)

From 1.13.0, everything it needs is built in, so there's nothing else to install.

## Requirements

- macOS 14 (Sonoma) or later. Apple Silicon or Intel.

That's all. The tools Converterator uses are built into the app:
- **chdman** (from MAME), in a universal build made from MAME's source code (see [How chdman is built](#how-chdman-is-built)).
- **PSXPackager**, which carries its own copy of .NET.
- **xdelta3**, for xdelta patches: the project's own dependency-free macOS builds for Apple Silicon and Intel, combined into one.

Converterator uses its built-in chdman. If that's ever missing, it falls back to one installed with Homebrew (`brew install rom-tools`), and if there's none, a banner explains how to install it. Releases before 1.13.0 didn't include chdman and needed the Homebrew one.

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

### Releasing

```bash
./release.sh 1.12.0 notes.md
```

It checks you're on `main` with nothing uncommitted and that the version is newer than the latest release, runs the tests (and stops if any fail), sets the version in `build.sh`, builds and notarizes, commits and pushes, publishes the GitHub release with the zip and its SHA-256, then downloads it back and checks the checksum, Gatekeeper and version. Without a notes file, the commit messages since the last release are used. `--dry-run` runs the checks and tests and shows the notes without changing anything. It needs the notarization setup below.

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
| `tests/test.sh`, `tests/Tests.swift` | The tests (see below). Run on every push by `.github/workflows/tests.yml`, on an Apple Silicon and an Intel Mac. |
| `.github/workflows/chdman.yml` | Builds the bundled universal chdman from MAME's source (see [How chdman is built](#how-chdman-is-built)). |
| `release.sh` | Tests, builds, notarizes and publishes a release (see below). |
| `build.sh` | Downloads PSXPackager if needed, compiles, and assembles and signs `Converterator.app`. |
| `notarize.sh` | Builds with Developer ID signing, notarizes with Apple, staples, and zips into `dist/`. |
| `psxpackager.entitlements` | Hardened-runtime permissions the bundled .NET PSXPackager needs. |
| `make_icon.swift` | Draws the app icon in light and dark versions. |
| `AppIcon.icon` | The generated Icon Composer icon that `build.sh` compiles into the app. |
| `icon-preview.png`, `icon-preview-dark.png` | Full-size previews of the light and dark icons. |

## Credits

- [PSXPackager](https://github.com/RupertAvery/PSXPackager) by RupertAvery, for PBP extraction.
- [chdman](https://docs.mamedev.org/tools/chdman.html) from the MAME project, for CHD compression.
- [xdelta](https://github.com/jmacd/xdelta) by Joshua MacDonald, for applying xdelta patches.

Converterator doesn't modify any of these tools. It runs them as separate programs, and the app includes an unmodified copy of each, which `build.sh` downloads.

### How chdman is built

MAME's developers only publish chdman for Windows, and Homebrew's copy depends on other Homebrew libraries, so Converterator builds its own. The [Build chdman](.github/workflows/chdman.yml) workflow downloads the official MAME source for one version, builds only MAME's tools on GitHub's Apple Silicon and Intel Macs (with MAME's own copies of its compression libraries and the native macOS layer, so it needs nothing but macOS), checks that nothing outside macOS is linked, combines the two into one universal program with `lipo`, and publishes it with MAME's licenses as a [`chdman-…` release](https://github.com/nickgudauskas/Converterator/releases?q=chdman) of this repository (not marked as the latest release, so the app's update check ignores it). A `SOURCE.txt` inside names the exact MAME source archive, its SHA-256 and the workflow run. `build.sh` downloads that release, checks it against the SHA-256 in `build.sh`, and puts it in `Contents/Resources/chdman` along with MAME's licenses.

To move to a newer MAME: run **Actions → Build chdman → Run workflow** with the new version, then update `CHDMAN_VERSION` and `CHDMAN_SHA256` in `build.sh`.

## License

Converterator is released under the [MIT License](LICENSE). PSXPackager, bundled inside the app, is also MIT-licensed. Its license is included in the app at `Contents/Resources/psxpackager/LICENSE`. xdelta3 is under the Apache License 2.0; its license is included at `Contents/Resources/xdelta3/LICENSE`. chdman is part of MAME, which is distributed under the GNU General Public License, version 2 (chdman's own source file is BSD-3-Clause). The bundled copy comes with MAME's license texts in `Contents/Resources/chdman` (`COPYING` and `legal/`), and `SOURCE.txt` there says exactly which MAME source it was built from. Converterator runs chdman as a separate program; Converterator's own code stays under the MIT License.
