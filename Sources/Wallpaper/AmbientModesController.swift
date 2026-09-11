import AppKit
import CoreLocation
import Foundation

/// Day/night/weather scene modes. Drives optional wallpaper switches on top of
/// the user's own selection and never fights manual picks: any user-chosen
/// scene becomes the new day scene and holds until the next mode boundary.
final class AmbientModesController: NSObject, CLLocationManagerDelegate {
    private let wallpaper: WallpaperController
    private let comfort: DesktopComfortController
    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private var weatherTimer: Timer?
    private var locationManager: CLLocationManager?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var evaluating = false

    private var appliedKey: String?
    private var manualHoldKey: String?
    private var lastWeatherGroup: WeatherGroup?

    enum WeatherGroup: String {
        case clear, cloudy, precip
        static func group(for code: Int) -> WeatherGroup? {
            switch code {
            case 0, 1: return .clear
            case 2, 3, 45, 48: return .cloudy
            case 51...99: return .precip
            default: return nil
            }
        }
    }

    override init() { fatalError("Use init(wallpaper:comfort:)") }
    init(wallpaper: WallpaperController, comfort: DesktopComfortController) {
        self.wallpaper = wallpaper
        self.comfort = comfort
        super.init()
        wallpaper.onSelectionCommitted = { [weak self] url in self?.adoptManualSelection(url) }
    }

    // MARK: - Settings

    var followSun: Bool {
        get { defaults.bool(forKey: "modes.followSun") }
        set { defaults.set(newValue, forKey: "modes.followSun"); refresh() }
    }
    var useMyLocation: Bool {
        get { defaults.object(forKey: "modes.useMyLocation") == nil ? true : defaults.bool(forKey: "modes.useMyLocation") }
        set { defaults.set(newValue, forKey: "modes.useMyLocation"); requestLocationFix(); refresh() }
    }
    var manualLatitude: Double {
        get { defaults.object(forKey: "modes.latitude") == nil ? 40.7128 : defaults.double(forKey: "modes.latitude") }
        set { defaults.set(newValue, forKey: "modes.latitude"); refresh() }
    }
    var manualLongitude: Double {
        get { defaults.object(forKey: "modes.longitude") == nil ? -74.006 : defaults.double(forKey: "modes.longitude") }
        set { defaults.set(newValue, forKey: "modes.longitude"); refresh() }
    }
    var weatherEnabled: Bool {
        get { defaults.bool(forKey: "modes.weatherEnabled") }
        set { defaults.set(newValue, forKey: "modes.weatherEnabled"); pollWeather(); refresh() }
    }

    // MARK: - Scene slots (bookmarks)

