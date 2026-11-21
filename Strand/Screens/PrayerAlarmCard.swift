import SwiftUI
import StrandDesign

/// Fajr alarm + prayer buzzes (personal fork addition), shown on the Alarms screen.
///
/// Fajr arms the strap's own alarm at Fajr + N minutes every day, so it fires with the phone locked or
/// NOOP closed. Dhuhr, Asr, Maghrib and Isha each get their own switch and share one offset and buzz
/// count. All of them share the strap's single alarm slot with the weekday smart alarm: whichever comes
/// first is armed (see `AppModel.applySmartAlarm`).
struct PrayerAlarmCard: View {
    @EnvironmentObject private var model: AppModel

    @AppStorage(PrayerAlarm.K.fajrOn) private var fajrOn = false
    @AppStorage(PrayerAlarm.K.fajrOffset) private var fajrOffset = 0
    @AppStorage(PrayerAlarm.K.fajrBuzzes) private var fajrBuzzes = 7
    @AppStorage(PrayerAlarm.K.fajrPause) private var fajrPause = 1
    @AppStorage(PrayerAlarm.K.buzzOffset) private var buzzOffset = 0
    @AppStorage(PrayerAlarm.K.buzzCount) private var buzzCount = 3
    @AppStorage("prayer.buzz.dhuhr.enabled") private var dhuhrOn = false
    @AppStorage("prayer.buzz.asr.enabled") private var asrOn = false
    @AppStorage("prayer.buzz.maghrib.enabled") private var maghribOn = false
    @AppStorage("prayer.buzz.isha.enabled") private var ishaOn = false
    @AppStorage(PrayerAlarm.K.fetchedAt) private var fetchedAt: Double = 0

    @State private var refreshing = false
    @State private var status: String?

