import Foundation

enum ToolTimelineItem: Identifiable {
    case activity(AppModel.RunActivity)
    case message(AppModel.ChatMessage)
    case tools([AppModel.RunActivity])

    var id: String {
        switch self {
        case .activity(let activity): activity.id
        case .message(let message): "message:\(message.id.uuidString)"
        case .tools(let activities): activities[0].id
        }
    }

    static func grouped(_ items: [Self]) -> [Self] {
        var result: [Self] = []
        var pending: [AppModel.RunActivity] = []
        func flush() {
            if !pending.isEmpty {
                result.append(.tools(pending))
                pending.removeAll()
            }
        }
        for item in items {
            if case .activity(let activity) = item, activity.kind == .tool {
                if let first = pending.first, first.sourceRunId != activity.sourceRunId { flush() }
                pending.append(activity)
            } else {
                flush()
                result.append(item)
            }
        }
        flush()
        return result
    }
}

struct ToolActivitySummary {
    let activities: [AppModel.RunActivity]

    var title: String {
        if activities.contains(where: { $0.toolState == .running || $0.toolState == .awaitingApproval }) {
            return "Working with \(activities.count) \(activities.count == 1 ? "tool" : "tools")…"
        }

        let completed = activities.filter { $0.toolState == .succeeded || $0.toolState == nil }
        let names = completed.map { $0.toolName ?? "" }
        var clauses: [(index: Int, text: String)] = []
        func count(_ name: String) -> Int { names.filter { $0 == name }.count }
        func noun(_ n: Int, _ singular: String, _ plural: String) -> String {
            "\(n) \(n == 1 ? singular : plural)"
        }
        func add(_ name: String, _ text: String) {
            clauses.append((names.firstIndex(of: name) ?? 0, text))
        }

        let searches = count("web_search")
        if searches > 0 { add("web_search", searches == 1 ? "searched the web" : "searched the web \(searches) times") }
        let pages = count("read_web_page") + count("fetch_page")
        if pages > 0 {
            let hosts = completed.filter { $0.toolName == "read_web_page" || $0.toolName == "fetch_page" }
                .compactMap { activity -> String? in
                    let input = activity.input?.objectValue
                    let captured = input?["preview"]?.objectValue ?? input
                    guard let url = captured?["url"]?.stringValue, let host = URL(string: url)?.host else { return nil }
                    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
                }
            let suffix = hosts.count == pages && Set(hosts).count == 1 ? " from \(hosts[0])" : ""
            add(names.first { $0 == "read_web_page" || $0 == "fetch_page" } ?? "read_web_page",
                "fetched \(noun(pages, "page", "pages"))\(suffix)")
        }
        let fileSearches = count("search_files")
        if fileSearches > 0 { add("search_files", fileSearches == 1 ? "searched files" : "searched files \(fileSearches) times") }
        for (name, verb, singular, plural) in [
            ("list_directory", "listed", "folder", "folders"),
            ("read_file", "read", "file", "files"),
            ("write_file", "wrote", "file", "files"),
            ("edit_file", "edited", "file", "files")
        ] {
            let matching = completed.filter { $0.toolName == name }
            guard !matching.isEmpty else { continue }
            // A repeated write/edit to one path is one affected file, not two files.
            let paths = matching.compactMap { activity -> String? in
                let input = activity.input?.objectValue
                let captured = input?["preview"]?.objectValue ?? input
                return captured?["path"]?.stringValue
            }
            let number = paths.count == matching.count ? Set(paths).count : matching.count
            add(name, "\(verb) \(noun(number, singular, plural))")
        }
        let commands = count("shell_exec")
        if commands > 0 { add("shell_exec", "ran \(noun(commands, "command", "commands"))") }
        let known: Set<String> = ["web_search", "read_web_page", "fetch_page", "search_files",
                                  "list_directory", "read_file", "write_file", "edit_file", "shell_exec"]
        let other = names.filter { !known.contains($0) }.count
        if other > 0 {
            clauses.append((names.firstIndex(where: { !known.contains($0) }) ?? 0,
                            "used \(noun(other, "other tool", "other tools"))"))
        }

        guard !clauses.isEmpty else { return "Tool activity" }
        let ordered = clauses.sorted { $0.index < $1.index }.map { $0.text }
        let text: String
        if ordered.count == 1 { text = ordered[0] }
        else if ordered.count == 2 { text = ordered.joined(separator: " and ") }
        else if ordered.count == 3 { text = ordered.dropLast().joined(separator: ", ") + ", and " + ordered[2] }
        else { text = ordered.prefix(2).joined(separator: ", ") + ", and \(ordered.count - 2) more actions" }
        return text.prefix(1).uppercased() + String(text.dropFirst())
    }

    var stateLabel: String {
        if activities.contains(where: { $0.toolState == .awaitingApproval }) { return "Approval" }
        if activities.contains(where: { $0.toolState == .running }) { return "Running" }
        let failed = activities.filter { $0.toolState == .failed }.count
        if failed > 0 { return "\(failed) failed" }
        if activities.allSatisfy({ $0.toolState == .skipped }) { return "Skipped" }
        let skipped = activities.filter { $0.toolState == .skipped }.count
        if skipped > 0 { return "\(skipped) skipped" }
        return "Done"
    }
}
