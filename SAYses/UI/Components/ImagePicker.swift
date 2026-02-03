import SwiftUI
import UIKit

struct ImagePicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    var onImagePicked: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: ImagePicker

        init(_ parent: ImagePicker) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onImagePicked(image)
            }
            parent.isPresented = false
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.isPresented = false
        }
    }
}

// MARK: - Crop View (UIKit-based for reliable zoom/crop)

struct ImageCropView: View {
    let sourceImage: UIImage
    var onCropped: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                CropScrollView(image: sourceImage)

                // Bottom button bar
                HStack {
                    Button("Abbrechen") { dismiss() }
                        .foregroundStyle(.white)

                    Spacer()

                    Button("Speichern") {
                        NotificationCenter.default.post(name: .cropImageRequested, object: nil)
                    }
                    .foregroundStyle(.white)
                    .fontWeight(.semibold)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .background(.black)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cropImageCompleted)) { notification in
            if let cropped = notification.object as? UIImage {
                onCropped(cropped)
                dismiss()
            }
        }
    }
}

extension Notification.Name {
    static let cropImageRequested = Notification.Name("cropImageRequested")
    static let cropImageCompleted = Notification.Name("cropImageCompleted")
}

// MARK: - UIScrollView-based crop (reliable pinch-zoom & pan)

struct CropScrollView: UIViewControllerRepresentable {
    let image: UIImage

    func makeUIViewController(context: Context) -> CropViewController {
        CropViewController(image: image)
    }

    func updateUIViewController(_ uiViewController: CropViewController, context: Context) {}
}

class CropViewController: UIViewController, UIScrollViewDelegate {
    private let sourceImage: UIImage
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let overlayView = CropOverlayView()
    private let cropSize: CGFloat = 300
    private var observer: Any?
    private var hasSetInitialZoom = false

    init(image: UIImage) {
        // Normalize orientation so pixel size matches visual size
        self.sourceImage = image.fixedOrientation()
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        // Image view
        imageView.image = sourceImage
        imageView.contentMode = .scaleAspectFit

        // Scroll view
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 6.0
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.bouncesZoom = true
        scrollView.alwaysBounceHorizontal = true
        scrollView.alwaysBounceVertical = true

        scrollView.addSubview(imageView)
        view.addSubview(scrollView)

        // Overlay with circle cutout (non-interactive)
        overlayView.isUserInteractionEnabled = false
        overlayView.cropSize = cropSize
        view.addSubview(overlayView)

        // Listen for crop request
        observer = NotificationCenter.default.addObserver(
            forName: .cropImageRequested, object: nil, queue: .main
        ) { [weak self] _ in
            self?.performCrop()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        scrollView.frame = view.bounds
        overlayView.frame = view.bounds

        let imgSize = sourceImage.size
        guard imgSize.width > 0, imgSize.height > 0 else { return }

        // Only configure image layout once to avoid resetting user's zoom/pan
        guard !hasSetInitialZoom else { return }
        hasSetInitialZoom = true

        // Set imageView size to fill the view (scale-to-fill, not fit)
        let viewW = view.bounds.width
        let viewH = view.bounds.height
        let imgAspect = imgSize.width / imgSize.height
        let viewAspect = viewW / viewH

        let displayW: CGFloat
        let displayH: CGFloat
        if imgAspect > viewAspect {
            // Image wider → fill height
            displayH = viewH
            displayW = displayH * imgAspect
        } else {
            // Image taller → fill width
            displayW = viewW
            displayH = displayW / imgAspect
        }

        imageView.frame = CGRect(origin: .zero, size: CGSize(width: displayW, height: displayH))
        scrollView.contentSize = CGSize(width: displayW, height: displayH)

        // Ensure image covers the crop circle at minimum zoom
        let minScaleW = cropSize / displayW
        let minScaleH = cropSize / displayH
        scrollView.minimumZoomScale = max(minScaleW, minScaleH, 1.0)
        scrollView.zoomScale = scrollView.minimumZoomScale

        // Center the image
        centerImageInScrollView()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImageInScrollView()
    }

    private func centerImageInScrollView() {
        let viewW = scrollView.bounds.width
        let viewH = scrollView.bounds.height
        let contentW = scrollView.contentSize.width
        let contentH = scrollView.contentSize.height

        let offsetX = max(0, (viewW - contentW) / 2)
        let offsetY = max(0, (viewH - contentH) / 2)

        scrollView.contentInset = UIEdgeInsets(
            top: offsetY, left: offsetX,
            bottom: offsetY, right: offsetX
        )
    }

    // MARK: - Perform Crop

    private func performCrop() {
        let viewCenter = CGPoint(x: view.bounds.midX, y: view.bounds.midY)

        // Convert crop circle rect from view coords to image content coords
        let cropRect = CGRect(
            x: viewCenter.x - cropSize / 2,
            y: viewCenter.y - cropSize / 2,
            width: cropSize,
            height: cropSize
        )

        // Convert to scrollView content coordinates
        let contentPoint = scrollView.convert(cropRect.origin, from: view)
        let zoomScale = scrollView.zoomScale

        // The imageView is displayed at displaySize * zoomScale
        // Map content coordinates to original image pixel coordinates
        let imgSize = sourceImage.size
        let displayW = imageView.frame.width / zoomScale  // original display width
        let displayH = imageView.frame.height / zoomScale

        let scaleToPixelsX = imgSize.width / displayW
        let scaleToPixelsY = imgSize.height / displayH

        let pixelRect = CGRect(
            x: (contentPoint.x / zoomScale) * scaleToPixelsX,
            y: (contentPoint.y / zoomScale) * scaleToPixelsY,
            width: (cropSize / zoomScale) * scaleToPixelsX,
            height: (cropSize / zoomScale) * scaleToPixelsY
        )

        // Render the cropped area
        let outputSize = CGSize(width: 512, height: 512)
        let renderer = UIGraphicsImageRenderer(size: outputSize)
        let cropped = renderer.image { _ in
            // Draw the source image offset so the crop area lands at (0,0)
            let drawRect = CGRect(
                x: -pixelRect.origin.x * (512 / pixelRect.width),
                y: -pixelRect.origin.y * (512 / pixelRect.height),
                width: imgSize.width * (512 / pixelRect.width),
                height: imgSize.height * (512 / pixelRect.height)
            )
            sourceImage.draw(in: drawRect)
        }

        NotificationCenter.default.post(name: .cropImageCompleted, object: cropped)
    }
}

// MARK: - Crop Overlay (dark with circle cutout)

// MARK: - Fix image orientation

extension UIImage {
    func fixedOrientation() -> UIImage {
        guard imageOrientation != .up else { return self }
        UIGraphicsBeginImageContextWithOptions(size, false, scale)
        draw(in: CGRect(origin: .zero, size: size))
        let normalized = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return normalized ?? self
    }
}

// MARK: - Crop Overlay (dark with circle cutout)

class CropOverlayView: UIView {
    var cropSize: CGFloat = 300

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }

        // Dark overlay
        ctx.setFillColor(UIColor.black.withAlphaComponent(0.5).cgColor)
        ctx.fill(rect)

        // Clear circle in center
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let circleRect = CGRect(
            x: center.x - cropSize / 2,
            y: center.y - cropSize / 2,
            width: cropSize,
            height: cropSize
        )
        ctx.setBlendMode(.clear)
        ctx.fillEllipse(in: circleRect)

        // Circle border
        ctx.setBlendMode(.normal)
        ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.6).cgColor)
        ctx.setLineWidth(1)
        ctx.strokeEllipse(in: circleRect)
    }
}
