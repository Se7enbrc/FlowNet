#!/usr/bin/swift
import Foundation
import Darwin
import SystemConfiguration

let TARGETIFNAM = "awdl0"
let VERSION = "2026.02.3"

// Atomic flag for signal handling (async-signal-safe)
var signalReceived: sig_atomic_t = 0

class FlowNetDaemon {
    private var running = true
    private let logPath = "/var/log/flownet.log"
    private let pidPath = "/var/run/flownet.pid"
    private var shutdownRequested = false
    private var suppressionCount: UInt64 = 0
    private var lastLoopTime = Date()
    private var dynamicStore: SCDynamicStore?
    private var runLoopSource: CFRunLoopSource?
    private var storeContext: UnsafeMutablePointer<SCDynamicStoreContext>?
    private var lockFd: Int32 = -1

    func start() {
        let myPID = ProcessInfo.processInfo.processIdentifier
        log("FlowNet daemon v\(VERSION) starting (PID: \(myPID))...")

        // Lock-based PID file check to prevent race condition
        lockFd = open(pidPath, O_CREAT | O_RDWR, 0o644)
        if lockFd == -1 {
            log("ERROR: Failed to open PID file")
            exit(1)
        }

        if flock(lockFd, LOCK_EX | LOCK_NB) == -1 {
            log("ERROR: Daemon already running (PID file locked)")
            close(lockFd)
            exit(1)
        }

        writePIDFile(myPID)

        // Async-signal-safe signal handlers
        signal(SIGTERM) { _ in signalReceived = SIGTERM }
        signal(SIGINT) { _ in signalReceived = SIGINT }
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

    func checkSignals() {
        if signalReceived != 0 && !shutdownRequested {
            shutdownRequested = true
            let sigName = signalReceived == SIGTERM ? "SIGTERM" : "SIGINT"
            log("Received \(sigName) - shutting down")
            running = false
        }
    }

    private func setupNetworkMonitoring() -> Bool {
        // Allocate context on heap for proper lifetime management
        storeContext = UnsafeMutablePointer<SCDynamicStoreContext>.allocate(capacity: 1)
        storeContext!.pointee = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passRetained(self).toOpaque(),
            retain: nil,
            release: { info in
                Unmanaged<FlowNetDaemon>.fromOpaque(info).release()
            },
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
            storeContext
        ) else {
            log("ERROR: Failed to create SCDynamicStore")
            if let ctx = storeContext {
                Unmanaged<FlowNetDaemon>.fromOpaque(ctx.pointee.info!).release()
                ctx.deallocate()
            }
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
        if !setupSleepWakeNotifications() {
            log("WARNING: Failed to setup sleep/wake notifications")
        }

        return true
    }

    private func setupSleepWakeNotifications() -> Bool {
        // Monitor system power state changes for sleep/wake detection
        let patterns = ["State:/IOKit/PowerManagement/SystemPowerState" as CFString] as CFArray
        if let store = dynamicStore {
            return SCDynamicStoreSetNotificationKeys(store, patterns, nil)
        }
        return false
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

            // Check for signals
            self.checkSignals()

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
            // Check for signals before each iteration
            checkSignals()

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
        // Layer 1: Bring interface down
        let success = executeCommand("/sbin/ifconfig", [TARGETIFNAM, "down"])

        // Layer 2: Delete IPv6 link-local addresses (prevents some re-enablement)
        if let ipv6Addrs = getIPv6Addresses() {
            for addr in ipv6Addrs {
                _ = executeCommand("/sbin/ifconfig", [TARGETIFNAM, "inet6", addr, "delete"])
            }
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

        // Clean up context memory
        if let ctx = storeContext {
            ctx.deallocate()
            storeContext = nil
        }

        // Release PID file lock
        if lockFd >= 0 {
            close(lockFd)
            lockFd = -1
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
if CommandLine.arguments.contains("--version") || CommandLine.arguments.contains("-v") {
    print("FlowNet v\(VERSION)")
    exit(0)
}

FlowNetDaemon.shared.start()
