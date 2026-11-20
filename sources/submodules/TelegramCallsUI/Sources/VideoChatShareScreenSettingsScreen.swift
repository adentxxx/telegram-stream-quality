import Foundation
import UIKit
import ReplayKit
import Display
import ComponentFlow
import SwiftSignalKit
import AccountContext
import ViewControllerComponent
import ResizableSheetComponent
import ListSectionComponent
import ListActionItemComponent
import MultilineTextComponent
import BundleIconComponent
import GlassBarButtonComponent
import ButtonComponent
import ContextUI
import TelegramPresentationData
import TelegramVoip

/// Rows of the Share Screen sheet, kept free of UIKit so the Premium rules can be unit-tested.
struct VideoChatShareScreenOption<Value: Equatable>: Equatable {
    let value: Value
    let title: String
    let isSelected: Bool
    let isLocked: Bool
}

func videoChatShareScreenResolutionOptions(settings: ScreencastQualitySettings, isPremium: Bool) -> [VideoChatShareScreenOption<ScreencastQualitySettings.Resolution>] {
    return ScreencastQualitySettings.Resolution.allCases.map { value in
        return VideoChatShareScreenOption(value: value, title: value.title, isSelected: value == settings.resolution, isLocked: value.requiresPremium && !isPremium)
    }
}

func videoChatShareScreenFrameRateOptions(settings: ScreencastQualitySettings, isPremium: Bool) -> [VideoChatShareScreenOption<ScreencastQualitySettings.FrameRate>] {
    return ScreencastQualitySettings.FrameRate.allCases.map { value in
        return VideoChatShareScreenOption(value: value, title: value.title, isSelected: value == settings.frameRate, isLocked: value.requiresPremium && !isPremium)
    }
}

private final class VideoChatShareScreenSettingsContentComponent: Component {
    typealias EnvironmentType = ViewControllerComponentContainer.Environment

    let settings: ScreencastQualitySettings
    let isPremium: Bool
    let openResolution: (UIView) -> Void
    let openFrameRate: (UIView) -> Void
    let toggleDeviceAudio: (Bool) -> Void
    let openPremium: () -> Void

    init(
        settings: ScreencastQualitySettings,
        isPremium: Bool,
        openResolution: @escaping (UIView) -> Void,
        openFrameRate: @escaping (UIView) -> Void,
        toggleDeviceAudio: @escaping (Bool) -> Void,
        openPremium: @escaping () -> Void
    ) {
        self.settings = settings
        self.isPremium = isPremium
        self.openResolution = openResolution
        self.openFrameRate = openFrameRate
        self.toggleDeviceAudio = toggleDeviceAudio
        self.openPremium = openPremium
    }

    static func ==(lhs: VideoChatShareScreenSettingsContentComponent, rhs: VideoChatShareScreenSettingsContentComponent) -> Bool {
        if lhs.settings != rhs.settings {
            return false
        }
        if lhs.isPremium != rhs.isPremium {
            return false
        }
        return true
    }

    final class View: UIView {
        private let qualitySection = ComponentView<Empty>()
        private let premiumSection = ComponentView<Empty>()

        private var component: VideoChatShareScreenSettingsContentComponent?

