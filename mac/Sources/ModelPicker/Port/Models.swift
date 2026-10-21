import Foundation

struct ChatMessage: Identifiable, Equatable {
    enum Role: String, Equatable {
        case user
        case assistant
    }

    let id: UUID
    var role: Role
    var text: String
    /// Tool names shown as small chips. Empty for ordinary prose.
    var toolNames: [String]
    /// Absolute paths from search_files, drawn as Open / Reveal rows.
    var filePaths: [String]
    /// A file change waiting for Approve. Nil for ordinary messages.
    var pending: PendingAction?

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        toolNames: [String] = [],
        filePaths: [String] = [],
        pending: PendingAction? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.toolNames = toolNames
        self.filePaths = filePaths
        self.pending = pending
    }
}
