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
      onDismiss()
    }
  }

  final class Presenter: UIViewController {
    let preview = QLPreviewController()
    let items: Items
    private var presented = false

    init(urls: [URL], selectedIndex: Int, onDismiss: @escaping () -> Void) {
      items = Items(urls: urls, onDismiss: onDismiss)
      super.init(nibName: nil, bundle: nil)
      preview.dataSource = items
      preview.delegate = items
      preview.modalPresentationStyle = .fullScreen
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
      present(preview, animated: true)
    }

    func close() {
      guard preview.presentingViewController != nil else { return }
      preview.dismiss(animated: false) { [items] in items.finish() }
    }
  }
  #endif
}