    private func slotKey(_ name: String) -> String { "modes.scene.\(name)" }
    func sceneURL(for slot: String) -> URL? {
        guard let data = defaults.data(forKey: slotKey(slot)) else { return nil }
        return Self.resolveBookmark(data)
    }
    func setScene(_ url: URL?, for slot: String) {
        if let url, let data = Self.makeBookmark(url) {
            defaults.set(data, forKey: slotKey(slot))
        } else {
            defaults.removeObject(forKey: slotKey(slot))
        }
        refresh()
    }
    private static func makeBookmark(_ url: URL) -> Data? {
        (try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
    }
    private static func resolveBookmark(_ data: Data) -> URL? {
        var stale = false
        return (try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale))
            ?? (try? URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale))
    }

    private var daySceneData: Data? {
        get { defaults.data(forKey: "modes.dayScene") }
        set {
            if let data = newValue { defaults.set(data, forKey: "modes.dayScene") }
            else { defaults.removeObject(forKey: "modes.dayScene") }
        }
    }
    private var daySceneURL: URL? {
        guard let data = daySceneData else { return nil }
        return Self.resolveBookmark(data)
    }

    // MARK: - Lifecycle

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 10
        weatherTimer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
            self?.pollWeather()
        }
        weatherTimer?.tolerance = 60
        let workspace = NSWorkspace.shared.notificationCenter
        let token = workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.requestLocationFix()
            self?.pollWeather()
            self?.refresh()
        }
        observers.append((workspace, token))
        if useMyLocation { requestLocationFix() }
        if weatherEnabled { pollWeather() }
        refresh()
    }

    // MARK: - Location

    private var coordinate: (lat: Double, lon: Double) {
        if useMyLocation,
           let lat = defaults.object(forKey: "modes.lastLatitude") as? Double,
           let lon = defaults.object(forKey: "modes.lastLongitude") as? Double {
            return (lat, lon)
        }
        return (manualLatitude, manualLongitude)
    }

    private func requestLocationFix() {
        guard useMyLocation else { return }
        if locationManager == nil {
            let manager = CLLocationManager()
            manager.delegate = self
            manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
            locationManager = manager
        }
        locationManager?.requestWhenInUseAuthorization()
        locationManager?.requestLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations.last else { return }
        defaults.set(fix.coordinate.latitude, forKey: "modes.lastLatitude")
        defaults.set(fix.coordinate.longitude, forKey: "modes.lastLongitude")
        pollWeather()
        refresh()
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Keep the last fix or manual coordinates; never block modes on location.
    }

    // MARK: - Solar (NOAA approximation, minutes from midnight local)
    // NOTE: times are computed in the *system* time zone, which is exact for
    // the user's own location and nearby custom coordinates. A far-away custom
    // location needs its own UTC offset (future: optional tz override field).

    static func sunEvents(latitude: Double, longitude: Double, date: Date = Date()) -> (rise: Int, set: Int)? {
        let cal = Calendar.current
        guard let dayOfYear = cal.ordinality(of: .day, in: .year, for: date) else { return nil }
        let tzHours = Double(TimeZone.current.secondsFromGMT(for: date)) / 3600
        let latRad = latitude * .pi / 180
        func event(isRise: Bool) -> Double? {
            let lngHour = longitude / 15
            let t = Double(dayOfYear) + ((isRise ? 6 : 18) - lngHour) / 24
            let m = 0.9856 * t - 3.289
            var l = m + 1.916 * sin(m * .pi / 180) + 0.020 * sin(2 * m * .pi / 180) + 282.634
            l = l.truncatingRemainder(dividingBy: 360); if l < 0 { l += 360 }
            var ra = atan(0.91764 * tan(l * .pi / 180)) * 180 / .pi
            ra = ra.truncatingRemainder(dividingBy: 360); if ra < 0 { ra += 360 }
            let lQuad = (l / 90).rounded(.down) * 90
            let raQuad = (ra / 90).rounded(.down) * 90
            ra += lQuad - raQuad
            ra /= 15
            let sinDec = 0.39782 * sin(l * .pi / 180)
            let cosDec = cos(asin(sinDec))
            let cosH = (cos(90.833 * .pi / 180) - sinDec * sin(latRad)) / (cosDec * cos(latRad))
            guard abs(cosH) <= 1 else { return nil }
            var h = acos(cosH) * 180 / .pi
            if isRise { h = 360 - h }
            h /= 15
            var utc = h + ra - 0.06571 * t - 6.622 - lngHour
            utc = utc.truncatingRemainder(dividingBy: 24); if utc < 0 { utc += 24 }
            var local = utc + tzHours
            local = local.truncatingRemainder(dividingBy: 24); if local < 0 { local += 24 }
            return local * 60
        }
        guard let rise = event(isRise: true), let set = event(isRise: false) else { return nil }
        return (Int(rise.rounded()), Int(set.rounded()))
    }

    var solarTimes: (rise: Int, set: Int)? {
        let c = coordinate
        return Self.sunEvents(latitude: c.lat, longitude: c.lon)
    }

    private func isSolarNight(now: Date = Date()) -> Bool {
        guard followSun, let sun = solarTimes else { return false }
        let minute = Calendar.current.dateComponents([.hour, .minute], from: now)
        let nowMin = (minute.hour ?? 0) * 60 + (minute.minute ?? 0)
        return nowMin < sun.rise || nowMin >= sun.set
    }

    // MARK: - Weather (Open-Meteo, keyless)

    private func pollWeather() {
        guard weatherEnabled else { return }
        let c = coordinate
        guard let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(c.lat)&longitude=\(c.lon)&current=weather_code") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let current = json["current"] as? [String: Any],
                  let code = current["weather_code"] as? Int,
                  let group = WeatherGroup.group(for: code) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lastWeatherGroup = group
                self.defaults.set(code, forKey: "modes.lastWeatherCode")
                self.refresh()
            }
        }.resume()
    }

    private var weatherGroup: WeatherGroup? {
        guard weatherEnabled else { return nil }
        if let group = lastWeatherGroup { return group }
        if let code = defaults.object(forKey: "modes.lastWeatherCode") as? Int {
            return WeatherGroup.group(for: code)
        }
        return nil
    }

    // MARK: - Evaluation

    private func adoptManualSelection(_ url: URL) {
        // Whatever the user picks becomes the day scene. Hold it until the
        // mode key changes so scheduled switches never fight a manual choice.
        // Mode-driven selects set expectingCommit and bypass adoption.
        if let expected = expectingCommit, expected == url {
            expectingCommit = nil
            return
        }
        expectingCommit = nil
        daySceneData = Self.makeBookmark(url)
        if let appliedKey { manualHoldKey = appliedKey }
        // Re-picking the active mode scene keeps it playing; anything else clears the override.
        wallpaper.modeOverrideActive = url == wallpaper.selectedURL && appliedKey != nil && manualHoldKey == appliedKey
    }
    private var expectingCommit: URL?

    func refresh() {
        guard !evaluating, !wallpaper.isLoading else { return }
        evaluating = true
        defer { evaluating = false }
        guard wallpaper.isRunning, let current = wallpaper.selectedURL else {
            appliedKey = nil
            wallpaper.modeOverrideActive = false
            return
        }
        let night = comfort.isDimmed || isSolarNight()
        let group = weatherGroup
        var key = night ? "N" : "D"
        var target: URL?
        if let group {
            key += ":\(group.rawValue)"
            target = sceneURL(for: "weather.\(group.rawValue)")
        }
        if target == nil, night {
            target = sceneURL(for: "night")
        }
        if let hold = manualHoldKey, hold == appliedKey, hold == key {
            return // User overrode this exact mode; wait for a boundary change.
        }
        manualHoldKey = nil
        guard let target else {
            if appliedKey != nil {
                appliedKey = nil
                wallpaper.modeOverrideActive = false
                if let day = daySceneURL, day != current {
                    expectingCommit = day
                    wallpaper.select(day, automatic: true)
                }
            }
            return
        }
        if target == current {
            appliedKey = key
            wallpaper.modeOverrideActive = true
            return
        }
        if appliedKey == nil, daySceneURL == nil {
            daySceneData = Self.makeBookmark(current)
        }
        appliedKey = key
        wallpaper.modeOverrideActive = true
        expectingCommit = target
        wallpaper.select(target, automatic: true)
    }
}
