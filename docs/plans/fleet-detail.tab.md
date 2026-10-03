# Fleet Detail Implementation plan

Scope
Two new UI surfaces, both on the Fleet tab (a third tab on the tab bar), plus a small set of engine-facing actions:

Fleet detail tab — per-VM drill-down (IP, phase timeline, attached runners, current job) and a per-repo queue/running breakdown card.
Per-fleet requeue/skip — operating on queued jobs across the fleet, from the Fleet tab.

1. New tab type
   Sources/kinhin-app/UI/MainWindowTypes.swift — add case detail to MainTab.
   Sources/kinhin-app/UI/SwiftUI/MainTabs/MainTabsView.swift — add the detail branch to the segmented picker and the page switch, and a FleetDetailView reference.
   Wire the tab into MainTabsModel.select/userSelected/visibleTabs so it is reachable from the menu bar and the tab bar.
2. Fleet detail model + view
   New files Sources/kinhin-app/UI/SwiftUI/Fleet/FleetDetailModel.swift and FleetDetailView.swift:
   FleetDetailModel (@MainActor @Observable): a live poll loop over FleetController.fetchStatus, filtering job-state (all / queued / running / cancelled), expanding a selected VM's rows (IP, phase, runner name, current job name, repos), and rendering the per-repo breakdown from FleetStatus.queueByRepo / runningByRepo.
   A confirm/cancel pattern consistent with the existing sheets; the detail view contains no destructive action by itself.
   The Fleet tab's segmented picker gains a "Detail" option; the view renders FleetDetailView when selected.
   No engine changes needed for the read side — everything reads through the existing FleetServing methods already called by the Fleet tab.
3. Per-fleet requeue/skip
   New FleetController methods:
   func requeueQueuedJobs(for forge: ForgeID) async throws — cancel matching queued jobs and re-queue them, for a specific forge.
   func skipQueuedJobs(for forge: ForgeID) async throws — mark matching queued jobs as skipped.
   Both go through the existing engine operations, and both are surfaced as throwing FleetServing methods so in-process and daemon backends honor them unchanged.
   App-layer entry points (existing pattern): FleetController.userRequeueQueuedJobs(for:) / userSkipQueuedJobs(for:) that set pendingFleetAction, run the command, refresh, and surface the result via AlertKit.present(error:).
   Fleet tab: a "Requeue queued" / "Skip queued" button in the breakdown card (or a compact actions row), with the pending-state backstop and disabled state matching the existing Stop/Pause buttons.
4. Wiring
   MainTabsModel: expose the new tab's model so the detail view and the requeue/skip button both read one controller instance.
   FleetView/FleetDetailModel: share the fleet status snapshot so the breakdown and the drill-down don't each re-poll.
   Menu: no new menu items needed (existing Start/Stop/Pause/Resume/Delete suffice); the detail tab is reachable from the tab bar and from the Fleet tab's menu.
5. Tests (new)
   Tests/KinhinAppTests/FleetDetailModelTests.swift: poll loop, selection, filter behavior, breakdown rendering (fake backend).
   Tests/KinhinAppTests/FleetRequeueSkipTests.swift: the new controller actions, pending state, and failure surfacing (fake backend).
6. Docs + build
   No new docs page needed; the detail tab is a section of the Fleet tab (like the pipeline sheet and Logs…). No sidebar change.
   Verification: swift build, swift test, swift format lint --strict -r Sources Tests before finishing.
   Decisions
   Location: Fleet tab, as a third tab (per your instruction).
   Requeue/skip scope: per fleet (your instruction), with the per-VM variant kept available later if needed.
