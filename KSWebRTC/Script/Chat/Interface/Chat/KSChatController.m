//
//  KSChatController.m
//  Telegraph
//
//  Created by saeipi on 2020/8/17.
//

#import "KSChatController.h"
#import <WebRTC/RTCAudioSession.h>
#import "KSMsg.h"
#import "UIButton+Category.h"
#import "KSCallView.h"
#import "KSProfileView.h"
#import "KSTopBarView.h"
#import "KSCallState.h"
#import "KSWebRTCManager.h"
#import "KSCallBarView.h"
#import "UIFont+Category.h"
#import "KSSuperController+Category.h"
#import "KSMessageHandler.h"
#import "UILabel+Category.h"
#import "SVProgressHUD.h"
#import "NSString+Category.h"
#import "KSBtnInfo.h"
#import "KSCoolTile.h"
#import "KSAlertController.h"

@interface KSChatController()<KSWebRTCManagerDelegate,KSCallViewDataSource,KSTopBarViewDataSource,KSTopBarViewDelegate>

@property (nonatomic, weak  ) KSCallView    *callView;
@property (nonatomic, weak  ) KSTopBarView  *topBarView;
@property (nonatomic, strong) KSTileLayout  *tileLayout;
@property (nonatomic, strong) KSProfileInfo *profileInfo;

@property (nonatomic, assign, readonly) KSCallType myType;
@property (nonatomic, assign, readonly ) int       peerId;//对方ID
@property (nonatomic, assign, readonly ) BOOL      isCalled;//是否是被叫

@end

@implementation KSChatController
- (void)viewDidLoad {
    [super viewDidLoad];
    //初始化布局
    [self initTileLayout];
    //初始化页面
    [self initKit];
    //更新代理
    [KSWebRTCManager shared].delegate = self;
    //页面逻辑
    [self kitLogic];
}

-(void)dealloc {
    [KSWebRTCManager close];
}

+ (void)callWithType:(KSCallType)type callState:(KSCallStateMaintenance)callState isCaller:(BOOL)isCaller peerId:(int)peerId target:(UIViewController *)target {
    [KSWebRTCManager shared].callState = callState;
    [KSWebRTCManager shared].callType  = type;
    
    if (isCaller) {//主叫
        [KSWebRTCManager callToPeerId:peerId];
    }
    
    KSChatController *ctrl             = [[KSChatController alloc] init];
    ctrl.isSuperBar                    = YES;
    ctrl.displayFlag                   = KSDisplayFlagAnimatedFirst;
    UINavigationController *navCtrl    = [[UINavigationController alloc] initWithRootViewController:ctrl];
    navCtrl.modalPresentationStyle     = UIModalPresentationFullScreen;
    [target presentViewController:navCtrl animated:NO completion:nil];
}

- (void)initTileLayout {
    KSTileLayout *tileLayout   = [KSTileLayout layoutWithCallType:self.myType];
    CGFloat statusHeight       = [[UIApplication sharedApplication] statusBarFrame].size.height;
    CGFloat navHeight          = self.navigationController.navigationBar.bounds.size.height;
    /*
    if (self.myType == KSCallTypeSingleVideo) {
    tileLayout.topPadding      = statusHeight + KS_Extern_Point10;
    }
    else if (self.myType == KSCallTypeManyVideo) {
    tileLayout.topPadding      = statusHeight + navHeight + KS_Extern_Point10;
    }*/
    tileLayout.isCalled        = self.isCalled;
    tileLayout.topPadding      = statusHeight + navHeight + KS_Extern_Point10;
    //tileLayout.layout          = KSLayoutMake(90, 160, KS_Extern_Point10, KS_Extern_Point10);
    self.tileLayout            = tileLayout;
}

