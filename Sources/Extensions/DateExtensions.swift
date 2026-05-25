import Foundation

extension Date {
    /// Formats the date as a relative string when appropriate
    /// - Returns: Relative format like "Today", "Yesterday", or absolute date
    func relativeFormatted() -> String {
        let calendar = Calendar.current
        let now = Date()

        // Check if same day
        if calendar.isDateInToday(self) {
            return "Today at \(self.formatted(date: .omitted, time: .shortened))"
        }

        // Check if yesterday
        if calendar.isDateInYesterday(self) {
            return "Yesterday at \(self.formatted(date: .omitted, time: .shortened))"
        }

        // Check if within last week
        if let daysAgo = calendar.dateComponents([.day], from: self, to: now).day,
           daysAgo < 7, daysAgo > 0 {
            let weekday = self.formatted(Date.FormatStyle().weekday(.wide))
            return "\(weekday) at \(self.formatted(date: .omitted, time: .shortened))"
        }

        // Check if within current year
        if calendar.component(.year, from: self) == calendar.component(.year, from: now) {
            return self.formatted(date: .abbreviated, time: .shortened)
        }

        // Default to full date
        return self.formatted(date: .long, time: .standard)
    }

    /// Formats the date as a compact relative string
    /// Sub-hour times are shown as "Xs ago" or "Xm ago". Older times show day + clock.
    func relativeFormattedCompact() -> String {
        let now = Date()
        let seconds = now.timeIntervalSince(self)
        let calendar = Calendar.current

        if seconds < 60 {
            return "\(max(0, Int(seconds)))s ago"
        }

        if seconds < 3600 {
            return "\(Int(seconds / 60))m ago"
        }

        // Same day - show "Today HH:MM"
        if calendar.isDateInToday(self) {
            return "Today \(self.formatted(date: .omitted, time: .shortened))"
        }

        // Yesterday - show "Yesterday HH:MM"
        if calendar.isDateInYesterday(self) {
            return "Yesterday \(self.formatted(date: .omitted, time: .shortened))"
        }

        // Older than yesterday - show full date with time
        return self.formatted(date: .abbreviated, time: .shortened)
    }

    /// True if the date is within the last 2 minutes
    var isRecent: Bool {
        Date().timeIntervalSince(self) < 120
    }
}
