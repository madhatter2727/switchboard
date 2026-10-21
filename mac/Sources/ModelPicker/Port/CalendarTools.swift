import EventKit
import Foundation

enum CalendarSpan: Equatable {
    case today
    case tomorrow
    case thisWeek
}

/// EventKit reads. The store is main-actor only; EventKit is not thread-safe.
@MainActor
enum CalendarTools {
    static let denialEvents = "Model Picker needs full calendar access. Turn it on in System Settings > Privacy & Security > Calendars, then try again."
    static let denialReminders = "Model Picker needs full reminders access. Turn it on in System Settings > Privacy & Security > Reminders, then try again."
    static let noWritableCalendar = "There's no calendar I can add to. Check that a calendar that allows new events is ticked under Settings > Calendars to read."

    static let store = EKEventStore()
    static let cap = 40

    /// "what's on my calendar today/tomorrow/this week", plus a few obvious wordings.
    nonisolated static func span(in raw: String) -> CalendarSpan? {
        var text = raw.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
        let trailing = CharacterSet(charactersIn: "?.!,;: ")
        while let last = text.unicodeScalars.last, trailing.contains(last) {
            text.unicodeScalars.removeLast()
        }
        if text.hasSuffix(" please") {
            text = String(text.dropLast(" please".count))
            while let last = text.unicodeScalars.last, trailing.contains(last) {
                text.unicodeScalars.removeLast()
            }
        }
        let prefixes = [
            "what's on my calendar",
            "what's on the calendar",
            "what is on my calendar",
            "what is on the calendar",
            "whats on my calendar",
            "whats on the calendar",
            "show me my calendar",
            "show my calendar",
            "show the calendar"
        ]
        for prefix in prefixes {
            guard text.hasPrefix(prefix) else { continue }
            var rest = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix("for ") {
                rest = String(rest.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            }
            switch rest {
            case "today": return .today
            case "tomorrow": return .tomorrow
            case "this week": return .thisWeek
            default: return nil
            }
        }
        return nil
    }

    static func report(_ span: CalendarSpan) async -> String {
        guard await ensureRead() else { return denialEvents }
        let (start, end) = window(span)
        let lines = eventLines(from: start, to: end)
        let title = heading(span, start: start, end: end)
        if lines.isEmpty { return "\(title): no events." }
        return "\(title):\n" + lines.joined(separator: "\n")
    }

    static func events(from startRaw: String, to endRaw: String) async -> String {
        guard let start = CalendarWhen.parse(startRaw), let end = CalendarWhen.parse(endRaw) else {
            return CalendarWhen.unreadable
        }
        guard let bounds = CalendarWhen.bounds(start, end) else {
            return "The end time has to be after the start."
        }
        guard await ensureRead() else { return denialEvents }
        let lines = eventLines(from: bounds.start, to: bounds.end)
        if lines.isEmpty { return "No events in that range." }
        return lines.joined(separator: "\n")
    }

    static func reminders() async -> String {
        guard await ensureReminders() else { return denialReminders }
        let items = await incompleteReminders()
        if items.isEmpty { return "No incomplete reminders." }
        var lines = items.prefix(cap).map(reminderLine)
        if items.count > cap { lines.append("And \(items.count - cap) more.") }
        return "Incomplete reminders:\n" + lines.joined(separator: "\n")
    }

    /// Authorization line, then tomorrow's events, or the words "no access".
    /// Does not prompt. A headless run must print and exit even when no one can click a dialog.
    static func selftestText() async -> String {
        let status = EKEventStore.authorizationStatus(for: .event)
        let label = statusLabel(status)
        guard canRead(status) else { return "authorization: \(label)\nno access" }
        let reading: String
        if let picked = Settings.calendarsForEventQuery(store: store) {
            reading = "calendars to read: \(picked.count) of \(store.calendars(for: .event).count)"
        } else {
            reading = "calendars to read: all"
        }
        let (start, end) = window(.tomorrow)
        let lines = eventLines(from: start, to: end)
        let body = lines.isEmpty ? "No events tomorrow." : lines.joined(separator: "\n")
        return "authorization: \(label)\n\(reading)\n\(body)"
    }

    static func newEventCalendarTitle() -> String? {
        guard let calendar = writableCalendar() else { return nil }
        let title = calendar.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "your calendar" : title
    }

    static func save(_ action: PendingAction) -> PendingAction {
        guard let title = action.eventTitle, let start = action.eventStart, let end = action.eventEnd else {
            return fail(action, "That event is missing a title or a time.")
        }
        guard canWrite(EKEventStore.authorizationStatus(for: .event)) else {
            return fail(action, denialEvents)
        }
        guard let calendar = writableCalendar() else {
            return fail(action, noWritableCalendar)
        }
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = title
        event.isAllDay = action.eventAllDay
        event.startDate = start
        event.endDate = end
        if !action.eventAllDay {
            event.timeZone = .current
        }
        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            return fail(action, "Couldn't add the event: \(error.localizedDescription)")
        }
        var done = action
        done.phase = .done
        let whereName = calendar.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = whereName.isEmpty ? "your calendar" : whereName
        done.resultText = "Added “\(title)” to \(place)."
        return done
    }

