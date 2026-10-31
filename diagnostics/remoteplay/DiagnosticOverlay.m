#import <UIKit/UIKit.h>

// Diagnostic UI only: no frame capture, networking, credentials or controller input.
@interface VLMRemotePlayDiagnostic01 : NSObject
@property(nonatomic, strong) UILabel *badge;
@property(nonatomic, strong) NSTimer *timer;
- (void)refresh;
- (void)start;
@end

@implementation VLMRemotePlayDiagnostic01
- (void)refresh {
    UIApplication *app = UIApplication.sharedApplication;
    if (app.applicationState != UIApplicationStateActive) {
        self.badge.hidden = YES;
        return;
    }
    UIWindow *chosen = nil;
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.hidden || window.alpha < 0.1 || window.windowLevel != UIWindowLevelNormal) continue;
            if (!chosen || window.isKeyWindow) chosen = window;
            if (window.isKeyWindow) break;
        }
    }
    if (!chosen) { self.badge.hidden = YES; return; }
    if (!self.badge) {
        self.badge = [[UILabel alloc] initWithFrame:CGRectZero];
        self.badge.text = @"VELMIRA TEST 01";
        self.badge.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightBold];
        self.badge.textColor = UIColor.blackColor;
        self.badge.backgroundColor = [UIColor.greenColor colorWithAlphaComponent:0.85];
        self.badge.textAlignment = NSTextAlignmentCenter;
        self.badge.layer.cornerRadius = 5;
        self.badge.clipsToBounds = YES;
        self.badge.userInteractionEnabled = NO;
        self.badge.isAccessibilityElement = NO;
    }
    if (self.badge.superview != chosen) {
        [self.badge removeFromSuperview];
        [chosen addSubview:self.badge];
    }
    UIEdgeInsets safe = chosen.safeAreaInsets;
    CGFloat width = MIN(142, MAX(0, CGRectGetWidth(chosen.bounds) - safe.left - safe.right - 16));
    self.badge.frame = CGRectMake(safe.left + 8, safe.top + 8, width, 24);
    self.badge.hidden = NO;
    [chosen bringSubviewToFront:self.badge];
}
- (void)start {
    if (self.timer) return;
    self.timer = [NSTimer timerWithTimeInterval:1 target:self selector:@selector(refresh)
                                     userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
    [self refresh];
}
@end

static VLMRemotePlayDiagnostic01 *diagnostic;
__attribute__((constructor))
static void VLMStartDiagnostic01(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        diagnostic = [VLMRemotePlayDiagnostic01 new];
        [diagnostic start];
    });
}
