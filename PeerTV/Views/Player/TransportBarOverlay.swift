import UIKit
import AVFoundation
import AVKit
import MediaPlayer

// MARK: - Configuration

/// When `true`, hides AVKit's system playback chrome so the overlay is the only focusable surface
/// and AVKit does not consume remote input before it reaches us.
enum TransportBarConfiguration {
    static var requiresHidingAllSystemPlaybackControls: Bool = true
}

private enum TransportBarMetrics {
    static let trackHeight: CGFloat = 11
    static let focusedTrackHeight: CGFloat = 16
    static let playheadSize: CGFloat = 18
    static let trackHitHeight: CGFloat = 40
    static let sideInset: CGFloat = 80
    static let bottomInset: CGFloat = 110
    static let labelSpacing: CGFloat = 16
    static let buttonRowSpacing: CGFloat = 14
    static let titleSpacing: CGFloat = 12
    static let autoHideDelay: TimeInterval = 5
    static let skipSeconds: Double = 10
    /// Press duration that separates a "tap" (skip) from a "hold" (enter skim mode).
    static let holdBeforeSkim: TimeInterval = 0.5
    /// Press duration that qualifies a touchpad click (`.select`) as a "hold" (toggles
    /// between 2x and 1x playback rate) vs. a short tap (regular action — toggle play/pause,
    /// exit skim, or commit a visual scrub).
    static let holdBeforeSpeedToggle: TimeInterval = 1.0
    /// How long a finger must rest on the Siri Remote touchpad (without enough movement to
    /// become a scrub pan or tap) before the temporary 2x boost kicks in. Lifting the finger
    /// ends the boost and restores the previous rate.
    static let touchHoldMinimumDuration: TimeInterval = 0.5
    /// Skim ticks per second — a step-seek is performed every `skimTickInterval` seconds.
    static let skimTickInterval: TimeInterval = 0.25
    /// Per-tick jump (seconds) for skim stages 1…4. Effective speed = value / skimTickInterval.
    /// These land at roughly ~4x, ~12x, ~30x, ~80x of real time.
    static let skimStageJumps: [Double] = [1, 3, 7.5, 20]
    /// Visual-scrub pan sensitivity. A full track-width swipe maps to `panSensitivity × duration`
    /// (was 1.0 = full-duration; 0.7 feels more natural for making smaller adjustments).
    static let panSensitivity: Double = 0.7
    // Thumbnail preview sizing (16:9 frame). Rendered in `ThumbnailPreviewView` above the cursor.
    static let thumbnailWidth: CGFloat = 400
    static let thumbnailHeight: CGFloat = 225
    /// Vertical gap between the thumbnail popover and the top of the scrubber track.
    static let thumbnailGap: CGFloat = 44
}

// MARK: - Focusable scrubber

/// Full-width scrubber: focusable, handles its own arrow press began/ended / select via `pressesBegan`
/// and `pressesEnded`, and horizontal touchpad swipes via a pan gesture. When focused, the track
/// grows and the playhead dot appears — same idea as Apple's native scrubber. Vertical swipes are
/// intentionally ignored by the pan gesture so the focus engine can route them to the buttons above.
final class FocusableTrackControl: UIControl, UIGestureRecognizerDelegate {

    // Visuals
    private let trackContainer = UIView()
    private let bufferedFillView = UIView()
    private let playedFillView = UIView()
    private let playheadDot = UIView()

    private var bufferedWidthConstraint: NSLayoutConstraint!
    private var playedWidthConstraint: NSLayoutConstraint!
    private var trackHeightConstraint: NSLayoutConstraint!
    /// Most recent chrome alpha (track / labels / buttons fade). `didUpdateFocus` multiplies the
    /// playhead dot's focus-driven alpha by this so the dot doesn't pop back in while the bar is
    /// hidden (e.g. after a Speed menu dismissal re-focuses the scrubber over a hidden track).
    private var currentChromeAlpha: CGFloat = 1

    // Callbacks
    /// `direction` is -1 for left / +1 for right.
    var onArrowPressBegan: ((Int) -> Void)?
    var onArrowPressEnded: ((Int) -> Void)?
    /// Physical touchpad click (`.select`) begins. Split into began/ended (with matching
    /// `onSelectPressEnded` / `onSelectPressCancelled`) so the overlay can distinguish a
    /// short tap (toggle play/pause, exit skim, commit scrub) from a hold (toggle 2x / 1x
    /// playback rate). Unlike the `.playPause` hardware button, `.select` has no parallel
    /// AVKit / `MPRemoteCommandCenter` path, so tap-vs-hold detection on this press is
    /// reliable.
    var onSelectPressBegan: (() -> Void)?
    var onSelectPressEnded: (() -> Void)?
    var onSelectPressCancelled: (() -> Void)?
    var onPanChanged: ((CGFloat) -> Void)?
    var onPanEnded: ((CGFloat) -> Void)?
    var onActivity: (() -> Void)?
    /// Fired when a light, stationary touch on the Siri Remote touchpad (indirect `UITouch`,
    /// **not** a physical `.select` click) has been held for at least
    /// `touchHoldMinimumDuration`. Used to temporarily boost playback to 2x while the finger
    /// stays on the pad. `onTouchHoldEnded` fires on release or cancellation.
    var onTouchHoldBegan: (() -> Void)?
    var onTouchHoldEnded: (() -> Void)?
    // Menu / Back is intentionally *not* handled on the scrubber — the container VC is the
    // single authority for cancelling visual scrub vs. dismissing the player. Handling it here
    // too caused a race: two parallel menu paths would both fire, and whichever saw
    // `pendingScrubCommit == false` (because the other just cleared it) would dismiss.

    // Model
    var duration: TimeInterval = 0 { didSet { updateFill() } }
    var currentTime: TimeInterval = 0 { didSet { if !isScrubbing { updateFill() } } }
    var bufferedTime: TimeInterval = 0 { didSet { updateFill() } }
    var scrubPreviewTime: TimeInterval? { didSet { updateFill() } }
    var isScrubbing: Bool = false { didSet { updateFill() } }

    override var canBecomeFocused: Bool { isUserInteractionEnabled && isEnabled }

    /// Fades the scrubber's visible parts while keeping the UIControl itself at `alpha = 1`
    /// so the focus engine keeps routing remote input here even when the bar is "hidden".
    func setChromeAlpha(_ alpha: CGFloat) {
        currentChromeAlpha = alpha
        trackContainer.alpha = alpha
        playheadDot.alpha = isFocused ? alpha : 0
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private func setup() {
        isUserInteractionEnabled = true
        clipsToBounds = false
        backgroundColor = .clear

        trackContainer.translatesAutoresizingMaskIntoConstraints = false
        trackContainer.backgroundColor = UIColor.white.withAlphaComponent(0.28)
        trackContainer.layer.cornerRadius = TransportBarMetrics.trackHeight / 2
        trackContainer.clipsToBounds = true
        addSubview(trackContainer)

        bufferedFillView.translatesAutoresizingMaskIntoConstraints = false
        bufferedFillView.backgroundColor = UIColor.white.withAlphaComponent(0.5)
        trackContainer.addSubview(bufferedFillView)

        playedFillView.translatesAutoresizingMaskIntoConstraints = false
        playedFillView.backgroundColor = .white
        trackContainer.addSubview(playedFillView)

        playheadDot.translatesAutoresizingMaskIntoConstraints = false
        playheadDot.backgroundColor = .white
        playheadDot.layer.cornerRadius = TransportBarMetrics.playheadSize / 2
        playheadDot.layer.borderWidth = 1
        playheadDot.layer.borderColor = UIColor.black.withAlphaComponent(0.3).cgColor
        playheadDot.alpha = 0
        playheadDot.isUserInteractionEnabled = false
        addSubview(playheadDot)

        trackHeightConstraint = trackContainer.heightAnchor.constraint(equalToConstant: TransportBarMetrics.trackHeight)
        bufferedWidthConstraint = bufferedFillView.widthAnchor.constraint(equalToConstant: 0)
        playedWidthConstraint = playedFillView.widthAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            trackContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            trackContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            trackContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            trackHeightConstraint,

            bufferedFillView.leadingAnchor.constraint(equalTo: trackContainer.leadingAnchor),
            bufferedFillView.topAnchor.constraint(equalTo: trackContainer.topAnchor),
            bufferedFillView.bottomAnchor.constraint(equalTo: trackContainer.bottomAnchor),
            bufferedWidthConstraint,

            playedFillView.leadingAnchor.constraint(equalTo: trackContainer.leadingAnchor),
            playedFillView.topAnchor.constraint(equalTo: trackContainer.topAnchor),
            playedFillView.bottomAnchor.constraint(equalTo: trackContainer.bottomAnchor),
            playedWidthConstraint,

            playheadDot.widthAnchor.constraint(equalToConstant: TransportBarMetrics.playheadSize),
            playheadDot.heightAnchor.constraint(equalToConstant: TransportBarMetrics.playheadSize),
            playheadDot.centerYAnchor.constraint(equalTo: trackContainer.centerYAnchor),
            playheadDot.centerXAnchor.constraint(equalTo: playedFillView.trailingAnchor)
        ])

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.cancelsTouchesInView = false
        pan.delegate = self
        addGestureRecognizer(pan)

