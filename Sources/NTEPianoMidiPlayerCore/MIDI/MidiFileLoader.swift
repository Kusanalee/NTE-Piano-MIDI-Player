import AudioToolbox
import Foundation

public enum MidiFileLoaderError: LocalizedError, Equatable {
    case couldNotCreateSequence(OSStatus)
    case couldNotLoadFile(OSStatus)
    case couldNotReadTrackCount(OSStatus)
    case couldNotReadTrack(Int, OSStatus)
    case couldNotCreateIterator(Int, OSStatus)

    public var errorDescription: String? {
        switch self {
        case .couldNotCreateSequence(let status):
            "Could not create MIDI sequence. OSStatus \(status)."
        case .couldNotLoadFile(let status):
            "Could not load MIDI file. OSStatus \(status)."
        case .couldNotReadTrackCount(let status):
            "Could not read MIDI track count. OSStatus \(status)."
        case .couldNotReadTrack(let index, let status):
            "Could not read MIDI track \(index). OSStatus \(status)."
        case .couldNotCreateIterator(let index, let status):
            "Could not create MIDI event iterator for track \(index). OSStatus \(status)."
        }
    }
}

public final class MidiFileLoader {
    public init() {}

    public func load(url: URL) throws -> MidiDocument {
        var sequence: MusicSequence?
        let createStatus = NewMusicSequence(&sequence)
        guard createStatus == noErr, let sequence else {
            throw MidiFileLoaderError.couldNotCreateSequence(createStatus)
        }
        defer { DisposeMusicSequence(sequence) }

        let loadStatus = MusicSequenceFileLoad(
            sequence,
            url as CFURL,
            .midiType,
            MusicSequenceLoadFlags(rawValue: 0)
        )
        guard loadStatus == noErr else {
            throw MidiFileLoaderError.couldNotLoadFile(loadStatus)
        }

        var trackCount: UInt32 = 0
        let countStatus = MusicSequenceGetTrackCount(sequence, &trackCount)
        guard countStatus == noErr else {
            throw MidiFileLoaderError.couldNotReadTrackCount(countStatus)
        }

        var allEvents: [MidiNoteEvent] = []
        var trackInfos: [MidiTrackInfo] = []
        var metaTempoChanges: [MidiTempoChange] = []
        var metaTimeSignatures: [MidiTimeSignature] = []

        for trackIndex in 0..<Int(trackCount) {
            var track: MusicTrack?
            let trackStatus = MusicSequenceGetIndTrack(sequence, UInt32(trackIndex), &track)
            guard trackStatus == noErr, let track else {
                throw MidiFileLoaderError.couldNotReadTrack(trackIndex, trackStatus)
            }

            let parsed = try parseTrack(track, trackIndex: trackIndex, sequence: sequence)
            allEvents.append(contentsOf: parsed.notes)
            trackInfos.append(parsed.info)
            metaTempoChanges.append(contentsOf: parsed.tempoChanges)
            metaTimeSignatures.append(contentsOf: parsed.timeSignatures)
        }

        allEvents.sort {
            if $0.startTime == $1.startTime {
                return $0.midiNote < $1.midiNote
            }
            return $0.startTime < $1.startTime
        }

        let tempoData = parseTempoAndTimeSignatureData(sequence: sequence)
        let tempoChanges = uniquedTempoChanges(tempoData.tempoChanges + metaTempoChanges)
        let timeSignatures = uniquedTimeSignatures(tempoData.timeSignatures + metaTimeSignatures)
        let duration = allEvents.map { $0.startTime + $0.duration }.max() ?? 0

        return MidiDocument(
            url: url,
            displayName: url.lastPathComponent,
            tracks: trackInfos,
            noteEvents: allEvents,
            tempoChanges: tempoChanges,
            timeSignatures: timeSignatures,
            duration: duration
        )
    }

    private struct ParsedTrack {
        var info: MidiTrackInfo
        var notes: [MidiNoteEvent]
        var tempoChanges: [MidiTempoChange]
        var timeSignatures: [MidiTimeSignature]
    }

