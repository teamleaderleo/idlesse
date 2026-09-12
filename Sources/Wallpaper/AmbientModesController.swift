import AppKit
import CoreLocation
import Foundation

/// Legacy day/night conditions plus Ambient Sets decision/actuation authority.
/// Before explicit cutover, legacy behavior stays unchanged. After cutover,
/// condition sources report state here and only the Ambient resolver chooses
/// wallpaper, dimming, Files and Widgets output.
final class AmbientModesController: NSObject, CLLocationManagerDelegate {
    private let wallpaper: WallpaperController
    private let comfort: DesktopComfortController
    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private var boundaryTimer: Timer?
    private var weatherTimer: Timer?
    private var locationManager: CLLocationManager?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var evaluating = false

    private var appliedKey: String?
    private var manualHoldKey: String?
    private var lastWeatherGroup: WeatherGroup?
    private var expectingCommit: URL?

    private let ambientResolver = AmbientSetResolver()
    private var ambientRotationTimer: Timer?
    private var ambientRotationCollectionID: String?
    private var ambientRotationQueue = SceneRotationQueue()
    private var ambientRotationShuffle = false
    private var ambientRotationMinutes = 30
    private var ambientAccess: SceneLibraryStore.Access?
    private var activeAmbientTarget: AmbientWallpaperTarget?
    private var ignoreNextCommittedSelection = false
    private(set) var currentAmbientResolution: AmbientResolution?
    var onAmbientResolutionChanged: ((AmbientResolution) -> Void)?

    private static let ambientAuthorityKey = "ambientSets.authoritative"
    private static let arrangementSnapshotKey = "ambientSets.arrangementSnapshot"
    private static let collectionScheduleBackupKey = "ambientSets.legacyCollectionScheduleBackup"

