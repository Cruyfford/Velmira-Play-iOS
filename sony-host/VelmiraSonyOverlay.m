#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// Diagnostic Sony-host integration. Does not use Chiaki, Sony private symbols,
// video frames, or controller interception. iOS requires a valid same-team
// signature for the main executable and every non-Apple dylib/framework.
@interface VMHitThroughWindow : UIWindow
@end
@implementation VMHitThroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self.rootViewController.view || hit == self) return nil;
    return hit;
}
@end

@interface VMSonyOverlay : NSObject
@property(nonatomic, strong) VMHitThroughWindow *window;
@property(nonatomic, strong) UIView *panel;
@property(nonatomic, assign) BOOL started;
+ (instancetype)shared;
- (void)startObserving;
@end

@implementation VMSonyOverlay
+ (instancetype)shared {
    static VMSonyOverlay *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [VMSonyOverlay new]; });
    return instance;
}
- (void)startObserving {
    if (self.started) return;
    self.started = YES;
    NSLog(@"[VelmiraSonyHost] Overlay loaded, deferring UI until application becomes active");
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(onBecomeActive:)
                   name:UIApplicationDidBecomeActiveNotification object:nil];
    [center addObserver:self selector:@selector(onEnterBackground:)
                   name:UIApplicationDidEnterBackgroundNotification object:nil];
    // May be injected after the application is already active.
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
        [self installIfPossible];
    }
}
- (void)onBecomeActive:(NSNotification *)note { [self installIfPossible]; }
- (void)onEnterBackground:(NSNotification *)note { self.window.hidden = YES; }
- (void)installIfPossible {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self installIfPossible]; });
        return;
    }
    if (self.window) { self.window.hidden = NO; return; }
    @try {
        UIWindowScene *scene = nil;
        for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
            if ([candidate isKindOfClass:UIWindowScene.class] &&
                candidate.activationState == UISceneActivationStateForegroundActive) {
                scene = (UIWindowScene *)candidate;
                break;
            }
        }
        if (!scene) {
            NSLog(@"[VelmiraSonyHost] No foreground window scene yet");
            return;
        }
        VMHitThroughWindow *window = [[VMHitThroughWindow alloc] initWithWindowScene:scene];
        window.frame = scene.coordinateSpace.bounds;
        // Do not supersede the system alert window level.
        window.windowLevel = UIWindowLevelNormal + 2;
        UIViewController *root = [UIViewController new];
        root.view.backgroundColor = UIColor.clearColor;
        window.rootViewController = root;

        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.frame = CGRectMake(12, 90, 54, 46);
        button.backgroundColor = [UIColor colorWithRed:0.08 green:0.11 blue:0.18 alpha:0.9];
        [button setTitle:@"V" forState:UIControlStateNormal];
        [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont boldSystemFontOfSize:22];
        button.layer.cornerRadius = 15;
        [button addTarget:self action:@selector(togglePanel:) forControlEvents:UIControlEventTouchUpInside];
        [root.view addSubview:button];

        UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(12, 144, 300, 132)];
        panel.backgroundColor = [UIColor colorWithRed:0.07 green:0.09 blue:0.16 alpha:0.97];
        panel.layer.cornerRadius = 15;
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(12, 8, 278, 115)];
        label.numberOfLines = 0;
        label.textColor = UIColor.whiteColor;
        label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        label.text = @"VELMIRA • SONY HOST V2\nSony Remote Play binary host\nNo Chiaki loaded\nDiagnostic UI only — features not yet ported";
        [panel addSubview:label];
        [root.view addSubview:panel];
        panel.hidden = YES;
        self.window = window;
        self.panel = panel;
        window.hidden = NO;
        NSLog(@"[VelmiraSonyHost] Diagnostic UI attached to active Sony scene");
    } @catch (NSException *exception) {
        NSLog(@"[VelmiraSonyHost] Overlay UI exception: %@", exception);
        self.window = nil;
        self.panel = nil;
    }
}
- (void)togglePanel:(id)sender { self.panel.hidden = !self.panel.hidden; }
@end

__attribute__((constructor)) static void velmira_sony_overlay_init(void) {
    // No UIKit calls in Mach-O dynamic initializer: the app may not yet have
    // initialized UIApplication or its scene.
    dispatch_async(dispatch_get_main_queue(), ^{
        [[VMSonyOverlay shared] startObserving];
    });
}
