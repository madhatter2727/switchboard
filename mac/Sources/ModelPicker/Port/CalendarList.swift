import EventKit
import Foundation

@MainActor
extension CalendarTools {
    static func eventLines(from start: Date, to end: Date) -> [String] {
        let calendars = Settings.calendarsForEventQuery(store: store)
        if let calendars, calendars.isEmpty { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        let sorted = store.events(matching: predicate).sorted {
            ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast)
        }
        var seen = Set<String>()
        var lines: [String] = []
        let showDay = spansMoreThanOneDay(start, end)
        for event in sorted {
            if event.status == .canceled { continue }
            let key = "\(event.eventIdentifier ?? "")|\(event.startDate?.timeIntervalSince1970 ?? 0)"
            if !seen.insert(key).inserted { continue }
            lines.append(eventLine(event, showDay: showDay))
            if lines.count == cap { break }
        }
        return lines
    }

    /// Today and tomorrow already name the day in the heading. A longer range has to say which day.
    private static func spansMoreThanOneDay(_ start: Date, _ end: Date) -> Bool {
        let calendar = Calendar.current
        let last = calendar.date(byAdding: .second, value: -1, to: end) ?? end
        return !calendar.isDate(start, inSameDayAs: last)
    }

    static func incompleteReminders() async -> [EKReminder] {
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let fetched: [EKReminder] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
        return fetched.filter { !$0.isCompleted }.sorted(by: reminderOrder)
    }

    static func reminderLine(_ reminder: EKReminder) -> String {
        let name = clean(reminder.title) ?? "(No title)"
        let due: String
        if let when = dueDate(reminder) {
            let text = when.hasTime
                ? when.date.formatted(date: .abbreviated, time: .shortened)
                : when.date.formatted(date: .abbreviated, time: .omitted)
            due = "due \(text)"
        } else {
            due = "no due date"
        }
        guard let list = clean(reminder.calendar?.title) else { return "- \(name) — \(due)" }
        return "- \(name) — \(due) (\(list))"
    }

    static func heading(_ span: CalendarSpan, start: Date, end: Date) -> String {
        switch span {
        case .today:
            return "Today, \(start.formatted(date: .complete, time: .omitted))"
        case .tomorrow:
            return "Tomorrow, \(start.formatted(date: .complete, time: .omitted))"
        case .thisWeek:
            let last = Calendar.current.date(byAdding: .day, value: -1, to: end) ?? start
            let left = start.formatted(date: .abbreviated, time: .omitted)
            let right = last.formatted(date: .abbreviated, time: .omitted)
            return "This week, \(left) – \(right)"
        }
    }

    private static func eventLine(_ event: EKEvent, showDay: Bool) -> String {
        let name = clean(event.title) ?? "(No title)"
        let when = whenText(event, showDay: showDay)
        guard let calendar = clean(event.calendar?.title) else { return "\(when) — \(name)" }
        return "\(when) — \(name) (\(calendar))"
    }

    private static func whenText(_ event: EKEvent, showDay: Bool) -> String {
        if event.isAllDay {
            return showDay ? allDayLabel(event.startDate, event.endDate) : "All day"
        }
        if showDay {
            return datedRange(event.startDate, event.endDate)
        }
        return clockRange(event.startDate, event.endDate)
    }

    private static func allDayLabel(_ start: Date?, _ end: Date?) -> String {
        guard let start else { return "All day" }
        let last = end.flatMap { Calendar.current.date(byAdding: .second, value: -1, to: $0) } ?? start
        if Calendar.current.isDate(start, inSameDayAs: last) {
            return "All day \(start.formatted(date: .abbreviated, time: .omitted))"
        }
        let left = start.formatted(date: .abbreviated, time: .omitted)
        let right = last.formatted(date: .abbreviated, time: .omitted)
        return "All day \(left) – \(right)"
    }

    private static func datedRange(_ start: Date?, _ end: Date?) -> String {
        guard let start else { return "Time not set" }
        guard let end else { return start.formatted(date: .abbreviated, time: .shortened) }
        if Calendar.current.isDate(start, inSameDayAs: end) {
            let day = start.formatted(date: .abbreviated, time: .omitted)
            let left = start.formatted(date: .omitted, time: .shortened)
            let right = end.formatted(date: .omitted, time: .shortened)
            return "\(day), \(left)–\(right)"
        }
        let left = start.formatted(date: .abbreviated, time: .shortened)
        let right = end.formatted(date: .abbreviated, time: .shortened)
        return "\(left) – \(right)"
    }

    private static func clockRange(_ start: Date?, _ end: Date?) -> String {
        guard let start else { return "Time not set" }
        let startText = start.formatted(date: .omitted, time: .shortened)
        guard let end else { return startText }
        if Calendar.current.isDate(start, inSameDayAs: end) {
            return "\(startText)–\(end.formatted(date: .omitted, time: .shortened))"
        }
        let left = start.formatted(date: .abbreviated, time: .shortened)
        let right = end.formatted(date: .abbreviated, time: .shortened)
        return "\(left) – \(right)"
    }

    private static func reminderOrder(_ lhs: EKReminder, _ rhs: EKReminder) -> Bool {
        switch (dueDate(lhs)?.date, dueDate(rhs)?.date) {
        case let (left?, right?) where left != right:
            return left < right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return (lhs.title ?? "") < (rhs.title ?? "")
        }
    }

    private static func dueDate(_ reminder: EKReminder) -> (date: Date, hasTime: Bool)? {
        guard let parts = reminder.dueDateComponents else { return nil }
        guard let date = Calendar.current.date(from: parts) else { return nil }
        return (date, parts.hour != nil)
    }
}
