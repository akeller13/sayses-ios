//
//  AudioCastModels.swift
//  SAYses
//
//  Data models for AudioCast playback feature
//

import Foundation

// MARK: - AudioCast Item

/// Single AudioCast item from the server
struct AudioCastItem: Codable, Identifiable {
    let id: String
    let title: String
    let durationSeconds: Int
    let position: Int

    enum CodingKeys: String, CodingKey {
        case id, title, position
        case durationSeconds = "duration_seconds"
    }

    /// Format duration as mm:ss
    var formattedDuration: String {
        let minutes = durationSeconds / 60
        let seconds = durationSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Playback Status

/// Current playback status from the server
struct PlaybackStatus: Codable {
    let isPlaying: Bool
    let isPaused: Bool
    let playbackId: String?
    let currentAudiocastId: String?
    let currentPositionSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case isPlaying = "is_playing"
        case isPaused = "is_paused"
        case playbackId = "playback_id"
        case currentAudiocastId = "current_audiocast_id"
        case currentPositionSeconds = "current_position_seconds"
    }
}

// MARK: - API Responses

/// Response from GET /api/mobile/audiocast/list
struct AudioCastListResponse: Codable {
    let success: Bool
    let audiocasts: [AudioCastItem]
    let playbackStatus: PlaybackStatus

    enum CodingKeys: String, CodingKey {
        case success, audiocasts
        case playbackStatus = "playback_status"
    }
}

// MARK: - Play Request/Response

/// Request body for POST /api/mobile/audiocast/play
struct AudioCastPlayRequest: Codable {
    let channelId: Int
    let audiocastIds: [String]

    enum CodingKeys: String, CodingKey {
        case channelId = "channel_id"
        case audiocastIds = "audiocast_ids"
    }
}

/// Response from POST /api/mobile/audiocast/play
struct AudioCastPlayResponse: Codable {
    let success: Bool
    let message: String
    let playbackId: String?
    let totalDurationSeconds: Int?
    let audiocastCount: Int?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case success, message, error
        case playbackId = "playback_id"
        case totalDurationSeconds = "total_duration_seconds"
        case audiocastCount = "audiocast_count"
    }
}

// MARK: - Pause Request/Response

/// Request body for POST /api/mobile/audiocast/pause
struct AudioCastPauseRequest: Codable {
    let channelId: Int
    let playbackId: String

    enum CodingKeys: String, CodingKey {
        case channelId = "channel_id"
        case playbackId = "playback_id"
    }
}

/// Response from POST /api/mobile/audiocast/pause
struct AudioCastPauseResponse: Codable {
    let success: Bool
    let message: String
    let playbackStatus: PlaybackStatus?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case success, message, error
        case playbackStatus = "playback_status"
    }
}

// MARK: - Stop Request/Response

/// Request body for POST /api/mobile/audiocast/stop
struct AudioCastStopRequest: Codable {
    let channelId: Int
    let playbackId: String

    enum CodingKeys: String, CodingKey {
        case channelId = "channel_id"
        case playbackId = "playback_id"
    }
}

/// Response from POST /api/mobile/audiocast/stop
struct AudioCastStopResponse: Codable {
    let success: Bool
    let message: String
    let playbackStatus: PlaybackStatus?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case success, message, error
        case playbackStatus = "playback_status"
    }
}
