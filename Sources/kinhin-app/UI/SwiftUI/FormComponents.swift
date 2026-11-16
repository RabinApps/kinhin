import KinhinKit
import SwiftUI

/// SwiftUI counterparts of the `FormKit` builders, so hosted forms look the
/// same as the AppKit ones still around them.
enum FormMetrics {
    /// Width of a form card (matches `FormKit.formWidth`).
    static let width: CGFloat = 520
}

/// A settings form backed by config.yaml: where it reads and writes, and who
/// to tell after a successful write (the app pushes the edit to the fleet).
@MainActor
protocol ConfigFormModel: AnyObject {
    var configURL: URL { get set }
    var onChanged: (() -> Void)? { get set }
}

/// A collapsible "Token permissions" list: exactly what a forge token needs,
/// with a link to where it is created. Expands itself when `expandOnError`.
struct TokenRequirementsView: View {
    let requirements: TokenRequirements
    var expandOnError = false
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.forward")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 10)
                    Text("Token permissions needed").font(.system(size: 11, weight: .semibold))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Token permissions needed")
            .accessibilityValue(expanded ? Text("expanded") : Text("collapsed"))

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(requirements.options, id: \.kind) { option in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(verbatim: option.kind).font(.system(size: 11, weight: .semibold))
                                if let url = URL(string: option.url), option.url.hasPrefix("http") {
                                    Link("Create…", destination: url).font(.system(size: 11))
                                }
                            }
                            ForEach(option.permissions, id: \.self) { line in
                                HintText(verbatim: "• " + line).textSelection(.enabled)
                            }
                        }
                    }
                    if let note = requirements.note { HintText(verbatim: note) }
                }
                .padding(.leading, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onChange(of: expandOnError) { _, isError in if isError { expanded = true } }
    }
}
