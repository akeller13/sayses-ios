#import "MumbleClientBridge.h"
#include "mumble_client.h"
#include <memory>

// MARK: - MumbleChannel Implementation

@implementation MumbleChannel {
    sayses::Channel _channel;
}

- (instancetype)initWithChannel:(const sayses::Channel &)channel {
    self = [super init];
    if (self) {
        _channel = channel;
    }
    return self;
}

- (uint32_t)channelId { return _channel.id; }
- (uint32_t)parentId { return _channel.parentId; }
- (NSString *)name { return [NSString stringWithUTF8String:_channel.name.c_str()]; }
- (NSString *)channelDescription { return [NSString stringWithUTF8String:_channel.description.c_str()]; }
- (int32_t)position { return _channel.position; }
- (BOOL)temporary { return _channel.temporary; }

@end

// MARK: - MumbleUser Implementation

@implementation MumbleUser {
    sayses::User _user;
}

- (instancetype)initWithUser:(const sayses::User &)user {
    self = [super init];
    if (self) {
        _user = user;
    }
    return self;
}

- (uint32_t)session { return _user.session; }
- (uint32_t)channelId { return _user.channelId; }
- (NSString *)name { return [NSString stringWithUTF8String:_user.name.c_str()]; }
- (NSString *)comment { return [NSString stringWithUTF8String:_user.comment.c_str()]; }
- (BOOL)mute { return _user.mute; }
- (BOOL)deaf { return _user.deaf; }
- (BOOL)selfMute { return _user.selfMute; }
- (BOOL)selfDeaf { return _user.selfDeaf; }
- (BOOL)suppress { return _user.suppress; }
- (BOOL)recording { return _user.recording; }

@end

// MARK: - MumbleServerInfo Implementation

@implementation MumbleServerInfo {
    sayses::ServerInfo _info;
}

- (instancetype)initWithServerInfo:(const sayses::ServerInfo &)info {
    self = [super init];
    if (self) {
        _info = info;
    }
    return self;
}

- (NSString *)welcomeMessage { return [NSString stringWithUTF8String:_info.welcomeMessage.c_str()]; }
- (uint32_t)maxBandwidth { return _info.maxBandwidth; }
- (uint32_t)maxUsers { return _info.maxUsers; }
- (BOOL)allowHtml { return _info.allowHtml; }
- (NSString *)serverVersion { return [NSString stringWithUTF8String:_info.serverVersion.c_str()]; }

@end

// MARK: - MumbleClientBridge Implementation

@implementation MumbleClientBridge {
    std::unique_ptr<sayses::MumbleClient> _client;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _client = sayses::MumbleClient::create();
        [self setupCallbacks];
    }
    return self;
}

