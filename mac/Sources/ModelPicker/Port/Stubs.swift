import Foundation
import EventKit

struct ToolDefinition { var name: String; var description: String; var parameters: [String: Any] }
struct ToolOutcome {
    var text: String
    var pending: PendingAction?
    static func text(_ t: String) -> ToolOutcome { ToolOutcome(text: t, pending: nil) }
}

/// Calendar choices only (engine and model are picked in the Model Picker window itself).
@MainActor
final class Settings {
    static let shared = Settings()
    private static let enabledKey = "modelpicker.enabledCalendarIDs"
    private static let knownKey = "modelpicker.knownCalendarIDs"
    private let d = UserDefaults.standard
    var enabled: [String]? { d.object(forKey: Self.enabledKey) == nil ? nil : (d.stringArray(forKey: Self.enabledKey) ?? []) }
    func isCalendarEnabled(_ id: String) -> Bool { guard let e = enabled else { return true }; return e.contains(id) }
    func setCalendarEnabled(_ id: String, isOn: Bool, allIdentifiers: [String]) {
        var set: Set<String>
        if let e = enabled { set = Set(e) } else { set = Set(allIdentifiers); d.set(Array(Set(allIdentifiers)).sorted(), forKey: Self.knownKey) }
        if isOn { set.insert(id) } else { set.remove(id) }
        d.set(Array(set).sorted(), forKey: Self.enabledKey)
    }
    func mergeNewCalendars(_ ids: [String]) {
        guard enabled != nil else { d.set(Array(Set(ids)).sorted(), forKey: Self.knownKey); return }
        let known = Set(d.stringArray(forKey: Self.knownKey) ?? [])
        let newcomers = Set(ids).subtracting(known)
        if !newcomers.isEmpty { var en = Set(enabled ?? []); en.formUnion(newcomers); d.set(Array(en).sorted(), forKey: Self.enabledKey) }
        d.set(Array(known.union(ids)).sorted(), forKey: Self.knownKey)
    }
    static func calendarsForEventQuery(store: EKEventStore, defaults: UserDefaults = .standard) -> [EKCalendar]? {
        guard defaults.object(forKey: enabledKey) != nil else { return nil }
        let enabled = Set(defaults.stringArray(forKey: enabledKey) ?? [])
        let known = Set(defaults.stringArray(forKey: knownKey) ?? [])
        return store.calendars(for: .event).filter { enabled.contains($0.calendarIdentifier) || !known.contains($0.calendarIdentifier) }
    }
}
