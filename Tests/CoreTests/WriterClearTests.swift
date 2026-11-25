import Foundation
import Testing

@testable import Core

/// `/bin/chmod` with `arguments`, its error output dropped. Returns its exit status.
private func runChmod(_ arguments: [String]) -> Int32 {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/chmod")
    task.arguments = arguments
    task.standardError = Pipe()
    guard (try? task.run()) != nil else { return -1 }
    task.waitUntilExit()
    return task.terminationStatus
}

/// The entries of `url`'s access list, a link not followed, that allow anyone but the user, from
/// the text `acl_to_text` writes, one entry a line.
private func entriesLettingOthersIn(_ url: URL) -> [String] {
    guard let list = acl_get_link_np(url.path, ACL_TYPE_EXTENDED) else {
        return errno == ENOENT ? [] : ["unreadable"]
    }
    defer { acl_free(UnsafeMutableRawPointer(list)) }
    var length = 0
    guard let text = acl_to_text(list, &length) else { return ["unreadable"] }
    defer { acl_free(UnsafeMutableRawPointer(text)) }
    return String(cString: text).split(separator: "\n").map(String.init).filter { line in
        let fields = line.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count >= 6, fields[4].hasPrefix("allow") else { return false }
        return !(fields[0] == "user" && fields[3] == "\(getuid())")
    }
}

/// Every entry of `url`'s access list, a link not followed, one a line as `acl_to_text` writes it.
private func entries(_ url: URL) -> [String] {
    guard let list = acl_get_link_np(url.path, ACL_TYPE_EXTENDED) else {
        return errno == ENOENT ? [] : ["unreadable"]
    }
    defer { acl_free(UnsafeMutableRawPointer(list)) }
    var length = 0
    guard let text = acl_to_text(list, &length) else { return ["unreadable"] }
    defer { acl_free(UnsafeMutableRawPointer(text)) }
    return String(cString: text).split(separator: "\n").map(String.init).filter {
        $0.split(separator: ":", omittingEmptySubsequences: false).count >= 6
    }
}

/// Sets or clears the append-only flag on `url`, a link not followed, keeping its other flags.
/// Returns whether that worked.
private func appendOnly(_ url: URL, _ on: Bool) -> Bool {
    var st = stat()
    guard lstat(url.path, &st) == 0 else { return false }
    let flag = UInt32(UF_APPEND)
    return lchflags(url.path, on ? st.st_flags | flag : st.st_flags & ~flag) == 0
}

/// The names of the writer's temporary shape in `url`.
private func temporaries(_ url: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).filter(
        NoFollowWriter.isTemporaryName)
}

/// The writer clears an allow entry for another user that a new file or folder takes from the
/// folder it is made in, where the clear acts: below the folder checks, which refuse a folder
/// that passes such an entry on, so a test reaches the clear through a folder handle opened past
/// them, or through an entry that lands on a folder after it passed them.
@Suite struct WriterClearTests {
    /// Clears every access list under the test's home, so nothing it set outlives it.
    func clear(_ t: TestHome) {
        _ = runChmod(["-R", "-N", t.home.path])
    }

    /// Makes `url` at 0700 with `entry` on its list and opens it by a plain handle, as no folder
    /// check would.
    func openPastTheChecks(_ url: URL, entry: String) throws -> Int32 {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        #expect(runChmod(["+a", entry, url.path]) == 0, "\(entry) \(url.lastPathComponent)")
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        try #require(fd >= 0)
        return fd
    }

    @Test func aTokenFileAndALaunchFileWrittenIntoAFolderThatPassesAnEntryOnCarryNone() throws {
        let t = try TestHome()
        defer { clear(t) }
        let body = try JSONSerialization.data(
            withJSONObject: ["env": [ProtectedEnv.tokenVariable: Canaries.oauth()]])
        let files = [
            try TokenPaths.fileURL(context: t.context, label: "pool-a"),
            try LaunchFiles.fileURL(context: t.context, label: "pool-a", leaseId: "l-0a0b0c0d"),
        ]
        for file in files {
            let folder = file.deletingLastPathComponent()
            let dir = try openPastTheChecks(folder, entry: "everyone allow read,file_inherit")
            defer { close(dir) }
            try NoFollowWriter.writeFile(body, in: dir, name: file.lastPathComponent)
            #expect(FileManager.default.fileExists(atPath: file.path))
            #expect(entriesLettingOthersIn(file).isEmpty, "\(file.lastPathComponent)")
            // A file made there another way takes the entry, so the writer's file had it too.
            let other = folder.appendingPathComponent("other.txt")
            #expect(FileManager.default.createFile(atPath: other.path, contents: Data()))
            #expect(!entriesLettingOthersIn(other).isEmpty, "\(file.lastPathComponent)")
        }
    }