    nonisolated static func window(_ span: CalendarSpan, now: Date = Date()) -> (Date, Date) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        switch span {
        case .today:
            let end = calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
            return (today, end)
        case .tomorrow:
            let start = calendar.date(byAdding: .day, value: 1, to: today) ?? today
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
            return (start, end)
        case .thisWeek:
            if let interval = calendar.dateInterval(of: .weekOfYear, for: now) {
                return (interval.start, interval.end)
            }
            let end = calendar.date(byAdding: .day, value: 7, to: today) ?? today.addingTimeInterval(7 * 86_400)
            return (today, end)
        }
    }

    static func ensureRead() async -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if canRead(status) { return true }
        if status != .notDetermined { return false }
        _ = await askEvents()
        return canRead(EKEventStore.authorizationStatus(for: .event))
    }

    static func ensureWrite() async -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if canWrite(status) { return true }
        if status != .notDetermined { return false }
        _ = await askEvents()
        return canWrite(EKEventStore.authorizationStatus(for: .event))
    }

    private static func ensureReminders() async -> Bool {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if canRead(status) { return true }
        if status != .notDetermined { return false }
        _ = await askReminders()
        return canRead(EKEventStore.authorizationStatus(for: .reminder))
    }

    private static func askEvents() async -> Bool {
        await withCheckedContinuation { continuation in
            store.requestFullAccessToEvents { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    private static func askReminders() async -> Bool {
        await withCheckedContinuation { continuation in
            store.requestFullAccessToReminders { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    /// Only calendars ticked in Settings > Calendars to read. The default calendar wins when it is ticked.
    private static func writableCalendar() -> EKCalendar? {
        let allowed = Settings.calendarsForEventQuery(store: store) ?? store.calendars(for: .event)
        let ids = Set(allowed.map(\.calendarIdentifier))
        if let calendar = store.defaultCalendarForNewEvents,
           calendar.allowsContentModifications,
           ids.contains(calendar.calendarIdentifier) {
            return calendar
        }
        return allowed.first { $0.allowsContentModifications }
    }

    private static func canRead(_ status: EKAuthorizationStatus) -> Bool {
        if status == .fullAccess { return true }
        return false
    }

    private static func canWrite(_ status: EKAuthorizationStatus) -> Bool {
        status == .fullAccess || status == .writeOnly
    }

    private static func statusLabel(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "not determined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .fullAccess: return "full access"
        case .writeOnly: return "write only"
        @unknown default: return "unknown"
        }
    }

    static func clean(_ raw: String?) -> String? {
        let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    private static func fail(_ action: PendingAction, _ message: String) -> PendingAction {
        var copy = action
        copy.phase = .failed
        copy.resultText = message
        return copy
    }
}
