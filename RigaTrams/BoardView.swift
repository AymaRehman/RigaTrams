import SwiftUI
import Combine

/// Colours for the board. The app follows the system's light/dark setting.
private struct Theme {
    let background: Color
    let backgroundAlt: Color
    let border: Color
    let borderWidth: CGFloat
    let text: Color
    let textMuted: Color
    let track: Color
    let dotBezel: Color
    let dotOff: Color
    let glow: Double             // strength of the halo around a lit dot
    let additiveGlow: Bool       // glows add light

    /// Dark luxury: charcoal with a warm bronze hairline.
    static let dark = Theme(
        background: Color(hex: 0x17191B),
        backgroundAlt: Color(hex: 0x202326),
        border: Color(hex: 0x66513D),
        borderWidth: 2,
        text: Color(hex: 0xE8E0D2),
        textMuted: Color(hex: 0x92918C),
        track: Color(hex: 0x92918C).opacity(0.45),
        dotBezel: Color(hex: 0x4A4640),
        dotOff: Color(hex: 0x0E0F10),
        glow: 0.6,
        additiveGlow: true)

    /// Light: warm paper, dark "off" LEDs like a physical board.
    static let light = Theme(
        background: Color(hex: 0xEAE5DC),
        backgroundAlt: Color(hex: 0xF4F0E9),
        border: Color(hex: 0xC4AF94),
        borderWidth: 2,
        text: Color(hex: 0x2A2622),
        textMuted: Color(hex: 0x85807A),
        track: Color(hex: 0x85807A).opacity(0.55),
        dotBezel: Color(hex: 0xBDB5A8),
        dotOff: Color(hex: 0x34302C),
        glow: 0.5,
        additiveGlow: false)
}

/// Board appearance the user can change at runtime.
@MainActor
final class BoardStyle: ObservableObject {
    @Published var transparency: Double   // 0 = solid, 1 = fully transparent
    @Published var hover: CGPoint?        // pointer position over the board, nil when outside

    init(transparency: Double) { self.transparency = transparency }

    /// Glass blur and border stay at full strength up to 75 % transparency,
    /// then fade out so that 100 % is completely clear.
    var glassOpacity: Double { min(1, (1 - transparency) * 4) }
}

/// The board: a panel with a hairline border, the tram network,
/// and a glowing dot at every station that has a tram right now.
struct BoardView: View {
    @ObservedObject var feed: TramFeed
    @ObservedObject var style: BoardStyle
    @Environment(\.colorScheme) private var colorScheme
    private let projection: Projection
    /// Line colours come from the network file (Rīgas satiksme uses one colour per
    /// vehicle type, so these are my own, chosen to tell the lines apart).
    private let lineColors: [String: Color]

    init(feed: TramFeed, style: BoardStyle) {
        self._feed = ObservedObject(wrappedValue: feed)
        self._style = ObservedObject(wrappedValue: style)
        self.projection = Projection(feed.network)
        self.lineColors = feed.network.colors.mapValues { Color(hex: UInt32($0, radix: 16) ?? 0xFFFFFF) }
    }

    private var theme: Theme { colorScheme == .dark ? .dark : .light }