    @Test func aProbeFolderMadeInAFolderThatPassesAnEntryOnCarriesNone() throws {
        let t = try TestHome()
        defer { clear(t) }
        let probe = t.context.dataRoot.appendingPathComponent(Layout.probeFolders[0])
        let dir = try openPastTheChecks(
            probe, entry: "everyone allow list,search,file_inherit,directory_inherit")
        defer { close(dir) }
        let name = Layout.probeFolderPrefix + "0123456789abcdef"
        #expect(NoFollowWriter.makeFolder(in: dir, name))
        #expect(entriesLettingOthersIn(probe.appendingPathComponent(name)).isEmpty)
        let other = probe.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        #expect(!entriesLettingOthersIn(other).isEmpty)
    }

    @Test func aFolderMadeBelowTheDataFolderTakesNoEntryThatLandedOnItsFolderAfterTheCheck()
        throws
    {
        let t = try TestHome()
        defer { clear(t) }
        let writer = NoFollowWriter(root: t.context.dataRoot)
        try writer.prepare(folders: [LaunchFiles.folder])
        let launch = LaunchFiles.rootURL(context: t.context)
        // A label no other test uses, so the seam acts on this test's folder only.
        let label = "made-after-the-check"
        let calls = HookCalls()
        NoFollowWriter.beforeMakingFolder.set(label) {
            calls.add(label)
            _ = runChmod(["+a", "everyone allow read,directory_inherit", launch.path])
        }
        defer { NoFollowWriter.beforeMakingFolder.set(label, nil) }
        try writer.prepare(folders: [LaunchFiles.folder, label])
        #expect(calls.labels == [label])
        #expect(entriesLettingOthersIn(launch.appendingPathComponent(label)).isEmpty)
        // The entry was there to take: the folder above still passes it on.
        #expect(!entriesLettingOthersIn(launch).isEmpty)
    }

