import Foundation
import CoreLocation

/// Alice's sense of PLACE + WEATHER, gathered from macOS.
///
/// - Location: CoreLocation (Wi-Fi/city-level) → reverse-geocoded to "City, Region, Country".
/// - Weather: Open-Meteo (free, no API key, no entitlement) for the current conditions at that spot.
///
/// The result is cached and refreshed slowly; the sidecar merges `environmentDict` into Alice's
/// "## Your environment" prompt block on every turn, so she knows where/what it's like — instead of
/// guessing (the "San Francisco" / "sunny during monsoon" failures).
///
/// Degrades gracefully: no permission, denied, or offline → `environmentDict` is nil and Alice simply
/// keeps her Phase-1 room (date + time + timezone). Nothing breaks.
///
/// NOTE: WeatherKit is the Apple-native weather source, but it needs a paid Developer entitlement that
/// the ad-hoc dev build can't sign for — swap `fetchWeather` to it if that's ever set up.
@MainActor
final class AmbientContextService: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    static let shared = AmbientContextService()

    @Published private(set) var placeName: String?       // "Mumbai, Maharashtra, India"
    @Published private(set) var weatherSummary: String?  // "28°C, heavy rain, 85% humidity"

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var timer: Timer?

    /// What the sidecar merges into the environment block. nil until we know something useful.
    var environmentDict: [String: String]? {
        var d: [String: String] = [:]
        if let placeName { d["location"] = placeName }
        if let weatherSummary { d["weather"] = weatherSummary }
        return d.isEmpty ? nil : d
    }

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer   // city-level is plenty + power-cheap
    }

    /// Call once at launch. Requests permission if needed, gets a fix, and refreshes every ~20 min.
    func start() {
        requestFix()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 20 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.requestFix() }
        }
    }

    private func requestFix() {
        switch manager.authorizationStatus {
        case .notDetermined:      manager.requestWhenInUseAuthorization()
        case .denied, .restricted: break                    // user said no → stay silent
        default:                  manager.requestLocation()  // any authorized variant
        }
    }

    // MARK: - CLLocationManagerDelegate (called on the main thread; manager was created here)

    func locationManagerDidChangeAuthorization(_ mgr: CLLocationManager) {
        requestFix()
    }

    func locationManager(_ mgr: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { await resolve(loc) }
    }

    func locationManager(_ mgr: CLLocationManager, didFailWithError error: Error) {
        // Graceful: keep whatever we already had (or nothing). Alice falls back to date/time.
    }

    // MARK: - Resolve

    private func resolve(_ loc: CLLocation) async {
        if let pm = try? await geocoder.reverseGeocodeLocation(loc).first {
            let parts = [pm.locality, pm.administrativeArea, pm.country].compactMap { $0 }
            if !parts.isEmpty { placeName = parts.joined(separator: ", ") }
        }
        await fetchWeather(loc.coordinate)
    }

    private func fetchWeather(_ c: CLLocationCoordinate2D) async {
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            .init(name: "latitude", value: String(c.latitude)),
            .init(name: "longitude", value: String(c.longitude)),
            .init(name: "current",
                  value: "temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m"),
            .init(name: "timezone", value: "auto"),
        ]
        guard let url = comps.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cur = json["current"] as? [String: Any] else { return }
        func num(_ k: String) -> Double? { cur[k] as? Double }

        var bits: [String] = []
        if let t = num("temperature_2m") { bits.append("\(Int(t.rounded()))°C") }
        if let code = num("weather_code").map({ Int($0) }), let desc = Self.wmo[code] { bits.append(desc) }
        if let feels = num("apparent_temperature"), let t = num("temperature_2m"), abs(feels - t) >= 2 {
            bits.append("feels \(Int(feels.rounded()))°C")
        }
        if let h = num("relative_humidity_2m") { bits.append("\(Int(h.rounded()))% humidity") }
        if let w = num("wind_speed_10m"), w >= 15 { bits.append("wind \(Int(w.rounded())) km/h") }
        if !bits.isEmpty { weatherSummary = bits.joined(separator: ", ") }
    }

    /// WMO weather codes (what Open-Meteo returns) → short human text.
    private static let wmo: [Int: String] = [
        0: "clear", 1: "mainly clear", 2: "partly cloudy", 3: "overcast",
        45: "fog", 48: "rime fog", 51: "light drizzle", 53: "drizzle", 55: "heavy drizzle",
        61: "light rain", 63: "rain", 65: "heavy rain", 66: "freezing rain", 67: "freezing rain",
        71: "light snow", 73: "snow", 75: "heavy snow", 77: "snow grains",
        80: "light showers", 81: "showers", 82: "violent showers", 85: "snow showers", 86: "snow showers",
        95: "thunderstorm", 96: "thunderstorm with hail", 99: "thunderstorm with hail",
    ]
}
