import Foundation
import CoreGraphics

/// Static network for one board (trams, or a chosen set of bus routes),
/// built from the Rīgas satiksme GTFS timetable (data.gov.lv) by
/// tools/make_network.py and bundled as riga_trams.json / riga_buses.json.
struct Station: Decodable {
    let name: String
    let lat: Double
    let lon: Double
}

/// One platform on a route variant. `station` indexes `TramNetwork.stations`
/// (platforms on both sides of the road share one station).
struct StopRef: Decodable {
    let id: String
    let lat: Double
    let lon: Double
    let station: Int
}

/// A route in one direction, e.g. route "1", dir "a-b".
/// `dir` matches the direction column of the live feed (digits aside).
struct Variant: Decodable {
    let route: String
    let type: String?   // live-feed vehicle type (1 trolleybus, 2 bus, 3 tram); nil = the network's
    let key: String?    // display key, e.g. "T25" for trolleybus 25; nil = the route number
    let dir: String
    let stops: [StopRef]
    let shape: [[Double]]   // [lat, lon] pairs
}

struct TramNetwork: Decodable {
    let title: String            // "RĪGA  ·  TRAMVAJI"
    let noun: String             // "trams" / "buses", for the status line
    let vehicleType: String      // default live-feed type code: 1 trolleybus, 2 bus, 3 tram
    let maxSnapMeters: Double    // further than this from every stop = off-route, not shown
    let routes: [String]         // line numbers, in legend order
    let colors: [String: String] // line number -> hex colour
    let stations: [Station]
    let variants: [Variant]
    let labels: [String: String]?   // station index -> label shown on the board
    let labelSides: [String: String]?   // station index -> "r", "l", "br" or "bl" (default: r, or l near the right edge)
    let labelOffsets: [String: [Double]]?   // station index -> extra [x, y] shift in points at Medium size
    let towardsCentre: [String: String]?    // line -> direction code heading into the centre (e.g. "b-a")

    static func load(_ resource: String) -> TramNetwork {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let network = try? JSONDecoder().decode(TramNetwork.self, from: data)
        else { fatalError("\(resource).json is missing from the app bundle or out of date") }
        return network
    }
}

/// Fits the network's lat/lon into a rectangle, keeping its real proportions.
struct Projection {
    private let minX: Double, maxX: Double, minY: Double, maxY: Double
    private let k: Double   // longitude shrink at Riga's latitude

    init(_ network: TramNetwork) {
        let k = cos(56.95 * .pi / 180)
        self.k = k
        let xs = network.stations.map { $0.lon * k }
        let ys = network.stations.map { $0.lat }
        minX = xs.min() ?? 0; maxX = xs.max() ?? 1
        minY = ys.min() ?? 0; maxY = ys.max() ?? 1
    }

    func point(lat: Double, lon: Double, in rect: CGRect) -> CGPoint {
        let w = maxX - minX, h = maxY - minY
        let scale = min(rect.width / w, rect.height / h)
        let ox = rect.minX + (rect.width - w * scale) / 2
        let oy = rect.minY + (rect.height - h * scale) / 2
        return CGPoint(x: ox + (lon * k - minX) * scale, y: oy + (maxY - lat) * scale)
    }
}
