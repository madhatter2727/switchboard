import Foundation

/// Parses event times and turns create_calendar_event into a PendingAction.
enum CalendarWhen {
    struct Parsed {
        var date: Date
        var allDay: Bool
    }

    static let unreadable = "I couldn't read the start or end. Use ISO 8601, like 2026-10-14T15:00:00."

    static func parse(_ raw: String) -> Parsed? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        if let parsed = iso(text) { return parsed }
        if let parsed = format(text, patterns: timed, allDay: false) { return parsed }
        return format(text, patterns: days, allDay: true)
    }

    /// All-day end is exclusive. Equal all-day dates mean one day.
    static func bounds(_ start: Parsed, _ end: Parsed) -> (start: Date, end: Date, allDay: Bool)? {
        let calendar = Calendar.current
        if start.allDay && end.allDay {
            let first = calendar.startOfDay(for: start.date)
            var last = calendar.startOfDay(for: end.date)
            if last <= first {
                guard let next = calendar.date(byAdding: .day, value: 1, to: first) else { return nil }
                last = next
            }
            return (first, last, true)
        }
        guard end.date > start.date else { return nil }
        return (start.date, end.date, false)
    }

    static func phrase(start: Date, end: Date, allDay: Bool) -> String {
        if allDay {
            let last = Calendar.current.date(byAdding: .second, value: -1, to: end) ?? start
            if Calendar.current.isDate(start, inSameDayAs: last) {
                return "all day \(start.formatted(date: .complete, time: .omitted))"
            }
            let left = start.formatted(date: .abbreviated, time: .omitted)
            let right = last.formatted(date: .abbreviated, time: .omitted)
            return "all day \(left) – \(right)"
        }
        if Calendar.current.isDate(start, inSameDayAs: end) {
            let day = start.formatted(date: .complete, time: .omitted)
            let left = start.formatted(date: .omitted, time: .shortened)
            let right = end.formatted(date: .omitted, time: .shortened)
            return "\(day), \(left)–\(right)"
        }
        let left = start.formatted(date: .abbreviated, time: .shortened)
        let right = end.formatted(date: .abbreviated, time: .shortened)
        return "\(left) – \(right)"
    }

    private static let timed = [
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd'T'HH:mm",
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd HH:mm",
        "yyyy-MM-dd h:mm a",
        "M/d/yyyy h:mm a",
        "M/d/yyyy HH:mm",
        "MMMM d, yyyy h:mm a",
        "MMMM d yyyy h:mm a",
        "MMM d, yyyy h:mm a"
    ]

    private static let days = [
        "yyyy-MM-dd",
        "M/d/yyyy",
        "MMMM d, yyyy",
        "MMMM d yyyy",
        "MMM d, yyyy"
    ]

    private static func iso(_ text: String) -> Parsed? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return Parsed(date: date, allDay: false) }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return Parsed(date: date, allDay: false) }
        formatter.formatOptions = [.withFullDate]
        if text.count <= 10, let date = formatter.date(from: text) { return Parsed(date: date, allDay: true) }
        return nil
    }

    private static func format(_ text: String, patterns: [String], allDay: Bool) -> Parsed? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for pattern in patterns {
            formatter.dateFormat = pattern
            if let date = formatter.date(from: text) {
                return Parsed(date: date, allDay: allDay)
            }
        }
        return nil
    }
}

@MainActor
extension CalendarTools {
    // The registry reads these off the main actor. They do not touch EventKit.
    nonisolated static var names: Set<String> {
        ["calendar_events", "reminders", "create_calendar_event"]
    }

