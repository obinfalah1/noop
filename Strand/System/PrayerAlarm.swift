import Foundation
#if canImport(CoreLocation)
import CoreLocation
#endif

/// Fajr alarm + prayer buzzes on the strap (personal fork addition).
///
/// The strap has ONE alarm slot. `AppModel.applySmartAlarm()` arms whichever comes first: the weekday
/// smart alarm, the next Fajr + offset, or the next enabled prayer buzz. When the alarm fires, the
/// strap's fired event (and every reconnect, foreground and the daily timer) re-runs that funnel, so the
/// slot moves on to the next occurrence. This file holds the settings, the cached times and the fetch;
/// it never talks to the strap itself.
enum PrayerAlarm {
    // MARK: Settings keys (plain UserDefaults, bound by @AppStorage in PrayerAlarmCard)

    enum K {
        static let fajrOn = "prayer.fajr.enabled"
        static let fajrOffset = "prayer.fajr.offsetMin"        // 0...120
        static let fajrBuzzes = "prayer.fajr.buzzCount"        // 1...20
        static let fajrPause = "prayer.fajr.pauseSteps"        // 1...7 (× 240 ms)
        static let buzzOffset = "prayer.buzz.offsetMin"        // 0...60, shared by the four prayers
        static let buzzCount = "prayer.buzz.buzzCount"         // 1...20, shared by the four prayers
        static let cache = "prayer.cache.v1"
        static let fetchedAt = "prayer.cache.fetchedAt"
        static let coords = "prayer.cache.coords"
        static let source = "prayer.cache.source"              // "gps" / "last" / "sharjah"
        static let lastLat = "prayer.lastLat"
        static let lastLon = "prayer.lastLon"
        static let armedSource = "prayer.armedSource"          // what the strap slot holds now
        static let armedCustom = "prayer.armedCustomPattern"   // the last arm used a non-stock pattern
        static let armedAt = "prayer.armedAt"                  // epoch seconds the strap slot is armed for
        static let lastFetchAttempt = "prayer.lastFetchAttempt"
        static let testUntil = "prayer.testUntil"              // a pending 1-minute test buzz
        static func buzzOn(_ p: Prayer) -> String { "prayer.buzz.\(p.rawValue.lowercased()).enabled" }
    }

    private static var d: UserDefaults { .standard }

    static var fajrEnabled: Bool { d.bool(forKey: K.fajrOn) }
    static var fajrOffsetMinutes: Int { min(max(d.integer(forKey: K.fajrOffset), 0), 120) }
    static var fajrBuzzCount: Int { let v = d.integer(forKey: K.fajrBuzzes); return v == 0 ? 7 : min(max(v, 1), 20) }
    static var fajrPauseSteps: Int { let v = d.integer(forKey: K.fajrPause); return v == 0 ? 1 : min(max(v, 1), 7) }
    static var buzzOffsetMinutes: Int { min(max(d.integer(forKey: K.buzzOffset), 0), 60) }
    static var buzzCount: Int { let v = d.integer(forKey: K.buzzCount); return v == 0 ? 3 : min(max(v, 1), 20) }
    static func buzzEnabled(_ p: Prayer) -> Bool { d.bool(forKey: K.buzzOn(p)) }
    /// Fajr only in this build: the Dhuhr–Isha buzzes never take the slot, even if switched on earlier.
    static var enabledBuzzPrayers: [Prayer] { [] }

    /// True when anything here wants the strap slot.
    static var anyEnabled: Bool { fajrEnabled || !enabledBuzzPrayers.isEmpty || pendingTest != nil }

    // MARK: Cache

    static var cache: [String: [String: Int]] {
        guard let data = d.data(forKey: K.cache),
              let m = try? JSONDecoder().decode([String: [String: Int]].self, from: data) else { return [:] }
        return m
    }

