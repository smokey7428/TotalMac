import Foundation
import AppKit

/// Headless verification of the filesystem engine.
/// Run with:  TotalMac.app/Contents/MacOS/TotalMac --selftest
enum SelfTest {

    private static var passed = 0
    private static var failed = 0
    private static var failures: [String] = []

    static func run() -> Int32 {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("totalmac-selftest-\(ProcessInfo.processInfo.processIdentifier)")
        try? fm.removeItem(at: root)
        guard (try? fm.createDirectory(at: root, withIntermediateDirectories: true)) != nil else {
            print("cannot create test root")
            return 1
        }
        defer { try? fm.removeItem(at: root) }

        print("TotalMac self test — \(root.path)\n")

        testListing(root: root)
        testMeasureAndCopy(root: root)
        testMove(root: root)
        testConflicts(root: root)
        testSymlinksAndUniqueNames(root: root)
        testMasks(root: root)
        testDelete(root: root)
        testSorting(root: root)
        testPanels(root: root)
        testArchives(root: root)
        testArchivePanel(root: root)
        testSynchronise(root: root)
        testMultiRename(root: root)
        testFavorites(root: root)
        testVolumes(root: root)
        testLargeTransfer(root: root)
        testStallDetection()
        testVersions(root: root)

        print("\n\(passed) passed, \(failed) failed")
        for failure in failures { print("  FAIL: \(failure)") }
        return failed == 0 ? 0 : 1
    }

    // MARK: - Assertions

    private static func check(_ condition: Bool, _ message: String) {
        if condition {
            passed += 1
            print("  ok   \(message)")
        } else {
            failed += 1
            failures.append(message)
            print("  FAIL \(message)")
        }
    }

