import AppKit
import SwiftUI

/// Widths that make up the main window. The window's minimum width is derived from them so a form card is never
/// clipped, even with the sidebar open.
enum ShellLayout {
    static let sidebarExpanded: CGFloat = 200
    /// The icon rail the sidebar folds to (Cmd-Opt-S).
    static let sidebarCollapsed: CGFloat = 52
    /// Height of a sidebar row.
    static let rowHeight: CGFloat = 28
    /// Space the traffic lights take at the top of the window (the content runs under the transparent title bar).
    static let titlebarClearance: CGFloat = 40
    /// The widest a page's content column grows; the existing forms are laid out for `FormMetrics.width`.
    static let contentMaxWidth: CGFloat = FormMetrics.width + 24 + 2 * Spacing.page
    /// Narrowest window that shows the expanded sidebar and a whole form column.
    static let minWindowWidth: CGFloat = sidebarExpanded + 1 + contentMaxWidth
    static let defaultWindowSize = CGSize(width: 1000, height: 680)
}

/// The window's sidebar: the six sections, then the footer with the update badge (only when Sparkle found a newer
/// release) and "Support kinhin". Folds to an icon rail with Cmd-Opt-S. Hidden while first-run setup gates the window.
struct SidebarView: View {
    let model: MainTabsModel

    private var collapsed: Bool { model.sidebarCollapsed }
    private var pendingUpdate: String? { model.models.updates.pendingVersion }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            header
            ForEach(model.visibleSections, id: \.self) { section in
                row(section)
            }
            Spacer(minLength: Spacing.md)
            footer
        }
        .padding(.horizontal, Spacing.md)
        .padding(.bottom, Spacing.md)
        .padding(.top, ShellLayout.titlebarClearance)
        .frame(width: collapsed ? ShellLayout.sidebarCollapsed : ShellLayout.sidebarExpanded)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(SidebarBackground())
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Spacing.sm) {
            if !collapsed {
                Text("kinhin")
                    .typeStyle(.title)
                Spacer(minLength: 0)
            }
            Button {
                withAnimation(.snappy) { model.toggleSidebar() }
            } label: {
                Image(systemName: "sidebar.left")
                    .frame(width: 28, height: ShellLayout.rowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(collapsed ? "Show sidebar" : "Hide sidebar")
            .accessibilityLabel(collapsed ? "Show sidebar" : "Hide sidebar")
            .accessibilityIdentifier("advanced-sidebar-toggle")
            .keyboardShortcut("s", modifiers: [.command, .option])
        }
        .padding(.bottom, Spacing.xs)
    }

    // MARK: - Rows

    private func row(_ section: MainSection) -> some View {
        let selected = model.selectedSection == section
        return Button {
            model.userSelected(section)
        } label: {
            SidebarRowLabel(symbol: section.symbol, title: Text(verbatim: section.label), collapsed: collapsed)
                .foregroundStyle(selected ? Palette.accentText : Palette.primaryText)
                .background(
                    RoundedRectangle(cornerRadius: Radius.md)
                        .fill(selected ? Palette.accent.opacity(0.15) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(section.label)
        .accessibilityLabel(section.label)
        .accessibilityIdentifier("sidebar-\(section.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if let version = pendingUpdate {
                Button {
                    model.userSelected(.settings)
                } label: {
                    if collapsed {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(Palette.accentText)
                            .frame(maxWidth: .infinity)
                    } else {
                        Chip("Update available", tone: .accent)
                    }
                }
                .buttonStyle(.plain)
                .help("Update available — kinhin \(version)")
                .accessibilityLabel("Update available — kinhin \(version)")
                .accessibilityIdentifier("sidebar-update")
            }
            Button {
                model.present(.sponsor)
            } label: {
                SidebarRowLabel(
                    symbol: "star.fill", title: Text("Support kinhin"), collapsed: collapsed, symbolTint: Palette.star
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Support kinhin")
            .accessibilityLabel("Support kinhin")
            .accessibilityIdentifier("sponsor-button")
        }
    }
}

/// One sidebar row's content: the SF Symbol, and the title unless the sidebar is folded to its rail.
private struct SidebarRowLabel: View {
    let symbol: String
    let title: Text
    let collapsed: Bool
    var symbolTint: Color?

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Group {
                if let symbolTint {
                    Image(systemName: symbol).foregroundStyle(symbolTint)
                } else {
                    Image(systemName: symbol)
                }
            }
            .frame(width: 20)
            if !collapsed {
                title.typeStyle(.body)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, Spacing.sm)
        .frame(height: ShellLayout.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The sidebar's translucent material, as in Finder and Settings.
private struct SidebarBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
