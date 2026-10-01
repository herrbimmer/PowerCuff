# PowerCuff

Menu-bar app that caps how much power your Mac draws at the wall and shows live power stats.

- **Live**: system load, adapter DC-in, wall estimate with peak, battery flow, source, adapter rating and spare, charge, 2-min history (SMC `PSTR`/`PDTR`, 10 Hz averaged).
- **Cap**: slider 15–150 W, enforced by a closed-loop governor running at 5 Hz (2 Hz when far below the cap).
- **Strict mode**: holds *peaks*, not just the average (adaptive margin from measured ripple, E-cores first, quicker escalation). It never let the wall estimate pass the cap in testing, at the price of undershooting it.
- **Update rate**: footer pill picks how often the shown wattage refreshes (0.5 / 1 / 2 / 5 / 10 s). The governor runs at its own rate whatever is displayed.
- **UI**: Liquid Glass on macOS 26+ (material fallback on 14/15). The ring animates in Core Animation, and the popover avoids `.blur`/`.shadow`, which SwiftUI rasterises on the CPU. About 2 % CPU monitoring, 3 % enforcing and idle.

## How the cap is held

Control signal: the SMC rails (exact, one update per second) corrected at 5 Hz by the SoC energy counters (IOReport "Energy Model", no root), so a burst is seen in ~250 ms. The SoC→system gain (fans, VRM and fabric losses make the machine move ~2× what the SoC counters show) is learned online.

Levers, cheapest first:

1. **Pause battery charging** (helper). Charging is often most of the wall draw on a fresh battery.
2. **Throttle processes**. Per-process energy (`ri_energy_nj`) plus GPU time pick the heaviest. They are duty-cycled with SIGSTOP/SIGCONT (100 ms period, windows staggered so peaks don't stack), and demoted to E-cores when needed. Whole process groups move together when every member is eligible, so helpers and short-lived children are caught. Interactive-shell job leaders are never stopped.
3. **Dim the built-in display** in small steps down to a floor you choose (gear menu → Display dimming). It returns to your level when there is headroom, when the cap is off, on sleep and on quit, and a watchdog restores it even if the app is killed.
4. **Low Power Mode** (helper).
5. **Run from the battery** (helper): switch the adapter input off, so the wall draw is ~0. Never below 15 % battery, and only as a last resort (in strict mode, when an overshoot can't be absorbed).

If the overshoot can't be shed by processes (it is charging or display, say), PowerCuff reports "can't reach" instead of freezing every app for a few watts.

### Wall estimate

DC input (`PDTR`) is converted to a wall figure with a load-dependent brick efficiency (≈85–92 %) plus cable loss, never less than Apple's own `AdapterEfficiencyLoss` figure. It errs high. If you have a wall meter, set the real efficiency in gear menu → Adapter efficiency.

Plane outlets are often limited in current (VA), not watts, and cheap bricks without PFC draw more VA than W. Leave margin.

## Root helper (optional, for hard limits)

Pausing charging, Low Power Mode and running from the battery need root. Gear menu → **Install helper for hard limits…** asks once for an administrator password and installs a launchd daemon (`/Library/PrivilegedHelperTools/com.powercuff.helper`). Everything stays off until the helper is installed.

- The app keeps a lease alive several times a second. If the app quits, crashes, hangs for 3 s or the socket closes, the helper undoes everything.
- It writes only the SMC keys `CHTE` (or `CH0B`+`CH0C`) for charging and `CHIE` (or `CH0J`/`CH0I`) for the adapter, and `pmset powermode`/`lowpowermode`. It saves what it changed and restores exactly that at next start, so it never overwrites another tool's setting.
- It talks only to a binary at `…/PowerCuff.app/Contents/MacOS/PowerCuff`. The bundle is ad-hoc signed, so this is a path check, not a code-signature check.
- Remove it from the same menu (the daemon undoes its changes before it exits).

Not tested on hardware: the SMC *writes* (they need root). The key sizes and values were read on an M1 Max and match what the helper writes; the protocol, lease and crash recovery are covered by tests that run the helper in dry-run.

## Quit = back to normal

Quit, Cmd-Q, logout/shutdown, SIGTERM/INT/HUP and crashes resume every stopped process, drop background QoS and restore the display. SIGKILL is covered by a shell watchdog (which also restores brightness through `PowerCuff --restore-brightness`), and a stale-state sweep runs at launch. Sleep releases everything. After quit the governor refuses to throttle again. Manual fix: `killall -CONT <name>`.

## Limits

- Software cap. Held within ~±2 W in steady state in testing; a sudden load step can overshoot for about a second before it is caught.
- Can't throttle other users' processes or the GPU/display (except by dimming), and can't go below the idle floor.
- Right-click a process in the list to exclude it. System UI processes and shells are excluded by default.
- The SoC counters, per-process energy and brightness use macOS APIs that are private but stable (IOReport, `proc_pid_rusage`, DisplayServices).

Build: `./scripts/build_app.sh [--install]` → `build/PowerCuff.app` (includes the helper). Tests: `swift test`. Debug governor: `POWERCUFF_DEBUG=1 build/PowerCuff.app/Contents/MacOS/PowerCuff`. Screenshots: launch with `POWERCUFF_OPEN_POPOVER=1` to auto-open the popover.

## License

[PolyForm Noncommercial 1.0.0](LICENSE). Free for noncommercial use; commercial use needs separate permission from the licensor.
