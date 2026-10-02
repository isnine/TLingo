//
//  DesignMetrics.swift
//  ShareCore
//

import SwiftUI

/// Corner radii. Always draw them with `style: .continuous`.
public enum TLingoRadius {
    /// Skeleton bars, small badges, inline controls.
    public static let small: CGFloat = 8
    /// Cards, message bubbles, list rows.
    public static let medium: CGFloat = 12
    /// Composer, language bar, floating panels.
    public static let large: CGFloat = 18
    /// Large docked bars.
    public static let extraLarge: CGFloat = 24
}

/// Spacing scale on a 4pt rhythm.
public enum TLingoSpacing {
    public static let xxs: CGFloat = 4
    public static let xs: CGFloat = 8
    public static let sm: CGFloat = 12
    public static let md: CGFloat = 16
    public static let lg: CGFloat = 20
    public static let xl: CGFloat = 24
}

public enum TLingoMetrics {
    /// Minimum tappable size for icon-only buttons.
    #if os(iOS)
        public static let minimumHitTarget: CGFloat = 44
    #else
        public static let minimumHitTarget: CGFloat = 28
    #endif
}
