import AppKit
import SwiftUI

// MARK: - 复制 → 入队的飞行动画（specs/012-scrub-stack-pin · US2 迭代四）
//
// 要解决的问题：录制模式下用户按下 ⌘C 之后，队列里凭空多出一行。视觉上
// 「刚才复制的那句话」和「列表里这一行」之间没有任何联系，用户要自己完成
// 「哦，它进去了」的推理。飞行卡片把这层推理变成一次可见的位移：
// 内容从用户当下看的地方（鼠标位置）沿一条向上拱起的弧线落到它未来所在的
// 那一行上，落点即归位。
//
// 三个约束决定了实现方式：
//   · 不能挡住鼠标——整块浮层 `ignoresMouseEvents = true`，用户此刻正在别的
//     应用里干活，动画绝不能把点击吃掉。
//   · 不能抢焦点——`.nonactivatingPanel`，与队列浮窗同一套规矩。
//   · 落点必须精确——所以终点不是「估一个大概位置」，而是由队列浮窗按自己的
//     布局常量算出来的真实行矩形（`PasteStackPillPanel.screenRect(forRow:)`）。
//     飞行浮层与队列浮窗是两个窗口，用同一份布局常量对齐，才不会出现
//     「卡片停在行的上方 3pt」这种说不清的偏差。

// MARK: - 轨迹几何（纯函数，可单测）

/// 飞行动画的全部几何与插值规则。
///
/// 单独抽出来的理由：动画本身没法在单测里断言，但「起点、控制点、终点、
/// 某一刻的位置、缩放、透明度」都是纯函数，可以逐条断言。手感调参只改常量，
/// 不碰窗口与视图代码。
enum PasteStackFlightGeometry {

    /// 弧线高度相对起终点直线距离的比例（向上拱起）
    static let liftRatio: CGFloat = 0.22
    /// 弧线最低抬升量：起终点很近时也要有可见的弧度，否则看起来像直线平移
    static let minLift: CGFloat = 18
    /// 弧线最高抬升量：跨屏拖动时不至于飞到屏幕外
    static let maxLift: CGFloat = 140
    /// 卡片从起点到终点缩小的比例（终点那一行只有 26pt 高，等大落上去会显得突兀）
    static let endScale: CGFloat = 0.84
    /// 淡入占用的进度比例（开头这么一小段用来出现）
    static let fadeInEnd: Double = 0.12
    /// 淡出占用的进度比例（收尾交给真实行淡入，卡片自己先退场）
    static let fadeOutStart: Double = 0.82

    /// 二次贝塞尔控制点：取起终点中点，向上抬一段。
    ///
    /// 为什么向上而不是向下：队列浮窗贴在屏幕下方，起点通常在上方或同高，
    /// 向上拱起的弧线让卡片先「飘起来」再「落下去」，读起来是主动归位；
    /// 向下拱会先沉进屏幕边缘，看起来像掉了。
    static func controlPoint(from start: NSPoint, to end: NSPoint) -> NSPoint {
        let distance = hypot(end.x - start.x, end.y - start.y)
        let lift = min(max(distance * liftRatio, minLift), maxLift)
        return NSPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2 + lift)
    }

    /// 二次贝塞尔求值：`progress` 会被夹到 0…1
    static func point(progress: Double, from start: NSPoint, control: NSPoint, to end: NSPoint) -> NSPoint {
        let t = CGFloat(min(max(progress, 0), 1))
        let inverse = 1 - t
        let a = inverse * inverse
        let b = 2 * inverse * t
        let c = t * t
        return NSPoint(
            x: a * start.x + b * control.x + c * end.x,
            y: a * start.y + b * control.y + c * end.y
        )
    }

    /// 缩放：线性收一点，落点处与行高接近
    static func cardScale(progress: Double) -> CGFloat {
        let t = CGFloat(min(max(progress, 0), 1))
        return 1 - (1 - endScale) * t
    }

    /// 透明度：开头淡入、结尾淡出，中段全不透明
    static func cardOpacity(progress: Double) -> Double {
        let t = min(max(progress, 0), 1)
        if t < fadeInEnd {
            return t / fadeInEnd
        }
        if t > fadeOutStart {
            return (1 - t) / (1 - fadeOutStart)
        }
        return 1
    }

    /// 飞行浮层的窗口矩形：包住起点与终点，外扩一个卡片边距。
    ///
    /// 不能直接 `NSRect(x:y:width:0,height:0).union(end)`：宽或高为 0 的矩形
    /// `isEmpty` 为真，`NSUnionRect` 会把它整个忽略掉，起点就丢了——卡片
    /// 起飞位置被裁到窗口外，用户看到的是「凭空出现」。所以逐轴取极值。
    static func windowRect(from start: NSPoint, to end: NSRect, margin: CGFloat) -> NSRect {
        let minX = min(start.x, end.minX)
        let maxX = max(start.x, end.maxX)
        let minY = min(start.y, end.minY)
        let maxY = max(start.y, end.maxY)
        return NSRect(x: minX - margin, y: minY - margin,
                      width: maxX - minX + margin * 2,
                      height: maxY - minY + margin * 2)
    }
}

