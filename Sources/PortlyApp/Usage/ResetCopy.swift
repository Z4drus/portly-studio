import Foundation

/// "Resets in 51 min" under an hour, "Resets Thu 12:00 AM" within the week,
/// "Resets Sep 28" beyond it.
enum ResetCopy {
    static func text(for resetsAt: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let seconds = resetsAt.timeIntervalSince(now)
        guard seconds > 0 else { return "Resetting…" }

        // Rounding, not truncation, so 50m40s reads as 51 rather than 50. A
        // value that rounds up to 60 falls through to the absolute form, so
        // "Resets in 60 min" never appears.
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 {
            return "Resets in \(max(1, minutes)) min"
        }

        let formatter = formatter(for: calendar)

        // A weekday only identifies a day inside the coming week; a monthly
        // window resetting 26 days out would otherwise read as *this* Monday.
        if daysApart(from: now, to: resetsAt, calendar: calendar) >= 7 {
            formatter.setLocalizedDateFormatFromTemplate("MMM d")
            return "Resets \(formatter.string(from: resetsAt))"
        }

        // A literal pattern rather than a localised template: the weekday and
        // AM/PM still come from the locale, but the separator stays a colon,
        // the way Claude's own usage panel writes it.
        formatter.dateFormat = "E h:mm a"
        return "Resets \(formatter.string(from: resetsAt))"
    }

    /// A formatter that renders in the given calendar's own zone.
    static func formatter(for calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = .current
        return formatter
    }

    /// Whole days between two instants, counted by calendar day rather than by
    /// dividing seconds, so a clock change cannot shift the answer.
    static func daysApart(from: Date, to: Date, calendar: Calendar = .current) -> Int {
        let start = calendar.startOfDay(for: from)
        let end = calendar.startOfDay(for: to)
        return calendar.dateComponents([.day], from: start, to: end).day ?? 0
    }
}

/// "How long has it been like this": the age of a reading or a session.
enum ElapsedCopy {
    /// The same span, phrased as a point in the past.
    static func ago(since: Date, now: Date = Date()) -> String {
        let elapsed = text(since: since, now: now)
        return elapsed == "just now" ? elapsed : "\(elapsed) ago"
    }

    static func text(since: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(since))
        if seconds < 45 { return "just now" }

        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(max(1, minutes)) min" }

        let hours = minutes / 60
        let rest = minutes % 60
        if rest == 0 { return "\(hours) hr" }
        return "\(hours) hr \(rest) min"
    }
}
