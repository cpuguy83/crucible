import SwiftUI

struct LogsWindowView: View {
    @ObservedObject var store: LogStore

    @State private var query = ""
    @State private var enabledSources = Set(LogSource.allCases)
    @State private var followTail = true
    @State private var paused = false
    @State private var frozenEvents: [LogEvent] = []
    @FocusState private var searchFocused: Bool

    private var displayedEvents: [LogEvent] {
        paused ? frozenEvents : store.events
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(8)
            Divider()
            LogTextView(
                events: displayedEvents,
                query: query,
                enabledSources: enabledSources,
                followTail: followTail
            )
        }
        .frame(minWidth: 900, minHeight: 520)
        .onChange(of: paused) { _, newValue in
            if newValue {
                frozenEvents = store.events
            } else {
                frozenEvents.removeAll(keepingCapacity: true)
            }
        }
        .onKeyPress("f", phases: .down) { event in
            guard event.modifiers.contains(.command) else { return .ignored }
            searchFocused = true
            return .handled
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            TextField("Search logs", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .frame(minWidth: 220, maxWidth: 320)

            Button(paused ? "Resume" : "Pause") {
                paused.toggle()
            }

            Toggle("Follow", isOn: $followTail)
                .toggleStyle(.checkbox)
                .disabled(paused)

            Menu("Sources") {
                ForEach(LogSource.allCases) { source in
                    Toggle(source.rawValue, isOn: binding(for: source))
                }
            }

            Spacer()

            Text("\(visibleCount) / \(displayedEvents.count) lines" + (paused ? " (paused)" : ""))
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
        displayedEvents.filter { event in
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
        let text = displayedEvents
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
