import CoreGraphics
import Foundation

/// Keeps the overlay near the composer without covering messages or editable drafts.
public enum OverlayPlacement {
    public static func frame(
        size: CGSize, visibleFrame: CGRect, anchor: CGRect?, composer: CGRect?, protectedFrames: [CGRect]
    ) -> CGRect? {
        let screen = visibleFrame.insetBy(dx: 8, dy: 8)
        guard screen.width > 0, screen.height > 0 else { return nil }
        let obstacles = (protectedFrames + (composer.map { [$0] } ?? []))
            .filter { !$0.isEmpty && !$0.isNull }.map { $0.insetBy(dx: -6, dy: -6) }
        var regions = [screen]
        for obstacle in obstacles {
            regions = regions.flatMap { region -> [CGRect] in
                let overlap = region.intersection(obstacle)
                guard !overlap.isNull, !overlap.isEmpty else { return [region] }
                return [
                    CGRect(x: region.minX, y: region.minY, width: overlap.minX - region.minX, height: region.height),
                    CGRect(x: overlap.maxX, y: region.minY, width: region.maxX - overlap.maxX, height: region.height),
                    CGRect(x: region.minX, y: region.minY, width: region.width, height: overlap.minY - region.minY),
                    CGRect(x: region.minX, y: overlap.maxY, width: region.width, height: region.maxY - overlap.maxY),
                ].filter { $0.width >= 240 && $0.height >= 100 }
            }
        }
        let target = composer ?? anchor ?? CGRect(x: screen.maxX, y: screen.maxY, width: 0, height: 0)
        let candidates = regions.filter { $0.width >= 240 && $0.height >= 100 }.map { region in
            let width = min(size.width, region.width)
            let height = min(size.height, region.height)
            let x = min(max(target.maxX + 12, region.minX), region.maxX - width)
            let y = min(max(target.minY, region.minY), region.maxY - height)
            return CGRect(x: x, y: y, width: width, height: height)
        }
        // A nearby sliver must not force scrolling when the full popup fits elsewhere.
        let fullSize = candidates.filter { $0.width >= size.width && $0.height >= size.height }
        return (fullSize.isEmpty ? candidates : fullSize).min { lhs, rhs in
            func score(_ rect: CGRect) -> CGFloat {
                let dx = max(rect.minX - target.maxX, target.minX - rect.maxX, 0)
                let dy = max(rect.minY - target.maxY, target.minY - rect.maxY, 0)
                return hypot(dx, dy) + (size.width - rect.width) * 3 + (size.height - rect.height) * 0.5
            }
            return score(lhs) < score(rhs)
        }
    }
}
