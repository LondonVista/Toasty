import SwiftUI

/// The glass card. Laid out at the widget's full width (212 pt) and scaled like the widget.
struct CardView: View {
    @ObservedObject var warmer: Warmer
    @ObservedObject var look: Look

    static let baseWidth: CGFloat = 212
    static let baseHeight: CGFloat = 242

    private let orange = Color(red: 1, green: 0.62, blue: 0.04)   // #FF9F0A
    private let blue = Color(red: 0.39, green: 0.82, blue: 1)     // #64D2FF

    var body: some View {
        card
            .frame(width: Self.baseWidth, height: Self.baseHeight)
            .scaleEffect(look.scale, anchor: .topLeading)
            .frame(width: Self.baseWidth * look.scale, height: Self.baseHeight * look.scale, alignment: .topLeading)
    }

    private var card: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(red: 0.11, green: 0.11, blue: 0.12).opacity(look.opacity))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.18), lineWidth: 1))
                .shadow(color: Color.black.opacity(0.55), radius: 8, y: 3)

            VStack(alignment: .leading, spacing: 7) {
                header
                bigTemperature
                progressBar
                stepperRow("Target", warmer.target) { warmer.nudgeTarget(by: $0) }
                stepperRow("Reheat at", warmer.effectiveReheatAt) { warmer.nudgeReheat(by: $0) }
                row("Heater", "\(Int((warmer.duty * 100).rounded()))%")
                row("Status", warmer.status, color: statusColor)
                cores
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: warmer.isWarming ? "flame.fill" : "flame")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(warmer.isWarming ? orange : .white.opacity(0.5))
            Text("Toasty")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
            Spacer()
            Button(action: warmer.toggle) {
                Image(systemName: "power")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(warmer.isWarming ? .black : .white.opacity(0.6))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(warmer.isWarming ? orange : Color.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .help(warmer.isWarming ? "Stop warming" : "Start warming")
        }
    }

    private var bigTemperature: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("Palm rest")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
            Spacer()
            Text(warmer.reading.battery.map { String(format: "%.1f°C", $0) } ?? "–")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundColor(temperatureColor.opacity(0.75))
        }
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(temperatureColor.opacity(0.45)).frame(width: geo.size.width * progress)
            }
        }
        .frame(height: 3)
    }

    private func stepperRow(_ title: String, _ value: Double, nudge: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.55))
            Spacer()
            stepButton("minus") { nudge(-1) }
            Text("\(Int(value))°C")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
                .frame(width: 38)
            stepButton("plus") { nudge(1) }
        }
    }

    private func stepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white.opacity(0.8))
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }

    /// One bar per core with its busy %, efficiency cores in blue then performance cores in orange.
    private var cores: some View {
        let loads = warmer.coreLoads
        let efficiency = warmer.coreMeter.efficiencyCount
        return VStack(spacing: 3) {
            HStack(spacing: 0) {
                Text("Efficiency")
                    .frame(maxWidth: .infinity)
                Text("Performance")
                    .frame(maxWidth: .infinity)
            }
            .font(.system(size: 8.5, weight: .medium))
            .foregroundColor(.white.opacity(0.45))

            HStack(spacing: 3) {
                ForEach(Array(loads.enumerated()), id: \.offset) { index, load in
                    coreBar(load, color: index < efficiency ? blue : orange)
                }
            }
        }
        .padding(.top, 2)
    }

    private func coreBar(_ load: Double, color: Color) -> some View {
        VStack(spacing: 2) {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.08))
                RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.6)).frame(height: 24 * load)
            }
            .frame(width: 10, height: 24)
            Text("\(Int((load * 100).rounded()))")
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
    }

    private func row(_ title: String, _ value: String, color: Color = .white) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.55))
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    /// 20 °C is an empty bar, the target is a full one.
    private var progress: CGFloat {
        guard let temp = warmer.reading.battery else { return 0 }
        return CGFloat(min(max((temp - 20) / (warmer.target - 20), 0), 1))
    }

    private var temperatureColor: Color {
        guard let temp = warmer.reading.battery else { return .white }
        return temp >= warmer.target - 0.5 ? orange : blue
    }

    private var statusColor: Color {
        switch warmer.status {
        case "Resting": return blue
        case "Warming up", "Reheating": return orange
        case "Off": return .white.opacity(0.6)
        default: return Color(red: 1, green: 0.84, blue: 0.04)          // #FFD60A
        }
    }
}

/// Scale and glass opacity, copied from the iPhone Battery Widget so both cards match.
final class Look: ObservableObject {
    @Published var scale: CGFloat = 1
    @Published var opacity: Double = 0.48
}
