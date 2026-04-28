import SwiftUI

struct LogsWindowView: View {
    @ObservedObject var store: LogStore

    @State private var query = ""
    @State private var enabledSources = Set(LogSource.allCases)
    @State private var followTail = true

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(8)
            Divider()
            LogTextView(
                events: store.events,
                query: query,
                enabledSources: enabledSources,
                followTail: followTail
            )
        }
        .frame(minWidth: 900, minHeight: 520)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            TextField("Search logs", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 220, maxWidth: 320)

            Toggle("Follow", isOn: $followTail)
                .toggleStyle(.checkbox)

            Menu("Sources") {
                ForEach(LogSource.allCases) { source in
                    Toggle(source.rawValue, isOn: binding(for: source))
                }
            }

            Spacer()

            Text("\(visibleCount) / \(store.events.count) lines")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Copy Visible") {
                copyVisibleLogs()
            }

            Button("Clear") {
                store.clear()
            }
        }
    }

    private var visibleCount: Int {
        store.events.filter { event in
            enabledSources.contains(event.source)
                && (query.isEmpty || event.rawLine.localizedCaseInsensitiveContains(query))
        }.count
    }

    private func binding(for source: LogSource) -> Binding<Bool> {
        Binding {
            enabledSources.contains(source)
        } set: { enabled in
            if enabled {
                enabledSources.insert(source)
            } else {
                enabledSources.remove(source)
            }
        }
    }

    private func copyVisibleLogs() {
        let text = store.events
            .filter { event in
                enabledSources.contains(event.source)
                    && (query.isEmpty || event.rawLine.localizedCaseInsensitiveContains(query))
            }
            .map(\.rawLine)
            .joined(separator: "\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
