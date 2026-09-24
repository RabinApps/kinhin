// Capture harness: renders the REAL OnboardingWizardViewController (all 4
// steps) and ConfigTabViewController into PNGs, in light AND dark appearance.
// AppKit-only: no engine, no Keychain, no daemon, no writes to the real
// config. Built together with the app sources (same module → internal
// access); AppMain.swift is excluded so this file's @main is the entry.
//
// Env: KINHIN_HARNESS_OUT (default ".") — destination directory.
import AppKit
import KinhinKit

let scale: CGFloat = 2

func render(_ vc: NSViewController, size: NSSize, name: String, appearance: NSAppearance.Name) {
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    window.appearance = NSAppearance(named: appearance) // explicit: light or dark
    window.contentView = vc.view
    vc.view.frame = NSRect(origin: .zero, size: size)
    window.layoutIfNeeded()

    // Opaque canvas with a skipped first row: NSBitmapImageRep rejects a
    // fully opaque RGBA spec ("inconsistent set of values") unless an extra
    // row is allocated and then cropped away via the bitmap's own bytesPerRow
    // trick — simplest is a 1px-taller rep and cropping on read.
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current = ctx
    // Opaque backdrop first (fills every pixel), then the view ONCE.
    // The backdrop must resolve in the WINDOW's appearance — resolved
    // outside, NSColor paints in the process appearance (light) regardless
    // of the window's darkAqua, and dark captures come out all-white.
    let backdrop: NSColor
    if appearance == .darkAqua {
        backdrop = NSColor(calibratedWhite: 0.10, alpha: 1)   // ~ windowBackgroundColor dark
    } else {
        backdrop = NSColor(calibratedWhite: 0.93, alpha: 1)   // ~ windowBackgroundColor light
    }
    backdrop.setFill()
    ctx!.cgContext.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
    vc.view.displayIgnoringOpacity(vc.view.bounds, in: ctx!)
    NSGraphicsContext.restoreGraphicsState()

    let outDir = ProcessInfo.processInfo.environment["KINHIN_HARNESS_OUT"] ?? "."
    let url = URL(fileURLWithPath: outDir).appendingPathComponent("\(name).png")
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try! data.write(to: url)
    print("wrote \(url.path)")

    // View-frame tree (local coords) for layout auditing.
    func walk(_ v: NSView, depth: Int, into out: inout String) {
        let f = v.frame
        out += String(repeating: "  ", count: depth)
        out += String(format: "%@ [%.0f,%.0f %.0fx%.0f]\n", String(describing: type(of: v)), f.origin.x, f.origin.y, f.width, f.height)
        for s in v.subviews { walk(s, depth: depth + 1, into: &out) }
    }
    var tree = ""
    walk(vc.view, depth: 0, into: &tree)
    try! tree.write(to: URL(fileURLWithPath: outDir).appendingPathComponent("\(name)-frames.txt"), atomically: true, encoding: .utf8)
}

/// Canned Docker output so the Containers capture never touches a real daemon.
struct CannedShell: ShellRunning {
    func run(_ argv: [String], cwd: URL?, timeout: TimeInterval) async throws -> ShellResult {
        if argv.contains("ps") {
            return ShellResult(exitCode: 0, stdout: """
            {"ID":"a1","Image":"postgres:16","Names":"db","State":"running","Status":"Up 3 hours"}
            {"ID":"b2","Image":"kinhin-ci-linux","Names":"kinhin-7f3a","State":"exited","Status":"Exited (0) 1 hour ago"}
            """, stderr: "")
        }
        return ShellResult(exitCode: 0, stdout: "{\"Name\":\"pgdata\",\"Driver\":\"local\"}\n{\"Name\":\"toolchain-cache\",\"Driver\":\"local\"}", stderr: "")
    }
}

/// Captures a whole window's content (segment bar + active tab) offscreen.
@MainActor
func captureWindow(_ controller: MainTabsWindowController, name: String, dark: Bool) {
    guard let window = controller.window, let content = window.contentView else { return }
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    content.frame = NSRect(x: 0, y: 0, width: 620, height: 600)
    window.layoutIfNeeded()
    content.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    content.layoutSubtreeIfNeeded()
    guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
    let backdrop = NSAppearance(named: dark ? .darkAqua : .aqua)
    backdrop?.performAsCurrentDrawingAppearance {
        NSColor.windowBackgroundColor.setFill()
    }
    content.cacheDisplay(in: content.bounds, to: rep)
    let out = ProcessInfo.processInfo.environment["KINHIN_HARNESS_OUT"] ?? "."
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out).appendingPathComponent("\(name).png"))
    print("wrote \(name).png")
}

