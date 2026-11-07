//
//  Tweak.m
//  No CydiaSubstrate needed: hooks are installed with the plain
//  Objective-C runtime, so the dylib works when injected with ESign on a
//  non-jailbroken device.
//
//  It looks for any class that implements the Agora raw-audio callback
//  -(BOOL)onRecordAudioFrame:(id)frame (usually the app's own delegate
//  class) and wraps it, so you don't have to know the class name.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "AgoraRecorder.h"
#import "AgoraMenu.h"

// Original IMPs, keyed by "Class|selector".
static NSMutableDictionary<NSString *, NSValue *> *gOrig;

static NSString *AMKey(Class cls, SEL sel) {
    return [NSString stringWithFormat:@"%@|%@", NSStringFromClass(cls), NSStringFromSelector(sel)];
}

static IMP AMFindOrig(id obj, SEL sel) {
    Class c = object_getClass(obj);
    while (c) {
        NSValue *v = nil;
        @synchronized (gOrig) { v = gOrig[AMKey(c, sel)]; }
        if (v) return (IMP)[v pointerValue];
        c = class_getSuperclass(c);
    }
    return NULL;
}

// Reads PCM bytes out of an AgoraAudioFrame through KVC, so no Agora
// headers are required. Works with both NSData and raw-pointer buffers.
static NSData *AMExtractPCM(id frame, NSUInteger *outRate, NSUInteger *outChannels) {
    @try {
        NSInteger samples = [[frame valueForKey:@"samples"] integerValue];
        NSInteger bytesPerSample = [[frame valueForKey:@"bytesPerSample"] integerValue];
        NSInteger channels = [[frame valueForKey:@"channels"] integerValue];
        NSInteger rate = [[frame valueForKey:@"samplesPerSec"] integerValue];
        if (channels < 1) channels = 1;
        if (rate < 8000) rate = 16000;
        *outRate = (NSUInteger)rate;
        *outChannels = (NSUInteger)channels;

        id buf = [frame valueForKey:@"buffer"];
        if ([buf isKindOfClass:[NSData class]]) return buf;
        if ([buf isKindOfClass:[NSValue class]] && samples > 0 && bytesPerSample > 0) {
            const void *p = [(NSValue *)buf pointerValue];
            if (p) {
                return [NSData dataWithBytes:p length:(NSUInteger)(samples * bytesPerSample * channels)];
            }
        }
    } @catch (NSException *e) {
        // Unknown frame layout; skip.
    }
    return nil;
}

static BOOL am_onRecordAudioFrame(id self, SEL _cmd, id frame) {
    @try {
        AgoraRecorder *rec = [AgoraRecorder sharedRecorder];
        if ([rec isRecordingEnabled]) {
            NSUInteger rate = 16000, channels = 1;
            NSData *pcm = AMExtractPCM(frame, &rate, &channels);
            if (pcm.length > 0) {
                if (![rec isCurrentlyRecording]) {
                    [rec startNewRecordingWithSampleRate:rate channels:channels];
                }
                [rec appendPCMData:pcm];
            }
        }
    } @catch (NSException *e) {
        // Never let a recording failure break the actual call.
    }

    IMP orig = AMFindOrig(self, _cmd);
    if (orig) return ((BOOL (*)(id, SEL, id))orig)(self, _cmd, frame);
    return YES;
}

static void AMHook(Class cls, SEL sel, IMP repl) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    if (method_getNumberOfArguments(m) != 3) return;   // self, _cmd, frame

    NSString *key = AMKey(cls, sel);
    @synchronized (gOrig) {
        if (gOrig[key]) return;
        IMP orig = method_getImplementation(m);
        if (orig == repl) return;
        if (!class_addMethod(cls, sel, repl, method_getTypeEncoding(m))) {
            // Class defines the method itself: swap its implementation.
            orig = method_setImplementation(m, repl);
        }
        gOrig[key] = [NSValue valueWithPointer:(const void *)orig];
    }
}

static void AMScanAndHook(void) {
    SEL sel = @selector(onRecordAudioFrame:);
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    for (unsigned int i = 0; i < count; i++) {
        Class c = classes[i];
        unsigned int mc = 0;
        Method *methods = class_copyMethodList(c, &mc);
        BOOL defines = NO;
        for (unsigned int j = 0; j < mc; j++) {
            if (method_getName(methods[j]) == sel) { defines = YES; break; }
        }
        if (methods) free(methods);
        if (defines) AMHook(c, sel, (IMP)am_onRecordAudioFrame);
    }
    if (classes) free(classes);
}

__attribute__((constructor))
static void AgoraRecorderTweakInit(void) {
    @autoreleasepool {
        gOrig = [NSMutableDictionary dictionary];

        dispatch_async(dispatch_get_main_queue(), ^{
            [AgoraMenu install];
        });

        // Agora's classes can load late, so scan a few times.
        double delays[] = {1.0, 5.0, 15.0, 40.0};
        for (int i = 0; i < 4; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[i] * NSEC_PER_SEC)),
                           dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                AMScanAndHook();
            });
        }
    }
}
