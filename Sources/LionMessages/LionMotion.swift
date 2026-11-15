import AppKit
import SwiftUI

/// Every duration and curve of the app's motion lives here, so it stays consistent and tunable.
/// Lion-era motion: quick ease-outs and crossfades, no springs.
@MainActor
enum LionMotion {
    /// Turned on for `--snapshot` so a still picture is always fully settled.
    static var isDisabled = false
    /// `--reduce-motion` forces the Reduce Motion behavior for testing.
    static var forceReduceMotion = false

    /// Movement is replaced by short fades (or nothing) when Reduce Motion is on.
    static var reduceMotion: Bool {
        forceReduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // Transcript
    static let bubbleArrival: TimeInterval = 0.28
    static let bubbleRise: CGFloat = 12
    static let bubbleStartScale: CGFloat = 0.92
    static let transcriptScroll: TimeInterval = 0.28
    static let transcriptCrossfade: TimeInterval = 0.12
    /// A row that just gained a fetched link preview fades in.
    static let linkPreviewFade: TimeInterval = 0.2
    /// How long a conversation switch may hold the old transcript while the new one loads.
    static let transcriptLoadHold: TimeInterval = 0.3

    // Composer
    static let composerResize: TimeInterval = 0.15
    static let sendFlash: TimeInterval = 0.12
    static let dropHighlight: TimeInterval = 0.15

    // Sidebar
    static let sidebarMove: TimeInterval = 0.25
    static let sidebarFilter: TimeInterval = 0.12

    // Focus ring: starts larger and fainter, then contracts onto the field.
    static let focusRingIn: TimeInterval = 0.2
    static let focusRingOut: TimeInterval = 0.15
    static let focusRingOutset: CGFloat = 6

    // Sheets, screens, window state, controls
    static let sheet: TimeInterval = 0.25
    static let sheetDim: Double = 0.12
    static let screenCrossfade: TimeInterval = 0.3
    static let panelAppear: TimeInterval = 0.3
    static let panelStartScale: CGFloat = 0.97
    static let windowActive: TimeInterval = 0.15
    static let buttonPress: TimeInterval = 0.08
    static let defaultButtonPulsePeriod: TimeInterval = 1.0
    static let scrollerFadeDelay: TimeInterval = 0.8
    static let scrollerFade: TimeInterval = 0.25

    /// `--slow-motion <factor>` stretches every duration (for inspecting frame sequences).
    static var timeScale: Double = 1

    /// The effective duration: 0 when motion is off (snapshots).
    static func duration(_ d: TimeInterval) -> TimeInterval { isDisabled ? 0 : d * timeScale }

    // SwiftUI equivalents (nil = no animation).
    static func easeOut(_ d: TimeInterval) -> Animation? { isDisabled ? nil : .easeOut(duration: d * timeScale) }
    static func easeInOut(_ d: TimeInterval) -> Animation? { isDisabled ? nil : .easeInOut(duration: d * timeScale) }
}

enum LionCurve {
    case linear, easeOut, easeInOut

    func apply(_ t: CGFloat) -> CGFloat {
        let t = min(max(t, 0), 1)
        switch self {
        case .linear: return t
        case .easeOut: return 1 - pow(1 - t, 3)
        case .easeInOut: return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        }
    }
}

/// A tiny frame-driven animation. It updates real view state every frame (frames, alphas,
/// progress values read by `draw`), so what's on screen is also what `cacheDisplay` captures.
@MainActor
final class LionTween {
    private let start = CACurrentMediaTime()
    private let duration: TimeInterval
    private let curve: LionCurve
    private let update: (CGFloat) -> Void
    private let completion: () -> Void
    private(set) var isFinished = false

    private static var active: [LionTween] = []
    private static var timer: Timer?

    /// Runs `update` with eased progress 0→1. A zero duration finishes synchronously.
    @discardableResult
    static func run(duration: TimeInterval, curve: LionCurve = .easeOut,
                    update: @escaping (CGFloat) -> Void, completion: @escaping () -> Void = {}) -> LionTween {
        let tween = LionTween(duration: LionMotion.duration(duration), curve: curve, update: update, completion: completion)
        if tween.duration <= 0 {
            tween.finish()
        } else {
            update(0)
            active.append(tween)
            startTimer()
        }
        return tween
    }

