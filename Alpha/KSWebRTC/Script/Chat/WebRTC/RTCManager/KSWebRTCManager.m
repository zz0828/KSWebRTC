//
//  KSWebRTCManager.m
//  KSWebRTC
//
//  Created by saeipi on 2020/8/12.
//  Copyright © 2020 saeipi. All rights reserved.
//

#import "KSWebRTCManager.h"

@interface KSWebRTCManager()<KSMessageHandlerDelegate,KSMediaConnectionDelegate>
@property (nonatomic, strong) KSMessageHandler *msgHandler;
@property (nonatomic, strong) KSMediaCapturer   *mediaCapture;//本地
@property (nonatomic, weak) KSMediaConnection *peerConnection;//本地
@end

@implementation KSWebRTCManager

+ (instancetype)shared {
    static KSWebRTCManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
        [instance initMsgHandler];
    });
    return instance;
}

- (void)initMsgHandler {
    _msgHandler          = [[KSMessageHandler alloc] init];
    _msgHandler.delegate = self;
}

- (void)initRTCWithMediaSetting:(KSMediaSetting *)mediaSetting {
    _mediaSetting              = mediaSetting;
    _callType                  = mediaSetting.callType;
    _mediaCapture              = [[KSMediaCapturer alloc] initWithSetting:mediaSetting.capturerSetting];

    [self createLocalConnection];
}

- (void)createLocalConnection {
    KSMediaConnection *peerConnection = [[KSMediaConnection alloc] initWithSetting:_mediaSetting.connectionSetting];
    peerConnection.delegate           = self;
    peerConnection.isLocal            = YES;
    peerConnection.videoTrack         = _mediaCapture.videoTrack;
    _peerConnection                   = peerConnection;

    [peerConnection createPeerConnectionWithMediaCapturer:_mediaCapture];
    [self.mediaConnections addObject:peerConnection];
}

#pragma mark - KSMessageHandlerDelegate
- (KSMediaConnection *)messageHandler:(KSMessageHandler *)messageHandler connectionOfHandleId:(NSNumber *)handleId {
    //若不返回错误，则ICE错误
    return [self mediaConnectionOfHandleId:handleId];
}

- (KSMediaConnection *)messageHandlerOfLocalConnection {
    return self.localConnection;
}

- (KSMediaConnection *)messageHandlerOfCreateConnection {
    KSMediaConnection *mc         = [[KSMediaConnection alloc] initWithSetting:_mediaSetting.connectionSetting];
    [mc createPeerConnectionWithMediaCapturer:_mediaCapture];
    mc.delegate                   = self;
    return mc;
}

- (KSConnectionSetting *)messageHandlerOfConnectionSetting {
    return _mediaSetting.connectionSetting;
}

- (KSMediaCapturer *)mediaCaptureOfSectionsInMessageHandler:(KSMessageHandler *)messageHandler {
    return _mediaCapture;
}

- (void)messageHandler:(KSMessageHandler *)messageHandler didReceivedMessage:(KSMsg *)message {
    if ([self.delegate respondsToSelector:@selector(webRTCManager:didReceivedMessage:)]) {
        [self.delegate webRTCManager:self didReceivedMessage:message];
    }
}

- (void)messageHandler:(KSMessageHandler *)messageHandler socketDidOpen:(KSWebSocket *)socket {
    _isConnect = YES;
    if ([self.delegate respondsToSelector:@selector(webRTCManagerSocketDidOpen:)]) {
        [self.delegate webRTCManagerSocketDidOpen:self];
    }
}

- (void)messageHandler:(KSMessageHandler *)messageHandler socketDidFail:(KSWebSocket *)socket {
    _isConnect = NO;
    if ([self.delegate respondsToSelector:@selector(webRTCManagerSocketDidFail:)]) {
        [self.delegate webRTCManagerSocketDidFail:self];
    }
}

#pragma mark - KSMediaConnectionDelegate
// 收到远端流处理
//- (void)mediaConnection:(KSMediaConnection *)mediaConnection peerConnection:(RTCPeerConnection *)peerConnection didAddStream:(RTCMediaStream *)stream;

- (RTCVideoTrack *)mediaConnectionOfVideoTrack:(KSMediaConnection *)mediaConnection {
    return _mediaCapture.videoTrack;
}

// 收到候选者
- (void)mediaConnection:(KSMediaConnection *)mediaConnection peerConnection:(RTCPeerConnection *)peerConnection didGenerateIceCandidate:(RTCIceCandidate *)candidate {
    NSMutableDictionary *body =[NSMutableDictionary dictionary];
    if (candidate) {
        body[@"candidate"] = candidate.sdp;
        body[@"sdpMid"] = candidate.sdpMid;
        body[@"sdpMLineIndex"]  = @(candidate.sdpMLineIndex);
        [_msgHandler trickleCandidate:mediaConnection.handleId candidate:body];
    }
    else{
        body[@"completed"] = @YES;
        [_msgHandler trickleCandidate:mediaConnection.handleId candidate:body];
    }
}

- (void)mediaConnection:(KSMediaConnection *)mediaConnection peerConnection:(RTCPeerConnection *)peerConnection didAddReceiver:(RTCRtpReceiver *)rtpReceiver streams:(NSArray<RTCMediaStream *> *)mediaStreams {
    RTCMediaStreamTrack *track = rtpReceiver.track;
    if([track.kind isEqualToString:kRTCMediaStreamTrackKindVideo]) {
        RTCVideoTrack *remoteVideoTrack = (RTCVideoTrack*)track;
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            mediaConnection.videoTrack = remoteVideoTrack;
            [weakSelf didAddMediaConnection:mediaConnection];
        });
    }
}

