import SwiftUI

// MARK: - Battery 12-Hour History Chart View
struct BatteryChartView: View {
    let historyPoints: [HistoryPoint]
    let chartLabels: [String]
    let isDark: Bool
    let colorLabel: Color
    let colorDivider: Color
    let colorCardStroke: Color
    let chartBg: Color
    let emeraldGreen: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4.5) {
            Text("Biểu đồ 12 giờ qua")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(colorLabel)

            ZStack(alignment: .leading) {
                // Grid background lines with perfectly padded and aligned right labels
                VStack(spacing: 0) {
                    // 100% Level
                    HStack(spacing: 4) {
                        Rectangle()
                            .fill(colorDivider)
                            .frame(height: 0.8)
                        Text("100%")
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundColor(colorLabel)
                            .frame(width: 32, alignment: .trailing)
                    }
                    
                    Spacer()
                    
                    // 50% Level
                    HStack(spacing: 4) {
                        Rectangle()
                            .fill(colorDivider)
                            .frame(height: 0.8)
                        Text("50%")
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundColor(colorLabel)
                            .frame(width: 32, alignment: .trailing)
                    }
                    
                    Spacer()
                    
                    // 0% Level
                    HStack(spacing: 4) {
                        Rectangle()
                            .fill(colorDivider)
                            .frame(height: 0.8)
                        Text("0%")
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundColor(colorLabel)
                            .frame(width: 32, alignment: .trailing)
                    }
                }
                .padding(.leading, 8)
                .padding(.trailing, 8)
                .padding(.vertical, 7)

                // Green Chart Line & Gradient Fill (mapped precisely within grid)
                GeometryReader { geo in
                    let insetLeft: CGFloat = 8
                    let insetTop: CGFloat = 7
                    let insetBottom: CGFloat = 7
                    let labelWidth: CGFloat = 40
                    let w = geo.size.width - insetLeft - labelWidth
                    let h = geo.size.height - insetTop - insetBottom

                    // Area Path
                    Path { path in
                        guard historyPoints.count > 1 else { return }
                        let step = w / CGFloat(historyPoints.count - 1)

                        path.move(to: CGPoint(x: insetLeft, y: insetTop + h * (1.0 - historyPoints[0].pct)))
                        for (i, pt) in historyPoints.enumerated() {
                            let x = insetLeft + CGFloat(i) * step
                            let y = insetTop + h * (1.0 - pt.pct)
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                        path.addLine(to: CGPoint(x: insetLeft + w, y: insetTop + h))
                        path.addLine(to: CGPoint(x: insetLeft, y: insetTop + h))
                        path.closeSubpath()
                    }
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                emeraldGreen.opacity(isDark ? 0.35 : 0.28),
                                emeraldGreen.opacity(0.0)
                            ]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    // Line Path
                    Path { path in
                        guard historyPoints.count > 1 else { return }
                        let step = w / CGFloat(historyPoints.count - 1)

                        path.move(to: CGPoint(x: insetLeft, y: insetTop + h * (1.0 - historyPoints[0].pct)))
                        for (i, pt) in historyPoints.enumerated() {
                            let x = insetLeft + CGFloat(i) * step
                            let y = insetTop + h * (1.0 - pt.pct)
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                    .stroke(
                        emeraldGreen,
                        style: StrokeStyle(lineWidth: 2.0, lineCap: .round, lineJoin: .round)
                    )
                }
            }
            .frame(height: 74)
            .background(chartBg)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(colorCardStroke, lineWidth: 1)
            )
            .cornerRadius(6)

            // Time Labels below chart (dynamically aligned with 12-hour window)
            HStack {
                Text(chartLabels.indices.contains(0) ? chartLabels[0] : "")
                Spacer()
                Text(chartLabels.indices.contains(1) ? chartLabels[1] : "")
                Spacer()
                Text(chartLabels.indices.contains(2) ? chartLabels[2] : "")
                Spacer()
                Text(chartLabels.indices.contains(3) ? chartLabels[3] : "")
                Spacer()
                Text("")
                    .frame(width: 32)
            }
            .font(.system(size: 9, weight: .regular))
            .foregroundColor(colorLabel)
            .padding(.leading, 8)
            .padding(.trailing, 8)
        }
    }
}