        override init(frame: CGRect) {
            super.init(frame: frame)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func update(component: VideoChatShareScreenSettingsContentComponent, availableSize: CGSize, state: EmptyComponentState, environment: Environment<EnvironmentType>, transition: ComponentTransition) -> CGSize {
            self.component = component

            let environment = environment[EnvironmentType.self].value
            let theme = environment.theme
            let strings = environment.strings

            let sideInset: CGFloat = 16.0
            let sectionWidth = availableSize.width - sideInset * 2.0
            let headerFont = Font.regular(13.0)
            let rowFont = Font.regular(17.0)

            // The sheet's title bar overlays the content (see `ResizableSheetComponent`).
            var contentHeight: CGFloat = 82.0

            func valueAccessory(_ text: String) -> ListActionItemComponent.Accessory {
                return .custom(ListActionItemComponent.CustomAccessory(
                    component: AnyComponentWithIdentity(id: text, component: AnyComponent(MultilineTextComponent(
                        text: .plain(NSAttributedString(string: text, font: rowFont, textColor: theme.list.itemSecondaryTextColor)),
                        maximumNumberOfLines: 1
                    ))),
                    insets: UIEdgeInsets(top: 0.0, left: 8.0, bottom: 0.0, right: 16.0)
                ))
            }

            func rowTitle(_ text: String) -> AnyComponent<Empty> {
                return AnyComponent(MultilineTextComponent(
                    text: .plain(NSAttributedString(string: text, font: rowFont, textColor: theme.list.itemPrimaryTextColor)),
                    maximumNumberOfLines: 1
                ))
            }

            let qualityItems: [AnyComponentWithIdentity<Empty>] = [
                AnyComponentWithIdentity(id: "resolution", component: AnyComponent(ListActionItemComponent(
                    theme: theme,
                    style: .glass,
                    title: rowTitle(strings.VideoChat_ShareScreenSettings_Resolution),
                    accessory: valueAccessory(component.settings.resolution.title),
                    action: { [weak self] view in
                        self?.component?.openResolution(view)
                    }
                ))),
                AnyComponentWithIdentity(id: "frameRate", component: AnyComponent(ListActionItemComponent(
                    theme: theme,
                    style: .glass,
                    title: rowTitle(strings.VideoChat_ShareScreenSettings_FrameRate),
                    accessory: valueAccessory(component.settings.frameRate.title),
                    action: { [weak self] view in
                        self?.component?.openFrameRate(view)
                    }
                ))),
                AnyComponentWithIdentity(id: "deviceAudio", component: AnyComponent(ListActionItemComponent(
                    theme: theme,
                    style: .glass,
                    title: rowTitle(strings.VideoChat_ShareScreenSettings_DeviceAudio),
                    accessory: .toggle(ListActionItemComponent.Toggle(style: .regular, isOn: component.settings.includesDeviceAudio, action: { [weak self] value in
                        self?.component?.toggleDeviceAudio(value)
                    })),
                    action: nil
                )))
            ]

            let qualitySize = self.qualitySection.update(
                transition: transition,
                component: AnyComponent(ListSectionComponent(
                    theme: theme,
                    style: .glass,
                    header: AnyComponent(MultilineTextComponent(
                        text: .plain(NSAttributedString(string: strings.VideoChat_ShareScreenSettings_QualityHeader.uppercased(), font: headerFont, textColor: theme.list.freeTextColor)),
                        maximumNumberOfLines: 1
                    )),
                    footer: AnyComponent(MultilineTextComponent(
                        text: .plain(NSAttributedString(string: strings.VideoChat_ShareScreenSettings_QualityFooter, font: headerFont, textColor: theme.list.freeTextColor)),
                        maximumNumberOfLines: 0
                    )),
                    items: qualityItems
                )),
                environment: {},
                containerSize: CGSize(width: sectionWidth, height: 10000.0)
            )
            if let qualityView = self.qualitySection.view {
                if qualityView.superview == nil {
                    self.addSubview(qualityView)
                }
                transition.setFrame(view: qualityView, frame: CGRect(origin: CGPoint(x: sideInset, y: contentHeight), size: qualitySize))
            }
            contentHeight += qualitySize.height

            if !component.isPremium {
                contentHeight += 24.0
                let premiumSize = self.premiumSection.update(
                    transition: transition,
                    component: AnyComponent(ListSectionComponent(
                        theme: theme,
                        style: .glass,
                        header: nil,
                        footer: nil,
                        items: [
                            AnyComponentWithIdentity(id: "premium", component: AnyComponent(ListActionItemComponent(
                                theme: theme,
                                style: .glass,
                                title: AnyComponent(MultilineTextComponent(
                                    text: .plain(NSAttributedString(string: strings.VideoChat_ShareScreenSettings_PremiumHint, font: rowFont, textColor: theme.list.itemAccentColor)),
                                    maximumNumberOfLines: 2
                                )),
                                icon: ListActionItemComponent.Icon(component: AnyComponentWithIdentity(id: "star", component: AnyComponent(BundleIconComponent(
                                    name: "Premium/PremiumStar",
                                    tintColor: nil
                                )))),
                                accessory: .arrow,
                                action: { [weak self] _ in
                                    self?.component?.openPremium()
                                }
                            )))
                        ]
                    )),
                    environment: {},
                    containerSize: CGSize(width: sectionWidth, height: 10000.0)
                )
                if let premiumView = self.premiumSection.view {
                    if premiumView.superview == nil {
                        self.addSubview(premiumView)
                    }
                    transition.setFrame(view: premiumView, frame: CGRect(origin: CGPoint(x: sideInset, y: contentHeight), size: premiumSize))
                    premiumView.isHidden = false
                }
                contentHeight += premiumSize.height
            } else if let premiumView = self.premiumSection.view {
                premiumView.isHidden = true
            }

            // Room for the "Start Broadcast" button the sheet pins to the bottom.
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

private final class VideoChatShareScreenSettingsSheetComponent: Component {
    typealias EnvironmentType = ViewControllerComponentContainer.Environment

    let context: AccountContext
    let isPremium: Bool
    let initialSettings: ScreencastQualitySettings
    let openPremium: () -> Void
    let start: (ScreencastQualitySettings) -> Void

    init(context: AccountContext, isPremium: Bool, initialSettings: ScreencastQualitySettings, openPremium: @escaping () -> Void, start: @escaping (ScreencastQualitySettings) -> Void) {
        self.context = context
        self.isPremium = isPremium
        self.initialSettings = initialSettings
        self.openPremium = openPremium
        self.start = start
    }

    static func ==(lhs: VideoChatShareScreenSettingsSheetComponent, rhs: VideoChatShareScreenSettingsSheetComponent) -> Bool {
        if lhs.context !== rhs.context {
            return false
        }
        if lhs.isPremium != rhs.isPremium {
            return false
        }
        if lhs.initialSettings != rhs.initialSettings {
            return false
        }
        return true
    }

    final class View: UIView {
        private let sheet = ComponentView<(ViewControllerComponentContainer.Environment, ResizableSheetComponentEnvironment)>()
        private let animateOut = ActionSlot<Action<()>>()

        private var component: VideoChatShareScreenSettingsSheetComponent?
        private weak var state: EmptyComponentState?
        private var environment: ViewControllerComponentContainer.Environment?

        private var settings: ScreencastQualitySettings?

        /// The system broadcast picker is the only way to start a ReplayKit broadcast to our
        /// extension. It stays invisible; "Start Broadcast" taps its button.
        private let broadcastPickerView: RPSystemBroadcastPickerView

        override init(frame: CGRect) {
            self.broadcastPickerView = RPSystemBroadcastPickerView(frame: CGRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0))
            self.broadcastPickerView.alpha = 0.02
            self.broadcastPickerView.showsMicrophoneButton = false

            super.init(frame: frame)

            self.addSubview(self.broadcastPickerView)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        private func dismiss(animated: Bool) {
            guard let environment = self.environment else {
                return
            }
            if animated {
                self.animateOut.invoke(Action { _ in
                    environment.controller()?.dismiss(completion: nil)
                })
            } else {
                environment.controller()?.dismiss(completion: nil)
            }
        }

        private func updateSettings(_ f: (inout ScreencastQualitySettings) -> Void) {
            guard let component = self.component else {
                return
            }
            var settings = self.settings ?? component.initialSettings
            f(&settings)
            self.settings = settings
            self.state?.updated(transition: .spring(duration: 0.4))
        }

        private func presentPremiumRequired() {
            guard let component = self.component else {
                return
            }
            HapticFeedback().error()
            component.openPremium()
        }

        private func presentOptions<Value: Equatable>(sourceView: UIView, options: [VideoChatShareScreenOption<Value>], select: @escaping (Value) -> Void) {
            guard let component = self.component, let environment = self.environment, let controller = environment.controller() else {
                return
            }
            var items: [ContextMenuItem] = []
            for option in options {
                let isSelected = option.isSelected
                let isLocked = option.isLocked
                items.append(.action(ContextMenuActionItem(text: option.title, icon: { theme in
                    if isLocked {
                        return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Lock"), color: theme.contextMenu.primaryColor)
                    } else if isSelected {
                        return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Check"), color: theme.contextMenu.primaryColor)
                    } else {
                        return UIImage()
                    }
                }, action: { [weak self] _, f in
                    f(.default)
                    guard let self else {
                        return
                    }
                    if isLocked {
                        self.presentPremiumRequired()
                    } else {
                        select(option.value)
                    }
                })))
            }
            let presentationData = component.context.sharedContext.currentPresentationData.with({ $0 }).withUpdated(theme: environment.theme)
            let contextController = makeContextController(
                presentationData: presentationData,
                source: .reference(CallAudioRouteContextReferenceContentSource(sourceView: sourceView)),
                items: .single(ContextController.Items(content: .list(items)))
            )
            controller.presentInGlobalOverlay(contextController)
        }

        private func startBroadcast() {
            guard let component = self.component else {
                return
            }
            let settings = (self.settings ?? component.initialSettings).clamped(isPremium: component.isPremium)
            // Written before the picker so the extension finds it in `broadcastStarted`.
            settings.store(basePath: component.context.sharedContext.basePath)
            component.start(settings)

            for subview in self.broadcastPickerView.subviews {
                if let button = subview as? UIButton {
                    button.sendActions(for: .allTouchEvents)
                    break
                }
            }
        }

        func update(component: VideoChatShareScreenSettingsSheetComponent, availableSize: CGSize, state: EmptyComponentState, environment: Environment<ViewControllerComponentContainer.Environment>, transition: ComponentTransition) -> CGSize {
            self.component = component
            self.state = state
            let environment = environment[ViewControllerComponentContainer.Environment.self].value
            self.environment = environment
            let theme = environment.theme

            self.broadcastPickerView.preferredExtension = "\(component.context.sharedContext.applicationBindings.appBundleId).BroadcastUpload"

            let settings = self.settings ?? component.initialSettings
            let isPremium = component.isPremium

            let sheetSize = self.sheet.update(
                transition: transition,
                component: AnyComponent(ResizableSheetComponent<ViewControllerComponentContainer.Environment>(
                    content: AnyComponent<ViewControllerComponentContainer.Environment>(VideoChatShareScreenSettingsContentComponent(
                        settings: settings,
                        isPremium: isPremium,
                        openResolution: { [weak self] sourceView in
                            guard let self else {
                                return
                            }
                            self.presentOptions(sourceView: sourceView, options: videoChatShareScreenResolutionOptions(settings: self.settings ?? component.initialSettings, isPremium: isPremium), select: { [weak self] value in
                                self?.updateSettings { $0.resolution = value }
                            })
                        },
                        openFrameRate: { [weak self] sourceView in
                            guard let self else {
                                return
                            }
                            self.presentOptions(sourceView: sourceView, options: videoChatShareScreenFrameRateOptions(settings: self.settings ?? component.initialSettings, isPremium: isPremium), select: { [weak self] value in
                                self?.updateSettings { $0.frameRate = value }
                            })
                        },
                        toggleDeviceAudio: { [weak self] value in
                            self?.updateSettings { $0.includesDeviceAudio = value }
                        },
                        openPremium: { [weak self] in
                            self?.component?.openPremium()
                        }
                    )),
                    titleItem: AnyComponent(MultilineTextComponent(
                        text: .plain(NSAttributedString(string: environment.strings.VideoChat_ShareScreenSettings_Title, font: Font.semibold(17.0), textColor: theme.list.itemPrimaryTextColor)),
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
                    bottomItem: AnyComponent(ButtonComponent(
                        background: ButtonComponent.Background(
                            style: .glass,
                            color: theme.list.itemCheckColors.fillColor,
                            foreground: theme.list.itemCheckColors.foregroundColor,
                            pressedColor: theme.list.itemCheckColors.fillColor.withMultipliedAlpha(0.9)
                        ),
                        content: AnyComponentWithIdentity(id: AnyHashable("start"), component: AnyComponent(ButtonTextContentComponent(
                            text: environment.strings.VideoChat_ShareScreenSettings_Start,
                            badge: 0,
                            textColor: theme.list.itemCheckColors.foregroundColor,
                            badgeBackground: theme.list.itemCheckColors.foregroundColor,
                            badgeForeground: theme.list.itemCheckColors.fillColor
                        ))),
                        isEnabled: true,
                        displaysProgress: false,
                        action: { [weak self] in
                            self?.startBroadcast()
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
                    self.insertSubview(sheetView, belowSubview: self.broadcastPickerView)
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

/// Share Screen with quality settings: resolution, frame rate and device audio, then the
/// system broadcast picker. 1440p and 60 FPS are Telegram Premium perks.
public final class VideoChatShareScreenSettingsScreen: ViewControllerComponentContainer {
    public init(context: AccountContext, isPremium: Bool, openPremium: @escaping () -> Void, start: @escaping (ScreencastQualitySettings) -> Void) {
        let initialSettings = ScreencastQualitySettings.load(basePath: context.sharedContext.basePath).clamped(isPremium: isPremium)
        super.init(
            context: context,
            component: VideoChatShareScreenSettingsSheetComponent(
                context: context,
                isPremium: isPremium,
                initialSettings: initialSettings,
                openPremium: openPremium,
                start: start
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