    private init(duration: TimeInterval, curve: LionCurve, update: @escaping (CGFloat) -> Void,
                 completion: @escaping () -> Void) {
        self.duration = duration
        self.curve = curve
        self.update = update
        self.completion = completion
    }

    /// Stops without calling `update` again or `completion`.
    func cancel() {
        isFinished = true
        Self.active.removeAll { $0 === self }
    }

    /// Jumps to the end state and completes.
    func finish() {
        guard !isFinished else { return }
        isFinished = true
        Self.active.removeAll { $0 === self }
        update(1)
        completion()
    }

    private func tick(_ now: CFTimeInterval) {
        let t = CGFloat((now - start) / duration)
        if t >= 1 { finish() } else { update(curve.apply(t)) }
    }

    private static func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in
            MainActor.assumeIsolated { LionTween.tickAll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Brings every running tween up to the current time (frame capture blocks the run loop,
    /// so it ticks first to picture the true state at that moment).
    static func tickNow() { tickAll() }

    private static func tickAll() {
        let now = CACurrentMediaTime()
        for tween in active where !tween.isFinished { tween.tick(now) }
        if active.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }
}

/// Animated 0…1 value for a window's key state (1 = active), for Lion's quick active/inactive crossfade.
@MainActor
final class LionActiveFader {
    private(set) var value: CGFloat = 1
    var onChange: () -> Void = {}
    private var tween: LionTween?
    private var observers: [NSObjectProtocol] = []

    func attach(to window: NSWindow?) {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        tween?.cancel()
        guard let window else { return }
        value = window.isKeyWindow ? 1 : 0
        onChange()
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                [weak self, weak window] _ in
                MainActor.assumeIsolated { self?.animate(to: window?.isKeyWindow == true ? 1 : 0) }
            })
        }
    }

    private func animate(to target: CGFloat) {
        tween?.cancel()
        let from = value
        guard from != target else { return }
        tween = LionTween.run(duration: LionMotion.windowActive, curve: .linear, update: { [weak self] t in
            guard let self else { return }
            self.value = from + (target - from) * t
            self.onChange()
        })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}

/// Lion's focus ring: on focus it starts ~6 pt larger and faint, then contracts onto the field;
/// on blur it fades out in place. Reduce Motion: fades only.
@MainActor
final class LionFocusRing {
    private(set) var alpha: CGFloat = 0
    /// Extra distance outside the resting ring.
    private(set) var outset: CGFloat = 0
    var onChange: () -> Void = {}
    private var focused = false
    private var tween: LionTween?

    func setFocused(_ focused: Bool) {
        guard focused != self.focused else { return }
        self.focused = focused
        tween?.cancel()
        let fromAlpha = alpha, fromOutset = outset
        if focused {
            let startOutset: CGFloat = LionMotion.reduceMotion || fromAlpha > 0 ? fromOutset : LionMotion.focusRingOutset
            tween = LionTween.run(duration: LionMotion.focusRingIn, curve: .easeOut, update: { [weak self] t in
                guard let self else { return }
                self.alpha = fromAlpha + (1 - fromAlpha) * t
                self.outset = startOutset * (1 - t)
                self.onChange()
            })
        } else {
            tween = LionTween.run(duration: LionMotion.focusRingOut, curve: .easeOut, update: { [weak self] t in
                guard let self else { return }
                self.alpha = fromAlpha * (1 - t)
                self.outset = fromOutset
                self.onChange()
            }, completion: { [weak self] in self?.outset = 0 })
        }
    }
}

extension NSColor {
    /// Linear blend in sRGB, `t` = 0 → self, 1 → other.
    func lionMix(_ other: NSColor, _ t: CGFloat) -> NSColor {
        if t <= 0 { return self }
        if t >= 1 { return other }
        return blended(withFraction: t, of: other) ?? (t < 0.5 ? self : other)
    }
}