        // A light tap on the Siri Remote touchpad arrives as an indirect `UITouch`, not a
        // `.select` press (which is a physical click). Listen for it explicitly so the user can
        // wake the bar by just brushing the touchpad, mirroring the native player.
        let wakeTap = UITapGestureRecognizer(target: self, action: #selector(handleWakeTap(_:)))
        wakeTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        wakeTap.cancelsTouchesInView = false
        addGestureRecognizer(wakeTap)

        // Touch-hold detection uses `touchesBegan` / `touchesEnded` directly (see overrides
        // below). `UILongPressGestureRecognizer` was tried first but is press-driven on tvOS
        // by default (`allowedPressTypes` = `[.select]`), so light touchpad touches alone
        // don't reliably start it. The direct `UITouch` path is the documented route for
        // Siri Remote indirect touches and is what powers `wakeTap` above as well.
    }

    /// Only recognize the pan gesture when the motion is primarily horizontal; that way vertical
    /// swipes flow to the focus engine and can move focus up to the Quality / Speed buttons.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let v = pan.velocity(in: self)
        return abs(v.x) > abs(v.y)
    }

    // MARK: - Touch-hold (temporary 2x boost)

    /// Fires after a finger has rested on the touchpad for `touchHoldMinimumDuration`. Set in
    /// `touchesBegan` and cleared in `touchesEnded` / `touchesCancelled`.
    private var touchHoldWorkItem: DispatchWorkItem?
    /// `true` once `touchHoldWorkItem` has actually fired and `onTouchHoldBegan` has been
    /// called. Gates the matching `onTouchHoldEnded` on finger-lift so we don't fire a phantom
    /// "end" for short taps that never hit the threshold.
    private var touchHoldDidFire: Bool = false
    /// `true` while the user is actively pressing the touchpad click (`.select`). The click
    /// rests on the same finger that's also producing indirect `UITouch`es, so without this
    /// gate the 0.5s touch-hold boost would fire halfway into a 1.0s click-and-hold (which
    /// is the speed-toggle gesture), causing the player to briefly run at 2x and then revert
    /// the moment the click is released — even if the user only intended to toggle speed.
    /// While set, we suppress new touch-hold timers and tear down any active boost.
    private var isSelectPressed: Bool = false

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        guard touches.contains(where: { $0.type == .indirect }) else { return }
        // While the touchpad click is held the user is doing a click-hold gesture, not a
        // light-touch gesture; don't arm the boost.
        guard !isSelectPressed else { return }
        scheduleTouchHold()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        guard touches.contains(where: { $0.type == .indirect }) else { return }
        finishTouchHold()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        guard touches.contains(where: { $0.type == .indirect }) else { return }
        finishTouchHold()
    }

    private func scheduleTouchHold() {
        touchHoldWorkItem?.cancel()
        touchHoldDidFire = false
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.touchHoldDidFire = true
            self.onTouchHoldBegan?()
        }
        touchHoldWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + TransportBarMetrics.touchHoldMinimumDuration,
            execute: work
        )
    }

    private func finishTouchHold() {
        touchHoldWorkItem?.cancel()
        touchHoldWorkItem = nil
        if touchHoldDidFire {
            touchHoldDidFire = false
            onTouchHoldEnded?()
        }
    }

    /// Called from `pressesBegan` when a `.select` click goes down. Tears down any active or
    /// pending touch-hold so the click-and-hold gesture (speed toggle) can run unobstructed.
    /// If a boost was already active, `onTouchHoldEnded` fires here so the player rate
    /// reverts cleanly *before* the speed toggle eventually applies.
    private func suppressTouchHoldForSelectPress() {
        isSelectPressed = true
        finishTouchHold()
    }

    private func releaseTouchHoldSuppression() {
        isSelectPressed = false
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateFill()
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        // When focus arrives at the scrubber from elsewhere (typically the Quality / Speed
        // buttons), reset the auto-hide timer so the user gets the full delay window instead of
        // whatever fragment was left over from the previous schedule.
        if focused && context.previouslyFocusedView !== self {
            onActivity?()
        }
        coordinator.addCoordinatedAnimations { [weak self] in
            guard let self else { return }
            let h = focused ? TransportBarMetrics.focusedTrackHeight : TransportBarMetrics.trackHeight
            self.trackHeightConstraint.constant = h
            self.trackContainer.layer.cornerRadius = h / 2
            // Respect the chrome's current fade so the dot never ghosts above a hidden track.
            self.playheadDot.alpha = focused ? self.currentChromeAlpha : 0
            self.layoutIfNeeded()
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            switch press.type {
            case .leftArrow:
                onArrowPressBegan?(-1)
                handled = true
            case .rightArrow:
                onArrowPressBegan?(1)
                handled = true
            case .select:
                suppressTouchHoldForSelectPress()
                onSelectPressBegan?()
                handled = true
            case .upArrow, .downArrow:
                // Wake the bar; fall through so the focus engine can navigate vertically.
                onActivity?()
            default:
                break
            }
        }
        if !handled {
            super.pressesBegan(presses, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            switch press.type {
            case .leftArrow:
                onArrowPressEnded?(-1)
                handled = true
            case .rightArrow:
                onArrowPressEnded?(1)
                handled = true
            case .select:
                releaseTouchHoldSuppression()
                onSelectPressEnded?()
                handled = true
            default:
                break
            }
        }
        if !handled {
            super.pressesEnded(presses, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Treat cancellation the same as end so scan doesn't get stuck.
        for press in presses {
            switch press.type {
            case .leftArrow: onArrowPressEnded?(-1)
            case .rightArrow: onArrowPressEnded?(1)
            case .select:
                releaseTouchHoldSuppression()
                onSelectPressCancelled?()
            default: break
            }
        }
        super.pressesCancelled(presses, with: event)
    }

    @objc private func handleWakeTap(_ gr: UITapGestureRecognizer) {
        onActivity?()
    }

    @objc private func handlePan(_ gr: UIPanGestureRecognizer) {
        let tx = gr.translation(in: self).x
        switch gr.state {
        case .began:
            onActivity?()
        case .changed:
            onActivity?()
            onPanChanged?(tx)
        case .ended, .cancelled, .failed:
            onActivity?()
            onPanEnded?(tx)
        default:
            break
        }
    }

    private func updateFill() {
        let d = duration
        guard d.isFinite, d > 0 else {
            bufferedWidthConstraint.constant = 0
            playedWidthConstraint.constant = 0
            return
        }
        let trackW = trackContainer.bounds.width
        guard trackW > 0 else { return }
        let effectiveCurrent = (isScrubbing ? (scrubPreviewTime ?? currentTime) : currentTime)
        let buf = min(1, max(0, bufferedTime / d))
        let played = min(1, max(0, effectiveCurrent / d))
        bufferedWidthConstraint.constant = trackW * CGFloat(buf)
        playedWidthConstraint.constant = trackW * CGFloat(played)
    }
}

// MARK: - Overlay layout

/// Visual layout only. No observers.
final class TransportBarOverlayView: UIView {

    let trackControl = FocusableTrackControl()
    let titleLabel = UILabel()
    let qualityButton: UIButton
    let skipNextButton: UIButton
    let speedButton: UIButton
    let captionsButton: UIButton
    let currentTimeLabel = UILabel()
    let remainingTimeLabel = UILabel()
    /// Small icon next to the elapsed-time label showing play/pause state or skim direction + stage.
    let stateIndicator = StateIndicatorView()
    /// Floating thumbnail popover shown above the cursor during skim or visual-scrub preview.
    let thumbnailPreview = ThumbnailPreviewView()
    private var thumbnailXConstraint: NSLayoutConstraint!
    private let scrim = GradientView()
    private let buttonStack = UIStackView()

    /// Shown only when playing from a playlist with another item after the current one.
    var showsSkipNextButton: Bool = false {
        didSet { skipNextButton.isHidden = !showsSkipNextButton }
    }

    var showsQualityButton: Bool = true {
        didSet { qualityButton.isHidden = !showsQualityButton }
    }

    /// Shown when the video has at least one caption track (PeerTube).
    var showsCaptionsButton: Bool = false {
        didSet { captionsButton.isHidden = !showsCaptionsButton }
    }

    /// Fades the visible chrome (scrim / title / buttons / time labels / track fill) but keeps the
    /// scrubber UIControl itself at `alpha = 1` so the focus engine continues to route remote input
    /// to it while the bar is "hidden". First press while hidden wakes the bar; second press acts.
    func setChromeAlpha(_ alpha: CGFloat) {
        scrim.alpha = alpha
        titleLabel.alpha = alpha
        buttonStack.alpha = alpha
        currentTimeLabel.alpha = alpha
        remainingTimeLabel.alpha = alpha
        stateIndicator.alpha = alpha
        thumbnailPreview.alpha = alpha
        trackControl.setChromeAlpha(alpha)
    }

    /// Positions the thumbnail popover so its centerX tracks the cursor position on the scrubber,
    /// clamped to the track's bounds so the popover doesn't overflow the screen edges.
    func positionThumbnail(atTime time: TimeInterval, duration: TimeInterval) {
        guard duration.isFinite, duration > 0 else { return }
        let trackW = trackControl.bounds.width
        guard trackW > 0 else { return }
        let ratio = CGFloat(min(max(0, time / duration), 1))
        let halfW = TransportBarMetrics.thumbnailWidth / 2
        let rawX = trackW * ratio
        let clamped = min(max(halfW, rawX), trackW - halfW)
        thumbnailXConstraint.constant = clamped
    }

    override init(frame: CGRect) {
        self.qualityButton = Self.makeIconButton(symbol: "sparkles.tv")
        self.skipNextButton = Self.makeIconButton(symbol: "forward.end.fill")
        self.speedButton = Self.makeIconButton(symbol: "gauge.with.dots.needle.67percent")
        self.captionsButton = Self.makeIconButton(symbol: "captions.bubble")
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private static func makeIconButton(symbol: String) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 32, weight: .semibold)
        )
        config.baseForegroundColor = .white
        config.contentInsets = NSDirectionalEdgeInsets(top: 18, leading: 22, bottom: 18, trailing: 22)
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    private func setup() {
        backgroundColor = .clear

        // Subtle gradient scrim so text + track read over bright scenes.
        scrim.translatesAutoresizingMaskIntoConstraints = false
        scrim.isUserInteractionEnabled = false
        addSubview(scrim)
        NSLayoutConstraint.activate([
            scrim.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrim.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrim.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrim.heightAnchor.constraint(equalToConstant: 360)
        ])

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 30, weight: .semibold).rounded()
        titleLabel.textAlignment = .left
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.numberOfLines = 1
        titleLabel.shadowColor = UIColor.black.withAlphaComponent(0.35)
        titleLabel.shadowOffset = CGSize(width: 0, height: 1)

        buttonStack.addArrangedSubview(qualityButton)
        buttonStack.addArrangedSubview(skipNextButton)
        buttonStack.addArrangedSubview(speedButton)
        buttonStack.addArrangedSubview(captionsButton)
        skipNextButton.isHidden = true
        skipNextButton.accessibilityLabel = "Play next in playlist"
        captionsButton.isHidden = true
        captionsButton.accessibilityLabel = "Captions"
        buttonStack.axis = .horizontal
        buttonStack.spacing = TransportBarMetrics.buttonRowSpacing
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        trackControl.translatesAutoresizingMaskIntoConstraints = false

        let labelFont = UIFont.monospacedDigitSystemFont(ofSize: 24, weight: .medium)
        currentTimeLabel.translatesAutoresizingMaskIntoConstraints = false
        currentTimeLabel.textColor = .white
        currentTimeLabel.font = labelFont
        currentTimeLabel.textAlignment = .left
        currentTimeLabel.text = "0:00"

        remainingTimeLabel.translatesAutoresizingMaskIntoConstraints = false
        remainingTimeLabel.textColor = .white
        remainingTimeLabel.font = labelFont
        remainingTimeLabel.textAlignment = .right
        remainingTimeLabel.text = "--:--"

        stateIndicator.translatesAutoresizingMaskIntoConstraints = false
        // Hidden until we have a valid duration; prevents the play-icon showing before the
        // elapsed-time label has been populated on initial load / playlist transitions.
        stateIndicator.isHidden = true

        thumbnailPreview.translatesAutoresizingMaskIntoConstraints = false
        thumbnailPreview.isHidden = true

        addSubview(titleLabel)
        addSubview(buttonStack)
        addSubview(trackControl)
        addSubview(currentTimeLabel)
        addSubview(stateIndicator)
        addSubview(remainingTimeLabel)
        addSubview(thumbnailPreview)

        NSLayoutConstraint.activate([
            // Track: full width, anchored near bottom
            trackControl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: TransportBarMetrics.sideInset),
            trackControl.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -TransportBarMetrics.sideInset),
            trackControl.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -TransportBarMetrics.bottomInset),
            trackControl.heightAnchor.constraint(equalToConstant: TransportBarMetrics.trackHitHeight),

            // Buttons: above track, trailing-aligned
            buttonStack.trailingAnchor.constraint(equalTo: trackControl.trailingAnchor),
            buttonStack.bottomAnchor.constraint(equalTo: trackControl.topAnchor, constant: -TransportBarMetrics.titleSpacing),

            // Title: above track, leading-aligned; shares the top row with the buttons
            titleLabel.leadingAnchor.constraint(equalTo: trackControl.leadingAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: buttonStack.leadingAnchor, constant: -16),
            titleLabel.centerYAnchor.constraint(equalTo: buttonStack.centerYAnchor),

            // Times: under track, leading / trailing
            currentTimeLabel.leadingAnchor.constraint(equalTo: trackControl.leadingAnchor),
            currentTimeLabel.topAnchor.constraint(equalTo: trackControl.bottomAnchor, constant: TransportBarMetrics.labelSpacing),

            // State / skim indicator: right of current time, vertically centered with it.
            stateIndicator.leadingAnchor.constraint(equalTo: currentTimeLabel.trailingAnchor, constant: 12),
            stateIndicator.centerYAnchor.constraint(equalTo: currentTimeLabel.centerYAnchor),

            remainingTimeLabel.trailingAnchor.constraint(equalTo: trackControl.trailingAnchor),
            remainingTimeLabel.topAnchor.constraint(equalTo: trackControl.bottomAnchor, constant: TransportBarMetrics.labelSpacing)
        ])

        // Thumbnail centered above the cursor. `thumbnailXConstraint.constant` is updated to follow
        // the cursor's x-position; thumbnail y is fixed relative to the track.
        thumbnailXConstraint = thumbnailPreview.centerXAnchor.constraint(equalTo: trackControl.leadingAnchor, constant: TransportBarMetrics.thumbnailWidth / 2)
        NSLayoutConstraint.activate([
            thumbnailXConstraint,
            thumbnailPreview.bottomAnchor.constraint(equalTo: trackControl.topAnchor, constant: -TransportBarMetrics.thumbnailGap),
            thumbnailPreview.widthAnchor.constraint(equalToConstant: TransportBarMetrics.thumbnailWidth),
            thumbnailPreview.heightAnchor.constraint(equalToConstant: TransportBarMetrics.thumbnailHeight)
        ])
    }

    func updateLabels(current: TimeInterval, duration: TimeInterval) {
        currentTimeLabel.text = Self.fmt(current)
        if duration.isFinite, duration > 0 {
            remainingTimeLabel.text = "-" + Self.fmt(max(0, duration - current))
        } else {
            remainingTimeLabel.text = "--:--"
        }
    }

    private static func fmt(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

/// Floating thumbnail popover shown above the scrubber cursor during skim / visual scrub.
/// Gives the user visual context even when the target position isn't buffered yet, so the
/// video image underneath doesn't appear to "jump back" when the seek finally commits.
final class ThumbnailPreviewView: UIView {

    private let imageView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private func setup() {
        backgroundColor = .clear
        layer.masksToBounds = false
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.5
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: 6)
        isUserInteractionEnabled = false

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFill
        imageView.backgroundColor = UIColor.black.withAlphaComponent(0.85)
        imageView.layer.cornerRadius = 12
        imageView.layer.masksToBounds = true
        imageView.layer.borderWidth = 2
        imageView.layer.borderColor = UIColor.white.withAlphaComponent(0.9).cgColor
        addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            imageView.widthAnchor.constraint(equalToConstant: TransportBarMetrics.thumbnailWidth),
            imageView.heightAnchor.constraint(equalToConstant: TransportBarMetrics.thumbnailHeight)
        ])
    }

    func setImage(_ image: UIImage?) {
        imageView.image = image
    }

    func clear() {
        imageView.image = nil
    }
}