// MARK: - 浮层窗口

/// 飞行卡片的透明浮层：自己一个窗口，飞完即销毁。
///
/// 为什么不画在队列浮窗里：卡片起点可能在屏幕另一头，而窗口不能画到自己的
/// frame 之外。要让同一张卡片从任意位置飞到列表里，只能给它一个足够大的
/// 透明窗口，或者另起一个窗口——后者更干净，也不会影响队列浮窗的命中测试。
@MainActor
final class PasteStackFlightOverlay: NSPanel {

    /// 飞行时长。0.44s 是「看得清是同一段文字」与「不拖慢连续复制的节奏」的折中：
    /// 再短就不像飞行，再长会让连按两次 ⌘C 的卡片互相压住。
    static let duration: TimeInterval = 0.44
    /// 卡片高度：与队列行的 26pt 接近，落上去像是「缩小归位」而不是「换了个东西」
    static let cardHeight: CGFloat = 24
    /// 卡片最大宽度：摘要是整段文本，必须截断，否则浮层会横跨半个屏幕
    static let cardMaxWidth: CGFloat = 240
    /// 窗口相对内容外扩的边距：足够放下卡片本身 + 一点点投影
    static let windowMargin: CGFloat = 72
    /// 落点对齐时留给真实行的淡入时长
    static let handoffDuration: TimeInterval = 0.18

    /// 正在飞的浮层。必须强引用住——NSPanel 一旦被释放，动画会当场消失
    private static var active: [PasteStackFlightOverlay] = []

    private let summary: String
    private let startPoint: NSPoint
    private let controlPoint: NSPoint
    private let endPoint: NSPoint
    private let windowSize: NSSize
    private let onLanded: () -> Void
    private var isFinished = false

    /// 发起一次飞行。`completion` 在卡片落到目标行的那一刻回调（由调用方在那里
    /// 让真实行淡入），随后浮层自行销毁。
    static func launch(
        summary: String,
        from start: NSPoint,
        to end: NSRect,
        completion: @escaping () -> Void
    ) {
        // 尊重「减少动态效果」：系统级无障碍设置下不做位移动画，改为原地淡入
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            completion()
            return
        }
        let overlay = PasteStackFlightOverlay(summary: summary, from: start, to: end, completion: completion)
        active.append(overlay)
        overlay.orderFrontRegardless()
        overlay.scheduleFinish()
    }

    /// 立刻结束全部飞行（停止队列、退出录制时调用），并让被压着的真实行立即显形
    static func dismissAll() {
        let overlays = active
        active.removeAll()
        for overlay in overlays {
            overlay.finish()
        }
    }

    private init(summary: String, from start: NSPoint, to end: NSRect, completion: @escaping () -> Void) {
        self.summary = summary
        self.onLanded = completion

        // 终点取行的左侧中点：卡片从行的中间落下，而不是从行尾飞过来
        let target = NSPoint(x: end.midX, y: end.midY)
        // 起点若已经压在浮窗里（鼠标正好停在列表上），往上抬一段，
        // 否则飞行距离太短，看起来只是一次闪烁
        let resolvedStart: NSPoint
        if end.insetBy(dx: -20, dy: -40).contains(start) {
            resolvedStart = NSPoint(x: target.x, y: end.maxY + 96)
        } else {
            resolvedStart = start
        }
        self.startPoint = resolvedStart
        self.endPoint = target
        self.controlPoint = PasteStackFlightGeometry.controlPoint(from: resolvedStart, to: target)

        let rect = PasteStackFlightGeometry.windowRect(
            from: resolvedStart,
            to: end,
            margin: Self.windowMargin
        )
        self.windowSize = rect.size

        super.init(
            contentRect: rect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        configure()
    }

    // MARK: NSWindow

    /// 纯展示层，永远不接管键盘
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private func configure() {
        isOpaque = false
        backgroundColor = .clear
        // 卡片自己的阴影已由 SwiftUI 画在窗口内，窗口再叠一层会在边缘硬切
        hasShadow = false
        isFloatingPanel = true
        // 压在队列浮窗之上（+1），否则卡片会在落地瞬间被列表挡住
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        // 关键：动画期间用户正在别的应用里打字，浮层绝不能吃掉点击
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        // 让浮层本身参与不了激活循环
        isMovableByWindowBackground = false
        animationBehavior = .none

        let origin = frame.origin
        let start = windowPoint(fromScreen: startPoint, origin: origin)
        let control = windowPoint(fromScreen: controlPoint, origin: origin)
        let end = windowPoint(fromScreen: endPoint, origin: origin)

        let hostingView = NSHostingView(
            rootView: PasteStackFlightCard(
                summary: summary,
                start: start,
                control: control,
                end: end,
                canvasSize: windowSize
            )
        )
        hostingView.autoresizingMask = [.width, .height]
        hostingView.frame = NSRect(origin: .zero, size: windowSize)
        contentView = hostingView
    }

    /// 屏幕坐标 → 窗口内容坐标。
    ///
    /// 两层换算缺一不可：先减窗口原点，再把 y 从「向上为正」翻成 SwiftUI 的
    /// 「向下为正」（NSHostingView 是 flipped 的）。
    private func windowPoint(fromScreen point: NSPoint, origin: NSPoint) -> CGPoint {
        CGPoint(x: point.x - origin.x, y: frame.maxY - point.y)
    }

    private func scheduleFinish() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration) { [weak self] in
            MainActor.assumeIsolated {
                self?.finish()
            }
        }
    }

    /// 收尾：无论正常落地还是被强制打断，都必须回调 `onLanded()`。
    ///
    /// 这里没有「落地」与「中途取消」之分。被压着的那一真实行从起飞起就是隐形的，
    /// 只有 `onLanded()` 能把它放出来；少调一次，队列里就永久少一行（用户看到的是
    /// 计数涨了、列表却是空的）。所以收尾一律按落地处理。
    private func finish() {
        guard !isFinished else { return }
        isFinished = true
        onLanded()
        orderOut(nil)
        Self.active.removeAll { $0 === self }
    }
}

