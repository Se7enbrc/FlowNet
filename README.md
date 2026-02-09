# FlowNet

Kills AWDL (`awdl0`) to stop latency spikes and packet loss during bandwidth sensitive operations.

## Why?

If you've ever had random WiFi stuttering in a game stream or on video calls, even dealing with high precision UDP telemetry, it's probably AWDL. macOS turns it on automatically for AirDrop, Sidecar, and Continuity features. This daemon will keep it off to preserve that traffic.

If at any point you need to disable flownet for these continuity features, just run:

```bash
flowctl stop
# or
sudo brew services stop flownet
```

Big hat tip to to [awdlkiller](https://github.com/jamestut/awdlkiller) for the original design which inspired this modern knockoff. the required patterns have changed and awdlkiller became less reliable for me, so this is a Swift rewrite that plays nice with modern macOS.

## Install

```bash
brew install --cask Se7enbrc/flownet/flownet
```

That's it. It'll prompt for your password to setup the launch daemon and start automatically.

Check if it's working:
```bash
flowctl status
```

## Usage

```bash
flowctl status    # show daemon status and AWDL state
flowctl logs      # tail the daemon logs
flowctl start     # start the daemon
flowctl stop      # stop the daemon
flowctl restart   # restart the daemon
```

## What you lose

AirDrop, Universal Control, Sidecar, and AirPlay won't work while this is running. I haven't found a workaround.

## Uninstall

```bash
brew uninstall flownet
```

## How it works

Monitors AWDL interface changes using macOS's `SCDynamicStore` for real-time notifications, with sleep/wake detection for resilience. Immediately runs `ifconfig awdl0 down` when AWDL comes up, with retry logic to ensure suppression succeeds.

Built with Swift, runs as a system daemon via launchd.

## License

MIT
