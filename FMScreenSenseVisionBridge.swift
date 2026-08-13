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

                let liveTextInteraction = ImageAnalysisInteraction()
                imageView.isUserInteractionEnabled = true
                imageView.addInteraction(liveTextInteraction)
                // Assign the analysis before enabling the interaction types.
                // iOS 16 rebuilds the Live Text state when analysis is set;
                // configuring textSelection before that point leaves the
                // interaction attached but with selectableItemsHighlighted=0.
                liveTextInteraction.analysis = result
                liveTextInteraction.delegate = self
                liveTextInteraction.preferredInteractionTypes = .textSelection
                liveTextInteraction.isSupplementaryInterfaceHidden = false
                // Keep the standard Live Text long-press behavior. Data
                // detector handling is disabled by textSelection itself
                // unless iOS finds a URL, phone number, or address.
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

        // iOS 16 exposes the active-selection state and the native Live Text
        // actions, but not a public selected-text string. The string APIs are
        // available starting with iOS 17 and are intentionally used only for
        // diagnostics here; translation and copying stay inside Live Text.
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
    public func presentingViewController(
        for interaction: ImageAnalysisInteraction
    ) -> UIViewController? {
        return preferredPresentingViewController
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
