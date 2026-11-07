//
//  AgoraMenu.m
//  Floating, draggable, animated menu (blue / black "terminal" look).
//  Added on top of the host app's key window, so it needs no jailbreak.
//

#import "AgoraMenu.h"
#import "AgoraRecorder.h"
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>

#define AM_BLUE [UIColor colorWithRed:0.10 green:0.55 blue:1.00 alpha:1.0]
#define AM_CYAN [UIColor colorWithRed:0.25 green:0.85 blue:1.00 alpha:1.0]
#define AM_BG   [UIColor colorWithRed:0.02 green:0.03 blue:0.07 alpha:0.95]
#define AM_DIM  [UIColor colorWithWhite:1.0 alpha:0.55]
#define AM_RED  [UIColor colorWithRed:1.0 green:0.25 blue:0.30 alpha:1.0]

static const CGFloat kPanelW = 300.0;
static const CGFloat kPanelH = 360.0;

#pragma mark - Helpers

static UIFont *AMFont(CGFloat size, BOOL bold) {
    UIFont *f = [UIFont fontWithName:(bold ? @"Menlo-Bold" : @"Menlo-Regular") size:size];
    return f ?: [UIFont systemFontOfSize:size weight:(bold ? UIFontWeightBold : UIFontWeightRegular)];
}

static UIWindow *AMKeyWindow(void) {
    UIApplication *app = [UIApplication sharedApplication];
    UIWindow *fallback = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            if (ws.activationState != UISceneActivationStateForegroundActive) continue;
            for (UIWindow *w in ws.windows) {
                if (w.isKeyWindow) return w;
            }
            if (!fallback) fallback = ws.windows.firstObject;
        }
    }
    if (!fallback) fallback = app.keyWindow;
    if (!fallback) fallback = app.windows.firstObject;
    return fallback;
}

static UIViewController *AMTopVC(void) {
    UIViewController *vc = AMKeyWindow().rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

static UILabel *AMLabel(CGRect f, NSString *text, CGFloat size, BOOL bold, UIColor *color, NSTextAlignment align) {
    UILabel *l = [[UILabel alloc] initWithFrame:f];
    l.text = text;
    l.font = AMFont(size, bold);
    l.textColor = color;
    l.textAlignment = align;
    l.adjustsFontSizeToFitWidth = YES;
    l.minimumScaleFactor = 0.7;
    return l;
}

static UIButton *AMButton(CGRect f, NSString *title, id target, SEL action) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = f;
    b.layer.cornerRadius = 10;
    b.layer.borderWidth = 1;
    b.layer.borderColor = AM_BLUE.CGColor;
    b.backgroundColor = [AM_BLUE colorWithAlphaComponent:0.12];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:AM_CYAN forState:UIControlStateNormal];
    b.titleLabel.font = AMFont(13, YES);
    [b addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

#pragma mark - Menu

@interface AgoraMenu () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UIButton *fab;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UIView *mainPage;
@property (nonatomic, strong) UIView *listPage;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSArray<NSString *> *paths;
@property (nonatomic, strong) AVAudioPlayer *player;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, assign) BOOL blink;
@property (nonatomic, assign) BOOL placedFab;
@property (nonatomic, assign) CGFloat panelScale;
@end

@implementation AgoraMenu

+ (instancetype)shared {
    static AgoraMenu *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [AgoraMenu new]; });
    return s;
}

+ (void)install {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[AgoraMenu shared] start];
    });
}

- (void)start {
    if (self.timer) return;
    self.panelScale = 1.0;
    self.paths = @[];
    [self buildFab];
    [self buildPanel];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    [self tick];
}

#pragma mark Build UI

- (void)buildFab {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(0, 0, 52, 52);
    b.backgroundColor = [UIColor colorWithRed:0.02 green:0.03 blue:0.08 alpha:0.92];
    b.layer.cornerRadius = 26;
    b.layer.borderWidth = 1.5;
    b.layer.borderColor = AM_BLUE.CGColor;
    b.layer.shadowColor = AM_BLUE.CGColor;
    b.layer.shadowOpacity = 0.9;
    b.layer.shadowRadius = 10;
    b.layer.shadowOffset = CGSizeZero;
    [b setTitle:@"A" forState:UIControlStateNormal];
    [b setTitleColor:AM_CYAN forState:UIControlStateNormal];
    b.titleLabel.font = AMFont(22, YES);
    [b addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)];
    [b addGestureRecognizer:pan];
    self.fab = b;
    [self addPulse];
}

