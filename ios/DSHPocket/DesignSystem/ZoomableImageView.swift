import SwiftUI
import UIKit

/// 可缩放的图片视图：原生捏合放大、拖动、双击放大/复位。
///
/// ## 为什么用 `UIScrollView` 而不是 SwiftUI 手势
///
/// 真机上"点开 PNG 附件，图片无法缩放"就是这么来的：
///   · 同一张图上挂两个 `.gesture`（捏合 + 拖动）时，后挂的那个会抢走识别 ——
///     捏合经常**完全不响应**，只有拖动生效；
///   · 缩放之后"别把图拖出屏幕"的钳制、以及"图比屏幕小时居中"这两件事，
///     手写 SwiftUI 很容易出偏差（`offset` 直接跟着手指跑，图能被拖飞）；
///   · 双击复位/放大要和捏合共享同一个缩放状态 —— UIKit 里只有一个 `zoomScale`。
///
/// `UIScrollView` 的 `contentInset` + `bouncesZoom` + `viewForZooming` 就是这件事的
/// 标准答案，行为和系统「照片」App 一致。聊天附件预览与工作区文件预览**共用这一份**。
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    /// 双击放大到的倍数（已经是放大态时双击回 1 倍）。
    var doubleTapZoomScale: CGFloat = 2.5
    var maximumZoomScale: CGFloat = 8

    func makeUIView(context: Context) -> ZoomingScrollView {
        let view = ZoomingScrollView()
        view.maximumZoomScale = maximumZoomScale
        view.doubleTapZoomScale = doubleTapZoomScale
        view.setImage(image)
        return view
    }

    func updateUIView(_ view: ZoomingScrollView, context: Context) {
        view.maximumZoomScale = maximumZoomScale
        view.doubleTapZoomScale = doubleTapZoomScale
        view.setImage(image)
    }
}

/// 只做一件事的 `UIScrollView`：把一张图缩放/拖动得像个正常的看图界面。
final class ZoomingScrollView: UIScrollView, UIScrollViewDelegate {
    fileprivate let imageView = UIImageView()
    fileprivate var doubleTapZoomScale: CGFloat = 2.5

    /// 上一次布局的尺寸。`layoutSubviews` 调用很频繁，
    /// **只在尺寸真的变了**才重算基准 —— 否则每滚一下都会把缩放重置回 1。
    private var lastBoundsSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        delegate = self
        backgroundColor = .clear
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        bouncesZoom = true
        decelerationRate = .fast
        // 全屏看图时不要系统再替我们留安全区边距（外面已经 ignoresSafeArea）。
        contentInsetAdjustmentBehavior = .never
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    func setImage(_ image: UIImage) {
        guard imageView.image !== image else { return }
        imageView.image = image
        lastBoundsSize = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0, bounds.size != lastBoundsSize else { return }
        lastBoundsSize = bounds.size
        resetToFit()
    }

    /// 基准：1 倍 = 整张图正好装进屏幕。之后 `zoomScale` 在此基础上放大。
    private func resetToFit() {
        guard let image = imageView.image,
              image.size.width > 0, image.size.height > 0
        else { return }
        let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
        imageView.frame = CGRect(
            x: 0,
            y: 0,
            width: image.size.width * fit,
            height: image.size.height * fit
        )
        contentSize = imageView.frame.size
        minimumZoomScale = 1
        maximumZoomScale = max(maximumZoomScale, 1)
        zoomScale = 1
        centerImage()
    }

    /// 图比视口小时居中（`contentInset` 是官方推荐做法，`bouncesZoom` 也不会把它弹走）。
    private func centerImage() {
        let insetX = max((bounds.width - contentSize.width) / 2, 0)
        let insetY = max((bounds.height - contentSize.height) / 2, 0)
        contentInset = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        // 已经是放大态 → 回 1 倍；否则放大到双击点附近。
        if zoomScale > minimumZoomScale * 1.01 {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        let target = min(max(doubleTapZoomScale, 1), maximumZoomScale)
        let point = recognizer.location(in: imageView)
        let size = CGSize(width: bounds.width / target, height: bounds.height / target)
        let rect = CGRect(
            x: point.x - size.width / 2,
            y: point.y - size.height / 2,
            width: size.width,
            height: size.height
        )
        zoom(to: rect, animated: true)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }
}