- (void)didAddMediaConnection:(KSMediaConnection *)connection {
    if (connection == nil) {
        return;
    }
    connection.index = (int)self.mediaConnections.count;
    [self.mediaConnections addObject:connection];
    if ([self.delegate respondsToSelector:@selector(webRTCManager:didAddMediaConnection:)]) {
        [self.delegate webRTCManager:self didAddMediaConnection:connection];
    }
}

- (void)mediaConnection:(KSMediaConnection *)mediaConnection didChangeIceConnectionState:(RTCIceConnectionState)newState {
    switch (newState) {
        case RTCIceConnectionStateDisconnected:
        case RTCIceConnectionStateClosed:
        case RTCIceConnectionStateFailed:
        {
            if (mediaConnection.isClose) {
                return;
            }
            mediaConnection.isClose      = YES;
            __weak typeof(self) weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf leaveOfHandleId:mediaConnection.handleId];
            });
        }
            break;
            
        default:
            break;
    }
}

- (void)leaveOfHandleId:(NSNumber *)handleId {
    KSMediaConnection *connection = [self mediaConnectionOfHandleId:handleId];
    if (connection == nil) {
        return;
    }
    [self removeConnection:connection];
    
    if ([self.delegate respondsToSelector:@selector(webRTCManager:leaveOfConnection:)]) {
        [self.delegate webRTCManager:self leaveOfConnection:connection];
    }
    if (self.mediaConnections.count == 1) {
        if ([self.delegate respondsToSelector:@selector(webRTCManagerHandlerEnd:)]) {
            [self.delegate webRTCManagerHandlerEnd:self];
        }
        [self close];
    }
}

#pragma mark - Get
- (AVCaptureSession *)captureSession {
    return self.mediaCapture.capturer.captureSession;
}

- (KSMediaConnection *)localConnection {
    return self.peerConnection;
}

#pragma mark - 事件
//MediaCapture
+ (void)switchCamera {
    [[KSWebRTCManager shared].mediaCapture switchCamera];
}
+ (void)switchTalkMode {
    [[KSWebRTCManager shared].mediaCapture switchTalkMode];
}
+ (void)startCapture {
    [[KSWebRTCManager shared].mediaCapture unmuteVideo];
}
+ (void)stopCapture {
    [[KSWebRTCManager shared].mediaCapture muteVideo];
    //[[KSWebRTCManager shared].mediaCapture stopCapture];
}
+ (void)speakerOff {
    [[KSWebRTCManager shared].mediaCapture speakerOff];
}
+ (void)speakerOn {
    [[KSWebRTCManager shared].mediaCapture speakerOn];
}

+ (void)muteAudio {
    [[KSWebRTCManager shared].mediaCapture muteAudio];
}

+ (void)unmuteAudio {
    [[KSWebRTCManager shared].mediaCapture unmuteAudio];
}

//SMediaConnection
+ (void)clearAllRenderer {
    for (KSMediaConnection *connection in [KSWebRTCManager shared].mediaConnections) {
        [connection clearRenderer];
    }
}

//Socket
+ (void)socketConnectServer:(NSString *)server {
     [[KSWebRTCManager shared].msgHandler connectServer:server];
}

+ (void)socketClose {
    [[KSWebRTCManager shared].msgHandler close];
}

+ (void)socketCreateSession {
    [[KSWebRTCManager shared].msgHandler createSession];
}

+ (void)socketSendHangup {
    [[KSWebRTCManager shared].msgHandler requestHangup];
}

//data
+ (KSMediaConnection *)connectionOfIndex:(NSInteger)index {
    if (index >= [KSWebRTCManager shared].connectCount) {
        return nil;
    }
    return [KSWebRTCManager shared].mediaConnections[index];
}

+ (NSInteger)connectionCount {
    return [KSWebRTCManager shared].connectCount;
}

+ (void)removeConnectionAtIndex:(int)index {
    if (index >= [KSWebRTCManager shared].mediaConnections.count) {
        return;
    }
    KSMediaConnection *connection = [KSWebRTCManager shared].mediaConnections[index];
    [[KSWebRTCManager shared].mediaConnections removeObjectAtIndex:index];
    [connection closeConnection];
    connection                    = nil;
}

- (void)removeConnection:(KSMediaConnection *)connection {
    if (connection == nil) {
        return;
    }
    [self.mediaConnections removeObject:connection];
    [connection closeConnection];
}

- (void)close {
    for (KSMediaConnection *connection in self.mediaConnections) {
        [connection closeConnection];
    }
    [self.mediaConnections removeAllObjects];
    
    [self.mediaCapture closeCapturer];
    self.mediaCapture = nil;
    
    [self.msgHandler close];
}

+ (void)close {
    [[KSWebRTCManager shared] close];
}

-(KSMediaConnection *)mediaConnectionOfHandleId:(NSNumber *)handleId {
    for (KSMediaConnection *connection in self.mediaConnections) {
        if (connection.handleId == handleId) {
            return connection;
        }
    }
    return nil;
}
#pragma mark - Get
- (int)connectCount {
    return (int)self.mediaConnections.count;;
}

#pragma mark - 懒加载
-(NSMutableArray *)mediaConnections {
    if (_mediaConnections == nil) {
        _mediaConnections = [NSMutableArray array];
    }
    return _mediaConnections;
}

@end
