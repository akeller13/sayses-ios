#pragma once

#include <functional>
#include <memory>
#include <string>
#include <vector>
#include <cstdint>

namespace sayses {

struct Channel {
    uint32_t id;
    uint32_t parentId;
    std::string name;
    std::string description;
    int32_t position;
    bool temporary;
    std::vector<uint32_t> linkedChannels;
};

struct User {
    uint32_t session;
    uint32_t channelId;
    std::string name;
    std::string comment;
    bool mute;
    bool deaf;
    bool selfMute;
    bool selfDeaf;
    bool suppress;
    bool recording;
    int32_t priority;
};

struct ServerInfo {
    std::string welcomeMessage;
    uint32_t maxBandwidth;
    uint32_t maxUsers;
    bool allowHtml;
    std::string serverVersion;
};

enum class ConnectionState {
    Disconnected,
    Connecting,
    Connected,
    Synchronizing,
    Synchronized,
    Disconnecting,
    Failed
};

enum class RejectReason {
    None,
    WrongVersion,
    InvalidUsername,
    WrongPassword,
    UsernameInUse,
    ServerFull,
    NoCertificate,
    AuthenticatorFail
};

/**
 * Mumble protocol client for voice communication.
 * Handles connection, authentication, and message passing.
 */
class MumbleClient {
public:
    // Callbacks
    using StateCallback = std::function<void(ConnectionState state)>;
    using ChannelCallback = std::function<void(const Channel& channel)>;
    using UserCallback = std::function<void(const User& user)>;
    using AudioCallback = std::function<void(uint32_t session, const int16_t* data, size_t frames)>;
    using RejectCallback = std::function<void(RejectReason reason, const std::string& message)>;
    using ServerInfoCallback = std::function<void(const ServerInfo& info)>;

    struct Config {
        std::string host;
        int port = 64738;
        std::string username;
        std::string password;
        std::string certificatePath;
        std::string privateKeyPath;
        bool validateServerCertificate = false;
    };

    /**
     * Create a new Mumble client instance.
     */
    static std::unique_ptr<MumbleClient> create();

    virtual ~MumbleClient() = default;

    /**
     * Connect to a Mumble server.
     * @param config Connection configuration
     * @return true if connection attempt started
     */
    virtual bool connect(const Config& config) = 0;

    /**
     * Disconnect from the server.
     */
    virtual void disconnect() = 0;

    /**
     * Get current connection state.
     */
    virtual ConnectionState getState() const = 0;

    /**
     * Join a channel by ID.
     * @param channelId The channel to join
     */
    virtual void joinChannel(uint32_t channelId) = 0;

    /**
     * Send audio data to the server.
     * @param data PCM audio data (16-bit mono)
     * @param frames Number of frames
     */
    virtual void sendAudio(const int16_t* data, size_t frames) = 0;

    /**
     * Set self mute state.
     */
    virtual void setSelfMute(bool mute) = 0;

    /**
     * Set self deaf state.
     */
    virtual void setSelfDeaf(bool deaf) = 0;

    /**
     * Get the local user session ID.
     */
    virtual uint32_t getLocalSession() const = 0;

    /**
     * Get all channels.
     */
    virtual std::vector<Channel> getChannels() const = 0;

    /**
     * Get all users.
     */
    virtual std::vector<User> getUsers() const = 0;

    /**
     * Get users in a specific channel.
     */
    virtual std::vector<User> getUsersInChannel(uint32_t channelId) const = 0;

    // Callback setters
    virtual void setStateCallback(StateCallback callback) = 0;
    virtual void setChannelAddedCallback(ChannelCallback callback) = 0;
    virtual void setChannelUpdatedCallback(ChannelCallback callback) = 0;
    virtual void setChannelRemovedCallback(ChannelCallback callback) = 0;
    virtual void setUserAddedCallback(UserCallback callback) = 0;
    virtual void setUserUpdatedCallback(UserCallback callback) = 0;
    virtual void setUserRemovedCallback(UserCallback callback) = 0;
    virtual void setAudioCallback(AudioCallback callback) = 0;
    virtual void setRejectCallback(RejectCallback callback) = 0;
    virtual void setServerInfoCallback(ServerInfoCallback callback) = 0;

protected:
    MumbleClient() = default;
};

}  // namespace sayses
