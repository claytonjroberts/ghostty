import Testing
@testable import Ghostty

struct HostStatusTests {
    private let hosts = [("mothership", "clayton@100.83.245.90")]

    @Test func foregroundSshToALinkedComputerIsItsName() {
        let ps = "Ss   -fish\nS+   ssh -o BatchMode=yes -p 22 clayton@100.83.245.90 -t tmux attach"
        #expect(HostStatus.name(ps: ps, hosts: hosts) == "Mothership")
    }

    @Test func otherHostsShowTheirHostName() {
        #expect(HostStatus.name(ps: "S+   /usr/bin/ssh -i key kaileynas", hosts: hosts) == "kaileynas")
    }

    @Test func noForegroundSshIsThisMac() {
        #expect(HostStatus.name(ps: "Ss+  -fish\nS    ssh clayton@100.83.245.90", hosts: hosts) == nil)
    }
}