- (void)initKit {
    __weak typeof(self) weakSelf    = self;
    KSEventCallback callback        = ^(KSEventType eventType, id info) {
        NSLog(@"|------| eventType: %d |------|",(int)eventType);
        [weakSelf triggerEvent:eventType info:info];
    };

    KSCallView *callView            = [[KSCallView alloc] initWithFrame:self.view.bounds tileLayout:_tileLayout deviceSwitch:[KSWebRTCManager shared].deviceSwitch];
    callView.dataSource             = self;
    [callView initKits];//设置数据源后调用
    self.callView                   = callView;
    [callView setEventCallback:callback];
    [self.view addSubview:callView];
    
    //if (self.myType == KSCallTypeSingleVideo) {//测试
        UIButton *arrowBtn              = [UIButton ks_buttonWithNormalImg:@"icon_bar_double_arrow_white"];
        arrowBtn.frame                  = CGRectMake(0, 0, KS_Extern_Point24, KS_Extern_Point24);
        [arrowBtn addTarget:self action:@selector(onArrowClick) forControlEvents:UIControlEventTouchUpInside];
        self.superBar.backBarButtonItem = arrowBtn;
    //}
    [self.superBar toFront];
}

//self.profileInfo
- (KSProfileInfo *)profileWithTitle:(NSString *)title {
    KSProfileInfo *profileInfo = [KSProfileInfo profileWithCallType:self.myType isCalled:self.isCalled title:title];
    return profileInfo;
}

- (void)kitLogic {
    KSUserInfo *userInfo = [KSUserInfo userWithId:self.peerId];
    _profileInfo         = [self profileWithTitle:userInfo.name];
    [self updateProfileInfo:_profileInfo];
    
    KSCallStateMaintenance callState = [KSWebRTCManager shared].callState;
    switch (callState) {
        case KSCallStateMaintenanceCaller://拨打界面（挂断）
        {
            [self setAnswerState:KSAnswerStateAwait];
            [self initWebRTC];
        }
            break;
        case KSCallStateMaintenanceRinger://被叫界面（挂断/接听）
        case KSCallStateMaintenanceRinged:
        {
            if (self.isCalled) {//被叫
                [self setAnswerState:KSAnswerStateJoin];
                if (callState == KSCallStateMaintenanceRinger) {
                    //[KSWebRTCManager ringed];
                }
            }
            else{//主叫
                [self setAnswerState:KSAnswerStateAwait];
            }
            
            [self initWebRTC];
        }
            break;
        case KSCallStateMaintenanceAnswoer:
        case KSCallStateMaintenanceRecording://通话中
        {
            [self updateCalleeAnswerKit];
            [self callLayout];
        }
            break;
        default:
            break;
    }
}

#pragma mark - RTC初始化
- (void)initWebRTC {
    if ([KSWebRTCManager shared].localMediaTrack == nil) {
        KSConnectionSetting *connectionSetting = [[KSConnectionSetting alloc] init];
        connectionSetting.iceServer            = [[KSIceServer alloc] init];
        
        __weak typeof(self) weakSelf = self;
        KSAuthorizationCallback authCallback   = ^(KSDeviceType deviceType, AVAuthorizationStatus authStatus) {
            NSLog(@"|============| deviceType:%d, authStatus:%d |============|",(int)deviceType,(int)authStatus);
            [weakSelf deviceAuthorization:authStatus deviceType:deviceType];
        };
        
        KSCapturerSetting *capturerSetting     = [[KSCapturerSetting alloc] init];
        capturerSetting.isFront                = YES;
        capturerSetting.authCallback           = authCallback;
        //capturerSetting.resolution           = CGSizeMake(540, 960);
  
        KSMediaSetting *setting                = [[KSMediaSetting alloc] initWithConnectionSetting:connectionSetting capturerSetting:capturerSetting callType:self.myType];
        [KSWebRTCManager initRTCWithMediaSetting:setting];
    }
    if ([KSWebRTCManager shared].testType == KSTestTypeJanus) {
        [KSWebRTCManager socketConnectServer:@"ws://10.0.115.144:8188"];
    }
    else if ([KSWebRTCManager shared].testType == KSTestTypeSignalling) {
        [KSWebRTCManager socketConnectServer:@"ws://10.0.115.144:6080"];
    }
    
    [self createLocalView];
}

