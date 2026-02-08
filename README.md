# FlowNet

AWDL suppression daemon for optimized WiFi performance on macOS.

## What It Does

FlowNet monitors and automatically disables the AWDL (Apple Wireless Direct Link) interface (`awdl0`) to prevent WiFi performance degradation and UDP packet loss caused by AirDrop, Sidecar, and other Continuity features.

## Inspiration

This project is inspired by [awdlkiller](https://github.com/jamestut/awdlkiller) by James T., which pioneered the approach of suppressing AWDL to eliminate ping spikes on macOS. However, with Apple's evolving security requirements and system integrity protections in modern macOS versions, a new implementation approach became necessary. FlowNet reimplements this functionality using Swift and native macOS APIs to work seamlessly with current macOS versions while maintaining the same goal: preventing AWDL from disrupting network performance.

## Install via Homebrew

```bash
brew tap se7enbrc/flownet
brew install flownet
# Service starts automatically
```

Check status:
```bash
flowctl status
```

## Manual Install

```bash
make
sudo ./flowctl install
```

## Usage

```bash
flowctl status    # Show daemon status and AWDL state
flowctl start     # Start the daemon
flowctl stop      # Stop the daemon
flowctl restart   # Restart the daemon
flowctl logs      # Tail daemon logs
```

## Update

```bash
brew upgrade flownet
```

## Uninstall

```bash
flowctl stop
brew uninstall flownet
```

Or manually:
```bash
sudo ./flowctl uninstall
```

## How It Works

1. Daemon monitors AWDL interface via BSD routing sockets
2. Detects when AWDL comes UP (triggered by macOS for Continuity features)
3. Immediately executes `ifconfig awdl0 down`
4. Runs as LaunchDaemon (survives reboots)
5. Event-driven (no polling) - instant response with zero CPU overhead

## Requirements

- macOS 13.0+
- Xcode Command Line Tools (for building)
- sudo access (for daemon installation)

## Files

- `src/flownet-daemon.swift` - Background daemon source
- `flowctl` - CLI control utility
- `flownet.rb` - Homebrew formula
- `com.whaleyshire.flownet.plist` - LaunchDaemon configuration
- `Makefile` - Build system

## License

MIT
