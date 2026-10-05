import LUIAppleBackend
import QuickLook
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The OCaml owner retains every URL until this presentation closes. iOS gives
/// QuickLook one immutable data source so its native pager owns item selection.
@MainActor enum JournalImagePreview {
  struct Properties: Decodable {
    let paths: [String]
    let selected_index: Int
  }

  struct View: SwiftUI.View {
    let context: LUIAppleExtensionViewContext
    #if !os(iOS)
    @State private var selectedURL: URL?
    @State private var opened = false
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
        Pager(urls: urls, selectedIndex: properties.selected_index, onDismiss: dismissed)
          .frame(width: 0, height: 0)
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
  struct Pager: UIViewControllerRepresentable {
    let urls: [URL]
    let selectedIndex: Int
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> Presenter {
      Presenter(urls: urls, selectedIndex: selectedIndex, onDismiss: onDismiss)
    }

    func updateUIViewController(_ presenter: Presenter, context: Context) {
      // The presentation is a snapshot. SwiftUI updates must not reset the
      // controller's currentPreviewItemIndex while the user is paging.
    }

    static func dismantleUIViewController(_ presenter: Presenter, coordinator: ()) {
      presenter.close()
    }
  }

  final class Items: NSObject, QLPreviewControllerDataSource, @MainActor QLPreviewControllerDelegate {
    let urls: [URL]
    private let onDismiss: () -> Void
    private var finished = false
    var onWillFinish: (() -> Void)?

    init(urls: [URL], onDismiss: @escaping () -> Void) {
      self.urls = urls
      self.onDismiss = onDismiss
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { urls.count }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
      urls[index] as NSURL
    }

    func previewControllerDidDismiss(_ controller: QLPreviewController) { finish() }

    func finish() {
      guard !finished else { return }
      finished = true
      onWillFinish?()
      onDismiss()
    }
  }

  /// Standard navigation containment keeps Save visible while QuickLook owns
  /// image paging, zooming and sharing. The selected URL is read on each tap.
  final class Screen: UIViewController {
    let preview: QLPreviewController
    let urls: [URL]
    var onClose: (() -> Void)?
    private static var chinese: Bool { Locale.current.language.languageCode?.identifier == "zh" }
    private static func text(_ english: String, _ chinese: String) -> String { self.chinese ? chinese : english }
    lazy var save = JournalPhotoSave(dependencies: JournalPhotos.dependencies { [weak self] in self?.feedback($0) })
    lazy var saveButton = UIBarButtonItem(title: Self.text("Save to Photos", "保存到相册"), style: .plain, target: self, action: #selector(saveCurrent))

    private lazy var shareButton = UIBarButtonItem(systemItem: .action, primaryAction: UIAction { [weak self] _ in self?.shareCurrent() })

    init(preview: QLPreviewController, urls: [URL]) {
      self.preview = preview
      self.urls = urls
      super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    var currentURL: URL? {
      let index = preview.currentPreviewItemIndex
      return urls.indices.contains(index) ? urls[index] : nil
    }

    override func viewDidLoad() {
      super.viewDidLoad()
      view.backgroundColor = .systemBackground
      navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.onClose?() })
      saveButton.accessibilityIdentifier = "journal-save-current-image"
      // A child QuickLook controller does not own this navigation item's
      // sharing controls; keep the system share sheet explicitly available.
      navigationItem.rightBarButtonItems = [saveButton, shareButton]
      save.onBusyChanged = { [weak self] busy in
        self?.saveButton.isEnabled = !busy
        self?.shareButton.isEnabled = !busy
        self?.saveButton.title = busy ? Self.text("Saving…", "正在保存…") : Self.text("Save to Photos", "保存到相册")
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
      activity.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItems?.last
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
        message = Self.text("Allow Journal to add photos in Settings, then try again.", "请在系统设置中允许 Journal 添加照片，然后重试。")
      case .restricted:
        title = Self.text("Photo Access Restricted", "添加照片受到限制")
        message = Self.text("This device restricts adding photos to the library.", "此设备限制了向相册添加照片。")
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

  final class Presenter: UIViewController {
    let preview = QLPreviewController()
    let items: Items
    let screen: Screen
    let navigation: UINavigationController
    private var presented = false

    init(urls: [URL], selectedIndex: Int, onDismiss: @escaping () -> Void) {
      items = Items(urls: urls, onDismiss: onDismiss)
      screen = Screen(preview: preview, urls: urls)
      navigation = UINavigationController(rootViewController: screen)
      super.init(nibName: nil, bundle: nil)
      preview.dataSource = items
      preview.delegate = items
      navigation.modalPresentationStyle = .fullScreen
      screen.onClose = { [weak self] in self?.close(animated: true) }
      items.onWillFinish = { [weak screen] in screen?.save.close() }
      // QuickLook has no active item until it loads the datasource. Selecting
      // before this boundary can leave currentPreviewItemIndex at NSNotFound.
      preview.loadViewIfNeeded()
      preview.reloadData()
      preview.currentPreviewItemIndex = urls.indices.contains(selectedIndex) ? selectedIndex : 0
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidLoad() {
      super.viewDidLoad()
      view.backgroundColor = .clear
    }

    override func viewDidAppear(_ animated: Bool) {
      super.viewDidAppear(animated)
      guard !presented, !items.urls.isEmpty else { return }
      presented = true
      present(navigation, animated: true)
    }

    func close(animated: Bool = false) {
      screen.save.close()
      guard navigation.presentingViewController != nil else { items.finish(); return }
      navigation.dismiss(animated: animated) { [items] in items.finish() }
    }
  }
  #endif
}