- (void)deviceAuthorization:(AVAuthorizationStatus)authStatus deviceType:(KSDeviceType)deviceType {
    if (authStatus == AVAuthorizationStatusDenied) {
        NSString *message = nil;
        switch (deviceType) {
            case KSDeviceTypeMicrophone:
                message = @"ks_app_global_text_auth_microphone";
                break;
            case KSDeviceTypeCamera:
                message = @"ks_app_global_text_auth_camera";
                break;
            default:
                break;
        }
        KSAlertInfo *alertInfo = [[KSAlertInfo alloc] initWithType:KSAlertTypeConfirml
                                                             title:nil
                                                           message:message
                                                            cancel:nil
                                                          confirml:@"ks_app_global_text_confirml"
                                                            target:self];
        [KSAlertController showInfo:alertInfo callback:^(KSAlertType actionType) {
        }];
    }
}

- (void)updateProfileInfo:(KSProfileInfo *)profileInfo {
    [self.callView setProfileInfo:profileInfo];
}

- (void)setAnswerState:(KSAnswerState)state {
    [self.callView setAnswerState:state];
    if (self.myType != KSCallTypeSingleAudio) {
        
    }
}

#pragma mark - 未开始会话的本地界面
- (void)createLocalView {
    switch (self.myType) {
        case KSCallTypeSingleAudio:
        case KSCallTypeSingleVideo:
        {
            dispatch_async(dispatch_get_main_queue(), ^{
                //[self.callView setScreenMediaTrack:[KSWebRTCManager shared].localMediaTrack];
                [self.callView setScreenMediaTrack:[KSWebRTCManager shared].screenMediaTrack];
            });
        }
            break;
        case KSCallTypeManyAudio:
            
            break;
        case KSCallTypeManyVideo:
        {
            [self.callView reloadCollectionView];
        }
            break;
        default:
            break;
    }
}

#pragma mark - 已经接通：从其他页面回到此页面
- (void)callLayout {
    switch (self.myType) {
        case KSCallTypeSingleAudio:
        case KSCallTypeSingleVideo:
        {
            KSWebRTCManager *manager = [KSWebRTCManager shared];
            for (int i = 0; i < manager.mediaTrackCount; i++) {
                KSMediaTrack *mt = [KSWebRTCManager mediaTrackOfIndex:i];
                if (mt.isLocal == NO) {
                    [self webRTCManager:manager didAddMediaTrack:mt];
                    break;
                }
            }
        }
            break;
        case KSCallTypeManyAudio:
        case KSCallTypeManyVideo:
        {
            [self.callView reloadCollectionView];
            
            /*
            KSWebRTCManager *manager = [KSWebRTCManager shared];
            for (KSMediaConnection *mediaConnection in manager.mediaConnections) {
                [self webRTCManager:manager didAddMediaConnection:mediaConnection];
            }*/
        }
        default:
            break;
    }
}

#pragma mark - 事件枚举switch
- (void)triggerEvent:(KSEventType)eventType info:(id)info {
    switch (eventType) {
        case KSEventTypeCallHangup://挂断
            [self callHangup];
            break;
        case KSEventTypeCalleeAnswer://被叫方接听
            [self calleeAnswer];
            break;
        case KSEventTypeInConversationMicrophoneOpen:
            [self inConversationMicrophoneOpen];
            break;
        case KSEventTypeInConversationMicrophoneClose:
            [self inConversationMicrophoneClose];
            break;
        case KSEventTypeInConversationVolumeOpen:
            [self inConversationVolumeOpen];
            break;
        case KSEventTypeInConversationVolumeClose:
            [self inConversationVolumeClose];
            break;
        case KSEventTypeInConversationCameraOpen:
            [self inConversationCameraOpen];
            break;
        case KSEventTypeInConversationCameraClose:
            [self inConversationCameraClose];
            break;
        case KSEventTypeInConversationBluetoothOpen:
            [self inConversationBluetoothOpen];
            break;
        case KSEventTypeInConversationBluetoothClose:
            [self inConversationBluetoothClose];
            break;
        case KSEventTypeMeetingThemeMicrophoneOpen:
            [self meetingThemeMicrophoneOpen];
            break;
        case KSEventTypeMeetingThemeMicrophoneClose:
            [self meetingThemeMicrophoneClose];
            break;
        case KSEventTypeMeetingThemeVolumeOpen:
            [self meetingThemeVolumeOpen];
            break;
        case KSEventTypeMeetingThemeVolumeClose:
            [self meetingThemeVolumeClose];
            break;
        case KSEventTypeMeetingThemeCameraOpen:
            [self meetingThemeCameraOpen];
            break;
        case KSEventTypeMeetingThemeCameraClose:
            [self meetingThemeCameraClose];
            break;
        case KSEventTypeMeetingThemeBluetoothOpen:
            [self meetingThemeBluetoothOpen];
            break;
        case KSEventTypeMeetingThemeBluetoothClose:
            [self meetingThemeBluetoothClose];
            break;
        case KSEventTypeStartMeeting:
            [self startMeeting];
            break;
        case KSEventTypeStartSwitch:
        {
            [self mediaSwitch:(KSMediaSwitch *)info];
        }
            break;
        default:
            break;
    }
}

