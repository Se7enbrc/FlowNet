# FlowNet

Kills AWDL (`awdl0`) to stop latency spikes and packet loss during bandwidth sensitive operations.

## Why?

If you've ever had random WiFi stuttering in a game stream or on video calls, even dealing with high precision UDP telemetry, it's probably AWDL). macOS turns it on automatically for AirDrop, Sidecar, and Continuity features. This daemon will keep it off to preserve that traffic.

If at any point you need to disable flownet for these continuity features, just run

```bash
sudo brew services stop flownet
```

I plan to add flowctl stop in the future but it didn't feel necessary day 1 to me

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
flowctl status    # show what's up
flowctl logs      # see what it's doing
flowctl restart   # restart if needed
```

## What you lose

AirDrop, Universal Control, Sidecar, and AirPlay won't work while this is running. I haven't found a workaround.

## Uninstall

```bash
brew uninstall flownet
```

## How it works

Watches for AWDL interface changes via BSD routing sockets, immediately runs `ifconfig awdl0 down` when it comes up.

Built with Swift, runs as a system daemon via launchd.

## License

MIT
