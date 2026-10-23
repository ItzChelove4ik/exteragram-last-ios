import Foundation
import UIKit
import PhotosUI
import UniformTypeIdentifiers

/// Photo-library picker used by the mod's image-based settings. Presents
/// the system PHPickerViewController on the top-most view controller and
/// delivers the picked image as a UIImage.
enum ExteraModImagePicker {
    static func pickImage(completion: @escaping (UIImage?) -> Void) {
        DispatchQueue.main.async {
            guard let root = UIApplication.shared.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
                completion(nil)
                return
            }
            var presenter = root
            while let next = presenter.presentedViewController, !next.isBeingDismissed {
                presenter = next
            }
            if #available(iOS 14.0, *) {
                let photoPicker = PHPickerViewController(configuration: photoPickerConfiguration())
                photoPicker.modalPresentationStyle = .pageSheet
                let delegate = PickerDelegate(completion: completion)
                photoPicker.delegate = delegate
                ExteraModImagePickerRetainer.retain(delegate)
                presenter.present(photoPicker, animated: true)
            } else {
                let picker = UIImagePickerController()
                picker.sourceType = .photoLibrary
                picker.modalPresentationStyle = .pageSheet
                let delegate = LegacyPickerDelegate(completion: completion)
                picker.delegate = delegate
                ExteraModImagePickerRetainer.retain(delegate)
                presenter.present(picker, animated: true)
            }
        }
    }

    @available(iOS 14.0, *)
    private static func photoPickerConfiguration() -> PHPickerConfiguration {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        return configuration
    }

    static func jpegData(from image: UIImage, maxDimension: CGFloat) -> Data? {
        let scaled = scaleImage(image, maxDimension: maxDimension)
        return scaled.jpegData(compressionQuality: 0.85)
    }

    private static func scaleImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let largest = max(size.width, size.height)
        guard largest > maxDimension, largest > 0 else { return image }
        let scale = maxDimension / largest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

private final class ExteraModImagePickerRetainer {
    private static var lock = NSLock()
    private static var delegates: [ObjectIdentifier: Any] = [:]

    static func retain(_ delegate: Any) {
        lock.lock()
        defer { lock.unlock() }
        delegates[ObjectIdentifier(delegate as AnyObject)] = delegate
        if delegates.count > 8 {
            // Keep the set small; each delegate releases itself after one pick.
            delegates.removeAll()
        }
    }

    static func release(_ delegate: Any) {
        lock.lock()
        defer { lock.unlock() }
        delegates.removeValue(forKey: ObjectIdentifier(delegate as AnyObject))
    }
}

@available(iOS 14.0, *)
private final class PickerDelegate: NSObject, PHPickerViewControllerDelegate {
    private let completion: (UIImage?) -> Void
    private var delivered = false

    init(completion: @escaping (UIImage?) -> Void) {
        self.completion = completion
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard !delivered, let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else {
            deliver(nil)
            return
        }
        provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
            DispatchQueue.main.async {
                self?.deliver(object as? UIImage)
            }
        }
    }

    private func deliver(_ image: UIImage?) {
        guard !delivered else { return }
        delivered = true
        ExteraModImagePickerRetainer.release(self)
        completion(image)
    }
}

private final class LegacyPickerDelegate: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    private let completion: (UIImage?) -> Void
    private var delivered = false

    init(completion: @escaping (UIImage?) -> Void) {
        self.completion = completion
    }

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        deliver(info[.originalImage] as? UIImage)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
        deliver(nil)
    }

    private func deliver(_ image: UIImage?) {
        guard !delivered else { return }
        delivered = true
        ExteraModImagePickerRetainer.release(self)
        completion(image)
    }
}