/// Small icon shown next to the elapsed-time label: a play / pause icon when the video is
/// in normal playback, or a fast-forward / rewind icon with stage chevrons during skim mode.
final class StateIndicatorView: UIView {

    enum State: Equatable {
        case playing
        case paused
        case skimForward(stage: Int)
        case skimBackward(stage: Int)
    }

    private let iconView = UIImageView()
    private let chevronsLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private func setup() {
        backgroundColor = .clear
        isUserInteractionEnabled = false

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.tintColor = .white
        iconView.contentMode = .scaleAspectFit
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)

        chevronsLabel.translatesAutoresizingMaskIntoConstraints = false
        chevronsLabel.textColor = .white
        chevronsLabel.font = .systemFont(ofSize: 22, weight: .semibold)

        addSubview(iconView)
        addSubview(chevronsLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconView.topAnchor.constraint(equalTo: topAnchor),
            iconView.bottomAnchor.constraint(equalTo: bottomAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 26),

            chevronsLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4),
            chevronsLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            chevronsLabel.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])

        update(.playing)
    }

    func update(_ state: State) {
        switch state {
        case .playing:
            iconView.image = UIImage(systemName: "play.fill")
            chevronsLabel.text = nil
        case .paused:
            iconView.image = UIImage(systemName: "pause.fill")
            chevronsLabel.text = nil
        case .skimForward(let stage):
            iconView.image = UIImage(systemName: "forward.fill")
            chevronsLabel.text = String(repeating: "›", count: max(1, stage))
        case .skimBackward(let stage):
            iconView.image = UIImage(systemName: "backward.fill")
            chevronsLabel.text = String(repeating: "‹", count: max(1, stage))
        }
    }
}

private final class GradientView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    override init(frame: CGRect) {
        super.init(frame: frame)
        let layer = self.layer as! CAGradientLayer
        layer.colors = [
            UIColor.black.withAlphaComponent(0).cgColor,
            UIColor.black.withAlphaComponent(0.55).cgColor
        ]
        layer.locations = [0, 1]
        layer.startPoint = CGPoint(x: 0.5, y: 0)
        layer.endPoint = CGPoint(x: 0.5, y: 1)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }
}

private extension UIFont {
    func rounded() -> UIFont {
        guard let desc = fontDescriptor.withDesign(.rounded) else { return self }
        return UIFont(descriptor: desc, size: pointSize)
    }
}

// MARK: - Speed-change notification

/// Small top-right pill shown briefly when the Play/Pause hold gesture toggles the playback
/// rate between 1x and 2x. Lives on the root view (not inside `TransportBarOverlayView`) so
/// it's not affected by the bar's auto-hide chrome fade — the user gets explicit feedback
/// even when the transport bar itself is hidden.
final class SpeedNotificationView: UIView {
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private func setup() {
        backgroundColor = UIColor.black.withAlphaComponent(0.75)
        layer.cornerRadius = 12
        clipsToBounds = true
        isUserInteractionEnabled = false

        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = .white
        label.font = .systemFont(ofSize: 28, weight: .semibold).rounded()
        label.textAlignment = .center
        addSubview(label)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22)
        ])
    }

    func setText(_ text: String) {
        label.text = text
    }
}

