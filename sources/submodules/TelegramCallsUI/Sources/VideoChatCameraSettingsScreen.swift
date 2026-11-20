import Foundation
import UIKit
import AVFoundation
import PhotosUI
import Display
import ComponentFlow
import SwiftSignalKit
import AccountContext
import ViewControllerComponent
import ResizableSheetComponent
import MultilineTextComponent
import BundleIconComponent
import GlassBarButtonComponent
import ButtonComponent
import TelegramPresentationData
import AppBundle

/// Live preview of the processed camera feed. Mirrored like a mirror, while the stream is sent unmirrored.
private final class VideoChatCameraPreviewView: UIView {
    let displayLayer = AVSampleBufferDisplayLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)

        self.clipsToBounds = true
        self.layer.cornerRadius = 26.0
        if #available(iOS 13.0, *) {
            self.layer.cornerCurve = .continuous
        }
        self.backgroundColor = UIColor(white: 0.1, alpha: 1.0)

        self.displayLayer.videoGravity = .resizeAspectFill
        self.displayLayer.setAffineTransform(CGAffineTransform(scaleX: -1.0, y: 1.0))
        self.layer.addSublayer(self.displayLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        if self.displayLayer.status == .failed {
            self.displayLayer.flush()
        }
        self.displayLayer.enqueue(sampleBuffer)
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.displayLayer.frame = self.bounds
        CATransaction.commit()
    }
}

/// One circle of the Background row: None, Blur, Studio, Custom.
private final class VideoChatCameraBackgroundOptionView: UIControl {
    enum Kind {
        case original
        case blur
        case studio
        case custom
    }

    private let kind: Kind
    private let circleView = UIView()
    private let iconView = UIImageView()
    private let dashedLayer = CAShapeLayer()
    private let selectionLayer = CAShapeLayer()
    private let titleLabel = UILabel()
    private let badgeView = UIImageView()

    static let circleSize: CGFloat = 56.0

    init(kind: Kind, title: String, showsPremiumBadge: Bool) {
        self.kind = kind

        super.init(frame: CGRect())

        self.circleView.isUserInteractionEnabled = false
        self.circleView.layer.cornerRadius = VideoChatCameraBackgroundOptionView.circleSize * 0.5
        self.circleView.clipsToBounds = true
        self.addSubview(self.circleView)

        self.iconView.isUserInteractionEnabled = false
        self.iconView.contentMode = .center
        self.iconView.tintColor = .white
        self.addSubview(self.iconView)

        let symbolConfiguration = UIImage.SymbolConfiguration(pointSize: 20.0, weight: .medium)
        switch kind {
        case .original:
            self.circleView.backgroundColor = UIColor(white: 1.0, alpha: 0.1)
            self.iconView.image = UIImage(systemName: "nosign", withConfiguration: symbolConfiguration)
        case .blur:
            self.circleView.backgroundColor = UIColor(rgb: 0x8a7a6e)
            self.iconView.image = UIImage(systemName: "circle.dotted", withConfiguration: symbolConfiguration)
        case .studio:
            let gradient = CAGradientLayer()
            gradient.type = .radial
            gradient.colors = [UIColor(rgb: 0x6b7387).cgColor, UIColor(rgb: 0x1f2129).cgColor]
            gradient.startPoint = CGPoint(x: 0.5, y: 0.35)
            gradient.endPoint = CGPoint(x: 1.1, y: 1.1)
            gradient.frame = CGRect(origin: CGPoint(), size: CGSize(width: VideoChatCameraBackgroundOptionView.circleSize, height: VideoChatCameraBackgroundOptionView.circleSize))
            self.circleView.layer.addSublayer(gradient)
        case .custom:
            self.circleView.backgroundColor = .clear
            self.iconView.image = UIImage(systemName: "plus", withConfiguration: symbolConfiguration)
            self.dashedLayer.fillColor = nil
            self.dashedLayer.strokeColor = UIColor(white: 1.0, alpha: 0.4).cgColor
            self.dashedLayer.lineWidth = 1.5
            self.dashedLayer.lineDashPattern = [4, 6]
            self.layer.addSublayer(self.dashedLayer)
        }

        self.selectionLayer.fillColor = nil
        self.selectionLayer.lineWidth = 2.0
        self.selectionLayer.isHidden = true
        self.layer.addSublayer(self.selectionLayer)

        self.titleLabel.font = Font.regular(13.0)
        self.titleLabel.textColor = UIColor(white: 1.0, alpha: 0.85)
        self.titleLabel.textAlignment = .center
        self.titleLabel.text = title
        self.addSubview(self.titleLabel)

        if showsPremiumBadge {
            self.badgeView.image = UIImage(bundleImageName: "Premium/PremiumStar")
            self.badgeView.contentMode = .scaleAspectFit
            self.addSubview(self.badgeView)
        }

        self.accessibilityLabel = title
        self.isAccessibilityElement = true
        self.accessibilityTraits = .button
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(isSelected: Bool, accentColor: UIColor) {
        self.selectionLayer.isHidden = !isSelected
        self.selectionLayer.strokeColor = accentColor.cgColor
        self.accessibilityTraits = isSelected ? [.button, .selected] : .button
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let size = VideoChatCameraBackgroundOptionView.circleSize
        let circleFrame = CGRect(x: floor((self.bounds.width - size) * 0.5), y: 4.0, width: size, height: size)
        self.circleView.frame = circleFrame
        self.iconView.frame = circleFrame
        self.dashedLayer.path = UIBezierPath(ovalIn: circleFrame.insetBy(dx: 0.75, dy: 0.75)).cgPath
        self.selectionLayer.path = UIBezierPath(ovalIn: circleFrame.insetBy(dx: -4.0, dy: -4.0)).cgPath
        self.titleLabel.frame = CGRect(x: 0.0, y: circleFrame.maxY + 10.0, width: self.bounds.width, height: 16.0)
        self.badgeView.frame = CGRect(x: circleFrame.maxX - 14.0, y: circleFrame.minY - 3.0, width: 18.0, height: 18.0)
    }
}

/// Appearance toggle: Lighting, Touch Up.
private final class VideoChatCameraChipView: UIControl {
    private let iconView = UIImageView()
    private let titleLabel = UILabel()

