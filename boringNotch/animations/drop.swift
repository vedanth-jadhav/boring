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
    /// Read the current preference for every transition, including its delays.
    private static func configured(_ animation: Animation) -> Animation {
        guard Defaults[.enableOpeningAnimation] else { return .linear(duration: 0) }
        let speed = Defaults[.animationSpeedMultiplier]
        return animation.speed(speed.isFinite && speed > 0 ? speed : 1)
    }

    /// Controls clear before the surface contracts; artwork has its own layer.
    static var contentDismiss: Animation {
        configured(.easeOut(duration: 0.10))
    }
    /// Content arrives after the expanding surface starts making space.
    static var contentSettle: Animation {
        configured(.easeOut(duration: 0.20).delay(0.08))
    }
    /// Interactive spring for responsive UI (used for notch interactions)
    static var interactive: Animation {
        configured(.interactiveSpring(response: 0.38, dampingFraction: 0.8, blendDuration: 0))
    }

    /// Tab/session changes settle quickly without disturbing the top anchor.
    static var focusTab: Animation {
        configured(.interactiveSpring(response: 0.36, dampingFraction: 0.94, blendDuration: 0))
    }

    /// Spring animation for opening the notch
    static var open: Animation {
        configured(.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0))
    }

    /// Spring animation for closing the notch
    static var close: Animation {
        configured(.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0))
    }

    /// Bouncy spring for playful animations
    @available(macOS 14.0, *)
    static var bouncy: Animation {
        configured(.spring(.bouncy(duration: 0.4)))
    }

    /// Smooth animation for general transitions
    static var smooth: Animation { configured(.smooth) }

    /// Closed-state content can resize the same notch surface.
    static var closedContent: Animation { configured(.smooth(duration: 0.3)) }

    /// Timing curve fallback for older macOS versions
    static var timingCurve: Animation {
        configured(.timingCurve(0.16, 1, 0.3, 1, duration: 0.7))
    }
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
