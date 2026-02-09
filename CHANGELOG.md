# Changelog

All notable changes to FlowNet will be documented in this file.

## [2026.02.3] - 2026-02-09

### Fixed
- **Critical: Signal handler safety** - Replaced unsafe Swift method calls in signal handlers with async-signal-safe atomic flag approach. Previous implementation could cause deadlocks or crashes.
- **Critical: Memory management** - Fixed SCDynamicStore context memory management by using `passRetained` instead of `passUnretained` with proper cleanup to prevent potential crashes.
- **Important: PID file race condition** - Implemented file locking (flock) to prevent TOCTOU race condition between checking and writing PID file.
- **Important: Cross-platform path handling** - Updated `flowctl install` to generate plist with correct daemon path for both Intel and Apple Silicon Macs.
- **Error handling** - Added return value checking for `setupSleepWakeNotifications()`.

### Removed
- Removed broken `route change` command with incorrect syntax that was being ignored anyway.
- Removed dead `aggressiveMode` code - variable was hardcoded to `true` with no way to configure it. Now always uses multi-layered suppression approach.

### Added
- Version information - Added `--version` / `-v` flag to display daemon version.
- Version constant embedded in binary (v2026.02.3).

### Changed
- Updated README to reflect that `flowctl stop` command exists and works.
- Updated README with accurate description of monitoring mechanism (SCDynamicStore).
- Improved signal checking in event loop for better shutdown responsiveness.

### Technical Details
**Signal Handler Fix:**
- Old: `signal(SIGTERM) { _ in FlowNetDaemon.shared.handleSignal(name: "SIGTERM") }`
- New: Uses `sig_atomic_t` flag that handlers set, checked in main loop

**Memory Management Fix:**
- Old: `Unmanaged.passUnretained(self).toOpaque()` - unsafe if object deallocated
- New: `Unmanaged.passRetained(self).toOpaque()` with proper release callback

**PID Race Fix:**
- Old: Check file, then write (race window)
- New: Open file, acquire exclusive lock (LOCK_EX | LOCK_NB), then write

## [1.x] - Previous versions
- Initial implementation with SCDynamicStore monitoring
- Sleep/wake detection
- Multi-layered suppression with retry logic