    init(title: String, systemImageName: String) {
        super.init(frame: CGRect())

        self.layer.cornerRadius = 18.0
        self.layer.borderWidth = 1.0
        self.layer.borderColor = UIColor(white: 1.0, alpha: 0.12).cgColor

        self.iconView.image = UIImage(systemName: systemImageName, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15.0, weight: .medium))
        self.iconView.tintColor = .white
        self.iconView.contentMode = .center
        self.addSubview(self.iconView)

        self.titleLabel.font = Font.medium(15.0)
        self.titleLabel.textColor = .white
        self.titleLabel.text = title
        self.addSubview(self.titleLabel)

        self.accessibilityLabel = title
        self.isAccessibilityElement = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(isOn: Bool, accentColor: UIColor) {
        self.backgroundColor = isOn ? accentColor : UIColor(white: 1.0, alpha: 0.08)
        self.layer.borderColor = isOn ? UIColor.clear.cgColor : UIColor(white: 1.0, alpha: 0.12).cgColor
        self.accessibilityTraits = isOn ? [.button, .selected] : .button
    }

    var preferredWidth: CGFloat {
        return 14.0 + 18.0 + 6.0 + ceil(self.titleLabel.sizeThatFits(CGSize(width: 1000.0, height: 36.0)).width) + 16.0
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        self.iconView.frame = CGRect(x: 14.0, y: 0.0, width: 18.0, height: self.bounds.height)
        self.titleLabel.frame = CGRect(x: 14.0 + 18.0 + 6.0, y: 0.0, width: self.bounds.width - (14.0 + 18.0 + 6.0) - 12.0, height: self.bounds.height)
    }
}

private final class VideoChatCameraSettingsContentComponent: Component {
    typealias EnvironmentType = ViewControllerComponentContainer.Environment

    let capturer: VideoChatCameraEffectsCapturer
    let effects: VideoChatCameraEffects
    let isPremium: Bool
    let selectBackground: (VideoChatCameraBackgroundOptionView.Kind) -> Void
    let toggleLighting: () -> Void
    let toggleTouchUp: () -> Void

