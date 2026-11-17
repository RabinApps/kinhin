import SwiftUI

/// The frame every sheet shares: a 17-point title, the body, and a footer of buttons, on the surface color with 20
/// points of padding. The footers below keep Done / Close / Cancel consistent: the affirmative button is the default
/// action (Return), Cancel and Close answer Escape.
struct SheetScaffold<Content: View, Footer: View>: View {
    let title: Text
    var width: CGFloat?
    let content: Content
    let footer: Footer

    init(
        title: LocalizedStringKey, width: CGFloat? = 480, @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.title = Text(title)
        self.width = width
        self.content = content()
        self.footer = footer()
    }

    /// A title a model already localized.
    init(
        verbatimTitle title: String, width: CGFloat? = 480, @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.title = Text(verbatim: title)
        self.width = width
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md + 2) {
            title
                .typeStyle(.title)
                .accessibilityAddTraits(.isHeader)
            content
            footer
        }
        .padding(Spacing.xl)
        .frame(width: width, alignment: .leading)
        .background(Palette.surface)
    }
}

/// The footer of a sheet you can only dismiss: one Done button on the trailing edge (Return and Escape both close).
struct SheetDoneFooter: View {
    let done: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button("Done", action: done)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("sheet-done")
        }
    }
}

/// The footer of a sheet that only reports (a pipeline, a log): Close, on the trailing edge, with optional leading
/// accessories (a back button, "Open in browser").
struct SheetCloseFooter<Leading: View>: View {
    let close: () -> Void
    @ViewBuilder var leading: Leading

    var body: some View {
        HStack {
            leading
            Spacer()
            Button("Close", action: close)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("sheet-close")
        }
    }
}

extension SheetCloseFooter where Leading == EmptyView {
    init(close: @escaping () -> Void) {
        self.init(close: close) { EmptyView() }
    }
}

/// The footer of a sheet that changes something: Cancel (Escape) and a confirming button (Return) such as Save, Add
/// or Install, with optional leading accessories (Copy Command).
struct SheetConfirmFooter<Leading: View>: View {
    let confirmTitle: Text
    var canConfirm = true
    let confirm: () -> Void
    let cancel: () -> Void
    @ViewBuilder var leading: Leading

    init(
        _ confirmTitle: LocalizedStringKey, canConfirm: Bool = true, confirm: @escaping () -> Void,
        cancel: @escaping () -> Void, @ViewBuilder leading: () -> Leading
    ) {
        self.confirmTitle = Text(confirmTitle)
        self.canConfirm = canConfirm
        self.confirm = confirm
        self.cancel = cancel
        self.leading = leading()
    }

    var body: some View {
        HStack {
            leading
            Spacer()
            Button("Cancel", action: cancel)
                .keyboardShortcut(.cancelAction)
            Button(action: confirm) { confirmTitle }
                .keyboardShortcut(.defaultAction)
                .disabled(!canConfirm)
        }
    }
}

extension SheetConfirmFooter where Leading == EmptyView {
    init(
        _ confirmTitle: LocalizedStringKey, canConfirm: Bool = true, confirm: @escaping () -> Void,
        cancel: @escaping () -> Void
    ) {
        self.init(confirmTitle, canConfirm: canConfirm, confirm: confirm, cancel: cancel) { EmptyView() }
    }
}

#Preview("Sheet: done") {
    SheetScaffold(title: "Support kinhin") {
        Text(verbatim: "kinhin is free and built by one developer.").typeStyle(.caption).foregroundStyle(.secondary)
    } footer: {
        SheetDoneFooter {}
    }
}

#Preview("Sheet: confirm") {
    SheetScaffold(title: "Test a workflow", width: 420) {
        Text(verbatim: "Send a repository, or one workflow, to a runtime.").typeStyle(.caption)
            .foregroundStyle(.secondary)
    } footer: {
        SheetConfirmFooter("Add", canConfirm: false, confirm: {}, cancel: {})
    }
}
