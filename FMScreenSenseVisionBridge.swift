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
    private var selectionHandler: ((Bool, Int, Int) -> Void)?
    private var visionStateHandler: ((Bool, UInt) -> Void)?
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
    @objc public var currentSelectedText: NSString {
        return selectedTextSnapshot() as NSString
    }

    @MainActor
    @objc public var currentFullText: NSString {
        return (analysis?.transcript ?? "") as NSString
    }

    @MainActor
    @objc public var selectedTextLength: Int {
        return currentSelectedText.length
    }

    @MainActor
    @objc public var selectedRangeCount: Int {
        guard let liveTextInteraction = interaction else {
            return 0
        }
        if #available(iOS 17.0, *) {
            return liveTextInteraction.selectedRanges.count
        }
        return 0
    }

    @MainActor
    @objc public var interactionViewMatchesImageView: Bool {
        guard let liveTextInteraction = interaction else {
            return false
        }
        return liveTextInteraction.view === attachedImageView
    }

    @MainActor
    @objc public var interactionImageViewBounds: CGRect {
        return attachedImageView?.bounds ?? .zero
    }

    @MainActor
    @objc public var interactionImageViewContentModeRawValue: Int {
        return attachedImageView?.contentMode.rawValue ?? -1
    }

    @MainActor
    @objc public var interactionImageSize: CGSize {
        return attachedImageView?.image?.size ?? .zero
    }

    @MainActor
    @objc public var interactionContentsRect: CGRect {
        return interaction?.contentsRect ?? .zero
    }

    /// Returns whether VisionKit has an interactive item at the point. The
    /// point must be in the attached UIImageView's coordinate space.
    @MainActor
    @objc(screenSenseHasInteractiveItemAt:)
    public func screenSenseHasInteractiveItem(at point: CGPoint) -> Bool {
        guard let liveTextInteraction = interaction else {
            return false
        }
        return liveTextInteraction.hasInteractiveItem(at: point)
    }

    /// Returns whether the analyzed image contains text at the point. The
    /// point must be in the attached UIImageView's coordinate space.
    @MainActor
    @objc(screenSenseHasTextAt:)
    public func screenSenseHasText(at point: CGPoint) -> Bool {
        guard let liveTextInteraction = interaction else {
            return false
        }
        return liveTextInteraction.analysisHasText(at: point)
    }

    @MainActor
    @objc public func setSelectionHandler(
        _ handler: @escaping (Bool, Int, Int) -> Void
    ) {
        selectionHandler = handler
    }

    @MainActor
    @objc public func setVisionStateHandler(
        _ handler: @escaping (Bool, UInt) -> Void
    ) {
        visionStateHandler = handler
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

                // Construct the interaction with its delegate already
                // installed. VisionKit creates the native Live Text action
                // responder while the interaction is attached; assigning the
                // delegate after analysis can leave selection highlights alive
                // while copy/translate actions have no presenting context on
                // iOS 16.
                let liveTextInteraction = ImageAnalysisInteraction(self)
                imageView.isUserInteractionEnabled = true
                imageView.addInteraction(liveTextInteraction)
                // Assign the analysis before enabling the interaction types.
                // iOS 16 rebuilds the Live Text state when analysis is set;
                // configuring textSelection before that point leaves the
                // interaction attached but with selectableItemsHighlighted=0.
                liveTextInteraction.analysis = result
                liveTextInteraction.preferredInteractionTypes = .textSelection
                liveTextInteraction.isSupplementaryInterfaceHidden = false
                // Keep standard Live Text long-press behavior for data found
                // inside recognized text. The text-selection action menu
                // remains the system menu and supplies Copy/Translate.
                liveTextInteraction.allowLongPressForDataDetectorsInTextMode = true
                liveTextInteraction.selectableItemsHighlighted = true
                self.analysis = result
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
        visionStateHandler = nil
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

    @MainActor
    private func selectedTextSnapshot() -> String {
        guard let liveTextInteraction = interaction else {
            return ""
        }

        // Some iOS 16 VisionKit builds expose the selection getter at runtime
        // even though the public SDK declares it starting with iOS 17. Probe
        // it dynamically so the system-Translate jump can carry the selected
        // range when the device provides it, while keeping the iOS 16 build
        // free of a newer-only link-time symbol.
        for key in ["selectedText", "selectedAttributedText"] {
            let selector = NSSelectorFromString(key)
            guard liveTextInteraction.responds(to: selector) else {
                continue
            }

            if let value = liveTextInteraction.value(forKey: key) as? String,
               !value.isEmpty {
                return value
            }

            if let value = liveTextInteraction.value(forKey: key) as? NSString,
               value.length > 0 {
                return value as String
            }

            if let value = liveTextInteraction.value(forKey: key)
                as? NSAttributedString,
               value.length > 0 {
                return value.string
            }
        }

        if #available(iOS 17.0, *) {
            return liveTextInteraction.selectedText
        }

        return ""
    }

    @MainActor
    private func notifySelectionState(for liveTextInteraction: ImageAnalysisInteraction) {
        let selectedText = selectedTextSnapshot()
        let fullText = analysis?.transcript ?? ""
        selectionHandler?(
            liveTextInteraction.hasActiveTextSelection || !selectedText.isEmpty,
            selectedText.count,
            fullText.count
        )
    }
}

extension FMScreenSenseVisionBridge: ImageAnalysisInteractionDelegate {
    @MainActor
    public func contentView(
        for interaction: ImageAnalysisInteraction
    ) -> UIView? {
        // Be explicit because this interaction lives in a custom SpringBoard
        // window. Returning the actual UIImageView keeps the native action
        // menu anchored to the same view that owns the image interaction.
        return attachedImageView
    }

    @MainActor
    public func contentsRect(
        for interaction: ImageAnalysisInteraction
    ) -> CGRect {
        // The image fills the UIImageView's content area. UIImageView would
        // normally provide this calculation itself; returning the unit rect
        // makes the contract deterministic for the custom window as well.
        return CGRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0)
    }

    @MainActor
    public func presentingViewController(
        for interaction: ImageAnalysisInteraction
    ) -> UIViewController? {
        return preferredPresentingViewController
    }

    @MainActor
    public func interaction(
        _ interaction: ImageAnalysisInteraction,
        shouldBeginAt point: CGPoint,
        for interactionType: ImageAnalysisInteraction.InteractionTypes
    ) -> Bool {
        // Do not let the default delegate implementation reject the second
        // tap/long-press that opens the native Live Text action menu on iOS
        // 16. VisionKit still performs the hit test internally.
        return true
    }

    @MainActor
    public func textSelectionDidChange(_ interaction: ImageAnalysisInteraction) {
        notifySelectionState(for: interaction)
    }

    @MainActor
    public func interaction(
        _ interaction: ImageAnalysisInteraction,
        highlightSelectedItemsDidChange highlighted: Bool
    ) {
        visionStateHandler?(
            highlighted,
            interaction.activeInteractionTypes.rawValue
        )
        notifySelectionState(for: interaction)
    }
}
