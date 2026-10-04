import SwiftUI

/// Turns raw per-frame peaks into display values: instant attack, 24 dB/s release,
/// a 1.5 s peak hold and a 2 s clip latch.
final class MeterBallistics {
    struct Channel: Equatable {
        var level: Float = -120
        var hold: Float = -120
        fileprivate var holdUntil = Date.distantPast
        fileprivate var clipUntil = Date.distantPast
        var clipping: Bool { clipUntil > Date() }
    }

    /// Indices 0-3 are the transmitters, 4 the stream mix, 5 the venue mix.
    private(set) var channels = [Channel](repeating: Channel(), count: 6)
    private var last = Date()

    func update(_ meters: AudioCoreMeters, now: Date) {
        let dt = Float(min(now.timeIntervalSince(last), 0.25))
        last = now
        let peaks = withUnsafeBytes(of: meters.peak) { Array($0.bindMemory(to: Float.self)) } + [meters.streamPeak, meters.venuePeak]
        for (i, peak) in peaks.enumerated() {
            let db = peak > 0 ? 20 * log10(peak) : -120
            var c = channels[i]
            c.level = max(db, c.level - 24 * dt)
            if db >= c.hold || now > c.holdUntil {
                c.hold = max(db, c.hold - 24 * dt)
                if db >= c.hold { c.holdUntil = now.addingTimeInterval(1.5) }
            }
            if peak >= 0.999 { c.clipUntil = now.addingTimeInterval(2) }
            channels[i] = c
        }
    }
}

/// Hardware-style LED ladder: 30 segments of 2 dB from -60 dBFS to 0.
struct LEDMeter: View {
    let channel: MeterBallistics.Channel
    var dimmed = false

    static let floor: Float = -60
    static let segments = 30

    var body: some View {
        Canvas { context, size in
            let n = Self.segments
            let gap: CGFloat = 2
            let height = (size.height - gap * CGFloat(n - 1)) / CGFloat(n)
            let lit = Self.segmentIndex(channel.level)
            let hold = Self.segmentIndex(channel.hold)
            for i in 0..<n {
                let top = Self.floor + Float(i + 1) * 2
                let color = top > -3 ? Console.red : (top > -12 ? Console.amber : Console.green)
                let on = i < lit || (i == hold - 1 && hold > 0) || (i == n - 1 && channel.clipping)
                let y = size.height - CGFloat(i + 1) * height - CGFloat(i) * gap
                let rect = CGRect(x: 0, y: y, width: size.width, height: height)
                let opacity = on ? (dimmed ? 0.3 : 1) : 0.09
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color.opacity(opacity)))
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Level")
        .accessibilityValue(channel.level <= Self.floor ? "Silent" : String(format: "%.0f dB", channel.level))
    }

    /// Number of lit segments for a level.
    static func segmentIndex(_ db: Float) -> Int {
        Int(((max(db, floor) - floor) / 2).rounded(.down))
    }

    static func fraction(_ db: Float) -> CGFloat {
        CGFloat((max(db, floor) - floor) / -floor)
    }
}

/// dBFS labels aligned to `LEDMeter`.
struct MeterScale: View {
    var body: some View {
        GeometryReader { geo in
            ForEach([0, -6, -12, -18, -30, -45], id: \.self) { db in
                Text("\(db)")
                    .font(.scale)
                    .foregroundStyle(Console.engraving)
                    .position(x: geo.size.width / 2, y: (1 - LEDMeter.fraction(Float(db))) * geo.size.height)
            }
        }
        .frame(width: 18)
        .accessibilityHidden(true)
    }
}

/// Vertical fader in dB; the bottom of the travel is silence. Drag to move, double-click for 0 dB.
struct FaderView: View {
    @Binding var value: Double
    var label: String
    var range: ClosedRange<Double> = -60...12
    @State private var dragStart: Double?

    private let capHeight: CGFloat = 26

    var body: some View {
        GeometryReader { geo in
            let travel = max(geo.size.height - capHeight, 1)
            let span = range.upperBound - range.lowerBound
            let position = (value - range.lowerBound) / span
            let zero = (0 - range.lowerBound) / span
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Console.well)
                    .frame(width: 6)
                    .padding(.vertical, capHeight / 2)
                Rectangle()
                    .fill(Console.engraving)
                    .frame(width: 22, height: 1)
                    .offset(y: -(zero * travel + capHeight / 2))
                RoundedRectangle(cornerRadius: 3)
                    .fill(Console.engraving)
                    .overlay(Rectangle().fill(Console.ink).frame(height: 2))
                    .frame(width: 36, height: capHeight)
                    .offset(y: -(position * travel))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { g in
                        let start = dragStart ?? value
                        dragStart = start
                        set(start - Double(g.translation.height) / travel * span)
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .onTapGesture(count: 2) { value = 0 }
        }
        .frame(width: 40)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(value.dbLabel)
        .accessibilityAdjustableAction { direction in
            set(value + (direction == .increment ? 1 : -1))
        }
    }

    private func set(_ next: Double) {
        value = (min(max(next, range.lowerBound), range.upperBound) * 2).rounded() / 2
    }
}

extension Double {
    var dbLabel: String {
        self <= -60 ? "Off" : (self == 0 ? "0 dB" : String(format: "%+.1f dB", self))
    }
}
