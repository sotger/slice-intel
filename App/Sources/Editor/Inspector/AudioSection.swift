//
//  AudioSection.swift
//  Slice
//
//  Created by rit3zh CX on 10/9/26.
//

import SliceCore
import SwiftUI

struct AudioSection: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        let p = editor.project
        let hasMic = p.clips.contains { $0.micFile != nil }
        let hasScreenAudio = p.clips.contains { $0.screenAudioFile != nil }
        PanelSection("Voice & screen audio") {
            if hasMic { row("Microphone", icon: "mic", value: $editor.project.micVolume) }
            if hasScreenAudio { row("Screen audio", icon: "speaker.wave.2", value: $editor.project.screenAudioVolume) }
            if !hasMic && !hasScreenAudio { PanelNote("No audio was recorded for these takes.") }
            PanelNote("Exports keep the mix's peaks under −1 dB, so voice, screen audio and music never clip together.")
        }
        PanelSection("Tracks") {
            ForEach(p.audioTracks) { track in
                trackRow(track)
            }
            if p.audioTracks.isEmpty {
                PanelNote("Add the lavalier recording, a second take or a call as its own track. "
                    + "It gets its own volume and is mixed into the export; it can be moved, trimmed and removed on the timeline.")
            }
            Button { editor.chooseAudioTrackFiles() } label: {
                Label("Add audio track…", systemImage: "waveform.badge.plus")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .help("Choose an audio file to put on its own track")
        }
    }

    private func row(_ title: String, icon: String, value: Binding<Double>) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button {
                withAnimation(.snappy) { value.wrappedValue = value.wrappedValue > 0 ? 0 : 1 }
            } label: {
                Image(systemName: value.wrappedValue > 0 ? icon : "speaker.slash")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(IconButtonStyle(selected: value.wrappedValue == 0, size: 30, iconSize: 13))
            .help(value.wrappedValue > 0 ? "Mute \(title.lowercased())" : "Unmute")
            PanelSlider(title, value: value, in: 0 ... 1.5, default: 1) { $0 > 0 ? "\(Int(($0 * 100).rounded()))%" : "Muted" }
        }
    }

    private func trackRow(_ track: AudioTrack) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button {
                editor.updateAudioTrack(track.id) { $0.muted.toggle() }
            } label: {
                Image(systemName: track.muted ? "speaker.slash" : "waveform")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(IconButtonStyle(selected: track.muted, size: 30, iconSize: 13))
            .help(track.muted ? "Unmute \(track.name)" : "Mute \(track.name)")
            PanelSlider(track.name, value: Binding(get: { track.volume },
                                                  set: { value in editor.updateAudioTrack(track.id) { $0.volume = value } }),
                        in: 0 ... 1.5, default: 1) { $0 > 0 ? "\(Int(($0 * 100).rounded()))%" : "Muted" }
            Button { editor.removeAudioTrack(track.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(IconButtonStyle(size: 30, iconSize: 11))
            .help("Remove this track and its clips")
        }
    }
}