    var body: some View {
        let t = theme
        let tint = 1 - style.transparency     // the glass blur behind is drawn by AppDelegate
        let edge = style.glassOpacity
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let shape = RoundedRectangle(cornerRadius: side * 0.05)   // matches the blur's mask
            shape
                .fill(LinearGradient(colors: [t.backgroundAlt.opacity(tint), t.background.opacity(tint)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(Canvas { ctx, size in drawFace(&ctx, size: size, side: side, theme: t) })
                .clipShape(shape)
                .overlay(shape.strokeBorder(t.border.opacity(edge), lineWidth: t.borderWidth))
        }
    }

    private func drawFace(_ ctx: inout GraphicsContext, size: CGSize, side: CGFloat, theme t: Theme) {
        let dotRadius = side / 150
        let lineWidth = max(1, side / 380)
        let fontSize = max(8, side / 46)
        let mapRect = CGRect(origin: .zero, size: size)
            .insetBy(dx: size.width * 0.08, dy: size.height * 0.09)
            .offsetBy(dx: 0, dy: -size.height * 0.02)
        let net = feed.network
        let points = net.stations.map { projection.point(lat: $0.lat, lon: $0.lon, in: mapRect) }

        // Track.
        for v in net.variants {
            var path = Path()
            for (j, p) in v.shape.enumerated() {
                let c = projection.point(lat: p[0], lon: p[1], in: mapRect)
                if j == 0 { path.move(to: c) } else { path.addLine(to: c) }
            }
            ctx.stroke(path, with: .color(t.track),
                       style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }

        // Unlit stations: "off" LED in a bezel.
        for c in points {
            ctx.fill(circle(c, dotRadius + lineWidth), with: .color(t.dotBezel))
            ctx.fill(circle(c, dotRadius), with: .color(t.dotOff))
        }

        // Lit stations, drawn last so their glow sits on top of neighbours.
        // Bright: a tram is heading to (or standing at) this stop. Dim: it has just left.
        if !feed.failed {
            var glowCtx = ctx
            if t.additiveGlow { glowCtx.blendMode = .plusLighter }
            for (index, vehicles) in feed.lit where index < points.count {
                guard let tram = vehicles.first else { continue }
                let c = points[index]
                let color = lineColors[tram.route] ?? t.text
                let halo = tram.arriving ? dotRadius * 3.4 : dotRadius * 2.6
                let strength = tram.arriving ? t.glow : t.glow * 0.4
                glowCtx.fill(circle(c, halo),
                             with: .radialGradient(Gradient(colors: [color.opacity(strength), color.opacity(0)]),
                                                   center: c, startRadius: dotRadius * 0.5, endRadius: halo))
                if tram.arriving {
                    ctx.fill(circle(c, dotRadius * 1.1),
                             with: .radialGradient(Gradient(colors: [.white, color]),
                                                   center: c, startRadius: 0, endRadius: dotRadius * 1.1))
                } else {
                    ctx.fill(circle(c, dotRadius), with: .color(color.opacity(0.6)))
                }
                // Direction: a small arrow per vehicle, pointing towards its next stop.
                for v in vehicles {
                    guard let n = v.next, n != index, n < points.count else { continue }
                    let arrowColor = (lineColors[v.route] ?? t.text).opacity(v.arriving ? 1 : 0.6)
                    ctx.fill(arrow(from: c, towards: points[n], dotRadius: dotRadius), with: .color(arrowColor))
                }
            }
        }

        // Terminus labels: one size, one weight. Each sits above or below its dot,
        // to the right or left, wherever the map has room (set in riga_trams.json).
        for (key, label) in net.labels ?? [:] {
            guard let index = Int(key), index < points.count else { continue }
            let c = points[index]
            let placement = net.labelSides?[key] ?? (c.x < size.width * 0.72 ? "r" : "l")
            let toRight = placement == "r" || placement == "br"
            let below = placement == "br" || placement == "bl"
            let nudge = net.labelOffsets?[key] ?? [0, 0]
            let scale = side / 420
            let anchorPoint = CGPoint(x: c.x + (toRight ? 1 : -1) * (dotRadius + 3) + nudge[0] * scale,
                                      y: (below ? c.y + dotRadius + 2 : c.y - dotRadius - 2) + nudge[1] * scale)
            let anchor: UnitPoint = below ? (toRight ? .topLeading : .topTrailing)
                                          : (toRight ? .bottomLeading : .bottomTrailing)
            ctx.draw(Text(label).font(.system(size: fontSize * 0.9, weight: .regular)).foregroundStyle(t.text),
                     at: anchorPoint, anchor: anchor)
        }

        // Legend: "LINES" then one coloured dot per tram line number, bottom left,
        // on the same baseline as the status line.
        var legendX = size.width * 0.06
        let legendTitle = ctx.resolve(Text("LINES")
            .font(.system(size: fontSize * 0.68, weight: .semibold))
            .tracking(1)
            .foregroundStyle(t.textMuted))
        ctx.draw(legendTitle, at: CGPoint(x: legendX, y: size.height * 0.95), anchor: .bottomLeading)
        legendX += legendTitle.measure(in: size).width + 8
        for route in net.routes {
            let label = ctx.resolve(Text(route)
                .font(.system(size: fontSize * 0.72).monospacedDigit())
                .foregroundStyle(t.textMuted))
            let labelSize = label.measure(in: size)
            ctx.fill(circle(CGPoint(x: legendX + dotRadius, y: size.height * 0.95 - labelSize.height / 2), dotRadius * 0.9),
                     with: .color(lineColors[route] ?? t.text))
            ctx.draw(label, at: CGPoint(x: legendX + dotRadius * 2 + 3, y: size.height * 0.95), anchor: .bottomLeading)
            legendX += dotRadius * 2 + 3 + labelSize.width + 9
        }

        // Hover: name of the stop under the pointer, and the vehicle there if any.
        if let pointer = style.hover,
           let index = nearest(to: pointer, in: points, within: max(10, dotRadius * 3)) {
            // One dot covers the stops on both sides of the road, so group the
            // vehicles by side: towards the centre, or away from it.
            var details: [(text: String, isHeading: Bool)] = []
            if !feed.failed, let vehicles = feed.lit[index] {
                var toCentre: [String] = [], fromCentre: [String] = [], inCentre: [String] = []
                for v in vehicles {
                    let nextStop = v.next.map { net.stations[$0].name } ?? "end of the line"
                    let isTrolleybus = v.route.hasPrefix("T")
                    let kind = isTrolleybus ? "Trolleybus" : (net.noun == "buses" ? "Bus" : "Tram")
                    let number = isTrolleybus ? String(v.route.dropFirst()) : v.route
                    let line = "\(kind) \(number) → \(nextStop)  ·  \(v.arriving ? "arriving" : "just left")"
                    switch centreDirection(of: v, at: index, in: net) {
                    case true?: toCentre.append(line)
                    case false?: fromCentre.append(line)
                    case nil: inCentre.append(line)
                    }
                }
                if !toCentre.isEmpty { details += [("TOWARDS CENTRE", true)] + toCentre.map { ($0, false) } }
                if !fromCentre.isEmpty { details += [("FROM CENTRE", true)] + fromCentre.map { ($0, false) } }
                details += inCentre.map { ($0, false) }
            }
            drawTooltip(&ctx, at: points[index], title: net.stations[index].name, details: details,
                        size: size, fontSize: fontSize, dotRadius: dotRadius, theme: t)
        }

        // Title and status line.
        ctx.draw(Text(net.title)
                    .font(.system(size: fontSize * 0.85, weight: .semibold))
                    .tracking(2)
                    .foregroundStyle(t.text),
                 at: CGPoint(x: size.width * 0.06, y: size.height * 0.055), anchor: .topLeading)
        ctx.draw(Text(statusText)
                    .font(.system(size: fontSize * 0.72).monospacedDigit())
                    .foregroundStyle(t.textMuted),
                 at: CGPoint(x: size.width * 0.94, y: size.height * 0.95), anchor: .bottomTrailing)
    }

    private var statusText: String {
        if feed.failed { return "no live data" }
        guard let t = feed.lastUpdate else { return "connecting…" }
        return "\(feed.tramCount) \(feed.network.noun)  ·  \(t.formatted(date: .omitted, time: .shortened))"
    }

    private func nearest(to p: CGPoint, in points: [CGPoint], within limit: CGFloat) -> Int? {
        var best: (distance: CGFloat, index: Int)?
        for (i, c) in points.enumerated() {
            let d = hypot(c.x - p.x, c.y - p.y)
            if d < (best?.distance ?? .infinity) { best = (d, i) }
        }
        guard let best, best.distance <= limit else { return nil }
        return best.index
    }

    /// A small label above the hovered dot (below it if there's no room).
    /// true: heading towards the centre; false: away from it; nil: unknown.
    /// Lines that start in the centre (the buses) say which direction code goes inbound.
    /// Otherwise (trams, which cross the centre) compare this stop's distance from the
    /// centre with the next stop's; within ~700 m of the centre that means little, so nil.
    private func centreDirection(of v: LitStation, at station: Int, in net: TramNetwork) -> Bool? {
        if let inbound = net.towardsCentre?[v.route] {
            // Compare where the trip starts, so variants like "b-c-a" count with "b-a".
            func start(_ d: String) -> Substring? { TramFeed.normalise(d).split(separator: "-").first }
            if let mine = start(v.direction), let theirs = start(inbound) { return mine == theirs }
        }
        guard let next = v.next else { return nil }
        let centre = (lat: 56.9479, lon: 24.1162)   // Stacijas laukums
        func km(_ s: Station) -> Double {
            hypot((s.lat - centre.lat) * 111.32, (s.lon - centre.lon) * 111.32 * cos(centre.lat * .pi / 180))
        }
        let here = km(net.stations[station]), there = km(net.stations[next])
        if max(here, there) < 0.7 { return nil }
        return there < here
    }

    private func drawTooltip(_ ctx: inout GraphicsContext, at c: CGPoint, title: String,
                             details: [(text: String, isHeading: Bool)],
                             size: CGSize, fontSize: CGFloat, dotRadius: CGFloat, theme t: Theme) {
        ctx.stroke(circle(c, dotRadius + 3), with: .color(t.text.opacity(0.9)), lineWidth: 1)
        let name = ctx.resolve(Text(title).font(.system(size: fontSize, weight: .semibold)).foregroundStyle(t.text))
        let subs = details.map { d in
            d.isHeading
                ? ctx.resolve(Text(d.text).font(.system(size: fontSize * 0.62, weight: .semibold)).tracking(1)
                                .foregroundStyle(t.textMuted))
                : ctx.resolve(Text(d.text).font(.system(size: fontSize * 0.8)).foregroundStyle(t.text.opacity(0.85)))
        }
        let nameSize = name.measure(in: size)
        let subSizes = subs.map { $0.measure(in: size) }
        let pad: CGFloat = 6
        let w = max(nameSize.width, subSizes.map(\.width).max() ?? 0) + pad * 2
        let h = nameSize.height + subSizes.reduce(0) { $0 + $1.height + 2 } + pad * 2
        var y = c.y - dotRadius - 8 - h
        if y < 4 { y = c.y + dotRadius + 8 }
        let x = min(max(c.x - w / 2, 4), size.width - w - 4)
        let pill = Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: 6)
        ctx.fill(pill, with: .color(t.backgroundAlt.opacity(0.96)))
        ctx.stroke(pill, with: .color(t.border), lineWidth: 1)
        ctx.draw(name, at: CGPoint(x: x + pad, y: y + pad), anchor: .topLeading)
        var lineY = y + pad + nameSize.height + 2
        for (sub, subSize) in zip(subs, subSizes) {
            ctx.draw(sub, at: CGPoint(x: x + pad, y: lineY), anchor: .topLeading)
            lineY += subSize.height + 2
        }
    }

    /// Small triangle just outside a dot, pointing from it towards `target`.
    private func arrow(from c: CGPoint, towards target: CGPoint, dotRadius r: CGFloat) -> Path {
        let dx = target.x - c.x, dy = target.y - c.y
        let length = max(hypot(dx, dy), 0.001)
        let u = CGPoint(x: dx / length, y: dy / length)      // direction of travel
        let v = CGPoint(x: -u.y, y: u.x)                      // sideways
        let tip = CGPoint(x: c.x + u.x * r * 2.7, y: c.y + u.y * r * 2.7)
        let base = CGPoint(x: c.x + u.x * r * 1.7, y: c.y + u.y * r * 1.7)
        var p = Path()
        p.move(to: tip)
        p.addLine(to: CGPoint(x: base.x + v.x * r * 0.7, y: base.y + v.y * r * 0.7))
        p.addLine(to: CGPoint(x: base.x - v.x * r * 0.7, y: base.y - v.y * r * 0.7))
        p.closeSubpath()
        return p
    }

    private func circle(_ c: CGPoint, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}
