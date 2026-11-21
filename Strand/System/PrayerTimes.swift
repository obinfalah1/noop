import Foundation

/// Prayer times for the strap alarm (personal fork addition).
///
/// Times come from the AlAdhan `/v1/calendar` API, method 16 (UAE: Fajr and Isha angle 18.2°), at the
/// phone's location. This month and next are fetched at once and cached, so a re-arm (the fired event,
/// a reconnect, the daily timer) never needs the network at that moment. Al Majaz, Sharjah is the
/// fallback location.
///
/// Everything in this file is pure and side-effect-free except the `PrayerTimesCache` load/save, so the
/// parser and the "next occurrence" resolver can be checked against a fixed clock.
enum Prayer: String, CaseIterable, Codable {
    case fajr = "Fajr"
    case dhuhr = "Dhuhr"
    case asr = "Asr"
    case maghrib = "Maghrib"
    case isha = "Isha"

    /// The four prayers that get a buzz (Fajr has its own alarm settings).
    static let buzzPrayers: [Prayer] = [.dhuhr, .asr, .maghrib, .isha]
}

enum PrayerTimes {
    /// Al Majaz, Sharjah, the best match against the awqaf.gov.ae Sharjah table.
    static let fallbackLatitude = 25.3255
    static let fallbackLongitude = 55.3870
    /// AlAdhan calculation method 16: UAE (Fajr and Isha angle 18.2°).
    static let method = 16

    /// `yyyy-MM-dd` for a local calendar day.
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The calendar request for one month.
    static func calendarURL(year: Int, month: Int, latitude: Double, longitude: Double) -> URL? {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "api.aladhan.com"
        comps.path = "/v1/calendar/\(year)/\(month)"
        comps.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", longitude)),
            URLQueryItem(name: "method", value: String(method)),
            URLQueryItem(name: "iso8601", value: "true"),
        ]
        return comps.url
    }

    /// Parse an AlAdhan `/v1/calendar` body (requested with `iso8601=true`) into
    /// `yyyy-MM-dd` → prayer name → unix seconds. The ISO times carry their UTC offset
    /// (`2026-11-20T05:18:00+04:00`), so each instant is exact whatever zone the phone is set to.
    /// Malformed days or times are skipped.
    static func parseCalendar(_ data: Data) -> [String: [String: Int]] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let days = root["data"] as? [[String: Any]] else { return [:] }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var out: [String: [String: Int]] = [:]
        for day in days {
            guard let timings = day["timings"] as? [String: Any],
                  let date = day["date"] as? [String: Any],
                  let greg = date["gregorian"] as? [String: Any],
                  let ddmmyyyy = greg["date"] as? String else { continue }
            let p = ddmmyyyy.split(separator: "-")
            guard p.count == 3 else { continue }
            var times: [String: Int] = [:]
            for prayer in Prayer.allCases {
                guard let raw = timings[prayer.rawValue] as? String,
                      let first = raw.split(separator: " ").first,
                      let d = iso.date(from: String(first)) else { continue }
                times[prayer.rawValue] = Int(d.timeIntervalSince1970)
            }
            if !times.isEmpty { out["\(p[2])-\(p[1])-\(p[0])"] = times }
        }
        return out
    }

    /// The earliest `prayer time + offset` strictly after `now` across `prayers`, or nil.
    static func next(in cache: [String: [String: Int]],
                     prayers: [Prayer],
                     offsetMinutes: Int,
                     after now: Date) -> (date: Date, prayer: Prayer)? {
        guard !prayers.isEmpty else { return nil }
        let nowSec = now.timeIntervalSince1970
        var best: (date: Date, prayer: Prayer)?
        for times in cache.values {
            for prayer in prayers {
                guard let sec = times[prayer.rawValue] else { continue }
                let at = Double(sec + offsetMinutes * 60)
                guard at > nowSec else { continue }
                if best == nil || at < best!.date.timeIntervalSince1970 {
                    best = (Date(timeIntervalSince1970: at), prayer)
                }
            }
        }
        return best
    }

    /// True when the cache misses any of the next `aheadDays` days or is older than a week.
    static func needsRefresh(cache: [String: [String: Int]], fetchedAt: Date?, now: Date,
                             aheadDays: Int = 10, calendar: Calendar = .current) -> Bool {
        for i in 0...aheadDays {
            guard let d = calendar.date(byAdding: .day, value: i, to: now) else { continue }
            if cache[dayKey(d, calendar: calendar)] == nil { return true }
        }
        guard let fetchedAt else { return true }
        return now.timeIntervalSince(fetchedAt) > 7 * 24 * 3600
    }

    /// The 12-byte WHOOP 5/MG alarm haptic pattern for `buzzCount` buzzes with `pauseSteps` × 240 ms
    /// of pause after each.
    ///
    /// Eight waveform slots, a u16 per-effect loop control, the overall loop count, and the maximum
    /// alarm duration in seconds. The stock pattern is `[47, 152, 0 ×6, 0, 0, 7, 30]`: effect 47 (the
    /// buzz) then 152 (a 240 ms pause), looped 7 times. Only those two waveform values are used (a
    /// WHOOP 5 refused other pause values with `invalid_waveform_effect`), so the pause is 152 repeated
    /// and the buzz count is the overall loop. With the defaults (7 buzzes, 1 pause step) this is
    /// byte-for-byte the stock pattern.
    static func hapticPattern(buzzCount: Int, pauseSteps: Int) -> [UInt8] {
        let count = min(max(buzzCount, 1), 20)
        let pauses = min(max(pauseSteps, 1), 7)
        var slots: [UInt8] = [47] + Array(repeating: 152, count: pauses)
        while slots.count < 8 { slots.append(0) }
        let needed = Int((Double(count) * Double(500 + pauses * 240) / 1000).rounded(.up)) + 5
        let duration = min(max(needed, 30), 255)
        return slots + [0, 0, UInt8(count), UInt8(duration)]
    }

    /// The stock pattern, used when the strap refuses a custom one.
    static let stockPattern: [UInt8] = [47, 152, 0, 0, 0, 0, 0, 0, 0, 0, 7, 30]
}