// 按钮操作
- (void)onArrowClick {
    NSLog(@"%s",__FUNCTION__);
    [self tileWindow];
}

- (void)onSwitchCameraClick {
    //[KSWebRTCManager switchCamera];
    NSLog(@"%s",__FUNCTION__);
    [KSWebRTCManager clearAllRenderer];
    [KSWebRTCManager shared].callState = KSCallStateMaintenanceRecording;
    KSChatController *ctrl             = [[KSChatController alloc] init];
    ctrl.isSuperBar                    = YES;
    ctrl.displayFlag                   = KSDisplayFlagAnimatedFirst;
    UINavigationController *navCtrl    = [[UINavigationController alloc] initWithRootViewController:ctrl];
    navCtrl.modalPresentationStyle     = UIModalPresentationFullScreen;
    [self presentViewController:navCtrl animated:NO completion:nil];
}

- (void)onAddMemberClick {
    NSLog(@"%s",__FUNCTION__);
//    KSConnectionSetting *connectionSetting = [[KSConnectionSetting alloc] init];
//    connectionSetting.callType             = KSCallTypeManyVideo;
//    connectionSetting.iceServer            = [[KSIceServer alloc] init];
//    KSMediaConnection *mc = [[KSMediaConnection alloc] initWithSetting:connectionSetting];
//    [[KSWebRTCManager shared].mediaConnections addObject:mc];
//    [self.callView insertItemsAtIndex:[KSWebRTCManager shared].connectCount-1];
}

- (void)onScaleDownClick {
    NSLog(@"%s",__FUNCTION__);
    [self dismiss];
}

- (void)onIdentifierClick {
    NSLog(@"%s",__FUNCTION__);
}

- (void)closeCtrl {
    [self dismissViewControllerAnimated:NO completion:nil];
}

- (void)closeRTC {
    [KSWebRTCManager leave];
    [KSWebRTCManager close];
    [self closeCtrl];
}

#pragma mark - 挂断
- (void)callHangup {
    NSLog(@"%s",__FUNCTION__);
    [self closeRTC];
}

#pragma mark - 被叫方接听
-(void)calleeAnswer {
    NSLog(@"%s",__FUNCTION__);
    [KSWebRTCManager answoer];
    [KSWebRTCManager updateStartingTime];//更新倒计时开始时间(点击接听和收到接听两处更新)
    [self updateCalleeAnswerKit];
}

- (void)updateCalleeAnswerKit {
    switch (self.myType) {
        case KSCallTypeSingleAudio:
            [self setAnswerState:KSAnswerStateSession];
            //[self.callView displayCallBar];
            break;
        case KSCallTypeSingleVideo:
            //[self.callView displayCallBar];
        break;
        default:
            break;
    }
    [self.topBarView showKitOfStartingTime:[KSWebRTCManager shared].startingTime];
    [self.callView displayCallBar];
}

//会话中开启麦克风
- (void)inConversationMicrophoneOpen {
    [KSWebRTCManager unmuteAudio];
}

