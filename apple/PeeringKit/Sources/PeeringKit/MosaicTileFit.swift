import CoreGraphics

/// Where a window's own picture sits inside one tile of an arrangement, and how big that tile's
/// capture is built.
public enum MosaicTileFit {
    public static func windowRect(sourceSize: CGSize, in tile: CGRect) -> CGRect? {
        guard sourceSize.width > 0, sourceSize.height > 0,
              tile.width > 0, tile.height > 0
        else { return nil }

        let scale = min(tile.width / sourceSize.width, tile.height / sourceSize.height)
        let size = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        return CGRect(
            x: tile.midX - size.width / 2,
            y: tile.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    /// The size a tile's own capture is configured at.
    public static func surface(sourceSize: CGSize, tilePixels: CGRect) -> CGSize? {
        guard let fitted = windowRect(sourceSize: sourceSize, in: tilePixels) else { return nil }

        func even(_ value: CGFloat) -> CGFloat {
            max(2, (value / 2).rounded() * 2)
        }
        return CGSize(
            width: even(min(fitted.width, sourceSize.width)),
            height: even(min(fitted.height, sourceSize.height))
        )
    }
}
