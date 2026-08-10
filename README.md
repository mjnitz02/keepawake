# keepawake

A small Amphetamine replacement for one specific problem: a MacBook running
lid-closed on a KVM that briefly drops the external display, causing macOS to
force a sleep.

## The actual problem

macOS records why it slept. On this machine:

```
2026-08-10 09:33:32 Sleep  Entering Sleep state due to 'Clamshell Sleep':TCPKeepAlive=active Using AC (Charge:80%)
```

`Clamshell Sleep`, on AC power. That is the KVM switch. When the KVM hands the
display and USB over to another machine, macOS sees "lid closed, external
display gone" and forces sleep.

This matters because it rules out the usual advice:

- **`caffeinate` and every app built on it** (KeepingYouAwake, Lungo, and any
  launchd job running `caffeinate -s -d`) create IOKit power assertions.
  Assertions block *idle* sleep. They do not block `Clamshell Sleep`.
- **Idle sleep is already off here.** `pmset -g` shows `sleep 0` on both AC and
  battery, so an idle-sleep blocker has nothing left to do.

The one supported knob that suppresses the clamshell path is the kernel's
`SleepDisabled` flag, set with `sudo pmset -a disablesleep 1`.

The reason that alone isn't enough: this Mac is Jamf-enrolled
(`datarobot.jamfcloud.com`), and management tooling periodically rewrites power
settings. A one-time `pmset` change gets flattened.

## What this does

A root LaunchDaemon holds `SleepDisabled` in the state you asked for and puts it
back within a few seconds if anything else changes it. It logs each time that
happens, so you get a record of the sweeps rather than a mystery.

The risk of `disablesleep` is a laptop that never sleeps in a bag, so the daemon
releases the flag automatically when:

- **AC power is disconnected**. The main guard. Unplugging to travel is
  enough; you do not have to remember to turn anything off.
- **Battery falls below `BATT_FLOOR`** (default 30%), even if AC is attached
  but not actually charging.
- **The CPU is thermally throttled** below `THERM_FLOOR` (default 50%).

Guards fail open toward *sleeping*: if the daemon can't read power state, it
releases the block. Stopping or uninstalling the daemon restores
`SleepDisabled=0` on the way out.

### Packing up

`SleepDisabled=1` blocks deliberate sleep too, not just clamshell sleep. That
creates one edge case worth handling: unplug the power, shut the lid inside the
poll window, and the lid-close event gets swallowed while the flag is still
held. With `sleep 0` configured on battery, nothing would retry it, and the
machine goes in a bag awake.

So when the daemon sees AC power disappear **while the lid is already shut**, it
reads that as packing up, releases the flag, and calls `pmset sleepnow` once to
make sure the machine actually goes down. Unplugging with the lid open does not
trigger this, since that is someone still using the machine.

The net effect: unplug, close, go. No command required, in either order.

## Install

```sh
sudo ./install.sh
```

The installer verifies that the kernel actually accepts the flag, and tells you
if something refuses it.

## Use

```sh
keepawake on        # block clamshell sleep (while on AC)
keepawake off       # hand sleep back to macOS
keepawake status    # one-shot state: switch, guards, kernel flag, daemon, log
keepawake watch     # same view, live-refreshing every 2s
keepawake why       # what the Mac last slept for, from the power log
keepawake log       # follow the daemon log
```

`keepawake status` is the answer to "is it actually on right now":

```
KeepAwake  ● ACTIVE   clamshell sleep is blocked

  switch     on
  guard      holding the flag
  power      AC power · 80%
  kernel     SleepDisabled=1
  daemon     loaded (pid 4812)
  updated    3s ago
```

There are four headline states, and the distinction between the middle two is
the part a simple on/off indicator would hide:

| Headline | Meaning |
| --- | --- |
| `● ACTIVE` | the block is held; clamshell sleep cannot fire |
| `● HELD OFF` | you asked for it, but a guard released it (unplugged, low battery, hot) |
| `○ OFF` | switched off; normal sleep |
| `● STALE` | the daemon has stopped reporting, so trust nothing else on screen |

`keepawake why` is the useful one when something still sleeps unexpectedly. It
prints the reason string straight from `pmset -g log`, which tells you whether
you're fighting clamshell sleep, idle sleep, or something else entirely.

## Layout

| Path | What |
| --- | --- |
| `/usr/local/libexec/keepawake-daemon` | the root daemon loop |
| `/usr/local/bin/keepawake` | CLI |
| `/Library/LaunchDaemons/local.keepawake.plist` | launchd job |
| `/usr/local/var/keepawake/state` | `on` / `off`, admin-writable |
| `/usr/local/var/keepawake/config` | interval and guard thresholds |
| `/usr/local/var/keepawake/status.json` | what the daemon is doing, read by `status` |
| `/usr/local/var/log/keepawake.log` | daemon log |

The state file is `root:admin` mode 664 so `keepawake on|off` works without sudo.
The daemon reads nothing from it but `on` or `off`, so the worst an admin user
can do through it is toggle sleep, which they could already do with `pmset`.

## Uninstall

```sh
sudo ./uninstall.sh
```

Re-enables sleep and removes the daemon, CLI, and state.

## Tuning

Edit `/usr/local/var/keepawake/config`, then:

```sh
sudo launchctl kickstart -k system/local.keepawake
```

## Notes

- The daemon polls rather than subscribing to power notifications. Polling is a
  few lines of shell and recovers from an external reset within `INTERVAL`
  seconds, which is the property that matters here.
- A hardware alternative worth knowing about: an HDMI/DisplayPort dummy plug on
  a spare port keeps a display attached through the KVM switch, so clamshell
  sleep never triggers. That removes the need for this entirely, at the cost of
  occupying a port.
