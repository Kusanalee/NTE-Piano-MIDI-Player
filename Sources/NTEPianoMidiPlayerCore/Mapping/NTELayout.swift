import Foundation

public enum NTELayout {
    public static let noteNames = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "G#", "A", "Bb", "B"]
    public static let naturalSemitones = [0, 2, 4, 5, 7, 9, 11]
    public static let naturalDegreeLabels = ["1", "2", "3", "4", "5", "6", "7"]

    public static let rowKeys: [PianoRow: [KeyboardKey]] = [
        .bas: [.z, .x, .c, .v, .b, .n, .m],
        .mid: [.a, .s, .d, .f, .g, .h, .j],
        .tre: [.q, .w, .e, .r, .t, .y, .u]
    ]

    public static let rowOffsets: [PianoRow: Int] = [
        .bas: 0,
        .mid: 12,
        .tre: 24
    ]

    public static let chromaticDegreeMap: [Int: (degree: String, naturalIndex: Int, modifier: KeyModifier)] = [
        0: ("1", 0, .none),
        1: ("#1", 0, .shift),
        2: ("2", 1, .none),
        3: ("b3", 2, .control),
        4: ("3", 2, .none),
        5: ("4", 3, .none),
        6: ("#4", 3, .shift),
        7: ("5", 4, .none),
        8: ("#5", 4, .shift),
        9: ("6", 5, .none),
        10: ("b7", 6, .control),
        11: ("7", 6, .none)
    ]

    public static func row(for midiNote: Int, baseMidiNote: Int) -> PianoRow? {
        let offset = midiNote - baseMidiNote
        switch offset {
        case 0..<12: return .bas
        case 12..<24: return .mid
        case 24..<36: return .tre
        default: return nil
        }
    }

    public static func keys(for layoutMode: LayoutMode, baseMidiNote: Int) -> [PianoRow: [PianoKey]] {
        var result: [PianoRow: [PianoKey]] = [:]
        for row in PianoRow.allCases {
            let rowBase = baseMidiNote + (rowOffsets[row] ?? 0)
            let keys = rowKeys[row] ?? []
            switch layoutMode {
            case .nte21Natural:
                result[row] = naturalSemitones.enumerated().map { index, semitone in
                    PianoKey(
                        row: row,
                        semitone: semitone,
                        degreeLabel: naturalDegreeLabels[index],
                        noteName: noteNames[semitone],
                        keyboardKey: keys[index],
                        modifier: .none,
                        midiNote: rowBase + semitone
                    )
                }
            case .nte36Chromatic:
                result[row] = (0..<12).compactMap { semitone in
                    guard let entry = chromaticDegreeMap[semitone] else { return nil }
                    return PianoKey(
                        row: row,
                        semitone: semitone,
                        degreeLabel: entry.degree,
                        noteName: noteNames[semitone],
                        keyboardKey: keys[entry.naturalIndex],
                        modifier: entry.modifier,
                        midiNote: rowBase + semitone
                    )
                }
            }
        }
        return result
    }
}