// MARK: - Root host

/// Hosts the bar. The scrubber is always focusable (its UIControl alpha stays at 1); only the
/// visible chrome fades. That keeps the focus engine routing remote input to the scrubber even
/// while the bar is "hidden", so any directional press, select, or touchpad motion wakes it.
final class TransportBarRootView: UIView {
    let barView: TransportBarOverlayView

    private(set) var isBarVisible: Bool = true

    /// Fired whenever `setBarVisible` runs so the caption overlay can match transport chrome.
    var onBarVisibilityChanged: ((Bool) -> Void)?

    /// Top-right speed-change indicator. Shown for `speedNotificationVisibleDuration` when the
    /// Play/Pause hold gesture flips between 2x and 1x.
    private let speedNotificationView = SpeedNotificationView()
    private var speedNotificationHideWorkItem: DispatchWorkItem?
    private static let speedNotificationFadeIn: TimeInterval = 0.2
    private static let speedNotificationFadeOut: TimeInterval = 0.3
    /// Total on-screen time for a speed-change pill, from start of fade-in to end of fade-out.
    private static let speedNotificationVisibleDuration: TimeInterval = 2.5

    override init(frame: CGRect) {
        barView = TransportBarOverlayView()
        super.init(frame: frame)
        backgroundColor = .clear

        addSubview(barView)
        barView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            barView.topAnchor.constraint(equalTo: topAnchor),
            barView.bottomAnchor.constraint(equalTo: bottomAnchor),
            barView.leadingAnchor.constraint(equalTo: leadingAnchor),
            barView.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])

        speedNotificationView.translatesAutoresizingMaskIntoConstraints = false
        speedNotificationView.alpha = 0
        addSubview(speedNotificationView)
        NSLayoutConstraint.activate([
            speedNotificationView.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 60),
            speedNotificationView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -80)
        ])

        setBarVisible(true, animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func setBarVisible(_ visible: Bool, animated: Bool, completion: (() -> Void)? = nil) {
        isBarVisible = visible
        onBarVisibilityChanged?(visible)
        let target: CGFloat = visible ? 1 : 0
        if animated {
            UIView.animate(withDuration: 0.25, animations: { [weak self] in
                self?.barView.setChromeAlpha(target)
            }, completion: { _ in completion?() })
        } else {
            barView.setChromeAlpha(target)
            completion?()
        }
    }

    /// Shows the speed-change pill with `text` (e.g. "2x", "1x"). Re-invoking during the
    /// visible window restarts the timer so rapid toggles extend rather than cut short.
    func showSpeedNotification(_ text: String) {
        speedNotificationView.setText(text)
        speedNotificationHideWorkItem?.cancel()

        UIView.animate(withDuration: Self.speedNotificationFadeIn) { [weak self] in
            self?.speedNotificationView.alpha = 1
        }

        let work = DispatchWorkItem { [weak self] in
            UIView.animate(withDuration: Self.speedNotificationFadeOut) {
                self?.speedNotificationView.alpha = 0
            }
        }
        speedNotificationHideWorkItem = work
        // Schedule the fade-out so its *completion* lands at `visibleDuration` — that gives
        // the user the full two-second window they asked for (fade-in → hold → fade-out = 2s).
        let stay = Self.speedNotificationVisibleDuration - Self.speedNotificationFadeOut
        DispatchQueue.main.asyncAfter(deadline: .now() + stay, execute: work)
    }

    /// Hides the pill immediately (no animation). Called during teardown so a stale pending
    /// fade doesn't touch a detached view.
    func cancelSpeedNotification() {
        speedNotificationHideWorkItem?.cancel()
        speedNotificationHideWorkItem = nil
        speedNotificationView.alpha = 0
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        [barView.trackControl]
    }
}

// MARK: - Controller

final class TransportBarController: NSObject {

    /// Created synchronously in `init` so the host container (PlayerContainerViewController)
    /// can install it as a sibling of AVPlayerViewController.view *before* presentation —
    /// which is required for the focus engine to route input here.
    let rootView: TransportBarRootView = TransportBarRootView()

    private weak var player: AVPlayer?

    private var periodicToken: Any?
    private var timeControlObservation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    private var durationObservation: NSKeyValueObservation?
    private var loadedRangesObservation: NSKeyValueObservation?

    private var hideWorkItem: DispatchWorkItem?
    /// Anchor time for the in-progress visual-scrub pan session. Set at the start of the first pan
    /// (to the player's current time) and advanced at the end of every pan gesture to the final
    /// target, so subsequent pans compose on top instead of snapping back to the original anchor.
    private var panAnchorTime: TimeInterval = 0
    private var registeredRemoteCommandTargets = false

    // Skim-mode state (press-and-hold arrow enters skim; subsequent arrow taps adjust stage /
    // direction; Play/Pause exits). The player is *paused* while skimming, and we step-seek
    // through the timeline each tick rather than using `player.rate`.
    private enum SkimPhase {
        case idle
        case pressed(direction: Int, began: Date)
        case skimming(direction: Int, stage: Int)
    }
    private var skimPhase: SkimPhase = .idle
    private var skimHoldWorkItem: DispatchWorkItem?
    private var skimTimer: Timer?
    /// Whether the video was playing when skim mode was entered, so we resume correctly on exit.
    private var wasPlayingBeforeSkim: Bool = true
    /// Controller-tracked skim target. Driven directly by `performSkimTick` so we keep advancing
    /// even when the player's `currentTime` is still catching up (which happens when the target is
    /// past the currently-buffered range on HLS — otherwise the bar "sticks" at the buffered edge).
    private var skimTargetTime: TimeInterval = 0

    // Visual scrub (pan while paused) — the cursor moves but the player doesn't seek until the
    // user presses Play/Pause. `pendingScrubCommit` is true once the pan ends while paused and
    // stays true until `selectTapAction` commits the seek.
    private var pendingScrubCommit: Bool = false

    // Thumbnail preview generator / cache
    private var thumbnailGenerator: AVAssetImageGenerator?
    private var thumbnailCache: [Int: UIImage] = [:]
    private var thumbnailRequestWork: DispatchWorkItem?
    private static let thumbnailDebounce: TimeInterval = 0.12
    /// Server-side sprite-sheet thumbnail source (PeerTube storyboards). When set, it's consulted
    /// before the `AVAssetImageGenerator` fallback — which does not work well on HLS past the
    /// currently-buffered range.
    var storyboardProvider: StoryboardThumbnailProvider?

    /// Fired on the main queue from the periodic time observer with the timeline time used for UI
    /// (scrub/skim preview when active, otherwise the player's current time).
    var onTimeUpdate: ((TimeInterval) -> Void)?

    private let onQualityTapped: () -> Void
    private let onSpeedTapped: () -> Void
    private let onCaptionsTapped: (() -> Void)?
    private let onSkipNextTapped: (() -> Void)?
    /// Invoked when the touchpad click (`.select`) is held past `holdBeforeSpeedToggle`.
    /// The coordinator owns `currentSpeed` (so it can reapply on resolution swaps), so the
    /// actual 2x / 1x toggle lives there — this controller just detects the gesture and
    /// calls back. Previously wired to `.playPause`, but that path had parallel AVKit /
    /// MPRemoteCommand handlers toggling play state at button-down which defeated the
    /// tap-vs-hold timing. `.select` has no such parallel path.
    private let onSpeedHold: (() -> Void)?
    /// Invoked when a stationary touch on the Siri Remote touchpad passes
    /// `touchHoldMinimumDuration`. Paired with `onTouchHoldEnded` (fired on finger-lift or
    /// gesture cancellation). Gives the coordinator a chance to apply a temporary 2x boost.
    private let onTouchHoldBegan: (() -> Void)?
    private let onTouchHoldEnded: (() -> Void)?
    private let showsQualityButton: Bool
    private var title: String

    // Touchpad-click hold detection (tap vs. long-press). The timer fires at
    // `holdBeforeSpeedToggle`; if it fires while the user is still holding, the speed-hold
    // callback runs and we remember it so the subsequent release doesn't also trigger the
    // tap action (play/pause toggle / skim exit / scrub commit).
    private var selectHoldWorkItem: DispatchWorkItem?
    private var selectHoldDidFire: Bool = false

