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

## Nudge mode: keeping the screen saver away

A second, separate problem. Blocking sleep does not stop the screen saver, and
on a managed Mac the screen saver is the thing that ends a remote session: it
starts, the display locks or the session goes inactive, and the VPN and any
remote shells go with it.

This matters for one specific use: leaving the Mac at home running remote work
(Claude Code sessions, a PagerDuty watch) while you are out for the evening. The
laptop stays home, which is both safer and less to carry, but only if it is
still reachable at 11pm.

### Why caffeinate cannot do this

`caffeinate -d`, `-i`, `-m`, `-s`, `-u`, and every combination of them create
IOKit power assertions. Assertions move the **sleep** timers. The screen saver
runs off a different clock entirely: **HID idle time**, which only real input
events reset.

The two clocks are usually nowhere near each other. On this machine:

```
screen saver idleTime  1200   (20 min, enforced by Jamf)
displaysleep             60   (60 min)
```

The screen saver fires forty minutes before display sleep is even a question,
so an assertion that blocks display sleep blocks a timer that never gets
reached. This is also why Amphetamine ships a mouse-movement feature at all: it
only sets `PreventUserIdleSystemSleep` and `PreventUserIdleDisplaySleep`, and
those were never going to be enough on their own.

The only thing that resets the HID clock is an actual input event. So nudge
mode synthesizes one: it moves the cursor one pixel and immediately moves it
back, once the Mac has genuinely gone idle.

### Use

```sh
keepawake nudge on 7h     # nudge for the next 7 hours
keepawake nudge on        # same, with the default duration (8h)
keepawake nudge on forever
keepawake nudge off
keepawake nudge status
keepawake nudge log
```

It never turns itself on. There is no schedule, no automatic enablement, and
nothing about plugging in a power cable starts it. Most weeks it is not useful,
so it stays off until you ask for it.

### How it turns itself off

Nudge mode **latches off**. This is the one place it deliberately differs from
the sleep block:

| | sleep block | nudge |
| --- | --- | --- |
| unplug AC | held off, resumes on replug | **switched off, stays off** |
| turning it back on | automatic | manual only |

The sleep block is a standing preference, so resuming it on replug is right.
Nudging is something you switched on for one evening. A machine that starts
moving its own cursor again because it found a power outlet in a coffee shop
would be wrong, so any guard that fires ends the session for good.

It switches off on all of:

- **AC power disconnected**, the main one
- **battery below `BATT_FLOOR`**
- **CPU thermally throttled**
- **the duration expiring**

`keepawake status` shows which one fired and how long ago:

```
  nudge      off (auto-off: no-ac, 12m ago)
```

### It only nudges an idle machine

The agent nudges once HID idle passes `NUDGE_IDLE` (default 300s). If you are
sitting at the machine, idle never gets there and nothing touches your cursor.
`NUDGE_IDLE` has to stay comfortably below the screen saver's idle time; the
installer checks yours and warns if it does not.

### The permission, and the failure it causes

Posting an input event requires **Accessibility**, granted per binary. Grant it
to:

```
/usr/local/libexec/keepawake-nudge
```

via `keepawake nudge grant`, or System Settings > Privacy & Security >
Accessibility > `+`, then Cmd+Shift+G and paste the path.

This is worth doing carefully, because without the grant macOS **accepts the
event and silently discards it**. No error, no failed call, nothing in a log.
The switch reads `on` all evening while the screen saver starts exactly on
schedule.

So the agent does not trust the API. After each nudge it re-reads the idle
clock and checks it actually dropped, and reports that outcome:

```
  nudge      on · idle 5m · nudged 3m ago (7) · 5h58m left
  agent      running · Accessibility granted
```

```
  agent      Accessibility not granted · nudges will silently do nothing
```

Reinstalling only rebuilds the helper when its source changed, because macOS
ties the grant to the binary's hash and a needless rebuild would revoke it.

### Why a second process

The nudge agent runs as a LaunchAgent in your GUI session, not in the root
daemon. Synthesized input has to originate inside the logged-in session, and
root is the wrong thing to hold Accessibility. The daemon still owns every
policy decision and publishes `nudge_active`; the agent only decides when the
machine is idle enough to act.

## Install

```sh
sudo ./install.sh
```

The installer verifies that the kernel actually accepts the flag, and tells you
if something refuses it. It also compiles the nudge helper and loads the agent.

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
| `/usr/local/var/keepawake/nudge` | nudge switch, `off` or `on <expiry>`, admin-writable |
| `/usr/local/var/keepawake/nudge.last` | what turned nudge off last, and when |
| `/usr/local/libexec/keepawake-nudge` | the compiled cursor helper, holds Accessibility |
| `/usr/local/libexec/keepawake-nudge-agent` | the user-session agent loop |
| `/Library/LaunchAgents/local.keepawake.nudge.plist` | launchd agent |
| `~/Library/Logs/keepawake-nudge.log` | nudge agent log |
| `~/Library/Application Support/keepawake/agent.json` | what the agent sees, read by `status` |
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

## Tests

```sh
tests/run.sh              # everything
tests/run.sh daemon cli   # just those suites
```

No root, no install, no changes to the machine's power settings. Every suite
runs in a scratch directory. GitHub Actions runs them on `macos-latest` for
every PR, plus shellcheck.

What is covered: both guard decision tables in full, the state file parsers, the
latch-off behavior, duration parsing, and every state the status display can
render. The agent is driven by a stub helper that can pretend to be an
unauthorized binary, so the silent-discard failure is regression-tested rather
than discovered at 9pm.

What is not, because it needs root and real hardware:

- whether `pmset` actually flips `SleepDisabled`. `install.sh` verifies this
  at install time instead, and says so if something refuses.
- whether a synthesized event reaches the window server. That needs a real
  Accessibility grant, so the agent verifies it at runtime by checking the idle
  clock actually moved.
- launchd bootstrap, and behavior on a real unplug.

Two things worth knowing if you add tests. The daemon and CLI can be sourced
without running, by setting `KEEPAWAKE_LIB_ONLY=1`, which is how the decision
tables get tested directly. And `KEEPAWAKE_STATE_DIR`, `KEEPAWAKE_LOG_FILE`,
and `KEEPAWAKE_HELPER` redirect the hardcoded paths; they exist for the tests,
and launchd controls the real processes' environment.

## Notes

- The daemon polls rather than subscribing to power notifications. Polling is a
  few lines of shell and recovers from an external reset within `INTERVAL`
  seconds, which is the property that matters here.
- A hardware alternative worth knowing about: an HDMI/DisplayPort dummy plug on
  a spare port keeps a display attached through the KVM switch, so clamshell
  sleep never triggers. That removes the need for this entirely, at the cost of
  occupying a port.
