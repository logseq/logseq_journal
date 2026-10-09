import LUIAppleBackend
import QuickLook
import SwiftUI

#if os(iOS)
import UIKit
#endif

/// The OCaml owner retains every URL until this presentation closes. The native
/// iOS page controller owns selection within one immutable image snapshot.
@MainActor enum JournalImagePreview {
  struct Properties: Decodable {
    let paths: [String]
    let selected_index: Int
    let document: Bool?
    let title: String?
  }

  struct View: SwiftUI.View {
    let context: LUIAppleExtensionViewContext
    @State private var opened = false
    #if os(iOS)
    @State private var presented = false
    #else
    @State private var selectedURL: URL?
    #endif

    private var properties: Properties? {
      JournalExtensions.decode(Properties.self, context: context)
    }

    private func dismissed() {
      JournalExtensions.emit(context: context, payload: Data("{\"type\":\"dismiss\"}".utf8))
    }

    var body: some SwiftUI.View {
      if let properties {
        let urls = properties.paths.map { URL(fileURLWithPath: $0) }
        #if os(iOS)
        Color.clear
          .frame(width: 0, height: 0)
          .fullScreenCover(isPresented: $presented, onDismiss: dismissed) {
            if properties.document == true, let url = urls.first {
              Document(url: url, title: properties.title ?? "Attachment") {
                presented = false
              }.ignoresSafeArea()
            } else {
              Pager(urls: urls, selectedIndex: properties.selected_index) {
                presented = false
              }.ignoresSafeArea()
            }
          }
          .onAppear {
            guard !opened, urls.indices.contains(properties.selected_index) else { return }
            opened = true
            presented = true
          }
        #else
        Color.clear
          .frame(width: 0, height: 0)
          .quickLookPreview($selectedURL, in: urls)
          .onAppear {
            guard !opened, urls.indices.contains(properties.selected_index) else { return }
            opened = true
            selectedURL = urls[properties.selected_index]
          }
          .onChange(of: selectedURL) { previous, current in
            if opened, previous != nil, current == nil { dismissed() }
          }
          .onDisappear { selectedURL = nil }
        #endif
      }
    }
  }

  #if os(iOS)
  // Quick Look accepts a display title independently of the immutable cache URL.
  struct Document: UIViewControllerRepresentable {
    let url: URL
    let title: String
    let onClose: () -> Void

