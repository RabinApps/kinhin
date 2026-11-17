import AppKit
import SwiftUI
import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// Renders the whole desktop app to PNGs, offscreen: every sidebar section, every Diagnostics pane and the setup
/// wizard, in light, dark and right-to-left. It is how "Design first" step 4 (compare against the design) is done
/// without launching the app; see CONTRIBUTING.md.
///
/// Not a regression test: it asserts nothing and is skipped unless `KINHIN_CAPTURE_OUT` names a folder. Run it
/// through `scripts/capture-ui.sh`, which points the app at a throwaway config and keeps tokens out of the Keychain.
/// `KINHIN_CAPTURE_PAGES` (comma-separated page names, e.g. `runtimes,settings`) renders only those pages.
///
/// Add a screen or a Diagnostics pane to `pages` below when you add one to the app.
@MainActor
final class UICaptureTests: MainWindowTestCase {
    private var outputFolder: String { ProcessInfo.processInfo.environment["KINHIN_CAPTURE_OUT"] ?? "" }

    private var onlyPages: Set<String>? {
        ProcessInfo.processInfo.environment["KINHIN_CAPTURE_PAGES"].map {
            Set($0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
        }
    }

    private struct Variant {
        let tag: String
        let dark: Bool
        let rightToLeft: Bool
    }

    private struct Page {
        let name: String
        /// Tall enough to show the whole page without scrolling.
        let height: CGFloat
        /// Also rendered in dark and right-to-left (the pages whose layout differs most).
        let allVariants: Bool
        let show: () -> Void
    }

    // MARK: - Test

    func testCaptureEverything() async throws {
        try XCTSkipIf(outputFolder.isEmpty, "set KINHIN_CAPTURE_OUT (scripts/capture-ui.sh does) to render the screens")
        try FileManager.default.createDirectory(atPath: outputFolder, withIntermediateDirectories: true)

        fleet.status = Self.demoStatus()
        fleet.environment.configURL = Paths.config
        window.models.tokenProbe = { _ in false }
        window.window?.orderBack(nil)
        guard let content = window.window?.contentView, let win = window.window else { return XCTFail("no window") }

        let variants = [
            Variant(tag: "light", dark: false, rightToLeft: false),
            Variant(tag: "dark", dark: true, rightToLeft: false),
            Variant(tag: "rtl", dark: false, rightToLeft: true),
        ]
        for variant in variants {
            for page in pages where variant.tag == "light" || page.allVariants {
                guard onlyPages?.contains(page.name) ?? true else { continue }
                page.show()
                // Lay the page out first: its models are created when it first renders, so there is nothing to wait for before.
                layout(content, window: win, size: NSSize(width: 1000, height: page.height), variant: variant)
                await waitForLoads()
                await snap(
                    content, window: win, size: NSSize(width: 1000, height: page.height),
                    name: "\(page.name)-\(variant.tag)", variant: variant)
            }
        }
        for variant in variants.prefix(2) { await captureWizard(variant) }
        for variant in variants.prefix(2) { await captureSheets(variant) }
        captureMenus()
    }

    // MARK: - Pages

    private var pages: [Page] {
        let tabs = window.tabs
        return [
            Page(name: "fleet", height: 1500, allVariants: true) { tabs.select(.fleet) },
            Page(name: "runtimes", height: 3300, allVariants: true) { tabs.select(.runtimes) },
            Page(name: "accounts", height: 1500, allVariants: false) { tabs.select(.accounts) },
            Page(name: "toolchains", height: 2600, allVariants: false) { tabs.select(.toolchains) },
            Page(name: "diag-health", height: 1700, allVariants: true) { tabs.showDiagnostics(.health) },
            Page(name: "diag-logs", height: 900, allVariants: false) { tabs.showDiagnostics(.logs) },
            Page(name: "diag-benchmarks", height: 1100, allVariants: false) { tabs.showDiagnostics(.benchmarks) },
            Page(name: "diag-containers", height: 900, allVariants: false) { tabs.showDiagnostics(.containers) },
            Page(name: "diag-tools", height: 700, allVariants: false) { tabs.showDiagnostics(.tools) },
            Page(name: "settings", height: 2800, allVariants: true) { tabs.select(.settings) },
        ]
    }

    private func captureWizard(_ variant: Variant) async {
        let model = WizardModel()
        model.connect.configURL = Paths.config
        model.connect.hasStoredToken = { _ in false }
        model.mac.configURL = Paths.config
        model.mac.autoEnableLinuxRuntime = false
        let host = NSHostingView(rootView: WizardView(model: model))
        host.sizingOptions = []
        let wizardWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 900), styleMask: [.titled], backing: .buffered,
            defer: false)
        wizardWindow.contentView = host
        // Jump to each step: Continue is blocked until a forge is connected, so `next()` would stay on step 1.
        let steps: [(WizardModel.Step, CGFloat)] = [(.connect, 900), (.mac, 1100), (.review, 900)]
        for (index, (step, height)) in steps.enumerated() {
            model.show(step)
            await snap(
                host, window: wizardWindow, size: NSSize(width: 820, height: height),
                name: "wizard\(index + 1)-\(variant.tag)", variant: variant)
        }
    }

    /// Every sheet, rendered on its own (a sheet is a separate window, which an offscreen render of the main window
    /// does not include). Each is sized to its content.
    private func captureSheets(_ variant: Variant) async {
        let models = window.models
        // Created when the Runtimes page rendered above (not when only some pages were asked for).
        window.tabs.select(.runtimes)
        layout(
            window.window!.contentView!, window: window.window!, size: NSSize(width: 1000, height: 900),
            variant: variant)
        await waitForLoads()
        guard let runtimes = models.runtimesModel else { return }
        let tool = InstallableTool.docker
        let options = RuntimeInstaller.options(for: tool)
        var sheets: [(String, AnyView)] = [
            ("sponsor", AnyView(SponsorSheet(close: {}))),
            ("workflow-test", AnyView(WorkflowTestView(model: WorkflowTestModel(), onClose: {}))),
            ("videos", AnyView(VideosView(model: models.ensureVideosModel(), onClose: {}))),
            ("pipeline", AnyView(PipelineView(model: models.makePipelineModel(vmID: "kinhin-vm-a1"), onClose: {}))),
            ("add-route", AnyView(AddRouteSheet(model: runtimes, runtimes: [.tart, .appleContainer, .docker]))),
            (
                "install",
                AnyView(
                    InstallConfirmationSheet(
                        offer: InstallOffer(tool: tool, options: options), onConfirm: { _ in }, onCopy: { _ in },
                        onCancel: {}))
            ),
            (
                "missing-brew",
                AnyView(
                    MissingBrewSheet(
                        offer: MissingBrewOffer(tool: tool, options: options), onGetBrew: {}, onDownload: {},
                        onCancel: {}))
            ),
        ]
        runtimes.editYAMLClicked()
        sheets.append(("edit-yaml", AnyView(EditYAMLSheet(model: runtimes))))
        runtimes.addContainerPoolClicked()
        if let offer = runtimes.containerPoolOffer {
            sheets.append(("container-pool", AnyView(ContainerPoolSheet(model: runtimes, offer: offer))))
        }
        models.alertsModel.beginAdd()
        sheets.append(("webhook", AnyView(AlertWebhookSheet(model: models.alertsModel))))
        for (name, view) in sheets {
            guard onlyPages?.contains("sheet-\(name)") ?? true else { continue }
            let host = NSHostingView(rootView: view)
            let sheetWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 900), styleMask: [.titled], backing: .buffered,
                defer: false)
            sheetWindow.contentView = host
            layout(host, window: sheetWindow, size: NSSize(width: 800, height: 900), variant: variant)
            await settle(0.8)
            let fit = host.fittingSize
            await snap(
                host, window: sheetWindow, size: NSSize(width: max(fit.width, 300), height: max(fit.height, 200)),
                name: "sheet-\(name)-\(variant.tag)", variant: variant)
        }
    }

    /// The menu bar menu as text (an NSMenu has no offscreen render): one `menu-<state>.txt` per fleet state, hidden
    /// items marked, so it can be read against the design's menu frame.
    private func captureMenus() {
        guard onlyPages?.contains("menu") ?? true else { return }
        func dump(_ menu: NSMenu, indent: String = "") -> String {
            menu.items.map { item in
                let line =
                    item.isSeparatorItem
                    ? "\(indent)----"
                    : "\(indent)\(item.isHidden ? "(hidden) " : "")\(item.title)"
                        + (item.isEnabled ? "" : "  [disabled]")
                return item.submenu.map { line + "\n" + dump($0, indent: indent + "    ") } ?? line
            }.joined(separator: "\n")
        }
        let states: [(String, FleetStatus?)] = [("running", Self.demoStatus()), ("stopped", FleetStatus())]
        for (name, status) in states {
            let delegate = AppDelegate()
            let menu = delegate.buildMenu()
            delegate.menu = menu
            delegate.applyFleetControlVisibility(to: menu, status: status)
            let url = URL(fileURLWithPath: outputFolder).appendingPathComponent("menu-\(name).txt")
            try? dump(menu).write(to: url, atomically: true, encoding: .utf8)
            print("wrote \(url.path)")
        }
    }

    // MARK: - Rendering

    private func layout(_ view: NSView, window: NSWindow, size: NSSize, variant: Variant) {
        window.appearance = NSAppearance(named: variant.dark ? .darkAqua : .aqua)
        view.userInterfaceLayoutDirection = variant.rightToLeft ? .rightToLeft : .leftToRight
        view.frame = NSRect(origin: .zero, size: size)
        window.layoutIfNeeded()
        view.layoutSubtreeIfNeeded()
    }

    private func snap(_ view: NSView, window: NSWindow, size: NSSize, name: String, variant: Variant) async {
        layout(view, window: window, size: size, variant: variant)
        await settle(0.6)
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let url = URL(fileURLWithPath: outputFolder).appendingPathComponent("cap-\(name).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("wrote \(url.path)")
    }

    /// Waits by suspending, not by spinning the run loop: the models' async loads are main-actor tasks, which only run
    /// while the test is suspended (and the run loop turns then too).
    private func settle(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// Lets the page's async loads land: the config read and the runtime health probes (up to a minute).
    private func waitForLoads() async {
        await settle(0.5)
        if let runtimes = window.models.runtimesModel {
            let deadline = Date().addingTimeInterval(60)
            while (!runtimes.hasLoadedForTesting || runtimes.isProbingHealth), Date() < deadline { await settle(0.1) }
        }
        await settle(1.5)
    }

    /// A fleet with one instance in each of three phases, spread over the three runtimes.
    private static func demoStatus() -> FleetStatus {
        var status = FleetStatus()
        status.running = true
        status.queueDepth = 3
        status.desired = 4
        status.capacityCap = 6
        status.jobCapacity = 8
        var busy = VMRecord(id: "kinhin-vm-a1", phase: .busy)
        busy.createdAt = Date()
        busy.repos = ["acme/api"]
        busy.job = "build"
        var booting = VMRecord(id: "kinhin-vm-b2", phase: .booting)
        booting.createdAt = Date()
        booting.runtime = RuntimeID.appleContainer.rawValue
        var failed = VMRecord(id: "kinhin-vm-c3", phase: .failed)
        failed.createdAt = Date()
        failed.runtime = RuntimeID.docker.rawValue
        failed.error = "image not found: kinhin-linux"
        status.records = [busy, booting, failed]
        status.capacityByRuntime = [
            RuntimeID.tart.rawValue: "2", RuntimeID.appleContainer.rawValue: "2", RuntimeID.docker.rawValue: "2",
        ]
        return status
    }
}
