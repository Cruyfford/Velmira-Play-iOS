#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// Experimental proof: Sony is the app host. No Chiaki code or Sony binary is shipped here.
@interface VMHitThroughWindow : UIWindow
@end
@implementation VMHitThroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return hit == self.rootViewController.view ? nil : hit;
}
@end

@interface VMSonyOverlay : NSObject
@property(nonatomic,strong) VMHitThroughWindow *window;
@property(nonatomic,strong) UIView *panel;
+ (instancetype)shared;
- (void)start;
@end
@implementation VMSonyOverlay
+ (instancetype)shared {
    static VMSonyOverlay *value;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ value = [VMSonyOverlay new]; });
    return value;
}
- (void)start {
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(install)
        name:UIApplicationDidBecomeActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(hide)
        name:UIApplicationDidEnterBackgroundNotification object:nil];
    [self install];
}
- (void)hide { self.window.hidden = YES; }
- (void)install {
    if (self.window) { self.window.hidden = NO; return; }
    UIWindowScene *scene = nil;
    for (UIScene *candidate in [UIApplication sharedApplication].connectedScenes) {
        if ([candidate isKindOfClass:UIWindowScene.class] &&
            candidate.activationState == UISceneActivationStateForegroundActive) {
            scene = (UIWindowScene *)candidate;
            break;
        }
    }
    if (!scene) return;
    self.window = [[VMHitThroughWindow alloc] initWithWindowScene:scene];
    self.window.frame = scene.coordinateSpace.bounds;
    self.window.windowLevel = UIWindowLevelAlert + 1;
    UIViewController *root = [UIViewController new];
    root.view.backgroundColor = UIColor.clearColor;
    self.window.rootViewController = root;
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = CGRectMake(12, 90, 54, 46);
    button.backgroundColor = [UIColor colorWithRed:0.08 green:0.11 blue:0.18 alpha:0.88];
    [button setTitle:@"V" forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:22];
    button.layer.cornerRadius = 15;
    button.layer.borderWidth = 1;
    button.layer.borderColor = UIColor.cyanColor.CGColor;
    [button addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
    [root.view addSubview:button];
    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(12, 144, 290, 146)];
    panel.backgroundColor = [UIColor colorWithRed:0.07 green:0.09 blue:0.16 alpha:0.97];
    panel.layer.cornerRadius = 15;
    panel.layer.borderWidth = 1;
    panel.layer.borderColor = UIColor.cyanColor.CGColor;
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(12, 11, 270, 118)];
    label.numberOfLines = 0;
    label.textColor = UIColor.whiteColor;
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    label.text = @"VELMIRA · SONY HOST TEST\n\nالمحرك: برنامج Sony الأصلي\nChiaki: غير موجود في هذه النسخة\nميزات Velmira: لم تُنقل بعد";
    [panel addSubview:label];
    [root.view addSubview:panel];
    panel.hidden = YES;
    self.panel = panel;
    self.window.hidden = NO;
}
- (void)togglePanel { self.panel.hidden = !self.panel.hidden; }
@end

__attribute__((constructor)) static void velmira_sony_overlay_init(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ [[VMSonyOverlay shared] start]; });
}