    final class Item: NSObject, QLPreviewItem {
      let previewItemURL: URL?
      let previewItemTitle: String?
      init(url: URL, title: String) {
        previewItemURL = url
        previewItemTitle = title
      }
    }
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
      let item: Item
      init(url: URL, title: String) { item = Item(url: url, title: title) }
      func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
      func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { item }
    }
    func makeCoordinator() -> Coordinator { Coordinator(url: url, title: title) }
    func makeUIViewController(context: Context) -> UINavigationController {
      let preview = QLPreviewController()
      preview.dataSource = context.coordinator
      preview.navigationItem.leftBarButtonItem = UIBarButtonItem(
        title: Locale.current.language.languageCode?.identifier == "zh" ? "关闭" : "Close",
        primaryAction: UIAction { _ in onClose() })
      preview.navigationItem.leftBarButtonItem?.accessibilityIdentifier = "journal-document-close"
      return UINavigationController(rootViewController: preview)
    }
    func updateUIViewController(_ navigation: UINavigationController, context: Context) {}
  }

  struct Pager: UIViewControllerRepresentable {
    let urls: [URL]
    let selectedIndex: Int
    let onClose: () -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
      let screen = Screen(preview: Gallery(urls: urls, selectedIndex: selectedIndex))
      screen.onClose = { [weak screen] in
        screen?.save.close()
        onClose()
      }
      return UINavigationController(rootViewController: screen)
    }

    func updateUIViewController(_ navigation: UINavigationController, context: Context) {
      // The presentation is a snapshot. SwiftUI updates must not reset the
      // native controller's current page while the user is paging.
    }

    static func dismantleUIViewController(_ navigation: UINavigationController, coordinator: ()) {
      // A native List may discard temporary hosting instances. Teardown only
      // cancels their local work; SwiftUI owns the actual presentation dismissal.
      if let screen = navigation.viewControllers.first as? Screen {
        screen.save.close()
        screen.onClose = nil
      }
    }
  }

  final class ImagePage: UIViewController, UIScrollViewDelegate {
    let index: Int
    let url: URL
    private let scroll = UIScrollView()
    private let image = UIImageView()

    init(index: Int, url: URL) {
      self.index = index
      self.url = url
      super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidLoad() {
      super.viewDidLoad()
      view.backgroundColor = .systemBackground
      scroll.delegate = self
      scroll.minimumZoomScale = 1
      scroll.maximumZoomScale = 8
      scroll.showsHorizontalScrollIndicator = false
      scroll.showsVerticalScrollIndicator = false
      scroll.contentInsetAdjustmentBehavior = .never
      scroll.panGestureRecognizer.isEnabled = false
      scroll.accessibilityIdentifier = "journal-image-zoom"
      image.image = UIImage(contentsOfFile: url.path)
      image.contentMode = .scaleAspectFit
      image.isAccessibilityElement = true
      image.accessibilityLabel = url.deletingPathExtension().lastPathComponent
      scroll.translatesAutoresizingMaskIntoConstraints = false
      image.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(scroll)
      scroll.addSubview(image)
      NSLayoutConstraint.activate([
        scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        scroll.topAnchor.constraint(equalTo: view.topAnchor),
        scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        image.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
        image.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
        image.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
        image.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
        image.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
        image.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
      ])
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { image }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
      // At fit size the outer page controller owns horizontal input. Once
      // zoomed, UIKit's image scroll view owns panning within the current page.
      scrollView.panGestureRecognizer.isEnabled =
        scrollView.zoomScale > scrollView.minimumZoomScale
    }
  }

  final class Gallery: UIPageViewController, UIPageViewControllerDataSource {
    let urls: [URL]

    init(urls: [URL], selectedIndex: Int) {
      self.urls = urls
      super.init(transitionStyle: .scroll, navigationOrientation: .horizontal)
      dataSource = urls.count > 1 ? self : nil
      if !urls.isEmpty {
        let index = urls.indices.contains(selectedIndex) ? selectedIndex : 0
        setViewControllers(
          [ImagePage(index: index, url: urls[index])], direction: .forward, animated: false)
      }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    var currentPage: ImagePage? { viewControllers?.first as? ImagePage }

    override func viewDidLoad() {
      super.viewDidLoad()
      view.accessibilityIdentifier = "journal-image-gallery"
    }

    private func adjacent(to controller: UIViewController, offset: Int) -> UIViewController? {
      guard let page = controller as? ImagePage else { return nil }
      let index = page.index + offset
      return urls.indices.contains(index) ? ImagePage(index: index, url: urls[index]) : nil
    }

    func pageViewController(
      _ pageViewController: UIPageViewController,
      viewControllerBefore viewController: UIViewController
    ) -> UIViewController? {
      adjacent(to: viewController, offset: -1)
    }

    func pageViewController(
      _ pageViewController: UIPageViewController,
      viewControllerAfter viewController: UIViewController
    ) -> UIViewController? {
      adjacent(to: viewController, offset: 1)
    }
  }

  /// Standard navigation keeps Save visible above native paging and zooming.
  /// Save and Share read the native current controller's URL on each tap.
  final class Screen: UIViewController {
    let preview: Gallery
    var onClose: (() -> Void)?
    private static var chinese: Bool { Locale.current.language.languageCode?.identifier == "zh" }
    private static func text(_ english: String, _ chinese: String) -> String {
      self.chinese ? chinese : english
    }
    lazy var save = JournalPhotoSave(
      dependencies: JournalPhotos.dependencies { [weak self] in self?.feedback($0) })
    lazy var saveButton = UIBarButtonItem(
      title: Self.text("Save to Photos", "保存到相册"), style: .plain, target: self,
      action: #selector(saveCurrent))

    private lazy var shareButton = UIBarButtonItem(
      systemItem: .action, primaryAction: UIAction { [weak self] _ in self?.shareCurrent() })

    init(preview: Gallery) {
      self.preview = preview
      super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    var currentURL: URL? { preview.currentPage?.url }

    override func viewDidLoad() {
      super.viewDidLoad()
      view.backgroundColor = .systemBackground
      navigationItem.leftBarButtonItem = UIBarButtonItem(
        title: Self.text("Close", "关闭"),
        primaryAction: UIAction { [weak self] _ in self?.onClose?() })
      navigationItem.leftBarButtonItem?.accessibilityIdentifier = "journal-image-close"
      saveButton.accessibilityIdentifier = "journal-save-current-image"
      navigationItem.rightBarButtonItems = [saveButton, shareButton]
      save.onBusyChanged = { [weak self] busy in
        self?.saveButton.isEnabled = !busy
        self?.shareButton.isEnabled = !busy
        self?.saveButton.title =
          busy ? Self.text("Saving…", "正在保存…") : Self.text("Save to Photos", "保存到相册")
      }
      addChild(preview)
      preview.view.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(preview.view)
      NSLayoutConstraint.activate([
        preview.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        preview.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        preview.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
        preview.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      ])
      preview.didMove(toParent: self)
    }

    @objc private func saveCurrent() {
      guard let url = currentURL else { return }
      save.save(url)
    }

    private func shareCurrent() {
      guard let url = currentURL else { return }
      let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
      activity.popoverPresentationController?.barButtonItem =
        navigationItem.rightBarButtonItems?.last
      present(activity, animated: true)
    }

    private func feedback(_ result: JournalPhotoSave.Feedback) {
      guard viewIfLoaded?.window != nil else { return }
      let title: String
      let message: String
      switch result {
      case .saved:
        title = Self.text("Saved to Photos", "已保存到相册")
        message = Self.text("The current image was saved.", "当前图片已保存。")
      case .denied:
        title = Self.text("Photo Access Denied", "未允许添加照片")
        message = Self.text(
          "Allow Journal to add photos in Settings, then try again.",
          "请在系统设置中允许 Journal 添加照片，然后重试。")
      case .restricted:
        title = Self.text("Photo Access Restricted", "添加照片受到限制")
        message = Self.text(
          "This device restricts adding photos to the library.", "此设备限制了向相册添加照片。")
      case .notImage:
        title = Self.text("Cannot Save Image", "无法保存图片")
        message = Self.text("This file is not a supported image.", "此文件不是支持的图片格式。")
      case .failed:
        title = Self.text("Save Failed", "保存失败")
        message = Self.text("The image could not be saved. Please try again.", "未能保存图片，请重试。")
      }
      let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
      alert.addAction(UIAlertAction(title: Self.text("OK", "好"), style: .default))
      present(alert, animated: true)
    }
  }

  #endif
}
