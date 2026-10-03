//
//  drop.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on  04/08/24.
//

import Defaults
import Foundation
import SwiftUI

// MARK: - Standardized Animations
/// Centralized animation definitions for consistent UI behavior across the app.
enum StandardAnimations {
    /// Controls clear before the surface contracts; artwork has its own layer.
    static var contentDismiss: Animation {
        guard Defaults[.enableOpeningAnimation] else { return .linear(duration: 0) }
        return .easeOut(duration: 0.10 / Defaults[.animationSpeedMultiplier])
    }
    /// Content arrives after the expanding surface starts making space.
    static var contentSettle: Animation {
        guard Defaults[.enableOpeningAnimation] else { return .linear(duration: 0) }
        let speed = Defaults[.animationSpeedMultiplier]
        return .easeOut(duration: 0.20 / speed).delay(0.08 / speed)
    }
    /// Interactive spring for responsive UI (used for notch interactions)
    static let interactive = Animation.interactiveSpring(response: 0.38, dampingFraction: 0.8, blendDuration: 0)

    /// Tab/session changes settle quickly without disturbing the top anchor.
    static let focusTab = Animation.interactiveSpring(response: 0.36, dampingFraction: 0.94, blendDuration: 0)

    /// Spring animation for opening the notch
    static var open: Animation {
        guard Defaults[.enableOpeningAnimation] else {
            return Animation.linear(duration: 0)
        }
        return Animation.spring(response: 0.42 / Defaults[.animationSpeedMultiplier], dampingFraction: 0.8, blendDuration: 0)
    }

    /// Spring animation for closing the notch
    static var close: Animation {
        guard Defaults[.enableOpeningAnimation] else {
            return Animation.linear(duration: 0)
        }
        return Animation.spring(response: 0.45 / Defaults[.animationSpeedMultiplier], dampingFraction: 1.0, blendDuration: 0)
    }

    /// Bouncy spring for playful animations
    @available(macOS 14.0, *)
    static var bouncy: Animation {
        Animation.spring(.bouncy(duration: 0.4))
    }

    /// Smooth animation for general transitions
    static let smooth = Animation.smooth

    /// Timing curve fallback for older macOS versions
    static let timingCurve = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.7)
}

final class BoringAnimations {
    @Published var notchStyle: Style = .notch

    var animation: Animation {
        if #available(macOS 14.0, *), notchStyle == .notch {
            StandardAnimations.bouncy
        } else {
            StandardAnimations.timingCurve
        }
    }
}
