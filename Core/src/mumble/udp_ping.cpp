/**
 * Mumble UDP Ping Implementation
 * Handles UDP connectivity test and latency measurement
 */

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <fcntl.h>

#include <atomic>
#include <thread>
#include <chrono>
#include <cstring>
#include <functional>
#include <mutex>

namespace sayses {

/**
 * UDP Ping handler for Mumble server connectivity testing.
 * Tests if UDP is usable and measures latency.
 */
class UdpPing {
public:
    using PingCallback = std::function<void(bool success, float latencyMs)>;

    UdpPing();
    ~UdpPing();

    /**
     * Start UDP ping to server.
     * @param host Server hostname or IP
     * @param port Server UDP port (usually same as TCP)
     * @param callback Called with results
     */
    bool start(const std::string& host, int port, PingCallback callback);

    /**
     * Stop UDP ping.
     */
    void stop();

    /**
     * Check if UDP appears to be working.
     */
    bool isUdpAvailable() const { return udpAvailable_; }

    /**
     * Get average latency in milliseconds.
     */
    float getLatency() const { return latencyMs_; }

private:
    void pingLoop();
    void sendPing();
    bool receiveResponse(int timeoutMs);

    int socket_{-1};
    struct sockaddr_in serverAddr_;

    std::atomic<bool> running_{false};
    std::atomic<bool> udpAvailable_{false};
    std::atomic<float> latencyMs_{0.0f};

    std::thread pingThread_;
    PingCallback callback_;
    std::mutex mutex_;

    // Ping statistics
    int pingsSent_{0};
    int pongsReceived_{0};
    std::chrono::steady_clock::time_point lastPingTime_;

    static constexpr int kPingIntervalMs = 5000;  // 5 seconds between pings
    static constexpr int kPingTimeoutMs = 2000;   // 2 second timeout
    static constexpr int kMaxRetries = 3;
};

UdpPing::UdpPing() {
    std::memset(&serverAddr_, 0, sizeof(serverAddr_));
}

UdpPing::~UdpPing() {
    stop();
}

bool UdpPing::start(const std::string& host, int port, PingCallback callback) {
    std::lock_guard<std::mutex> lock(mutex_);

    if (running_) {
        return false;
    }

    callback_ = std::move(callback);

    // Create UDP socket
    socket_ = socket(AF_INET, SOCK_DGRAM, 0);
    if (socket_ < 0) {
        return false;
    }

    // Set non-blocking
    int flags = fcntl(socket_, F_GETFL, 0);
    fcntl(socket_, F_SETFL, flags | O_NONBLOCK);

    // Setup server address
    serverAddr_.sin_family = AF_INET;
    serverAddr_.sin_port = htons(port);

    if (inet_pton(AF_INET, host.c_str(), &serverAddr_.sin_addr) != 1) {
        // Try hostname resolution
        // For simplicity, we assume IP address here
        close(socket_);
        socket_ = -1;
        return false;
    }

    running_ = true;
    udpAvailable_ = false;
    pingsSent_ = 0;
    pongsReceived_ = 0;

    pingThread_ = std::thread(&UdpPing::pingLoop, this);

    return true;
}

void UdpPing::stop() {
    running_ = false;

    if (pingThread_.joinable()) {
        pingThread_.join();
    }

    if (socket_ >= 0) {
        close(socket_);
        socket_ = -1;
    }
}

void UdpPing::pingLoop() {
    int retries = 0;

    while (running_ && retries < kMaxRetries) {
        sendPing();

        if (receiveResponse(kPingTimeoutMs)) {
            // Got response - UDP is working
            udpAvailable_ = true;

            if (callback_) {
                callback_(true, latencyMs_);
            }

            // Continue pinging periodically
            retries = 0;
        } else {
            retries++;
        }

        // Wait before next ping
        for (int i = 0; i < kPingIntervalMs / 100 && running_; i++) {
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
    }

    if (retries >= kMaxRetries && !udpAvailable_) {
        // UDP not working
        if (callback_) {
            callback_(false, 0.0f);
        }
    }
}

void UdpPing::sendPing() {
    // Mumble UDP ping packet format:
    // 1 byte: type (0x20 = ping)
    // 8 bytes: timestamp (varint)

    uint8_t packet[9];
    packet[0] = 0x20;  // UDP ping type

    auto now = std::chrono::steady_clock::now();
    lastPingTime_ = now;

    auto timestamp = std::chrono::duration_cast<std::chrono::microseconds>(
        now.time_since_epoch()
    ).count();

    // Encode timestamp as varint (simplified - just use lower 8 bytes)
    for (int i = 0; i < 8; i++) {
        packet[1 + i] = static_cast<uint8_t>(timestamp >> (i * 8));
    }

    sendto(socket_, packet, sizeof(packet), 0,
           reinterpret_cast<sockaddr*>(&serverAddr_), sizeof(serverAddr_));

    pingsSent_++;
}

bool UdpPing::receiveResponse(int timeoutMs) {
    auto startTime = std::chrono::steady_clock::now();

    while (running_) {
        auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - startTime
        ).count();

        if (elapsed >= timeoutMs) {
            return false;
        }

        uint8_t buffer[64];
        struct sockaddr_in fromAddr;
        socklen_t fromLen = sizeof(fromAddr);

        ssize_t received = recvfrom(socket_, buffer, sizeof(buffer), 0,
                                    reinterpret_cast<sockaddr*>(&fromAddr), &fromLen);

        if (received > 0 && buffer[0] == 0x20) {
            // Got ping response
            auto now = std::chrono::steady_clock::now();
            auto latency = std::chrono::duration_cast<std::chrono::microseconds>(
                now - lastPingTime_
            ).count();

            latencyMs_ = latency / 1000.0f;
            pongsReceived_++;

            return true;
        }

        // Brief sleep to avoid busy-waiting
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }

    return false;
}

}  // namespace sayses
