import Foundation

public struct PianoSheetOptions: Codable, Equatable {
    public var showNoteNames: Bool
    public var showScaleDegrees: Bool
    public var showKeyboardKeys: Bool
    public var delimiter: String
    public var lineLength: Int
    public var useChordBrackets: Bool

    public init(
        showNoteNames: Bool = false,
        showScaleDegrees: Bool = true,
        showKeyboardKeys: Bool = true,
        delimiter: String = " ",
        lineLength: Int = 12,
        useChordBrackets: Bool = true
    ) {
        self.showNoteNames = showNoteNames
        self.showScaleDegrees = showScaleDegrees
        self.showKeyboardKeys = showKeyboardKeys
        self.delimiter = delimiter
        self.lineLength = lineLength
        self.useChordBrackets = useChordBrackets
    }
}

public struct PianoSheetExporter {
    public init() {}

    public func export(events: [MappedNoteEvent], options: PianoSheetOptions = PianoSheetOptions()) -> String {
        guard !events.isEmpty else { return "" }
        let groups = EventTimelineBuilder.group(events: events, threshold: 0.010)
        let tokens = groups.map { group in
            let noteTokens = group.events.map { token(for: $0, options: options) }
            if noteTokens.count > 1, options.useChordBrackets {
                return "[\(noteTokens.joined(separator: options.delimiter))]"
            }
            return noteTokens.joined(separator: options.delimiter)
        }

        let lineLength = max(1, options.lineLength)
        var lines: [String] = []
        var current: [String] = []
        for token in tokens {
            current.append(token)
            if current.count >= lineLength {
                lines.append(current.joined(separator: options.delimiter))
                current.removeAll()
            }
        }
        if !current.isEmpty {
            lines.append(current.joined(separator: options.delimiter))
        }
        return lines.joined(separator: "\n")
    }

    private func token(for event: MappedNoteEvent, options: PianoSheetOptions) -> String {
        let keyTokens = event.pianoKeys.map { key in
            var parts: [String] = []
            if options.showNoteNames {
                parts.append(key.noteName)
            }
            if options.showScaleDegrees {
                parts.append("\(key.row.rawValue)\(key.degreeLabel)")
            }
            if options.showKeyboardKeys {
                parts.append(key.keyboardLabel)
            }
            if parts.isEmpty {
                return key.keyboardLabel
            }
            return parts.joined(separator: ":")
        }
        return keyTokens.joined(separator: "+")
    }
}
