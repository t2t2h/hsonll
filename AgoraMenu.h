#import <Foundation/Foundation.h>

/// Floating in-app menu (blue/black, animated). Works without jailbreak:
/// it is added as a draggable button on top of the host app's key window.
@interface AgoraMenu : NSObject
+ (void)install;
@end
