//
//  AudioTrackTests.swift
//  SliceCoreTests
//
//  Imported audio tracks: what the project keeps, what the mix hears, how clips move and trim.
//

@testable import SliceCore
import XCTest

final class AudioTrackTests: XCTestCase {
    private func project(seconds: Double = 10) -> Project {
        var p = Project(name: "Tracks")
        p.clips = [Clip(screenFile: "clips/a/screen.mov", duration: seconds,
                        screenPixelSize: CGSize(width: 100, height: 100), captureRect: .zero)]
        return p
    }

    private func clip(start: Double = 2, end: Double = 6, sourceDuration: Double = 20) -> AudioClip {
        AudioClip(source: "audio/lav.m4a", name: "lav", start: start, end: end, sourceDuration: sourceDuration)
    }

    func testRoundTripKeepsTracks() throws {
        var p = project()
        p.audioTracks = [AudioTrack(name: "Lav", volume: 0.7, muted: true, clips: [clip()])]
        let back = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back.audioTracks, p.audioTracks)
    }

    func testOlderProjectWithoutTracksStillOpens() throws {
        var p = project()
        p.audioTracks = []
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as? [String: Any])
        json.removeValue(forKey: "audioTracks")
        let data = try JSONSerialization.data(withJSONObject: json)
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: data).audioTracks, [])
    }

    func testEnvelopeIsTheTrackVolumeInsideAndSilentOutside() {
        let track = AudioTrack(name: "Lav", volume: 0.5, clips: [clip()])
        let p = project()
        let envelope = p.audioTrackEnvelope(track)
        XCTAssertEqual(envelope.value(at: 0), 0)
        XCTAssertEqual(envelope.value(at: 4), 0.5, accuracy: 0.001)
        XCTAssertEqual(envelope.value(at: 6), 0, accuracy: 0.001)
        XCTAssertEqual(envelope.value(at: 9), 0)
    }

    func testMutedTrackIsSilent() {
        let track = AudioTrack(name: "Lav", volume: 1, muted: true, clips: [clip()])
        XCTAssertEqual(project().audioTrackEnvelope(track).value(at: 4), 0)
    }

    func testMoveStaysInsideTheTimeline() {
        var p = project()
        p.audioTracks = [AudioTrack(name: "Lav", clips: [clip()])]
        let id = p.audioTracks[0].clips[0].id
        p.moveAudioClip(p.audioTracks[0].id, clip: id, to: 100)
        XCTAssertEqual(p.audioTracks[0].clips[0].start, 6)
        p.moveAudioClip(p.audioTracks[0].id, clip: id, to: -100)
        XCTAssertEqual(p.audioTracks[0].clips[0].start, 0)
    }

    func testMoveDoesNotCrossAnotherClipOnTheSameTrack() {
        var p = project()
        p.audioTracks = [AudioTrack(name: "Lav", clips: [clip(start: 0, end: 2), clip(start: 5, end: 7)])]
        let track = p.audioTracks[0].id
        let second = p.audioTracks[0].clips[1].id
        p.moveAudioClip(track, clip: second, to: 0)
        XCTAssertEqual(p.audioTracks[0].clips[1].start, 2, accuracy: 0.001)
    }

    func testTrimmingTheStartMovesIntoTheFile() {
        var p = project()
        p.audioTracks = [AudioTrack(name: "Lav", clips: [clip()])]
        let track = p.audioTracks[0].id
        let id = p.audioTracks[0].clips[0].id
        p.trimAudioClip(track, clip: id, start: 3)
        XCTAssertEqual(p.audioTracks[0].clips[0].start, 3)
        XCTAssertEqual(p.audioTracks[0].clips[0].offset, 1, accuracy: 0.001)
        XCTAssertEqual(p.audioTracks[0].clips[0].end, 6)
    }

    func testTrimmingTheEndStaysInsideTheTimeline() {
        var p = project()
        p.audioTracks = [AudioTrack(name: "Lav", clips: [clip(start: 2, end: 8, sourceDuration: 20)])]
        let track = p.audioTracks[0].id
        let id = p.audioTracks[0].clips[0].id
        p.trimAudioClip(track, clip: id, end: 100)
        XCTAssertEqual(p.audioTracks[0].clips[0].end, 10)
    }

    func testTrimmingTheEndStaysInsideItsFile() {
        var p = project(seconds: 30)
        p.audioTracks = [AudioTrack(name: "Lav", clips: [clip(start: 2, end: 8, sourceDuration: 20)])]
        let track = p.audioTracks[0].id
        let id = p.audioTracks[0].clips[0].id
        p.trimAudioClip(track, clip: id, end: 100)
        XCTAssertEqual(p.audioTracks[0].clips[0].end, 22, accuracy: 0.001)
    }
}
