import AppKit
import SwiftUI

/// Programmatic brick animation for the menu bar icon during the PROCESSING state.
///
/// Generates 12 frames at 18x18pt (36x36px @2x) using Core Graphics paths.
/// The animation cycles through:
///   - Frames 0-3: Bricks stacking into a pyramid (one brick per frame)
///   - Frames 4-5: Pyramid collapses into a heap
///   - Frames 6-9: Bricks form a rectangle
///   - Frames 10-11: Rectangle collapses, then loop
///
/// All frames use `isTemplate = true` so macOS adapts them to light/dark menu bar.
class BrickAnimator: ObservableObject {
    static let frameCount = 12
    static let frameSize = CGSize(width: 18, height: 18)

    @Published var currentFrameIndex: Int = 0

    private var timer: Timer?
    private let frames: [NSImage]

    /// The current frame as an `NSImage` suitable for `statusItem.button?.image`.
    var currentFrame: NSImage {
        frames[currentFrameIndex]
    }

    init() {
        frames = BrickAnimator.generateFrames()
    }

    // MARK: - Timer Control

    /// Start cycling frames at 0.25s intervals.
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                self.currentFrameIndex = (self.currentFrameIndex + 1) % BrickAnimator.frameCount
            }
        }
    }

    /// Stop the animation and reset to frame 0.
    func stop() {
        timer?.invalidate()
        timer = nil
        currentFrameIndex = 0
    }

    // MARK: - Frame Generation

    /// Generates all 12 animation frames programmatically.
    static func generateFrames() -> [NSImage] {
        (0..<frameCount).map { generateFrame(index: $0) }
    }

    private static func generateFrame(index: Int) -> NSImage {
        let image = NSImage(size: frameSize, flipped: false) { rect in
            let ctx = NSGraphicsContext.current!.cgContext

            // Brick dimensions in points
            let brickW: CGFloat = 5
            let brickH: CGFloat = 3
            let gap: CGFloat = 0.5

            // Canvas origin is bottom-left
            let baseY: CGFloat = 2

            let bricks: [(CGFloat, CGFloat)]

            switch index {
            // Frames 0-3: Pyramid stacking — one brick appears per frame
            case 0:
                // Single brick at center bottom
                bricks = [
                    (6.5, baseY)
                ]
            case 1:
                // Two bricks side by side at bottom
                bricks = [
                    (3.5, baseY),
                    (9.5, baseY)
                ]
            case 2:
                // Two at bottom, one on top center
                bricks = [
                    (3.5, baseY),
                    (9.5, baseY),
                    (6.5, baseY + brickH + gap)
                ]
            case 3:
                // Full pyramid: 3 bottom, 2 middle, 1 top
                bricks = [
                    (1.0, baseY),
                    (6.5, baseY),
                    (12.0, baseY),
                    (3.5, baseY + brickH + gap),
                    (9.5, baseY + brickH + gap),
                    (6.5, baseY + 2 * (brickH + gap))
                ]

            // Frames 4-5: Pyramid collapses into a heap
            case 4:
                // Bricks sliding down and spreading
                bricks = [
                    (1.0, baseY),
                    (6.0, baseY),
                    (11.0, baseY),
                    (3.0, baseY + brickH + gap),
                    (8.5, baseY + brickH + gap),
                    (5.5, baseY + 0.5)
                ]
            case 5:
                // Collapsed heap — all near bottom, scattered
                bricks = [
                    (0.5, baseY),
                    (4.5, baseY),
                    (8.5, baseY),
                    (12.5, baseY),
                    (2.5, baseY + brickH + gap),
                    (6.5, baseY + brickH + gap)
                ]

            // Frames 6-9: Bricks forming a rectangle
            case 6:
                // Start arranging into grid — bottom row forming
                bricks = [
                    (1.5, baseY),
                    (7.0, baseY),
                    (12.0, baseY),
                    (4.0, baseY + brickH + gap),
                    (9.5, baseY + brickH + gap),
                    (6.5, baseY + 2 * (brickH + gap))
                ]
            case 7:
                // Tighter grid
                bricks = [
                    (1.5, baseY),
                    (7.0, baseY),
                    (12.0, baseY),
                    (1.5, baseY + brickH + gap),
                    (7.0, baseY + brickH + gap),
                    (12.0, baseY + brickH + gap)
                ]
            case 8:
                // Almost perfect rectangle (2x3 grid)
                bricks = [
                    (2.0, baseY),
                    (7.0, baseY),
                    (12.0, baseY),
                    (2.0, baseY + brickH + gap),
                    (7.0, baseY + brickH + gap),
                    (12.0, baseY + brickH + gap)
                ]
            case 9:
                // Perfect rectangle
                bricks = [
                    (1.5, baseY),
                    (6.75, baseY),
                    (12.0, baseY),
                    (1.5, baseY + brickH + gap),
                    (6.75, baseY + brickH + gap),
                    (12.0, baseY + brickH + gap)
                ]

            // Frames 10-11: Rectangle collapses, loop back
            case 10:
                // Rectangle breaking apart
                bricks = [
                    (1.0, baseY),
                    (7.0, baseY + 1),
                    (12.5, baseY),
                    (2.0, baseY + brickH + gap + 1),
                    (8.0, baseY + brickH + gap),
                    (13.0, baseY + brickH + gap - 1)
                ]
            case 11:
                // Fully collapsed — nearly empty, just remnants
                bricks = [
                    (3.0, baseY),
                    (9.0, baseY),
                    (6.0, baseY + 0.5)
                ]

            default:
                bricks = []
            }

            // Draw each brick
            ctx.setFillColor(NSColor.black.cgColor)
            for (x, y) in bricks {
                let brickRect = CGRect(x: x, y: y, width: brickW, height: brickH)
                let path = CGPath(roundedRect: brickRect,
                                  cornerWidth: 0.5,
                                  cornerHeight: 0.5,
                                  transform: nil)
                ctx.addPath(path)
                ctx.fillPath()
            }

            return true
        }

        image.isTemplate = true
        return image
    }
}

// MARK: - SwiftUI Menu Bar Icon View

/// A SwiftUI view that displays the animated brick icon in the menu bar label.
/// Used by `MeetingRecorderApp` in the `.processing` state.
struct BrickAnimationMenuBarIcon: View {
    @StateObject private var animator = BrickAnimator()
    var tooltip: String = "Processing audio..."

    var body: some View {
        Image(nsImage: animator.currentFrame)
            .help(tooltip)
            .onAppear {
                animator.start()
            }
            .onDisappear {
                animator.stop()
            }
    }
}
