import SwiftUI

extension View {
    /// Briefly crumples the view toward its top corner, like the icon's paper,
    /// whenever `trigger` changes. Stays still with Reduce Motion.
    func mehCrumple(trigger: Int) -> some View {
        modifier(MehCrumple(trigger: trigger))
    }
}

private struct MehCrumple: ViewModifier {
    let trigger: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Pose {
        var scale = 1.0
        var angle = 0.0
    }

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: Pose(), trigger: trigger) { content, pose in
            content
                .scaleEffect(reduceMotion ? 1 : pose.scale, anchor: .topTrailing)
                .rotationEffect(.degrees(reduceMotion ? 0 : pose.angle), anchor: .topTrailing)
        } keyframes: { _ in
            KeyframeTrack(\.scale) {
                CubicKeyframe(0.86, duration: 0.18)
                SpringKeyframe(1, duration: 0.42, spring: .bouncy)
            }
            KeyframeTrack(\.angle) {
                CubicKeyframe(-5, duration: 0.18)
                SpringKeyframe(0, duration: 0.42, spring: .bouncy)
            }
        }
    }
}
