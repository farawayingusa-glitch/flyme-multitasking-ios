param(
    [string]$Source = 'Tweak.xm',
    [string]$KeyboardSource = 'Keyboard.xm',
    [string]$LifecycleSource = 'SceneLifecycle.xm',
    [string]$KeyboardFilter = 'FlymeKeyboard.plist'
)

$ErrorActionPreference = 'Stop'

function Require-Text([string]$Path, [string]$Text) {
    if (-not (Select-String -LiteralPath $Path -SimpleMatch $Text -Quiet)) {
        throw "Missing required repair marker in ${Path}: $Text"
    }
}

function Reject-Text([string]$Path, [string]$Text) {
    if (Select-String -LiteralPath $Path -SimpleMatch $Text -Quiet) {
        throw "Rejected obsolete or unsafe marker in ${Path}: $Text"
    }
}

# Scene launch and gesture foundations remain frozen.
foreach ($Marker in @(
    'FLMFloatingLaunchTimeout = 6.5',
    'FLMFloatingSceneSettleDelay = 0.18',
    'FLMFloatingSceneGenerationDelay = 0.75',
    'failFloatingLaunchForIdentifier:',
    'generatingNewPrimarySceneIfRequired:generatePrimaryScene',
    'restoreFloatingHandleInteraction',
    'updateFloatingFullscreenSnapshotForProgress:',
    'displayCommitted = targetIsFrontmost && attempt >= 1',
    'CGFloat handleWidth = visibleHandleWidth + 40.0;',
    'pointIsInsideFloatingInteractionDomain:',
    'outsideCloseAuthorized',
    'flmOutsideCloseAuthorized',
    'UIKeyboardDidHideNotification',
    'FLYME_KEYBOARD_SESSION_NOTIFICATION',
    'FLMPublishKeyboardCardGeometry',
    '@interface FLMKeyboardForwardingWindow : UIWindow',
    'window.windowLevel = self.floatingWindow.windowLevel + 1.0;',
    '[self.keyboardForwardingWindow makeKeyAndVisible];',
    '%hook _UIKeyboardLayerHostView',
    'didUpdateClientSettingsWithDiff:',
    '[forwardingRoot addSubview:hostView];',
    'sb frame-apply rejected=inactive-session',
    'sb session-end route-cleared',
    '0.24 * NSEC_PER_SEC'
)) {
    Require-Text $Source $Marker
}

# NathanLR/ElleKit loads UIKit adapters through the UIKit bundle filter. A
# Classes=UIApplication filter was the 0.8.30 regression and must not return.
Require-Text $KeyboardFilter '<key>Bundles</key>'
Require-Text $KeyboardFilter '<string>com.apple.UIKit</string>'
Reject-Text $KeyboardFilter '<key>Classes</key>'

# The app/extension module is a narrow geometry adapter. It may end an old
# responder only when the centered Scene generation changes; it must not hook
# keyboard hide notifications, mutate safe areas, or synthesize notifications.
foreach ($Marker in @(
    'This module is deliberately a narrow UIKit geometry adapter',
    '%hook UITextEffectsWindow',
    'keyboardScreenReferenceSize',
    '%group FLMRemoteKeyboardGeometry',
    'intersectionHeightForWindowScene:',
    'FLMSceneMatchesKeyboardRoute',
    'FLMKeyboardTargetApplication',
    'FLMKeyboardExtensionProcess',
    '@"keyboard-service"',
    'FLMReloadKeyboardCardGeometry',
    'FLMExternalKeyboardAvoidanceGeneration',
    'FLMEndPreviousApplicationKeyboardSession',
    'sendAction:@selector(resignFirstResponder)',
    'FLMDiagnosticEventIntersection'
)) {
    Require-Text $KeyboardSource $Marker
}

foreach ($Removed in @(
    '%hook UIResponder',
    '%hook NSNotificationCenter',
    'UIKeyboardWillHideNotification',
    'UIKeyboardDidHideNotification',
    'FLYME_KEYBOARD_FRAME_NOTIFICATION',
    'FLYME_KEYBOARD_ROUTE_ACK_NOTIFICATION',
    'FLYME_KEYBOARD_DISMISS_NOTIFICATION',
    'FLYME_KEYBOARD_DISMISS_ACK_NOTIFICATION',
    'additionalSafeAreaInsets',
    'FLMApplyApplicationKeyboardSafeArea',
    'FLMCorrectKeyboardNotificationUserInfo',
    'applyFloatingKeyboardContainerOffsetForFrame:',
    '%hook UIWindowScene',
    '%hook UIKeyboardWindow',
    '%hook UIRemoteKeyboardWindow'
)) {
    Reject-Text $KeyboardSource $Removed
}

foreach ($Removed in @(
    'FLYME_KEYBOARD_FRAME_NOTIFICATION',
    'FLYME_KEYBOARD_ROUTE_ACK_NOTIFICATION',
    'FLYME_KEYBOARD_DISMISS_NOTIFICATION',
    'FLYME_KEYBOARD_DISMISS_ACK_NOTIFICATION',
    'FLMRequestApplicationKeyboardDismiss',
    'floatingKeyboardRouteReadyGeneration',
    'finalizeFloatingKeyboardSessionEnd:',
    'route-not-ready',
    'consumeOutsideTapForKeyboardDismissal',
    'applyFloatingKeyboardContainerOffsetForFrame:',
    'floatingKeyboardContainerOffsetY',
    'setFloatingSceneUsesFullscreenKeyboardHost'
)) {
    Reject-Text $Source $Removed
}

Require-Text $LifecycleSource 'FLMClearProtectedScene(self);'
Write-Output 'scene lifecycle and SpringBoard-owned keyboard architecture verified'
