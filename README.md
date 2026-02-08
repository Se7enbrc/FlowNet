# FlowNet

Kills AWDL (`awdl0`) to stop ping spikes and packet loss on macOS.

## Why?

If you've ever had random WiFi lag while gaming or on calls, it's probably AWDL. macOS turns it on automatically for AirDrop, Sidecar, and Continuity stuff. This daemon just keeps it off.

Shoutout to [awdlkiller](https://github.com/jamestut/awdlkiller) for the original implementation. Apple's gotten stricter with security over the years, so this is a Swift rewrite that plays nice with modern macOS.

## Install

```bash
brew tap Se7enbrc/flownet
brew install flownet
```

That's it. The service starts automatically.

Check if it's working:
```bash
flowctl status
```

## Usage

```bash
flowctl status    # show what's up
flowctl logs      # see what it's doing
flowctl restart   # restart if needed
```

## What you lose

AirDrop, Universal Control, Sidecar, and AirPlay won't work while this is running. That's the tradeoff for stable network performance.

## Uninstall

```bash
sudo brew services stop flownet
brew uninstall flownet
```

## How it works

Watches for AWDL interface changes via BSD routing sockets, immediately runs `ifconfig awdl0 down` when it comes up. Zero polling, zero CPU overhead when idle.

Built with Swift, runs as a system daemon via launchd.

## License

MIT
