import Foundation

/// The folder the menu app's developer flags (`--render`, `--iconset`) write into. It must lie
/// under the current folder's `build` folder, be written with no `..` segment, have no link on its
/// way and no folder named `.claude` or `.agent-balancer` below the current folder, and sit
/// outside the home's `.claude` and `.agent-balancer` folders. Each home must be a folder named
/// with no `..` segment, and its `.claude` and `.agent-balancer` missing or a folder, a link to one
/// included; a HOME that is set but empty or is not an absolute path stops the render too. `hold`
/// checks that, then opens the folder once, one name at a time from the current folder, and every
/// file is written relative to that handle by the Paths writer, after the protected folders are
/// read again.
public enum RenderOutput {
    static let refusal = ToolError(
        "The output folder must be a folder under build/ in the current folder, written without .. and with no link or .claude or .agent-balancer folder on its path, outside ~/.claude and ~/.agent-balancer. Nothing was written."
    )

    static let toolFolderRefusal = ToolError(
        "The home must be a folder, and its .claude and .agent-balancer must each be missing or a folder: a link to nothing or to a file stops every render. A HOME that is set but empty, is not an absolute path, or has a .. segment stops every render too. Nothing was written."
    )

    static let toolFolders = [".claude", ".agent-balancer"]

    /// Folder names no output path may hold below the current folder, compared without case.
    static let toolFolderNames = Set(toolFolders)

