import UIKit

/// Renders WebVTT cues over the video, above the transport bar.
final class CaptionOverlayView: UIView {

    private let backdrop = UIView()
    private let label = UILabel()
    private var bottomConstraint: NSLayoutConstraint!

    private var cues: [VTTCue] = []
    private var lastShownText: String?

    /// Extra space above the safe-area bottom when the transport bar chrome is visible.
    private static let bottomInsetBarVisible: CGFloat = 260
    private static let bottomInsetBarHidden: CGFloat = 80

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private func setup() {
        isUserInteractionEnabled = false
        backgroundColor = .clear

        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.backgroundColor = UIColor.black.withAlphaComponent(0.72)
        backdrop.layer.cornerRadius = 10
        backdrop.clipsToBounds = true

        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 30, weight: .semibold))
        label.adjustsFontForContentSizeCategory = true
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.55
        label.layer.shadowRadius = 4
        label.layer.shadowOffset = CGSize(width: 0, height: 1)

        addSubview(backdrop)
        backdrop.addSubview(label)

        bottomConstraint = backdrop.bottomAnchor.constraint(
            equalTo: safeAreaLayoutGuide.bottomAnchor,
            constant: -Self.bottomInsetBarVisible
        )

        NSLayoutConstraint.activate([
            backdrop.centerXAnchor.constraint(equalTo: centerXAnchor),
            backdrop.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 72),
            backdrop.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -72),
            bottomConstraint,
            backdrop.topAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.topAnchor, constant: 24),

            label.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -12),
            label.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 18),
            label.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -18)
        ])

        clearDisplay()
    }

    func setCues(_ newCues: [VTTCue]) {
        cues = newCues
        lastShownText = nil
        clearDisplay()
    }

    func setCurrentTime(_ t: TimeInterval) {
        guard !cues.isEmpty else {
            clearDisplay()
            return
        }
        let time = t.isFinite ? max(0, t) : 0
        guard let cue = cue(at: time) else {
            if lastShownText != nil {
                lastShownText = nil
                clearDisplay()
            }
            return
        }
        if cue.text == lastShownText { return }
        lastShownText = cue.text
        label.text = cue.text
        backdrop.isHidden = false
        label.isHidden = false
    }

    func clearCuesAndDisplay() {
        cues = []
        lastShownText = nil
        clearDisplay()
    }

    /// Lifts captions when the transport bar is visible so they don’t sit under the scrubber.
    func setTransportBarChromeVisible(_ visible: Bool) {
        let inset = visible ? Self.bottomInsetBarVisible : Self.bottomInsetBarHidden
        bottomConstraint.constant = -inset
        layoutIfNeeded()
    }

    private func clearDisplay() {
        label.text = nil
        label.isHidden = true
        backdrop.isHidden = true
    }

    private func cue(at time: TimeInterval) -> VTTCue? {
        guard let idx = indexOfLastCueWithStart(beforeOrAt: time) else { return nil }
        let c = cues[idx]
        return time < c.end ? c : nil
    }

    private func indexOfLastCueWithStart(beforeOrAt t: TimeInterval) -> Int? {
        var lo = 0
        var hi = cues.count - 1
        var answer: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if cues[mid].start <= t {
                answer = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return answer
    }
}
