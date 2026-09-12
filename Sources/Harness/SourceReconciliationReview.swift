import AppKit

/// Native review for Source reconciliation. Confirmed matches are informational;
/// probable moves require an explicit checkbox before identity is transferred.
enum SourceReconciliationReview {
    private static let maxMoveControls = 64

    @MainActor
    static func choose(diff: SceneLibraryStore.ReconciliationDiff, sourceName: String,
                       window: NSWindow) async -> Set<String>? {
        let summary = diff.summary
        let alert = NSAlert()
        alert.messageText = "Review \(sourceName) Rescan"
        var lines = [
            "Added: \(summary.added)",
            "Missing: \(summary.missing)",
            "Changed: \(summary.changed)",
            "Moved: \(summary.moved)",
            "Restored: \(summary.restored)",
            "Unchanged: \(summary.unchanged)"
        ]
        if summary.probableMoves > 0 {
            lines.append("Probable moves for review: \(summary.probableMoves)")
        }
        alert.informativeText = lines.joined(separator: " · ")
            + "\n\nApply updates the Library catalog once. Source files stay untouched."
        alert.addButton(withTitle: "Apply Reconciliation")
        alert.addButton(withTitle: "Cancel")

        var controls: [(NSButton, SceneLibraryStore.ProbableMove)] = []
        let displayed = Array(diff.probableMoves.prefix(maxMoveControls))
        if !displayed.isEmpty {
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 7
            let intro = NSTextField(wrappingLabelWithString:
                "Confirm only moves you recognize. Unchecked candidates stay as a missing old entry plus a new entry.")
            intro.preferredMaxLayoutWidth = 520
            stack.addArrangedSubview(intro)
            for move in displayed {
                let button = NSButton(checkboxWithTitle: "\(move.fromPath) → \(move.toPath)", target: nil, action: nil)
                button.state = .off
                button.toolTip = move.evidence
                stack.addArrangedSubview(button)
                if !move.evidence.isEmpty {
                    let evidence = NSTextField(labelWithString: "    \(move.evidence)")
                    evidence.textColor = .secondaryLabelColor
                    evidence.font = .systemFont(ofSize: 11)
                    stack.addArrangedSubview(evidence)
                }
                controls.append((button, move))
            }
            if diff.probableMoves.count > displayed.count {
                let overflow = NSTextField(wrappingLabelWithString:
                    "\(diff.probableMoves.count - displayed.count) additional probable moves stay separate in this pass to keep review bounded.")
                overflow.textColor = .secondaryLabelColor
                overflow.preferredMaxLayoutWidth = 520
                stack.addArrangedSubview(overflow)
            }
            stack.frame = NSRect(origin: .zero, size: NSSize(width: 540, height: max(1, stack.fittingSize.height)))
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560,
                height: min(320, max(100, stack.frame.height))))
            scroll.hasVerticalScroller = stack.frame.height > scroll.frame.height
            scroll.hasHorizontalScroller = false
            scroll.autohidesScrollers = true
            scroll.drawsBackground = false
            scroll.documentView = stack
            alert.accessoryView = scroll
        }

        let response = await alert.beginSheetModal(for: window)
        guard response == .alertFirstButtonReturn else { return nil }
        return Set(controls.compactMap { button, move in
            guard button.state == .on else { return nil }
            return SceneLibraryStore.ReconciliationDiff.moveKey(entryID: move.entryID, scannedIndex: move.scannedIndex)
        })
    }
}
