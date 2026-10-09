import AppKit
import KinhinKit
import Observation
import SwiftUI

/// Match against level, component, or message — case-insensitive.
struct LogEntryFilter {
    var query: String = ""
    var minLevel: Log.Level = .debug

    func matches(_ entry: Log.Entry) -> Bool {
        guard let level = Log.Level(rawValue: entry.level), level >= minLevel else { return false }
        guard !query.isEmpty else { return true }
        return entry.message.localizedCaseInsensitiveContains(query)
            || entry.component.localizedCaseInsensitiveContains(query)
            || entry.level.localizedCaseInsensitiveContains(query)
    }
}

/// Toolbar (search, level, follow, line count) over the log text.
struct LogsView: View {
    @Bindable var model: LogsModel

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                TextField("Search logs (message, component, level)", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search logs")
                Picker("Level", selection: $model.minLevel) {
                    ForEach(LogsModel.levels, id: \.level) { item in
                        Text(item.title).tag(item.level)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Filter by log level")
                Toggle("Follow", isOn: $model.follow)
                    .font(.system(size: 12))
                Text(model.statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            LogTextView(
                text: model.text, appended: model.appended, revision: model.revision,
                rebuildRevision: model.rebuildRevision, searchRevision: model.searchRevision,
                follow: model.follow
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
        }
    }
}

/// The log body: a read-only `NSTextView`. SwiftUI `Text`/`List` stays slow
/// at ring-buffer size and loses text selection and Find, so this stays
/// AppKit.
private struct LogTextView: NSViewRepresentable {
    let text: NSAttributedString
    /// What the last change appended (valid while `rebuildRevision` holds).
    let appended: NSAttributedString
    let revision: Int
    let rebuildRevision: Int
    let searchRevision: Int
    let follow: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isRichText = false
        textView.autoresizingMask = [.width]
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.usesFindBar = true
        textView.setAccessibilityLabel(
            String(localized: "Log output", bundle: .l10n, comment: "VoiceOver label of the log text area"))

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = textView
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        guard let textView = coordinator.textView, let storage = textView.textStorage else { return }

        if coordinator.revision != revision {
            let wasAtBottom = coordinator.isAtBottom(scroll)
            let grew = text.length > coordinator.length
            // A pure append (the model's very next revision, same base text)
            // only adds the new lines; anything else reloads the whole text.
            if coordinator.rebuildRevision == rebuildRevision, coordinator.revision == revision - 1,
                storage.length == coordinator.length
            {
                storage.append(appended)
            } else {
                storage.setAttributedString(text)
            }
            let searched = coordinator.searchRevision != searchRevision
            if searched || (follow && (grew || wasAtBottom)) {
                coordinator.scrollToBottom(scroll)
            }
            coordinator.revision = revision
            coordinator.rebuildRevision = rebuildRevision
            coordinator.searchRevision = searchRevision
            coordinator.length = text.length
        } else if follow, !coordinator.follow {
            coordinator.scrollToBottom(scroll)
        }
        coordinator.follow = follow
    }

    @MainActor
    final class Coordinator {
        weak var textView: NSTextView?
        var revision = -1
        var rebuildRevision = -1
        var searchRevision = 0
        var length = 0
        var follow = true

        /// Within a few lines of the end counts as "at the bottom", so a
        /// user who scrolled up to read is not yanked back down.
        func isAtBottom(_ scroll: NSScrollView) -> Bool {
            guard let textView else { return false }
            return NSMaxY(textView.bounds) <= NSMaxY(scroll.contentView.bounds) + 40
        }

        func scrollToBottom(_ scroll: NSScrollView) {
            guard let document = scroll.documentView else { return }
            document.scroll(NSPoint(x: 0, y: max(0, document.bounds.height - 10)))
        }
    }
}
