import SwiftUI

/// The Tools pane: the entry points to the Test Workflow and Make a Video sheets.
struct ToolsPane: View {
    let testWorkflow: () -> Void
    let makeVideo: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Card(
                title: "Test a workflow", subtitle: "Run a workflow file locally before pushing", layout: .fill
            ) {
                HStack {
                    Button("Choose Workflow File…", action: testWorkflow)
                        .accessibilityIdentifier("open-workflow-test")
                    Spacer(minLength: Spacing.md)
                }
            }
            Card(title: "Make a video", subtitle: "Launch videos built in a container", layout: .fill) {
                HStack(spacing: Spacing.md) {
                    Button("Make a Video…", action: makeVideo)
                        .accessibilityIdentifier("open-videos")
                    Spacer(minLength: Spacing.md)
                    HintText("Builds download the video image on first run.")
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

#Preview("Tools pane") {
    ToolsPane(testWorkflow: {}, makeVideo: {})
        .padding(Spacing.lg)
        .frame(width: 560, height: 300)
}
