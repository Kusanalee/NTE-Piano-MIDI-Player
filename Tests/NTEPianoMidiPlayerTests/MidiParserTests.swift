import Foundation
import XCTest
@testable import NTEPianoMidiPlayerCore

final class MidiParserTests: XCTestCase {
    func testLoadsTracksTempoTimeSignatureAndNoteTiming() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mid")
        try makeFixtureMidiFile().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let document = try MidiFileLoader().load(url: url)

        XCTAssertEqual(document.noteEvents.count, 1)
        XCTAssertEqual(document.noteEvents[0].midiNote, 60)
        XCTAssertEqual(document.noteEvents[0].channel, 0)
        XCTAssertGreaterThanOrEqual(document.noteEvents[0].trackIndex, 0)
        XCTAssertEqual(document.noteEvents[0].startTime, 0, accuracy: 0.001)
        XCTAssertEqual(document.noteEvents[0].duration, 0.5, accuracy: 0.010)
        XCTAssertTrue(document.tracks.contains { $0.noteCount == 1 })
        XCTAssertTrue(document.tempoChanges.contains { abs($0.bpm - 120) < 0.001 })
        XCTAssertTrue(document.timeSignatures.contains { $0.numerator == 4 && $0.denominator == 4 })
    }

    private func makeFixtureMidiFile() -> Data {
        var data = Data()
        data.append(bytes: [0x4D, 0x54, 0x68, 0x64])
        data.appendUInt32BE(6)
        data.appendUInt16BE(1)
        data.appendUInt16BE(2)
        data.appendUInt16BE(480)

        let tempoTrack: [UInt8] = [
            0x00, 0xFF, 0x03, 0x05, 0x54, 0x65, 0x6D, 0x70, 0x6F,
            0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20,
            0x00, 0xFF, 0x58, 0x04, 0x04, 0x02, 0x18, 0x08,
            0x00, 0xFF, 0x2F, 0x00
        ]
        data.appendTrack(tempoTrack)

        let noteTrack: [UInt8] = [
            0x00, 0xFF, 0x03, 0x05, 0x50, 0x69, 0x61, 0x6E, 0x6F,
            0x00, 0xC0, 0x00,
            0x00, 0x90, 0x3C, 0x40,
            0x83, 0x60, 0x80, 0x3C, 0x00,
            0x00, 0xFF, 0x2F, 0x00
        ]
        data.appendTrack(noteTrack)
        return data
    }
}

private extension Data {
    mutating func append(bytes: [UInt8]) {
        append(contentsOf: bytes)
    }

    mutating func appendUInt16BE(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendTrack(_ bytes: [UInt8]) {
        append(bytes: [0x4D, 0x54, 0x72, 0x6B])
        appendUInt32BE(UInt32(bytes.count))
        append(bytes: bytes)
    }
}
