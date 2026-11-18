import CoreGraphics
import Testing

@testable import PeeringKit

@Suite("Recognising a book-shaped screen")
struct ScreenShapeTests {
    @Test("the foldable's outer display, in either orientation, is book shaped")
    func foldableOuterDisplay() {
        #expect(ScreenShape.isBookShaped(size: CGSize(width: 1398, height: 2034)))
        #expect(ScreenShape.isBookShaped(size: CGSize(width: 2034, height: 1398)))
    }

    @Test("an ordinary phone is not")
    func ordinaryPhone() {
        #expect(!ScreenShape.isBookShaped(size: CGSize(width: 1320, height: 2868)))
        #expect(!ScreenShape.isBookShaped(size: CGSize(width: 1170, height: 2532)))
    }

    @Test("an empty size is not")
    func emptySize() {
        #expect(!ScreenShape.isBookShaped(size: .zero))
    }
}
