import CoreGraphics
import Foundation

public enum MacVirtualKeyCodes {
    public static func code(for key: KeyboardKey) -> CGKeyCode {
        switch key {
        case .a: 0
        case .s: 1
        case .d: 2
        case .f: 3
        case .h: 4
        case .g: 5
        case .z: 6
        case .x: 7
        case .c: 8
        case .v: 9
        case .b: 11
        case .q: 12
        case .w: 13
        case .e: 14
        case .r: 15
        case .y: 16
        case .t: 17
        case .u: 32
        case .j: 38
        case .n: 45
        case .m: 46
        }
    }

    public static func code(for modifier: KeyModifier, side: ModifierKeySide = .left) -> CGKeyCode? {
        switch modifier {
        case .none: nil
        case .shift: side == .left ? 56 : 60
        case .control: side == .left ? 59 : 62
        }
    }

    public static var escape: CGKeyCode { 53 }
}

public enum ModifierKeySide: String, Codable, Equatable {
    case left
    case right
}

public extension KeyModifier {
    var cgEventFlags: CGEventFlags {
        switch self {
        case .none: []
        case .shift: .maskShift
        case .control: .maskControl
        }
    }
}
