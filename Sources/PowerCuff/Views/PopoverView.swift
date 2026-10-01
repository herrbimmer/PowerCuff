import SwiftUI
import Charts
import PowerCuffCore

extension PowerModel {
    var watts: Double { snapshot?.controlledW ?? 0 }

    var tint: Color {
        guard enabled, snapshot != nil else { return Palette.accent }
        return Palette.level(watts: watts, cap: capW)
    }

    /// Gauge range: the cap sits about two thirds round the ring, so "how close am I" reads at a glance.
    var scaleMax: Double {
        let m = max(capW * 1.5, watts * 1.1, 30)
        return (m / 10).rounded(.up) * 10
    }

    /// Chart range fits the recent data instead of the gauge scale.
    var chartMax: Double {
        let m = max(capW * 1.2, (history.map(\.watts).max() ?? 0) * 1.15, 30)
        return (m / 10).rounded(.up) * 10
    }

    var motion: Animation { RefreshRate.animation(refreshSeconds) }
}

struct PopoverView: View {
    let model: PowerModel

    var body: some View {
        VStack(spacing: 8) {
            HeaderView(model: model)
            if model.snapshot == nil {
                Text("No battery data available on this Mac.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 60)
                    .glassCard()
            } else {
                GlassGroup(spacing: 8) {
                    VStack(spacing: 8) {
                        HeroCard(model: model)
                        StatusBanner(model: model)
                        TilesGrid(model: model)
                        HistoryCard(model: model)
                        ProcessListView(model: model)
                    }
                }
            }
            FooterView(model: model)
        }
        .padding(12)
        .frame(width: 364)
        .background { AmbientBackground(tint: model.tint) }
        .animation(.smooth(duration: 0.3), value: model.snapshot == nil)
    }
}

// MARK: - Header

private struct HeaderView: View {
    let model: PowerModel

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 0) {
                Text("PowerCuff").font(.headline)
                Text(model.enabled ? (model.strict ? "Strict cap active" : "Cap active") : "Monitoring only")
                    .font(.caption).foregroundStyle(.secondary)
                    .contentTransition(.interpolate)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { model.enabled }, set: { model.setEnabled($0) }))
                .toggleStyle(.switch).labelsHidden().tint(model.tint)
        }
        .padding(.horizontal, 4)
        .animation(.smooth(duration: 0.25), value: model.enabled)
    }
}

// MARK: - Gauge + cap slider

private struct HeroCard: View {
    let model: PowerModel

    var body: some View {
        VStack(spacing: 8) {
            GaugeView(watts: model.watts, cap: model.capW, scaleMax: model.scaleMax, tint: model.tint,
                      caption: (model.snapshot?.onAC ?? true) ? "from wall (est.)" : "system load",
                      duration: min(max(model.refreshSeconds * 0.9, 0.3), 0.9))
            CapControl(model: model)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .glassCard(cornerRadius: 26, tint: model.tint.opacity(0.10))
    }
}

private struct CapControl: View {
    let model: PowerModel

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Max power draw").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(model.capW)) W")
                    .font(.system(.title3, design: .rounded, weight: .semibold)).monospacedDigit()
                    .contentTransition(.numericText(value: model.capW))
                    .animation(.smooth(duration: 0.2), value: model.capW)
            }
            Slider(value: Binding(get: { model.capW }, set: { model.setCap($0) }),
                   in: PowerModel.capRange, step: 1)
                .tint(model.tint)
            ChipRow(model: model)
            HStack(spacing: 6) {
                Image(systemName: "scope").font(.caption).foregroundStyle(.secondary)
                Text("Strict").font(.caption.weight(.medium))
                Text("hold peaks, not just the average").font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                Spacer()
                Toggle("", isOn: Binding(get: { model.strict }, set: { model.setStrict($0) }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden().tint(model.tint)
            }
            .padding(.top, 2)
        }
    }
}