    /// HOME, or the default home when HOME is not set, and the home the user database names.
    /// HOME is checked as written, by the rule every command shares (`ToolContext.isUsableHome`),
    /// before it becomes a path: a path made from a relative HOME is joined to the current folder
    /// with each `..` dropped by name, while the system resolves a `..` after a link from where the
    /// link points, and a path made from an empty HOME names the current folder
    /// (`ToolContext.current()` reads an empty HOME as the default home).
    static func homes(environment: [String: String]) throws -> [URL] {
        let home = environment["HOME"] ?? NSHomeDirectory()
        guard ToolContext.isUsableHome(home) else { throw toolFolderRefusal }
        var homes = [URL(fileURLWithPath: home)]
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            homes.append(URL(fileURLWithPath: String(cString: dir)))
        }
        return homes
    }

    static func homes() throws -> [URL] { try homes(environment: Env.snapshot()) }

    /// The checked folder for the flag's argument, from the process's current folder and homes.
    public static func folder(_ argument: String) throws -> URL {
        try folder(
            argument, currentDirectoryPath: FileManager.default.currentDirectoryPath,
            homes: homes())
    }

    /// The flag's folder, checked and then held open for writing, from the process's current
    /// folder.
    public static func hold(_ argument: String) throws -> HeldFolder {
        try hold(
            argument, currentDirectoryPath: FileManager.default.currentDirectoryPath,
            homes: homes(), start: ".")
    }

    /// Checks `argument` as `folder` does, then opens the folder from `start` (the current folder;
    /// its path when nil). The start must be the folder that path names, with no protected folder
    /// above it, and no folder on the way down may be a link or a protected folder. The protected
    /// folders are read again once the folder is open and before each file.
    public static func hold(
        _ argument: String, currentDirectoryPath: String, homes: [URL], start: String? = nil
    ) throws -> HeldFolder {
        let refused = try check(argument, currentDirectoryPath: currentDirectoryPath, homes: homes)
            .protected
        let base = normalized(currentDirectoryPath)
        let path = normalized(argument.hasPrefix("/") ? argument : base + "/" + argument)
        let names = path.dropFirst(base == "/" ? 1 : base.count + 1)
            .split(separator: "/").map(String.init)
        guard names.first == "build", names.count >= 2 else { throw refusal }
        do {
            return try NoFollowWriter.holdFolder(
                start: start ?? base, checked: base, names: names, refused: refused,
                current: { protectedIdentities(homes) })
        } catch {
            throw refusal
        }
    }

    /// The homes' `.claude` and `.agent-balancer` folders as their paths name them now, or nil
    /// when one cannot be compared: a home named with a `..` segment or that is not a folder, or
    /// a tool folder that is a link to nothing, names something other than a folder, or cannot be
    /// read. A tool folder missing from a home that is a folder can be made only by its own name,
    /// which no output path holds.
    static func protectedIdentities(_ homes: [URL]) -> [FileIdentity]? {
        var found: [FileIdentity] = []
        for home in homes {
            // The system resolves a `..` after a link from where the link points, while a join of
            // the path drops the name before it, so the two can name different tool folders.
            guard !home.path.split(separator: "/").contains(".."),
                folderIdentity(normalized(home.path)) != nil
            else { return nil }
            for name in toolFolders {
                let spot = normalized(home.path + "/" + name)
                var st = stat()
                if lstat(spot, &st) != 0 {
                    if errno == ENOENT { continue }
                    return nil
                }
                guard let identity = folderIdentity(spot) else { return nil }
                found.append(identity)
            }
        }
        return found
    }

    /// The identity of the folder `path` names, following links, or nil when it names none.
    static func folderIdentity(_ path: String) -> FileIdentity? {
        var st = stat()
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return nil }
        return FileIdentity(st)
    }

    /// Throws `refusal` for any argument that breaks one of the rules; nothing is created here.
    public static func folder(_ argument: String, currentDirectoryPath: String, homes: [URL])
        throws -> URL
    {
        try check(argument, currentDirectoryPath: currentDirectoryPath, homes: homes).folder
    }

    /// The checked folder and the protected folders it was checked against.
    static func check(_ argument: String, currentDirectoryPath: String, homes: [URL])
        throws -> (folder: URL, protected: [FileIdentity])
    {
        // Foundation gives "" when the current folder's path is too long, and then no path names
        // the folder that "." opens.
        guard currentDirectoryPath.hasPrefix("/") else { throw refusal }
        let segments = argument.split(separator: "/", omittingEmptySubsequences: false)
        guard !argument.isEmpty, !segments.contains("..") else { throw refusal }
        let base = normalized(currentDirectoryPath)
        let path = normalized(argument.hasPrefix("/") ? argument : base + "/" + argument)
        let build = (base == "/" ? "" : base) + "/build/"
        guard path.hasPrefix(build), path.count > build.count else { throw refusal }
        // A home given through a link names a tool folder not made yet by another spelling, and
        // only a folder that exists has an identity to compare, so the names alone are refused.
        let below = path.dropFirst(base == "/" ? 1 : base.count + 1).split(separator: "/")
        guard !below.contains(where: { toolFolderNames.contains($0.lowercased()) }) else {
            throw refusal
        }

        for home in homes {
            for name in toolFolders {
                let inside = normalized(home.path + "/" + name)
                let lower = path.lowercased()
                if lower == inside.lowercased() || lower.hasPrefix(inside.lowercased() + "/") {
                    throw refusal
                }
            }
        }
        // A case or firmlink spelling of a protected folder is caught by its identity. A tool
        // folder that is a link to nothing has none, and the run could make the folder it names.
        guard let protected = protectedIdentities(homes) else { throw toolFolderRefusal }

        var walked = ""
        for part in path.split(separator: "/") {
            walked += "/" + part
            var st = stat()
            guard lstat(walked, &st) == 0 else {
                // Everything below a missing folder is missing too; the writer refuses to make it.
                if errno == ENOENT { break }
                throw refusal
            }
            guard (st.st_mode & S_IFMT) == S_IFDIR, !protected.contains(FileIdentity(st)) else {
                throw refusal
            }
        }
        return (URL(fileURLWithPath: path, isDirectory: true), protected)
    }

    /// The path with empty and `.` segments dropped. Foundation's standardizing is not used: it
    /// can drop a leading `/private`, which would put the `/var` or `/tmp` link back on the path.
    static func normalized(_ path: String) -> String {
        "/" + path.split(separator: "/").filter { $0 != "." }.joined(separator: "/")
    }
}