    init(
        showsQualityButton: Bool,
        showsSkipNextButton: Bool = false,
        title: String,
        onQualityTapped: @escaping () -> Void,
        onSpeedTapped: @escaping () -> Void,
        onCaptionsTapped: (() -> Void)? = nil,
        onSkipNextTapped: (() -> Void)? = nil,
        onSpeedHold: (() -> Void)? = nil,
        onTouchHoldBegan: (() -> Void)? = nil,
        onTouchHoldEnded: (() -> Void)? = nil
    ) {
        self.showsQualityButton = showsQualityButton
        self.title = title
        self.onQualityTapped = onQualityTapped
        self.onSpeedTapped = onSpeedTapped
        self.onCaptionsTapped = onCaptionsTapped
        self.onSkipNextTapped = onSkipNextTapped
        self.onSpeedHold = onSpeedHold
        self.onTouchHoldBegan = onTouchHoldBegan
        self.onTouchHoldEnded = onTouchHoldEnded
        super.init()

        rootView.barView.showsQualityButton = showsQualityButton
        rootView.barView.showsSkipNextButton = showsSkipNextButton
        rootView.barView.titleLabel.text = title

        rootView.barView.qualityButton.addTarget(self, action: #selector(qualityPressed), for: .primaryActionTriggered)
        rootView.barView.speedButton.addTarget(self, action: #selector(speedPressed), for: .primaryActionTriggered)
        rootView.barView.captionsButton.addTarget(self, action: #selector(captionsPressed), for: .primaryActionTriggered)
        rootView.barView.skipNextButton.addTarget(self, action: #selector(skipNextPressed), for: .primaryActionTriggered)

        rootView.barView.trackControl.onArrowPressBegan = { [weak self] d in self?.handleArrowPressBegan(direction: d) }
        rootView.barView.trackControl.onArrowPressEnded = { [weak self] d in self?.handleArrowPressEnded(direction: d) }
        rootView.barView.trackControl.onSelectPressBegan = { [weak self] in self?.handleSelectPressBegan() }
        rootView.barView.trackControl.onSelectPressEnded = { [weak self] in self?.handleSelectPressEnded() }
        rootView.barView.trackControl.onSelectPressCancelled = { [weak self] in self?.handleSelectPressCancelled() }
        rootView.barView.trackControl.onActivity = { [weak self] in self?.showBarAndResetTimer() }
        rootView.barView.trackControl.onPanChanged = { [weak self] tx in self?.handleScrubberPan(translationX: tx, ended: false) }
        rootView.barView.trackControl.onPanEnded = { [weak self] tx in self?.handleScrubberPan(translationX: tx, ended: true) }
        rootView.barView.trackControl.onTouchHoldBegan = { [weak self] in self?.onTouchHoldBegan?() }
        rootView.barView.trackControl.onTouchHoldEnded = { [weak self] in self?.onTouchHoldEnded?() }
    }

    // Public

    func setTitle(_ newTitle: String) {
        title = newTitle
        rootView.barView.titleLabel.text = newTitle
    }

    func setShowsSkipNext(_ show: Bool) {
        rootView.barView.showsSkipNextButton = show
    }

    func setShowsCaptionsButton(_ show: Bool) {
        rootView.barView.showsCaptionsButton = show
    }

    /// Timestamp of the most recent Menu press this controller consumed. Used to debounce
    /// duplicate calls arriving from parallel paths (e.g. `pressesBegan` vs.
    /// `AVPlayerViewControllerDelegate.playerViewControllerShouldDismiss`), so whichever path
    /// fires second doesn't see a just-cleared `pendingScrubCommit` and dismiss the player.
    private var menuConsumedAt: Date?
    private static let menuConsumeWindow: TimeInterval = 0.3

    /// Returns `true` if a Menu/Back press should be consumed (i.e. NOT dismiss the player).
    /// Called by the container VC's `pressesBegan` and by the AVPlayerViewControllerDelegate's
    /// `playerViewControllerShouldDismiss` — both may fire for the same press on tvOS because
    /// AVKit runs its own internal `.menu` gesture recognizer outside the responder chain.
    func handleMenuPressIfNeeded() -> Bool {
        if pendingScrubCommit {
            cancelVisualScrub()
            menuConsumedAt = Date()
            return true
        }
        // If we just consumed a Menu press via another path, swallow the duplicate so it
        // doesn't trigger dismissal.
        if let at = menuConsumedAt, Date().timeIntervalSince(at) < Self.menuConsumeWindow {
            return true
        }
        return false
    }

    /// Siri Remote hardware Play/Pause button. Fires immediately on press — no hold
    /// detection, because `.playPause` has parallel AVKit / `MPRemoteCommandCenter` paths
    /// that toggle state at button-down which we can't reliably suppress. Hold-for-speed
    /// lives on the touchpad click (`.select`) instead, which has no such parallel path.
    func handlePlayPausePress() {
        playPauseTapAction()
    }

    /// Touchpad click (`.select`) press-down on the scrubber. Starts the hold-detection
    /// timer; past `holdBeforeSpeedToggle` the `onSpeedHold` callback fires (coordinator
    /// toggles between 2x and 1x). A quick release runs the normal tap action via
    /// `handleSelectPressEnded`.
    ///
    /// While skimming or with a staged visual-scrub commit pending, we skip the hold timer
    /// entirely so those modes only respond to the tap — the user can get out of skim /
    /// scrub via a quick click and never accidentally toggle speed.
    func handleSelectPressBegan() {
        selectHoldWorkItem?.cancel()
        selectHoldDidFire = false

        if case .skimming = skimPhase { return }
        if pendingScrubCommit { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.selectHoldDidFire = true
            self.onSpeedHold?()
            self.showBarAndResetTimer()
        }
        selectHoldWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + TransportBarMetrics.holdBeforeSpeedToggle,
            execute: work
        )
    }

    /// Called when the touchpad click is released. Runs the tap action unless the hold
    /// timer already fired — in which case the release is a no-op because the user got
    /// their 2x / 1x toggle and we shouldn't also flip play state.
    func handleSelectPressEnded() {
        selectHoldWorkItem?.cancel()
        selectHoldWorkItem = nil
        if selectHoldDidFire {
            selectHoldDidFire = false
            return
        }
        selectTapAction()
    }

    /// Called when the touchpad click is cancelled by the system (e.g. a menu is presented
    /// on top). Just cancels the hold timer — no tap action, since the user didn't complete
    /// a deliberate press.
    func handleSelectPressCancelled() {
        selectHoldWorkItem?.cancel()
        selectHoldWorkItem = nil
        selectHoldDidFire = false
    }

    /// Shared tap action used by touchpad-click release, the `.playPause` hardware button,
    /// and the MPRemoteCommand handlers. Mirrors what the touchpad Select click does: exit
    /// skim, commit a staged visual scrub, or toggle play/pause.
    private func playPauseTapAction() {
        if case .skimming = skimPhase {
            exitSkim()
            return
        }
        if pendingScrubCommit, let target = rootView.barView.trackControl.scrubPreviewTime {
            commitVisualScrubSeek(to: target)
            return
        }
        togglePlayPause()
    }

    func attach(player: AVPlayer) {
        detach()
        self.player = player
        // Reset visible state so playlist transitions don't briefly show a stale play / pause icon
        // for the previous item before the new item's duration arrives.
        rootView.barView.stateIndicator.isHidden = true
        rootView.barView.updateLabels(current: 0, duration: 0)
        setupThumbnailGenerator(for: player)
        observePlayer(player)
        registerRemoteCommands()
        updateFromPlayer()
        updateIndicator()
        showBarAndResetTimer()
    }

    func detach() {
        unregisterRemoteCommands()
        skimHoldWorkItem?.cancel(); skimHoldWorkItem = nil
        skimTimer?.invalidate(); skimTimer = nil
        skimPhase = .idle
        pendingScrubCommit = false
        selectHoldWorkItem?.cancel(); selectHoldWorkItem = nil
        selectHoldDidFire = false
        thumbnailRequestWork?.cancel(); thumbnailRequestWork = nil
        thumbnailGenerator?.cancelAllCGImageGeneration()
        thumbnailGenerator = nil
        thumbnailCache.removeAll()
        storyboardProvider = nil
        onTimeUpdate = nil
        rootView.barView.thumbnailPreview.isHidden = true
        rootView.barView.thumbnailPreview.clear()
        if let periodicToken, let p = player {
            p.removeTimeObserver(periodicToken)
        }
        periodicToken = nil
        timeControlObservation?.invalidate(); timeControlObservation = nil
        itemObservation?.invalidate(); itemObservation = nil
        durationObservation?.invalidate(); durationObservation = nil
        loadedRangesObservation?.invalidate(); loadedRangesObservation = nil
        player = nil
    }

    func tearDown() {
        detach()
        hideWorkItem?.cancel()
        hideWorkItem = nil
        rootView.cancelSpeedNotification()
        rootView.removeFromSuperview()
    }

    /// Shows a brief top-right pill reading e.g. "2x" or "1x". Called by the coordinator
    /// after the Play/Pause hold gesture toggles the playback rate — only the hold path
    /// triggers this; the Speed menu's selections do not.
    func showSpeedNotification(_ text: String) {
        rootView.showSpeedNotification(text)
    }

    func setLoadingOverlayActive(_ active: Bool) {
        if active {
            rootView.setBarVisible(false, animated: true)
            hideWorkItem?.cancel()
        } else {
            showBarAndResetTimer()
        }
    }

    // MARK: - Player observations

    private func observePlayer(_ player: AVPlayer) {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        periodicToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            self?.updateFromPlayer()
        }
        timeControlObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
            self?.scheduleAutoHideIfNeeded()
            self?.updateIndicator()
        }
        itemObservation = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] player, _ in
            self?.rebindItemObservers(player.currentItem)
            self?.updateFromPlayer()
        }
        rebindItemObservers(player.currentItem)
    }

    private func rebindItemObservers(_ item: AVPlayerItem?) {
        durationObservation?.invalidate(); durationObservation = nil
        loadedRangesObservation?.invalidate(); loadedRangesObservation = nil

        guard let item else {
            rootView.barView.trackControl.duration = 0
            return
        }
        durationObservation = item.observe(\.duration, options: [.initial, .new]) { [weak self] item, _ in
            self?.rootView.barView.trackControl.duration = Self.seconds(item.duration)
            self?.updateHiddenForLiveIfNeeded()
        }
        loadedRangesObservation = item.observe(\.loadedTimeRanges, options: [.initial, .new]) { [weak self] _, _ in
            self?.updateBuffered()
        }
    }

    private func updateFromPlayer() {
        guard let player else {
            rootView.barView.stateIndicator.isHidden = true
            onTimeUpdate?(0)
            return
        }
        if player.currentItem?.duration.isIndefinite == true {
            // Live streams — the bar is hidden elsewhere; keep the indicator hidden too.
            rootView.barView.stateIndicator.isHidden = true
            onTimeUpdate?(0)
            return
        }

        let duration = Self.seconds(player.currentItem?.duration ?? .zero)
        let hasDuration = duration > 0
        rootView.barView.trackControl.duration = duration

        // Skim mode drives the scrubber fill from our own `skimTargetTime`; don't let normal
        // periodic updates fight the scrub preview.
        let t = CMTimeGetSeconds(player.currentTime())
        let cur = t.isFinite ? t : 0
        if !rootView.barView.trackControl.isScrubbing {
            rootView.barView.trackControl.currentTime = cur
            rootView.barView.updateLabels(current: cur, duration: duration)
        }
        updateBuffered()

        // Only show the state indicator once we know the video's duration — otherwise the
        // play / pause icon can render before the elapsed-time label has any content.
        if hasDuration && rootView.barView.stateIndicator.isHidden {
            rootView.barView.stateIndicator.isHidden = false
            updateIndicator()
        } else if !hasDuration {
            rootView.barView.stateIndicator.isHidden = true
        }

        let track = rootView.barView.trackControl
        let captionTime: TimeInterval
        if track.isScrubbing, let preview = track.scrubPreviewTime {
            captionTime = preview
        } else {
            captionTime = cur
        }
        onTimeUpdate?(captionTime)
    }

    private func updateBuffered() {
        guard let item = player?.currentItem else {
            rootView.barView.trackControl.bufferedTime = 0
            return
        }
        var end: TimeInterval = 0
        for value in item.loadedTimeRanges {
            let e = CMTimeGetSeconds(CMTimeRangeGetEnd(value.timeRangeValue))
            if e.isFinite { end = max(end, e) }
        }
        rootView.barView.trackControl.bufferedTime = end
    }

    private func updateHiddenForLiveIfNeeded() {
        guard let item = player?.currentItem else { return }
        if item.duration.isIndefinite {
            rootView.setBarVisible(false, animated: false)
        }
    }

    private static func seconds(_ t: CMTime) -> TimeInterval {
        let s = CMTimeGetSeconds(t)
        return s.isFinite ? s : 0
    }

    // MARK: - Show / hide

    private func showBarAndResetTimer() {
        let wasHidden = !rootView.isBarVisible
        if wasHidden {
            rootView.setBarVisible(true, animated: true)
            // Only snap focus to the scrubber on a hidden-to-visible transition.
            // Re-requesting on every activity would pull focus back from the Quality / Speed
            // buttons whenever the user swiped up to reach them.
            requestFocusOnBar()
        }
        scheduleAutoHideIfNeeded()
    }

    private func updateIndicator() {
        let state: StateIndicatorView.State
        switch skimPhase {
        case .skimming(let direction, let stage):
            state = direction > 0 ? .skimForward(stage: stage) : .skimBackward(stage: stage)
        default:
            if player?.timeControlStatus == .paused {
                state = .paused
            } else {
                state = .playing
            }
        }
        rootView.barView.stateIndicator.update(state)
    }

    private func requestFocusOnBar() {
        rootView.setNeedsFocusUpdate()
        rootView.updateFocusIfNeeded()
    }

    private func scheduleAutoHideIfNeeded() {
        hideWorkItem?.cancel()
        guard let player else { return }

        // Keep visible while paused.
        if player.timeControlStatus == .paused {
            if !rootView.isBarVisible { rootView.setBarVisible(true, animated: true); requestFocusOnBar() }
            return
        }

        // Keep visible while skimming.
        if case .skimming = skimPhase { return }

        // Keep visible while a visual-scrub seek is staged but not yet committed — otherwise
        // the bar would fade out mid-decision, leaving the user unable to see their target.
        if pendingScrubCommit { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self, let player = self.player else { return }
            if player.timeControlStatus == .paused { return }
            if case .skimming = self.skimPhase { return }
            if self.pendingScrubCommit { return }
            // If the user has navigated up to the Quality / Speed buttons, keep the bar visible
            // and push the hide out — they're still engaged with the overlay. When focus
            // eventually returns to the scrubber, `FocusableTrackControl.didUpdateFocus` resets
            // the timer to a full `autoHideDelay` window.
            if self.isChromeButtonFocused {
                self.scheduleAutoHideIfNeeded()
                return
            }
            self.rootView.setBarVisible(false, animated: true) {
                self.requestFocusOnBar()
            }
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + TransportBarMetrics.autoHideDelay, execute: work)
    }

    /// `true` when the Quality or Speed button currently owns focus. Used by the auto-hide timer
    /// and `scheduleAutoHideIfNeeded` to suppress hiding while the user is interacting with the
    /// chrome buttons above the scrubber.
    private var isChromeButtonFocused: Bool {
        rootView.barView.qualityButton.isFocused
            || rootView.barView.skipNextButton.isFocused
            || rootView.barView.speedButton.isFocused
            || rootView.barView.captionsButton.isFocused
    }

    // MARK: - Actions (buttons / gestures / arrows)

    /// Short-tap action for the touchpad click (`.select`). Classic tvOS overlay UX: first
    /// tap wakes the (hidden) bar without toggling playback; a subsequent tap while the bar
    /// is visible toggles play/pause. Differs from `playPauseTapAction` (the dedicated
    /// `.playPause` hardware button) which always toggles immediately.
    private func selectTapAction() {
        if case .skimming = skimPhase {
            exitSkim()
            return
        }
        if pendingScrubCommit, let target = rootView.barView.trackControl.scrubPreviewTime {
            commitVisualScrubSeek(to: target)
            return
        }
        let wasVisible = rootView.isBarVisible
        showBarAndResetTimer()
        guard wasVisible else { return }
        togglePlayPause()
    }

    private func handleScrubberPan(translationX: CGFloat, ended: Bool) {
        // Skim mode consumes the bar; ignore incidental horizontal swipes until the user exits.
        if case .skimming = skimPhase { return }
        guard let player else { return }
        // Visual scrub only happens while the video is paused. Touchpad swipes during playback
        // do nothing — the UI stays as it is so the user isn't accidentally seeking while watching.
        guard player.timeControlStatus == .paused else { return }

        let wasVisible = rootView.isBarVisible
        showBarAndResetTimer()
        guard wasVisible else { return }
        handlePan(translationX: translationX, ended: ended)
    }

    /// Commits the seek staged by a pan-while-paused (visual scrub). Uses the same `finished`-
    /// aware retry loop as skim exit so we don't "jump back" when the seek is interrupted.
    ///
    /// Always resumes playback after the seek lands — committing a scrub is an explicit
    /// "go to here and play" gesture. (Visual scrub only runs while paused, so without this
    /// the player would silently stay paused after the user submits the seek.)
    private func commitVisualScrubSeek(to target: TimeInterval) {
        guard player != nil else {
            pendingScrubCommit = false
            finalizeSeekExitUI()
            return
        }
        commitVisualScrubRetry(target: target, attempt: 1)
    }

    private func commitVisualScrubRetry(target: TimeInterval, attempt: Int) {
        guard let player else { pendingScrubCommit = false; finalizeSeekExitUI(); return }
        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
        let seekTime = CMTime(seconds: target, preferredTimescale: 600)
        player.seek(to: seekTime, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] finished in
            DispatchQueue.main.async {
                guard let self else { return }
                if finished {
                    self.applyFinalSeek(target: target)
                    self.pendingScrubCommit = false
                    self.player?.play()
                    self.showBarAndResetTimer()
                } else if attempt < 3 {
                    self.commitVisualScrubRetry(target: target, attempt: attempt + 1)
                } else {
                    self.pendingScrubCommit = false
                    self.finalizeSeekExitUI()
                    self.player?.play()
                }
            }
        }
    }

    // MARK: - Skim mode (press-and-hold arrows)

    /// Arrow press began.
    ///
    /// - If idle: start a hold timer (0.5 s). If the user releases before it fires, that's a tap
    ///   and we skip ±10 s. If it fires while still held, we enter skim mode.
    /// - If already skimming: the new press adjusts — same direction bumps to a faster stage,
    ///   opposite direction bumps to a slower stage (or flips direction at stage 1).
    private func handleArrowPressBegan(direction: Int) {
        skimHoldWorkItem?.cancel()
        skimHoldWorkItem = nil

        if case .skimming(let curDir, let curStage) = skimPhase {
            var newDir = curDir
            var newStage = curStage
            if direction == curDir {
                newStage = min(TransportBarMetrics.skimStageJumps.count, curStage + 1)
            } else if curStage > 1 {
                newStage = curStage - 1
            } else {
                newDir = direction
            }
            skimPhase = .skimming(direction: newDir, stage: newStage)
            updateIndicator()
            return
        }

        skimPhase = .pressed(direction: direction, began: Date())
        let work = DispatchWorkItem { [weak self] in
            self?.enterSkim(direction: direction)
        }
        skimHoldWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + TransportBarMetrics.holdBeforeSkim, execute: work)

        showBarAndResetTimer()
    }

    private func handleArrowPressEnded(direction: Int) {
        skimHoldWorkItem?.cancel()
        skimHoldWorkItem = nil

        switch skimPhase {
        case .pressed:
            // Short tap — "first press wakes, second press acts" rule. An arrow tap also
            // cancels a pending visual-scrub commit (user has clearly moved on).
            let wasVisible = rootView.isBarVisible
            skimPhase = .idle
            if pendingScrubCommit {
                pendingScrubCommit = false
                rootView.barView.trackControl.isScrubbing = false
                rootView.barView.trackControl.scrubPreviewTime = nil
                hideThumbnailPreview()
            }
            showBarAndResetTimer()
            if wasVisible {
                seekBy(seconds: Double(direction) * TransportBarMetrics.skipSeconds)
            }
        case .skimming:
            // Release does NOT exit skim mode — only Play/Pause does.
            break
        case .idle:
            break
        }
    }

    private func enterSkim(direction: Int) {
        guard let player else { return }
        wasPlayingBeforeSkim = (player.timeControlStatus == .playing || player.timeControlStatus == .waitingToPlayAtSpecifiedRate)
        player.pause()
        skimPhase = .skimming(direction: direction, stage: 1)
        let cur = CMTimeGetSeconds(player.currentTime())
        skimTargetTime = cur.isFinite ? cur : 0
        // Display the target on the scrubber immediately; normal periodic updates stay suppressed
        // while `isScrubbing == true` so a slow seek can't stomp on our advancing preview.
        rootView.barView.trackControl.isScrubbing = true
        rootView.barView.trackControl.scrubPreviewTime = skimTargetTime
        showThumbnailPreview(at: skimTargetTime)
        startSkimTimer()
        showBarAndResetTimer()
        updateIndicator()
    }

    private func startSkimTimer() {
        skimTimer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: TransportBarMetrics.skimTickInterval, repeats: true) { [weak self] _ in
            self?.performSkimTick()
        }
        // Keep ticks firing even while the user is interacting with gestures elsewhere.
        RunLoop.main.add(t, forMode: .common)
        skimTimer = t
    }

    private func performSkimTick() {
        guard case .skimming(let direction, let stage) = skimPhase else { return }
        guard let player, let item = player.currentItem else { return }
        let dur = CMTimeGetSeconds(item.duration)
        guard dur.isFinite, dur > 0 else { return }

        let jumps = TransportBarMetrics.skimStageJumps
        let idx = min(max(0, stage - 1), jumps.count - 1)
        let step = jumps[idx] * Double(direction)

        let previous = skimTargetTime
        skimTargetTime = min(max(0, previous + step), dur)
        if abs(skimTargetTime - previous) < 0.01 { return } // pinned to an edge

        // Drive the scrubber fill and the elapsed-time label from our target — the player may
        // still be fetching segments past the buffer, but the UI keeps advancing smoothly.
        let track = rootView.barView.trackControl
        track.scrubPreviewTime = skimTargetTime
        rootView.barView.updateLabels(current: skimTargetTime, duration: dur)
        showThumbnailPreview(at: skimTargetTime)

        // Loose tolerance so HLS can snap to the nearest keyframe at / past the buffered range.
        // Exact (`.zero`) seeks require full decode to that frame and in practice refuse to leave
        // the buffered region, which was what made skim "stick" at the buffer edge.
        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
        player.seek(
            to: CMTime(seconds: skimTargetTime, preferredTimescale: 600),
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        )
    }

    /// Exits skim by **committing the final target with a seek completion** before calling
    /// `play()`. The seek callback's `finished` flag is authoritative: if it's `false`, the seek
    /// was interrupted and the player is at an older position — retrying (rather than clearing
    /// the UI) avoids the "jump back" the user reported. On success we pin the scrubber's
    /// `currentTime` *before* clearing `isScrubbing` so the next periodic observer tick can't
    /// overwrite it with a stale value from `player.currentTime`.
    private func exitSkim() {
        skimHoldWorkItem?.cancel(); skimHoldWorkItem = nil
        skimTimer?.invalidate(); skimTimer = nil
        skimPhase = .idle

        guard player != nil else {
            finalizeSeekExitUI()
            return
        }
        commitSeekAndResume(target: skimTargetTime, resume: wasPlayingBeforeSkim, attempt: 1)
    }

    private func commitSeekAndResume(target: TimeInterval, resume: Bool, attempt: Int) {
        guard let player else { finalizeSeekExitUI(); return }
        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
        let seekTime = CMTime(seconds: target, preferredTimescale: 600)
        player.seek(to: seekTime, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] finished in
            DispatchQueue.main.async {
                guard let self else { return }
                if finished {
                    self.applyFinalSeek(target: target)
                    if resume { self.player?.play() }
                    self.updateIndicator()
                    self.showBarAndResetTimer()
                } else if attempt < 3 {
                    // Seek was interrupted (usually by another seek still in flight). Retry.
                    self.commitSeekAndResume(target: target, resume: resume, attempt: attempt + 1)
                } else {
                    // Give up gracefully: clear UI and start playback wherever the player ended up
                    // so we don't lock the user in a preview state forever.
                    self.finalizeSeekExitUI()
                    if resume { self.player?.play() }
                }
            }
        }
    }

    /// Pin the scrubber/labels to the target, then drop the preview state. Order matters: setting
    /// `currentTime` *before* clearing `isScrubbing` prevents a stale `player.currentTime` reading
    /// from briefly snapping the cursor backwards after the seek completes.
    private func applyFinalSeek(target: TimeInterval) {
        let track = rootView.barView.trackControl
        track.currentTime = target
        rootView.barView.updateLabels(current: target, duration: track.duration)
        track.isScrubbing = false
        track.scrubPreviewTime = nil
        hideThumbnailPreview()
    }

    private func finalizeSeekExitUI() {
        rootView.barView.trackControl.isScrubbing = false
        rootView.barView.trackControl.scrubPreviewTime = nil
        hideThumbnailPreview()
        updateIndicator()
        showBarAndResetTimer()
    }

    @objc private func qualityPressed() {
        onQualityTapped()
        showBarAndResetTimer()
    }

    @objc private func speedPressed() {
        onSpeedTapped()
        showBarAndResetTimer()
    }

    @objc private func captionsPressed() {
        onCaptionsTapped?()
        showBarAndResetTimer()
    }

    @objc private func skipNextPressed() {
        onSkipNextTapped?()
        showBarAndResetTimer()
    }

    private func togglePlayPause() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
        }
        showBarAndResetTimer()
    }

    private func seekBy(seconds: Double) {
        guard let player else { return }
        let cur = CMTimeGetSeconds(player.currentTime())
        guard cur.isFinite else { return }
        let d: Double = {
            guard let item = player.currentItem else { return 0 }
            let s = CMTimeGetSeconds(item.duration)
            return s.isFinite ? s : 0
        }()
        var target = cur + seconds
        if d > 0 { target = min(max(0, target), d) } else { target = max(0, target) }
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        showBarAndResetTimer()
    }

    /// Visual-scrub pan handler. Runs only while the player is paused (the `handleScrubberPan`
    /// caller enforces that). Each gesture's `translationX` is measured from that gesture's own
    /// `.began`, so we apply it on top of `panAnchorTime` — the position the cursor reached at the
    /// end of the previous gesture, or `player.currentTime` if this is the very first pan after
    /// the user entered pause. This composition lets the user make small adjustments by lifting
    /// and swiping again instead of the cursor snapping back to the original starting position.
    private func handlePan(translationX: CGFloat, ended: Bool) {
        guard let player else { return }
        let track = rootView.barView.trackControl
        let dur = track.duration
        guard dur.isFinite, dur > 0 else { return }
        let trackW = track.bounds.width
        guard trackW > 0 else { return }

        if !track.isScrubbing {
            let cur = CMTimeGetSeconds(player.currentTime())
            panAnchorTime = cur.isFinite ? cur : 0
            track.isScrubbing = true
            pendingScrubCommit = true
        }
        let deltaT = Double(translationX / trackW) * dur * TransportBarMetrics.panSensitivity
        var target = panAnchorTime + deltaT
        target = min(max(0, target), dur)
        track.scrubPreviewTime = target
        rootView.barView.updateLabels(current: target, duration: dur)
        showThumbnailPreview(at: target)

        if ended {
            // Lock this position as the anchor for the next gesture so continuing to pan extends
            // from here instead of snapping back to `player.currentTime`.
            panAnchorTime = target
            showBarAndResetTimer()
        }
    }

    /// Cancels a pending visual-scrub commit without seeking. The cursor / thumbnail / labels
    /// snap back to the player's real current time. Invoked when the user presses Menu/Back.
    private func cancelVisualScrub() {
        guard pendingScrubCommit else { return }
        let track = rootView.barView.trackControl
        track.isScrubbing = false
        track.scrubPreviewTime = nil
        pendingScrubCommit = false
        hideThumbnailPreview()
        if let player {
            let cur = CMTimeGetSeconds(player.currentTime())
            let safe = cur.isFinite ? cur : 0
            track.currentTime = safe
            rootView.barView.updateLabels(current: safe, duration: track.duration)
        }
        updateIndicator()
        showBarAndResetTimer()
    }

    // MARK: - Thumbnail preview

    /// Builds an `AVAssetImageGenerator` for the current item's asset so we can render frame
    /// previews above the cursor while skimming / scrubbing. Tolerances are deliberately loose
    /// (up to 2 s) — on HLS, exact-frame generation requires fetching new segments, which is
    /// slow; snapping to the nearest keyframe keeps the popover responsive.
    private func setupThumbnailGenerator(for player: AVPlayer) {
        guard let asset = player.currentItem?.asset else { return }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 640, height: 360)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)
        thumbnailGenerator = gen
        thumbnailCache.removeAll()
    }

    private func showThumbnailPreview(at time: TimeInterval) {
        let dur = rootView.barView.trackControl.duration
        guard dur.isFinite, dur > 0 else { return }
        rootView.barView.positionThumbnail(atTime: time, duration: dur)
        rootView.barView.thumbnailPreview.isHidden = false
        requestThumbnail(at: time)
    }

    private func hideThumbnailPreview() {
        rootView.barView.thumbnailPreview.isHidden = true
        thumbnailRequestWork?.cancel(); thumbnailRequestWork = nil
        thumbnailGenerator?.cancelAllCGImageGeneration()
    }

    private func requestThumbnail(at time: TimeInterval) {
        // 1. Preferred source: PeerTube server-side storyboard. Cropping the sprite is a
        //    synchronous image operation — no need for debounce or async work.
        if let provider = storyboardProvider, let sprite = provider.image(for: time) {
            rootView.barView.thumbnailPreview.setImage(sprite)
            return
        }

        // 2. Fallback: AVAssetImageGenerator. Works for local files / MP4 but is effectively
        //    unusable for HLS positions past the buffer.
        let key = Int(time.rounded(.down))
        if let cached = thumbnailCache[key] {
            rootView.barView.thumbnailPreview.setImage(cached)
            return
        }
        if let closest = nearestCachedThumbnail(to: key) {
            rootView.barView.thumbnailPreview.setImage(closest)
        }
        thumbnailRequestWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.generateThumbnail(at: time, key: key)
        }
        thumbnailRequestWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.thumbnailDebounce, execute: work)
    }

    private func nearestCachedThumbnail(to key: Int) -> UIImage? {
        guard !thumbnailCache.isEmpty else { return nil }
        var bestKey = thumbnailCache.keys.first!
        var bestDistance = abs(bestKey - key)
        for k in thumbnailCache.keys where abs(k - key) < bestDistance {
            bestKey = k
            bestDistance = abs(k - key)
        }
        return thumbnailCache[bestKey]
    }

    private func generateThumbnail(at time: TimeInterval, key: Int) {
        guard let generator = thumbnailGenerator else { return }
        generator.cancelAllCGImageGeneration()
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: cmTime)]) { [weak self] _, image, _, result, _ in
            guard let self, result == .succeeded, let image else { return }
            let uiImage = UIImage(cgImage: image)
            DispatchQueue.main.async {
                self.thumbnailCache[key] = uiImage
                // Only apply if the preview is still visible for roughly this time, so an old
                // in-flight request can't stomp on the current preview after the user moved on.
                if !self.rootView.barView.thumbnailPreview.isHidden {
                    self.rootView.barView.thumbnailPreview.setImage(uiImage)
                }
            }
        }
    }

    // MARK: - MPRemoteCommandCenter (Siri Remote / Now Playing)

    private func registerRemoteCommands() {
        guard !registeredRemoteCommandTargets else { return }
        registeredRemoteCommandTargets = true
        let c = MPRemoteCommandCenter.shared()
        c.skipForwardCommand.isEnabled = true
        c.skipForwardCommand.preferredIntervals = [NSNumber(value: TransportBarMetrics.skipSeconds)]
        c.skipForwardCommand.addTarget(self, action: #selector(mpSkipForward))
        c.skipBackwardCommand.isEnabled = true
        c.skipBackwardCommand.preferredIntervals = [NSNumber(value: TransportBarMetrics.skipSeconds)]
        c.skipBackwardCommand.addTarget(self, action: #selector(mpSkipBackward))
        c.togglePlayPauseCommand.isEnabled = true
        c.togglePlayPauseCommand.addTarget(self, action: #selector(mpTogglePlayPause))
        c.playCommand.isEnabled = true
        c.playCommand.addTarget(self, action: #selector(mpPlay))
        c.pauseCommand.isEnabled = true
        c.pauseCommand.addTarget(self, action: #selector(mpPause))
    }

    private func unregisterRemoteCommands() {
        guard registeredRemoteCommandTargets else { return }
        registeredRemoteCommandTargets = false
        let c = MPRemoteCommandCenter.shared()
        c.skipForwardCommand.removeTarget(self)
        c.skipBackwardCommand.removeTarget(self)
        c.togglePlayPauseCommand.removeTarget(self)
        c.playCommand.removeTarget(self)
        c.pauseCommand.removeTarget(self)
    }

    @objc private func mpSkipForward(_ e: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        seekBy(seconds: TransportBarMetrics.skipSeconds); return .success
    }
    @objc private func mpSkipBackward(_ e: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        seekBy(seconds: -TransportBarMetrics.skipSeconds); return .success
    }
    @objc private func mpTogglePlayPause(_ e: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        playPauseTapAction(); return .success
    }
    @objc private func mpPlay(_ e: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        if case .skimming = skimPhase { exitSkim(); return .success }
        if pendingScrubCommit, let target = rootView.barView.trackControl.scrubPreviewTime {
            commitVisualScrubSeek(to: target); return .success
        }
        player?.play(); showBarAndResetTimer(); return .success
    }
    @objc private func mpPause(_ e: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        if case .skimming = skimPhase { exitSkim(); return .success }
        if pendingScrubCommit, let target = rootView.barView.trackControl.scrubPreviewTime {
            commitVisualScrubSeek(to: target); return .success
        }
        player?.pause(); showBarAndResetTimer(); return .success
    }
}

// MARK: - Player container

/// Wraps `AVPlayerViewController` as a child view controller and hosts the transport bar
/// overlay as a sibling. Doing this (rather than installing into `contentOverlayView`) is
/// required on tvOS because AVKit does not reliably route focus to custom subviews of the
/// `AVPlayerViewController`'s own view hierarchy. The container returns the overlay's root
/// as its preferred focus environment, so the scrubber always receives focus.
final class PlayerContainerViewController: UIViewController {

    private let playerViewController: AVPlayerViewController
    private let overlayRoot: TransportBarRootView

    /// Sits above the video and below the transport overlay so captions stay readable.
    let captionOverlay = CaptionOverlayView()

    /// Called after the container begins dismissing, once per lifecycle.
    var onDismissed: (() -> Void)?

    /// Asked whether a Menu/Back press should be swallowed by the overlay (e.g. cancelling a
    /// staged visual scrub) instead of dismissing the player. Return `true` to swallow.
    ///
    /// This is the **single** menu handler on the container. Earlier iterations had a gesture
    /// recognizer AND a pressesBegan override AND a scrubber-level consumer all racing; whichever
    /// one cleared `pendingScrubCommit` first left the others dismissing the player instead of
    /// cancelling the scrub. Collapsing to one path fixes it.
    var shouldConsumeMenuPress: (() -> Bool)?

    /// Invoked when the Siri Remote's physical Play/Pause button goes down. Handled at the
    /// container level (rather than on the focused scrubber) so the button works even when
    /// focus has moved up to the Quality / Speed buttons. Fires once per press — no tap
    /// vs. hold distinction here because the `.playPause` button has parallel AVKit /
    /// `MPRemoteCommandCenter` paths that we can't reliably suppress. Hold-for-speed lives
    /// on the touchpad click (`.select`) instead.
    var onPlayPausePress: (() -> Void)?

    init(playerViewController: AVPlayerViewController, overlayRoot: TransportBarRootView) {
        self.playerViewController = playerViewController
        self.overlayRoot = overlayRoot
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        addChild(playerViewController)
        playerViewController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(playerViewController.view)
        NSLayoutConstraint.activate([
            playerViewController.view.topAnchor.constraint(equalTo: view.topAnchor),
            playerViewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            playerViewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            playerViewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        playerViewController.didMove(toParent: self)

        captionOverlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(captionOverlay)
        NSLayoutConstraint.activate([
            captionOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            captionOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            captionOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            captionOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        overlayRoot.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlayRoot)
        NSLayoutConstraint.activate([
            overlayRoot.topAnchor.constraint(equalTo: view.topAnchor),
            overlayRoot.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            overlayRoot.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlayRoot.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        overlayRoot.onBarVisibilityChanged = { [weak self] visible in
            self?.captionOverlay.setTransportBarChromeVisible(visible)
        }
        captionOverlay.setTransportBarChromeVisible(overlayRoot.isBarVisible)
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        [overlayRoot]
    }

    /// Single menu handler: consult the overlay first (it may cancel an in-progress visual
    /// scrub), otherwise dismiss the player. Not calling `super` means UIKit's default
    /// "Menu dismisses the topmost presented VC" behavior is suppressed when we consume.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            switch press.type {
            case .menu:
                if shouldConsumeMenuPress?() == true { return }
                dismiss(animated: true)
                return
            case .playPause:
                // Consume the press so AVKit / MPRemoteCommandCenter don't also react — those
                // paths only reliably pause (Now Playing state is stale because we hide AVKit's
                // native controls), which is what caused the "pause works, play doesn't" bug.
                if let handler = onPlayPausePress {
                    handler()
                    return
                }
            default:
                break
            }
        }
        super.pressesBegan(presses, with: event)
    }

    /// UIKit installs a `.menu`-only tap gesture recognizer on the presentation controller to
    /// auto-dismiss modal VCs on tvOS. That gesture runs in parallel with our `pressesBegan`
    /// override and can't be blocked by not calling `super` — it just calls `dismiss(animated:)`
    /// on us directly. Intercept *all* dismissal attempts here so the overlay can veto them while
    /// a visual-scrub is in flight (or just got cancelled — see the debounce window in
    /// `TransportBarController.handleMenuPressIfNeeded`).
    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        if shouldConsumeMenuPress?() == true {
            completion?()
            return
        }
        super.dismiss(animated: flag, completion: completion)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || isMovingFromParent {
            onDismissed?()
            onDismissed = nil
        }
    }
}
