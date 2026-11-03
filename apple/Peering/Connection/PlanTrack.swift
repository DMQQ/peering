import PeeringKit
import RemoteCore
import SwiftUI

/// The agent's own plan as a row of segments, with the step it is on named under it.
struct PlanTrack: View {
    let plan: AgentPlanProgress
    let isRunning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if plan.total <= 14 {
                HStack(spacing: 3) {
                    ForEach(Array(plan.steps.enumerated()), id: \.offset) { _, step in
                        segment(step.status)
                    }
                }
            } else {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.12))
                        Capsule().fill(.white.opacity(0.85))
                            .frame(width: geometry.size.width * CGFloat(plan.completed) / CGFloat(plan.total))
                    }
                }
                .frame(height: 4)
            }
            HStack(spacing: 6) {
                if let number = plan.currentNumber {
                    Text("Step \(number) of \(plan.total)")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                if let current = plan.current {
                    Text(verbatim: current.text)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .id(current.text)
                        .transition(.blurReplace)
                }
            }
            .animation(Motion.settle, value: plan.currentNumber)
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.7), value: plan.completed)
    }

    @ViewBuilder
    private func segment(_ status: AgentPlanStep.Status) -> some View {
        Capsule()
            .fill(status == .completed ? .white.opacity(0.85) : .white.opacity(status == .inProgress ? 0.4 : 0.12))
            .frame(height: 4)
            .overlay {
                if status == .inProgress, isRunning {
                    LiveTimeline { context in
                        let wave = (sin(context.date.timeIntervalSinceReferenceDate * 4) + 1) / 2
                        Capsule().fill(.white.opacity(0.2 + 0.6 * wave))
                    }
                }
            }
    }
}
