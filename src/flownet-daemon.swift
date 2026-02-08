#!/usr/bin/swift
import Foundation
import Darwin

let TARGETIFNAM = "awdl0"

// Routing message types (from net/route.h)
let RTM_IFINFO: UInt8 = 0x0e  // Interface state change

// Routing message header structure
struct rt_msghdr {
    var rtm_msglen: UInt16
    var rtm_version: UInt8
    var rtm_type: UInt8
    var rtm_index: UInt16
    var rtm_flags: Int32
    var rtm_addrs: Int32
    var rtm_pid: pid_t
    var rtm_seq: Int32
    var rtm_errno: Int32
    var rtm_use: Int32
    var rtm_inits: UInt32
    var rtm_rmx: rt_metrics
}

struct rt_metrics {
    var rmx_locks: UInt32
    var rmx_mtu: UInt32
    var rmx_hopcount: UInt32
    var rmx_expire: Int32
    var rmx_recvpipe: UInt32
    var rmx_sendpipe: UInt32
    var rmx_ssthresh: UInt32
    var rmx_rtt: UInt32
    var rmx_rttvar: UInt32
    var rmx_pksent: UInt32
    var rmx_state: UInt32
    var rmx_filler: (UInt32, UInt32, UInt32)
}

class FlowNetDaemon {
    private var running = true
    private let logPath = "/var/log/flownet.log"
    private let pidPath = "/var/run/flownet.pid"
    private var shutdownRequested = false
    private var routeSocket: Int32 = -1
    private var suppressionCount: UInt64 = 0
    private var aggressiveMode = true  // Multi-layered suppression

    func start() {
        let myPID = ProcessInfo.processInfo.processIdentifier
        log("FlowNet daemon starting (PID: \(myPID), aggressive mode: \(aggressiveMode))...")

        if let existingPID = readPIDFile(), processExists(existingPID) {
            log("ERROR: Daemon already running with PID \(existingPID)")
            exit(1)
        }

        writePIDFile(myPID)

        signal(SIGTERM) { _ in FlowNetDaemon.shared.handleSignal(name: "SIGTERM") }
        signal(SIGINT) { _ in FlowNetDaemon.shared.handleSignal(name: "SIGINT") }
        signal(SIGHUP, SIG_IGN)
        signal(SIGPIPE, SIG_IGN)

        if getuid() != 0 {
            log("ERROR: Must run as root")
            exit(1)
        }

        // Create routing socket for monitoring interface changes
        routeSocket = socket(AF_ROUTE, SOCK_RAW, 0)
        if routeSocket < 0 {
            log("ERROR: Failed to create routing socket: \(String(cString: strerror(errno)))")
            exit(1)
        }

        // Set socket to non-blocking mode for efficient message draining
        let flags = fcntl(routeSocket, F_GETFL, 0)
        if flags < 0 {
            log("ERROR: Failed to get socket flags: \(String(cString: strerror(errno)))")
            exit(1)
        }
        if fcntl(routeSocket, F_SETFL, flags | O_NONBLOCK) < 0 {
            log("ERROR: Failed to set socket non-blocking: \(String(cString: strerror(errno)))")
            exit(1)
        }

        // Initial suppression - use aggressive mode
        if suppressAWDL() {
            log("✓ Initial AWDL suppression successful")
        } else {
            log("⚠️  Initial AWDL suppression failed - will retry on state change")
        }

        log("Monitoring \(TARGETIFNAM) via routing socket (event-driven)...")

        // Event-driven monitoring loop
        eventLoop()

        cleanup()
        log("FlowNet daemon stopped (total suppressions: \(suppressionCount))")
        exit(0)
    }

    func handleSignal(name: String) {
        if !shutdownRequested {
            shutdownRequested = true
            log("Received \(name) - shutting down")
            running = false
        }
    }

