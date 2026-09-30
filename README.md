# PowerCuff

Menu-bar app that caps how much power your Mac draws (approximately) and shows live power stats.

- Live: system load, adapter DC-in, wall estimate, battery flow, source, adapter rating, charge, 2-min history (SMC `PSTR`/`PDTR`, 10 Hz averaged).
- Cap: slider 15–150 W. A closed-loop governor duty-cycles (SIGSTOP/SIGCONT, 100 ms period) your own heaviest processes to hold draw under the cap; background-QoS demotion is a last resort.
- Update rate: footer pill picks how often the shown wattage refreshes (0.5 / 1 / 2 / 5 / 10 s; default 1 s). The SMC publishes one new reading per second, so 0.5 s only cuts latency; slower rates show the mean over the interval. The governor always runs at a fixed 1 Hz, whatever is displayed.
- UI: Liquid Glass on macOS 26+ (material fallback on 14/15). The ring animates in Core Animation (render server) and the popover avoids `.blur`/`.shadow`, which SwiftUI rasterises on the CPU: popover open ≈ 3 % CPU, closed ≈ 2 %.
- Quit = back to normal: Quit, Cmd-Q, logout/shutdown, SIGTERM/INT/HUP and crashes resume every stopped process and drop background QoS; sleep also releases everything. SIGKILL is covered by a shell watchdog, and a stale-state sweep runs at launch. After quit the governor refuses to throttle again (no late-tick race). PowerCuff changes no system power setting (no pmset, no SMC writes), so there is nothing else to restore. Manual fix: `killall -CONT <name>`.

Limits: software cap, ±5 W. Can't throttle GPU/display/other users' processes; can't go below the idle floor. Right-click a process in the list to exclude it.

Build: `./scripts/build_app.sh [--install]` → `build/PowerCuff.app`. Tests: `swift test`. Debug governor: `POWERCUFF_DEBUG=1 build/PowerCuff.app/Contents/MacOS/PowerCuff`. Screenshots: launch with `POWERCUFF_OPEN_POPOVER=1` to auto-open the popover.

## License

[PolyForm Noncommercial 1.0.0](LICENSE). Free for noncommercial use; commercial use needs separate permission from the licensor.