private struct ChipRow: View {
    let model: PowerModel

    var body: some View {
        GlassGroup(spacing: 6) {
            HStack(spacing: 6) {
                ForEach([30, 45, 60, 96], id: \.self) { w in
                    chip("\(w)W", active: Int(model.capW) == w) { model.setCap(Double(w)) }
                }
                if let rated = model.snapshot?.adapterRatedW {
                    let safe = (rated * 0.95).rounded()
                    chip("Charger \(Int(safe))W", active: Int(model.capW) == Int(safe)) { model.setCap(safe) }
                }
            }
            .animation(.smooth(duration: 0.25), value: model.capW)
        }
    }

    private func chip(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.caption.weight(active ? .semibold : .regular)).monospacedDigit()
                .padding(.horizontal, 10).padding(.vertical, 5)
                .glass(in: Capsule(), tint: active ? Palette.accent.opacity(0.55) : nil, interactive: true)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Status

private struct StatusBanner: View {
    let model: PowerModel

    private var content: (icon: String, text: String, color: Color) {
        let cap = Int(model.capW)
        switch model.report.state {
        case .off: return ("pause.circle", "Cap is off. Flip the switch to enforce \(cap) W.", .secondary)
        case .noData: return ("exclamationmark.triangle", "No power data.", Palette.warn)
        case .underCap: return ("checkmark.circle.fill", "Under the cap. Nothing throttled.", Palette.ok)
        case .limiting(let n):
            let lv = model.report.levers
            var parts: [String] = []
            if n > 0 { parts.append("\(n) process\(n == 1 ? "" : "es") throttled") }
            if lv.chargePaused { parts.append("charging paused") }
            if let d = lv.dimmedTo { parts.append("display \(Int((d * 100).rounded()))%") }
            if lv.lowPower { parts.append("Low Power Mode") }
            if lv.onBattery { parts.append("running from battery") }
            let what = parts.isEmpty ? "limiting" : parts.joined(separator: " · ")
            return ("gauge.with.dots.needle.67percent", "Holding \(cap) W: \(what).", Palette.accent)
        case .cannotReach:
            let charging = model.snapshot.map { $0.onAC && $0.batteryW > 2 ? Int($0.batteryW.rounded()) : 0 } ?? 0
            let why = charging > 0 ? "battery charging takes \(charging) W" : "remaining load (display, GPU, idle floor) isn't throttleable"
            let hint = model.helperInstalled ? "" : " Install the helper (⚙) to pause charging."
            return ("exclamationmark.triangle.fill", "Can't reach \(cap) W: \(why).\(hint)", Palette.hot)
        }
    }

    var body: some View {
        let c = content
        Label {
            Text(c.text).contentTransition(.interpolate)
        } icon: {
            Image(systemName: c.icon).contentTransition(.symbolEffect(.replace))
        }
        .font(.caption).foregroundStyle(c.color)
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .glassCard(cornerRadius: 16, tint: c.color.opacity(0.14))
        .animation(.smooth(duration: 0.35), value: model.report.state)
    }
}

// MARK: - Tiles

private struct TilesGrid: View {
    let model: PowerModel

