/**
 * Mumble Crypto Implementation
 * OCB-AES128 encryption for UDP audio packets
 * Based on Mumble's CryptState implementation
 */

#include <openssl/aes.h>
#include <openssl/rand.h>

#include <cstring>
#include <cstdint>
#include <mutex>

namespace sayses {

/**
 * OCB-AES128 encryption state for Mumble UDP packets.
 * Implements the OCB (Offset Codebook) mode of operation.
 */
class CryptState {
public:
    CryptState();
    ~CryptState() = default;

    /**
     * Initialize with key and nonces from server.
     */
    bool init(const uint8_t key[16],
              const uint8_t clientNonce[16],
              const uint8_t serverNonce[16]);

    /**
     * Encrypt a packet.
     * @param src Source data
     * @param dst Destination buffer (must be src_len + 4 bytes)
     * @param srcLen Source length
     * @return true on success
     */
    bool encrypt(const uint8_t* src, uint8_t* dst, size_t srcLen);

    /**
     * Decrypt a packet.
     * @param src Source data
     * @param dst Destination buffer
     * @param srcLen Source length (includes 4-byte tag)
     * @return true on success
     */
    bool decrypt(const uint8_t* src, uint8_t* dst, size_t srcLen);

    /**
     * Check if crypto is initialized.
     */
    bool isValid() const { return initialized_; }

    /**
     * Request nonce resync.
     */
    void requestResync() { needResync_ = true; }

    /**
     * Check if resync is needed.
     */
    bool needsResync() const { return needResync_; }

private:
    void ocbEncrypt(const uint8_t* plain, uint8_t* encrypted,
                    size_t len, const uint8_t* nonce, uint8_t* tag);
    bool ocbDecrypt(const uint8_t* encrypted, uint8_t* plain,
                    size_t len, const uint8_t* nonce, const uint8_t* tag);

    void aesEncrypt(uint8_t* dst, const uint8_t* src);
    void xorBlock(uint8_t* dst, const uint8_t* a, const uint8_t* b);
    void shift(uint8_t* dst, const uint8_t* src);
    void generateSubkeys();

    // Key material
    uint8_t key_[16];
    uint8_t clientNonce_[16];
    uint8_t serverNonce_[16];

    // AES
    AES_KEY aesKey_;
    uint8_t L_[16];    // L = E_K(0^n)
    uint8_t delta_[16];

    // State
    bool initialized_{false};
    bool needResync_{false};
    std::mutex mutex_;