// MARK: - 卡片视图

/// 沿贝塞尔曲线飞行的卡片。
///
/// 用 `Animatable` 自己插值 `progress` 而不是叠一堆 `offset` 动画：轨迹是曲线，
/// 只有拿到连续进度才能算出弧线上的位置。`animatableData` 让 SwiftUI 的动画
/// 直接驱动 `progress` 从 0 到 1，每一帧重算坐标。
private struct PasteStackFlightCard: View {
    let summary: String
    let start: CGPoint
    let control: CGPoint
    let end: CGPoint
    let canvasSize: NSSize

    @State private var progress: Double = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            FlightBody(
                progress: progress,
                summary: summary,
                start: start,
                control: control,
                end: end
            )
        }
        .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .onAppear {
            // 曲线前段快、后段收：落点处减速，看起来是「被吸进去」而不是「撞上去」
            withAnimation(.timingCurve(0.32, 0.0, 0.26, 1.0, duration: PasteStackFlightOverlay.duration)) {
                progress = 1
            }
        }
    }
}

/// 真正会动的部分：只负责「按进度求位置、缩放、透明度」
private struct FlightBody: View, Animatable {
    var progress: Double
    let summary: String
    let start: CGPoint
    let control: CGPoint
    let end: CGPoint

    /// SwiftUI 动画插值的就是这个值
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let position = interpolatedPoint
        card
            .scaleEffect(PasteStackFlightGeometry.cardScale(progress: progress), anchor: .center)
            .opacity(PasteStackFlightGeometry.cardOpacity(progress: progress))
            .position(x: position.x, y: position.y)
    }

    /// 复用同一套曲线公式，只是坐标系换成了窗口内容坐标
    private var interpolatedPoint: CGPoint {
        let point = PasteStackFlightGeometry.point(
            progress: progress,
            from: NSPoint(x: start.x, y: start.y),
            control: NSPoint(x: control.x, y: control.y),
            to: NSPoint(x: end.x, y: end.y)
        )
        return CGPoint(x: point.x, y: point.y)
    }

    private var card: some View {
        HStack(spacing: 5) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(NookClip.accent)
            Text(summary)
                .font(.nookClipCaption)
                .foregroundStyle(NookClip.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: PasteStackFlightOverlay.cardMaxWidth)
        .frame(height: PasteStackFlightOverlay.cardHeight)
        .background {
            RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                .fill(NookClip.bgPopover)
        }
        .overlay {
            RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                .strokeBorder(NookClip.borderHairline, lineWidth: 0.5)
        }
        // 阴影画在窗口内，外扩的 72pt 边距足够，不会被窗口边界切掉
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    }
}