- (void)addPulse {
    if ([self.fab.layer animationForKey:@"pulse"]) return;
    CABasicAnimation *p = [CABasicAnimation animationWithKeyPath:@"shadowRadius"];
    p.fromValue = @4;
    p.toValue = @16;
    p.duration = 1.2;
    p.autoreverses = YES;
    p.repeatCount = HUGE_VALF;
    [self.fab.layer addAnimation:p forKey:@"pulse"];
}

- (void)buildPanel {
    UIView *p = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kPanelW, kPanelH)];
    p.backgroundColor = AM_BG;
    p.layer.cornerRadius = 18;
    p.layer.borderWidth = 1.5;
    p.layer.borderColor = AM_BLUE.CGColor;
    p.layer.shadowColor = AM_BLUE.CGColor;
    p.layer.shadowOpacity = 0.6;
    p.layer.shadowRadius = 14;
    p.layer.shadowOffset = CGSizeZero;
    p.hidden = YES;

    CABasicAnimation *glow = [CABasicAnimation animationWithKeyPath:@"borderColor"];
    glow.fromValue = (id)AM_BLUE.CGColor;
    glow.toValue = (id)AM_CYAN.CGColor;
    glow.duration = 1.6;
    glow.autoreverses = YES;
    glow.repeatCount = HUGE_VALF;
    [p.layer addAnimation:glow forKey:@"glow"];
    self.panel = p;

    [self buildMainPage];
    [self buildListPage];
}

