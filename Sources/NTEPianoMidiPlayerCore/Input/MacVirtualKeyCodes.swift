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

    public static func code(for modifier: KeyModifier) -> CGKeyCode? {
        switch modifier {
        case .none: nil
        case .shift: 56
        case .control: 59
        }
    }

    public static var escape: CGKeyCode { 53 }
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