    private var anyBuzz: Bool { dhuhrOn || asrOn || maghribOn || ishaOn }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
            fajrCard
            buzzCard
        }
        .onChangeCompat(of: fajrOn) { on in changed(turnedOn: on) }
        .onChangeCompat(of: dhuhrOn) { on in changed(turnedOn: on) }
        .onChangeCompat(of: asrOn) { on in changed(turnedOn: on) }
        .onChangeCompat(of: maghribOn) { on in changed(turnedOn: on) }
        .onChangeCompat(of: ishaOn) { on in changed(turnedOn: on) }
        .onChangeCompat(of: fajrOffset) { _ in model.applySmartAlarm() }
        .onChangeCompat(of: fajrBuzzes) { _ in model.applySmartAlarm() }
        .onChangeCompat(of: fajrPause) { _ in model.applySmartAlarm() }
        .onChangeCompat(of: buzzOffset) { _ in model.applySmartAlarm() }
        .onChangeCompat(of: buzzCount) { _ in model.applySmartAlarm() }
    }

    // MARK: Fajr

    private var fajrCard: some View {
        StrandCard(padding: 20, tint: fajrOn ? StrandPalette.accent : nil) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Before dawn").strandOverline()
                    HStack(spacing: 10) {
                        Image(systemName: "sunrise.fill")
                            .foregroundStyle(StrandPalette.accent)
                            .accessibilityHidden(true)
                        Text("Fajr alarm")
                            .font(StrandFont.title2)
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                }
                toggleRow("Wake me at Fajr",
                          detail: "Armed on the strap every day at Fajr plus your offset, so it buzzes even with the phone locked or NOOP closed. Times use the UAE method (18.2°) at your location.",
                          isOn: $fajrOn)
                if fajrOn {
                    Divider().overlay(StrandPalette.hairline)
                    stepperRow("Minutes after Fajr", value: $fajrOffset, range: 0...120, step: 5, unit: "min")
                    stepperRow("Buzzes", value: $fajrBuzzes, range: 1...20, step: 1, unit: nil)
                    stepperRow("Pause between buzzes", value: $fajrPause, range: 1...7, step: 1,
                               unit: nil, display: { "\($0 * 240) ms" })
                    if let next = PrayerAlarm.nextFajr() {
                        Text("Next Fajr alarm: \(stamp(next)).")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    Button {
                        PrayerAlarm.scheduleTest(in: 60)
                        model.applySmartAlarm()
                        status = String(localized: "Test armed: the strap buzzes in about a minute, then the real alarm is re-armed.")
                        // Re-arm the real alarm after the test even if the fired event is missed.
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 95 * 1_000_000_000)
                            model.applySmartAlarm()
                        }
                    } label: {
                        Text("Test in 1 minute")
                    }
                    .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))
                }
                timesFooter
            }
        }
    }

    // MARK: Prayer buzzes

    private var buzzCard: some View {
        StrandCard(padding: 20, tint: anyBuzz ? StrandPalette.accent : nil) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Through the day").strandOverline()
                    HStack(spacing: 10) {
                        Image(systemName: "bell.badge.fill")
                            .foregroundStyle(StrandPalette.accent)
                            .accessibilityHidden(true)
                        Text("Prayer buzzes")
                            .font(StrandFont.title2)
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                }
                Text("A short buzz on the strap at each prayer you switch on. Fajr has its own alarm above.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                prayerToggle(.dhuhr, isOn: $dhuhrOn)
                prayerToggle(.asr, isOn: $asrOn)
                prayerToggle(.maghrib, isOn: $maghribOn)
                prayerToggle(.isha, isOn: $ishaOn)
                if anyBuzz {
                    Divider().overlay(StrandPalette.hairline)
                    stepperRow("Minutes after the adhan", value: $buzzOffset, range: 0...60, step: 1, unit: "min")
                    stepperRow("Buzzes", value: $buzzCount, range: 1...20, step: 1, unit: nil)
                }
            }
        }
    }

    private func prayerToggle(_ p: Prayer, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(p.rawValue)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
            if let t = PrayerAlarm.today()[p] {
                Text(clock(t))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden().toggleStyle(.switch).tint(StrandPalette.accent)
                .accessibilityLabel(p.rawValue)
        }
        .frame(minHeight: 36)
    }

    // MARK: Shared rows

    private func toggleRow(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(detail)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden().toggleStyle(.switch).tint(StrandPalette.accent)
                .accessibilityLabel(title)
        }
        .frame(minHeight: 42)
    }

    private func stepperRow(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int,
                            unit: String?, display: ((Int) -> String)? = nil) -> some View {
        let clamped = Binding<Int>(
            get: { min(max(value.wrappedValue, range.lowerBound), range.upperBound) },
            set: { value.wrappedValue = min(max($0, range.lowerBound), range.upperBound) })
        let label = display?(clamped.wrappedValue)
            ?? (unit.map { "\(clamped.wrappedValue) \($0)" } ?? "\(clamped.wrappedValue)")
        return Stepper(value: clamped, in: range, step: step) {
            HStack {
                Text(title)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Text(label)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        }
        .accessibilityLabel(title)
    }

    @ViewBuilder private var timesFooter: some View {
        if fajrOn || anyBuzz {
            Divider().overlay(StrandPalette.hairline)
            VStack(alignment: .leading, spacing: 6) {
                Text(timesSourceLine)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if let status {
                    Text(status)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    Task { await refresh(askPermission: true) }
                } label: {
                    Text(refreshing ? "Updating prayer times…" : "Update prayer times now")
                }
                .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))
                .disabled(refreshing)
            }
        }
    }

    private var timesSourceLine: String {
        guard fetchedAt > 0 else { return String(localized: "Prayer times have not been downloaded yet.") }
        let place: String
        switch PrayerAlarm.locationSource {
        case "gps": place = String(localized: "your location")
        case "last": place = String(localized: "your last known location")
        default: place = String(localized: "Sharjah (location unavailable)")
        }
        let when = Date(timeIntervalSince1970: fetchedAt).formatted(date: .abbreviated, time: .shortened)
        return String(localized: "Times for \(place), updated \(when). Cached for this month and next, so the alarm works offline.")
    }

    // MARK: Actions

    private func changed(turnedOn: Bool) {
        if turnedOn && (PrayerAlarm.cache.isEmpty || fetchedAt == 0) {
            Task { await refresh(askPermission: true) }
        } else if turnedOn {
            Task {
                await PrayerAlarm.refreshIfNeeded(askPermission: true)
                model.applySmartAlarm()
            }
        }
        model.applySmartAlarm()
    }

    @MainActor
    private func refresh(askPermission: Bool) async {
        refreshing = true
        let ok = await PrayerAlarm.refreshIfNeeded(force: true, useLocation: true, askPermission: askPermission)
        refreshing = false
        status = ok ? String(localized: "Prayer times updated.")
                    : String(localized: "Couldn't download prayer times. Check your connection and try again.")
        model.applySmartAlarm()
    }

    private func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE d MMM jj:mm")
        return f.string(from: d)
    }

    private func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("jj:mm")
        return f.string(from: d)
    }
}
