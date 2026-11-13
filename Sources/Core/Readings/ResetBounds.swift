import Foundation

/// How far from the time of a reading a window's reset time can plausibly be. A reset time
/// outside these bounds is not stored: it would pin the window, or fail to encode.
public enum ResetBounds {
    /// Clock skew between the service and this Mac.
    public static let slack: TimeInterval = 300

    /// The length of the window: five hours for `five_hour`, seven days for every name that
    /// starts with `seven_day` (the weekly window, the Fable meter and any other weekly one), and
    /// 31 days for any other name.
    public static func horizon(for name: String) -> TimeInterval {
        if name == WindowName.fiveHour { return 5 * 3600 }
        if name.hasPrefix("seven_day") { return 7 * 86_400 }
        return 31 * 86_400
    }

    /// True when `reset` lies within `slack` before `readAt` and one window length plus `slack`
    /// after it. NaN and infinity are never in range.
    public static func contains(_ reset: Date, window name: String, readAt: Date) -> Bool {
        let seconds = reset.timeIntervalSince(readAt)
        guard seconds.isFinite else { return false }
        return seconds >= -slack && seconds <= horizon(for: name) + slack
    }

    /// The latest reset time a stored window can hold at `now`. The margin covers a reading dated
    /// a little ahead of the clock.
    static func storedCeiling(window name: String, now: Date) -> Date {
        now.addingTimeInterval(horizon(for: name) + 2 * slack)
    }
}
