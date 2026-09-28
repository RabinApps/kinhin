import AppIntents

struct KinhinShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: FleetStatusIntent(),
            phrases: ["How's my \(.applicationName) fleet", "\(.applicationName) status"],
            shortTitle: "Fleet Status", systemImageName: "gauge.with.dots.needle.50percent")
        AppShortcut(
            intent: StartFleetIntent(),
            phrases: ["Start \(.applicationName)"],
            shortTitle: "Start Fleet", systemImageName: "power")
        AppShortcut(
            intent: StopFleetIntent(),
            phrases: ["Stop \(.applicationName)"],
            shortTitle: "Stop Fleet", systemImageName: "stop.circle")
        AppShortcut(
            intent: PauseFleetIntent(),
            phrases: ["Pause \(.applicationName)"],
            shortTitle: "Pause Fleet", systemImageName: "pause.circle")
        AppShortcut(
            intent: ResumeFleetIntent(),
            phrases: ["Resume \(.applicationName)"],
            shortTitle: "Resume Fleet", systemImageName: "play.circle")
        AppShortcut(
            intent: RunDoctorIntent(),
            phrases: ["Run \(.applicationName) diagnostics", "Run \(.applicationName) doctor"],
            shortTitle: "Run Diagnostics", systemImageName: "stethoscope")
        AppShortcut(
            intent: DeleteVMIntent(),
            phrases: ["Delete \(.applicationName) VM"],
            shortTitle: "Delete VM", systemImageName: "trash")
    }
}