- (void)buildMainPage {
    UIView *page = [[UIView alloc] initWithFrame:self.panel.bounds];

    [page addSubview:AMLabel(CGRectMake(16, 14, 170, 22), @"> AGORA REC", 15, YES, AM_CYAN, NSTextAlignmentLeft)];
    self.statusLabel = AMLabel(CGRectMake(186, 14, 98, 22), @"● IDLE", 12, YES, AM_DIM, NSTextAlignmentRight);
    [page addSubview:self.statusLabel];

    // Animated scanner line under the header.
    CAGradientLayer *line = [CAGradientLayer layer];
    line.frame = CGRectMake(16, 44, kPanelW - 32, 2);
    line.colors = @[(id)[AM_BLUE colorWithAlphaComponent:0.15].CGColor, (id)AM_CYAN.CGColor, (id)[AM_BLUE colorWithAlphaComponent:0.15].CGColor];
    line.startPoint = CGPointMake(0, 0.5);
    line.endPoint = CGPointMake(1, 0.5);
    line.locations = @[@0, @0.5, @1];
    CABasicAnimation *scan = [CABasicAnimation animationWithKeyPath:@"locations"];
    scan.fromValue = @[@-1.0, @-0.5, @0.0];
    scan.toValue = @[@1.0, @1.5, @2.0];
    scan.duration = 1.8;
    scan.repeatCount = HUGE_VALF;
    [line addAnimation:scan forKey:@"scan"];
    [page.layer addSublayer:line];

    NSArray *titles = @[@"REC   Recording", @"MON   Live monitor", @"3X    Monitor 3x speed"];
    for (NSInteger i = 0; i < 3; i++) {
        CGFloat y = 62 + i * 46;
        [page addSubview:AMLabel(CGRectMake(16, y, 190, 31), titles[i], 13, NO, [UIColor whiteColor], NSTextAlignmentLeft)];
        UISwitch *sw = [[UISwitch alloc] init];
        sw.onTintColor = AM_BLUE;
        sw.tag = 101 + i;
        sw.frame = CGRectMake(kPanelW - 16 - sw.bounds.size.width, y, sw.bounds.size.width, sw.bounds.size.height);
        [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        [page addSubview:sw];
    }

    [page addSubview:AMButton(CGRectMake(16, 212, kPanelW - 32, 40), @"▶  RECORDINGS", self, @selector(showListPage))];
    [page addSubview:AMButton(CGRectMake(16, 262, kPanelW - 32, 36), @"✕  CLOSE", self, @selector(togglePanel))];
    [page addSubview:AMLabel(CGRectMake(0, 322, kPanelW, 22), @"by Aflatoon", 11, YES, [AM_BLUE colorWithAlphaComponent:0.85], NSTextAlignmentCenter)];

    self.mainPage = page;
    [self.panel addSubview:page];
}

- (void)buildListPage {
    UIView *page = [[UIView alloc] initWithFrame:self.panel.bounds];
    page.hidden = YES;

    [page addSubview:AMButton(CGRectMake(12, 10, 78, 30), @"‹ BACK", self, @selector(showMainPage))];
    [page addSubview:AMLabel(CGRectMake(100, 14, kPanelW - 116, 22), @"RECORDINGS", 14, YES, AM_CYAN, NSTextAlignmentRight)];

    UITableView *tv = [[UITableView alloc] initWithFrame:CGRectMake(8, 52, kPanelW - 16, 270) style:UITableViewStylePlain];
    tv.backgroundColor = [UIColor clearColor];
    tv.separatorColor = [AM_BLUE colorWithAlphaComponent:0.3];
    tv.dataSource = self;
    tv.delegate = self;
    tv.rowHeight = 46;
    self.table = tv;
    [page addSubview:tv];

    [page addSubview:AMLabel(CGRectMake(0, 330, kPanelW, 20), @"by Aflatoon", 11, YES, [AM_BLUE colorWithAlphaComponent:0.85], NSTextAlignmentCenter)];

    self.listPage = page;
    [self.panel addSubview:page];
}

#pragma mark Periodic upkeep

- (void)tick {
    UIWindow *w = AMKeyWindow();
    if (!w) return;

    if (self.fab.superview != w) {
        [self.fab removeFromSuperview];
        if (!self.placedFab) {
            self.fab.center = CGPointMake(w.bounds.size.width - 44, 140);
            self.placedFab = YES;
        }
        [w addSubview:self.fab];
    }
    if (!self.panel.hidden && self.panel.superview != w) {
        [self.panel removeFromSuperview];
        self.panel.center = CGPointMake(w.bounds.size.width / 2, w.bounds.size.height / 2);
        [w addSubview:self.panel];
    }
    if (!self.panel.hidden) [w bringSubviewToFront:self.panel];
    [w bringSubviewToFront:self.fab];
    [self addPulse];

    self.blink = !self.blink;
    if ([[AgoraRecorder sharedRecorder] isCurrentlyRecording]) {
        self.statusLabel.text = self.blink ? @"● REC" : @"○ REC";
        self.statusLabel.textColor = AM_RED;
    } else {
        self.statusLabel.text = @"● IDLE";
        self.statusLabel.textColor = AM_DIM;
    }
}

#pragma mark Actions

- (void)pan:(UIPanGestureRecognizer *)g {
    UIView *v = g.view;
    UIView *sv = v.superview;
    if (!sv) return;
    CGPoint t = [g translationInView:sv];
    CGPoint c = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    CGSize s = sv.bounds.size;
    c.x = MAX(28, MIN(s.width - 28, c.x));
    c.y = MAX(60, MIN(s.height - 28, c.y));
    v.center = c;
    [g setTranslation:CGPointZero inView:sv];
}

- (void)syncSwitches {
    AgoraRecorder *r = [AgoraRecorder sharedRecorder];
    ((UISwitch *)[self.mainPage viewWithTag:101]).on = [r isRecordingEnabled];
    ((UISwitch *)[self.mainPage viewWithTag:102]).on = [r isLiveMonitorEnabled];
    ((UISwitch *)[self.mainPage viewWithTag:103]).on = [r isLiveMonitor3xEnabled];
}

- (void)switchChanged:(UISwitch *)s {
    AgoraRecorder *r = [AgoraRecorder sharedRecorder];
    switch (s.tag) {
        case 101: [r setRecordingEnabled:s.on]; break;
        case 102: [r setLiveMonitorEnabled:s.on]; break;
        case 103: [r setLiveMonitor3xEnabled:s.on]; break;
    }
}

- (void)togglePanel {
    UIWindow *w = AMKeyWindow();
    if (!w) return;

    if (self.panel.hidden) {
        if (self.panel.superview != w) [w addSubview:self.panel];
        self.panelScale = MIN(1.0, (w.bounds.size.height - 20.0) / kPanelH);
        CGAffineTransform finalT = CGAffineTransformMakeScale(self.panelScale, self.panelScale);
        self.panel.transform = CGAffineTransformIdentity;
        self.panel.center = CGPointMake(w.bounds.size.width / 2, w.bounds.size.height / 2);
        [self syncSwitches];
        [self showMainPage];
        self.panel.hidden = NO;
        self.panel.alpha = 0;
        self.panel.transform = CGAffineTransformScale(finalT, 0.8, 0.8);
        [w bringSubviewToFront:self.panel];
        [w bringSubviewToFront:self.fab];
        [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.72 initialSpringVelocity:0.6
                            options:0 animations:^{
            self.panel.alpha = 1;
            self.panel.transform = finalT;
        } completion:nil];
    } else {
        [UIView animateWithDuration:0.2 animations:^{
            self.panel.alpha = 0;
            self.panel.transform = CGAffineTransformMakeScale(0.85 * self.panelScale, 0.85 * self.panelScale);
        } completion:^(BOOL finished) {
            self.panel.hidden = YES;
            self.panel.transform = CGAffineTransformIdentity;
        }];
    }
}

- (void)showMainPage {
    self.mainPage.hidden = NO;
    self.listPage.hidden = YES;
}

- (void)showListPage {
    self.paths = [[AgoraRecorder sharedRecorder] allRecordings];
    [self.table reloadData];
    self.listPage.alpha = 0;
    self.listPage.hidden = NO;
    self.mainPage.hidden = YES;
    [UIView animateWithDuration:0.25 animations:^{ self.listPage.alpha = 1; }];
}

#pragma mark Table

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    return MAX((NSInteger)self.paths.count, 1);
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"am"];
    if (!c) {
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"am"];
        c.backgroundColor = [UIColor clearColor];
        c.textLabel.font = AMFont(11, YES);
        c.textLabel.textColor = [UIColor whiteColor];
        c.detailTextLabel.font = AMFont(10, NO);
        c.detailTextLabel.textColor = AM_DIM;
        UIView *sel = [UIView new];
        sel.backgroundColor = [AM_BLUE colorWithAlphaComponent:0.25];
        c.selectedBackgroundView = sel;
    }
    if (self.paths.count == 0) {
        c.textLabel.text = @"No recordings yet";
        c.detailTextLabel.text = @"Turn on REC and start a call";
        c.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        NSString *path = self.paths[ip.row];
        unsigned long long size = [[[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil] fileSize];
        c.textLabel.text = [path lastPathComponent];
        c.detailTextLabel.text = [NSString stringWithFormat:@"%.1f KB", size / 1024.0];
        c.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (self.paths.count == 0) return;
    NSString *path = self.paths[ip.row];
    UIViewController *top = AMTopVC();
    if (!top) return;

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:[path lastPathComponent]
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Play" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSError *err = nil;
        self.player = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path] error:&err];
        if (!err) [self.player play];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Stop" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self.player stop];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Share / Save to Files" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        UIActivityViewController *avc = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:path]]
                                                                          applicationActivities:nil];
        [self configurePopover:avc.popoverPresentationController];
        [AMTopVC() presentViewController:avc animated:YES completion:nil];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [self.player stop];
        [[AgoraRecorder sharedRecorder] deleteRecordingAtPath:path];
        self.paths = [[AgoraRecorder sharedRecorder] allRecordings];
        [self.table reloadData];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self configurePopover:sheet.popoverPresentationController];
    [top presentViewController:sheet animated:YES completion:nil];
}

- (void)configurePopover:(UIPopoverPresentationController *)pop {
    if (!pop) return;
    pop.sourceView = self.panel.superview ?: self.panel;
    pop.sourceRect = CGRectMake(CGRectGetMidX(self.panel.frame), CGRectGetMidY(self.panel.frame), 1, 1);
    pop.permittedArrowDirections = 0;
}

@end