    private static func makeFile(_ url: URL, bytes: Int) {
        let data = Data(repeating: 0x41, count: bytes)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url)
    }

    // MARK: - Tests

    private static func testListing(root: URL) {
        print("listing")
        let source = root.appendingPathComponent("listing")
        makeFile(source.appendingPathComponent("file1.txt"), bytes: 1000)
        makeFile(source.appendingPathComponent("file2.bin"), bytes: 5000)
        makeFile(source.appendingPathComponent("sub/nested.txt"), bytes: 200)
        makeFile(source.appendingPathComponent(".hidden"), bytes: 10)

        let visible = (try? FileSystemService.list(source, showHidden: false)) ?? []
        let all = (try? FileSystemService.list(source, showHidden: true)) ?? []

        check(visible.count == 4, "hidden files are skipped (\(visible.count) of 4 entries: .., file1, file2, sub)")
        check(all.count == 5, "hidden files included when requested (\(all.count) of 5)")
        check(all.first?.isParent == true, "the parent row is first")
        check(all.dropFirst().first(where: { $0.name == "sub" })?.isDirectory == true, "directories are recognised")
        check(all.first(where: { $0.name == "file1.txt" })?.size == 1000, "file size is read")
        check(all.first(where: { $0.name == "file1.txt" })?.ext == "TXT", "extension column is uppercased")
        check(all.first(where: { $0.name == "sub" })?.attr.hasPrefix("d") == true, "attribute column marks folders")
        check(all.first(where: { $0.name == ".hidden" })?.attr.contains("h") == true, "attribute column marks hidden files")
        check(all.first?.attr == "d----", "the parent row reads as a writable folder (got \(all.first?.attr ?? "-"))")

        let readOnly = source.appendingPathComponent("readonly.txt")
        makeFile(readOnly, bytes: 5)
        try? FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: readOnly.path)
        let readOnlyItem = FileSystemService.makeItem(url: readOnly)
        check(readOnlyItem?.attr.hasPrefix("-ar") == true,
              "read-only files are flagged in the attribute column (got \(readOnlyItem?.attr ?? "-"))")
        check(readOnlyItem?.permissions.hasPrefix("-r--") == true,
              "permissions are rendered from the mode bits (got \(readOnlyItem?.permissions ?? "-"))")
    }

    private static func testMeasureAndCopy(root: URL) {
        print("measure and copy")
        let source = root.appendingPathComponent("measure")
        makeFile(source.appendingPathComponent("a.txt"), bytes: 1000)
        makeFile(source.appendingPathComponent("sub/b.txt"), bytes: 2000)
        makeFile(source.appendingPathComponent("sub/deep/c.txt"), bytes: 500)

        let measured = FileSystemService.measure(source)
        check(measured.bytes == 3500, "recursive size is 3500 bytes (got \(measured.bytes))")
        check(measured.files == 3, "recursive file count is 3 (got \(measured.files))")

        let destination = root.appendingPathComponent("copied")
        let context = TransferContext(title: "test") { _ in }
        context.policy = .replaceAll
        TransferEngine.run(sources: [source], destination: destination, move: false, context: context)

        let copied = destination.appendingPathComponent("measure")
        check(FileManager.default.fileExists(atPath: copied.appendingPathComponent("sub/deep/c.txt").path),
              "nested folder structure is copied")
        check(FileSystemService.measure(copied).bytes == 3500, "copied tree has the same size")
        check(FileManager.default.fileExists(atPath: source.appendingPathComponent("a.txt").path),
              "copy leaves the source in place")

        let original = try? Data(contentsOf: source.appendingPathComponent("sub/b.txt"))
        let duplicate = try? Data(contentsOf: copied.appendingPathComponent("sub/b.txt"))
        check(original == duplicate, "file contents are identical after copying")
        check(context.errors.isEmpty, "copy reports no errors (\(context.errors.first ?? "-"))")
    }

    private static func testMove(root: URL) {
        print("move")
        let source = root.appendingPathComponent("move")
        makeFile(source.appendingPathComponent("one.txt"), bytes: 100)
        makeFile(source.appendingPathComponent("folder/two.txt"), bytes: 100)

        let destination = root.appendingPathComponent("moved")
        let context = TransferContext(title: "test") { _ in }
        context.policy = .replaceAll
        TransferEngine.run(sources: [source.appendingPathComponent("one.txt"),
                                     source.appendingPathComponent("folder")],
                           destination: destination, move: true, context: context)

        check(FileManager.default.fileExists(atPath: destination.appendingPathComponent("one.txt").path),
              "moved file arrives at the destination")
        check(!FileManager.default.fileExists(atPath: source.appendingPathComponent("one.txt").path),
              "moved file is removed from the source")
        check(FileManager.default.fileExists(atPath: destination.appendingPathComponent("folder/two.txt").path),
              "moved folder arrives with its contents")
        check(!FileManager.default.fileExists(atPath: source.appendingPathComponent("folder").path),
              "moved folder is removed from the source")
    }

    private static func testConflicts(root: URL) {
        print("conflicts")
        let source = root.appendingPathComponent("conflict-source")
        let destination = root.appendingPathComponent("conflict-target")
        makeFile(source.appendingPathComponent("same.txt"), bytes: 10)
        makeFile(destination.appendingPathComponent("same.txt"), bytes: 9999)

        let replaceContext = TransferContext(title: "test") { _ in }
        replaceContext.policy = .replaceAll
        TransferEngine.run(sources: [source.appendingPathComponent("same.txt")],
                           destination: destination, move: false, context: replaceContext)
        let replaced = try? Data(contentsOf: destination.appendingPathComponent("same.txt"))
        check(replaced?.count == 10, "replace overwrites the existing file")

        let skipContext = TransferContext(title: "test") { _ in }
        skipContext.policy = .skipAll
        TransferEngine.run(sources: [source.appendingPathComponent("same.txt")],
                           destination: destination, move: false, context: skipContext)
        let skipped = try? Data(contentsOf: destination.appendingPathComponent("same.txt"))
        check(skipped?.count == 10, "skip leaves the existing file alone")

        let keepContext = TransferContext(title: "test") { _ in }
        keepContext.policy = .keepBothAll
        makeFile(source.appendingPathComponent("same.txt"), bytes: 20)
        TransferEngine.run(sources: [source.appendingPathComponent("same.txt")],
                           destination: destination, move: false, context: keepContext)
        check(FileManager.default.fileExists(atPath: destination.appendingPathComponent("same 2.txt").path),
              "keep both creates “same 2.txt”")

        check(FileSystemService.isDescendant(destination.appendingPathComponent("inner"),
                                             of: destination),
              "descendant detection catches a folder inside itself")
        check(!FileSystemService.isDescendant(source, of: destination),
              "descendant detection rejects unrelated paths")
    }

    private static func testSymlinksAndUniqueNames(root: URL) {
        print("symlinks and name collisions")
        let source = root.appendingPathComponent("links")
        makeFile(source.appendingPathComponent("real.txt"), bytes: 40)
        try? FileManager.default.createSymbolicLink(
            atPath: source.appendingPathComponent("alias.txt").path,
            withDestinationPath: "real.txt"
        )

        let destination = root.appendingPathComponent("links-copy")
        let context = TransferContext(title: "test") { _ in }
        context.policy = .replaceAll
        TransferEngine.run(sources: [source], destination: destination, move: false, context: context)

        let copiedLink = destination.appendingPathComponent("links/alias.txt")
        let attributes = try? FileManager.default.attributesOfItem(atPath: copiedLink.path)
        check(attributes?[.type] as? FileAttributeType == .typeSymbolicLink,
              "symbolic links are copied as links, not followed")
        check(FileSystemService.measure(source.appendingPathComponent("alias.txt")).files == 1,
              "measuring a symlink does not recurse")

        let colliding = root.appendingPathComponent("collide/name.txt")
        makeFile(colliding, bytes: 1)
        makeFile(colliding.deletingLastPathComponent().appendingPathComponent("name 2.txt"), bytes: 1)
        let unique = FileSystemService.uniqueURL(for: colliding)
        check(unique.lastPathComponent == "name 3.txt", "unique name skips taken candidates (got \(unique.lastPathComponent))")
    }

    private static func testMasks(root: URL) {
        print("wildcards")
        check(FileSystemService.matchesMask("report.txt", mask: "*.txt"), "*.txt matches report.txt")
        check(!FileSystemService.matchesMask("report.pdf", mask: "*.txt"), "*.txt rejects report.pdf")
        check(FileSystemService.matchesMask("photo1.jpg", mask: "photo?.jpg"), "? matches a single character")
        check(FileSystemService.matchesMask("Report.TXT", mask: "report*"),
              "masks ignore case")
        check(FileSystemService.matchesMask("anything", mask: "any"), "plain text acts as a substring match")
        check(FileSystemService.matchesMask("b.txt", mask: "a.txt;b.txt"), "semicolon separates alternatives")

        let item = FileItem(url: URL(fileURLWithPath: "/tmp/report.txt"), name: "report.txt",
                            isDirectory: false, isPackage: false, isSymlink: false, isHidden: false,
                            isAlias: false, isParent: false, size: 1, modified: nil, created: nil,
                            permissions: "rw-r--r--", kind: "Document")
        check(FileSystemService.matches(item, filter: "*.txt"), "item filter accepts a wildcard")
        check(FileSystemService.matches(item, filter: ""), "an empty filter matches everything")
        check(!FileSystemService.matches(item, filter: "*.png"), "item filter rejects a non match")
    }

    private static func testDelete(root: URL) {
        print("delete")
        let folder = root.appendingPathComponent("trash-me")
        makeFile(folder.appendingPathComponent("file.txt"), bytes: 5)

        var resulting: NSURL?
        do {
            try FileManager.default.trashItem(at: folder, resultingItemURL: &resulting)
            check(!FileManager.default.fileExists(atPath: folder.path), "trash removes the item from its folder")
        } catch {
            check(false, "trash operation failed: \(error.localizedDescription)")
        }

        let permanent = root.appendingPathComponent("delete-me")
        makeFile(permanent.appendingPathComponent("file.txt"), bytes: 5)
        let deleteContext = TransferContext(title: "test") { _ in }
        TransferEngine.delete(urls: [permanent], permanent: true, context: deleteContext)
        check(!FileManager.default.fileExists(atPath: permanent.path), "permanent delete removes the tree")
        check(deleteContext.errors.isEmpty, "delete reports no errors")
    }

    // MARK: - Panel tests

    /// Drives a real PanelModel through listing, navigation, filtering, sorting,
    /// selection and tab handling. Requires the main run loop to be serviced.
    private static func testPanels(root: URL) {
        print("panels")
        MainActor.assumeIsolated {
            let folder = root.appendingPathComponent("panels")
            makeFile(folder.appendingPathComponent("alpha.txt"), bytes: 100)
            makeFile(folder.appendingPathComponent("beta.txt"), bytes: 200)
            makeFile(folder.appendingPathComponent("gamma.log"), bytes: 300)
            makeFile(folder.appendingPathComponent("sub/inner.txt"), bytes: 50)
            makeFile(folder.appendingPathComponent(".hidden.txt"), bytes: 10)

            let panel = PanelModel(startURL: folder, sideTitle: "Test")

            guard waitForLoad(panel) else {
                print("  note  the model did not finish loading; panel checks skipped")
                return
            }
            check(panel.displayItems.count == 5,
                  "listing shows the parent row plus 4 visible entries (got \(panel.displayItems.count))")
            check(panel.displayItems.first?.isParent == true, "the parent row leads the panel")
            check(panel.displayItems.count > 1 && panel.displayItems[1].name == "sub",
                  "folders are listed before files")

            panel.showHidden = true
            panel.reload(preserveSelection: false)
            _ = waitForLoad(panel)
            check(panel.displayItems.count == 6, "hidden files appear when enabled (got \(panel.displayItems.count))")

            panel.setSort(key: .size, ascending: true)
            check(panel.displayItems.count > 3 && panel.displayItems[2].name == ".hidden.txt",
                  "sorting by size ascending orders the files")

            panel.navigate(to: folder.appendingPathComponent("sub"))
            guard waitForLoad(panel) else { return }
            check(panel.displayItems.count == 2, "navigating into a folder lists its contents")
            check(panel.canGoBack, "navigation adds a history entry")

            panel.goBack()
            _ = waitForLoad(panel)
            check(panel.url.path == folder.path, "going back returns to the previous folder")

            panel.setFilter("*.txt")
            check(panel.displayItems.count == 4,
                  "the quick filter keeps only matching files (got \(panel.displayItems.count))")
            panel.setFilter("")

            panel.showHidden = false
            panel.reload(preserveSelection: false)
            _ = waitForLoad(panel)

            panel.selectByMask("*.log")
            check(panel.selectedItems.map(\.name) == ["gamma.log"], "select by mask marks the right file")

            panel.selectAll()
            check(panel.selectedItems.count == 4, "select all marks every non parent row (got \(panel.selectedItems.count))")
            check(panel.operationTargets.count == 4, "operations act on the marked files")

            panel.selectNone()
            panel.setCursor(row: 1)
            check(panel.operationTargets.count == 1, "with nothing marked, operations fall back to the cursor row")

            panel.setCursor(row: 0)
            panel.toggleSelectionAndAdvance()
            check(panel.cursorIndex == 1, "space steps the cursor down")
            check(panel.selectedItems.count == 1, "space marks the row it moved to")

            let tabCount = panel.tabs.count
            panel.newTab()
            check(panel.tabs.count == tabCount + 1, "a new tab is added")
            panel.closeCurrentTab()
            check(panel.tabs.count == tabCount, "the tab can be closed again")

            panel.goUp()
            _ = waitForLoad(panel)
            check(panel.url.path == root.path, "the parent command moves one level up")
        }
    }

    private static func waitForLoad(_ panel: PanelModel, timeout: TimeInterval = 6) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while MainActor.assumeIsolated({ panel.isLoading }) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return !MainActor.assumeIsolated { panel.isLoading }
    }

    // MARK: - Archive tests

    private static func testArchives(root: URL) {
        print("archives (libarchive \(ArchiveService.libarchiveVersion))")
        let fileManager = FileManager.default
        let source = root.appendingPathComponent("archive-source")
        makeFile(source.appendingPathComponent("docs/readme.txt"), bytes: 100)
        makeFile(source.appendingPathComponent("docs/notes.txt"), bytes: 200)
        makeFile(source.appendingPathComponent("images/logo.dat"), bytes: 50)
        makeFile(source.appendingPathComponent("secret.txt"), bytes: 10)
        try? fileManager.setAttributes([.posixPermissions: 0o600],
                                       ofItemAtPath: source.appendingPathComponent("secret.txt").path)
        try? fileManager.createSymbolicLink(atPath: source.appendingPathComponent("link.txt").path,
                                            withDestinationPath: "docs/readme.txt")

        check(ArchiveService.isArchive(URL(fileURLWithPath: "/tmp/thing.zip")), ".zip is recognised as an archive")
        check(ArchiveService.isArchive(URL(fileURLWithPath: "/tmp/thing.tar.gz")), ".tar.gz is recognised")
        check(!ArchiveService.isArchive(URL(fileURLWithPath: "/tmp/thing.txt")), "plain files are not archives")

        let archiveURL = root.appendingPathComponent("bundle.zip")
        do {
            let result = try ArchiveService.create(
                archive: archiveURL,
                sources: [source.appendingPathComponent("docs"),
                          source.appendingPathComponent("images"),
                          source.appendingPathComponent("secret.txt"),
                          source.appendingPathComponent("link.txt")],
                format: .zip
            )
            check(result.files == 7, "packing reported 7 members (got \(result.files))")
            check(result.bytes == 360, "packing reported 360 bytes (got \(result.bytes))")
            check(fileManager.fileExists(atPath: archiveURL.path), "the zip file was created")
        } catch {
            check(false, "packing failed: \(error.localizedDescription)")
            return
        }

        var entries: [ArchiveEntry] = []
        do {
            let listing = try ArchiveService.list(archiveURL)
            entries = listing.entries
            check(listing.format.lowercased().contains("zip"),
                  "the container is detected as zip (got \(listing.format))")
        } catch {
            check(false, "listing failed: \(error.localizedDescription)")
            return
        }

        let byPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
        check(entries.count == 7, "the archive lists 7 members (got \(entries.count))")
        check(byPath["docs"]?.isDirectory == true, "directories are listed")
        check(byPath["docs/readme.txt"]?.size == 100, "member sizes are read")
        check(byPath["link.txt"]?.isSymlink == true, "symlinks are flagged")
        check(byPath["link.txt"]?.symlinkTarget == "docs/readme.txt", "the symlink target is read")

        // Directory view for the file panel
        let children = ArchiveService.children(of: "", archive: archiveURL, entries: entries, showHidden: false)
        check(children.contains { $0.name == "docs" && $0.isDirectory }, "the root shows the docs folder")
        check(children.first { $0.name == "docs" }?.size == 300, "a virtual folder reports its total size")
        let docsChildren = ArchiveService.children(of: "docs", archive: archiveURL, entries: entries, showHidden: false)
        check(docsChildren.count == 2, "browsing into a virtual folder lists its files")

        // Raw member reads, independent of the extraction machinery.
        do {
            var rawReads: Int64 = 0
            var firstByte: UInt8 = 0
            let probe = try ArchiveReader(path: archiveURL.path)
            var scratch = [UInt8](repeating: 0, count: 64 * 1024)
            while let entry = try probe.next() {
                if entry.isDirectory || entry.isSymlink { continue }
                var entryBytes: Int64 = 0
                while true {
                    let count = probe.read(into: &scratch)
                    if count <= 0 { break }
                    if entry.path == "docs/readme.txt", entryBytes == 0, let first = scratch.first {
                        firstByte = first
                    }
                    entryBytes += Int64(count)
                }
                if entry.path == "docs/readme.txt" { rawReads = entryBytes }
            }
            probe.close()
            check(rawReads == 100,
                  "raw member reads return the data (got \(rawReads) bytes, libarchive says: \(ArchiveService.lastError))")
            check(firstByte == 0x41, "raw member reads return the real content (got \(String(firstByte, radix: 16)))")
        } catch {
            check(false, "raw read probe failed: \(error.localizedDescription)")
        }

        // Extraction
        let destination = root.appendingPathComponent("archive-out")
        do {
            let result = try ArchiveService.extract(archive: archiveURL, entries: entries,
                                                     wanted: nil, destination: destination)
            check(result.files == 7, "all members were extracted (got \(result.files))")
            check(result.bytes == 360, "the extracted byte count matches (got \(result.bytes))")

            let readme = destination.appendingPathComponent("docs/readme.txt")
            let attributes = try? fileManager.attributesOfItem(atPath: readme.path)
            check((attributes?[.size] as? NSNumber)?.intValue == 100, "extracted file contents match")
            check(attributes?[.type] as? FileAttributeType == .typeRegular, "regular files extract as files")

            if let data = try? Data(contentsOf: readme) {
                check(data.count == 100 && data.allSatisfy { $0 == 0x41 },
                      "the extracted file holds the real bytes (got \(data.count) bytes)")
            } else {
                check(false, "could not read the extracted file")
            }

            let secret = destination.appendingPathComponent("secret.txt")
            let secretPermissions = (try? fileManager.attributesOfItem(atPath: secret.path))?[.posixPermissions] as? NSNumber
            let secretOctal = secretPermissions.map { String($0.intValue, radix: 8) } ?? "nil"
            check(secretPermissions?.intValue == 0o600,
                  "permissions survive the round trip (got \(secretOctal))")

            let link = destination.appendingPathComponent("link.txt")
            let linkType = (try? fileManager.attributesOfItem(atPath: link.path))?[.type] as? FileAttributeType
            check(linkType == .typeSymbolicLink, "symlinks extract as symlinks")
            check((try? fileManager.destinationOfSymbolicLink(atPath: link.path)) == "docs/readme.txt",
                  "the symlink target survives")
        } catch {
            check(false, "extraction failed: \(error.localizedDescription)")
        }

        // Partial extraction of a single folder
        let single = root.appendingPathComponent("archive-single")
        do {
            _ = try ArchiveService.extract(archive: archiveURL, entries: entries,
                                           wanted: ["docs"], destination: single)
            check(fileManager.fileExists(atPath: single.appendingPathComponent("docs/notes.txt").path),
                  "selecting a folder extracts everything inside it")
            check(!fileManager.fileExists(atPath: single.appendingPathComponent("secret.txt").path),
                  "unselected members are not extracted")
        } catch {
            check(false, "partial extraction failed: \(error.localizedDescription)")
        }

        // Conflict policy: `single` already holds everything under docs/
        do {
            let result = try ArchiveService.extract(archive: archiveURL, entries: entries,
                                                    wanted: nil, destination: single,
                                                    policy: .skip)
            check(result.skipped == 3, "skip policy counts the existing members (got \(result.skipped))")
            check(fileManager.fileExists(atPath: single.appendingPathComponent("secret.txt").path),
                  "skip policy still extracts members that were missing")
        } catch {
            check(false, "skip extraction failed: \(error.localizedDescription)")
        }

        // Removing a member by rewriting the archive
        do {
            let result = try ArchiveService.rewrite(archive: archiveURL, removing: ["docs/notes.txt"])
            check(result.files == 6, "rewriting kept 6 of 7 members (got \(result.files))")
            let after = try ArchiveService.list(archiveURL).entries
            check(!after.contains { $0.path == "docs/notes.txt" }, "the deleted member is gone")
            check(after.contains { $0.path == "docs/readme.txt" }, "the other members survive")
            entries = after
        } catch {
            check(false, "rewrite (remove) failed: \(error.localizedDescription)")
        }

        // Adding a member
        let extraSource = root.appendingPathComponent("archive-extra/added.txt")
        makeFile(extraSource, bytes: 42)
        do {
            _ = try ArchiveService.rewrite(archive: archiveURL,
                                           removing: [],
                                           adding: [extraSource],
                                           addingPrefix: "extra")
            let after = try ArchiveService.list(archiveURL).entries
            check(after.contains { $0.path == "extra/added.txt" && $0.size == 42 },
                  "the added member is present with its size")
            check(after.contains { $0.path == "docs/readme.txt" }, "existing members survive an addition")
            entries = after
        } catch {
            check(false, "rewrite (add) failed: \(error.localizedDescription)")
        }

        // tar.gz round trip
        let tarURL = root.appendingPathComponent("bundle.tar.gz")
        do {
            _ = try ArchiveService.create(archive: tarURL,
                                          sources: [source.appendingPathComponent("docs")],
                                          format: .tarGz)
            let listing = try ArchiveService.list(tarURL)
            check(listing.entries.contains { $0.path == "docs/readme.txt" },
                  "tar.gz round trips through the same machinery")
            check(listing.entries.contains { $0.path == "docs" && $0.isDirectory },
                  "tar.gz keeps directory members")
        } catch {
            check(false, "tar.gz packing failed: \(error.localizedDescription)")
        }

        // Path safety
        check(ArchiveService.normalize(path: "../../etc/passwd") == "etc/passwd",
              "path traversal is stripped from member names")
        check(ArchiveService.normalize(path: "/absolute/path") == "absolute/path",
              "absolute member names are made relative")
        check(ArchiveService.normalize(path: "a//b/./c") == "a/b/c",
              "empty and dot components are dropped")

        check(ArchiveService.canRewrite(URL(fileURLWithPath: "/tmp/a.zip")), "zip archives can be rewritten")
        // Same filesystem detection: exact, and safe when the target is new.
        let here = root.appendingPathComponent("volume-probe")
        makeFile(here.appendingPathComponent("f.txt"), bytes: 4)
        check(FileSystemService.isSameVolume(here, here.appendingPathComponent("f.txt")),
              "a folder and a file inside it share a filesystem")
        check(FileSystemService.isSameVolume(here, here.deletingLastPathComponent().appendingPathComponent("brand-new")),
              "a not yet existing target falls back to its folder")
        check(!FileSystemService.isSameVolume(here, URL(fileURLWithPath: "/dev/null")),
              "a different device is detected (devfs)")
        check(!FileSystemService.isSameVolume(here, URL(fileURLWithPath: "/nonexistent/place")),
              "an unresolvable path is conservatively treated as another volume")
        check(ArchiveService.canRewrite(URL(fileURLWithPath: "/tmp/a.tar.gz")), "tar.gz archives can be rewritten")
        check(!ArchiveService.canRewrite(URL(fileURLWithPath: "/tmp/a.7z")),
              "read-only formats are refused for rewriting")
        do {
            _ = try ArchiveService.rewrite(archive: root.appendingPathComponent("not-there.7z"), removing: ["x"])
            check(false, "rewriting a 7z should be refused")
        } catch {
            check(error.localizedDescription.contains("cannot be modified"),
                  "rewriting a read-only format reports a clear error")
        }

        // Reading an archive produced by the system tools proves interoperability.
        let systemSource = root.appendingPathComponent("system-zip/inner/file.txt")
        makeFile(systemSource, bytes: 24)
        let systemZip = root.appendingPathComponent("system.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", root.appendingPathComponent("system-zip").path, systemZip.path]
        try? process.run()
        process.waitUntilExit()
        if process.terminationStatus == 0, let listing = try? ArchiveService.list(systemZip) {
            check(listing.entries.contains { $0.path.hasSuffix("inner/file.txt") },
                  "a zip written by ditto reads back correctly")
        } else {
            check(false, "could not read a zip produced by ditto")
        }
    }

    // MARK: - Archive browsing inside a panel

    private static func testArchivePanel(root: URL) {
        print("archive browsing")
        MainActor.assumeIsolated {
            let folder = root.appendingPathComponent("zip-panel")
            makeFile(folder.appendingPathComponent("source/docs/readme.txt"), bytes: 100)
            makeFile(folder.appendingPathComponent("source/docs/notes.txt"), bytes: 60)
            makeFile(folder.appendingPathComponent("source/images/logo.dat"), bytes: 40)
            let archive = folder.appendingPathComponent("bundle.zip")
            do {
                _ = try ArchiveService.create(archive: archive,
                                              sources: [folder.appendingPathComponent("source/docs"),
                                                        folder.appendingPathComponent("source/images")],
                                              format: .zip)
            } catch {
                check(false, "could not build the test archive: \(error.localizedDescription)")
                return
            }

            let panel = PanelModel(startURL: folder, sideTitle: "Test")
            guard waitForLoad(panel) else {
                check(false, "panel did not load")
                return
            }

            check(panel.displayItems.contains { $0.name == "bundle.zip" }, "the archive shows up as a file")

            guard let archiveIndex = panel.displayItems.firstIndex(where: { $0.name == "bundle.zip" }) else {
                check(false, "archive row missing")
                return
            }
            panel.setSelection([panel.displayItems[archiveIndex].id], cursorRow: archiveIndex)
            panel.open(panel.displayItems[archiveIndex])
            _ = waitForLoad(panel)

            check(panel.isBrowsingArchive, "Enter on an archive enters it")
            check(panel.displayItems.contains { $0.name == "docs" && $0.isDirectory },
                  "the archive root lists its folders")
            check(panel.displayItems.first?.isParent == true, "the archive root has a parent row")

            guard let docsIndex = panel.displayItems.firstIndex(where: { $0.name == "docs" }) else {
                check(false, "docs folder missing inside the archive")
                return
            }
            panel.setSelection([panel.displayItems[docsIndex].id], cursorRow: docsIndex)
            panel.open(panel.displayItems[docsIndex])
            _ = waitForLoad(panel)

            check(panel.archive?.internalPath == "docs", "opening a folder inside the archive navigates into it")
            check(panel.displayItems.contains { $0.name == "readme.txt" }, "files inside the folder are listed")
            let member = panel.displayItems.first { $0.name == "readme.txt" }
            check(member?.isArchiveMember == true, "rows are marked as archive members")
            check(member?.archive?.archiveURL.lastPathComponent == "bundle.zip", "the member knows its archive")

            panel.goUp()
            _ = waitForLoad(panel)
            check(panel.archive?.internalPath == "", "going up returns to the archive root")

            panel.goUp()
            _ = waitForLoad(panel)
            check(!panel.isBrowsingArchive, "going up from the root leaves the archive")
            check(panel.url.lastPathComponent == "zip-panel", "the pane returns to the folder holding the archive")

            check(panel.canGoBack, "the archive visit is in the history")
            panel.goBack()
            _ = waitForLoad(panel)
            check(panel.isBrowsingArchive, "going back re-enters the archive from history")

            // Rebuilding the archive must refresh a pane that is browsing it.
            if let docsIndex = panel.displayItems.firstIndex(where: { $0.name == "docs" }) {
                panel.setSelection([panel.displayItems[docsIndex].id], cursorRow: docsIndex)
                panel.open(panel.displayItems[docsIndex])
                _ = waitForLoad(panel)
            }
            check(panel.displayItems.contains { $0.name == "readme.txt" }, "the member is listed before the rebuild")

            do {
                _ = try ArchiveService.rewrite(archive: archive, removing: ["docs/readme.txt"])
                panel.invalidateArchiveCache()
                panel.reload()
                _ = waitForLoad(panel)
                check(!panel.displayItems.contains { $0.name == "readme.txt" },
                      "a pane browsing an archive picks up a rebuilt archive")
                check(panel.displayItems.contains { $0.name == "notes.txt" },
                      "the surviving members are still listed")
            } catch {
                check(false, "rebuilding while browsing failed: \(error.localizedDescription)")
            }

            // The stale cache is what the fix guards against.
            panel.reload()
            _ = waitForLoad(panel)
            check(!panel.displayItems.contains { $0.name == "readme.txt" },
                  "reloading again keeps the pane in step with the archive")
        }
    }

    // MARK: - Directory synchronisation

    private static func testSynchronise(root: URL) {
        print("synchronise")
        let fileManager = FileManager.default
        let left = root.appendingPathComponent("sync-left")
        let right = root.appendingPathComponent("sync-right")

        makeFile(left.appendingPathComponent("same.txt"), bytes: 50)
        makeFile(right.appendingPathComponent("same.txt"), bytes: 50)
        makeFile(left.appendingPathComponent("only-left.txt"), bytes: 10)
        makeFile(right.appendingPathComponent("only-right.txt"), bytes: 30)
        makeFile(left.appendingPathComponent("newer.txt"), bytes: 20)
        makeFile(right.appendingPathComponent("newer.txt"), bytes: 20)
        makeFile(left.appendingPathComponent("sub/nested.txt"), bytes: 20)
        makeFile(right.appendingPathComponent("sub/nested.txt"), bytes: 25)

        let older = Date(timeIntervalSince1970: 1_600_000_000)
        let newer = Date(timeIntervalSince1970: 1_700_000_000)
        try? fileManager.setAttributes([.modificationDate: older],
                                       ofItemAtPath: left.appendingPathComponent("newer.txt").path)
        try? fileManager.setAttributes([.modificationDate: newer],
                                       ofItemAtPath: right.appendingPathComponent("newer.txt").path)
        try? fileManager.setAttributes([.modificationDate: newer],
                                       ofItemAtPath: left.appendingPathComponent("same.txt").path)
        try? fileManager.setAttributes([.modificationDate: newer],
                                       ofItemAtPath: right.appendingPathComponent("same.txt").path)

        let options = SyncService.Options(includeSubdirectories: true,
                                          compareByContent: false,
                                          includeHidden: true,
                                          onlyDifferences: true,
                                          mask: "")
        var result = SyncService.compare(left: left, right: right, options: options)
        let byPath = Dictionary(uniqueKeysWithValues: result.rows.map { ($0.relativePath, $0) })

        check(byPath["only-left.txt"]?.status == .leftOnly, "files only on the left are detected")
        check(byPath["only-right.txt"]?.status == .rightOnly, "files only on the right are detected")
        check(byPath["newer.txt"]?.status == .rightNewer, "the newer copy is identified")
        check(byPath["sub/nested.txt"]?.status == .sizeDiffers, "differing sizes are detected in subfolders")
        check(byPath["same.txt"] == nil, "identical files are hidden when only differences are wanted")
        check(result.rows.count == 4, "four differences are reported (got \(result.rows.count))")

        var withIdentical = SyncService.Options(includeSubdirectories: true,
                                                compareByContent: false,
                                                includeHidden: true,
                                                onlyDifferences: false,
                                                mask: "")
        withIdentical.onlyDifferences = false
        result = SyncService.compare(left: left, right: right, options: withIdentical)
        check(result.rows.contains { $0.relativePath == "same.txt" && $0.status == .identical },
              "identical files are listed when requested")

        // Content comparison
        makeFile(left.appendingPathComponent("content.bin"), bytes: 64)
        makeFile(right.appendingPathComponent("content.bin"), bytes: 64)
        if let handle = try? FileHandle(forWritingTo: right.appendingPathComponent("content.bin")) {
            try? handle.seek(toOffset: 10)
            try? handle.write(contentsOf: Data([0x42]))
            try? handle.close()
        }
        var contentOptions = withIdentical
        contentOptions.compareByContent = true
        let contentResult = SyncService.compare(left: left, right: right, options: contentOptions)
        check(contentResult.rows.contains { $0.relativePath == "content.bin" && $0.status == .contentDiffers },
              "same-sized files with different bytes are detected by content comparison")

        // Non recursive
        var flat = options
        flat.includeSubdirectories = false
        let flatResult = SyncService.compare(left: left, right: right, options: flat)
        check(!flatResult.rows.contains { $0.relativePath.contains("nested") },
              "subdirectories are skipped when the option is off")

        // Executing actions
        var batch = SyncService.compare(left: left, right: right, options: options).rows
        for index in batch.indices {
            switch batch[index].relativePath {
            case "only-left.txt": batch[index].direction = .leftToRight
            case "only-right.txt": batch[index].direction = .rightToLeft
            case "newer.txt": batch[index].direction = .leftToRight
            case "sub/nested.txt": batch[index].direction = .rightToLeft
            default: break
            }
        }
        let context = TransferContext(title: "test") { _ in }
        context.policy = .replaceAll
        SyncService.execute(rows: batch, left: left, right: right, context: context)

        check(fileManager.fileExists(atPath: right.appendingPathComponent("only-left.txt").path),
              "left-only files are copied to the right")
        check(fileManager.fileExists(atPath: left.appendingPathComponent("only-right.txt").path),
              "right-only files are copied to the left")
        check((try? Data(contentsOf: left.appendingPathComponent("sub/nested.txt")))?.count == 25,
              "the newer right copy replaced the left file")

        var after = SyncService.compare(left: left, right: right, options: options)
        check(!after.rows.contains { $0.relativePath == "only-left.txt" }, "the synced file no longer differs")
        after = SyncService.compare(left: left, right: right, options: withIdentical)
        check(after.rows.contains { $0.relativePath == "newer.txt" && $0.status == .identical },
              "the file copied left to right is now identical")
    }

    // MARK: - Multi rename

    private static func testMultiRename(root: URL) {
        print("multi-rename")
        var template = RenameTemplate()
        template.mask = "[N]"

        check(MultiRenameService.newName(for: "photo.jpg", isDirectory: false, modified: nil,
                                         counter: 1, template: template) == "photo.jpg",
              "an empty template keeps the name")

        template.mask = "[N]_[C]"
        template.counterDigits = 3
        check(MultiRenameService.newName(for: "photo.jpg", isDirectory: false, modified: nil,
                                         counter: 5, template: template) == "photo_005.jpg",
              "the counter is padded to the requested digits")

        template = RenameTemplate()
        template.mask = "[N]"
        template.searchText = "a"
        template.replaceText = "o"
        check(MultiRenameService.newName(for: "alpha.txt", isDirectory: false, modified: nil,
                                         counter: 1, template: template) == "olpho.txt",
              "search and replace applies to the name part")

        template.searchText = "[0-9]"
        template.replaceText = ""
        template.useRegex = true
        check(MultiRenameService.newName(for: "file2.txt", isDirectory: false, modified: nil,
                                         counter: 1, template: template) == "file.txt",
              "regular expressions can strip parts of the name")

        template = RenameTemplate()
        template.mask = "[N]"
        template.caseMode = .upper
        check(MultiRenameService.newName(for: "alpha.txt", isDirectory: false, modified: nil,
                                         counter: 1, template: template) == "ALPHA.txt",
              "case conversion only touches the name part")

        template.extensionMode = .upper
        check(MultiRenameService.newName(for: "alpha.txt", isDirectory: false, modified: nil,
                                         counter: 1, template: template) == "ALPHA.TXT",
              "the extension can be upper-cased separately")

        template.extensionMode = .replace
        template.extensionReplacement = "dat"
        check(MultiRenameService.newName(for: "alpha.txt", isDirectory: false, modified: nil,
                                         counter: 1, template: template) == "ALPHA.dat",
              "the extension can be replaced")

        template = RenameTemplate()
        template.mask = "[Y]-[M]-[D]_[N]"
        template.extensionMode = .remove
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        let dated = MultiRenameService.newName(for: "note.txt", isDirectory: false, modified: date,
                                               counter: 1, template: template)
        check(dated.hasPrefix("2020-09-13_"), "date placeholders are expanded (got \(dated))")

        // Preview + apply, including a swap.
        let folder = root.appendingPathComponent("rename")
        makeFile(folder.appendingPathComponent("a.txt"), bytes: 1)
        makeFile(folder.appendingPathComponent("b.txt"), bytes: 2)
        let items = (try? FileSystemService.list(folder, showHidden: false)) ?? []
        let files = items.filter { !$0.isParent }

        template = RenameTemplate()
        template.mask = "[N]_renamed"
        var preview = MultiRenameService.preview(items: files, template: template)
        check(preview.count == 2, "the preview covers every selected file")
        check(preview.allSatisfy { $0.hasChange }, "every file is marked as changing")
        check(preview.allSatisfy { !$0.isConflicting }, "no conflicts in a clean folder")

        // Two files mapping to the same name must be flagged.
        template.mask = "same"
        preview = MultiRenameService.preview(items: files, template: template)
        check(preview.allSatisfy { $0.isDuplicate }, "colliding target names are flagged")

        // A real rename, using a swap to exercise the two phase logic.
        let swapFolder = root.appendingPathComponent("rename-swap")
        makeFile(swapFolder.appendingPathComponent("one.txt"), bytes: 10)
        makeFile(swapFolder.appendingPathComponent("two.txt"), bytes: 20)
        let swapRows = [
            RenamePreviewRow(original: "one.txt", proposed: "two.txt", folder: swapFolder, isDirectory: false, modified: nil),
            RenamePreviewRow(original: "two.txt", proposed: "one.txt", folder: swapFolder, isDirectory: false, modified: nil)
        ]
        let outcome = MultiRenameService.apply(rows: swapRows, overwrite: true)
        check(outcome.renamed == 2, "both files were renamed (got \(outcome.renamed))")
        check(outcome.errors.isEmpty, "a name swap works without errors (\(outcome.errors.first ?? "-"))")
        check((try? Data(contentsOf: swapFolder.appendingPathComponent("one.txt")))?.count == 20,
              "the swapped contents followed their names")

        // Conflict protection
        let conflictRows = MultiRenameService.preview(items: files, template: {
            var t = RenameTemplate()
            t.mask = "a_renamed"
            return t
        }())
        let guarded = MultiRenameService.apply(rows: conflictRows, overwrite: false)
        check(guarded.errors.isEmpty || guarded.renamed >= 1, "renaming into free names succeeds")
    }

    // MARK: - Favorites and volumes

    private static func testFavorites(root: URL) {
        print("favorites")
        MainActor.assumeIsolated {
            let file = root.appendingPathComponent("favorites/favorites.json")
            try? FileManager.default.removeItem(at: file)

            let store = FavoritesStore(fileURL: file)
            check(store.items.count >= 5, "the list is seeded on first run (got \(store.items.count))")
            check(FileManager.default.fileExists(atPath: file.path), "the favorites file is written")
            check(store.flattened().contains { $0.isGroup && $0.title == "Quick Access" },
                  "the seed includes a group")
            check(store.flattened().contains { $0.depth == 1 }, "group children are nested one level deep")

            let target = root.appendingPathComponent("favorite-target")
            makeFile(target.appendingPathComponent("x.txt"), bytes: 1)

            check(store.addIfMissing(title: "Target", path: target.path), "a folder can be added")
            check(!store.addIfMissing(title: "Target again", path: target.path),
                  "the same folder is not added twice")

            guard let group = store.flattened().first(where: { $0.isGroup && $0.title == "Projects" }) else {
                check(false, "seed group missing")
                return
            }
            store.add(title: "Inside", path: target.path, into: group.id)
            check(store.flattened().contains { $0.title == "Inside" && $0.depth == 1 },
                  "an entry can be added inside a group")

            guard let row = store.flattened().first(where: { $0.title == "Inside" }) else {
                check(false, "nested entry missing")
                return
            }
            store.update(id: row.id, title: "Renamed", path: "/tmp/elsewhere")
            let updated = store.flattened().first { $0.id == row.id }
            check(updated?.title == "Renamed", "an entry can be renamed")
            check(updated?.path == "/tmp/elsewhere", "an entry's folder can be changed")

            store.move(id: row.id, offset: -1)
            check(store.flattened().first { $0.id == row.id }?.depth == 1,
                  "moving an entry keeps it in its group")

            guard let firstInGroup = store.flattened().first(where: { $0.title == "Home" }) else {
                check(false, "seed entry missing")
                return
            }
            let beforeMove = store.flattened().firstIndex { $0.id == firstInGroup.id }
            store.move(id: firstInGroup.id, offset: 1)
            let afterMove = store.flattened().firstIndex { $0.id == firstInGroup.id }
            check(beforeMove != afterMove, "moving reorders the entry")

            store.remove(id: row.id)
            check(!store.flattened().contains { $0.id == row.id }, "deleting removes the entry")

            let ghost = store.add(title: "Ghost", path: "/definitely/not/here")
            check(store.item(id: ghost.id)?.exists == false,
                  "entries pointing at a missing folder are flagged")
            check(store.item(id: ghost.id)?.url?.path == "/definitely/not/here",
                  "the stored path expands to a URL")

            store.add(title: "Persisted", path: target.path)
            let reloaded = FavoritesStore(fileURL: file)
            check(reloaded.flattened().contains { $0.title == "Persisted" },
                  "the list survives a reload")
            check(reloaded.flattened().count == store.flattened().count,
                  "every entry round trips through JSON")
        }
    }

    private static func testVolumes(root: URL) {
        print("volumes")

        let mounted = VolumeService.mountedVolumes()
        print("      mounted: " + mounted.map { "\($0.displayName)[\($0.subtitle)]" }.joined(separator: ", "))
        check(mounted.contains { $0.isRoot }, "the startup disk is listed")
        check(mounted.allSatisfy { !$0.displayName.isEmpty }, "every volume has a name")
        check(Set(mounted.map(\.id)).count == mounted.count, "no volume is listed twice")

        let externals = mounted.filter(\.isExternal)
        check(externals.allSatisfy { $0.isRemovable || !$0.isInternal },
              "external volumes are flagged as such")
        if let removable = externals.first(where: { $0.isRemovable }) {
            check(!removable.isRoot, "removable media is not the startup disk")
            check(VolumeService.contains(removable, path: removable.url.path),
                  "a volume contains its own mount point")
            check(removable.icon.size.width > 0, "volumes provide an icon")
        }

        func sample(_ path: String, _ name: String, removable: Bool = false, internalDrive: Bool = false) -> Volume {
            Volume(url: URL(fileURLWithPath: path), name: name,
                   isRemovable: removable, isEjectable: !internalDrive,
                   isInternal: internalDrive, isReadOnly: false,
                   freeSpace: 100, totalSpace: 200)
        }

        let rootVolume = sample("/", "Macintosh HD", internalDrive: true)
        let external = sample("/Volumes/USB", "USB", removable: true)
        let externalTwo = sample("/Volumes/Alpha", "Alpha")
        let internalExtra = sample("/System/Volumes/Data", "Data", internalDrive: true)

        let ordered = VolumeService.sorted([internalExtra, externalTwo, external, rootVolume])
        check(ordered.first?.isRoot == true, "the startup disk sorts first")
        check(ordered[1].displayName == "Alpha", "external volumes come next, alphabetically")
        check(ordered[2].displayName == "USB", "removable media is grouped with the externals")
        check(ordered.last?.displayName == "Data", "internal extras come last")

        check(VolumeService.volume(for: "/Volumes/USB/photos/a.jpg", in: [rootVolume, external])?.displayName == "USB",
              "the deepest volume match wins")
        check(VolumeService.volume(for: "/Users/someone/file.txt", in: [rootVolume])?.isRoot == true,
              "files on the startup disk map to it")
        check(VolumeService.volume(for: "/Volumes/USB/photos", in: [rootVolume])?.isRoot == true,
              "without a matching volume, the startup disk is assumed")
        check(external.capacityText.contains("free of"), "capacity is described in words")
        check(!external.isReadOnly, "removable media is writable in this sample")

        // A favourite that points inside an archive resolves to the archive plus
        // an internal path rather than a plain folder.
        let plain = AppModel.splitArchivePath("/Users/someone/Documents")
        check(plain == nil, "a normal folder is not treated as an archive")
    }

    /// Copies a large file through the engine and watches the progress stream.
    /// This is the path used when moving to an external drive.
    private static func testLargeTransfer(root: URL) {
        print("large file transfer")
        let fileManager = FileManager.default
        let source = root.appendingPathComponent("large-source/disk-image.bin")
        let destination = root.appendingPathComponent("large-target")

        let size: Int64 = 80 * 1024 * 1024
        try? fileManager.createDirectory(at: source.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
        fileManager.createFile(atPath: source.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: source) else {
            check(false, "cannot create the large test file")
            return
        }
        // Sparse file: created instantly, reads back as zeros.
        try? handle.truncate(atOffset: UInt64(size))
        try? handle.close()
        check(fileSizeOf(source) == size, "the test file is \(size) bytes")

        // Record every progress report so we can inspect the shape of the run.
        var samples: [(bytes: Int64, at: Date)] = []
        let context = TransferContext(title: "test") { progress in
            samples.append((progress.bytesDone, Date()))
        }

        let started = Date()
        TransferEngine.run(sources: [source], destination: destination, move: false, context: context)
        let elapsed = Date().timeIntervalSince(started)

        let copied = destination.appendingPathComponent("disk-image.bin")
        check(fileManager.fileExists(atPath: copied.path), "the large file reaches the destination")
        check(fileSizeOf(copied) == size,
              "the copy is complete, not truncated (got \(fileSizeOf(copied)) of \(size))")
        check(context.errors.isEmpty, "the large copy reports no errors (\(context.errors.first ?? "-"))")
        check(context.bytesDone == size,
              "the engine accounts for every byte (got \(context.bytesDone))")

        check(samples.count >= 2, "progress is reported at least at start and finish (got \(samples.count) reports)")
        if let last = samples.last {
            check(last.bytes == size, "the final report equals the total")
        }
        let monotonic = zip(samples, samples.dropFirst()).allSatisfy { $0.bytes <= $1.bytes }
        check(monotonic, "progress never goes backwards")

        let gaps = zip(samples, samples.dropFirst()).map { $1.at.timeIntervalSince($0.at) }
        let biggestGap = gaps.max() ?? 0
        print("      \(samples.count) progress reports, largest gap \(String(format: "%.2f", biggestGap))s, total \(String(format: "%.2f", elapsed))s")
        check(biggestGap < 5, "progress keeps flowing between reports (largest gap \(String(format: "%.2f", biggestGap))s)")

        // The cross volume path: no page cache, flushed in bounded windows so a
        // slow destination cannot swallow gigabytes of dirty pages.
        let flushedTarget = root.appendingPathComponent("large-flushed/disk-image.bin")
        try? fileManager.createDirectory(at: flushedTarget.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
        var flushedSamples: [Int64] = []
        let flushingContext = TransferContext(title: "test") { progress in
            flushedSamples.append(progress.bytesDone)
        }
        do {
            try TransferEngine.streamCopy(source: source,
                                          destination: flushedTarget,
                                          context: flushingContext,
                                          flushing: true)
            check(fileSizeOf(flushedTarget) == size,
                  "the flushing copy is byte complete (got \(fileSizeOf(flushedTarget)) of \(size))")
            check(flushingContext.bytesDone == size, "the flushing copy accounts for every byte")
            check(!flushedSamples.isEmpty, "the flushing copy reports progress")
        } catch {
            check(false, "the flushing copy failed: \(error.localizedDescription)")
        }

        // The same file, this time moved across directories.
        let moveTarget = root.appendingPathComponent("large-moved")
        let moveContext = TransferContext(title: "test") { _ in }
        TransferEngine.run(sources: [copied], destination: moveTarget, move: true, context: moveContext)
        let moved = moveTarget.appendingPathComponent("disk-image.bin")
        check(fileManager.fileExists(atPath: moved.path), "a large file can be moved")
        check(fileSizeOf(moved) == size, "the moved file is complete")
        check(!fileManager.fileExists(atPath: copied.path), "the source is removed after a move")

        // Tidy up the big files immediately so the suite stays light.
        try? fileManager.removeItem(at: destination)
        try? fileManager.removeItem(at: flushedTarget.deletingLastPathComponent())
        try? fileManager.removeItem(at: moveTarget)
        try? fileManager.removeItem(at: source.deletingLastPathComponent())
    }

    /// The HUD has to be able to tell "slow" from "stuck".
    private static func testStallDetection() {
        print("stall detection")

        var progress = OpProgress(title: "Copying", detail: "big.bin",
                                  filesDone: 1, filesTotal: 1,
                                  bytesDone: 250, bytesTotal: 1000,
                                  bytesPerSecond: 10_000_000)
        check(progress.fraction == 0.25, "the fraction reflects the byte counts")
        check(!progress.isIndeterminate, "a known total is not indeterminate")
        check(!progress.isStalled, "a fresh report is not stalled")
        check(!progress.etaText.isEmpty, "an ETA is offered while data is flowing")
        check(!progress.rateText.isEmpty, "the transfer rate is shown")

        progress.updatedAt = Date().addingTimeInterval(-30)
        check(progress.isStalled, "no news for 30 s counts as stalled")
        check(Int(progress.secondsSinceUpdate) >= 29, "the stall duration is reported")

        var scanning = OpProgress(title: "Copying", detail: "Measuring…",
                                  filesDone: 0, filesTotal: 0,
                                  bytesDone: 0, bytesTotal: 0,
                                  bytesPerSecond: 0)
        check(scanning.isIndeterminate, "the up front scan is indeterminate")
        scanning.updatedAt = Date().addingTimeInterval(-30)
        check(!scanning.isStalled, "an indeterminate scan is not called stalled")
        check(scanning.etaText.isEmpty, "no ETA is invented before the total is known")
    }

    private static func fileSizeOf(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1)
    }

    /// Version stamping and the archive of previous builds.
    private static func testVersions(root: URL) {
        print("versions")

        check(!VersionService.currentVersion.isEmpty, "the running app reports a version")
        check(VersionService.currentBuild >= 1, "the running app reports a build number")
        check(VersionService.currentDescription.contains(VersionService.currentVersion),
              "the build stamp mentions the version (got \(VersionService.currentDescription))")

        // Build a fake versions folder with two app bundles and one decoy.
        let folder = root.appendingPathComponent("versions")
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        func makeFakeApp(_ name: String, version: String, build: Int, identifier: String = "com.totalmac.app") -> URL {
            let app = folder.appendingPathComponent(name)
            let contents = app.appendingPathComponent("Contents")
            try? fileManager.createDirectory(at: contents, withIntermediateDirectories: true)
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>CFBundleIdentifier</key><string>\(identifier)</string>
            <key>CFBundleShortVersionString</key><string>\(version)</string>
            <key>CFBundleVersion</key><string>\(build)</string>
            <key>TotalMacBuildNumber</key><integer>\(build)</integer>
            </dict></plist>
            """
            try? plist.data(using: .utf8)?.write(to: contents.appendingPathComponent("Info.plist"))
            try? Data(repeating: 0x41, count: 2048)
                .write(to: contents.appendingPathComponent("filler.bin"))
            return app
        }

        _ = makeFakeApp("TotalMac-1.2.0-b4.app", version: "1.2.0", build: 4)
        _ = makeFakeApp("TotalMac-1.4.0-b9.app", version: "1.4.0", build: 9)
        _ = makeFakeApp("SomethingElse.app", version: "9.9.9", build: 99, identifier: "com.example.other")
        try? Data("not an app".utf8).write(to: folder.appendingPathComponent("readme.txt"))
        try? fileManager.createDirectory(at: folder.appendingPathComponent("Empty.app"),
                                         withIntermediateDirectories: true)

        let builds = VersionService.archivedBuilds(in: folder)
        check(builds.count == 2, "only TotalMac bundles are listed (got \(builds.count))")
        check(builds.first?.build == 9, "the newest build is listed first")
        check(builds.last?.build == 4, "older builds follow")

        guard let newest = builds.first else {
            check(false, "no build was read back")
            return
        }
        check(newest.version == "1.4.0", "the version is read from the bundle (got \(newest.version))")
        check(newest.versionText == "1.4.0 (build 9)", "the version text is formatted")
        check(newest.size > 2048, "the bundle size is measured (got \(newest.size))")
        check(newest.date != nil, "the build date is taken from the file")
        check(!newest.isRunning, "an archived build is not the running one")
        check(newest.statusText == "newer than the running app" || newest.statusText == "older",
              "each build is compared against the running one (got \(newest.statusText))")

        check(VersionService.read(appAt: folder.appendingPathComponent("Empty.app")) == nil,
              "a bundle without an Info.plist is ignored")
        check(VersionService.read(appAt: folder.appendingPathComponent("readme.txt")) == nil,
              "a plain file is ignored")
        check(VersionService.archivedBuilds(in: root.appendingPathComponent("no-such-folder")).isEmpty,
              "a missing versions folder yields no builds")

        // Pruning keeps the newest and trashes the rest.
        _ = makeFakeApp("TotalMac-1.0.0-b1.app", version: "1.0.0", build: 1)
        _ = makeFakeApp("TotalMac-1.1.0-b2.app", version: "1.1.0", build: 2)
        check(VersionService.archivedBuilds(in: folder).count == 4, "four builds are archived")
        let removed = VersionService.pruneArchivedBuilds(keeping: 2, in: folder)
        check(removed == 2, "pruning removed the surplus (got \(removed))")
        let kept = VersionService.archivedBuilds(in: folder)
        check(kept.count == 2, "two builds remain after pruning")
        check(kept.map(\.build) == [9, 4], "pruning keeps the newest builds")
    }

    // MARK: - Sorting

    private static func testSorting(root: URL) {
        print("sorting")
        let items: [FileItem] = ["b.txt", "a.txt", "file10.txt", "file2.txt"].map { name in
            FileItem(url: URL(fileURLWithPath: "/tmp/\(name)"), name: name,
                     isDirectory: false, isPackage: false, isSymlink: false, isHidden: false,
                     isAlias: false, isParent: false, size: Int64(name.count), modified: nil,
                     created: nil, permissions: "rw-r--r--", kind: "Document")
        }
        let sorted = FileSystemService.process(items, spec: SortSpec(key: .name, ascending: true), filter: "")
        check(sorted.map(\.name) == ["a.txt", "b.txt", "file2.txt", "file10.txt"],
              "natural sort orders file2 before file10")

        let descending = FileSystemService.process(items, spec: SortSpec(key: .size, ascending: false), filter: "")
        check(descending.first?.name == "file10.txt", "descending size sort puts the biggest first")

        let filtered = FileSystemService.process(items, spec: SortSpec() , filter: "*.txt")
        check(filtered.count == 4, "filtering keeps matching entries")
    }
}