    init(
        capturer: VideoChatCameraEffectsCapturer,
        effects: VideoChatCameraEffects,
        isPremium: Bool,
        selectBackground: @escaping (VideoChatCameraBackgroundOptionView.Kind) -> Void,
        toggleLighting: @escaping () -> Void,
        toggleTouchUp: @escaping () -> Void
    ) {
        self.capturer = capturer
        self.effects = effects
        self.isPremium = isPremium
        self.selectBackground = selectBackground
        self.toggleLighting = toggleLighting
        self.toggleTouchUp = toggleTouchUp
    }

    static func ==(lhs: VideoChatCameraSettingsContentComponent, rhs: VideoChatCameraSettingsContentComponent) -> Bool {
        if lhs.capturer !== rhs.capturer {
            return false
        }
        if lhs.effects != rhs.effects {
            return false
        }
        if lhs.isPremium != rhs.isPremium {
            return false
        }
        return true
    }

    final class View: UIView {
        private let previewView = VideoChatCameraPreviewView()
        private let backgroundTitle = UILabel()
        private var backgroundOptionViews: [(VideoChatCameraBackgroundOptionView.Kind, VideoChatCameraBackgroundOptionView)] = []
        private let chipsContainer = UIView()
        private var lightingChip: VideoChatCameraChipView?
        private var touchUpChip: VideoChatCameraChipView?

        private var component: VideoChatCameraSettingsContentComponent?