- (void)setupCallbacks {
    if (!_client) return;

    __weak MumbleClientBridge *weakSelf = self;

    _client->setStateCallback([weakSelf](sayses::ConnectionState state) {
        dispatch_async(dispatch_get_main_queue(), ^{
            MumbleClientBridge *strongSelf = weakSelf;
            if (strongSelf && strongSelf.delegate) {
                [strongSelf.delegate mumbleClient:strongSelf
                                   didChangeState:(MumbleConnectionState)state];
            }
        });
    });

    _client->setChannelAddedCallback([weakSelf](const sayses::Channel& channel) {
        dispatch_async(dispatch_get_main_queue(), ^{
            MumbleClientBridge *strongSelf = weakSelf;
            if (strongSelf && strongSelf.delegate) {
                MumbleChannel *ch = [[MumbleChannel alloc] initWithChannel:channel];
                [strongSelf.delegate mumbleClient:strongSelf didAddChannel:ch];
            }
        });
    });

    _client->setChannelUpdatedCallback([weakSelf](const sayses::Channel& channel) {
        dispatch_async(dispatch_get_main_queue(), ^{
            MumbleClientBridge *strongSelf = weakSelf;
            if (strongSelf && strongSelf.delegate) {
                MumbleChannel *ch = [[MumbleChannel alloc] initWithChannel:channel];
                [strongSelf.delegate mumbleClient:strongSelf didUpdateChannel:ch];
            }
        });
    });

    _client->setChannelRemovedCallback([weakSelf](const sayses::Channel& channel) {
        dispatch_async(dispatch_get_main_queue(), ^{
            MumbleClientBridge *strongSelf = weakSelf;
            if (strongSelf && strongSelf.delegate) {
                MumbleChannel *ch = [[MumbleChannel alloc] initWithChannel:channel];
                [strongSelf.delegate mumbleClient:strongSelf didRemoveChannel:ch];
            }
        });
    });

    _client->setUserAddedCallback([weakSelf](const sayses::User& user) {
        dispatch_async(dispatch_get_main_queue(), ^{
            MumbleClientBridge *strongSelf = weakSelf;
            if (strongSelf && strongSelf.delegate) {
                MumbleUser *u = [[MumbleUser alloc] initWithUser:user];
                [strongSelf.delegate mumbleClient:strongSelf didAddUser:u];
            }
        });
    });

    _client->setUserUpdatedCallback([weakSelf](const sayses::User& user) {
        dispatch_async(dispatch_get_main_queue(), ^{
            MumbleClientBridge *strongSelf = weakSelf;
            if (strongSelf && strongSelf.delegate) {
                MumbleUser *u = [[MumbleUser alloc] initWithUser:user];
                [strongSelf.delegate mumbleClient:strongSelf didUpdateUser:u];
            }
        });
    });

    _client->setUserRemovedCallback([weakSelf](const sayses::User& user) {
        dispatch_async(dispatch_get_main_queue(), ^{
            MumbleClientBridge *strongSelf = weakSelf;
            if (strongSelf && strongSelf.delegate) {
                MumbleUser *u = [[MumbleUser alloc] initWithUser:user];
                [strongSelf.delegate mumbleClient:strongSelf didRemoveUser:u];
            }
        });
    });

    _client->setAudioCallback([weakSelf](uint32_t session, const int16_t* data, size_t frames) {
        MumbleClientBridge *strongSelf = weakSelf;
        if (strongSelf && strongSelf.delegate) {
            [strongSelf.delegate mumbleClient:strongSelf
                     didReceiveAudioFromSession:session
                                           data:data
                                         frames:frames];
        }
    });

    _client->setRejectCallback([weakSelf](sayses::RejectReason reason, const std::string& message) {
        dispatch_async(dispatch_get_main_queue(), ^{
            MumbleClientBridge *strongSelf = weakSelf;
            if (strongSelf && strongSelf.delegate) {
                [strongSelf.delegate mumbleClient:strongSelf
                              didRejectWithReason:(MumbleRejectReason)reason
                                          message:[NSString stringWithUTF8String:message.c_str()]];
            }
        });
    });

    _client->setServerInfoCallback([weakSelf](const sayses::ServerInfo& info) {
        dispatch_async(dispatch_get_main_queue(), ^{
            MumbleClientBridge *strongSelf = weakSelf;
            if (strongSelf && strongSelf.delegate) {
                MumbleServerInfo *si = [[MumbleServerInfo alloc] initWithServerInfo:info];
                [strongSelf.delegate mumbleClient:strongSelf didReceiveServerInfo:si];
            }
        });
    });
}

- (MumbleConnectionState)state {
    return _client ? (MumbleConnectionState)_client->getState() : MumbleConnectionStateDisconnected;
}

- (uint32_t)localSession {
    return _client ? _client->getLocalSession() : 0;
}

- (BOOL)connectToHost:(NSString *)host
                 port:(int)port
             username:(NSString *)username
             password:(NSString *)password
      certificatePath:(NSString *)certificatePath
       privateKeyPath:(NSString *)privateKeyPath
validateServerCertificate:(BOOL)validate {
    if (!_client) return NO;

    sayses::MumbleClient::Config config;
    config.host = [host UTF8String];
    config.port = port;
    config.username = [username UTF8String];
    config.password = password ? [password UTF8String] : "";
    config.certificatePath = certificatePath ? [certificatePath UTF8String] : "";
    config.privateKeyPath = privateKeyPath ? [privateKeyPath UTF8String] : "";
    config.validateServerCertificate = validate;

    return _client->connect(config);
}

- (void)disconnect {
    if (_client) {
        _client->disconnect();
    }
}

- (void)joinChannel:(uint32_t)channelId {
    if (_client) {
        _client->joinChannel(channelId);
    }
}

- (void)sendAudio:(const int16_t *)data frames:(size_t)frames {
    if (_client) {
        _client->sendAudio(data, frames);
    }
}

- (void)setSelfMute:(BOOL)mute {
    if (_client) {
        _client->setSelfMute(mute);
    }
}

- (void)setSelfDeaf:(BOOL)deaf {
    if (_client) {
        _client->setSelfDeaf(deaf);
    }
}

- (NSArray<MumbleChannel *> *)channels {
    NSMutableArray *result = [NSMutableArray array];
    if (_client) {
        for (const auto& ch : _client->getChannels()) {
            [result addObject:[[MumbleChannel alloc] initWithChannel:ch]];
        }
    }
    return result;
}

- (NSArray<MumbleUser *> *)users {
    NSMutableArray *result = [NSMutableArray array];
    if (_client) {
        for (const auto& u : _client->getUsers()) {
            [result addObject:[[MumbleUser alloc] initWithUser:u]];
        }
    }
    return result;
}

- (NSArray<MumbleUser *> *)usersInChannel:(uint32_t)channelId {
    NSMutableArray *result = [NSMutableArray array];
    if (_client) {
        for (const auto& u : _client->getUsersInChannel(channelId)) {
            [result addObject:[[MumbleUser alloc] initWithUser:u]];
        }
    }
    return result;
}

@end