@main
struct HarnessMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let size = NSSize(width: 620, height: 560)

        // Fixed snapshot via the test seam — no disk access.
        let yaml = """
        repo: "RabinApps/kinhin"
        labels: ["self-hosted", "macos", "arm64"]
        min_runners: 0
        max_runners: 2
        runners_per_vm: 1
        poll_interval: 20
        vm:
          cpu: 4
          memory_gb: 8
          ephemeral: true
        image: "tahoe-base"
        reserve:
          cpu: 2
          memory_gb: 4
        container:
          image: "kinhin-ci-linux"
          cpus: 4
          memory_gb: 8
        docker:
          image: "kinhin-ci-linux"
          cpus: 2
          memory_gb: 4
          max_slots: 8
        """
        let snapshot = try! GeneralConfigEditor.snapshot(from: yaml)

        // Scratch config: the forms edit/read this file, never the real one.
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("kinhin-harness-config.yaml")
        try! yaml.write(to: scratch, atomically: true, encoding: .utf8)

        for appearance in [NSAppearance.Name.aqua, NSAppearance.Name.darkAqua] {
            let tag = appearance == .darkAqua ? "dark" : "light"

            // The wizard's forms are created with it: point them at the
            // scratch file and stub the Keychain probe BEFORE the view loads.
            let wizard = OnboardingWizardViewController()
            wizard.connectFormForTesting.configURL = scratch
            wizard.connectFormForTesting.hasStoredToken = { _ in false }
            wizard.macFormForTesting.configURL = scratch
            wizard.loadViewIfNeeded()
            render(wizard, size: size, name: "cap-wizard1-\(tag)", appearance: appearance)
            wizard.nextClickedForTesting(); wizard.loadViewIfNeeded()
            render(wizard, size: size, name: "cap-wizard2-\(tag)", appearance: appearance)
            wizard.nextClickedForTesting(); wizard.loadViewIfNeeded()
            render(wizard, size: size, name: "cap-wizard3-\(tag)", appearance: appearance)

            // Setup tab (post-onboarding): the same two forms on one page.
            let connect = ConnectFormViewController()
            connect.configURL = scratch
            connect.hasStoredToken = { _ in false }
            let mac = MacToolsFormViewController()
            mac.configURL = scratch
            let page = NSViewController()
            let (scroll, column) = FormKit.scrollingColumn(spacing: 14)
            column.addArrangedSubview(connect.view)
            column.addArrangedSubview(mac.view)
            let holder = NSView()
            holder.addSubview(scroll)
            NSLayoutConstraint.activate([
                scroll.topAnchor.constraint(equalTo: holder.topAnchor),
                scroll.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
                scroll.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 16),
                scroll.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -16),
            ])
            page.view = holder
            render(page, size: NSSize(width: 620, height: 820), name: "cap-setup-\(tag)", appearance: appearance)

            let containers = ContainersViewController()
            containers.makeManager = { ContainerManager(tool: $0, shell: CannedShell(), binary: "/bin/docker") }
            containers.loadViewIfNeeded()
            let wait = DispatchSemaphore(value: 0)
            Task { @MainActor in await containers.reloadAndWait(); wait.signal() }
            while wait.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            render(containers, size: NSSize(width: 600, height: 620), name: "cap-containers-\(tag)", appearance: appearance)

            let config = ConfigTabViewController()
            config.configURL = scratch
            config.loadViewIfNeeded()
            config.renderForTesting(snapshot)
            render(config, size: NSSize(width: 600, height: 760), name: "cap-config-\(tag)", appearance: appearance)
        }

        // Whole-window walkthrough with the real MainTabsWindowController.
        // Setup is skipped here (its forms probe the real Keychain) — it is
        // captured above with a stubbed token probe.
        let suite = UserDefaults(suiteName: "kinhin-harness-\(UUID().uuidString)")!
        for dark in [false, true] {
            let tag = dark ? "dark" : "light"
            let main = MainTabsWindowController(defaults: suite)
            var status = FleetStatus()
            status.running = true
            status.queueDepth = 3
            status.desired = 2
            status.capacityCap = 2
            status.jobCapacity = 2
            var busy = VMRecord(id: "kinhin-vm-a1", phase: .busy)
            busy.createdAt = Date(); busy.repos = ["acme/api"]; busy.job = "build"
            var ready = VMRecord(id: "kinhin-vm-b2", phase: .ready)
            ready.createdAt = Date()
            status.records = [busy, ready]
            main.render(status: status)
            main.window?.orderBack(nil)
            captureWindow(main, name: "win-fleet-\(tag)", dark: dark)
            main.tokenProbe = { _ in false }
            main.showAdvanced(.accounts)
            captureWindow(main, name: "win-advanced-accounts-\(tag)", dark: dark)
            main.showAdvanced(.capacity)
            captureWindow(main, name: "win-advanced-capacity-\(tag)", dark: dark)
            main.showAdvanced(.routing)
            // The pane loads asynchronously (config read + health probes).
            for _ in 0..<150 where main.runtimesController?.hasLoadedForTesting != true {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            RunLoop.main.run(until: Date().addingTimeInterval(1.0))
            captureWindow(main, name: "win-advanced-routing-\(tag)", dark: dark)
            main.showAdvanced(.app)
            captureWindow(main, name: "win-advanced-app-\(tag)", dark: dark)
        }

        exit(0)
    }
}