        override init(frame: CGRect) {
            super.init(frame: frame)

            self.addSubview(self.previewView)

            self.backgroundTitle.font = Font.regular(13.0)
            self.addSubview(self.backgroundTitle)

            self.chipsContainer.clipsToBounds = true
            self.addSubview(self.chipsContainer)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        @objc private func backgroundOptionPressed(_ sender: VideoChatCameraBackgroundOptionView) {
            guard let component = self.component, let kind = self.backgroundOptionViews.first(where: { $0.1 === sender })?.0 else {
                return
            }
            HapticFeedback().impact(.light)
            component.selectBackground(kind)
        }

        @objc private func lightingPressed() {
            HapticFeedback().impact(.light)
            self.component?.toggleLighting()
        }

        @objc private func touchUpPressed() {
            HapticFeedback().impact(.light)
            self.component?.toggleTouchUp()
        }

        func update(component: VideoChatCameraSettingsContentComponent, availableSize: CGSize, state: EmptyComponentState, environment: Environment<EnvironmentType>, transition: ComponentTransition) -> CGSize {
            let previousComponent = self.component
            self.component = component

            let environment = environment[EnvironmentType.self].value
            let theme = environment.theme
            let strings = environment.strings
            let accentColor = theme.list.itemAccentColor

            if previousComponent?.capturer !== component.capturer {
                component.capturer.previewFrame = { [weak self] sampleBuffer in
                    self?.previewView.enqueue(sampleBuffer)
                }
            }

            if self.backgroundOptionViews.isEmpty {
                let options: [(VideoChatCameraBackgroundOptionView.Kind, String)] = [
                    (.original, strings.VideoChat_CameraSettings_BackgroundNone),
                    (.blur, strings.VideoChat_CameraSettings_BackgroundBlur),
                    (.studio, strings.VideoChat_CameraSettings_BackgroundStudio),
                    (.custom, strings.VideoChat_CameraSettings_BackgroundCustom)
                ]
                for (kind, title) in options {
                    let optionView = VideoChatCameraBackgroundOptionView(kind: kind, title: title, showsPremiumBadge: kind == .custom && !component.isPremium)
                    optionView.addTarget(self, action: #selector(self.backgroundOptionPressed(_:)), for: .touchUpInside)
                    self.addSubview(optionView)
                    self.backgroundOptionViews.append((kind, optionView))
                }

                let lightingChip = VideoChatCameraChipView(title: strings.VideoChat_CameraSettings_Lighting, systemImageName: "sun.max")
                lightingChip.addTarget(self, action: #selector(self.lightingPressed), for: .touchUpInside)
                self.chipsContainer.addSubview(lightingChip)
                self.lightingChip = lightingChip

                let touchUpChip = VideoChatCameraChipView(title: strings.VideoChat_CameraSettings_TouchUp, systemImageName: "sparkles")
                touchUpChip.addTarget(self, action: #selector(self.touchUpPressed), for: .touchUpInside)
                self.chipsContainer.addSubview(touchUpChip)
                self.touchUpChip = touchUpChip
            }

            let sideInset: CGFloat = 16.0
            // The sheet's title bar overlays the content.
            var contentHeight: CGFloat = 76.0

            let previewWidth = availableSize.width - sideInset * 2.0
            let previewHeight = min(floor(previewWidth * 4.0 / 3.0), max(240.0, availableSize.height * 0.42))
            transition.setFrame(view: self.previewView, frame: CGRect(x: sideInset, y: contentHeight, width: previewWidth, height: previewHeight))
            contentHeight += previewHeight + 22.0

            self.backgroundTitle.text = strings.VideoChat_CameraSettings_Background.uppercased()
            self.backgroundTitle.textColor = theme.list.freeTextColor
            self.backgroundTitle.frame = CGRect(x: sideInset + 16.0, y: contentHeight, width: previewWidth, height: 16.0)
            contentHeight += 16.0 + 8.0

            let optionWidth: CGFloat = 72.0
            let optionsWidth = optionWidth * CGFloat(self.backgroundOptionViews.count)
            var optionX = floor((availableSize.width - optionsWidth) * 0.5)
            for (kind, optionView) in self.backgroundOptionViews {
                let isSelected: Bool
                switch (kind, component.effects.background) {
                case (.original, .original), (.blur, .blur), (.studio, .studio), (.custom, .custom):
                    isSelected = true
                default:
                    isSelected = false
                }
                optionView.update(isSelected: isSelected, accentColor: accentColor)
                transition.setFrame(view: optionView, frame: CGRect(x: optionX, y: contentHeight, width: optionWidth, height: 92.0))
                optionX += optionWidth
            }
            contentHeight += 92.0 + 12.0

            let chipHeight: CGFloat = 36.0
            var chipX: CGFloat = 0.0
            if let lightingChip = self.lightingChip {
                lightingChip.update(isOn: component.effects.lighting, accentColor: accentColor)
                let width = lightingChip.preferredWidth
                lightingChip.frame = CGRect(x: chipX, y: 0.0, width: width, height: chipHeight)
                chipX += width + 8.0
            }
            if let touchUpChip = self.touchUpChip {
                touchUpChip.update(isOn: component.effects.touchUp, accentColor: accentColor)
                let width = touchUpChip.preferredWidth
                touchUpChip.frame = CGRect(x: chipX, y: 0.0, width: width, height: chipHeight)
                chipX += width
            }
            let chipsWidth = min(chipX, availableSize.width - sideInset * 2.0)
            transition.setFrame(view: self.chipsContainer, frame: CGRect(x: floor((availableSize.width - chipsWidth) * 0.5), y: contentHeight, width: chipsWidth, height: chipHeight))
            contentHeight += chipHeight

            // Room for the "Turn On Video" button the sheet pins to the bottom.
            contentHeight += 24.0 + 52.0 + 24.0 + environment.safeInsets.bottom

            return CGSize(width: availableSize.width, height: contentHeight)
        }
    }

    func makeView() -> View {
        return View(frame: CGRect())
    }

    func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<EnvironmentType>, transition: ComponentTransition) -> CGSize {
        return view.update(component: self, availableSize: availableSize, state: state, environment: environment, transition: transition)
    }
}

private final class VideoChatCameraSettingsSheetComponent: Component {
    typealias EnvironmentType = ViewControllerComponentContainer.Environment

    let capturer: VideoChatCameraEffectsCapturer
    let isPremium: Bool
    let openPremium: () -> Void
    let turnOnVideo: (VideoChatCameraEffectsCapturer) -> Void

    init(capturer: VideoChatCameraEffectsCapturer, isPremium: Bool, openPremium: @escaping () -> Void, turnOnVideo: @escaping (VideoChatCameraEffectsCapturer) -> Void) {
        self.capturer = capturer
        self.isPremium = isPremium
        self.openPremium = openPremium
        self.turnOnVideo = turnOnVideo
    }

    static func ==(lhs: VideoChatCameraSettingsSheetComponent, rhs: VideoChatCameraSettingsSheetComponent) -> Bool {
        if lhs.capturer !== rhs.capturer {
            return false
        }
        if lhs.isPremium != rhs.isPremium {
            return false
        }
        return true
    }

    final class View: UIView, PHPickerViewControllerDelegate {
        private let sheet = ComponentView<(ViewControllerComponentContainer.Environment, ResizableSheetComponentEnvironment)>()
        private let animateOut = ActionSlot<Action<()>>()

        private var component: VideoChatCameraSettingsSheetComponent?
        private weak var state: EmptyComponentState?
        private var environment: ViewControllerComponentContainer.Environment?

        private var effects: VideoChatCameraEffects = .off
        private var didTurnOnVideo = false

        override init(frame: CGRect) {
            super.init(frame: frame)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func sheetWillDismiss() {
            if !self.didTurnOnVideo {
                self.component?.capturer.stop()
            }
        }

        private func dismiss(animated: Bool) {
            guard let environment = self.environment else {
                return
            }
            self.sheetWillDismiss()
            if animated {
                self.animateOut.invoke(Action { _ in
                    environment.controller()?.dismiss(completion: nil)
                })
            } else {
                environment.controller()?.dismiss(completion: nil)
            }
        }

        private func updateEffects(_ f: (inout VideoChatCameraEffects) -> Void) {
            guard let component = self.component else {
                return
            }
            var effects = self.effects
            f(&effects)
            self.effects = effects
            component.capturer.effects = effects
            self.state?.updated(transition: .easeInOut(duration: 0.2))
        }

        private func selectBackground(_ kind: VideoChatCameraBackgroundOptionView.Kind) {
            guard let component = self.component else {
                return
            }
            switch kind {
            case .original:
                self.updateEffects { $0.background = .original }
            case .blur:
                self.updateEffects { $0.background = .blur }
            case .studio:
                self.updateEffects { $0.background = .studio }
            case .custom:
                if !component.isPremium {
                    HapticFeedback().error()
                    component.openPremium()
                    return
                }
                self.pickCustomBackground()
            }
        }

        private func pickCustomBackground() {
            guard let environment = self.environment, let controller = environment.controller() else {
                return
            }
            var configuration = PHPickerConfiguration()
            configuration.filter = .images
            configuration.selectionLimit = 1
            let picker = PHPickerViewController(configuration: configuration)
            picker.delegate = self
            controller.present(picker, animated: true)
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else {
                return
            }
            provider.loadObject(ofClass: UIImage.self, completionHandler: { [weak self] object, _ in
                guard let image = object as? UIImage else {
                    return
                }
                DispatchQueue.main.async {
                    self?.updateEffects { $0.background = .custom(image) }
                }
            })
        }

        func update(component: VideoChatCameraSettingsSheetComponent, availableSize: CGSize, state: EmptyComponentState, environment: Environment<ViewControllerComponentContainer.Environment>, transition: ComponentTransition) -> CGSize {
            if self.component == nil {
                self.effects = component.capturer.effects
                component.capturer.start()
            }
            self.component = component
            self.state = state
            let environment = environment[ViewControllerComponentContainer.Environment.self].value
            self.environment = environment
            let theme = environment.theme

            let sheetSize = self.sheet.update(
                transition: transition,
                component: AnyComponent(ResizableSheetComponent<ViewControllerComponentContainer.Environment>(
                    content: AnyComponent<ViewControllerComponentContainer.Environment>(VideoChatCameraSettingsContentComponent(
                        capturer: component.capturer,
                        effects: self.effects,
                        isPremium: component.isPremium,
                        selectBackground: { [weak self] kind in
                            self?.selectBackground(kind)
                        },
                        toggleLighting: { [weak self] in
                            self?.updateEffects { $0.lighting = !$0.lighting }
                        },
                        toggleTouchUp: { [weak self] in
                            self?.updateEffects { $0.touchUp = !$0.touchUp }
                        }
                    )),
                    titleItem: AnyComponent(MultilineTextComponent(
                        text: .plain(NSAttributedString(string: environment.strings.VideoChat_CameraSettings_Title, font: Font.semibold(17.0), textColor: theme.list.itemPrimaryTextColor)),
                        maximumNumberOfLines: 1
                    )),
                    leftItem: AnyComponent(GlassBarButtonComponent(
                        size: CGSize(width: 44.0, height: 44.0),
                        backgroundColor: nil,
                        isDark: theme.overallDarkAppearance,
                        state: .glass,
                        component: AnyComponentWithIdentity(id: "close", component: AnyComponent(BundleIconComponent(
                            name: "Navigation/Close",
                            tintColor: theme.chat.inputPanel.panelControlColor
                        ))),
                        action: { [weak self] _ in
                            self?.dismiss(animated: true)
                        }
                    )),
                    rightItem: AnyComponent(GlassBarButtonComponent(
                        size: CGSize(width: 44.0, height: 44.0),
                        backgroundColor: nil,
                        isDark: theme.overallDarkAppearance,
                        state: .glass,
                        component: AnyComponentWithIdentity(id: "switchCamera", component: AnyComponent(BundleIconComponent(
                            name: "Call/CallSwitchCameraButton",
                            tintColor: theme.chat.inputPanel.panelControlColor,
                            maxSize: CGSize(width: 26.0, height: 26.0)
                        ))),
                        action: { [weak self] _ in
                            HapticFeedback().impact(.light)
                            self?.component?.capturer.switchCamera()
                        }
                    )),
                    bottomItem: AnyComponent(ButtonComponent(
                        background: ButtonComponent.Background(
                            style: .glass,
                            color: theme.list.itemCheckColors.fillColor,
                            foreground: theme.list.itemCheckColors.foregroundColor,
                            pressedColor: theme.list.itemCheckColors.fillColor.withMultipliedAlpha(0.9)
                        ),
                        content: AnyComponentWithIdentity(id: AnyHashable("turnOn"), component: AnyComponent(ButtonTextContentComponent(
                            text: environment.strings.VideoChat_CameraSettings_TurnOnVideo,
                            badge: 0,
                            textColor: theme.list.itemCheckColors.foregroundColor,
                            badgeBackground: theme.list.itemCheckColors.foregroundColor,
                            badgeForeground: theme.list.itemCheckColors.fillColor
                        ))),
                        isEnabled: true,
                        displaysProgress: false,
                        action: { [weak self] in
                            guard let self, let component = self.component else {
                                return
                            }
                            self.didTurnOnVideo = true
                            component.capturer.previewFrame = nil
                            component.turnOnVideo(component.capturer)
                            self.dismiss(animated: true)
                        }
                    )),
                    backgroundColor: .color(theme.list.modalBlocksBackgroundColor),
                    animateOut: self.animateOut
                )),
                environment: {
                    environment
                    ResizableSheetComponentEnvironment(
                        theme: theme,
                        statusBarHeight: environment.statusBarHeight,
                        safeInsets: environment.safeInsets,
                        inputHeight: 0.0,
                        metrics: environment.metrics,
                        deviceMetrics: environment.deviceMetrics,
                        isDisplaying: environment.isVisible,
                        isCentered: environment.presentsFloatingPanels,
                        screenSize: availableSize,
                        regularMetricsSize: nil,
                        dismiss: { [weak self] animated in
                            self?.dismiss(animated: animated)
                        }
                    )
                },
                containerSize: availableSize
            )
            self.sheet.parentState = state
            if let sheetView = self.sheet.view {
                if sheetView.superview == nil {
                    self.addSubview(sheetView)
                }
                transition.setFrame(view: sheetView, frame: CGRect(origin: CGPoint(), size: sheetSize))
            }

            return availableSize
        }
    }

    func makeView() -> View {
        return View(frame: CGRect())
    }

    func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<ViewControllerComponentContainer.Environment>, transition: ComponentTransition) -> CGSize {
        return view.update(component: self, availableSize: availableSize, state: state, environment: environment, transition: transition)
    }
}

/// Camera with video effects: background (None, Blur, Studio, Custom with Premium), Lighting and
/// Touch Up, all previewed live before the video goes out. The effects keep running on the same
/// capturer after "Turn On Video", so what the preview shows is what participants see.
public final class VideoChatCameraSettingsScreen: ViewControllerComponentContainer {
    public init(context: AccountContext, capturer: VideoChatCameraEffectsCapturer, isPremium: Bool, openPremium: @escaping () -> Void, turnOnVideo: @escaping (VideoChatCameraEffectsCapturer) -> Void) {
        super.init(
            context: context,
            component: VideoChatCameraSettingsSheetComponent(
                capturer: capturer,
                isPremium: isPremium,
                openPremium: openPremium,
                turnOnVideo: turnOnVideo
            ),
            navigationBarAppearance: .none,
            statusBarStyle: .ignore,
            theme: .dark
        )
        self.navigationPresentation = .flatModal
    }

    required public init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
