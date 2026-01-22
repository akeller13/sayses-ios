/**
 * MumbleClient Implementation
 * Based on Mumble 1.3.x protocol specification
 */

#include "mumble_client.h"
#include "Mumble.pb.h"

#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/x509.h>
#include <openssl/pem.h>
#include <openssl/pkcs12.h>

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <unistd.h>

#include <thread>
#include <mutex>
#include <atomic>
#include <queue>
#include <chrono>
#include <cstring>

namespace sayses {

// Mumble protocol message types (must match server ordering)
enum class MessageType : uint16_t {
    Version = 0,
    UDPTunnel = 1,
    Authenticate = 2,
    Ping = 3,
    Reject = 4,
    ServerSync = 5,
    ChannelRemove = 6,
    ChannelState = 7,
    UserRemove = 8,
    UserState = 9,
    BanList = 10,
    TextMessage = 11,
    PermissionDenied = 12,
    ACL = 13,
    QueryUsers = 14,
    CryptSetup = 15,
    ContextActionModify = 16,
    ContextAction = 17,
    UserList = 18,
    VoiceTarget = 19,
    PermissionQuery = 20,
    CodecVersion = 21,
    UserStats = 22,
    RequestBlob = 23,
    ServerConfig = 24,
    SuggestConfig = 25
};

// Mumble version encoding: Major << 16 | Minor << 8 | Patch
constexpr uint32_t MUMBLE_VERSION = (1 << 16) | (3 << 8) | 0;

class MumbleClientImpl : public MumbleClient {
public:
    MumbleClientImpl();
    ~MumbleClientImpl() override;

    bool connect(const Config& config) override;
    void disconnect() override;
    ConnectionState getState() const override;
    void joinChannel(uint32_t channelId) override;
    void sendAudio(const int16_t* data, size_t frames) override;
    void setSelfMute(bool mute) override;
    void setSelfDeaf(bool deaf) override;
    uint32_t getLocalSession() const override;
    std::vector<Channel> getChannels() const override;
    std::vector<User> getUsers() const override;
    std::vector<User> getUsersInChannel(uint32_t channelId) const override;

    void setStateCallback(StateCallback callback) override { stateCallback_ = std::move(callback); }
    void setChannelAddedCallback(ChannelCallback callback) override { channelAddedCallback_ = std::move(callback); }
    void setChannelUpdatedCallback(ChannelCallback callback) override { channelUpdatedCallback_ = std::move(callback); }
    void setChannelRemovedCallback(ChannelCallback callback) override { channelRemovedCallback_ = std::move(callback); }
    void setUserAddedCallback(UserCallback callback) override { userAddedCallback_ = std::move(callback); }
    void setUserUpdatedCallback(UserCallback callback) override { userUpdatedCallback_ = std::move(callback); }
    void setUserRemovedCallback(UserCallback callback) override { userRemovedCallback_ = std::move(callback); }
    void setAudioCallback(AudioCallback callback) override { audioCallback_ = std::move(callback); }
    void setRejectCallback(RejectCallback callback) override { rejectCallback_ = std::move(callback); }
    void setServerInfoCallback(ServerInfoCallback callback) override { serverInfoCallback_ = std::move(callback); }

private:
    // SSL/TLS
    bool initSSL(const Config& config);
    bool loadCertificate(const std::string& path, const std::string& keyPath);
    bool loadPKCS12(const std::string& p12Data, const std::string& password);
    void cleanupSSL();

    // Networking
    bool connectSocket(const std::string& host, int port);
    void receiveLoop();
    void pingLoop();

    // Protocol
    bool sendMessage(MessageType type, const google::protobuf::Message& message);
    bool sendRawMessage(MessageType type, const uint8_t* data, size_t length);
    void handleMessage(MessageType type, const uint8_t* data, size_t length);

    // Message handlers
    void handleVersion(const uint8_t* data, size_t length);
    void handleReject(const uint8_t* data, size_t length);
    void handleServerSync(const uint8_t* data, size_t length);
    void handleChannelState(const uint8_t* data, size_t length);
    void handleChannelRemove(const uint8_t* data, size_t length);
    void handleUserState(const uint8_t* data, size_t length);
    void handleUserRemove(const uint8_t* data, size_t length);
    void handlePing(const uint8_t* data, size_t length);
    void handleCryptSetup(const uint8_t* data, size_t length);
    void handleServerConfig(const uint8_t* data, size_t length);
    void handleCodecVersion(const uint8_t* data, size_t length);
    void handlePermissionQuery(const uint8_t* data, size_t length);
    void handleUDPTunnel(const uint8_t* data, size_t length);

