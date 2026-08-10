import Foundation
import UIKit
import VisionKit

/// The Swift-only part of ScreenSense.
///
/// ImageAnalyzer, ImageAnalysis, and ImageAnalyzer.Configuration are kept
/// inside this bridge. Objective-C++ only sees the small NSObject surface
/// below, which keeps VisionKit's Swift-only types out of the tweak session.
@objcMembers
public final class FMScreenSenseVisionBridge: NSObject {
    private let bridgeErrorDomain = "com.codex.flymemultitasking.screensense.vision"

    private var analyzer: ImageAnalyzer?
    private var analysis: ImageAnalysis?
    private var interaction: ImageAnalysisInteraction?
    private var analysisTask: Task<Void, Never>?
    private weak var attachedImageView: UIImageView?
    private var completion: ((Bool, NSError?) -> Void)?
    private var selectionHandler: ((Bool, Int) -> Void)?
    private weak var preferredPresentingViewController: UIViewController?
    private var generation: UInt64 = 0

    @objc public class var isSupported: Bool {
        return ImageAnalyzer.isSupported
    }

    @objc public override init() {
        super.init()
    }

    @MainActor
    @objc public var preferredInteractionTypesRawValue: UInt {
        return interaction?.preferredInteractionTypes.rawValue ?? 0
    }

    @MainActor
    @objc public var supplementaryInterfaceHidden: Bool {
        return interaction?.isSupplementaryInterfaceHidden ?? false
    }

    @MainActor
    @objc public var selectableItemsHighlighted: Bool {
        return interaction?.selectableItemsHighlighted ?? false
    }

    @MainActor
    @objc public var hasActiveTextSelection: Bool {
        return interaction?.hasActiveTextSelection ?? false
    }

    @MainActor
    @objc public var selectedTextLength: Int {
        guard let liveTextInteraction = interaction else {
            return 0
        }
        if #available(iOS 17.0, *) {
            return liveTextInteraction.selectedText.count
        }
        // iOS 16 exposes hasActiveTextSelection but not selectedText. Keep
        // this diagnostic value at zero rather than using an unsafe runtime
        // call to a newer API.
        return 0
    }

    /// Returns whether VisionKit owns the point. The point must be in the
    /// attached UIImageView's coordinate space.
    @MainActor
    @objc public func isInteractivePoint(at point: CGPoint) -> Bool {
        guard let liveTextInteraction = interaction else {
            return false
        }
        return liveTextInteraction.hasInteractiveItem(at: point) ||
               liveTextInteraction.analysisHasText(at: point)
    }

    @MainActor
    @objc public func setSelectionHandler(
        _ handler: @escaping (Bool, Int) -> Void
    ) {
        selectionHandler = handler
    }

    @MainActor
    @objc public func setPresentingViewController(
        _ viewController: UIViewController?
    ) {
        preferredPresentingViewController = viewController
    }

    /// Starts one text-only Live Text analysis for the supplied frozen image.
    /// The method is main-actor isolated because it creates and attaches the
    /// UIKit ImageAnalysisInteraction. The analysis itself may suspend while
    /// VisionKit performs its asynchronous work.
    @MainActor
    @objc public func attachLiveText(
        to imageView: UIImageView,
        image: UIImage,
        completion: @escaping (Bool, NSError?) -> Void
    ) {
        generation &+= 1
        let currentGeneration = generation

        analysisTask?.cancel()
        removeInteractionOnMain()
        analysis = nil
        analyzer = nil
        self.completion = completion
        attachedImageView = imageView

        guard ImageAnalyzer.isSupported else {
            let error = NSError(
                domain: bridgeErrorDomain,
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Image analysis is not supported on this device."
                ]
            )
            self.completion = nil
            completion(false, error)
            return
        }

        let imageAnalyzer = ImageAnalyzer()
        analyzer = imageAnalyzer
        let configuration = ImageAnalyzer.Configuration([.text])

        analysisTask = Task { [weak self, imageAnalyzer, image, imageView, configuration, currentGeneration] in
            do {
                let result = try await imageAnalyzer.analyze(
                    image,
                    configuration: configuration
                )

                guard !Task.isCancelled else {
                    return
                }

                guard let self = self,
                      self.generation == currentGeneration,
                      self.attachedImageView === imageView else {
                    return
                }

                self.analysis = result

                let liveTextInteraction = ImageAnalysisInteraction()
                liveTextInteraction.preferredInteractionTypes = .textSelection
                liveTextInteraction.isSupplementaryInterfaceHidden = true
                liveTextInteraction.selectableItemsHighlighted = true
                liveTextInteraction.delegate = self
                imageView.isUserInteractionEnabled = true
                imageView.addInteraction(liveTextInteraction)
                liveTextInteraction.analysis = result
                self.interaction = liveTextInteraction
                self.analysisTask = nil

                let finish = self.completion
                self.completion = nil
                finish?(true, nil)
            } catch {
                guard !Task.isCancelled else {
                    return
                }

                guard let self = self,
                      self.generation == currentGeneration else {
                    return
                }

                self.analysisTask = nil
                self.analysis = nil
                let finish = self.completion
                self.completion = nil
                finish?(false, error as NSError)
            }
        }
    }

    /// Cancels the current analysis and removes all Live Text state.
    @MainActor
    @objc public func teardown() {
        generation &+= 1
        analysisTask?.cancel()
        analysisTask = nil
        removeInteractionOnMain()
        analysis = nil
        analyzer = nil
        attachedImageView = nil
        completion = nil
        selectionHandler = nil
        preferredPresentingViewController = nil
    }

    @MainActor
    private func removeInteractionOnMain() {
        if let liveTextInteraction = interaction,
           let imageView = attachedImageView {
            imageView.removeInteraction(liveTextInteraction)
        }
        interaction = nil
    }
}

extension FMScreenSenseVisionBridge: ImageAnalysisInteractionDelegate {
    public func presentingViewController(
        for interaction: ImageAnalysisInteraction
    ) -> UIViewController? {
        return preferredPresentingViewController
    }

    public func textSelectionDidChange(_ interaction: ImageAnalysisInteraction) {
        Task { @MainActor [weak self, weak interaction] in
            guard let self = self, let interaction = interaction else {
                return
            }
            let length: Int
            if #available(iOS 17.0, *) {
                length = interaction.selectedText.count
            } else {
                length = 0
            }
            self.selectionHandler?(
                interaction.hasActiveTextSelection,
                length
            )
        }
    }
}
