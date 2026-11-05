import SwiftUI

/// Shared native typography, corners and adaptive surfaces. Stage and location colours stay semantic.
enum TypeStyle {
    static let body = Font.body
    static let callout = Font.callout
    static let caption = Font.caption
    static let caption2 = Font.caption2
    static let headline = Font.headline
    static let title = Font.title
    static let title2 = Font.title2
    static let title3 = Font.title3
    static let largeTitle = Font.largeTitle
}

enum Radius {
    static let sm: CGFloat = 4
    static let md: CGFloat = 8
    static let lg: CGFloat = 12
}

enum Surface {
    static let window = Color(nsColor: .windowBackgroundColor)
    static let control = Color(nsColor: .controlBackgroundColor)
    static let secondary = Color(nsColor: .underPageBackgroundColor)
}