    // State
    void setState(ConnectionState state);
    void sendVersion();
    void sendAuthenticate(const std::string& username, const std::string& password);
    void sendPing();

    // Member variables
    std::atomic<ConnectionState> state_{ConnectionState::Disconnected};
    std::atomic<bool> running_{false};
    std::atomic<uint32_t> localSession_{0};

    // SSL
    SSL_CTX* sslCtx_{nullptr};
    SSL* ssl_{nullptr};
    int socket_{-1};

    // Threads
    std::thread receiveThread_;
    std::thread pingThread_;
    std::mutex sendMutex_;

    // Data
    mutable std::mutex dataMutex_;
    std::map<uint32_t, Channel> channels_;
    std::map<uint32_t, User> users_;
    ServerInfo serverInfo_;
    Config config_;

    // Crypto
    uint8_t cryptKey_[16];
    uint8_t clientNonce_[16];
    uint8_t serverNonce_[16];
    bool cryptSetup_{false};

    // Callbacks
    StateCallback stateCallback_;
    ChannelCallback channelAddedCallback_;
    ChannelCallback channelUpdatedCallback_;
    ChannelCallback channelRemovedCallback_;
    UserCallback userAddedCallback_;
    UserCallback userUpdatedCallback_;
    UserCallback userRemovedCallback_;
    AudioCallback audioCallback_;
    RejectCallback rejectCallback_;
    ServerInfoCallback serverInfoCallback_;
};

// Create implementation
std::unique_ptr<MumbleClient> MumbleClient::create() {
    return std::make_unique<MumbleClientImpl>();
}

MumbleClientImpl::MumbleClientImpl() {
    // Initialize OpenSSL
    SSL_library_init();
    SSL_load_error_strings();
    OpenSSL_add_all_algorithms();
}

MumbleClientImpl::~MumbleClientImpl() {
    disconnect();
}

bool MumbleClientImpl::connect(const Config& config) {
    if (state_ != ConnectionState::Disconnected) {
        return false;
    }

    config_ = config;
    setState(ConnectionState::Connecting);

    // Initialize SSL context
    if (!initSSL(config)) {
        setState(ConnectionState::Failed);
        return false;
    }

    // Connect socket
    if (!connectSocket(config.host, config.port)) {
        cleanupSSL();
        setState(ConnectionState::Failed);
        return false;
    }

    // Start SSL handshake
    ssl_ = SSL_new(sslCtx_);
    SSL_set_fd(ssl_, socket_);

    if (SSL_connect(ssl_) <= 0) {
        ERR_print_errors_fp(stderr);
        cleanupSSL();
        setState(ConnectionState::Failed);
        return false;
    }

    setState(ConnectionState::Connected);
    running_ = true;

    // Start receive thread
    receiveThread_ = std::thread(&MumbleClientImpl::receiveLoop, this);

    // Send version and authenticate
    sendVersion();
    sendAuthenticate(config.username, config.password);

    return true;
}

void MumbleClientImpl::disconnect() {
    if (state_ == ConnectionState::Disconnected) {
        return;
    }

    setState(ConnectionState::Disconnecting);
    running_ = false;

    // Close SSL connection
    if (ssl_) {
        SSL_shutdown(ssl_);
    }

    // Close socket
    if (socket_ >= 0) {
        close(socket_);
        socket_ = -1;
    }

    // Wait for threads
    if (receiveThread_.joinable()) {
        receiveThread_.join();
    }
    if (pingThread_.joinable()) {
        pingThread_.join();
    }

    cleanupSSL();

    // Clear data
    {
        std::lock_guard<std::mutex> lock(dataMutex_);
        channels_.clear();
        users_.clear();
        localSession_ = 0;
    }

    setState(ConnectionState::Disconnected);
}

ConnectionState MumbleClientImpl::getState() const {
    return state_;
}

void MumbleClientImpl::joinChannel(uint32_t channelId) {
    MumbleProto::UserState userState;
    userState.set_session(localSession_);
    userState.set_channel_id(channelId);
    sendMessage(MessageType::UserState, userState);
}

void MumbleClientImpl::sendAudio(const int16_t* data, size_t frames) {
    // TODO: Implement Opus encoding and audio packet sending
    // Audio is sent via UDPTunnel message type
}

void MumbleClientImpl::setSelfMute(bool mute) {
    MumbleProto::UserState userState;
    userState.set_session(localSession_);
    userState.set_self_mute(mute);
    sendMessage(MessageType::UserState, userState);
}

void MumbleClientImpl::setSelfDeaf(bool deaf) {
    MumbleProto::UserState userState;
    userState.set_session(localSession_);
    userState.set_self_deaf(deaf);
    sendMessage(MessageType::UserState, userState);
}

uint32_t MumbleClientImpl::getLocalSession() const {
    return localSession_;
}

std::vector<Channel> MumbleClientImpl::getChannels() const {
    std::lock_guard<std::mutex> lock(dataMutex_);
    std::vector<Channel> result;
    for (const auto& pair : channels_) {
        result.push_back(pair.second);
    }
    return result;
}

std::vector<User> MumbleClientImpl::getUsers() const {
    std::lock_guard<std::mutex> lock(dataMutex_);
    std::vector<User> result;
    for (const auto& pair : users_) {
        result.push_back(pair.second);
    }
    return result;
}

std::vector<User> MumbleClientImpl::getUsersInChannel(uint32_t channelId) const {
    std::lock_guard<std::mutex> lock(dataMutex_);
    std::vector<User> result;
    for (const auto& pair : users_) {
        if (pair.second.channelId == channelId) {
            result.push_back(pair.second);
        }
    }
    return result;
}

// SSL Initialization
bool MumbleClientImpl::initSSL(const Config& config) {
    sslCtx_ = SSL_CTX_new(TLS_client_method());
    if (!sslCtx_) {
        return false;
    }

    // Set minimum TLS version
    SSL_CTX_set_min_proto_version(sslCtx_, TLS1_2_VERSION);

    // Load client certificate if provided
    if (!config.certificatePath.empty()) {
        if (!loadCertificate(config.certificatePath, config.privateKeyPath)) {
            return false;
        }
    }

    // Disable server certificate verification if requested
    if (!config.validateServerCertificate) {
        SSL_CTX_set_verify(sslCtx_, SSL_VERIFY_NONE, nullptr);
    }

    return true;
}

bool MumbleClientImpl::loadCertificate(const std::string& certPath, const std::string& keyPath) {
    // Try loading as PEM first
    if (SSL_CTX_use_certificate_file(sslCtx_, certPath.c_str(), SSL_FILETYPE_PEM) == 1) {
        if (SSL_CTX_use_PrivateKey_file(sslCtx_, keyPath.c_str(), SSL_FILETYPE_PEM) == 1) {
            return true;
        }
    }

    // Try loading as PKCS12
    FILE* fp = fopen(certPath.c_str(), "rb");
    if (!fp) return false;

    PKCS12* p12 = d2i_PKCS12_fp(fp, nullptr);
    fclose(fp);

    if (!p12) return false;

    EVP_PKEY* pkey = nullptr;
    X509* cert = nullptr;
    STACK_OF(X509)* ca = nullptr;

    if (!PKCS12_parse(p12, "", &pkey, &cert, &ca)) {
        PKCS12_free(p12);
        return false;
    }

    PKCS12_free(p12);

    bool result = true;
    if (cert && SSL_CTX_use_certificate(sslCtx_, cert) != 1) {
        result = false;
    }
    if (result && pkey && SSL_CTX_use_PrivateKey(sslCtx_, pkey) != 1) {
        result = false;
    }

    if (pkey) EVP_PKEY_free(pkey);
    if (cert) X509_free(cert);
    if (ca) sk_X509_pop_free(ca, X509_free);

    return result;
}

bool MumbleClientImpl::loadPKCS12(const std::string& p12Data, const std::string& password) {
    const unsigned char* data = reinterpret_cast<const unsigned char*>(p12Data.data());
    PKCS12* p12 = d2i_PKCS12(nullptr, &data, p12Data.size());
    if (!p12) return false;

    EVP_PKEY* pkey = nullptr;
    X509* cert = nullptr;
    STACK_OF(X509)* ca = nullptr;

    if (!PKCS12_parse(p12, password.c_str(), &pkey, &cert, &ca)) {
        PKCS12_free(p12);
        return false;
    }

    PKCS12_free(p12);

    bool result = true;
    if (cert && SSL_CTX_use_certificate(sslCtx_, cert) != 1) {
        result = false;
    }
    if (result && pkey && SSL_CTX_use_PrivateKey(sslCtx_, pkey) != 1) {
        result = false;
    }

    if (pkey) EVP_PKEY_free(pkey);
    if (cert) X509_free(cert);
    if (ca) sk_X509_pop_free(ca, X509_free);

    return result;
}

void MumbleClientImpl::cleanupSSL() {
    if (ssl_) {
        SSL_free(ssl_);
        ssl_ = nullptr;
    }
    if (sslCtx_) {
        SSL_CTX_free(sslCtx_);
        sslCtx_ = nullptr;
    }
}

// Socket connection
bool MumbleClientImpl::connectSocket(const std::string& host, int port) {
    struct addrinfo hints{}, *result;
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;

    std::string portStr = std::to_string(port);
    if (getaddrinfo(host.c_str(), portStr.c_str(), &hints, &result) != 0) {
        return false;
    }

    socket_ = socket(result->ai_family, result->ai_socktype, result->ai_protocol);
    if (socket_ < 0) {
        freeaddrinfo(result);
        return false;
    }

    if (::connect(socket_, result->ai_addr, result->ai_addrlen) < 0) {
        close(socket_);
        socket_ = -1;
        freeaddrinfo(result);
        return false;
    }

    freeaddrinfo(result);
    return true;
}

// Receive loop
void MumbleClientImpl::receiveLoop() {
    uint8_t header[6];

    while (running_) {
        // Read header: 2-byte type + 4-byte length
        int bytesRead = SSL_read(ssl_, header, 6);
        if (bytesRead != 6) {
            if (running_) {
                setState(ConnectionState::Failed);
            }
            break;
        }

        uint16_t type = (header[0] << 8) | header[1];
        uint32_t length = (header[2] << 24) | (header[3] << 16) | (header[4] << 8) | header[5];

        // Read payload
        std::vector<uint8_t> payload(length);
        if (length > 0) {
            size_t totalRead = 0;
            while (totalRead < length && running_) {
                int n = SSL_read(ssl_, payload.data() + totalRead, length - totalRead);
                if (n <= 0) {
                    if (running_) {
                        setState(ConnectionState::Failed);
                    }
                    return;
                }
                totalRead += n;
            }
        }

        handleMessage(static_cast<MessageType>(type), payload.data(), length);
    }
}

// Ping loop
void MumbleClientImpl::pingLoop() {
    while (running_) {
        std::this_thread::sleep_for(std::chrono::seconds(15));
        if (running_ && state_ == ConnectionState::Synchronized) {
            sendPing();
        }
    }
}

// Send message
bool MumbleClientImpl::sendMessage(MessageType type, const google::protobuf::Message& message) {
    std::string serialized;
    if (!message.SerializeToString(&serialized)) {
        return false;
    }
    return sendRawMessage(type, reinterpret_cast<const uint8_t*>(serialized.data()), serialized.size());
}

bool MumbleClientImpl::sendRawMessage(MessageType type, const uint8_t* data, size_t length) {
    std::lock_guard<std::mutex> lock(sendMutex_);

    if (!ssl_) return false;

    // Build header: 2-byte type + 4-byte length
    uint8_t header[6];
    uint16_t typeVal = static_cast<uint16_t>(type);
    header[0] = (typeVal >> 8) & 0xFF;
    header[1] = typeVal & 0xFF;
    header[2] = (length >> 24) & 0xFF;
    header[3] = (length >> 16) & 0xFF;
    header[4] = (length >> 8) & 0xFF;
    header[5] = length & 0xFF;

    // Send header
    if (SSL_write(ssl_, header, 6) != 6) {
        return false;
    }

    // Send payload
    if (length > 0) {
        if (SSL_write(ssl_, data, length) != static_cast<int>(length)) {
            return false;
        }
    }

    return true;
}

// Handle incoming message
void MumbleClientImpl::handleMessage(MessageType type, const uint8_t* data, size_t length) {
    switch (type) {
        case MessageType::Version:
            handleVersion(data, length);
            break;
        case MessageType::Reject:
            handleReject(data, length);
            break;
        case MessageType::ServerSync:
            handleServerSync(data, length);
            break;
        case MessageType::ChannelState:
            handleChannelState(data, length);
            break;
        case MessageType::ChannelRemove:
            handleChannelRemove(data, length);
            break;
        case MessageType::UserState:
            handleUserState(data, length);
            break;
        case MessageType::UserRemove:
            handleUserRemove(data, length);
            break;
        case MessageType::Ping:
            handlePing(data, length);
            break;
        case MessageType::CryptSetup:
            handleCryptSetup(data, length);
            break;
        case MessageType::ServerConfig:
            handleServerConfig(data, length);
            break;
        case MessageType::CodecVersion:
            handleCodecVersion(data, length);
            break;
        case MessageType::PermissionQuery:
            handlePermissionQuery(data, length);
            break;
        case MessageType::UDPTunnel:
            handleUDPTunnel(data, length);
            break;
        default:
            // Unknown message type - ignore
            break;
    }
}

// Message handlers
void MumbleClientImpl::handleVersion(const uint8_t* data, size_t length) {
    MumbleProto::Version version;
    if (version.ParseFromArray(data, length)) {
        // Server version received
    }
}

void MumbleClientImpl::handleReject(const uint8_t* data, size_t length) {
    MumbleProto::Reject reject;
    if (reject.ParseFromArray(data, length)) {
        RejectReason reason = static_cast<RejectReason>(reject.type());
        setState(ConnectionState::Failed);
        if (rejectCallback_) {
            rejectCallback_(reason, reject.reason());
        }
    }
}

void MumbleClientImpl::handleServerSync(const uint8_t* data, size_t length) {
    MumbleProto::ServerSync sync;
    if (sync.ParseFromArray(data, length)) {
        localSession_ = sync.session();

        {
            std::lock_guard<std::mutex> lock(dataMutex_);
            serverInfo_.welcomeMessage = sync.welcome_text();
            serverInfo_.maxBandwidth = sync.max_bandwidth();
        }

        setState(ConnectionState::Synchronized);

        // Start ping thread
        pingThread_ = std::thread(&MumbleClientImpl::pingLoop, this);

        if (serverInfoCallback_) {
            serverInfoCallback_(serverInfo_);
        }
    }
}

void MumbleClientImpl::handleChannelState(const uint8_t* data, size_t length) {
    MumbleProto::ChannelState state;
    if (state.ParseFromArray(data, length)) {
        Channel channel;
        channel.id = state.channel_id();
        channel.parentId = state.has_parent() ? state.parent() : 0;
        channel.name = state.name();
        channel.description = state.description();
        channel.position = state.position();
        channel.temporary = state.temporary();

        for (int i = 0; i < state.links_size(); i++) {
            channel.linkedChannels.push_back(state.links(i));
        }

        bool isNew;
        {
            std::lock_guard<std::mutex> lock(dataMutex_);
            isNew = channels_.find(channel.id) == channels_.end();
            channels_[channel.id] = channel;
        }

        if (isNew) {
            if (channelAddedCallback_) channelAddedCallback_(channel);
        } else {
            if (channelUpdatedCallback_) channelUpdatedCallback_(channel);
        }
    }
}

void MumbleClientImpl::handleChannelRemove(const uint8_t* data, size_t length) {
    MumbleProto::ChannelRemove remove;
    if (remove.ParseFromArray(data, length)) {
        Channel channel;
        {
            std::lock_guard<std::mutex> lock(dataMutex_);
            auto it = channels_.find(remove.channel_id());
            if (it != channels_.end()) {
                channel = it->second;
                channels_.erase(it);
            }
        }
        if (channelRemovedCallback_) {
            channelRemovedCallback_(channel);
        }
    }
}

void MumbleClientImpl::handleUserState(const uint8_t* data, size_t length) {
    MumbleProto::UserState state;
    if (state.ParseFromArray(data, length)) {
        bool isNew;
        User user;

        {
            std::lock_guard<std::mutex> lock(dataMutex_);
            auto it = users_.find(state.session());
            isNew = (it == users_.end());

            if (!isNew) {
                user = it->second;
            }

            user.session = state.session();
            if (state.has_channel_id()) user.channelId = state.channel_id();
            if (state.has_name()) user.name = state.name();
            if (state.has_comment()) user.comment = state.comment();
            if (state.has_mute()) user.mute = state.mute();
            if (state.has_deaf()) user.deaf = state.deaf();
            if (state.has_self_mute()) user.selfMute = state.self_mute();
            if (state.has_self_deaf()) user.selfDeaf = state.self_deaf();
            if (state.has_suppress()) user.suppress = state.suppress();
            if (state.has_recording()) user.recording = state.recording();
            if (state.has_priority_speaker()) user.priority = state.priority_speaker() ? 1 : 0;

            users_[state.session()] = user;
        }

        if (isNew) {
            if (userAddedCallback_) userAddedCallback_(user);
        } else {
            if (userUpdatedCallback_) userUpdatedCallback_(user);
        }
    }
}

void MumbleClientImpl::handleUserRemove(const uint8_t* data, size_t length) {
    MumbleProto::UserRemove remove;
    if (remove.ParseFromArray(data, length)) {
        User user;
        {
            std::lock_guard<std::mutex> lock(dataMutex_);
            auto it = users_.find(remove.session());
            if (it != users_.end()) {
                user = it->second;
                users_.erase(it);
            }
        }
        if (userRemovedCallback_) {
            userRemovedCallback_(user);
        }
    }
}

void MumbleClientImpl::handlePing(const uint8_t* data, size_t length) {
    // Server ping received - could track latency here
}

void MumbleClientImpl::handleCryptSetup(const uint8_t* data, size_t length) {
    MumbleProto::CryptSetup setup;
    if (setup.ParseFromArray(data, length)) {
        if (setup.has_key() && setup.key().size() == 16) {
            memcpy(cryptKey_, setup.key().data(), 16);
        }
        if (setup.has_client_nonce() && setup.client_nonce().size() == 16) {
            memcpy(clientNonce_, setup.client_nonce().data(), 16);
        }
        if (setup.has_server_nonce() && setup.server_nonce().size() == 16) {
            memcpy(serverNonce_, setup.server_nonce().data(), 16);
        }
        cryptSetup_ = true;
    }
}

void MumbleClientImpl::handleServerConfig(const uint8_t* data, size_t length) {
    MumbleProto::ServerConfig config;
    if (config.ParseFromArray(data, length)) {
        std::lock_guard<std::mutex> lock(dataMutex_);
        if (config.has_max_bandwidth()) serverInfo_.maxBandwidth = config.max_bandwidth();
        if (config.has_welcome_text()) serverInfo_.welcomeMessage = config.welcome_text();
        if (config.has_allow_html()) serverInfo_.allowHtml = config.allow_html();
        if (config.has_max_users()) serverInfo_.maxUsers = config.max_users();
    }
}

void MumbleClientImpl::handleCodecVersion(const uint8_t* data, size_t length) {
    MumbleProto::CodecVersion codec;
    if (codec.ParseFromArray(data, length)) {
        // Store codec preferences - we prefer Opus
    }
}

void MumbleClientImpl::handlePermissionQuery(const uint8_t* data, size_t length) {
    MumbleProto::PermissionQuery query;
    if (query.ParseFromArray(data, length)) {
        // Store channel permissions
        // Could add a permissions callback here
    }
}

void MumbleClientImpl::handleUDPTunnel(const uint8_t* data, size_t length) {
    if (length < 1) return;

    // Audio packet format:
    // Byte 0: Header (type << 5 | target)
    // Varint: Session ID
    // Varint: Sequence number
    // Opus data...

    // TODO: Decode Opus audio and call audioCallback_
}

// State management
void MumbleClientImpl::setState(ConnectionState state) {
    state_ = state;
    if (stateCallback_) {
        stateCallback_(state);
    }
}

// Send version message
void MumbleClientImpl::sendVersion() {
    MumbleProto::Version version;
    version.set_version(MUMBLE_VERSION);
    version.set_release("SAYses iOS 1.0");
    version.set_os("iOS");
    version.set_os_version("15.0");
    sendMessage(MessageType::Version, version);
}

// Send authenticate message
void MumbleClientImpl::sendAuthenticate(const std::string& username, const std::string& password) {
    MumbleProto::Authenticate auth;
    auth.set_username(username);
    if (!password.empty()) {
        auth.set_password(password);
    }
    auth.set_opus(true);
    sendMessage(MessageType::Authenticate, auth);

    setState(ConnectionState::Synchronizing);
}

// Send ping
void MumbleClientImpl::sendPing() {
    MumbleProto::Ping ping;
    auto now = std::chrono::steady_clock::now();
    auto timestamp = std::chrono::duration_cast<std::chrono::milliseconds>(now.time_since_epoch()).count();
    ping.set_timestamp(timestamp);
    sendMessage(MessageType::Ping, ping);
}

}  // namespace sayses