    private func parseTrack(
        _ track: MusicTrack,
        trackIndex: Int,
        sequence: MusicSequence
    ) throws -> ParsedTrack {
        var iterator: MusicEventIterator?
        let iteratorStatus = NewMusicEventIterator(track, &iterator)
        guard iteratorStatus == noErr, let iterator else {
            throw MidiFileLoaderError.couldNotCreateIterator(trackIndex, iteratorStatus)
        }
        defer { DisposeMusicEventIterator(iterator) }

        var notes: [MidiNoteEvent] = []
        var trackName: String?
        var instrumentName: String?
        var firstChannel: UInt8?
        var firstProgram: UInt8?
        var tempoChanges: [MidiTempoChange] = []
        var timeSignatures: [MidiTimeSignature] = []

        var hasEvent = DarwinBoolean(false)
        MusicEventIteratorHasCurrentEvent(iterator, &hasEvent)

        while hasEvent.boolValue {
            var beat = MusicTimeStamp()
            var eventType = MusicEventType()
            var eventData: UnsafeRawPointer?
            var eventDataSize: UInt32 = 0
            MusicEventIteratorGetEventInfo(iterator, &beat, &eventType, &eventData, &eventDataSize)

            if eventType == kMusicEventType_MIDINoteMessage, let eventData {
                let message = eventData.assumingMemoryBound(to: MIDINoteMessage.self).pointee
                let startSeconds = seconds(forBeat: beat, sequence: sequence)
                let endSeconds = seconds(forBeat: beat + MusicTimeStamp(message.duration), sequence: sequence)
                firstChannel = firstChannel ?? message.channel
                notes.append(
                    MidiNoteEvent(
                        midiNote: message.note,
                        velocity: message.velocity,
                        startTime: startSeconds,
                        duration: max(0.001, endSeconds - startSeconds),
                        channel: message.channel,
                        trackIndex: trackIndex
                    )
                )
            } else if eventType == kMusicEventType_MIDIChannelMessage, let eventData {
                let message = eventData.assumingMemoryBound(to: MIDIChannelMessage.self).pointee
                let status = message.status & 0xF0
                if status == 0xC0 {
                    firstProgram = firstProgram ?? message.data1
                    firstChannel = firstChannel ?? (message.status & 0x0F)
                }
            } else if eventType == kMusicEventType_Meta, let eventData {
                let meta = parseMetaEvent(eventData)
                if meta.type == 0x03, trackName == nil {
                    trackName = meta.string
                } else if meta.type == 0x04, instrumentName == nil {
                    instrumentName = meta.string
                } else if meta.type == 0x51, meta.bytes.count >= 3 {
                    let microsecondsPerQuarter =
                        (Int(meta.bytes[0]) << 16) |
                        (Int(meta.bytes[1]) << 8) |
                        Int(meta.bytes[2])
                    if microsecondsPerQuarter > 0 {
                        tempoChanges.append(
                            MidiTempoChange(
                                beat: beat,
                                seconds: seconds(forBeat: beat, sequence: sequence),
                                bpm: 60_000_000 / Double(microsecondsPerQuarter)
                            )
                        )
                    }
                } else if meta.type == 0x58, meta.bytes.count >= 2 {
                    let numerator = Int(meta.bytes[0])
                    let denominator = Int(pow(2.0, Double(meta.bytes[1])))
                    timeSignatures.append(
                        MidiTimeSignature(beat: beat, numerator: numerator, denominator: denominator)
                    )
                }
            }

            MusicEventIteratorNextEvent(iterator)
            MusicEventIteratorHasCurrentEvent(iterator, &hasEvent)
        }

        let fallbackName = notes.isEmpty ? "Meta track \(trackIndex + 1)" : "Track \(trackIndex + 1)"
        let info = MidiTrackInfo(
            trackIndex: trackIndex,
            name: nonEmpty(trackName) ?? fallbackName,
            channel: firstChannel,
            instrumentProgram: firstProgram,
            instrumentName: nonEmpty(instrumentName),
            noteCount: notes.count
        )
        return ParsedTrack(
            info: info,
            notes: notes,
            tempoChanges: tempoChanges,
            timeSignatures: timeSignatures
        )
    }

