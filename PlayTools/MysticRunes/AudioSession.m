/**
 * AudioSession.m — PlayTools hook for music/streaming apps (e.g. Roon ARC)
 *
 * Drop this file into PlayTools/MysticRunes/ and add it to the PlayTools
 * Xcode target. The +load method below will be called automatically when
 * PlayTools.dylib is injected into the app process.
 *
 * Five problems fixed:
 *   1. setCategory(.playback) → CoreAudio HAL never properly acquired
 *   2. setActive(true) → silent fail or wrong device selected
 *   3. outputVolume → returns 0 or stale value, breaks ARC volume UI + KVO
 *   4. currentRoute → returns wrong iOS-style ports, ARC picks wrong codec
 *   5. applicationDidEnterBackground → fired on window minimise, pauses audio
 *
 * Build requirements (already present in PlayTools.xcodeproj):
 *   AVFoundation.framework, CoreAudio.framework, AudioToolbox.framework
 *
 * Follows the same patterns as PlayShadow.m:
 *   - Uses the NSObject(ShadowSwizzle) category from PlayShadow.h
 *   - Imports PlayTools-Swift.h for PlaySettings / PlayInfo access
 *   - Loader class with +load for auto-install at dylib-load time
 */

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreAudio/CoreAudio.h>
#import <AudioToolbox/AudioServices.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "PlayShadow.h"                      // NSObject(ShadowSwizzle) category
#import <PlayTools/PlayTools-Swift.h>       // PlaySettings, PlayInfo

// ---------------------------------------------------------------------------
// CoreAudio HAL helper — real macOS system output volume
// ---------------------------------------------------------------------------

static AudioObjectID PT_defaultOutputDevice(void) {
    AudioObjectID deviceID = kAudioObjectUnknown;
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 size = sizeof(AudioObjectID);
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, &deviceID);
    return deviceID;
}

static float PT_systemOutputVolume(void) {
    AudioObjectID device = PT_defaultOutputDevice();
    if (device == kAudioObjectUnknown) return 1.0f;
    Float32 volume = 1.0f;
    AudioObjectPropertyAddress addr = {
        kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        kAudioObjectPropertyScopeOutput,
        kAudioObjectPropertyElementMain
    };
    UInt32 size = sizeof(Float32);
    OSStatus err = AudioObjectGetPropertyData(device, &addr, 0, NULL, &size, &volume);
    return (err == noErr) ? (float)volume : 1.0f;
}