    // Nonce tracking
    uint32_t encryptNonce_{0};
    uint32_t decryptNonce_{0};
    uint32_t lastGood_{0};
    uint32_t late_{0};
    uint32_t lost_{0};
};

CryptState::CryptState() {
    std::memset(key_, 0, sizeof(key_));
    std::memset(clientNonce_, 0, sizeof(clientNonce_));
    std::memset(serverNonce_, 0, sizeof(serverNonce_));
}

bool CryptState::init(const uint8_t key[16],
                      const uint8_t clientNonce[16],
                      const uint8_t serverNonce[16]) {
    std::lock_guard<std::mutex> lock(mutex_);

    std::memcpy(key_, key, 16);
    std::memcpy(clientNonce_, clientNonce, 16);
    std::memcpy(serverNonce_, serverNonce, 16);

    // Initialize AES key
    if (AES_set_encrypt_key(key_, 128, &aesKey_) != 0) {
        return false;
    }

    generateSubkeys();

    encryptNonce_ = 0;
    decryptNonce_ = 0;
    lastGood_ = 0;
    late_ = 0;
    lost_ = 0;
    needResync_ = false;
    initialized_ = true;

    return true;
}

void CryptState::generateSubkeys() {
    uint8_t zero[16] = {0};

    // L = E_K(0^n)
    aesEncrypt(L_, zero);

    // delta = L
    std::memcpy(delta_, L_, 16);
}

void CryptState::aesEncrypt(uint8_t* dst, const uint8_t* src) {
    AES_encrypt(src, dst, &aesKey_);
}

void CryptState::xorBlock(uint8_t* dst, const uint8_t* a, const uint8_t* b) {
    for (int i = 0; i < 16; i++) {
        dst[i] = a[i] ^ b[i];
    }
}

void CryptState::shift(uint8_t* dst, const uint8_t* src) {
    // Double in GF(2^128)
    uint8_t carry = src[0] >> 7;
    for (int i = 0; i < 15; i++) {
        dst[i] = (src[i] << 1) | (src[i + 1] >> 7);
    }
    dst[15] = (src[15] << 1) ^ (carry ? 0x87 : 0);
}

bool CryptState::encrypt(const uint8_t* src, uint8_t* dst, size_t srcLen) {
    std::lock_guard<std::mutex> lock(mutex_);

    if (!initialized_) {
        return false;
    }

    // Prepare nonce
    uint8_t nonce[16];
    std::memcpy(nonce, clientNonce_, 16);

    // Increment nonce counter
    encryptNonce_++;
    nonce[0] = static_cast<uint8_t>(encryptNonce_);
    nonce[1] = static_cast<uint8_t>(encryptNonce_ >> 8);
    nonce[2] = static_cast<uint8_t>(encryptNonce_ >> 16);
    nonce[3] = static_cast<uint8_t>(encryptNonce_ >> 24);

    // First byte is nonce counter LSB
    dst[0] = nonce[0];

    // Encrypt and generate tag
    uint8_t tag[16];
    ocbEncrypt(src, dst + 4, srcLen, nonce, tag);

    // Store 3 bytes of tag
    dst[1] = tag[0];
    dst[2] = tag[1];
    dst[3] = tag[2];

    return true;
}

bool CryptState::decrypt(const uint8_t* src, uint8_t* dst, size_t srcLen) {
    std::lock_guard<std::mutex> lock(mutex_);

    if (!initialized_ || srcLen < 4) {
        return false;
    }

    // Extract nonce counter from first byte
    uint8_t nonce[16];
    std::memcpy(nonce, serverNonce_, 16);

    uint8_t nonceByte = src[0];

    // Reconstruct full nonce
    int32_t diff = static_cast<int8_t>(nonceByte - static_cast<uint8_t>(decryptNonce_));
    uint32_t predictedNonce = decryptNonce_ + diff;

    nonce[0] = static_cast<uint8_t>(predictedNonce);
    nonce[1] = static_cast<uint8_t>(predictedNonce >> 8);
    nonce[2] = static_cast<uint8_t>(predictedNonce >> 16);
    nonce[3] = static_cast<uint8_t>(predictedNonce >> 24);

    // Decrypt
    uint8_t expectedTag[16];
    size_t plainLen = srcLen - 4;

    ocbEncrypt(dst, const_cast<uint8_t*>(src + 4), plainLen, nonce, expectedTag);

    // Verify tag (first 3 bytes)
    if (expectedTag[0] != src[1] ||
        expectedTag[1] != src[2] ||
        expectedTag[2] != src[3]) {
        needResync_ = true;
        return false;
    }

    // Update nonce counter
    decryptNonce_ = predictedNonce + 1;

    return true;
}

void CryptState::ocbEncrypt(const uint8_t* plain, uint8_t* encrypted,
                            size_t len, const uint8_t* nonce, uint8_t* tag) {
    // OCB-AES128 encryption
    // Simplified implementation for Mumble's specific usage

    uint8_t offset[16];
    uint8_t checksum[16];
    std::memset(checksum, 0, 16);

    // Initialize offset from nonce
    aesEncrypt(offset, nonce);

    // Process full blocks
    size_t fullBlocks = len / 16;
    for (size_t i = 0; i < fullBlocks; i++) {
        // Update offset: offset = offset XOR L
        xorBlock(offset, offset, L_);

        // Encrypt: C = offset XOR E_K(P XOR offset)
        uint8_t tmp[16];
        xorBlock(tmp, plain + i * 16, offset);
        uint8_t enc[16];
        aesEncrypt(enc, tmp);
        xorBlock(encrypted + i * 16, enc, offset);

        // Update checksum
        xorBlock(checksum, checksum, plain + i * 16);
    }

    // Process partial block if any
    size_t remaining = len % 16;
    if (remaining > 0) {
        // Update offset for last block
        shift(offset, offset);

        uint8_t pad[16];
        aesEncrypt(pad, offset);

        for (size_t i = 0; i < remaining; i++) {
            encrypted[fullBlocks * 16 + i] = plain[fullBlocks * 16 + i] ^ pad[i];
            checksum[i] ^= plain[fullBlocks * 16 + i];
        }
        checksum[remaining] ^= 0x80;  // Padding
    }

    // Generate tag
    xorBlock(checksum, checksum, offset);
    aesEncrypt(tag, checksum);
}

bool CryptState::ocbDecrypt(const uint8_t* encrypted, uint8_t* plain,
                            size_t len, const uint8_t* nonce, const uint8_t* tag) {
    // OCB decryption is similar to encryption due to the mode's properties
    uint8_t computedTag[16];
    ocbEncrypt(encrypted, plain, len, nonce, computedTag);

    // Verify tag
    return std::memcmp(computedTag, tag, 16) == 0;
}

}  // namespace sayses
