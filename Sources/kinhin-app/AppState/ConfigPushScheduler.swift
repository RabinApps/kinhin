import Foundation

/// Debounces config edits so a save burst (a stepper drag) flushes once.
/// `push()` records that edits are pending and, if no flush is scheduled,
/// schedules one after `delay`; edits that land while a flush runs trigger
/// another pass rather than being lost.
@MainActor
final class ConfigPushScheduler {
    var delay: Duration = .seconds(1)
    /// What a flush does: reload the config into the engine or daemon.
    /// The controller installs this; tests replace it.
    var flush: () async -> Void = {}
    var hasPendingEdits = false
    private(set) var isScheduled = false

    func push() {
        hasPendingEdits = true
        guard !isScheduled else { return }
        isScheduled = true
        Task { [weak self, delay] in
            do {
                try await Task.sleep(for: delay)  // debounce a save burst
            } catch {
                self?.isScheduled = false  // cancelled: nothing to push
                return
            }
            guard let self else { return }
            while self.hasPendingEdits {
                self.hasPendingEdits = false
                await self.flush()
            }
            self.isScheduled = false
        }
    }
}