    private struct LegacyCollectionScheduleBackup: Codable {
        var collectionID: String
        var playback: SceneLibraryStore.Playback
    }

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
    }

    private lazy var ambientStore: AmbientSetStore? = {
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: true)
            return try AmbientSetStore(fileURL: support.appendingPathComponent("Idlesse/AmbientSets/index.json"))
        } catch {
            NSLog("Idlesse Ambient Sets store unavailable: %@", error.localizedDescription)
            defaults.set(false, forKey: Self.ambientAuthorityKey)
            return nil
        }
    }()

    var isAmbientSetsAuthoritative: Bool {
        defaults.bool(forKey: Self.ambientAuthorityKey) && ambientStore != nil
    }

    var ambientSets: [AmbientSet] { ambientStore?.catalog.sets ?? [] }

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
        set {
            defaults.set(newValue, forKey: "modes.weatherEnabled")
            if !isAmbientSetsAuthoritative { pollWeather() }
            refresh()
        }
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
            guard self?.isAmbientSetsAuthoritative != true else { return }
            self?.pollWeather()
        }
        weatherTimer?.tolerance = 60
        let workspace = NSWorkspace.shared.notificationCenter
        let wake = workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.requestLocationFix()
            if self?.isAmbientSetsAuthoritative != true { self?.pollWeather() }
            self?.refresh()
        }
        observers.append((workspace, wake))
        for name in [NSNotification.Name.NSSystemClockDidChange, NSNotification.Name.NSSystemTimeZoneDidChange] {
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            }
            observers.append((.default, token))
        }
        let manualComfort = NotificationCenter.default.addObserver(
            forName: DesktopComfortController.manualStateChanged, object: comfort, queue: .main) { [weak self] note in
                self?.adoptManualComfortChange(note)
            }
        observers.append((.default, manualComfort))

        if isAmbientSetsAuthoritative {
            comfort.setAmbientAuthorityEnabled(true)
            ignoreNextCommittedSelection = true
            do { try suspendLegacyCollectionSchedules() }
            catch {
                NSLog("Idlesse Ambient Sets could not suspend legacy collection schedules: %@", error.localizedDescription)
                defaults.set(false, forKey: Self.ambientAuthorityKey)
                comfort.setAmbientAuthorityEnabled(false)
            }
        }
        if useMyLocation { requestLocationFix() }
        if weatherEnabled && !isAmbientSetsAuthoritative { pollWeather() }
        refresh()
    }

    deinit {
        timer?.invalidate()
        boundaryTimer?.invalidate()
        weatherTimer?.invalidate()
        ambientRotationTimer?.invalidate()
        observers.forEach { $0.0.removeObserver($0.1) }
        ambientAccess?.close()
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
        if !isAmbientSetsAuthoritative { pollWeather() }
        refresh()
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Keep the last fix or manual coordinates; location never blocks modes.
    }

    // MARK: - Solar (NOAA approximation, minutes from midnight local)

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

    private func ambientSolarEvents(for date: Date, calendar: Calendar) -> AmbientSolarEvents? {
        let c = coordinate
        guard let values = Self.sunEvents(latitude: c.lat, longitude: c.lon, date: date) else { return nil }
        let day = calendar.startOfDay(for: date)
        guard let sunrise = calendar.date(bySettingHour: values.rise / 60, minute: values.rise % 60, second: 0, of: day),
              let sunset = calendar.date(bySettingHour: values.set / 60, minute: values.set % 60, second: 0, of: day) else { return nil }
        return AmbientSolarEvents(sunrise: sunrise, sunset: sunset)
    }

    private func isSolarNight(now: Date = Date()) -> Bool {
        guard followSun, let sun = solarTimes else { return false }
        let minute = Calendar.current.dateComponents([.hour, .minute], from: now)
        let nowMin = (minute.hour ?? 0) * 60 + (minute.minute ?? 0)
        return nowMin < sun.rise || nowMin >= sun.set
    }

    // MARK: - Weather (Open-Meteo, keyless; legacy only in this slice)

    private func pollWeather() {
        guard weatherEnabled, !isAmbientSetsAuthoritative else { return }
        let c = coordinate
        guard let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(c.lat)&longitude=\(c.lon)&current=weather_code") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let current = json["current"] as? [String: Any],
                  let code = current["weather_code"] as? Int,
                  let group = WeatherGroup.group(for: code) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isAmbientSetsAuthoritative else { return }
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

    private var hasConfiguredOnlineWeatherTarget: Bool {
        ["clear", "cloudy", "precip"].contains { sceneURL(for: "weather.\($0)") != nil }
    }

    // MARK: - Ambient Sets public API

    func replaceAmbientSets(_ sets: [AmbientSet]) throws {
        try AmbientSetActuationPolicy.validateUserSets(sets)
        guard let ambientStore else { throw AmbientSetActuationError.unavailableStore }
        try ambientStore.replaceAll(sets)
        if isAmbientSetsAuthoritative { refresh() }
    }

    func activateAmbientSet(id: String, untilResumed: Bool = false) throws {
        guard isAmbientSetsAuthoritative, let ambientStore else { throw AmbientSetActuationError.unavailableStore }
        guard ambientStore.catalog.sets.contains(where: { $0.id == id && $0.isEnabled }) else {
            throw AmbientSetActuationError.missingAmbientSet(id)
        }
        let policy: AmbientManualHoldPolicy = untilResumed ? .untilResumed : .untilNextAutomaticChange
        let hold = ambientResolver.makeManualHold(intent: .set(id: id), policy: policy,
                                                  sets: ambientStore.catalog.sets, now: Date(),
                                                  solarProvider: { [weak self] date, calendar in
                                                      self?.ambientSolarEvents(for: date, calendar: calendar)
                                                  })
        try ambientStore.setManualHold(hold)
        refresh()
    }

    func resumeAutomaticAmbientSets() throws {
        guard let ambientStore else { throw AmbientSetActuationError.unavailableStore }
        try ambientStore.setManualHold(nil)
        refresh()
    }

    /// Converts every supported legacy automatic source in one explicit cutover.
    /// Online condition scenes stay on the legacy path until their additive Ambient
    /// condition lands, so conversion refuses to silently drop them.
    @discardableResult
    func migrateLegacyToAmbientSets() throws -> [AmbientSet] {
        if weatherEnabled && hasConfiguredOnlineWeatherTarget {
            throw AmbientSetActuationError.onlineConditionStillConfigured
        }
        let library = try loadLibraryStore()
        var collections: [AmbientLegacyCollectionSchedule] = []
        for collection in library.catalog.collections {
            guard let playback = collection.playback,
                  let start = playback.startMinute, let end = playback.endMinute else { continue }
            collections.append(.init(collectionID: collection.id, collectionName: collection.name,
                                     startMinute: start, endMinute: end, weekdays: playback.weekdays))
        }

        var nightSceneID: String?
        if let nightURL = sceneURL(for: "night") {
            nightSceneID = try stableSceneID(for: nightURL, library: library, createIfMissing: true)
        }
        let bedtimeSettings = comfort.bedtimeSettings
        let bedtime = AmbientLegacyBedtime(enabled: bedtimeSettings.enabled,
                                            startMinute: bedtimeSettings.start,
                                            endMinute: bedtimeSettings.end,
                                            dimLevel: bedtimeSettings.amount,
                                            nightSceneID: nightSceneID)
        let sets = try AmbientLegacyMigrationPlan.make(collections: collections,
                                                       followsSun: followSun,
                                                       nightSceneID: nightSceneID,
                                                       bedtime: bedtime)
        try enableAmbientSets(sets)
        return sets
    }

    func enableAmbientSets(_ sets: [AmbientSet]) throws {
        if weatherEnabled && hasConfiguredOnlineWeatherTarget {
            throw AmbientSetActuationError.onlineConditionStillConfigured
        }
        try AmbientSetActuationPolicy.validateUserSets(sets)
        guard let ambientStore else { throw AmbientSetActuationError.unavailableStore }
        let heldManualWallpaper = manualHoldKey != nil ? wallpaper.selectedURL : nil
        try ambientStore.replaceAll(sets)
        try ambientStore.setManualHold(nil)
        try captureArrangementSnapshot(force: true)
        do {
            try suspendLegacyCollectionSchedules()
        } catch {
            try? restoreLegacyCollectionSchedules()
            throw error
        }
        defaults.set(true, forKey: Self.ambientAuthorityKey)
        comfort.setAmbientAuthorityEnabled(true)
        appliedKey = nil
        manualHoldKey = nil
        wallpaper.modeOverrideActive = false
        ignoreNextCommittedSelection = false
        if let heldManualWallpaper {
            updateArrangementWallpaper(heldManualWallpaper)
            applyManualOverrides(.init(wallpaper: AmbientSetActuationPolicy.currentSelectionTarget), label: "Manual Wallpaper")
        } else {
            refresh()
        }
    }

    func disableAmbientSets() throws {
        guard isAmbientSetsAuthoritative else { return }
        boundaryTimer?.invalidate(); boundaryTimer = nil
        stopAmbientRotation()
        try ambientStore?.setManualHold(nil)
        let snapshot = arrangementSnapshot()
        if let snapshot {
            comfort.applyResolvedDesktopIconsVisible(snapshot.filesVisible)
            comfort.applyResolvedDesktopWidgetsVisible(snapshot.widgetsVisible)
        }
        let restoreURL = arrangementWallpaperURL()
        defaults.set(false, forKey: Self.ambientAuthorityKey)
        comfort.setAmbientAuthorityEnabled(false)
        try restoreLegacyCollectionSchedules()
        currentAmbientResolution = nil
        activeAmbientTarget = nil
        wallpaper.modeOverrideActive = false
        if let restoreURL, restoreURL != wallpaper.selectedURL {
            expectingCommit = restoreURL
            wallpaper.select(restoreURL, automatic: true)
        }
        refresh()
    }

    // MARK: - Ambient Sets evaluation / actuation

    func refresh() {
        guard !evaluating, !wallpaper.isLoading, !wallpaper.isPeeking else { return }
        evaluating = true
        defer { evaluating = false }
        if isAmbientSetsAuthoritative {
            evaluateAmbientSets()
        } else {
            evaluateLegacyModes()
        }
    }

    private func evaluateAmbientSets(now: Date = Date()) {
        guard let ambientStore else { return }
        if let hold = ambientStore.catalog.manualHold, !hold.isActive(at: now) {
            try? ambientStore.setManualHold(nil)
        }
        guard let arrangement = arrangementSnapshot()?.resolvedState else {
            NSLog("Idlesse Ambient Sets arrangement snapshot missing; recapturing current desktop state")
            try? captureArrangementSnapshot(force: true)
            guard let arrangement = arrangementSnapshot()?.resolvedState else { return }
            return evaluateAmbientSetsWithArrangement(arrangement, now: now, store: ambientStore)
        }
        evaluateAmbientSetsWithArrangement(arrangement, now: now, store: ambientStore)
    }

    private func evaluateAmbientSetsWithArrangement(_ arrangement: ResolvedDesktopState,
                                                     now: Date,
                                                     store: AmbientSetStore) {
        let solar: AmbientSetResolver.SolarProvider = { [weak self] date, calendar in
            self?.ambientSolarEvents(for: date, calendar: calendar)
        }
        let resolution = ambientResolver.resolve(sets: store.catalog.sets,
                                                 arrangementDefault: arrangement,
                                                 manualHold: store.catalog.manualHold,
                                                 now: now,
                                                 solarProvider: solar)
        applyAmbientState(resolution.state)
        currentAmbientResolution = resolution
        onAmbientResolutionChanged?(resolution)
        armAmbientBoundary(resolution.explanation.nextChange)
    }

    private func applyAmbientState(_ state: ResolvedDesktopState) {
        comfort.applyResolvedDesktopIconsVisible(state.filesVisible)
        comfort.applyResolvedDesktopWidgetsVisible(state.widgetsVisible)
        comfort.applyResolvedDimming(state.dimming)
        applyAmbientWallpaper(state.wallpaper)
        let target = state.wallpaper
        wallpaper.modeOverrideActive = target != nil &&
            !AmbientSetActuationPolicy.isCurrentSelection(target) &&
            !AmbientSetActuationPolicy.isArrangementDefault(target)
    }

    private func armAmbientBoundary(_ change: AmbientNextChange?) {
        boundaryTimer?.invalidate()
        boundaryTimer = nil
        guard let date = change?.date else { return }
        let interval = max(0.05, date.timeIntervalSinceNow + 0.05)
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in self?.refresh() }
        timer.tolerance = min(2, interval * 0.05)
        RunLoop.main.add(timer, forMode: .common)
        boundaryTimer = timer
    }

    private func applyAmbientWallpaper(_ target: AmbientWallpaperTarget?) {
        guard let target else {
            stopAmbientRotation()
            activeAmbientTarget = nil
            return
        }
        if AmbientSetActuationPolicy.isCurrentSelection(target) {
            stopAmbientRotation()
            activeAmbientTarget = target
            return
        }
        if AmbientSetActuationPolicy.isArrangementDefault(target) {
            stopAmbientRotation()
            activeAmbientTarget = target
            if let url = arrangementWallpaperURL(), url != wallpaper.selectedURL {
                wallpaper.select(url, automatic: true, transient: true)
            }
            return
        }
        if target == activeAmbientTarget {
            if target.kind == .collection, ambientRotationCollectionID == target.id { return }
            if target.kind == .scene { return }
        }
        switch target.kind {
        case .scene:
            stopAmbientRotation()
            do {
                let library = try loadLibraryStore()
                let opened = try openStableScene(id: target.id, library: library)
                ambientAccess?.close()
                ambientAccess = opened.access
                activeAmbientTarget = target
                if opened.url != wallpaper.selectedURL {
                    wallpaper.select(opened.url, automatic: true, transient: true)
                }
            } catch {
                NSLog("Idlesse Ambient Set scene unavailable: %@", error.localizedDescription)
            }
        case .collection:
            beginAmbientCollection(id: target.id)
            activeAmbientTarget = target
        }
    }

    private func beginAmbientCollection(id: String) {
        if ambientRotationCollectionID == id { return }
        stopAmbientRotation()
        do {
            let library = try loadLibraryStore()
            guard let collection = library.catalog.collections.first(where: { $0.id == id }) else {
                throw AmbientSetActuationError.missingWallpaperTarget(id)
            }
            ambientRotationCollectionID = id
            ambientRotationShuffle = collection.playback?.shuffle ?? false
            ambientRotationMinutes = min(1440, max(1, collection.playback?.minutes ?? 30))
            ambientRotationQueue = SceneRotationQueue()
            advanceAmbientCollection()
            if ambientRotationCollectionID != nil {
                let seconds = TimeInterval(ambientRotationMinutes * 60)
                let timer = Timer(timeInterval: seconds, repeats: true) { [weak self] _ in self?.advanceAmbientCollection() }
                timer.tolerance = min(60, seconds * 0.1)
                RunLoop.main.add(timer, forMode: .common)
                ambientRotationTimer = timer
            }
        } catch {
            stopAmbientRotation()
            NSLog("Idlesse Ambient Set collection unavailable: %@", error.localizedDescription)
        }
    }

    private func advanceAmbientCollection() {
        guard let id = ambientRotationCollectionID else { return }
        do {
            let library = try loadLibraryStore()
            guard let collection = library.catalog.collections.first(where: { $0.id == id }) else {
                stopAmbientRotation(); return
            }
            let ids = collection.sceneIDs
            guard !ids.isEmpty else { stopAmbientRotation(); return }
            var attempts = ids.count
            while attempts > 0, let sceneID = ambientRotationQueue.next(ids, shuffle: ambientRotationShuffle) {
                attempts -= 1
                if let opened = try? openStableScene(id: sceneID, library: library) {
                    ambientAccess?.close()
                    ambientAccess = opened.access
                    if opened.url != wallpaper.selectedURL {
                        wallpaper.select(opened.url, automatic: true, transient: true)
                    }
                    return
                }
            }
            stopAmbientRotation()
        } catch {
            stopAmbientRotation()
            NSLog("Idlesse Ambient Set rotation failed: %@", error.localizedDescription)
        }
    }

    private func stopAmbientRotation() {
        ambientRotationTimer?.invalidate()
        ambientRotationTimer = nil
        ambientRotationCollectionID = nil
        ambientRotationQueue = SceneRotationQueue()
    }

    private func loadLibraryStore() throws -> SceneLibraryStore {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true)
        return try SceneLibraryStore(file: support.appendingPathComponent("Idlesse/Library/index.json"))
    }

    private func openStableScene(id: String, library: SceneLibraryStore) throws -> (url: URL, access: SceneLibraryStore.Access?) {
        if id.hasPrefix("builtin.") {
            let name = String(id.dropFirst("builtin.".count))
            if let builtin = SceneLibraryController.builtinScenes().first(where: { $0.name == name }) {
                return (builtin.url, nil)
            }
        }
        guard let entry = library.catalog.entries.first(where: { $0.id == id }) else {
            throw AmbientSetActuationError.missingWallpaperTarget(id)
        }
        let access = try library.access(entry)
        return (access.url, access)
    }

    private func stableSceneID(for url: URL, library: SceneLibraryStore, createIfMissing: Bool) throws -> String {
        let wanted = url.standardizedFileURL.resolvingSymlinksInPath()
        if let builtin = SceneLibraryController.builtinScenes().first(where: {
            $0.url.standardizedFileURL.resolvingSymlinksInPath() == wanted
        }) {
            return "builtin.\(builtin.name)"
        }
        for entry in library.catalog.entries {
            guard let access = try? library.access(entry) else { continue }
            let matches = access.url.standardizedFileURL.resolvingSymlinksInPath() == wanted
            access.close()
            if matches { return entry.id }
        }
        guard createIfMissing else { throw AmbientSetActuationError.missingWallpaperTarget(url.lastPathComponent) }
        return try library.add(url).id
    }

    // MARK: - Arrangement default and manual hold

    private func captureArrangementSnapshot(force: Bool) throws {
        if !force, arrangementSnapshot() != nil { return }
        let baselineWallpaper = appliedKey != nil ? (daySceneURL ?? wallpaper.selectedURL) : wallpaper.selectedURL
        let bookmark = baselineWallpaper.flatMap(Self.makeBookmark)
        let snapshot = AmbientArrangementSnapshot(wallpaperBookmark: bookmark,
                                                  filesVisible: comfort.desktopIconsVisible,
                                                  widgetsVisible: comfort.desktopWidgetsVisible,
                                                  dimming: AmbientDimmingState(enabled: false, level: comfort.bedtimeSettings.amount))
        guard snapshot.isValid else { throw AmbientSetActuationError.invalidArrangementSnapshot }
        let data = try JSONEncoder().encode(snapshot)
        defaults.set(data, forKey: Self.arrangementSnapshotKey)
    }

    private func arrangementSnapshot() -> AmbientArrangementSnapshot? {
        guard let data = defaults.data(forKey: Self.arrangementSnapshotKey),
              data.count <= 32_768,
              let snapshot = try? JSONDecoder().decode(AmbientArrangementSnapshot.self, from: data),
              snapshot.isValid else { return nil }
        return snapshot
    }

    private func arrangementWallpaperURL() -> URL? {
        arrangementSnapshot()?.wallpaperBookmark.flatMap(Self.resolveBookmark)
    }

    private func updateArrangementWallpaper(_ url: URL) {
        guard var snapshot = arrangementSnapshot() else {
            try? captureArrangementSnapshot(force: true)
            return
        }
        snapshot.wallpaperBookmark = Self.makeBookmark(url)
        guard snapshot.isValid, let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Self.arrangementSnapshotKey)
    }

    private func applyManualOverrides(_ changes: AmbientDesktopOverrides, label: String) {
        guard isAmbientSetsAuthoritative, let ambientStore else { return }
        let now = Date()
        let merged = AmbientSetActuationPolicy.mergedManualOverrides(existing: ambientStore.catalog.manualHold,
                                                                     changes: changes, at: now)
        let hold = ambientResolver.makeManualHold(intent: .overrides(merged, label: label),
                                                  policy: .untilNextAutomaticChange,
                                                  sets: ambientStore.catalog.sets,
                                                  now: now,
                                                  solarProvider: { [weak self] date, calendar in
                                                      self?.ambientSolarEvents(for: date, calendar: calendar)
                                                  })
        do {
            try ambientStore.setManualHold(hold)
            refresh()
        } catch {
            NSLog("Idlesse Ambient manual hold could not be saved: %@", error.localizedDescription)
        }
    }

    private func adoptManualComfortChange(_ note: Notification) {
        guard isAmbientSetsAuthoritative,
              let kind = note.userInfo?[DesktopComfortController.manualStateKindKey] as? String else { return }
        switch kind {
        case DesktopComfortController.manualFilesKind:
            applyManualOverrides(.init(filesVisible: comfort.desktopIconsVisible), label: "Manual Desktop")
        case DesktopComfortController.manualWidgetsKind:
            applyManualOverrides(.init(widgetsVisible: comfort.desktopWidgetsVisible), label: "Manual Desktop")
        case DesktopComfortController.manualDimmingKind:
            let enabled = note.userInfo?["dimmingEnabled"] as? Bool ?? comfort.isDimmed
            let level = note.userInfo?["dimmingLevel"] as? Double ?? comfort.resolvedDimmingState.level
            applyManualOverrides(.init(dimming: .init(enabled: enabled, level: level)), label: "Manual Dimming")
        default:
            break
        }
    }

    // MARK: - Legacy collection schedule cutover / recovery

    private func suspendLegacyCollectionSchedules() throws {
        let library = try loadLibraryStore()
        let backup = library.catalog.collections.compactMap { collection -> LegacyCollectionScheduleBackup? in
            guard let playback = collection.playback,
                  playback.startMinute != nil, playback.endMinute != nil else { return nil }
            return .init(collectionID: collection.id, playback: playback)
        }
        if !backup.isEmpty && defaults.data(forKey: Self.collectionScheduleBackupKey) == nil {
            defaults.set(try JSONEncoder().encode(backup), forKey: Self.collectionScheduleBackupKey)
        }
        for item in backup {
            var playback = item.playback
            playback.startMinute = nil
            playback.endMinute = nil
            playback.weekdays = nil
            try library.setPlayback(item.collectionID, playback)
        }
    }

    private func restoreLegacyCollectionSchedules() throws {
        guard let data = defaults.data(forKey: Self.collectionScheduleBackupKey), data.count <= 131_072 else { return }
        let backup = try JSONDecoder().decode([LegacyCollectionScheduleBackup].self, from: data)
        guard backup.count <= SceneLibraryStore.maxEntries else { throw AmbientSetActuationError.invalidArrangementSnapshot }
        let library = try loadLibraryStore()
        for item in backup where library.catalog.collections.contains(where: { $0.id == item.collectionID }) {
            try library.setPlayback(item.collectionID, item.playback)
        }
        defaults.removeObject(forKey: Self.collectionScheduleBackupKey)
    }

    // MARK: - Legacy evaluation

    /// Called for every committed selection. In Ambient authority mode every
    /// non-transient commit is a user choice because Ambient actuation is transient.
    func adoptManualSelection(_ url: URL) {
        if isAmbientSetsAuthoritative {
            ambientAccess?.close(); ambientAccess = nil
            stopAmbientRotation()
            activeAmbientTarget = AmbientSetActuationPolicy.currentSelectionTarget
            updateArrangementWallpaper(url)
            if ignoreNextCommittedSelection {
                ignoreNextCommittedSelection = false
                refresh()
                return
            }
            applyManualOverrides(.init(wallpaper: AmbientSetActuationPolicy.currentSelectionTarget), label: "Manual Wallpaper")
            return
        }

        // Mode-driven selects set expectingCommit and bypass adoption.
        if let expected = expectingCommit, expected == url {
            expectingCommit = nil
            return
        }
        expectingCommit = nil
        daySceneData = Self.makeBookmark(url)
        if let appliedKey { manualHoldKey = appliedKey }
        wallpaper.modeOverrideActive = url == wallpaper.selectedURL && appliedKey != nil && manualHoldKey == appliedKey
    }

    private func evaluateLegacyModes() {
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
        if target == nil, night { target = sceneURL(for: "night") }
        if let hold = manualHoldKey, hold == appliedKey, hold == key { return }
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
        if appliedKey == nil, daySceneURL == nil { daySceneData = Self.makeBookmark(current) }
        appliedKey = key
        wallpaper.modeOverrideActive = true
        expectingCommit = target
        wallpaper.select(target, automatic: true)
    }
}
