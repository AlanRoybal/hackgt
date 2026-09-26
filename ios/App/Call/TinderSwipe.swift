import DesignSystem
import SwiftUI

enum SwipeDirection { case left, right }

/// Tinder-style swipe: the view follows the finger with a slight tilt; released past the threshold (or flung)
/// it flies off that side and `onSwipe` fires once it's gone, otherwise it springs back. The caller owns `offset`
/// so it can fade in hints or react to the drag. Reduce Motion drops the tilt.
struct TinderSwipe: ViewModifier {
    @Binding var offset: CGSize
    var isEnabled = true
    var threshold: CGFloat = 110
    let onSwipe: (SwipeDirection) -> Void
    @State private var width: CGFloat = 400
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .offset(x: offset.width, y: offset.height * 0.4)
            .rotationEffect(.degrees(reduceMotion ? 0 : offset.width / 20))
            .gesture(drag, including: isEnabled ? .all : .subviews)
    }

    var drag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { offset = $0.translation }
            .onEnded { v in
                let x = abs(v.predictedEndTranslation.width) > abs(v.translation.width) * 2 ? v.predictedEndTranslation.width : v.translation.width
                guard abs(x) > threshold else {
                    withAnimation(Motion.resolved(Motion.snap, reduceMotion: reduceMotion)) { offset = .zero }
                    return
                }
                let direction: SwipeDirection = x > 0 ? .right : .left
                let flyTo = CGSize(width: (x > 0 ? 1 : -1) * (width * 1.5 + 200), height: v.translation.height * 2)
                withAnimation(.easeOut(duration: 0.28)) { offset = flyTo } completion: { onSwipe(direction) }
            }
    }
}

extension View {
    func tinderSwipe(offset: Binding<CGSize>, isEnabled: Bool = true, threshold: CGFloat = 110,
                     onSwipe: @escaping (SwipeDirection) -> Void) -> some View {
        modifier(TinderSwipe(offset: offset, isEnabled: isEnabled, threshold: threshold, onSwipe: onSwipe))
    }
}

/// A stamp that fades in as a swipe heads toward its side ("Show", "Not now", "Stop showing").
struct SwipeStamp: View {
    let text: String
    let systemImage: String
    let tint: Color
    let progress: CGFloat

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.headline)
            .foregroundStyle(tint)
            .padding(.horizontal, Space.s).padding(.vertical, Space.xs)
            .background(.white.opacity(0.92), in: Capsule())
            .overlay(Capsule().strokeBorder(tint, lineWidth: 2))
            .opacity(min(max(progress, 0), 1))
            .scaleEffect(0.85 + 0.15 * min(max(progress, 0), 1))
            .accessibilityHidden(true)
    }
}
