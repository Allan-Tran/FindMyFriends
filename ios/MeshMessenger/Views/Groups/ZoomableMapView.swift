import SwiftUI
import UIKit

// MARK: - ZoomableMapView (UIViewRepresentable)

struct ZoomableMapView: UIViewRepresentable {
    let image: UIImage
    let pins: [FirestorePin]
    var uiColorForPin: (FirestorePin) -> UIColor
    var onMapTap: (CGPoint) -> Void   // normalized 0..1
    var onPinTap: (FirestorePin) -> Void

    typealias Coordinator = ZoomableMapCoordinator

    func makeCoordinator() -> ZoomableMapCoordinator {
        ZoomableMapCoordinator()
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1.0
        scroll.maximumZoomScale = 5.0
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.bouncesZoom = true
        scroll.backgroundColor = .systemBackground

        let container = UIView()
        container.isUserInteractionEnabled = true
        scroll.addSubview(container)

        let iv = UIImageView(image: image)
        iv.contentMode = .scaleAspectFit
        iv.isUserInteractionEnabled = true
        container.addSubview(iv)

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(ZoomableMapCoordinator.handleMapTap(_:))
        )
        tap.cancelsTouchesInView = false   // let PinCircleButton receive its own touches
        container.addGestureRecognizer(tap)

        context.coordinator.containerView = container
        context.coordinator.imageView = iv
        context.coordinator.scrollView = scroll

        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        let c = context.coordinator
        c.onMapTap = onMapTap
        c.onPinTap = onPinTap
        c.uiColorForPin = uiColorForPin

        c.imageView?.image = image   // always sync in case a new map was uploaded

        // Width source priority:
        // 1. Actual scroll view bounds — stable, correct after layout.
        // 2. Last known good width — used when bounds are transiently 0 (sheet
        //    covering the map) to avoid a contentSize reset that would lose zoom state.
        // 3. Screen width — fallback for the very first call before layout runs.
        let svWidth: CGFloat
        if scroll.bounds.width > 0 {
            svWidth = scroll.bounds.width
        } else if c.layoutSize.width > 0 {
            svWidth = c.layoutSize.width
        } else {
            svWidth = UIScreen.main.bounds.width
        }

        let h = svWidth * image.size.height / max(image.size.width, 1)
        let size = CGSize(width: svWidth, height: h)

        // Guard against container.frame.size, which changes with zoom (because
        // UIScrollView applies a scale transform to the container). Instead compare
        // against the stored unzoomed layoutSize so a zoomed re-render never resets
        // contentSize or the container frame.
        if let container = c.containerView, c.layoutSize != size {
            container.frame = CGRect(origin: .zero, size: size)
            c.imageView?.frame = CGRect(origin: .zero, size: size)
            scroll.contentSize = size
            c.layoutSize = size
        }

        let pinW = c.layoutSize.width  > 0 ? c.layoutSize.width  : svWidth
        let pinH = c.layoutSize.height > 0 ? c.layoutSize.height : h
        c.updatePins(pins, width: pinW, height: pinH)
    }
}

// MARK: - Coordinator

final class ZoomableMapCoordinator: NSObject, UIScrollViewDelegate {
    weak var containerView: UIView?
    weak var imageView: UIImageView?
    weak var scrollView: UIScrollView?

    var onMapTap: ((CGPoint) -> Void)?
    var onPinTap: ((FirestorePin) -> Void)?
    var uiColorForPin: ((FirestorePin) -> UIColor)?

    var layoutSize: CGSize = .zero
    var currentZoomScale: CGFloat = 1.0

    private var pinViews: [String: PinCircleButton] = [:]

    // Base diameter at zoom scale 1; pins shrink as you zoom so they feel fixed-size on screen.
    private let basePinDiameter: CGFloat = 22

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { containerView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        // Keep content centered when smaller than the scroll view.
        let svSize = scrollView.bounds.size
        let cs = scrollView.contentSize
        let hInset = max(0, (svSize.width - cs.width) / 2)
        let vInset = max(0, (svSize.height - cs.height) / 2)
        scrollView.contentInset = UIEdgeInsets(top: vInset, left: hInset, bottom: vInset, right: hInset)

        currentZoomScale = scrollView.zoomScale
        rescalePins()
    }

    // Resize every existing pin view so it appears the same physical size on screen
    // regardless of zoom level (diameter stays basePinDiameter points after the
    // scroll view's zoom transform is applied).
    private func rescalePins() {
        let diameter = basePinDiameter / currentZoomScale
        let radius = diameter / 2
        for (_, pinView) in pinViews {
            let cx = pinView.frame.midX
            let cy = pinView.frame.midY
            pinView.frame = CGRect(x: cx - radius, y: cy - radius, width: diameter, height: diameter)
            pinView.layer.cornerRadius = radius
        }
    }

    func updatePins(_ pins: [FirestorePin], width: CGFloat, height: CGFloat) {
        guard let container = containerView, width > 0, height > 0 else { return }

        let diameter = basePinDiameter / currentZoomScale
        let radius = diameter / 2

        let currentIds = Set(pins.compactMap { $0.id })
        for (id, view) in pinViews where !currentIds.contains(id) {
            view.removeFromSuperview()
            pinViews.removeValue(forKey: id)
        }

        for pin in pins {
            guard let id = pin.id else { continue }
            let x = pin.x * width
            let y = pin.y * height
            let frame = CGRect(x: x - radius, y: y - radius, width: diameter, height: diameter)

            if let existing = pinViews[id] {
                existing.frame = frame
                existing.layer.cornerRadius = radius
            } else {
                let color = uiColorForPin?(pin) ?? .systemRed
                let btn = PinCircleButton(pin: pin, color: color)
                btn.frame = frame
                btn.layer.cornerRadius = radius
                btn.addTarget(self, action: #selector(pinTapped(_:)), for: .touchUpInside)
                container.addSubview(btn)
                pinViews[id] = btn
            }
        }
    }

    @objc func handleMapTap(_ gesture: UITapGestureRecognizer) {
        guard let container = containerView else { return }
        let loc = gesture.location(in: container)
        let w = container.bounds.width
        let h = container.bounds.height
        guard w > 0, h > 0 else { return }
        for (_, pinView) in pinViews where pinView.frame.contains(loc) { return }
        let nx = loc.x / w
        let ny = loc.y / h
        guard (0...1).contains(nx), (0...1).contains(ny) else { return }
        onMapTap?(CGPoint(x: nx, y: ny))
    }

    @objc func pinTapped(_ btn: PinCircleButton) {
        onPinTap?(btn.pin)
    }
}

// MARK: - PinCircleButton

final class PinCircleButton: UIControl {
    let pin: FirestorePin

    init(pin: FirestorePin, color: UIColor) {
        self.pin = pin
        super.init(frame: .zero)
        backgroundColor = color
        layer.cornerRadius = 11
        layer.borderWidth = 2
        layer.borderColor = UIColor.white.cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.3
        layer.shadowRadius = 2
        layer.shadowOffset = .zero
        layer.masksToBounds = false
    }

    required init?(coder: NSCoder) { fatalError() }
}