    var body: some View {
        if let s = model.snapshot {
            GlassGroup(spacing: 8) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    Tile(title: "Source", value: s.onAC ? "AC adapter" : "Battery",
                         sub: s.onAC ? (s.adapterName ?? "Unknown") : "unplugged")
                    Tile(title: "Adapter", value: s.adapterRatedW.map { "\(Int($0)) W" } ?? "—",
                         sub: adapterSub(s))
                    Tile(title: "Wall (est.)", value: s.onAC ? fmt(s.wallW) : "—",
                         sub: s.onAC ? "peak \(Int(s.peakW.rounded())) W" : nil,
                         tint: s.onAC && s.adapterRatedW != nil && s.dcInW > (s.adapterRatedW ?? 0) ? Palette.hot : .primary)
                    Tile(title: "System", value: fmt(s.systemW), sub: "SoC + display")
                    Tile(title: batteryTitle(s), value: fmt(abs(s.batteryW)), sub: batterySub(s),
                         tint: s.batteryW < -0.5 ? Palette.warn : .primary)
                    Tile(title: "Charge", value: "\(s.percent)%", sub: chargeSub(s))
                }
            }
        }
    }

    private func fmt(_ w: Double) -> String { String(format: "%.1f W", w) }

    private func adapterSub(_ s: PowerSnapshot) -> String? {
        guard let v = s.adapterVolts else { return nil }
        let volts = String(format: "%.0f V", v)
        return s.adapterSpareW.map { "\(volts) · \(Int($0.rounded())) spare" } ?? volts
    }

    private func batteryTitle(_ s: PowerSnapshot) -> String {
        s.batteryW > 0.5 ? "Charging" : (s.batteryW < -0.5 ? "Battery draw" : "Battery")
    }

    private func batterySub(_ s: PowerSnapshot) -> String {
        if s.batteryW > 0.5 { return "into battery" }
        if s.batteryW < -0.5 { return "powering Mac" }
        return s.fullyCharged ? "full" : "idle / held"
    }

    private func chargeSub(_ s: PowerSnapshot) -> String {
        guard let m = s.minutesRemaining else { return s.isCharging ? "charging" : (s.onAC ? "plugged in" : " ") }
        let t = "\(m / 60)h \(m % 60)m"
        return s.isCharging ? "\(t) to full" : "\(t) left"
    }
}

// MARK: - History

private struct HistoryCard: View {
    let model: PowerModel

    var body: some View {
        let hist = model.history
        let end = hist.last?.date ?? Date()
        VStack(alignment: .leading, spacing: 4) {
            Text("Last 2 minutes").font(.caption2).foregroundStyle(.secondary)
            Chart {
                ForEach(hist) { p in
                    AreaMark(x: .value("t", p.date), y: .value("W", p.watts))
                        .foregroundStyle(LinearGradient(colors: [model.tint.opacity(0.35), model.tint.opacity(0.02)],
                                                        startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("t", p.date), y: .value("W", p.watts))
                        .foregroundStyle(model.tint)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
                RuleMark(y: .value("Cap", model.capW))
                    .foregroundStyle(Palette.hot.opacity(0.85))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            .chartXScale(domain: end.addingTimeInterval(-120)...end)
            .chartYScale(domain: 0...model.chartMax)
            .chartXAxis(.hidden)
            .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) }
            .chartPlotStyle { $0.clipped() }
            .frame(height: 48)
            .animation(.smooth(duration: 0.35), value: model.capW)
            .animation(.smooth(duration: 0.6), value: model.chartMax)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 18)
    }
}

// MARK: - Processes

struct ProcessListView: View {
    let model: PowerModel
    private let rows = 3

    var body: some View {
        let procs = Array(model.report.procs.filter { $0.name != "PowerCuff" }.prefix(rows))
        VStack(alignment: .leading, spacing: 3) {
            Text("Top consumers").font(.caption2).foregroundStyle(.secondary)
            // Fixed row count so the popover never changes height.
            ForEach(0..<rows, id: \.self) { i in
                if i < procs.count { row(procs[i]) } else { Text(" ").font(.callout).frame(height: 20) }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 18)
    }

    private func row(_ p: ProcRow) -> some View {
        HStack(spacing: 6) {
            Text(p.name).lineLimit(1)
            if p.background {
                Image(systemName: "leaf.fill").font(.caption2).foregroundStyle(Palette.ok)
            }
            if p.duty < 0.98 {
                Label("\(Int(p.duty * 100))%", systemImage: "pause.fill")
                    .font(.caption2).foregroundStyle(Palette.accent)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Palette.accent.opacity(0.18), in: Capsule())
                    .transition(.scale.combined(with: .opacity))
            }
            if p.excluded {
                Image(systemName: "shield.fill").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text(String(format: "%.1f W", p.estWatts)).font(.caption).foregroundStyle(.secondary).monospacedDigit()

        }
        .font(.callout)
        .frame(height: 20)
        .contextMenu {
            Button(p.excluded ? "Allow throttling \(p.name)" : "Never throttle \(p.name)") {
                model.toggleExcluded(p.name)
            }
        }
    }
}

// MARK: - Footer

private struct FooterView: View {
    let model: PowerModel

