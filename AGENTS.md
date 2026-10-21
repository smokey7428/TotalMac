# TotalMac — project memory

Everything an agent (or a human six months from now) needs to pick this up again:
what it is, where things live, how to build and test it, the invariants that must
not be broken, and the traps already stepped in.

**Owner's quick facts**

| | |
|---|---|
| Location | a clone of this repository; the commands below assume its root |
| Repository | **https://github.com/smokey7428/TotalMac** (public, branch `main`, MIT licensed) |
| What | A native macOS dual-pane file manager in the spirit of Total Commander |
| Language | Swift 6 / SwiftUI + AppKit, one C shim over libarchive (Swift 5 language mode) |
| Size | ~10,300 lines across 22 source files |
| Build | `./build.sh` → `dist/TotalMac.app` (+ a copy in `dist/versions/`) |
| Test | `./.build/debug/TotalMac --selftest` → **232 checks, all passing** |
| Version | Single source of truth: the `VERSION` file; build number in `.build-number` |

### Publishing

`dist/`, `.build/` and `.build-number` are gitignored, so the repo holds sources
only (~290 KB). Commits are authored as `smokey7428 <smokey7428@users.noreply.github.com>`;
the identity is set **per repo**, so the machine's global git config is untouched.

```bash
git add -A && git commit -m "…" && git push        # origin = https://github.com/smokey7428/TotalMac.git
```

### Continuous integration

`.github/workflows/selfchecks.yml` runs on every push to `main` and on pull
requests: it builds with `./build.sh` (release), asserts that the bundle's
`CFBundleShortVersionString` equals the `VERSION` file and that a build number was
stamped, then runs `dist/TotalMac.app/Contents/MacOS/TotalMac --selftest` — the
**bundled** app, not the debug binary — and uploads the `.app` as an artifact.

Two things learned the hard way:

