import Foundation

public struct MappedNoteGroup: Codable, Equatable, Identifiable {
    public var id: UUID
    public var startTime: TimeInterval
    public var events: [MappedNoteEvent]

    public init(id: UUID = UUID(), startTime: TimeInterval, events: [MappedNoteEvent]) {
        self.id = id
        self.startTime = startTime
        self.events = events
    }
}

public enum EventTimelineBuilder {
    public static func group(events: [MappedNoteEvent], threshold: TimeInterval) -> [MappedNoteGroup] {
        let sorted = events.sorted {
            if $0.startTime == $1.startTime {
                return $0.pianoKey.midiNote < $1.pianoKey.midiNote
            }
            return $0.startTime < $1.startTime
        }
        guard let first = sorted.first else { return [] }

        var groups: [MappedNoteGroup] = []
        var groupStart = first.startTime
        var current: [MappedNoteEvent] = []

        for event in sorted {
            if event.startTime - groupStart <= threshold {
                current.append(event)
            } else {
                groups.append(MappedNoteGroup(startTime: groupStart, events: orderedForInjection(current)))
                groupStart = event.startTime
                current = [event]
            }
        }
        if !current.isEmpty {
            groups.append(MappedNoteGroup(startTime: groupStart, events: orderedForInjection(current)))
        }
        return groups
    }

    public static func orderedForInjection(_ events: [MappedNoteEvent]) -> [MappedNoteEvent] {
        let modifierOrder: [KeyModifier: Int] = [.none: 0, .shift: 1, .control: 2]
        return events.sorted {
            let leftModifier = modifierOrder[$0.pianoKey.modifier] ?? 0
            let rightModifier = modifierOrder[$1.pianoKey.modifier] ?? 0
            if leftModifier != rightModifier {
                return leftModifier < rightModifier
            }
            if $0.pianoKey.row != $1.pianoKey.row {
                return rowOrder($0.pianoKey.row) < rowOrder($1.pianoKey.row)
            }
            return $0.pianoKey.midiNote < $1.pianoKey.midiNote
        }
    }

    private static func rowOrder(_ row: PianoRow) -> Int {
        switch row {
        case .bas: 0
        case .mid: 1
        case .tre: 2
        }
    }
}