    @ViewBuilder
    private var helperItems: some View {
        switch model.report.helper {
        case .notInstalled:
            Button("Install helper for hard limits…") { model.installHelper() }.disabled(model.helperBusy)
        case .unreachable:
            Text("Helper installed, not responding")
            Button("Reinstall helper…") { model.installHelper() }.disabled(model.helperBusy)
            Button("Remove helper…") { model.uninstallHelper() }.disabled(model.helperBusy)
        case .outdated:
            Button("Update helper…") { model.installHelper() }.disabled(model.helperBusy)
            Button("Remove helper…") { model.uninstallHelper() }.disabled(model.helperBusy)
        case .connected(let caps):
            Toggle("Pause charging when over the cap", isOn: Binding(get: { model.pauseCharging }, set: { model.setPauseCharging($0) }))
                .disabled(!caps.charge)
            Toggle("Low Power Mode when over the cap", isOn: Binding(get: { model.lowPowerMode }, set: { model.setLowPowerMode($0) }))
                .disabled(!caps.lowPower)
            Toggle("Run from battery as a last resort", isOn: Binding(get: { model.batteryBackstop }, set: { model.setBatteryBackstop($0) }))
                .disabled(!caps.adapter)
            Button("Remove helper…") { model.uninstallHelper() }.disabled(model.helperBusy)
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Menu("Display dimming") {
                    Picker("Dim no lower than", selection: Binding(get: { model.dimFloor }, set: { model.setDimFloor($0) })) {
                        Text("Never dim").tag(0.0)
                        ForEach([0.7, 0.5, 0.4, 0.3, 0.2], id: \.self) { Text("\(Int($0 * 100))%").tag($0) }
                    }
                    .pickerStyle(.inline)
                }
                Menu("Adapter efficiency") {
                    Picker("Wall estimate", selection: Binding(get: { model.efficiency }, set: { model.setEfficiency($0) })) {
                        Text("Auto (conservative)").tag(0.0)
                        ForEach([0.85, 0.88, 0.90, 0.92, 0.94], id: \.self) { Text("\(Int($0 * 100))%").tag($0) }
                    }
                    .pickerStyle(.inline)
                }
                Divider()
                helperItems
                Divider()
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                Toggle("Show in Dock", isOn: Binding(get: { model.showInDock }, set: { model.setShowInDock($0) }))
                Divider()
                Button("Quit PowerCuff (releases all limits)") { model.quit() }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "gearshape")
                    .padding(8)
                    .glass(in: Circle(), interactive: true)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()

            Menu {
                Section("Sensor refreshes once per second") {
                    Picker("Update rate", selection: Binding(get: { model.refreshSeconds }, set: { model.setRefresh($0) })) {
                        ForEach(RefreshRate.options, id: \.self) { s in
                            Text(s == 1 ? "1 s (default)" : RefreshRate.label(s)).tag(s)
                        }
                    }
                    .pickerStyle(.inline)
                }
            } label: {
                Label(RefreshRate.label(model.refreshSeconds), systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption).monospacedDigit()
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .glass(in: Capsule(), interactive: true)
                    .contentTransition(.numericText())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("Update rate of the displayed wattage")

            Spacer()
            Text(model.strict ? "Strict · peaks held under the cap" : "Software cap · ~±2 W")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.top, 2)
    }
}
