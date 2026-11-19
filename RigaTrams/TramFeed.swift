import Foundation
import Combine

/// A vehicle near a station right now.
/// `arriving`: heading to (or standing at) this stop; otherwise it has just left it.
/// `towards`: station index of the route's final stop in the vehicle's direction.
/// `next`: station index of its next stop (nil at the end of the line).
struct LitStation {
    let route: String
    let direction: String   // e.g. "a-b", as reported by the feed
    let arriving: Bool
    let towards: Int
    let next: Int?
}

/// Polls the live vehicle feed behind saraksti.lv and works out which
/// stations currently have a tram (or bus, depending on the network).
///
/// Feed lines look like: 3,11,24122970,56952083,2,228,,30024,b-a,1025,222,
///   0 type (3 = tram)   1 route   2 lon×1e6   3 lat×1e6   4 speed
///   5 heading   6 low-floor flag   7 vehicle id   8 direction
///
/// This is the site's internal endpoint, not a public API, so keep the polling gentle (15 s)
@MainActor
final class TramFeed: ObservableObject {
    @Published private(set) var lit: [Int: [LitStation]] = [:]   // station index -> vehicles there, arriving first
    @Published private(set) var tramCount = 0
    @Published private(set) var lastUpdate: Date?
    @Published private(set) var failed = false

    let network: TramNetwork
    /// "type/route" (as the feed reports them, e.g. "2/22") -> direction -> ordered stop lists
    private var sequencesByRoute: [String: [String: [[StopRef]]]] = [:]
    /// "type/route" -> display key used for colours and labels ("22", "T25", ...)
    private var displayKeys: [String: String] = [:]
    private var timer: Timer?
    private let interval: TimeInterval = 15
    private let atStopMeters = 40.0

    init(network: TramNetwork) {
        self.network = network
        for v in network.variants {
            let feedKey = "\(v.type ?? network.vehicleType)/\(v.route)"
            sequencesByRoute[feedKey, default: [:]][Self.normalise(v.dir), default: []].append(v.stops)
            displayKeys[feedKey] = v.key ?? v.route
        }
    }

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = 3
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        Task {
            do {
                let ms = Int(Date().timeIntervalSince1970 * 1000)
                var request = URLRequest(url: URL(string: "https://saraksti.lv/gpsdata.ashx?gps&time=\(ms)")!)
                request.setValue("saraksti.lv", forHTTPHeaderField: "Origin-Custom")
                request.setValue("https://saraksti.lv/", forHTTPHeaderField: "Referer")
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.timeoutInterval = 10
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let text = String(data: data, encoding: .utf8),
                      !text.hasPrefix("Bad request")
                else { throw URLError(.badServerResponse) }
                apply(text)
            } catch {
                failed = true
            }
        }
    }

    private func apply(_ text: String) {
        var newLit: [Int: [LitStation]] = [:]
        var count = 0
        for line in text.split(whereSeparator: \.isNewline) {
            let f = line.split(separator: ",", omittingEmptySubsequences: false)
            // Match on vehicle type AND number: bus 22 and trolleybus 22 are different lines.
            guard f.count > 8 else { continue }
            let feedKey = "\(f[0])/\(f[1])"
            guard let lon = Double(f[2]), let lat = Double(f[3]),
                  let byDirection = sequencesByRoute[feedKey]
            else { continue }
            count += 1
            let route = displayKeys[feedKey] ?? String(f[1])
            let sequences = byDirection[Self.normalise(String(f[8]))] ?? Array(byDirection.values.joined())
            guard let hit = locate(lat: lat / 1e6, lon: lon / 1e6, in: sequences) else { continue }
            newLit[hit.station, default: []].append(
                LitStation(route: route, direction: Self.normalise(String(f[8])),
                           arriving: hit.arriving, towards: hit.towards, next: hit.next))
        }
        // Several vehicles at one station (e.g. both directions): arriving ones first.
        lit = newLit.mapValues { $0.sorted { $0.arriving && !$1.arriving } }
        tramCount = count
        lastUpdate = Date()
        failed = false
    }

    /// Nearest stop on the tram's own line and direction, and whether the tram
    /// is still heading to it or has already passed it.
    private func locate(lat: Double, lon: Double, in sequences: [[StopRef]])
        -> (station: Int, arriving: Bool, towards: Int, next: Int?)? {
        let k = cos(lat * .pi / 180)
        var best: (meters: Double, stops: [StopRef], index: Int)?
        for stops in sequences {
            for (i, p) in stops.enumerated() {
                let dy = (p.lat - lat) * 111_320
                let dx = (p.lon - lon) * 111_320 * k
                let d = (dx * dx + dy * dy).squareRoot()
                if d < (best?.meters ?? .infinity) { best = (d, stops, i) }
            }
        }
        guard let best, best.meters <= network.maxSnapMeters else { return nil }   // off-route, e.g. in a depot
        let arriving = best.meters <= atStopMeters
            || hasNotPassed(lat: lat, lon: lon, k: k, stops: best.stops, index: best.index)
        let stops = best.stops
        let next = best.index + 1 < stops.count ? stops[best.index + 1].station : nil
        return (stops[best.index].station, arriving, stops[stops.count - 1].station, next)
    }

    /// Projects the tram onto the track from the previous stop to this one:
    /// short of this stop means it is still on its way here.
    private func hasNotPassed(lat: Double, lon: Double, k: Double, stops: [StopRef], index i: Int) -> Bool {
        guard i > 0 else { return false }   // first stop of the run: it is about to leave
        let prev = stops[i - 1], cur = stops[i]
        let vx = (cur.lon - prev.lon) * k, vy = cur.lat - prev.lat
        let wx = (lon - prev.lon) * k, wy = lat - prev.lat
        let lengthSquared = vx * vx + vy * vy
        guard lengthSquared > 0 else { return true }
        return (vx * wx + vy * wy) / lengthSquared < 1
    }

    /// "b-a1" -> "b-a": the feed and the timetable label branch variants differently.
    nonisolated static func normalise(_ direction: String) -> String {
        direction.filter { !$0.isNumber }
    }
}
