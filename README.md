# macOS VPN Watchdog

Keep a macOS VPN connected and automatically reconnect it when the tunnel drops.
This helps with the common problem where a work, school, or company VPN keeps
disconnecting after sleep, Wi-Fi changes, inactivity, or flaky network handoffs.

`vpn_watchdog.sh` is a small macOS watchdog for VPN connections managed by
[`vpnutil`](https://github.com/Timac/VPNStatus/tree/master/vpnutil). It runs as
a user LaunchAgent, checks whether a named VPN appears connected, and calls
`vpnutil start <VPN_NAME>` when the connection is missing.

Search terms this project is meant to help with: macOS VPN keeps disconnecting,
Mac VPN auto reconnect, keep VPN connected on macOS, launchd VPN keepalive,
macOS VPN watchdog, and automatically reconnect VPN after sleep.

## Who This Is For

Use this if your VPN is already configured in macOS, but it randomly disconnects
or silently loses its tunnel routes. This is especially useful for remote workers
who need a company VPN to stay connected during the day.

This is not a VPN client. It does not create VPN profiles, store credentials, or
replace VPN provider software. It only watches an existing macOS VPN profile and
asks macOS to start it again when the connection appears down.

## What It Does

- Keeps a configured macOS VPN connection running in the background.
- Can run all day or only during a configured local-time working window.
- Detects connectivity from the VPN network interface and, optionally, routes
  that must be present on that interface.
- Uses a cooldown so it does not repeatedly spam `vpnutil start`.
- Polls on an interval and can also wake up on `scutil` reachability changes.
- Writes errors to `~/Library/Logs/vpnwatchdog.err.log`. Info logs are disabled
  unless `VPN_WATCHDOG_LOG_INFO=true` is set.

This script is useful when macOS reports a VPN profile as configured but the
actual tunnel interface or expected routes disappear after network changes.

## Requirements

- macOS.
- A VPN profile already configured in System Settings.
- Homebrew `vpnutil` installed at `/opt/homebrew/bin/vpnutil`.

Install `vpnutil` if needed:

```sh
brew install vpnutil
```

## Configure

Set these values before generating the LaunchAgent plist:

```sh
VPN_NAME="Your VPN Name"
LABEL="com.local.vpnwatchdog"
MODE="duringWorkingHoursOnly"
VPN_INTERFACE="ipsec0"
ROUTE_DESTINATIONS_TEXT=""
WATCH_HOST=""
```

Configuration notes:

- `VPN_NAME` must match the VPN profile name used by `vpnutil`.
- `MODE` is `duringWorkingHoursOnly` or `runAlways`.
- `VPN_INTERFACE` defaults to `ipsec0`, which is common for macOS IPsec VPNs.
- `ROUTE_DESTINATIONS_TEXT` is optional. When set, every space-separated route
  must be present on `VPN_INTERFACE`, for example `10.0/16 192.168.10/24`.
- `WATCH_HOST` is optional. Set it to a host that should trigger network
  reachability changes, often an internal VPN host. If empty, polling still runs.

Working hours default to `08:30` through `19:00` local time. Override them with
`WORK_START` and `WORK_END` in the LaunchAgent environment if needed.

## Install Or Update

Run from this folder after setting the configuration variables above:

```sh
mkdir -p "$HOME/vpn_watchdog" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"

install -m 755 ./vpn_watchdog.sh "$HOME/vpn_watchdog/vpn_watchdog.sh"

sed \
  -e "s#__HOME__#$HOME#g" \
  -e "s#__LABEL__#$LABEL#g" \
  -e "s#__VPN_NAME__#$VPN_NAME#g" \
  -e "s#__MODE__#$MODE#g" \
  -e "s#__VPN_INTERFACE__#$VPN_INTERFACE#g" \
  -e "s#__ROUTE_DESTINATIONS_TEXT__#$ROUTE_DESTINATIONS_TEXT#g" \
  -e "s#__WATCH_HOST__#$WATCH_HOST#g" \
  ./vpnwatchdog.plist.template > "$HOME/Library/LaunchAgents/$LABEL.plist"

plutil -lint "$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/$LABEL.plist" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/$LABEL.plist"
launchctl kickstart -k "gui/$(id -u)/$LABEL"
```

## Verify

Check that the LaunchAgent is loaded:

```sh
launchctl print "gui/$(id -u)/$LABEL"
```

Check the VPN interface:

```sh
ifconfig "$VPN_INTERFACE"
```

If you configured routes, check that they point at the VPN interface:

```sh
netstat -rn -f inet
```

Check errors:

```sh
tail -n 50 "$HOME/Library/Logs/vpnwatchdog.err.log"
```

Run one check manually without installing the LaunchAgent:

```sh
VPN_WATCHDOG_ONCE=true ./vpn_watchdog.sh "$VPN_NAME" "$MODE"
```

## Useful Environment Variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `VPN_CMD` | `/opt/homebrew/bin/vpnutil` | Command used to start the VPN. |
| `VPN_INTERFACE` | `ipsec0` | Interface expected to have a VPN IPv4 address. |
| `ROUTE_DESTINATIONS_TEXT` | empty | Optional required routes, separated by spaces. |
| `WATCH_HOST` | empty | Optional host for reachability wakeups. |
| `CHECK_INTERVAL_SECONDS` | `5` | Poll fallback interval. |
| `START_COOLDOWN_SECONDS` | `45` | Minimum seconds between start attempts. |
| `WORK_START` | `0830` | Start of the working-hours window. |
| `WORK_END` | `1900` | End of the working-hours window. |
| `VPN_WATCHDOG_LOG_INFO` | `false` | Set to `true` for info logs. |

## Uninstall

```sh
launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/$LABEL.plist" 2>/dev/null || true

rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -f "$HOME/vpn_watchdog/vpn_watchdog.sh"
rm -rf /tmp/vpnwatchdog.lock
rm -f /tmp/vpnwatchdog.last_start /tmp/vpnwatchdog.status
```
