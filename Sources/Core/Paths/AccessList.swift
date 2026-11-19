import Darwin.membership
import Foundation

/// Reads a file's or folder's extended access list through libc's access list calls only. An
/// access list can let others in whatever the mode says, so the privacy checks read both, and the
/// check of the `claude` binary also reads every rights bit of each entry.
enum AccessList {
    /// What an extended access list lets in.
    enum Verdict: Equatable, Sendable {
        /// No list, or entries that only deny, or only allow the user, or, when only a change
        /// counts, entries that give others nothing but rights that change nothing.
        case closed
        /// An allow entry for another user, for a group, or for anyone it cannot name, inherited
        /// or not, also one that only passes on to what is made inside a folder.
        case open
        /// The list cannot be read, such as one with an entry that denies the user `readsecurity`
        /// or `readattr`.
        case unreadable
    }

    /// Which rights of an allow entry for another user or group make a list open.
    enum Counted: Sendable {
        /// Every right, so an entry that only lets others read counts, as privacy needs.
        case anyRight
        /// Every right but those of `unchangingRights`.
        case anyChange
    }

    /// The rights bits that change nothing: `read` (`list` on a folder), `execute` (`search`),
    /// `readattr`, `readextattr`, `readsecurity`, and `synchronize`, which macOS keeps for
    /// Windows file sharing only. Any other bit counts as a change, a generic right or one libc
    /// does not name included, so a bit the check does not know never passes.
    static let unchangingRights: UInt32 =
        ACL_READ_DATA.rawValue | ACL_EXECUTE.rawValue | ACL_READ_ATTRIBUTES.rawValue
        | ACL_READ_EXTATTRIBUTES.rawValue | ACL_READ_SECURITY.rawValue | ACL_SYNCHRONIZE.rawValue

    /// The verdict on the extended access list of the open file or folder `fd`.
    static func verdict(_ fd: Int32) -> Verdict {
        errno = 0
        let list = acl_get_fd_np(fd, ACL_TYPE_EXTENDED)
        return verdict(list, error: errno, counting: .anyRight)
    }

    /// The verdict on the entry at `path` itself: a link there is not followed, and the entry is
    /// not opened, so one whose list denies its owner `read` is still judged.
    static func verdict(path: String, counting counted: Counted = .anyRight) -> Verdict {
        errno = 0
        let list = acl_get_link_np(path, ACL_TYPE_EXTENDED)
        return verdict(list, error: errno, counting: counted)
    }

    /// Whether the list of `fd` lets anyone but the user in or cannot be read, so a check that
    /// asks fails closed.
    static func letsOthersIn(_ fd: Int32) -> Bool { verdict(fd) != .closed }

    /// The same answer for the entry at `path` itself, as `verdict(path:)` reads it.
    static func letsOthersIn(path: String) -> Bool { verdict(path: path) != .closed }

    /// Whether the list of the entry at `path` itself gives another user or group a right other
    /// than those of `unchangingRights`, inherited or not, or cannot be read, so a check that
    /// asks fails closed.
    static func letsOthersChange(path: String) -> Bool {
        verdict(path: path, counting: .anyChange) != .closed
    }

    /// The verdict when a read gives no list, from its `errno`: no extended list (`ENOENT`) and a
    /// volume that keeps no access lists (`ENOTSUP`, `EOPNOTSUPP`) hold no entry; any other error
    /// leaves the list unread.
    static func verdictWithoutList(_ error: Int32) -> Verdict {
        [ENOENT, ENOTSUP, EOPNOTSUPP].contains(error) ? .closed : .unreadable
    }

    private static func verdict(_ list: acl_t?, error: Int32, counting counted: Counted)
        -> Verdict
    {
        guard let list else { return verdictWithoutList(error) }
        defer { acl_free(UnsafeMutableRawPointer(list)) }
        if counted == .anyChange { return changeVerdict(list) }
        var entry: acl_entry_t?
        var which = ACL_FIRST_ENTRY.rawValue
        while true {
            errno = 0
            guard acl_get_entry(list, which, &entry) == 0, let found = entry else {
                // Only the end of the list reads as EINVAL; any other stop leaves entries unread.
                return errno == EINVAL ? .closed : .unreadable
            }
            which = ACL_NEXT_ENTRY.rawValue
            var tag = ACL_UNDEFINED_TAG
            guard acl_get_tag_type(found, &tag) == 0 else { return .unreadable }
            if tag == ACL_EXTENDED_DENY { continue }
            guard tag == ACL_EXTENDED_ALLOW, namesTheUser(found) else { return .open }
        }
    }

    /// The verdict on `list` when only a change counts, read from libc's external form of the
    /// list (`acl_copy_ext_native`, laid out as `sys/kauth.h`'s `kauth_filesec`), which keeps
    /// every rights bit of each entry, where `acl_get_perm_np` refuses the generic rights.
    private static func changeVerdict(_ list: acl_t) -> Verdict {
        guard let aclStart = MemoryLayout<kauth_filesec>.offset(of: \.fsec_acl),
            let aceStart = MemoryLayout<kauth_acl>.offset(of: \.acl_ace),
            let whoAt = MemoryLayout<kauth_ace>.offset(of: \.ace_applicable),
            let flagsAt = MemoryLayout<kauth_ace>.offset(of: \.ace_flags),
            let rightsAt = MemoryLayout<kauth_ace>.offset(of: \.ace_rights)
        else { return .unreadable }
        let size = acl_size(list)
        guard size >= aclStart + aceStart else { return .unreadable }
        var form = [UInt8](repeating: 0, count: size)
        let copied = form.withUnsafeMutableBytes { acl_copy_ext_native($0.baseAddress, list, size) }
        guard copied == size else { return .unreadable }
        return form.withUnsafeBytes { raw -> Verdict in
            guard let base = raw.baseAddress,
                raw.loadUnaligned(as: UInt32.self) == UInt32(KAUTH_FILESEC_MAGIC)
            else { return .unreadable }
            let count = Int(raw.loadUnaligned(fromByteOffset: aclStart, as: UInt32.self))
            let stride = MemoryLayout<kauth_ace>.stride
            guard count <= (size - aclStart - aceStart) / stride else { return .unreadable }
            for index in 0..<count {
                let ace = aclStart + aceStart + index * stride
                let flags = raw.loadUnaligned(fromByteOffset: ace + flagsAt, as: UInt32.self)
                let rights = raw.loadUnaligned(fromByteOffset: ace + rightsAt, as: UInt32.self)
                switch flags & UInt32(KAUTH_ACE_KINDMASK) {
                case UInt32(KAUTH_ACE_DENY): continue
                case UInt32(KAUTH_ACE_PERMIT): break
                default: return .open
                }
                if namesTheUser(base + ace + whoAt) { continue }
                if rights & ~unchangingRights != 0 { return .open }
            }
            return .closed
        }
    }

    /// Whether the entry's qualifier resolves to the user who runs the tool.
    private static func namesTheUser(_ entry: acl_entry_t) -> Bool {
        guard let qualifier = acl_get_qualifier(entry) else { return false }
        defer { acl_free(qualifier) }
        return namesTheUser(UnsafeRawPointer(qualifier))
    }

    /// Whether the 16-byte qualifier at `uuid` resolves to the user who runs the tool.
    private static func namesTheUser(_ uuid: UnsafeRawPointer) -> Bool {
        var id: uid_t = 0
        var type: Int32 = -1
        guard mbr_uuid_to_id(uuid.assumingMemoryBound(to: UInt8.self), &id, &type) == 0 else {
            return false
        }
        return type == ID_TYPE_UID && id == getuid()
    }
}
