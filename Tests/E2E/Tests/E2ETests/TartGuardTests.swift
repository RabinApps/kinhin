import E2ESupport
import Testing

private func tartVM(_ name: String, running: Bool = true, linux: Bool = false) -> Instances.TartVM {
    Instances.TartVM(name: name, running: running, isLinux: linux)
}

/// The Tart lane guard, decided from the VMs listed. Pure: no VM, Tart or network is needed, so it runs in the quick
/// tier.
@Suite("Tart lane guard")
struct TartGuardTests {
    @Test func noFleetVMsLetsEitherLaneStart() {
        #expect(Instances.tartBlockers(for: .tartMacOS, leftovers: [], fleet: []).isEmpty)
        #expect(Instances.tartBlockers(for: .tartLinux, leftovers: [], fleet: []).isEmpty)
    }

    @Test func leftoversAlwaysBlock() {
        #expect(Instances.tartBlockers(for: .tartLinux, leftovers: ["ke2ed-1"], fleet: []) == ["ke2ed-1"])
        #expect(Instances.tartBlockers(for: .tartMacOS, leftovers: ["ke2ed-1"], fleet: []) == ["ke2ed-1"])
    }

    @Test func aFleetsLinuxVMsNeverBlock() {
        let fleet = [tartVM("kinhin-1", linux: true), tartVM("kinhin-2", linux: true)]
        #expect(Instances.tartBlockers(for: .tartLinux, leftovers: [], fleet: fleet).isEmpty)
        #expect(Instances.tartBlockers(for: .tartMacOS, leftovers: [], fleet: fleet).isEmpty)
    }

    @Test func oneRunningFleetMacOSVMLeavesRoomForTheLane() {
        #expect(Instances.tartBlockers(for: .tartMacOS, leftovers: [], fleet: [tartVM("kinhin-1")]).isEmpty)
    }

    @Test func twoRunningFleetMacOSVMsUseUpTheCap() {
        let fleet = [tartVM("kinhin-1"), tartVM("kinhin-2")]
        #expect(Instances.tartBlockers(for: .tartMacOS, leftovers: [], fleet: fleet) == ["kinhin-1", "kinhin-2"])
    }

    @Test func stoppedFleetVMsHoldNoSlot() {
        let fleet = [tartVM("kinhin-1", running: false), tartVM("kinhin-2", running: false), tartVM("kinhin-3")]
        #expect(Instances.tartBlockers(for: .tartMacOS, leftovers: [], fleet: fleet).isEmpty)
    }

    @Test func linuxVMsDoNotCountTowardTheMacOSCap() {
        let fleet = [tartVM("kinhin-1"), tartVM("kinhin-2", linux: true), tartVM("kinhin-3", linux: true)]
        #expect(Instances.tartBlockers(for: .tartMacOS, leftovers: [], fleet: fleet).isEmpty)
    }
}
