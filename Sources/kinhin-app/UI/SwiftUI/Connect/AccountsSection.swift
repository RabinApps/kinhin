import KinhinKit
import SwiftUI

/// "More accounts": extra GitHub or Gitea accounts beyond the two cards
/// above, each with its own token.
struct AccountsSection: View {
    @Bindable var model: AccountsModel

    var body: some View {
        FormCard(
            title: "More accounts",
            subtitle: "Serve additional GitHub or Gitea accounts (another org, a second server) with their own tokens."
        ) {
            ForEach(model.rows) { row in
                accountRow(row)
                Divider()
            }
            addForm
        }
    }

    private func accountRow(_ row: AccountsModel.Row) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(row.account.name).font(.system(size: 12, weight: .semibold))
                Text(describe(row.account)).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Remove") { model.removeAccount(row.account.name) }
                    .controlSize(.small)
                    .accessibilityIdentifier("account-remove-\(row.account.name)")
            }
            StatusText(text: row.status.text, style: row.status.style)
            HStack(spacing: 8) {
                SecureField(
                    "Paste a \(row.account.forge == .github ? "personal access" : "Gitea access") token",
                    text: Binding(
                        get: { model.tokenTexts[row.account.name] ?? "" },
                        set: { model.tokenTexts[row.account.name] = $0 })
                )
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 300)
                .onSubmit { model.connect(row.account.name) }
                .accessibilityIdentifier("account-token-\(row.account.name)")
                .accessibilityLabel("\(row.account.name) access token")
                Button(row.tokenStored ? "Replace" : "Connect") { model.connect(row.account.name) }
                    .disabled(row.checking)
                    .accessibilityIdentifier("account-connect-\(row.account.name)")
            }
        }
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Add an account").font(.system(size: 12, weight: .semibold))
            HStack(spacing: 8) {
                Picker("", selection: $model.newForge) {
                    Text("GitHub").tag(ForgeID.github)
                    Text("Gitea").tag(ForgeID.gitea)
                }
                .labelsHidden()
                .frame(width: 90)
                .accessibilityIdentifier("account-new-forge")
                TextField("", text: $model.newName, prompt: Text(verbatim: "name, e.g. work"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)
                    .accessibilityIdentifier("account-new-name")
                    .accessibilityLabel("New account name")
                TextField("", text: $model.newScope, prompt: Text(verbatim: "owner/name, or an org"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 170)
                    .accessibilityIdentifier("account-new-scope")
                    .accessibilityLabel("New account repository or organization")
            }
            if model.newForge == .gitea {
                TextField("", text: $model.newInstance, prompt: Text(verbatim: "https://gitea.example.com"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
                    .accessibilityIdentifier("account-new-instance")
                    .accessibilityLabel("New account Gitea server address")
            }
            HStack(spacing: 8) {
                Button("Add account") { model.addAccount() }
                    .accessibilityIdentifier("account-add")
                if !model.addStatus.text.isEmpty {
                    StatusText(text: model.addStatus.text, style: model.addStatus.style)
                }
            }
        }
    }

    private func describe(_ account: AccountConfig) -> String {
        let forge = account.forge == .github ? "GitHub" : "Gitea"
        return account.instance.map { "\(forge) · \(account.scope) @ \($0)" } ?? "\(forge) · \(account.scope)"
    }
}
