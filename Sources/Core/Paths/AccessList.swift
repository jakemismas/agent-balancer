import Darwin.membership
import Foundation

/// Reads a file's or folder's extended access list through libc's access list calls only. An
/// access list can let others in whatever the mode says, so the privacy checks read both.
enum AccessList {
    /// What an extended access list lets in.
    enum Verdict: Equatable, Sendable {
        /// No list, or entries that only deny, or only allow the user.
        case closed
        /// An allow entry for another user, for a group, or for anyone it cannot name, inherited
        /// or not, also one that only passes on to what is made inside a folder.
        case open
        /// The list cannot be read, such as one with an entry that denies the user `readsecurity`
        /// or `readattr`.
        case unreadable
    }

    /// The verdict on the extended access list of the open file or folder `fd`.
    static func verdict(_ fd: Int32) -> Verdict {
        errno = 0
        let list = acl_get_fd_np(fd, ACL_TYPE_EXTENDED)
        return verdict(list, error: errno)
    }

    /// The verdict on the entry at `path` itself: a link there is not followed, and the entry is
    /// not opened, so one whose list denies its owner `read` is still judged.
    static func verdict(path: String) -> Verdict {
        errno = 0
        let list = acl_get_link_np(path, ACL_TYPE_EXTENDED)
        return verdict(list, error: errno)
    }

    /// Whether the list of `fd` lets anyone but the user in or cannot be read, so a check that
    /// asks fails closed.
    static func letsOthersIn(_ fd: Int32) -> Bool { verdict(fd) != .closed }

    /// The same answer for the entry at `path` itself, as `verdict(path:)` reads it.
    static func letsOthersIn(path: String) -> Bool { verdict(path: path) != .closed }

    /// The verdict when a read gives no list, from its `errno`: no extended list (`ENOENT`) and a
    /// volume that keeps no access lists (`ENOTSUP`, `EOPNOTSUPP`) hold no entry; any other error
    /// leaves the list unread.
    static func verdictWithoutList(_ error: Int32) -> Verdict {
        [ENOENT, ENOTSUP, EOPNOTSUPP].contains(error) ? .closed : .unreadable
    }

    private static func verdict(_ list: acl_t?, error: Int32) -> Verdict {
        guard let list else { return verdictWithoutList(error) }
        defer { acl_free(UnsafeMutableRawPointer(list)) }
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

    /// Whether the entry's qualifier resolves to the user who runs the tool.
    private static func namesTheUser(_ entry: acl_entry_t) -> Bool {
        guard let qualifier = acl_get_qualifier(entry) else { return false }
        defer { acl_free(qualifier) }
        var id: uid_t = 0
        var type: Int32 = -1
        let uuid = qualifier.assumingMemoryBound(to: UInt8.self)
        guard mbr_uuid_to_id(uuid, &id, &type) == 0 else { return false }
        return type == ID_TYPE_UID && id == getuid()
    }
}