    @Test func aCheckFileItCannotDeleteLosesItsOwnListAndOnlyAFolderEntryKeepsIt() throws {
        let t = try TestHome()
        defer { clear(t) }
        let writer = NoFollowWriter(root: t.context.dataRoot)
        try writer.prepare(folders: TokenPaths.folders)
        let tokens = t.context.dataRoot.appendingPathComponent(TokenPaths.folderName)
        let place = "~/.agent-balancer/" + TokenPaths.folderName
        let me = NSUserName()
        // An inherited entry on the check's file alone: it goes with the file's list.
        #expect(runChmod(["+a", "\(me) deny delete,file_inherit,only_inherit", tokens.path]) == 0)
        #expect(throws: ToolError(Messages.folderNotWritable(place))) {
            try writer.requireWritable(folders: TokenPaths.folders)
        }
        #expect(temporaries(tokens).isEmpty)
        // The folder's own entry keeps it: the refusal names it, empty and with no list.
        #expect(runChmod(["+a", "\(me) deny delete_child", tokens.path]) == 0)
        var said = ""
        do {
            try writer.requireWritable(folders: TokenPaths.folders)
        } catch let error as ToolError {
            said = error.message
        }
        let left = try #require(temporaries(tokens).first)
        #expect(temporaries(tokens).count == 1)
        #expect(
            said
                == Messages.folderNotWritable(place) + " "
                + Messages.checkLeft(place + "/" + left, folder: false))
        let file = tokens.appendingPathComponent(left)
        #expect(entries(file).isEmpty)
        #expect(try Data(contentsOf: file).isEmpty)
        // It holds nothing, so doctor neither counts it nor names it as a file that may hold a
        // token, though a delete would fail on it.
        #expect(TokenAccounts.writerLeftovers(context: t.context) == 1)
        #expect(TokenAccounts.writerLeftoversWithData(context: t.context) == 0)
        #expect(TokenAccounts.stuckTemporaries(context: t.context).isEmpty)
        // Once the folder's entries go, the check passes and the token save's cleanup takes it.
        #expect(runChmod(["-N", tokens.path]) == 0)
        try writer.requireWritable(folders: TokenPaths.folders)
        #expect(try TokenStore.deleteWriterLeftovers(context: t.context) == 0)
        #expect(temporaries(tokens).isEmpty)
        // A leftover that holds bytes, as a write cut off part way leaves, may hold a token.
        try writer.put(Data("x".utf8), folders: TokenPaths.folders, name: ".tmp-fedcba9876543210")
        #expect(TokenAccounts.writerLeftoversWithData(context: t.context) == 1)
    }

    @Test func aWriteStoppedBeforeItsRenameInAnAppendOnlyFolderNamesItsTemporaryFile() throws {
        let t = try TestHome()
        defer { clear(t) }
        let writer = NoFollowWriter(root: t.context.dataRoot)
        try writer.prepare(folders: TokenPaths.folders)
        let tokens = t.context.dataRoot.appendingPathComponent(TokenPaths.folderName)
        let place = "~/.agent-balancer/" + TokenPaths.folderName
        // A name no other test writes, so the seam stops this write only.
        let name = "stopped-before-rename.json"
        NoFollowWriter.beforeRename.set(name) { throw ToolError("Stopped before the rename.") }
        defer { NoFollowWriter.beforeRename.set(name, nil) }
        #expect(appendOnly(tokens, true))
        defer { _ = appendOnly(tokens, false) }
        let holding = "the token of 'pool-a'"
        var said = ""
        do {
            try writer.put(
                Data("x".utf8), folders: TokenPaths.folders, name: name, holding: holding)
        } catch let error as ToolError {
            said = error.message
        }
        let left = try #require(temporaries(tokens).first)
        #expect(temporaries(tokens).count == 1)
        #expect(
            said
                == "Stopped before the rename. "
                + Messages.temporaryLeft(place: place, name: left, holding: holding))
        #expect(try Data(contentsOf: tokens.appendingPathComponent(left)) == Data("x".utf8))
        #expect(!FileManager.default.fileExists(atPath: tokens.appendingPathComponent(name).path))
    }

    @Test func aProbeFolderItCannotRemoveLosesItsOwnListAndOnlyAFolderEntryKeepsIt() throws {
        let t = try TestHome()
        defer { clear(t) }
        let writer = NoFollowWriter(root: t.context.dataRoot)
        try writer.prepare(folders: Layout.probeFolders)
        let probe = t.context.dataRoot.appendingPathComponent(Layout.probeFolders[0])
        let place = "~/.agent-balancer/" + Layout.probeFolders[0]
        let me = NSUserName()
        func check() throws {
            try writer.requireScratchable(
                parent: Layout.probeFolders, prefix: Layout.probeFolderPrefix, staleAfter: 3600)
        }
        #expect(
            runChmod(["+a", "\(me) deny delete,directory_inherit,only_inherit", probe.path]) == 0)
        #expect(throws: ToolError(Messages.folderNotWritable(place), code: .checkFailed)) {
            try check()
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: probe.path).isEmpty)
        #expect(runChmod(["+a", "\(me) deny delete_child", probe.path]) == 0)
        var said = ""
        do {
            try check()
        } catch let error as ToolError {
            said = error.message
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: probe.path)
        let left = try #require(names.first)
        #expect(
            said
                == Messages.folderNotWritable(place) + " "
                + Messages.checkLeft(place + "/" + left, folder: true))
        let folder = probe.appendingPathComponent(left)
        #expect(entries(folder).isEmpty)
        #expect(runChmod(["-N", probe.path]) == 0)
        try check()
    }

    @Test func aCheckFileAnotherCommandDeletedFirstIsMadeOnceMore() throws {
        let t = try TestHome()
        defer { clear(t) }
        let writer = NoFollowWriter(root: t.context.dataRoot)
        try writer.prepare(folders: TokenPaths.folders)
        let tokens = t.context.dataRoot.appendingPathComponent(TokenPaths.folderName)
        let calls = HookCalls()
        // The folder's full path, so the seam acts on this test's folder only.
        let key = t.context.dataRoot.path + "/" + TokenPaths.folderName
        NoFollowWriter.afterCheckFileMade.set(key) {
            calls.add("made")
            // The cleanup of the writer's leftovers another `login` runs, once.
            guard calls.labels.count == 1 else { return }
            for name in temporaries(tokens) {
                try FileManager.default.removeItem(at: tokens.appendingPathComponent(name))
            }
        }
        defer { NoFollowWriter.afterCheckFileMade.set(key, nil) }
        try writer.requireWritable(folders: TokenPaths.folders)
        #expect(calls.labels.count == 2)
        #expect(temporaries(tokens).isEmpty)
    }

    @Test func aReadCheckSaysTheToolDoesNotReadANameThatIsNotARegularFile() {
        let text = Messages.fileRefused("`x`", "x", .notRegular, "read it")
        #expect(text.contains("so the tool does not read it"))
        #expect(
            Messages.fileRefused("`x`", "x", .notRegular, "replace or delete it").contains(
                "so the tool does not write it"))
    }
}
