import AppKit
import SwiftUI
import XCTest

@testable import NookClip

/// 面板环境光（Aurora）实机渲染校验。
///
/// 目的：确认 `nookClipAuroraBackground` 的渐变真的被画出来了、且落在正确的位置。
/// SwiftUI 层叠写错（渐变被不透明底色盖住、或压到文字上）在编译期完全看不出来，
/// 只有把面板真的渲染成位图、逐点采样才能证明。
///
/// 判定口径来自 `.taste-skill/gradient/` 的静态原型实测：
///   · 顶部薄雾：面板顶部 1px 行 与 中部行的颜色必须**不同**（否则说明渐变没生效）；
///   · 冷光是右锚的：右侧详情画布顶部右侧必须比同高度中部更亮/更蓝；
///   · 列表列左侧（搜索框与分类胶囊所在）不得被冷光染色——这是把参考稿
///     左锚极光改成右锚的全部理由。
@MainActor
final class AuroraRenderTests: XCTestCase {

    // MARK: - 渲染工具

    /// 把任意 SwiftUI 视图渲染成位图（1x）。
    ///
    /// 用 `ImageRenderer` 而不是 `NSHostingView.cacheDisplay`：后者对 SwiftUI 的
    /// 渐变/半透明层会截出整片白（实测连纯红渐变都截成 rgb(255,254,255)），
    /// 会让「渐变没画出来」和「截图工具不行」无法区分。
    private func render<V: View>(_ view: V, size: CGSize) -> NSBitmapImageRep? {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 1
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep
    }

    private struct RGB: CustomStringConvertible {
        let r: Int, g: Int, b: Int
        var description: String { "rgb(\(r),\(g),\(b))" }
        /// 与另一色的最大通道差，用来判断「是否肉眼可辨」
        func distance(to other: RGB) -> Int {
            max(abs(r - other.r), max(abs(g - other.g), abs(b - other.b)))
        }
    }