    static var fetchedAt: Date? {
        let t = d.double(forKey: K.fetchedAt)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    static var locationSource: String? { d.string(forKey: K.source) }

    // MARK: The next occurrence

    /// What should hold the strap slot next from this module, with the pattern to arm it with.
    struct Plan: Equatable {
        let date: Date
        let label: String          // "Fajr", "Asr", "Test"
        let haptics: [UInt8]
    }

    /// A pending test buzz, if one is due in the future.
    static var pendingTest: Date? {
        let t = d.double(forKey: K.testUntil)
        guard t > 0 else { return nil }
        let at = Date(timeIntervalSince1970: t)
        return at > Date() ? at : nil
    }

    static func nextPlan(after now: Date = Date()) -> Plan? {
        var plans: [Plan] = []
        if let t = pendingTest, t > now {
            plans.append(Plan(date: t, label: "Test",
                              haptics: PrayerTimes.hapticPattern(buzzCount: fajrBuzzCount, pauseSteps: fajrPauseSteps)))
        }
        let c = cache
        if fajrEnabled, let f = PrayerTimes.next(in: c, prayers: [.fajr], offsetMinutes: fajrOffsetMinutes, after: now) {
            plans.append(Plan(date: f.date, label: "Fajr",
                              haptics: PrayerTimes.hapticPattern(buzzCount: fajrBuzzCount, pauseSteps: fajrPauseSteps)))
        }
        let buzz = enabledBuzzPrayers
        if !buzz.isEmpty, let b = PrayerTimes.next(in: c, prayers: buzz, offsetMinutes: buzzOffsetMinutes, after: now) {
            plans.append(Plan(date: b.date, label: b.prayer.rawValue,
                              haptics: PrayerTimes.hapticPattern(buzzCount: buzzCount, pauseSteps: 1)))
        }
        return plans.min { $0.date < $1.date }
    }

    /// Next Fajr + offset only, for the card's readout.
    static func nextFajr(after now: Date = Date()) -> Date? {
        PrayerTimes.next(in: cache, prayers: [.fajr], offsetMinutes: fajrOffsetMinutes, after: now)?.date
    }

    /// Today's times (local day), for the card's readout.
    static func today(_ now: Date = Date()) -> [Prayer: Date] {
        guard let t = cache[PrayerTimes.dayKey(now)] else { return [:] }
        var out: [Prayer: Date] = [:]
        for p in Prayer.allCases { if let s = t[p.rawValue] { out[p] = Date(timeIntervalSince1970: Double(s)) } }
        return out
    }

    // MARK: Test buzz

    static func scheduleTest(in seconds: TimeInterval = 60) {
        d.set(Date().addingTimeInterval(seconds).timeIntervalSince1970, forKey: K.testUntil)
    }

    // MARK: Fetch

    @MainActor private static var fetching = false

    /// Refresh the cached times when they are missing, running low or a week old (or always, with
    /// `force`). `useLocation` asks the phone for a fresh fix (only meaningful in the foreground);
    /// `askPermission` may show the location prompt (only when the user just switched an alarm on).
    /// Returns true when new times were stored. Never throws; a failure keeps the old cache.
    @MainActor
    @discardableResult
    static func refreshIfNeeded(force: Bool = false, useLocation: Bool = true, askPermission: Bool = false) async -> Bool {
        let now = Date()
        if !force {
            guard anyEnabled, PrayerTimes.needsRefresh(cache: cache, fetchedAt: fetchedAt, now: now) else { return false }
            // Don't hammer the API from every re-arm when offline: one attempt per 30 minutes.
            let last = d.double(forKey: K.lastFetchAttempt)
            if last > 0, now.timeIntervalSince1970 - last < 30 * 60 { return false }
        }
        guard !fetching else { return false }
        fetching = true
        defer { fetching = false }
        d.set(now.timeIntervalSince1970, forKey: K.lastFetchAttempt)

        let (lat, lon, source) = await coordinates(useLocation: useLocation, askPermission: askPermission)
        let cal = Calendar.current
        var fresh: [String: [String: Int]] = [:]
        for offset in 0...1 {
            guard let m = cal.date(byAdding: .month, value: offset, to: now) else { continue }
            let c = cal.dateComponents([.year, .month], from: m)
            guard let y = c.year, let mo = c.month,
                  let url = PrayerTimes.calendarURL(year: y, month: mo, latitude: lat, longitude: lon) else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = 20
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200 else { continue }
            fresh.merge(PrayerTimes.parseCalendar(data)) { _, new in new }
        }
        guard !fresh.isEmpty else { return false }
        var merged = cache.merging(fresh) { _, new in new }
        // Keep two days back (an alarm armed just before midnight still finds its day); drop the rest.
        if let keep = cal.date(byAdding: .day, value: -2, to: now) {
            let keepKey = PrayerTimes.dayKey(keep)
            merged = merged.filter { $0.key >= keepKey }
        }
        if let data = try? JSONEncoder().encode(merged) { d.set(data, forKey: K.cache) }
        d.set(now.timeIntervalSince1970, forKey: K.fetchedAt)
        d.set(String(format: "%.4f,%.4f", lat, lon), forKey: K.coords)
        d.set(source, forKey: K.source)
        return true
    }

    @MainActor
    private static func coordinates(useLocation: Bool, askPermission: Bool) async -> (Double, Double, String) {
        #if os(iOS)
        if useLocation, let loc = await OneShotLocation.fetch(askPermission: askPermission) {
            d.set(loc.latitude, forKey: K.lastLat)
            d.set(loc.longitude, forKey: K.lastLon)
            return (loc.latitude, loc.longitude, "gps")
        }
        #endif
        if d.object(forKey: K.lastLat) != nil {
            return (d.double(forKey: K.lastLat), d.double(forKey: K.lastLon), "last")
        }
        return (PrayerTimes.fallbackLatitude, PrayerTimes.fallbackLongitude, "sharjah")
    }
}

#if os(iOS)
/// A single "where am I" fix, coarse accuracy, with a timeout. Asks for When-In-Use permission only when
/// `askPermission` is true; otherwise returns nil unless permission was already granted.
@MainActor
final class OneShotLocation: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocationCoordinate2D?, Never>?
    private static var active: OneShotLocation?

    static func fetch(askPermission: Bool, timeout: TimeInterval = 12) async -> CLLocationCoordinate2D? {
        let me = OneShotLocation()
        active = me
        defer { active = nil }
        return await me.run(askPermission: askPermission, timeout: timeout)
    }

    private func run(askPermission: Bool, timeout: TimeInterval) async -> CLLocationCoordinate2D? {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        let status = manager.authorizationStatus
        if status == .denied || status == .restricted { return nil }
        if status == .notDetermined && !askPermission { return nil }
        return await withCheckedContinuation { cont in
            continuation = cont
            if status == .notDetermined {
                manager.requestWhenInUseAuthorization()
            } else {
                manager.requestLocation()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(nil)
            }
        }
    }

    private func finish(_ c: CLLocationCoordinate2D?) {
        guard let cont = continuation else { return }
        continuation = nil
        manager.delegate = nil
        cont.resume(returning: c)
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            switch status {
            case .authorizedWhenInUse, .authorizedAlways: self.manager.requestLocation()
            case .denied, .restricted: self.finish(nil)
            default: break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let c = locations.last?.coordinate
        Task { @MainActor in self.finish(c) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(nil) }
    }
}
#endif