    nonisolated static var definitions: [ToolDefinition] {
        [
            tool(
                "calendar_events",
                "List calendar events from start until end. Read-only. Times are ISO 8601 local, like 2026-10-14T00:00:00. Date-only values are all-day and end is exclusive.",
                [
                    "start": prop("string", "Range start, ISO 8601."),
                    "end": prop("string", "Range end, ISO 8601, not included.")
                ],
                ["start", "end"]
            ),
            tool(
                "reminders",
                "List reminders that are not completed. Read-only.",
                ["incomplete": prop("boolean", "Pass true. This tool only lists incomplete reminders.")],
                []
            ),
            tool(
                "create_calendar_event",
                "Prepare a new calendar event. Does not add it until the user approves the card.",
                [
                    "title": prop("string", "Event title."),
                    "start": prop("string", "Start, ISO 8601 local time, like 2026-10-14T15:00:00."),
                    "end": prop("string", "End, ISO 8601 local time.")
                ],
                ["title", "start", "end"]
            )
        ]
    }

    static func perform(name: String, arguments: String) async -> ToolOutcome {
        let args = object(from: arguments)
        switch name {
        case "calendar_events":
            let start = firstString(args, ["start", "from", "start_time"]) ?? ""
            let end = firstString(args, ["end", "to", "end_time"]) ?? ""
            return .text(await events(from: start, to: end))
        case "reminders":
            return .text(await reminders())
        case "create_calendar_event":
            let action = await ActionCenter.planCalendarEvent(
                title: firstString(args, ["title", "name", "summary"]) ?? "",
                start: firstString(args, ["start", "start_time"]) ?? "",
                end: firstString(args, ["end", "end_time"]) ?? ""
            )
            guard action.phase == .pending else { return .text(action.previewText) }
            let note = action.previewText + "\nWaiting for approval. Nothing has been added."
            return ToolOutcome(text: note, pending: action)
        default:
            return .text("Unknown tool \(name).")
        }
    }

    static func planEvent(title: String, start: String, end: String) async -> PendingAction {
        let name = title
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return .failed(kind: .calendarEvent, summary: "The event needs a title.")
        }
        guard let startWhen = CalendarWhen.parse(start), let endWhen = CalendarWhen.parse(end) else {
            return .failed(kind: .calendarEvent, summary: CalendarWhen.unreadable)
        }
        guard let bounds = CalendarWhen.bounds(startWhen, endWhen) else {
            return .failed(kind: .calendarEvent, summary: "The end time has to be after the start.")
        }
        guard await ensureWrite() else {
            return .failed(kind: .calendarEvent, summary: denialEvents)
        }
        guard let calendarTitle = newEventCalendarTitle() else {
            return .failed(kind: .calendarEvent, summary: noWritableCalendar)
        }
        let when = CalendarWhen.phrase(start: bounds.start, end: bounds.end, allDay: bounds.allDay)
        return PendingAction(
            id: UUID(),
            kind: .calendarEvent,
            title: "Add “\(name)”",
            summary: "Add “\(name)” to \(calendarTitle), \(when). Nothing is added until you approve.",
            transfers: [PendingAction.Transfer(source: name, destination: when)],
            warnings: [],
            phase: .pending,
            resultText: nil,
            undoID: nil,
            ensureFolder: nil,
            eventTitle: name,
            eventStart: bounds.start,
            eventEnd: bounds.end,
            eventAllDay: bounds.allDay
        )
    }

    nonisolated private static func tool(
        _ name: String,
        _ description: String,
        _ properties: [String: Any],
        _ required: [String]
    ) -> ToolDefinition {
        ToolDefinition(
            name: name,
            description: description,
            parameters: [
                "type": "object",
                "properties": properties,
                "required": required
            ]
        )
    }

    nonisolated private static func prop(_ type: String, _ description: String) -> [String: Any] {
        ["type": type, "description": description]
    }

    private static func object(from arguments: String) -> [String: Any] {
        guard let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return json
    }

    private static func firstString(_ json: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            guard let text = json[key] as? String else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}

extension ActionCenter {
    static func planCalendarEvent(title: String, start: String, end: String) async -> PendingAction {
        await CalendarTools.planEvent(title: title, start: start, end: end)
    }

    static func saveCalendarEvent(_ action: PendingAction) -> PendingAction {
        CalendarTools.save(action)
    }
}
