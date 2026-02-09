#!/usr/bin/swift
import Foundation
import Darwin
import SystemConfiguration

let TARGETIFNAM = "awdl0"

class FlowNetDaemon {
    private var running = true
    private let logPath = "/var/log/flownet.log"
    private let pidPath = "/var/run/flownet.pid"
    private var shutdownRequested = false
    private var suppressionCount: UInt64 = 0
    private var aggressiveMode = true
    private var lastLoopTime = Date()
    private var dynamicStore: SCDynamicStore?
    private var runLoopSource: CFRunLoopSource?

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

        // Setup real-time network monitoring with SCDynamicStore
        if !setupNetworkMonitoring() {
            log("ERROR: Failed to setup network monitoring")
            exit(1)
        }

        // Initial suppression
        suppressWithRetry(reason: "Initial startup")

        log("Monitoring \(TARGETIFNAM) via SCDynamicStore (real-time)")
        log("Wake-from-sleep detection enabled")

        // Event-driven monitoring loop
        runEventLoop()

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

    private func setupNetworkMonitoring() -> Bool {
        // Create callback context
        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        // Create dynamic store
        guard let store = SCDynamicStoreCreate(
            nil,
            "com.whaleyshire.flownet" as CFString,
            { (store, changedKeys, info) in
                guard let info = info else { return }
                let daemon = Unmanaged<FlowNetDaemon>.fromOpaque(info).takeUnretainedValue()
                daemon.handleNetworkChange(changedKeys: changedKeys as! [String])
            },
            &context
        ) else {
            log("ERROR: Failed to create SCDynamicStore")
            return false
        }

        self.dynamicStore = store

        // Monitor ALL network interface state changes
        // This pattern catches any State:/Network/Interface/*/Link changes
        let patterns = [
            "State:/Network/Interface/.*/Link" as CFString,
            "State:/Network/Interface/.*/IPv4" as CFString,
            "State:/Network/Interface/.*/IPv6" as CFString,
            "State:/Network/Global/IPv4" as CFString
        ] as CFArray

        if !SCDynamicStoreSetNotificationKeys(store, nil, patterns) {
            log("ERROR: Failed to set notification keys")
            return false
        }

        // Create run loop source
        guard let rls = SCDynamicStoreCreateRunLoopSource(nil, store, 0) else {
            log("ERROR: Failed to create run loop source")
            return false
        }

        self.runLoopSource = rls
        CFRunLoopAddSource(CFRunLoopGetCurrent(), rls, .defaultMode)

        // Setup wake from sleep notification
        setupSleepWakeNotifications()

        return true
    }

    private func setupSleepWakeNotifications() {
        // Monitor system power state changes for sleep/wake detection
        let patterns = ["State:/IOKit/PowerManagement/SystemPowerState" as CFString] as CFArray
        if let store = dynamicStore {
            SCDynamicStoreSetNotificationKeys(store, patterns, nil)
        }
    }

    private func handleNetworkChange(changedKeys: [String]) {
        // Check if any AWDL-related keys changed
        let awdlChanged = changedKeys.contains { key in
            key.contains(TARGETIFNAM) || key.contains("PowerManagement")
        }

        if awdlChanged {
            // Check for wake from sleep
            if changedKeys.contains(where: { $0.contains("PowerManagement") }) {
                log("⏰ System wake detected")
                // Give system a moment to stabilize
                usleep(500000)  // 500ms
            }

            // Immediate check and suppression
            let status = checkAWDLStatus()
            if status.isUp {
                log("⚡ Real-time event: AWDL is UP (flags: \(status.flags), status: \(status.status))")
                suppressWithRetry(reason: "Real-time detection")
            }
        }
    }

    private func runEventLoop() {
        // Setup watchdog timer for periodic health checks
        let timer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let status = self.checkAWDLStatus()
            if status.isUp {
                self.log("⚠️  Watchdog: AWDL is STILL UP - attempting suppression")
                self.suppressWithRetry(reason: "Watchdog")
            } else {
                self.log("✓ Watchdog: AWDL is DOWN (suppressions: \(self.suppressionCount))")
            }
        }

        // Run the event loop
        while running {
            let result = CFRunLoopRunInMode(.defaultMode, 1.0, true)

            if result == .stopped || result == .finished {
                break
            }
        }

        timer.invalidate()
    }

    // Interface state from ifconfig
    struct AWDLStatus {
        let isUp: Bool
        let flags: String
        let status: String
    }

    private func checkAWDLStatus() -> AWDLStatus {
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
                    // Extract flags
                    var flags = "unknown"
                    var status = "unknown"

                    for line in output.components(separatedBy: "\n") {
                        if line.contains("flags=") {
                            if let range = line.range(of: "flags=[^\\s]+", options: .regularExpression) {
                                flags = String(line[range]).replacingOccurrences(of: "flags=", with: "")
                            }
                        }
                        if line.contains("status:") {
                            if let range = line.range(of: "status:\\s+\\w+", options: .regularExpression) {
                                status = String(line[range]).replacingOccurrences(of: "status:\\s+", with: "", options: .regularExpression)
                            }
                        }
                    }

                    let hasUpFlag = output.range(of: "flags=[^<]*<[^>]*UP[^>]*>", options: .regularExpression) != nil
                    let isActive = output.contains("status: active")

                    return AWDLStatus(isUp: hasUpFlag || isActive, flags: flags, status: status)
                }
            }
            return AWDLStatus(isUp: false, flags: "error", status: "error")
        } catch {
            log("⚠️  checkAWDLStatus() error: \(error.localizedDescription)")
            return AWDLStatus(isUp: false, flags: "error", status: "error")
        }
    }

    private func suppressWithRetry(reason: String) {
        var attempts = 0
        let maxAttempts = 5

        while attempts < maxAttempts {
            let statusBefore = checkAWDLStatus()
            if !statusBefore.isUp {
                if attempts == 0 {
                    log("✓ \(reason): AWDL already DOWN")
                }
                return
            }

            if suppressAWDL() {
                suppressionCount += 1

                usleep(100000)
                let statusAfter = checkAWDLStatus()

                if !statusAfter.isUp {
                    log("✅ \(reason): AWDL suppressed successfully (count: \(suppressionCount))")
                    return
                } else {
                    log("⚠️  \(reason): Suppression command succeeded but AWDL still UP (attempt \(attempts + 1)/\(maxAttempts))")
                }
            } else {
                log("⚠️  \(reason): Suppression command failed (attempt \(attempts + 1)/\(maxAttempts))")
            }

            attempts += 1
            if attempts < maxAttempts {
                usleep(500000)  // Wait 500ms before retry
            }
        }

        log("❌ \(reason): Failed to suppress AWDL after \(maxAttempts) attempts")
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
        if let rls = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), rls, .defaultMode)
        }
        dynamicStore = nil
        runLoopSource = nil
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
        return kill(pid, 0) == 0  // Non-destructive process existence check
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
