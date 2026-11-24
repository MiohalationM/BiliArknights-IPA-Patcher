import UIKit
import UniformTypeIdentifiers

/// Presents iOS's `UIDocumentPickerViewController` directly via UIKit modal presentation
/// from the active window's top-most `UIViewController` (never embedded inside a SwiftUI `.sheet`),
/// ensuring reliable delegate callbacks and dismissal across iOS 16–27.
@MainActor
final class SystemDocumentPickerPresenter: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
    private enum Mode {
        case importFile(onPick: (URL) -> Void, onCancel: () -> Void)
        case exportFile(onComplete: (SystemExportResult) -> Void)
    }

    private var activeMode: Mode?

    func presentImporter(
        onPick: @escaping (URL) -> Void,
        onCancel: @escaping () -> Void,
        onPresentationFailure: @escaping (String) -> Void
    ) {
        // `com.apple.itunes.ipa` conforms to `public.data` (and NOT `public.zip-archive`).
        // Passing `[.data]` plus the system `.ipa` UTType with `asCopy: true` guarantees `.ipa` files
        // remain selectable across all iOS FileProviders (whereas `asCopy: false` grays out `.ipa` files
        // in providers that disallow in-place opening; same-volume APFS copies use zero-block CoW clones).
        var types: [UTType] = [.data]
        if let ipaType = UTType(filenameExtension: "ipa"), !types.contains(ipaType) {
            types.insert(ipaType, at: 0)
        }
        presentOpeningPicker(
            contentTypes: types,
            onPick: onPick,
            onCancel: onCancel,
            onPresentationFailure: onPresentationFailure
        )
    }

    /// Presents a document picker tailored for importing manual `.json` / `.plist` adaptation profiles.
    func presentProfileImporter(
        onPick: @escaping (URL) -> Void,
        onCancel: @escaping () -> Void,
        onPresentationFailure: @escaping (String) -> Void
    ) {
        let types: [UTType] = [.json, .propertyList, .xml, .data]
        presentOpeningPicker(
            contentTypes: types,
            onPick: onPick,
            onCancel: onCancel,
            onPresentationFailure: onPresentationFailure
        )
    }

    private func presentOpeningPicker(
        contentTypes: [UTType],
        onPick: @escaping (URL) -> Void,
        onCancel: @escaping () -> Void,
        onPresentationFailure: @escaping (String) -> Void
    ) {
        guard activeMode == nil else {
            return
        }
        guard let presenter = Self.topViewController(),
              !presenter.isBeingPresented,
              !presenter.isBeingDismissed else {
            onPresentationFailure("当前窗口正在切换，请稍后再试打开系统文件选择器。")
            return
        }

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        picker.presentationController?.delegate = self

        activeMode = .importFile(onPick: onPick, onCancel: onCancel)
        presenter.present(picker, animated: true)
    }

    func presentExporter(
        fileURL: URL,
        onComplete: @escaping (SystemExportResult) -> Void
    ) {
        guard activeMode == nil else {
            return
        }
        guard let presenter = Self.topViewController(),
              !presenter.isBeingPresented,
              !presenter.isBeingDismissed else {
            onComplete(.failed("当前窗口正在切换，请稍后再试打开系统文件导出器。"))
            return
        }

        let picker = UIDocumentPickerViewController(forExporting: [fileURL], asCopy: true)
        picker.delegate = self
        picker.shouldShowFileExtensions = true
        picker.presentationController?.delegate = self

        activeMode = .exportFile(onComplete: onComplete)
        presenter.present(picker, animated: true)
    }

    // MARK: - UIDocumentPickerDelegate

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let mode = activeMode else { return }
        activeMode = nil
        switch mode {
        case .importFile(let onPick, let onCancel):
            if let first = urls.first {
                onPick(first)
            } else {
                onCancel()
            }
        case .exportFile(let onComplete):
            onComplete(.saved(urls))
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        guard let mode = activeMode else { return }
        activeMode = nil
        switch mode {
        case .importFile(_, let onCancel):
            onCancel()
        case .exportFile(let onComplete):
            onComplete(.cancelled)
        }
    }

    // MARK: - UIAdaptivePresentationControllerDelegate

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard let mode = activeMode else { return }
        activeMode = nil
        switch mode {
        case .importFile(_, let onCancel):
            onCancel()
        case .exportFile(let onComplete):
            onComplete(.cancelled)
        }
    }

    // MARK: - Top ViewController Lookup

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }

        let keyWindow = scenes
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
            ?? scenes.flatMap(\.windows).first

        var top = keyWindow?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}