    private func pixel(_ rep: NSBitmapImageRep, x: Int, y: Int) -> RGB? {
        guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh else { return nil }
        guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return nil }
        return RGB(
            r: Int(color.redComponent * 255),
            g: Int(color.greenComponent * 255),
            b: Int(color.blueComponent * 255)
        )
    }

    // MARK: - 关键几何：直接把 aurora 叠在白底上渲染

    /// 顶部薄雾：同一列，顶部与中部的颜色必须不同。
    func testMistIsActuallyDrawn() throws {
        let size = CGSize(width: 360, height: 400)
        // 内容层必须透明：aurora 挂在 background 上，不透明的内容会把它整个盖住
        let view = Color.clear
            .nookClipAuroraBackground(base: { Color.white }, previewGlow: false)

        guard let rep = render(view, size: size) else {
            return XCTFail("渲染失败")
        }

        let cx = Int(size.width / 2)
        guard let top = pixel(rep, x: cx, y: 2),
              let mid = pixel(rep, x: cx, y: Int(size.height) - 2) else {
            return XCTFail("采样失败")
        }

        XCTAssertGreaterThan(
            top.distance(to: mid), 0,
            "顶部薄雾未生效：顶部 \(top) 与中部 \(mid) 完全相同（渐变被盖住或未绘制）"
        )
        XCTAssertGreaterThanOrEqual(top.b, top.r, "薄雾应偏冷（蓝 ≥ 红），实测 \(top)")
    }

    /// 冷光锚在右上：右上角必须比同高度的中部更「有光」，且中部接近纯底色。
    func testCoolGlowAnchorsToRightEdge() throws {
        let size = CGSize(width: 440, height: 400)
        let view = Color.clear
            .nookClipAuroraBackground(base: { Color.white }, previewGlow: true)

        guard let rep = render(view, size: size) else {
            return XCTFail("渲染失败")
        }

        guard let rightTop = pixel(rep, x: Int(size.width) - 4, y: 4),
              let center = pixel(rep, x: Int(size.width / 2), y: Int(size.height / 2)) else {
            return XCTFail("采样失败")
        }

        XCTAssertGreaterThan(
            rightTop.distance(to: center), 0,
            "冷光未落在右上角：\(rightTop) 与中心 \(center) 相同"
        )
        XCTAssertGreaterThan(rightTop.b, rightTop.r, "冷光应偏蓝，实测 \(rightTop)")
    }

    /// 左列不挂 previewGlow 时，右缘不得出现冷光/暖光，只剩顶部薄雾。
    func testListColumnHasNoSideGlow() throws {
        let size = CGSize(width: 320, height: 400)
        let view = Color.clear
            .nookClipAuroraBackground(base: { Color.white }, previewGlow: false)

        guard let rep = render(view, size: size) else {
            return XCTFail("渲染失败")
        }

        // 同一行（纵向避开薄雾区）上，左缘与右缘应完全一致
        let y = Int(size.height * 0.75)
        guard let left = pixel(rep, x: 4, y: y),
              let right = pixel(rep, x: Int(size.width) - 4, y: y) else {
            return XCTFail("采样失败")
        }
        XCTAssertEqual(
            left.r, right.r,
            "列表列不该有左右向的光晕，实测左 \(left) / 右 \(right)"
        )
        XCTAssertEqual(
            left.b, right.b,
            "列表列不该有左右向的光晕，实测左 \(left) / 右 \(right)"
        )
    }

    /// 双模式都要有光：深色下薄雾不得被底色吞掉。
    func testMistVisibleInDarkAppearance() throws {
        let size = CGSize(width: 360, height: 400)
        let view = Color.clear
            .nookClipAuroraBackground(base: { Color.black }, previewGlow: false)
            .environment(\.colorScheme, .dark)

        guard let rep = render(view, size: size) else {
            return XCTFail("渲染失败")
        }

        let cx = Int(size.width / 2)
        guard let top = pixel(rep, x: cx, y: 2),
              let mid = pixel(rep, x: cx, y: Int(size.height) - 2) else {
            return XCTFail("采样失败")
        }
        XCTAssertGreaterThan(
            top.distance(to: mid), 0,
            "深色下薄雾未生效：顶部 \(top) 与中部 \(mid) 相同"
        )
    }

    /// 预览区必须整块被环境光覆盖：四个角都要带色，不能只有右半边。
    ///
    /// 回归的是这个 bug：`endRadiusFraction: 0.95`（≈半宽）时渐变只铺到右半边，
    /// 左侧 x<40% 是纯白 255,255,255，读起来像「只染了一半」。
    func testPreviewGlowCoversWholeArea() throws {
        let size = CGSize(width: 440, height: 600)
        let view = Color.clear
            .nookClipAuroraBackground(base: { Color.white }, previewGlow: true)

        guard let rep = render(view, size: size) else { return XCTFail("渲染失败") }

        let w = Int(size.width), h = Int(size.height)
        // 采样点必须避开顶部薄雾（薄雾会盖住顶部两个角，让「只染一半」测不出来）：
        // 旧半径 0.95 时，左中与左下是纯白 255,254,255，这才是真正的症状位置。
        let points: [(String, Int, Int)] = [
            ("左中", 6, h / 2), ("左下", 6, h - 6),
            ("右中", w - 6, h / 2), ("右下", w - 6, h - 6)
        ]
        let pureWhite = RGB(r: 255, g: 255, b: 255)
        for (name, x, y) in points {
            guard let c = pixel(rep, x: x, y: y) else { return XCTFail("采样失败") }
            XCTAssertGreaterThan(
                c.distance(to: pureWhite), 1,
                "\(name)仍是纯白 \(c)：渐变没铺满整块画布（只染了一半）"
            )
        }
    }

    // 说明：不对完整 MainView 做位图断言。
    // ImageRenderer 无法绘制 AppKit 承载的子视图（NSSearchField、NSVisualEffectView），
    // 整窗渲染出来是占位图与错色，断言只会测到渲染器的缺陷、而不是面板本身。
}