//会话中关闭麦克风
- (void)inConversationMicrophoneClose {
    [KSWebRTCManager muteAudio];
}

//会话中开启声音
- (void)inConversationVolumeOpen {
    [KSWebRTCManager speakerOn];
}

//会话中静音
- (void)inConversationVolumeClose {
    [KSWebRTCManager speakerOff];
}

//会话中开启摄像机
- (void)inConversationCameraOpen {
    [KSWebRTCManager startCapture];
}

//会话中关闭摄像机
- (void)inConversationCameraClose {
    [KSWebRTCManager stopCapture];
}

//会话中开启蓝牙
- (void)inConversationBluetoothOpen {
    
}

//会话中关闭蓝牙
- (void)inConversationBluetoothClose {
    
}

//会议主题面板中开启麦克风
- (void)meetingThemeMicrophoneOpen {
    [KSWebRTCManager unmuteAudio];
}

//会议主题面板中关闭麦克风
- (void)meetingThemeMicrophoneClose {
    [KSWebRTCManager muteAudio];
}

//会议主题面板中开启声音
- (void)meetingThemeVolumeOpen {
    [KSWebRTCManager speakerOn];
}

//会议主题面板中静音
- (void)meetingThemeVolumeClose {
    [KSWebRTCManager speakerOff];
}

//会议主题面板中开启摄像机
- (void)meetingThemeCameraOpen {
    [KSWebRTCManager startCapture];
}

//会议主题面板中关闭摄像机
- (void)meetingThemeCameraClose {
    [KSWebRTCManager stopCapture];
}

//会议主题面板中开启蓝牙
- (void)meetingThemeBluetoothOpen {
    
}

//会议主题面板中关闭蓝牙
- (void)meetingThemeBluetoothClose {
    
}

//开始会议
- (void)startMeeting {
    
}

//此处修改 callType 01
-(void)mediaSwitch:(KSMediaSwitch *)mediaSwitch {
    [KSWebRTCManager shared].callType = mediaSwitch.callType;//更新类型
    if (mediaSwitch.mediaType == KSCallMenuTypeVideo) {
        [KSWebRTCManager switchToSingleVideo];
        [KSWebRTCManager switchToVideoCall];
    }
    else if (mediaSwitch.mediaType == KSCallMenuTypeVoice){
        [KSWebRTCManager switchToSingleAudio];
        [KSWebRTCManager switchToVoiceCall];
    }
    if (self.isCalled) {
        [self calleeAnswer];
    }
}

#pragma mark - KSTopBarViewDataSource
- (NSMutableArray *)menuDatasOfTopBarView:(KSTopBarView *)topBarView {
    if (self.myType == KSCallTypeSingleAudio) {
        return [KSBtnInfo topAudioBarBtns];
    }
    if (self.myType == KSCallTypeSingleVideo) {
        return [KSBtnInfo topVideoBarBtns];
    }
    return [NSMutableArray array];
}

- (NSString *)sessionIDOfTopBarView:(KSTopBarView *)topBarView {
    return [[KSWebRTCManager shared].session.room uppercaseString];
}

#pragma mark - KSTopBarViewDelegate
- (void)topBarView:(KSTopBarView *)topBarView btnInfo:(KSBtnInfo *)btnInfo {
    switch (btnInfo.btnType) {
        case KSCallBarBtnTypeSwitchCamera:
            [KSWebRTCManager switchCamera];
            break;
        case KSCallBarBtnTypeAddMember:
            [self showMessage:@"ks_app_global_text_look_forward_to"];
            break;
        case KSCallBarBtnTypeZoomOut:
            [self tileWindow];
            break;
        default:
            break;
    }
}

#pragma mark - 小窗
- (void)tileWindow {
    [_callView clearRender];
    [_topBarView hiddenKit];

    [KSWebRTCManager displayTile];

    [self closeCtrl];
}