* `runs-on: macos-latest` now resolves to an **arm64** runner and those are often
  starved of capacity ("The job was not acquired by Runner of type hosted even after
  multiple attempts" after ~15 minutes). The workflow pins **`macos-15`** (Intel),
  which starts promptly. GitHub's current image there is macOS 15.7.9 with Xcode 16.4
  / Swift 6.1.2, which is enough: `swift-tools-version` is 6.0 and the code targets
  macOS 14.
* The self-test prints the mounted volumes, so on a runner it legitimately shows only
  "Macintosh HD[startup disk]" — the volume checks are written to cope with that.

---

## 1. Build, run, test

```bash
cd TotalMac                # the root of this repository

./build.sh                 # release + stamp version + archive in dist/versions
./build.sh debug           # debug configuration
ARCHIVE=0 ./build.sh       # build only, no archived copy
KEEP=10 ./build.sh         # keep the newest 10 archived builds (default 20)

open dist/TotalMac.app
./.build/debug/TotalMac --selftest      # 232 headless checks, exit code 0/1
```

`build.sh` stamps `CFBundleShortVersionString` (from `VERSION`), `CFBundleVersion`
and `TotalMacBuildNumber` (auto-incrementing) plus `TotalMacBuildDate` into the
bundle, generates the icon, ad-hoc signs, and copies the result to
`dist/versions/TotalMac-<version>-b<build>-<yyyymmdd-hhmm>.app`.
`dist/TotalMac.app` stays the "current" one; the app's **App Versions** window
(⇧⌘V) lists the archive and can switch back to an older build.

### Gotcha: never pipe a build into `head`

`swift build | head -5` gets SIGPIPE, dies mid-compile and leaves orphaned
`swift-frontend`/`clang` processes holding a lock (they show as 0% CPU, reparented
to launchd, and the *next* build hangs for ~8 minutes). Redirect to a file instead:

```bash
swift build > /tmp/b.log 2>&1; grep -E "error:|warning:" /tmp/b.log
```

---

## 2. Where everything lives

```
Package.swift                    SwiftPM: CArchive (C shim, links -larchive) + TotalMac
VERSION                          the version string, bumped by hand
.build-number                    auto-incrementing build counter (build.sh)
Resources/Info.plist             bundle template, stamped by build.sh
build.sh                         build + stamp + icon + sign + archive + prune
scripts/make_icon.swift          draws the .icns artwork
Sources/CArchive/                libarchive shim (the macOS SDK has no archive.h)
  include/tmac_archive.h           read / extract / create entry points
  tmac_archive.c                   implementation, constants copied from archive.h
Sources/TotalMac/
  App/TotalMacApp.swift          @main, scenes (main, viewer, about, favorites, versions),
                                 menus, AppDelegate, --selftest hook
  Models/FileItem.swift          a row: sizing, permissions, TC attribute flags, archive membership
  Models/PanelModel.swift        one pane: tabs, locations, selection, cursor, history
  Models/AppModel.swift          both panes, clipboard, favorites, volumes, commands, keyboard
  Services/FileSystemService.swift   listing, sorting, wildcards, measuring (with progress), st_dev
  Services/TransferEngine.swift      copy/move/delete: POSIX streaming, conflicts, metadata,
                                     OpProgress, CancelToken, TransferContext
  Services/OperationCenter.swift     the operation queue, published progress, force stop
  Services/ConflictUI.swift          the shared "file already exists" dialog
  Services/ArchiveService.swift      list/extract/pack/rewrite, path safety, conflict policy
  Services/SyncService.swift         directory compare + execute
  Services/MultiRenameService.swift  masks, preview, two-phase rename
  Services/VolumeService.swift       mounted volumes, external detection, eject
  Services/FavoritesStore.swift      the hotlist, JSON in Application Support
  Services/VersionService.swift      version stamp reading, archived builds, switching
  Support/SelfTest.swift         232 checks, the whole engine
  Views/FileListView.swift       NSTableView wrapper: columns, rename, drag & drop, Quick Look, menus
  Views/PanelView.swift          one pane: tabs, location popup, path bar, filter, status bar
  Views/MainView.swift           split view, toolbar, status strip, function key bar, dialogs
  Views/ToolsView.swift          Pack, Synchronise, Multi-rename, About
  Views/FavoritesView.swift      location popup, favorites window, drive chooser
  Views/VersionsView.swift       the App Versions window
  Views/ViewerWindow.swift       Lister (text / hex / image / PDF / info)
```

User data lives in `~/Library/Application Support/TotalMac/favorites.json`.
Viewing an archive member extracts it to `…/T/TotalMac-preview/<uuid>/` (wiped at
launch and on quit).

---

## 3. Invariants — do not break these

1. **`Tab` switches panes, `Space` marks and steps down.** That is the Total
   Commander contract; Quick Look is on `⌘Y` precisely so `Space` stays free.
2. **The keyboard monitor (`AppModel.handleKeyEvent`) is the single source of
   truth for function keys.** It runs before the menu system, consumes what it
   handles, and must pass through while a text view is the first responder
   (`isEditingText`).
3. **F-keys belong to the monitor, not to menus.** Menu items show the shortcut as
   text (e.g. `"Copy to Other Panel  (F5)"`) rather than registering it, otherwise
   a key can fire twice.
4. **`⌘C/⌘X/⌘V/⌘A/⌘D/⌘Y` are handled in the monitor and skipped while editing
   text**, so text fields keep the standard clipboard.
5. **A pane's location is either a folder or an archive + internal path**
   (`PanelLocation`). Navigation, history, the path bar and every operation route
   through it. Archive members carry `FileItem.archive` and must never be passed to
   `FileManager` directly — `AppModel.materialize(items:)` extracts them first.
6. **`isSameVolume` compares `st_dev`** (falling back to the parent when the target
   does not exist). Never trust `volumeIdentifier` casts, and never let a cross
   volume move take the `moveItem` fast path — that is how a silent, progress-less
   copy happens.
7. **Cross-volume copies flush in bounded windows with `F_NOCACHE`** (32 MB). Do
   not turn this into a plain buffered write loop; see §4.
8. **Nothing long runs on the main thread.** Panels, measuring, archives, transfers
   and the sync engine all run off it with a token/generation guard for stale results.
9. **Every operation is cancellable and the app must never be locked out.**
   `OperationCenter` uses a concurrent queue and `forceStop()`; the completion path
   checks `context === context` so an abandoned worker cannot clobber the UI.
10. **`--selftest` must stay green** and must not touch anything outside its temp
    folder (no Trash, no mounts, no user files).

---

## 4. Traps already stepped in (and the fixes)

| Trap | Symptom | Fix |
|---|---|---|
| `tmac_is_symlink` masked with `0120000` instead of comparing the type field | Every regular file matched as a symlink; archives extracted as 100-byte files of zeros | `(filetype & 0170000) == TMAC_IF*` |
| `ARCHIVE_EXTRACT_SECURE_SYMLINKS` | Extraction failed on `/var/…` paths (macOS `/var` **is** a symlink) | Dropped the flag, pass `SECURE_NODOTDOT`, and guard against writing through a symlink the archive itself created |
| Stale archive cache | After rebuilding an archive, a pane browsing it still showed deleted members | `PanelModel.invalidateArchiveCache()` from `afterFileOperation()` |
| Rewriting a `.7z` | Would silently write a **zip renamed to `.7z`** | `ArchiveService.canRewrite` refuses non ZIP/TAR formats |
| Panels never loaded | The app opened with two empty panes | `PanelModel.init` calls `reload()`; a panel‑level test now covers it |
| Nested `ObservableObject` | The progress HUD never updated (SwiftUI does not observe `app.operations.progress`) | `OperationProgressView` observes `OperationCenter` directly |
| Buffered copy to a slow drive | **The user's bug**: a move to a USB drive froze at ~25%, the bar stopped, and the app refused every later operation | POSIX copy with `F_NOCACHE` + `fsync` every 32 MB for cross-volume work, stall detection after 8 s, Force Stop, concurrent queue |
| `Task { @MainActor … }` progress flood + `isBusy` | Cancel could not interrupt a blocked syscall and the app stayed "busy" forever | `forceStop()` + `context` identity check |
| `swift build \| head` | Orphaned compilers, 8-minute build hangs | Log builds to a file (§1) |
| Swift: `@ViewBuilder` recursion | `some View` cannot refer to itself | Type-erase with `AnyView` for recursive menus |
| Swift: backslash continuation | Invalid inside a **single-line** string literal (fine in `"""` blocks) | Use `"""` or one long line |
| Swift: `.systemRed` | No such `Color` member | `Color.red` or `Color(nsColor: .systemRed)` |
| SwiftPM C target | `archive_write_disk_header` is not an exported symbol | The disk writer uses `archive_write_header` |

---

## 5. Feature map (what is done)

* **Panes** — two panes, tabs (⌘T/⌘W/⌘1‑9), per-pane sort/filter/history, `Tab` to
  switch, `⇧⌘U` swap, editable path bar, free space + selection size in the status bar.
* **List** — Name/Ext/Size/Date/Attr columns (TC attribute flags), natural sort,
  folders first, `..` row, wildcard quick filter, type-ahead, inline rename,
  hidden-files and byte-count toggles, symlinks shown but never followed.
* **TC cursor** — `Space` marks and advances, `Enter` opens, operations fall back to
  the cursor row when nothing is marked.
* **File operations** — F5 copy / F6 move with a destination dialog, progress HUD
  with rate/ETA, per-item conflicts (Replace / Skip / Keep both / **Apply to all**),
  metadata + xattr + ACL preserving copies, instant same-volume renames, F8 trash,
  ⇧F8 permanent delete, F7 new folder, F11 duplicate, internal clipboard, error
  summary instead of abort, stall detection + Force Stop.
* **Archives** (ZIP, TAR, TAR.GZ/BZ2/XZ, 7z, RAR, ISO, CPIO…) — **browse inside the
  pane**, extract with F5 (or ⌥F9), pack with ⌥F5, delete members with F8 (rewrite),
  ⌘V to add, drop files onto an archive to add them, ⇧F9 test (CRC), path-traversal
  and symlink-escape defences. Only ZIP/TAR can be rewritten.
* **Compare & synchronise** (F9) — status per row, optional content comparison,
  per-row direction cycling, bulk buttons, confirmation listing deletions.
* **Multi-rename** (⌃M / ⇧F4) — masks `[N] [E] [F] [C] [Y] [M] [D] [h] [m] [s]`,
  search/replace (regex optional), case + extension modes, counter with padding,
  live preview with collisions flagged, two-phase (swap-safe) apply.
* **Drives & favorites** — click the location name for favorites (with Volumes and
  History submenus), ⌘D favorites window (the directory hotlist, groups, add/edit/
  delete/reorder, missing folders in red), ⇧⌘D add current, ⌥F1/⌥F2 drive chooser
  with capacity, eject for external media, live mount/unmount refresh.
* **Viewing** — F3 Lister (text/hex/image/PDF/info), F4 edit, Open With, ⌘Y Quick
  Look, ⌥⌘I Get Info (archive-aware).
* **App versions** (⇧⌘V) — every build archived, listed with version/size/date,
  Open / Reveal / Make Current / Delete / Relaunch.
* **About** — credits Christian Ghisler and asks the user to buy a Total Commander
  licence.

### Deliberately not done

FTP/SFTP/WebDAV panes and the plugin APIs (WCX/WDX/WFX); encrypted archives
(detected, not decrypted); rewriting 7z/RAR/ISO; nested archive-in-archive;
side-by-side content diff; button bar, saved tab sets, custom columns, thumbnail
view.

---

## 6. History

| Version | What landed |
|---|---|
| 1.0 | Dual-pane core: panes, tabs, TC cursor, function keys, copy/move/delete with progress and conflict prompts, Lister, help |
| 1.1 | libarchive C shim, in-pane archive browsing, pack/extract/rewrite, Quick Look, About window with the credit to Christian Ghisler |
| 1.2 | Compare & synchronise window, multi-rename tool |
| 1.3 | Volume/drive chooser with eject, favorites hotlist (⌘D), location popup |
| 1.4 | Progress-HUD observation fix, the large-file/slow-drive transfer fix (`F_NOCACHE` + bounded flush), stall detection + Force Stop, exact `st_dev` volume test |
| 1.5 | Version stamping, archived builds in `dist/versions`, the App Versions window |

### Testing note

`SelfTest.run()` is called from `applicationDidFinishLaunching` on the main thread,
so panel tests use `MainActor.assumeIsolated` and pump the run loop with
`waitForLoad`. Add new checks there rather than writing a separate harness; the
suite is the safety net for every invariant in §3.