    private func eventLoop() {
        var pollfd = Darwin.pollfd(fd: routeSocket, events: Int16(POLLIN), revents: 0)
        var buffer = [UInt8](repeating: 0, count: 2048)

        while running {
            // Poll with 1 second timeout to allow signal handling
            let result = Darwin.poll(&pollfd, 1, 1000)

            if result < 0 {
                if errno == EINTR {
                    continue
                }
                log("ERROR: poll() failed: \(String(cString: strerror(errno)))")
                break
            }

            if result == 0 {
                continue
            }

            if pollfd.revents & Int16(POLLIN) != 0 {
                // Data available - drain ALL pending messages
                var awdlStateChanged = false

                while true {
                    let bytesRead = recv(routeSocket, &buffer, buffer.count, 0)

                    if bytesRead < 0 {
                        if errno == EAGAIN || errno == EWOULDBLOCK {
                            break
                        }
                        log("ERROR: recv() failed: \(String(cString: strerror(errno)))")
                        break
                    }

                    if bytesRead == 0 {
                        break
                    }

                    if shouldProcessMessage(&buffer, bytesRead) {
                        awdlStateChanged = true
                    }
                }

                // Only suppress ONCE after draining all messages
                if awdlStateChanged {
                    if isAWDLUp() {
                        log("⚡ AWDL detected UP - engaging suppression")
                        if suppressAWDL() {
                            suppressionCount += 1
                            log("✓ AWDL suppressed (count: \(suppressionCount))")
                        }
                    }
                }
            }
        }
    }

    private func shouldProcessMessage(_ buffer: inout [UInt8], _ length: Int) -> Bool {
        guard length >= MemoryLayout<rt_msghdr>.size else {
            return false
        }

        let header = buffer.withUnsafeBytes { ptr in
            ptr.load(as: rt_msghdr.self)
        }

        guard header.rtm_type == RTM_IFINFO else {
            return false
        }

        guard let ifname = getInterfaceName(fromIndex: Int32(header.rtm_index)) else {
            return false
        }

        return ifname == TARGETIFNAM
    }

    private func getInterfaceName(fromIndex index: Int32) -> String? {
        var ifname = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        guard if_indextoname(UInt32(index), &ifname) != nil else {
            return nil
        }
        return String(cString: ifname)
    }

    private func isAWDLUp() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
        task.arguments = [TARGETIFNAM]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
            task.waitUntilExit()

            if task.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8) {
                    return output.contains("flags=") && output.contains("UP")
                }
            }
            return false
        } catch {
            return false
        }
    }

    // Multi-layered suppression approach
    private func suppressAWDL() -> Bool {
        var success = false

        // Layer 1: Bring interface down
        success = executeCommand("/sbin/ifconfig", [TARGETIFNAM, "down"])

        if aggressiveMode {
            // Layer 2: Delete IPv6 link-local addresses (prevents some re-enablement)
            if let ipv6Addrs = getIPv6Addresses() {
                for addr in ipv6Addrs {
                    _ = executeCommand("/sbin/ifconfig", [TARGETIFNAM, "inet6", addr, "delete"])
                }
            }

            // Layer 3: Set interface metric to max (deprioritize routing)
            _ = executeCommand("/sbin/route", ["change", "-ifp", TARGETIFNAM, "-hopcount", "255"])
        }

        return success
    }

    private func getIPv6Addresses() -> [String]? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
        task.arguments = [TARGETIFNAM]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                var addresses: [String] = []
                for line in output.components(separatedBy: "\n") {
                    if line.contains("inet6") {
                        let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: " ")
                        if parts.count > 1 {
                            addresses.append(parts[1])
                        }
                    }
                }
                return addresses.isEmpty ? nil : addresses
            }
        } catch {}

        return nil
    }

    private func executeCommand(_ path: String, _ args: [String]) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func cleanup() {
        if routeSocket >= 0 {
            close(routeSocket)
        }
        try? FileManager.default.removeItem(atPath: pidPath)
    }

    private func readPIDFile() -> Int32? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: pidPath)),
              let pidString = String(data: data, encoding: .utf8),
              let pid = Int32(pidString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return pid
    }

    private func writePIDFile(_ pid: Int32) {
        try? "\(pid)\n".write(toFile: pidPath, atomically: true, encoding: .utf8)
    }

    private func processExists(_ pid: Int32) -> Bool {
        return kill(pid, 0) == 0
    }

    private func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logMessage = "[\(timestamp)] \(message)"
        print(logMessage)
        fflush(stdout)
    }

    static let shared = FlowNetDaemon()
}

// Entry point
FlowNetDaemon.shared.start()