#pragma mark - RTC回调
//KSWebRTCManagerDelegate
#pragma mark - KSMediaConnection
- (void)webRTCManager:(KSWebRTCManager *)webRTCManager didAddMediaTrack:(KSMediaTrack *)mediaTrack {
    switch (self.myType) {
        case KSCallTypeSingleAudio:
        case KSCallTypeSingleVideo:
        {
            if (mediaTrack.isLocal) {
                
            }
            else{
                //[self.callView setScreenMediaTrack:mediaTrack];
                //[self.callView setTileMediaTrack:[KSWebRTCManager shared].localMediaTrack];
                [self.callView setScreenMediaTrack:[KSWebRTCManager shared].screenMediaTrack];
                [self.callView setTileMediaTrack:[KSWebRTCManager shared].tileMediaTrack];
            }
        }
            break;
        case KSCallTypeManyAudio:
        case KSCallTypeManyVideo:
        {
            [self.callView reloadCollectionView];
            //[self.callView insertItemsAtIndex:[KSWebRTCManager shared].mediaTrackCount - 1];
        }
            break;
        default:
            break;
    }
}

- (void)webRTCManager:(KSWebRTCManager *)webRTCManager mediaConnection:(KSMediaConnection *)mediaConnection peerConnection:(RTCPeerConnection *)peerConnection didChangeIceConnectionState:(RTCIceConnectionState)newState {
    switch (newState) {
        case RTCIceConnectionStateNew:
            break;
        case RTCIceConnectionStateChecking:
            break;
        case RTCIceConnectionStateConnected:
            break;
        case RTCIceConnectionStateCompleted:
            break;
        case RTCIceConnectionStateFailed:
            break;
        case RTCIceConnectionStateDisconnected:
            //[self showMessage:@"通话断开"];
            break;
        case RTCIceConnectionStateClosed:
            //[self showMessage:@"通话关闭"];
            break;
        case RTCIceConnectionStateCount:
            break;
        default:
            break;
    }
}

#pragma mark - Message
- (void)showMessage:(NSString *)message {
    [SVProgressHUD showSuccessWithStatus:message.localizde];
}

- (void)webRTCManager:(KSWebRTCManager *)webRTCManager ackCall:(KSAckCall *)ackCall {
}

- (void)webRTCManagerCallTimeout :(KSWebRTCManager *)webRTCManager {
    [self showMessage:@"ks_app_global_text_call_timeout"];
    [self closeCtrl];
}

//只剩下自己（KSWebRTCManager已经调用Leave和Close）
- (void)webRTCManagerHandlerEnd:(KSWebRTCManager *)webRTCManager {
    [self closeCtrl];
}

- (void)webRTCManagerDisconnected:(KSWebRTCManager *)webRTCManager {
    [self showMessage:@"ks_app_global_text_dropped_call"];
    [self closeCtrl];
}

- (void)webRTCManager:(KSWebRTCManager *)webRTCManager ackJoined:(KSAckJoined *)ackJoined {
    [self.topBarView showKitOfStartingTime:[KSWebRTCManager shared].startingTime];
    [self.callView displayCallBar];
}

- (void)webRTCManager:(KSWebRTCManager *)webRTCManager ackStart:(KSAckStart *)ackStart {
}

//有人离开
- (void)webRTCManager:(KSWebRTCManager *)webRTCManager ackLeft:(KSAckLeft *)ackLeft mediaTrack:(KSMediaTrack *)mediaTrack {
    NSString *msg = [NSString ks_localizde:@"ks_app_global_text_user_hungup"];
    [self showMessage:[NSString stringWithFormat:msg,[KSUserInfo userWithId:ackLeft.user_id].name]];
    switch (self.myType) {
        case KSCallTypeSingleVideo:
        case KSCallTypeManyVideo:
            [self.callView deleteItemsAtIndex:mediaTrack.index];
            break;
        default:
            break;
    }
}

//对方接听 弃用
- (void)webRTCManager:(KSWebRTCManager *)webRTCManager ackAnswer:(KSAckAnswer *)answer {
    //[self.topBarView showKitOfStartingTime:[KSWebRTCManager shared].startingTime];
    //[self.callView displayCallBar];
}

- (void)webRTCManager:(KSWebRTCManager *)webRTCManager mediaState:(KSMediaState)mediaState userInfo:(KSUserInfo *)userInfo {
    NSLog(@"|============| switchType : %d, userid : %lld |============|",(int)mediaState,userInfo.ID);
}

