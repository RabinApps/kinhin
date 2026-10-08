import Foundation

// MARK: - Token checks (`kinhin doctor --check-tokens`)

extension DoctorReportBuilder {
    /// Probes every configured account's token against its own forge, all at
    /// once, and returns one verdict per account in config order. A token that
    /// cannot be read or is not stored fails without a network call. Every
    /// failure carries `AuthFix.command` so the report says how to repair it.
    func tokenChecks(
        accounts: [AccountConfig], load: @escaping @Sendable (ForgeID, String) throws -> String?
    ) async -> [DoctorReport.TokenCheck] {
        let probe = tokenCheck
        return await withTaskGroup(of: (Int, DoctorReport.TokenCheck).self) { group in
            for (index, account) in accounts.enumerated() {
                group.addTask {
                    let report: TokenHealthCheck.Report
                    do {
                        if let token = try load(account.forge, account.name) {
                            report = await probe(account, token)
                        } else {
                            report = TokenHealthCheck.Report(ok: false, message: "No token stored.")
                        }
                    } catch {
                        report = TokenHealthCheck.Report(
                            ok: false, message: "Token could not be read: \(error.localizedDescription)")
                    }
                    return (
                        index,
                        DoctorReport.TokenCheck(
                            account: account.name, forge: account.forge.rawValue, ok: report.ok,
                            message: report.message,
                            fix: report.ok ? nil : AuthFix.command(forge: account.forge, account: account.name))
                    )
                }
            }
            var results: [(Int, DoctorReport.TokenCheck)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
}
