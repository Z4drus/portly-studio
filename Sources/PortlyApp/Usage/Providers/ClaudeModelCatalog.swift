import Foundation

/// Claude's model names, newest first, from `GET /v1/models`.
///
/// The usage endpoint names a model-capped window by family alone ("Fable").
/// The list says which version that family is at, so the window reads
/// "Fable 5.1", and "Fable 5.2" the day it ships, with no release of Portly.
struct ClaudeModelCatalog: Codable, Equatable {
    struct Model: Codable, Equatable {
        let id: String
        /// The display name without "Claude ": "Fable 5.1".
        let name: String
    }

    var models: [Model]

    static let empty = ClaudeModelCatalog(models: [])

    /// The newest model of a family: "Fable" becomes "Fable 5.1". Anything
    /// that is not a family the list knows comes back as it was.
    func versioned(_ family: String) -> String {
        let wanted = family.trimmingCharacters(in: .whitespaces).lowercased()
        guard !wanted.isEmpty else { return family }
        let newest = models.first { model in
            let name = model.name.lowercased()
            return name == wanted || name.hasPrefix(wanted + " ")
        }
        return newest?.name ?? family
    }

    /// The label for a window scoped to one model: by its id when the
    /// endpoint gives one, otherwise by its family.
    func name(id: String?, family: String?) -> String? {
        if let id, let model = models.first(where: { $0.id == id }) { return model.name }
        guard let family, !family.isEmpty else { return nil }
        return versioned(family)
    }

    /// Reads `/v1/models`, whose rows carry `id`, `display_name` and
    /// `created_at`. Newest first, whatever order the page comes in.
    static func decode(_ data: Data) -> ClaudeModelCatalog? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["data"] as? [[String: Any]]
        else { return nil }
        let dated = rows.compactMap { row -> (model: Model, created: String)? in
            guard let id = row["id"] as? String, let display = row["display_name"] as? String else { return nil }
            let name = display.hasPrefix("Claude ") ? String(display.dropFirst("Claude ".count)) : display
            return (Model(id: id, name: name), row["created_at"] as? String ?? "")
        }
        // ISO 8601 timestamps in UTC sort as text.
        let newestFirst = dated.enumerated().sorted { lhs, rhs in
            lhs.element.created == rhs.element.created
                ? lhs.offset < rhs.offset
                : lhs.element.created > rhs.element.created
        }
        return ClaudeModelCatalog(models: newestFirst.map(\.element.model))
    }
}