- (void)webRTCManager:(KSWebRTCManager *)webRTCManager changeMediaType:(KSChangeMediaType)mediaType userInfo:(KSUserInfo *)userInfo {
    NSLog(@"|============| mediaType : %d, userid : %lld |============|",(int)mediaType,userInfo.ID);
    switch (mediaType) {
        case KSChangeMediaTypeVoice://切换到音频
        {
            [KSWebRTCManager switchToSingleAudio];
            [self.callView updateSwitchOfCalltype:self.myType];
            [self showMessage:@"ks_app_global_text_switch_to_voice_call"];
        }
            break;
        case KSChangeMediaTypeVideo://切换到视频
        {
            [KSWebRTCManager switchToSingleVideo];
            [self.callView updateSwitchOfCalltype:self.myType];
            [self showMessage:@"ks_app_global_text_switch_to_video_call"];
            //[self.callView setScreenMediaTrack:[KSWebRTCManager shared].localMediaTrack];
            [self.callView setScreenMediaTrack:[KSWebRTCManager shared].screenMediaTrack];
        }
            break;
        default:
            break;
    }
    //更新
    [_profileInfo updateDescOfCallType:self.myType isCalled:self.isCalled];
    [self updateProfileInfo:_profileInfo];
}

//占线
- (void)webRTCManagerLineBusy:(KSWebRTCManager *)webRTCManager userInfo:(KSUserInfo *)userInfo {
    [self showMessage:@"ks_app_global_text_subscriber_engaged"];
    [self closeRTC];
}

- (void)webRTCManager:(KSWebRTCManager *)webRTCManager requestError:(KSRequestError *)error {
    NSLog(@"|============| 错误: %@ |============|",error.errorInfo);
    [SVProgressHUD showErrorWithStatus:error.errorInfo];
    [self closeRTC];
    return;
    
    switch (error.type) {
        case KSRequestTypeUnknown:
            
            break;
        case KSRequestTypeNewCall:
            
            break;
        case KSRequestTypeCandidate:
            
            break;
        case KSRequestTypeAnswoer:
            
            break;
        case KSRequestTypeRinged:
            
            break;
        case KSRequestTypeStart:
            
            break;
        case KSRequestTypeSendOffer:
            
            break;
        case KSRequestTypeSendAnswer:
            
            break;
        case KSRequestTypeLeave:
            
            break;
        case KSRequestTypeRTCInfo:
            
            break;
        case KSRequestTypeJoinOffer:
            
            break;
        default:
            break;
    }
}

#pragma mark - KSCallViewDataSource
- (NSInteger)callView:(KSCallView *)callView numberOfItemsInSection:(NSInteger)section {
    return [KSWebRTCManager shared].mediaTrackCount;
}

- (KSMediaTrack *)callView:(KSCallView *)callView itemAtIndexPath:(NSIndexPath *)indexPath {
    return [KSWebRTCManager mediaTrackOfIndex:indexPath.item];
}

- (KSCallType)callTypeOfCallView:(KSCallView *)callView {
    return self.myType;
}

//懒加载
-(KSTopBarView *)topBarView {
    if (_topBarView == nil) {
        KSTopBarView *topBarView = [[KSTopBarView alloc] initWithFrame:self.superBar.bounds];
        topBarView.dataSource    = self;
        topBarView.delegate      = self;
        [self.superBar addSubview:topBarView];
        _topBarView              = topBarView;
        [topBarView.identifierBtn addTarget:self action:@selector(onIdentifierClick) forControlEvents:UIControlEventTouchUpInside];
    }
    return _topBarView;
}

#pragma mark - Get
-(KSCallType)myType {
    return [KSWebRTCManager shared].callType;
}

-(int)peerId {
    return [KSWebRTCManager shared].peerId;
}
-(void)setPeerId:(int)inId {
}

-(BOOL)isCalled {
    return [KSWebRTCManager shared].isCalled;
}
-(void)setIsCalled:(BOOL)isInCalled {
}

@end


