#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, MumbleConnectionState) {
    MumbleConnectionStateDisconnected,
    MumbleConnectionStateConnecting,
    MumbleConnectionStateConnected,
    MumbleConnectionStateSynchronizing,
    MumbleConnectionStateSynchronized,
    MumbleConnectionStateDisconnecting,
    MumbleConnectionStateFailed
};

typedef NS_ENUM(NSInteger, MumbleRejectReason) {
    MumbleRejectReasonNone,
    MumbleRejectReasonWrongVersion,
    MumbleRejectReasonInvalidUsername,
    MumbleRejectReasonWrongPassword,
    MumbleRejectReasonUsernameInUse,
    MumbleRejectReasonServerFull,
    MumbleRejectReasonNoCertificate,
    MumbleRejectReasonAuthenticatorFail
};

@interface MumbleChannel : NSObject
@property (nonatomic, readonly) uint32_t channelId;
@property (nonatomic, readonly) uint32_t parentId;
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly, copy) NSString *channelDescription;
@property (nonatomic, readonly) int32_t position;
@property (nonatomic, readonly) BOOL temporary;
@end

@interface MumbleUser : NSObject
@property (nonatomic, readonly) uint32_t session;
@property (nonatomic, readonly) uint32_t channelId;
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly, copy) NSString *comment;
@property (nonatomic, readonly) BOOL mute;
@property (nonatomic, readonly) BOOL deaf;
@property (nonatomic, readonly) BOOL selfMute;
@property (nonatomic, readonly) BOOL selfDeaf;
@property (nonatomic, readonly) BOOL suppress;
@property (nonatomic, readonly) BOOL recording;
@end

@interface MumbleServerInfo : NSObject
@property (nonatomic, readonly, copy) NSString *welcomeMessage;
@property (nonatomic, readonly) uint32_t maxBandwidth;
@property (nonatomic, readonly) uint32_t maxUsers;
@property (nonatomic, readonly) BOOL allowHtml;
@property (nonatomic, readonly, copy) NSString *serverVersion;
@end

@protocol MumbleClientDelegate <NSObject>
@optional
- (void)mumbleClient:(id)client didChangeState:(MumbleConnectionState)state;
- (void)mumbleClient:(id)client didAddChannel:(MumbleChannel *)channel;
- (void)mumbleClient:(id)client didUpdateChannel:(MumbleChannel *)channel;
- (void)mumbleClient:(id)client didRemoveChannel:(MumbleChannel *)channel;
- (void)mumbleClient:(id)client didAddUser:(MumbleUser *)user;
- (void)mumbleClient:(id)client didUpdateUser:(MumbleUser *)user;
- (void)mumbleClient:(id)client didRemoveUser:(MumbleUser *)user;
- (void)mumbleClient:(id)client didReceiveAudioFromSession:(uint32_t)session
                data:(const int16_t *)data frames:(size_t)frames;
- (void)mumbleClient:(id)client didRejectWithReason:(MumbleRejectReason)reason
             message:(NSString *)message;
- (void)mumbleClient:(id)client didReceiveServerInfo:(MumbleServerInfo *)info;
@end

/**
 * Objective-C bridge for the C++ MumbleClient.
 */
@interface MumbleClientBridge : NSObject

@property (nonatomic, weak, nullable) id<MumbleClientDelegate> delegate;
@property (nonatomic, readonly) MumbleConnectionState state;
@property (nonatomic, readonly) uint32_t localSession;

- (BOOL)connectToHost:(NSString *)host
                 port:(int)port
             username:(NSString *)username
             password:(NSString *)password
      certificatePath:(nullable NSString *)certificatePath
       privateKeyPath:(nullable NSString *)privateKeyPath
validateServerCertificate:(BOOL)validate;

- (void)disconnect;

- (void)joinChannel:(uint32_t)channelId;

- (void)sendAudio:(const int16_t *)data frames:(size_t)frames;

- (void)setSelfMute:(BOOL)mute;
- (void)setSelfDeaf:(BOOL)deaf;

- (NSArray<MumbleChannel *> *)channels;
- (NSArray<MumbleUser *> *)users;
- (NSArray<MumbleUser *> *)usersInChannel:(uint32_t)channelId;

@end

NS_ASSUME_NONNULL_END