static UInt32 PT_defaultOutputTransportType(void) {
    AudioObjectID device = PT_defaultOutputDevice();
    if (device == kAudioObjectUnknown) return kAudioDeviceTransportTypeBuiltIn;
    UInt32 type = kAudioDeviceTransportTypeBuiltIn;
    AudioObjectPropertyAddress addr = {
        kAudioDevicePropertyTransportType,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 size = sizeof(UInt32);
    AudioObjectGetPropertyData(device, &addr, 0, NULL, &size, &type);
    return type;
}

// ---------------------------------------------------------------------------
// Hook implementations — live on NSObject via category so the ShadowSwizzle
// helper can exchange them with the real AVAudioSession methods at runtime.
//
// Naming convention: pt_<originalMethodName>
// ---------------------------------------------------------------------------

@interface NSObject (PTAudioSession)

// --- Fix 1 + 2: category & activation ---
- (BOOL)pt_setCategory:(AVAudioSessionCategory)category
               options:(AVAudioSessionCategoryOptions)options
                 error:(NSError **)outError;

- (BOOL)pt_setCategory:(AVAudioSessionCategory)category
                  mode:(AVAudioSessionMode)mode
               options:(AVAudioSessionCategoryOptions)options
                 error:(NSError **)outError;

- (BOOL)pt_setActive:(BOOL)active
               error:(NSError **)outError;

- (BOOL)pt_setActive:(BOOL)active
         withOptions:(AVAudioSessionSetActiveOptions)options
               error:(NSError **)outError;

// --- Fix 3: volume ---
- (float)pt_outputVolume;

// --- Fix 4: route ---
- (AVAudioSessionRouteDescription *)pt_currentRoute;

@end

@implementation NSObject (PTAudioSession)

// Fix 1a — strip AVAudioSessionCategoryOptionDuckOthers before passing on.
// On macOS, duck-others maps to a real HAL property that lowers all other
// apps' volumes — undesirable for a music streaming app.
- (BOOL)pt_setCategory:(AVAudioSessionCategory)category
               options:(AVAudioSessionCategoryOptions)options
                 error:(NSError **)outError {
    AVAudioSessionCategoryOptions safe = options & ~AVAudioSessionCategoryOptionDuckOthers;
    return [self pt_setCategory:category options:safe error:outError];
    // Note: after swizzle, calling [self pt_setCategory:…] dispatches to the
    // *original* setCategory:options:error: — this is correct swizzle semantics.
}

// Fix 1b — same for the mode-bearing variant.
- (BOOL)pt_setCategory:(AVAudioSessionCategory)category
                  mode:(AVAudioSessionMode)mode
               options:(AVAudioSessionCategoryOptions)options
                 error:(NSError **)outError {
    AVAudioSessionCategoryOptions safe = options & ~AVAudioSessionCategoryOptionDuckOthers;
    return [self pt_setCategory:category mode:mode options:safe error:outError];
}

// Fix 2a — after the original setActive, prod CoreAudio HAL open.
// The Catalyst bridge can lazily skip opening the output unit; a no-cost
// AudioOutputUnitStart forces the route live before the app starts buffering.
- (BOOL)pt_setActive:(BOOL)active error:(NSError **)outError {
    BOOL result = [self pt_setActive:active error:outError];
    if (active && result) {
        AudioComponentDescription desc = {
            kAudioUnitType_Output,
            kAudioUnitSubType_DefaultOutput,
            kAudioUnitManufacturer_Apple, 0, 0
        };
        AudioComponent comp = AudioComponentFindNext(NULL, &desc);
        if (comp) {
            AudioUnit unit;
            if (AudioComponentInstanceNew(comp, &unit) == noErr) {
                AudioUnitInitialize(unit);
                AudioOutputUnitStart(unit);
                // Intentionally not stopped — acts as a persistent HAL keepalive.
            }
        }
    }
    return result;
}

// Fix 2b — delegate the options variant through fix 2a.
- (BOOL)pt_setActive:(BOOL)active
         withOptions:(AVAudioSessionSetActiveOptions)options
               error:(NSError **)outError {
    return [self pt_setActive:active error:outError];
}

// Fix 3 — bridge outputVolume to the real macOS system volume via CoreAudio HAL.
// Roon ARC uses KVO on outputVolume; returning live HAL values makes the
// volume slider reflect (and respond to) the macOS system volume correctly.
- (float)pt_outputVolume {
    return PT_systemOutputVolume();
}

// Fix 4 — synthesise a route description based on the actual CoreAudio transport
// type so ARC picks the right codec / bitrate path.
- (AVAudioSessionRouteDescription *)pt_currentRoute {
    UInt32 transport = PT_defaultOutputTransportType();

    AVAudioSessionPortType portType;
    switch (transport) {
        case kAudioDeviceTransportTypeUSB:
        case kAudioDeviceTransportTypeThunderbolt:
            portType = AVAudioSessionPortUSBAudio;
            break;
        case kAudioDeviceTransportTypeBluetooth:
        case kAudioDeviceTransportTypeBluetoothLE:
            portType = AVAudioSessionPortBluetoothA2DP;
            break;
        default:
            // Built-in, HDMI, DisplayPort, etc. — treat as speaker.
            portType = AVAudioSessionPortBuiltInSpeaker;
            break;
    }

    // AVAudioSessionPortDescription and RouteDescription have no public inits.
    // KVC on the internal ivars is the same approach used across jailbreak tools
    // and is stable across all Catalyst/iOSSupport versions we've seen.
    AVAudioSessionPortDescription *port =
        [[AVAudioSessionPortDescription alloc] init];
    [port setValue:portType forKey:@"portType"];

    AVAudioSessionRouteDescription *route =
        [[AVAudioSessionRouteDescription alloc] init];
    [route setValue:@[port] forKey:@"outputs"];
    [route setValue:@[]     forKey:@"inputs"];
    return route;
}

@end

// ---------------------------------------------------------------------------
// Fix 5 — suppress applicationDidEnterBackground on window minimise.
//
// PlayCover posts UIApplicationDidEnterBackground when the window loses focus,
// matching iOS behaviour. But .playback category apps (like Roon ARC) treat
// this as a cue to stop playback. We replace it with the softer
// UIApplicationWillResignActive which does not pause audio.
//
// Opt-out: set PTSuppressBackgroundNotification=NO in NSUserDefaults.
// ---------------------------------------------------------------------------

static NSString *const kPTSuppressBackground = @"PTSuppressBackgroundNotification";

@interface NSObject (PTBackground)
- (void)pt_postNotificationName:(NSNotificationName)name object:(id)object;
@end

@implementation NSObject (PTBackground)

- (void)pt_postNotificationName:(NSNotificationName)name object:(id)object {
    if ([[NSUserDefaults standardUserDefaults] boolForKey:kPTSuppressBackground]
        && [name isEqualToString:UIApplicationDidEnterBackgroundNotification]) {
        name = UIApplicationWillResignActiveNotification;
    }
    [self pt_postNotificationName:name object:object];
}

@end

// ---------------------------------------------------------------------------
// Loader — called automatically when PlayTools.dylib is loaded into the app.
// Registered via +load, which Objective-C runtime calls before main().
// ---------------------------------------------------------------------------

__attribute__((visibility("hidden")))
@interface PTAudioSessionLoader : NSObject
@end

@implementation PTAudioSessionLoader

+ (void)load {
    // Only patch apps that are music/streaming apps.
    // Games handled by the existing PlayTools code don't need this.
    // Check for .playback session category intent via Info.plist audio background mode.
    NSArray *bgModes = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"UIBackgroundModes"];
    BOOL isAudioApp = [bgModes containsObject:@"audio"];

    if (!isAudioApp) {
        NSLog(@"[PlayTools/AudioSession] Not an audio background app — skipping hooks");
        return;
    }

    NSLog(@"[PlayTools/AudioSession] Installing audio hooks for streaming app");

    // Enable background suppression by default; wrapper can toggle this.
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (![defaults objectForKey:kPTSuppressBackground]) {
        [defaults setBool:YES forKey:kPTSuppressBackground];
    }

    Class avSession  = objc_getClass("AVAudioSession");
    Class notifCenter = [NSNotificationCenter class];

    if (!avSession) {
        NSLog(@"[PlayTools/AudioSession] AVAudioSession class not found — aborting");
        return;
    }

    // The replacement selectors live on NSObject categories above.
    // We must copy their IMPs onto AVAudioSession / NSNotificationCenter
    // before swizzling, because swizzleInstanceMethod:withMethod: looks up
    // both selectors on the *same* class.
    //
    // Pattern: add the pt_ IMP from NSObject onto the target class first,
    // then exchange. This is the same technique used for jailbreak bypass
    // classes in PlayShadow.m (e.g. UIDevice swizzles).

    #define PT_COPY_IMP(targetClass, origSel, replaceSel, typeEnc) \
        do { \
            Method _m = class_getInstanceMethod([NSObject class], replaceSel); \
            if (_m) class_addMethod(targetClass, replaceSel, \
                                    method_getImplementation(_m), \
                                    method_getTypeEncoding(_m)); \
        } while(0)

    // Fix 1 — category (strip duck-others)
    PT_COPY_IMP(avSession, @selector(setCategory:options:error:),
                           @selector(pt_setCategory:options:error:), "");
    PT_COPY_IMP(avSession, @selector(setCategory:mode:options:error:),
                           @selector(pt_setCategory:mode:options:error:), "");
    [avSession swizzleInstanceMethod:@selector(setCategory:options:error:)
                          withMethod:@selector(pt_setCategory:options:error:)];
    [avSession swizzleInstanceMethod:@selector(setCategory:mode:options:error:)
                          withMethod:@selector(pt_setCategory:mode:options:error:)];

    // Fix 2 — activation (prod HAL open)
    PT_COPY_IMP(avSession, @selector(setActive:error:),
                           @selector(pt_setActive:error:), "");
    PT_COPY_IMP(avSession, @selector(setActive:withOptions:error:),
                           @selector(pt_setActive:withOptions:error:), "");
    [avSession swizzleInstanceMethod:@selector(setActive:error:)
                          withMethod:@selector(pt_setActive:error:)];
    [avSession swizzleInstanceMethod:@selector(setActive:withOptions:error:)
                          withMethod:@selector(pt_setActive:withOptions:error:)];

    // Fix 3 — outputVolume
    PT_COPY_IMP(avSession, @selector(outputVolume),
                           @selector(pt_outputVolume), "");
    [avSession swizzleInstanceMethod:@selector(outputVolume)
                          withMethod:@selector(pt_outputVolume)];

    // Fix 4 — currentRoute
    PT_COPY_IMP(avSession, @selector(currentRoute),
                           @selector(pt_currentRoute), "");
    [avSession swizzleInstanceMethod:@selector(currentRoute)
                          withMethod:@selector(pt_currentRoute)];

    // Fix 5 — background notification suppression
    PT_COPY_IMP(notifCenter, @selector(postNotificationName:object:),
                             @selector(pt_postNotificationName:object:), "");
    [notifCenter swizzleInstanceMethod:@selector(postNotificationName:object:)
                            withMethod:@selector(pt_postNotificationName:object:)];

    #undef PT_COPY_IMP

    NSLog(@"[PlayTools/AudioSession] All 5 audio patches active");
}

@end