    private func parseTempoAndTimeSignatureData(
        sequence: MusicSequence
    ) -> (tempoChanges: [MidiTempoChange], timeSignatures: [MidiTimeSignature]) {
        var tempoTrack: MusicTrack?
        guard MusicSequenceGetTempoTrack(sequence, &tempoTrack) == noErr, let tempoTrack else {
            return ([MidiTempoChange(beat: 0, seconds: 0, bpm: 120)], [])
        }

        var iterator: MusicEventIterator?
        guard NewMusicEventIterator(tempoTrack, &iterator) == noErr, let iterator else {
            return ([MidiTempoChange(beat: 0, seconds: 0, bpm: 120)], [])
        }
        defer { DisposeMusicEventIterator(iterator) }

        var tempoChanges: [MidiTempoChange] = []
        var timeSignatures: [MidiTimeSignature] = []
        var hasEvent = DarwinBoolean(false)
        MusicEventIteratorHasCurrentEvent(iterator, &hasEvent)

        while hasEvent.boolValue {
            var beat = MusicTimeStamp()
            var eventType = MusicEventType()
            var eventData: UnsafeRawPointer?
            var eventDataSize: UInt32 = 0
            MusicEventIteratorGetEventInfo(iterator, &beat, &eventType, &eventData, &eventDataSize)

            if eventType == kMusicEventType_ExtendedTempo, let eventData {
                let tempo = eventData.assumingMemoryBound(to: ExtendedTempoEvent.self).pointee
                tempoChanges.append(
                    MidiTempoChange(
                        beat: beat,
                        seconds: seconds(forBeat: beat, sequence: sequence),
                        bpm: Double(tempo.bpm)
                    )
                )
            } else if eventType == kMusicEventType_Meta, let eventData {
                let meta = parseMetaEvent(eventData)
                if meta.type == 0x58, meta.bytes.count >= 2 {
                    let numerator = Int(meta.bytes[0])
                    let denominator = Int(pow(2.0, Double(meta.bytes[1])))
                    timeSignatures.append(
                        MidiTimeSignature(beat: beat, numerator: numerator, denominator: denominator)
                    )
                }
            }

            MusicEventIteratorNextEvent(iterator)
            MusicEventIteratorHasCurrentEvent(iterator, &hasEvent)
        }

        if tempoChanges.isEmpty {
            tempoChanges.append(MidiTempoChange(beat: 0, seconds: 0, bpm: 120))
        }
        return (tempoChanges, timeSignatures)
    }

    private func seconds(forBeat beat: MusicTimeStamp, sequence: MusicSequence) -> TimeInterval {
        var seconds = MusicTimeStamp()
        let status = MusicSequenceGetSecondsForBeats(sequence, beat, &seconds)
        guard status == noErr else { return 0 }
        return seconds
    }

    private func parseMetaEvent(_ pointer: UnsafeRawPointer) -> (type: UInt8, bytes: [UInt8], string: String?) {
        let meta = pointer.assumingMemoryBound(to: MIDIMetaEvent.self).pointee
        let length = Int(meta.dataLength)
        let dataStart = pointer.advanced(by: 8).assumingMemoryBound(to: UInt8.self)
        let bytes = Array(UnsafeBufferPointer(start: dataStart, count: length))
        let string = String(bytes: bytes, encoding: .utf8)
            ?? String(bytes: bytes, encoding: .macOSRoman)
        return (meta.metaEventType, bytes, string)
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func uniquedTempoChanges(_ changes: [MidiTempoChange]) -> [MidiTempoChange] {
        var seen = Set<String>()
        return changes.sorted { $0.beat < $1.beat }.filter { change in
            let key = "\(String(format: "%.6f", change.beat))-\(String(format: "%.3f", change.bpm))"
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }
    }

    private func uniquedTimeSignatures(_ signatures: [MidiTimeSignature]) -> [MidiTimeSignature] {
        var seen = Set<String>()
        return signatures.sorted { $0.beat < $1.beat }.filter { signature in
            let key = "\(String(format: "%.6f", signature.beat))-\(signature.numerator)-\(signature.denominator)"
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }
    }
}
