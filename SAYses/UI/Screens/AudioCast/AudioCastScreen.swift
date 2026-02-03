//
//  AudioCastScreen.swift
//  SAYses
//
//  UI for AudioCast playback feature
//

import SwiftUI

struct AudioCastScreen: View {
    let channel: Channel
    @ObservedObject var mumbleService: MumbleService
    @State private var viewModel: AudioCastViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showError = false

    init(channel: Channel, mumbleService: MumbleService) {
        self.channel = channel
        self.mumbleService = mumbleService
        self._viewModel = State(initialValue: AudioCastViewModel(
            channelId: channel.id,
            mumbleService: mumbleService
        ))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Channel info
                channelInfo

                Divider()

                // Playback controls
                playbackControls
                    .padding()

                Divider()

                // AudioCast list
                if viewModel.isLoading && viewModel.audioCasts.isEmpty {
                    Spacer()
                    ProgressView()
                        .scaleEffect(1.5)
                    Spacer()
                } else if viewModel.audioCasts.isEmpty {
                    emptyState
                } else {
                    audioCastList
                }
            }
            .navigationTitle("AudioCast")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fertig") {
                        dismiss()
                    }
                }
            }
            .task {
                await viewModel.loadAudioCasts()
            }
            .onChange(of: viewModel.errorMessage) { _, newValue in
                showError = newValue != nil
            }
            .alert("Fehler", isPresented: $showError) {
                Button("OK") {
                    viewModel.clearError()
                }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
        }
    }

    // MARK: - Channel Info

    private var channelInfo: some View {
        HStack {
            Image(systemName: "person.3.fill")
                .font(.title2)
                .foregroundStyle(.secondary)

            Text(channel.name)
                .font(.headline)

            Spacer()
        }
        .padding()
        .background(Color(.systemGray6))
    }

    // MARK: - Playback Controls

    private var playbackControls: some View {
        let isPlaybackActive = viewModel.isPlaying || viewModel.isPaused
        let hasSelection = !viewModel.selectedIds.isEmpty

        return HStack(spacing: 12) {
            if isPlaybackActive {
                // Stop button (red)
                Button(action: {
                    Task { await viewModel.stop() }
                }) {
                    HStack {
                        Image(systemName: "stop.fill")
                        Text("Abbrechen")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.red)
                    .foregroundStyle(.white)
                    .cornerRadius(10)
                }

                // Pause/Resume button
                Button(action: {
                    Task { await viewModel.togglePause() }
                }) {
                    HStack {
                        Image(systemName: viewModel.isPaused ? "play.fill" : "pause.fill")
                        Text(viewModel.isPaused ? "Fortsetzen" : "Pause")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .cornerRadius(10)
                }
            } else {
                // Play button
                Button(action: {
                    Task { await viewModel.play() }
                }) {
                    HStack {
                        if viewModel.isLoading {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        } else {
                            Image(systemName: "play.fill")
                        }
                        Text("Abspielen")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(hasSelection && !viewModel.isLoading ? Color.accentColor : Color.gray)
                    .foregroundStyle(.white)
                    .cornerRadius(10)
                }
                .disabled(!hasSelection || viewModel.isLoading)
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 50))
                .foregroundStyle(.secondary)

            Text("Keine AudioCasts verfügbar")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("In diesem Kanal sind keine AudioCasts vorhanden.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Spacer()
        }
    }

    // MARK: - AudioCast List

    private var audioCastList: some View {
        List {
            ForEach(viewModel.audioCasts) { audioCast in
                AudioCastListItem(
                    audioCast: audioCast,
                    isSelected: viewModel.selectedIds.contains(audioCast.id),
                    isCurrentlyPlaying: audioCast.id == viewModel.playbackStatus?.currentAudiocastId,
                    onToggle: {
                        viewModel.toggleSelection(audioCast.id)
                    }
                )
            }
        }
        .listStyle(.plain)
    }
}

// MARK: - AudioCast List Item

struct AudioCastListItem: View {
    let audioCast: AudioCastItem
    let isSelected: Bool
    let isCurrentlyPlaying: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                // Checkbox
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)

                // Title and duration
                VStack(alignment: .leading, spacing: 2) {
                    Text(audioCast.title)
                        .font(.body)
                        .foregroundStyle(isCurrentlyPlaying ? Color.accentColor : .primary)
                        .lineLimit(2)

                    Text(audioCast.formattedDuration)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Playing indicator
                if isCurrentlyPlaying {
                    Image(systemName: "play.fill")
                        .font(.body)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
    }
}

// MARK: - Preview

#Preview {
    AudioCastScreen(
        channel: Channel(id: 1, name: "Test Channel", position: 0),
        mumbleService: MumbleService()
    )
}
