@preconcurrency import AppKit
import SwiftUI

struct LogTextView: NSViewRepresentable {
    var events: [LogEvent]
    var query: String
    var enabledSources: Set<LogSource>
    @Binding var followTail: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = false
        scroll.borderType = .noBorder
        scroll.contentView.postsBoundsChangedNotifications = true

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.usesFindBar = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.backgroundColor = NSColor.textBackgroundColor

        scroll.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.followTail = $followTail
        context.coordinator.observe(scrollView: scroll)
        context.coordinator.render(
            events: events,
            query: query,
            enabledSources: enabledSources,
            followTail: followTail
        )
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.followTail = $followTail
        context.coordinator.render(
            events: events,
            query: query,
            enabledSources: enabledSources,
            followTail: followTail
        )
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        weak var textView: NSTextView?
        var followTail: Binding<Bool>?
        private var lastRenderedSignature = ""
        private var scrollObserver: NSObjectProtocol?
        private var programmaticScroll = false

        deinit {
            if let scrollObserver {
                NotificationCenter.default.removeObserver(scrollObserver)
            }
        }

        func observe(scrollView: NSScrollView) {
            guard scrollObserver == nil else { return }
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self, weak scrollView] _ in
                Task { @MainActor in
                    guard let self, let scrollView else { return }
                    self.handleScroll(scrollView)
                }
            }
        }

        func render(
            events: [LogEvent],
            query: String,
            enabledSources: Set<LogSource>,
            followTail: Bool
        ) {
            guard let textView else { return }
            let filtered = events.filter { event in
                enabledSources.contains(event.source)
                    && (query.isEmpty || event.rawLine.localizedCaseInsensitiveContains(query))
            }
            let signature = "\(filtered.count)|\(events.last?.id.uuidString ?? "")|\(query)|\(enabledSources.map(\.rawValue).sorted().joined(separator: ","))"
            guard signature != lastRenderedSignature else { return }
            lastRenderedSignature = signature

            let text = NSMutableAttributedString()
            for event in filtered {
                let line = NSMutableAttributedString(
                    string: event.rawLine + "\n",
                    attributes: attributes(for: event)
                )
                if !query.isEmpty {
                    highlight(query: query, in: line)
                }
                text.append(line)
            }
            textView.textStorage?.setAttributedString(text)
            if followTail {
                programmaticScroll = true
                textView.scrollToEndOfDocument(nil)
                programmaticScroll = false
            }
        }

        private func handleScroll(_ scrollView: NSScrollView) {
            guard !programmaticScroll, followTail?.wrappedValue == true else { return }
            let visible = scrollView.contentView.bounds
            let docHeight = scrollView.documentView?.bounds.height ?? 0
            // If the user is more than roughly two text lines away from the
            // bottom, stop auto-following. They can re-enable via the toggle.
            let distanceFromBottom = docHeight - visible.maxY
            if distanceFromBottom > 32 {
                followTail?.wrappedValue = false
            }
        }

        private func attributes(for event: LogEvent) -> [NSAttributedString.Key: Any] {
            let color: NSColor
            switch event.level {
            case .error:
                color = .systemRed
            case .warning:
                color = .systemOrange
            case .debug:
                color = .secondaryLabelColor
            case .info, nil:
                switch event.source {
                case .progress:
                    color = .systemBlue
                case .state:
                    color = .systemPurple
                case .buildx:
                    color = .systemGreen
                case .supervisor:
                    color = .secondaryLabelColor
                case .buildkitd:
                    color = .labelColor
                }
            }
            return [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: color,
            ]
        }

        private func highlight(query: String, in line: NSMutableAttributedString) {
            let haystack = line.string.lowercased()
            let needle = query.lowercased()
            guard !needle.isEmpty else { return }
            var searchRange = haystack.startIndex..<haystack.endIndex
            while let range = haystack.range(of: needle, range: searchRange) {
                let nsRange = NSRange(range, in: haystack)
                line.addAttributes([
                    .backgroundColor: NSColor.systemYellow.withAlphaComponent(0.35),
                    .foregroundColor: NSColor.labelColor,
                ], range: nsRange)
                searchRange = range.upperBound..<haystack.endIndex
            }
        }
    }
}
