# TotalMac

[![Self checks](https://github.com/smokey7428/TotalMac/actions/workflows/selfchecks.yml/badge.svg)](https://github.com/smokey7428/TotalMac/actions/workflows/selfchecks.yml)

A native macOS dual‑pane file manager built in the spirit of [Total Commander](https://www.ghisler.com/index.htm).

Total Commander itself is a closed‑source Windows/Delphi application written by **Christian Ghisler**
(C. Ghisler & Co., Switzerland). This is not a port of his code — it is an independent Mac application
that reproduces the interaction model that makes Total Commander fast to use: two panes side by side,
a keyboard‑first workflow, function keys, and a keyboard cursor that is separate from the selection.

> **Please support the original.** If you enjoy working this way, buy a Total Commander licence at
> [ghisler.com](https://www.ghisler.com/order.htm). That is what keeps the original alive and improving —
> on Windows, Android and beyond. The in‑app **About TotalMac** window says the same thing.

Native SwiftUI + AppKit (the file list is a real `NSTableView`, so columns, sorting, drag & drop and
inline editing behave like they should on macOS). Archive support is built on the **libarchive** that
ships with macOS.

Source: <https://github.com/smokey7428/TotalMac>. Licensed under the [MIT licence](LICENSE).

---

## Build & run

Requires macOS 14 or newer and Xcode command line tools (Swift 6+).

```bash
git clone https://github.com/smokey7428/TotalMac.git
cd TotalMac
./build.sh                 # release build + TotalMac.app in ./dist (+ archived in dist/versions)
open dist/TotalMac.app
```

For a debug build: `swift build && ./.build/debug/TotalMac`.

The build script generates the app icon (`scripts/make_icon.swift`) and ad‑hoc signs the bundle.

### Versions

Every build is stamped with a version and kept, so you can always go back to the one
that worked:

* `VERSION` holds the version string (currently **1.5.0**); the build number
  auto‑increments in `.build-number` each time you build.
* `build.sh` stamps `CFBundleShortVersionString`, `CFBundleVersion`,
  `TotalMacBuildNumber` and the build date into the bundle, then copies the finished
  app to `dist/versions/TotalMac-<version>-b<build>-<date>.app`. The newest 20 are
  kept (`KEEP=5 ./build.sh` to change that, `ARCHIVE=0 ./build.sh` to skip archiving).
* **App Versions** (⇧⌘V, or *TotalMac ▸ App Versions…*) lists everything in that
  folder with its version, build date and size, and lets you **Open** a build to try
  it, **Reveal** it in the Finder, **Make Current** (copy it over the running app and
  relaunch) or **Delete** it. The About window shows the version, build number and
  build time of the app you are running.

### Headless self test

Everything except the SwiftUI layer is covered by a built‑in test suite:

```bash
./.build/debug/TotalMac --selftest
```

It builds a temporary tree and exercises the whole engine — **232 checks, all passing**:

| Area | Coverage |
|---|---|
| Listing | hidden files, parent row, sizes, extensions, TC attribute flags, read‑only detection |
| Copy / move | recursive trees, byte‑accurate contents, metadata, same‑volume fast path, self‑copy refusal |
| Conflicts | replace, skip, keep both (`name 2.txt`), cancellation, symlink handling |
| Wildcards | `*`, `?`, alternatives, substring fallback, invalid patterns |
| Archives | pack, list, extract, permissions/date round trip, symlinks, conflict policies, partial extraction, delete‑inside‑archive, add‑to‑archive, tar.gz, interop with `ditto`, path‑traversal defence |
| Archive browsing | entering an archive from a pane, navigating inside it, leaving it, history |
| Panels | asynchronous loading, navigation, history, filtering, sorting, selection, tabs, the TC cursor |
| Synchronise | left/right/only/newer/size/content comparison, non‑recursive mode, executing a sync |
| Multi‑rename | mask expansion, search/replace, regex, case, extension modes, date placeholders, collisions, two‑phase swap rename |
| Large transfers | an 80 MB file copies byte‑exact with progress reaching the total, monotonic reports, the cross‑volume flushing path, and move‑then‑delete |
| Stall detection | fraction, ETA, rate, indeterminate scans, and "no news for 30 s" being reported as stalled |
| Favorites | seeding, nesting in groups, add/dedupe, rename, re‑point, reorder, delete, missing‑folder detection, JSON round trip |
| Volumes | every mounted volume listed once, external media flagged, startup disk first then externals, deepest‑match resolution, ejectability |

The same suite runs on **every push to `main`** in GitHub Actions
([workflow](.github/workflows/selfchecks.yml)): on a macOS 15 runner it builds with
`./build.sh`, verifies the version stamp matches the `VERSION` file, then runs the
checks from inside the bundled app.

---

## What it does

### Drives and favorites
* **Click the location name** at the top of a pane and the favorites appear right there, followed by
  submenus for **Volumes** and **History** — the Total Commander way of clicking the directory header.
* **⌘D** opens the **Favorites** window (Total Commander's *directory hotlist*): a list with groups,
  one‑click navigation, search, "only existing" filter, and buttons to add the current folder, add a
  folder *inside* a group, create groups, edit, delete and reorder. **⇧⌘D** adds the current folder.
  The list lives in `~/Library/Application Support/TotalMac/favorites.json`.
* Favorites can point **inside an archive** too: `…/bundle.zip/docs` reopens the archive and steps into
  that folder.
* **⌥F1 / ⌥F2** (or the toolbar drive button, or *Go ▸ Choose Drive*) open the **drive chooser** for the
  left / right pane, listing every mounted volume with its icon, capacity and free space, and an **Eject**
  button for external media. Double‑click a drive to open it in that pane.
* External / removable volumes (USB sticks, hard drives, disk images) are listed **first** and badged, so
  the drive you just plugged in is one click away. `Volumes`, mount/unmount and rename notifications
  refresh the list automatically — plugging the drive in while the app is open is picked up live.

### Two panes
* Independent folder, sort order, filter, selection, scroll position and history per pane.
* Tabs in each pane (⌘T / ⌘W, ⌘1…⌘9).
* `Tab` switches the active pane; the active pane gets an accent bar and a blue tab highlight.
* `⇧⌘U` swaps the two panes. Editable path field with `~` and `file://` support, plus a Places/history menu.
* Per‑pane status bar: item counts, recursive size of the selection (background), and free space.

### The file list
* Columns: Name, Ext, Size, Date, Attr (Total Commander style `d-a--` attribute flags).
* Sort by clicking a header, natural ordering (`file2` before `file10`), folders first, `..` row at the top.
* Quick filter with `*` / `?` wildcards and `;` / `,` alternatives (⌘F).
* Type‑ahead: start typing to jump to a file. Inline rename (`F2` / `⇧F6`, `Esc` cancels).
* Hidden files (⇧⌘.) and exact byte counts (⇧⌘B) toggles. Symlinks shown with `→ target`, never followed.

### The Total Commander cursor
* `Space` toggles the row under the cursor and steps down one row.
* `Enter` opens the row under the cursor (folders navigate, files open in their default app).
* Operations act on the marked files, or on the file under the cursor when nothing is marked.
* Quick Look is on `⌘Y` so `Space` can keep the Total Commander meaning.

### File operations
* **F5 copy** / **F6 move** — a dialog with the destination prefilled from the other pane, browse button,
  *Other pane* / *This folder* / *Home* shortcuts, the item list, and a live copy/move switch.
* Progress HUD with percentage, bytes, speed, ETA and a working Cancel.
* Conflicts ask per item — *Replace / Skip / Keep both / Cancel* — with **Apply to all** and the details of
  both files. *Keep both* generates `name 2.txt`, `name 3.txt`, …
* Byte‑accurate streaming copy (1 MB chunks) preserving permissions, timestamps, extended attributes,
  ACLs and Finder metadata. Same‑volume moves are an instant rename. Folder merges merge.
* **Big files onto slow drives just work.** A fast reader writing to a slower destination (an external
  USB drive) used to push gigabytes of dirty pages into the page cache until the kernel blocked the
  writer — which looked exactly like a frozen transfer. Cross‑volume copies now bypass the page cache
  (`F_NOCACHE`) and flush to the device in bounded 32 MB windows, so the reported progress tracks the
  drive and the rest of the Mac stays responsive.
* The progress HUD shows the rate and ETA, and if the destination stops reporting progress for 8 seconds
  it says **“waiting for the drive”** and offers **Force Stop**, which frees the app (and warns that the
  destination file may be incomplete) instead of leaving every later file operation blocked.
* The up‑front folder scan reports progress too, so packing up a huge tree is not a silent wait.
* **F8** moves to the Trash; **⇧F8** deletes permanently after a confirmation.
* **F7** new folder (then inline‑rename), **F11** duplicate in place, **⌘C/⌘X/⌘V** internal clipboard.
* Errors are collected and summarised instead of aborting the run. Work happens off the main thread.

### Archives (ZIP, TAR, TAR.GZ, TAR.BZ2, TAR.XZ, 7z, RAR, ISO, CPIO, … read)
* **Browse archives in the pane itself**, like Total Commander: `Enter` on a `.zip` enters it, folders
  inside it navigate, `Backspace` / `..` step up, and stepping up from the archive root leaves it.
  History works across the boundary.
* Members show size, date, permissions and symlink targets; virtual folders report their total size.
* **F5** extracts the selection to the other pane (with progress, conflict prompts and a real Move that
  extracts and then rewrites the archive).
* **⌥F5** packs the selection into a new archive — name, format (ZIP / TAR.GZ / TAR) and compression level.
* **Drag & drop**: drop files *onto* an archive row — or onto a pane that is browsing an archive — and they
  are copied into it.
* **F8 inside an archive** rebuilds the archive without the selected members; **⌘V** adds to it.
* **⇧F9** tests an archive (reads every member, verifying CRCs) and reports the totals.
* Read‑only formats (7z, RAR, ISO…) can be browsed and extracted from; trying to modify one explains why
  it is refused instead of silently producing a broken file.
* Path traversal (`../`, absolute names) is stripped, and extraction never writes *through* a symlink
  created by the archive itself.

### Compare & synchronise directories (F9)
A Total Commander style synchronise window:
* Walks both panes (optionally non‑recursively), matching by relative path.
* Status per row: *same / left only / right only / left newer / right newer / size differs / content
  differs / type differs* — colour coded.
* Compare by content performs a chunked byte comparison instead of trusting timestamps.
* Optional wildcard mask; "only differences" filter; include hidden files toggle.
* Per‑row action button (click to cycle: none → → → ← → delete left → delete right) plus *All →*, *← All*,
  *Clear*. The confirmation lists exactly what will happen and how many items will be deleted.
* Runs through the shared operation queue, so you get progress and the usual error summary.

### Multi‑rename tool (⌃M or ⇧F4)
* Rename mask with placeholders: `[N]` name, `[E]` extension, `[F]` full name, `[C]` counter,
  `[Y]` `[M]` `[D]` date, `[h]` `[m]` `[s]` time — combined freely, e.g. `[Y]-[M]-[D]_[N]_[C]`.
* Search & replace (literal or regular expression) on the name part.
* Case conversion (lower / UPPER / Capitalised) and extension modes (keep / lower / upper / replace / remove).
* Counter with start, step and zero padding.
* Live preview table showing old → new for every file, with duplicates and existing targets flagged in red.
* Safe application: files are moved to temporary names first, so swaps and cycles work; failures roll back.
* Optional "overwrite existing files".

### Viewing, editing, tools
* **F3** Lister window: Text / Hex / Image / PDF / Info modes, magic‑number detection, 8 MB preview cap.
* **F4** opens with the default editor; "Open With ▸" lists installed applications.
* **⌘Y** Quick Look for the selection (using the system preview panel).
* **Get Info** (⌥⌘I) with permissions, attributes, dates, symlink target, volume free space and a
  background folder size — and it knows about archive members.
* **About TotalMac** with the credit and support link to the original developer.

---

## Keyboard reference (F1 in the app)

| Key | Action |
|---|---|
| `Tab` | Switch the active pane |
| `⌘D` | Favorites window (directory hotlist) |
| `⇧⌘D` | Add the current folder to the favorites |
| `⌥F1` / `⌥F2` | Choose a drive for the left / right pane |
| Click the location name | Favorites, volumes and history for that pane |
| `Enter` / double click | Open folder, file, or **archive** |
| `Space` | Mark the cursor row and step down |
| `Backspace` | Parent folder (or up inside an archive) |
| `F1` | Help |
| `F2`, `⇧F6` | Rename (inline) |
| `F3` | View (text/hex/image/PDF) |
| `F4` | Edit with the default editor |
| `⇧F4`, `⌃M` | Multi‑rename tool |
| `F5` | Copy to the other pane… (extracts when inside an archive) |
| `⌥F5` | Pack the selection into a new archive… |
| `F6` | Move to the other pane… |
| `F7` | New folder |
| `F8` | Move selection to the Trash (rebuilds the archive when inside one) |
| `⇧F8` | Delete permanently |
| `F9` | Compare & synchronise the two panes |
| `⌥F9` | Extract the archive selection to the other pane |
| `⇧F9` | Test the archive under the cursor |
| `⌘⇧F8` | Copy full paths |
| `F11` | Duplicate selection |
| `⌘Y` | Quick Look |
| `⌘T` / `⌘W` | New tab / close tab |
| `⌘1…⌘9` | Jump to tab |
| `⌘[` / `⌘]` | Back / forward in history |
| `⌘↑` / `⇧⌘H` | Parent folder / home folder |
| `⌘R` | Refresh both panes |
| `⌘F` | Quick filter |
| `⌘A` / `⇧⌘A` | Select all / select none |
| `⇧⌘I` | Invert selection |
| `⌘C` / `⌘X` / `⌘V` | Internal clipboard copy / cut / paste (into an archive while browsing one) |
| `⇧⌘U` | Swap panes |
| `⇧⌘.` / `⇧⌘B` | Hidden files / byte sizes |
| `⌥⌘I` | Get info |
| `⇧⌘V` | App Versions window |

Right‑click menus cover everything, including *Select Group…*, *Reveal in Finder*, *Open in New Tab*,
*Pack into Archive…*, *Multi‑Rename…*, *Compare Directories…* and *Test archive*.

---

## Project layout

```
Package.swift                     SwiftPM manifest (macOS 14+, Swift 5 language mode)
Resources/Info.plist              bundle metadata
build.sh                          release build → dist/TotalMac.app (icon + ad-hoc signing)
scripts/make_icon.swift           generates the AppIcon artwork
Sources/CArchive/                 thin C shim over the system libarchive
  include/tmac_archive.h            the handful of entry points we need, declared locally
  tmac_archive.c                    read / extract-to-disk / create implementations
Sources/TotalMac/
  App/TotalMacApp.swift           @main, scenes (main, viewer, about), menus, --selftest hook
  Models/FileItem.swift           a list row: sizing, permissions, TC attribute flags, archive membership
  Models/PanelModel.swift         one pane: tabs, locations (folder or archive), selection, cursor, history
  Models/AppModel.swift           both panes, clipboard, commands, global keyboard handling
  Services/FileSystemService.swift listing, sorting, wildcards, measuring, name collisions
  Services/TransferEngine.swift   copy/move/delete engine: streaming, conflicts, metadata
  Services/ArchiveService.swift   libarchive wrapper: list, extract, pack, rewrite, path safety
  Services/SyncService.swift      directory comparison and synchronisation
  Services/MultiRenameService.swift  mask expansion, preview, safe two-phase rename
  Services/VolumeService.swift    mounted volumes, external media detection, eject
  Services/FavoritesStore.swift   the directory hotlist, persisted as JSON
  Services/VersionService.swift   version stamps, archived builds, switching versions
  Services/OperationCenter.swift  background queue + published progress for every operation
  Services/ConflictUI.swift       the shared "file already exists" dialog
  Support/SelfTest.swift          232 headless checks
  Views/FileListView.swift        NSTableView wrapper: columns, rename, drag & drop, Quick Look, menus
  Views/PanelView.swift           one pane: tabs, location menu, path bar, filter, status bar
  Views/MainView.swift            split view, toolbar, status strip, function key bar, dialogs
  Views/ToolsView.swift           Pack, Synchronise, Multi-rename and About windows
  Views/FavoritesView.swift       the location popup, the favorites window and the drive chooser
  Views/VersionsView.swift        the App Versions window
  Views/ViewerWindow.swift        Lister window (text / hex / image / PDF / info)
```

Project memory lives in [`AGENTS.md`](AGENTS.md): architecture, the invariants that
must not be broken, the traps already hit, and the history of what landed when.

### Notes on the design

* A pane's location is a small value type (`PanelLocation`) that is either an on‑disk folder or an archive
  plus an internal path. Navigation, history, the path bar and every operation route through it, which is
  what lets archives behave like folders without special cases spreading everywhere.
* `PanelModel` keeps a raw listing plus a sorted/filtered `display` array, so the table only reloads when
  the content actually changes (a cheap signature compare in the coordinator).
* Panels load asynchronously with a token so stale results from a fast navigation are discarded.
* libarchive's headers are no longer in the macOS SDK, so `Sources/CArchive` declares the ~30 functions we
  use with ABI‑correct signatures and the constants copied from `archive.h`. That keeps the build
  self‑contained while still using the fast, in‑process system library.
* Conflict prompts are modal `NSAlert`s shown from the worker queue via `DispatchQueue.main.sync`, so the
  engines stay single‑threaded while the user still gets proper dialogs.

---

## Not implemented (yet)

Where this still differs from a 30‑year‑old original:

* **FTP/SFTP/WebDAV / cloud panes** and the plugin APIs (WCX packer, WDX content, WFX file system).
* **Encrypted archives** — password‑protected ZIP/AES and 7z entries are detected and reported, but there is
  no passphrase prompt yet.
* **Rewriting exotic formats** — 7z, RAR, ISO, CAB, XAR, DMG and friends can be browsed and extracted from;
  only ZIP and TAR variants can be *modified*.
* **Nested archives** (an archive inside an archive) are read as data: extract, then open. There is no
  in‑place nesting.
* **Comparing by content inside a sync run** is per file and on demand; there is no "compare by content"
  viewer with a side‑by‑side diff.
* Button bar customisation, saved tab sets / `F12` configuration, custom columns, internal associations,
  thumbnail view.

Natural next steps: FTP/SFTP, an archive passphrase prompt, a side‑by‑side content diff, and a directory
hotlist.

## Known limitations

* macOS asks for permission the first time the app touches Desktop, Documents, Downloads or an external
  volume. Grant it in *System Settings ▸ Privacy & Security ▸ Files and Folders* (or give the app Full Disk
  Access for system folders).
* The app is ad‑hoc signed, which is fine locally; distributing it would need a Developer ID certificate
  and notarisation.
* Archives cannot be entered from a *read‑only* location, and modifying an archive is a full rewrite, so it
  needs free space roughly the size of the archive.
* Deleting to the Trash requires the volume to have a trash — otherwise use ⇧F8.

## Licence

MIT — see [LICENSE](LICENSE). You may use, modify and redistribute this code freely,
including commercially; the only requirement is that the copyright notice is kept.

Total Commander itself is **not** part of this project and is not covered by this
licence. It is Christian Ghisler's proprietary software — please
[buy a licence](https://www.ghisler.com/order.htm) if you use it. The MIT licence
also grants no rights to the “Total Commander” name or logo.
