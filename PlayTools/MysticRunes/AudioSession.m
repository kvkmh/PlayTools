/**
 * AudioSession.m — PlayTools hook for music/streaming apps (e.g. Roon ARC)
 *
 * Fixes 5 AVAudioSession bridging failures under PlayCover on macOS.
 * Drop into PlayTools/MysticRunes/ and add to the PlayTools Xcode target.
 *
 * Build notes:
 *   - Builds against the iOS SDK (no CoreAudio headers needed)
 *   - All macOS-specific APIs resolved via dlsym at runtime
 *   - Works around upstream PlayShadow.h missing semicolon (see below)
 */

// PlayShadow.h has a pre-existing missing ';' after swizzleClassMethod
// declaration (upstream bug). We import Foundation first so the compiler
// already knows @interface syntax, then import the header inside a
// @class forward-reference scope to silence the parse error.
// Actually the cleanest workaround: re-declare only what we need ourselves.
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>

// Forward-declare the swizzle helper from PlayShadow without importing the
// broken header. The implementation is already compiled into PlayTools.dylib.
@interface NSObject (ShadowSwizzle)
- (void)swizzleInstanceMethod:(SEL)origSelector withMethod:(SEL)newSelector;
@end

// No need for PlayTools-Swift.h — we only need runtime swizzle, not PlaySettings.

// ---------------------------------------------------------------------------
// macOS AudioHardwareService — resolved via dlsym at runtime.
// Builds cleanly against iOS SDK; symbols are present at runtime on macOS.
// ---------------------------------------------------------------------------

typedef UInt32 PT_AudioObjectID;

typedef struct {
    UInt32 mSelector;
    UInt32 mScope;
    UInt32 mElement;
} PT_AudioObjectPropertyAddress;

// Stable 4CC constants — never change across macOS versions
#define PT_kAudioObjectSystemObject              ((PT_AudioObjectID)1)
#define PT_kAudioObjectUnknown                   ((PT_AudioObjectID)0)
#define PT_kAudioHardwarePropertyDefaultOutputDevice  0x644F7574u  // 'dOut'
#define PT_kAudioHardwareServiceDeviceProperty_VirtualMainVolume  0x766D7677u  // 'vmvw'
#define PT_kAudioDevicePropertyTransportType     0x7472616Eu  // 'tran'
#define PT_kAudioObjectPropertyScopeGlobal       0x676C6F62u  // 'glob'
#define PT_kAudioObjectPropertyScopeOutput       0x6F757470u  // 'outp'
#define PT_kAudioObjectPropertyElementMain       0u

#define PT_kAudioDeviceTransportTypeBuiltIn      0x626C746Eu  // 'bltn'
#define PT_kAudioDeviceTransportTypeBluetooth    0x626C7565u  // 'blue'
#define PT_kAudioDeviceTransportTypeBluetoothLE  0x626C6565u  // 'blee'
#define PT_kAudioDeviceTransportTypeUSB          0x75736220u  // 'usb '

typedef OSStatus (*PT_GetPropertyFn)(PT_AudioObjectID,
                                     const PT_AudioObjectPropertyAddress *,
                                     UInt32, const void *, UInt32 *, void *);

static PT_GetPropertyFn PT_getPropertyFn(void) {
    static PT_GetPropertyFn fn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *lib = dlopen(
            "/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox",
            RTLD_LAZY | RTLD_NOLOAD);
        if (!lib)
            lib = dlopen(
                "/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox",
                RTLD_LAZY);
        if (lib)
            fn = (PT_GetPropertyFn)dlsym(lib, "AudioHardwareServiceGetPropertyData");
    });
    return fn;
}

static PT_AudioObjectID PT_defaultOutputDevice(void) {
    PT_GetPropertyFn fn = PT_getPropertyFn();
    if (!fn) return PT_kAudioObjectUnknown;
    PT_AudioObjectID dev = PT_kAudioObjectUnknown;
    UInt32 sz = sizeof(dev);
    PT_AudioObjectPropertyAddress a = {
        PT_kAudioHardwarePropertyDefaultOutputDevice,
        PT_kAudioObjectPropertyScopeGlobal,
        PT_kAudioObjectPropertyElementMain
    };
    fn(PT_kAudioObjectSystemObject, &a, 0, NULL, &sz, &dev);
    return dev;
}

static float PT_systemVolume(void) {
    PT_GetPropertyFn fn = PT_getPropertyFn();
    PT_AudioObjectID dev = PT_defaultOutputDevice();
    if (!fn || dev == PT_kAudioObjectUnknown) return 1.0f;
    Float32 vol = 1.0f;
    UInt32 sz = sizeof(vol);
    PT_AudioObjectPropertyAddress a = {
        PT_kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        PT_kAudioObjectPropertyScopeOutput,
        PT_kAudioObjectPropertyElementMain
    };
    OSStatus err = fn(dev, &a, 0, NULL, &sz, &vol);
    return (err == noErr) ? (float)vol : 1.0f;
}

static UInt32 PT_transportType(void) {
    PT_GetPropertyFn fn = PT_getPropertyFn();
    PT_AudioObjectID dev = PT_defaultOutputDevice();
    if (!fn || dev == PT_kAudioObjectUnknown) return PT_kAudioDeviceTransportTypeBuiltIn;
    UInt32 type = PT_kAudioDeviceTransportTypeBuiltIn;
    UInt32 sz = sizeof(type);
    PT_AudioObjectPropertyAddress a = {
        PT_kAudioDevicePropertyTransportType,
        PT_kAudioObjectPropertyScopeGlobal,
        PT_kAudioObjectPropertyElementMain
    };
    fn(dev, &a, 0, NULL, &sz, &type);
    return type;
}

// ---------------------------------------------------------------------------
// Hook method implementations on NSObject category.
// Moved here (before @interface declaration) to avoid forward-reference issues.
// ---------------------------------------------------------------------------

@interface NSObject (PTAudioHooks)
- (BOOL)pt_setCategory:(id)category options:(NSUInteger)options error:(NSError **)e;
- (BOOL)pt_setCategory:(id)category mode:(id)mode options:(NSUInteger)options error:(NSError **)e;
- (BOOL)pt_setActive:(BOOL)active error:(NSError **)e;
- (BOOL)pt_setActive:(BOOL)active withOptions:(NSUInteger)options error:(NSError **)e;
- (float)pt_outputVolume;
- (id)pt_currentRoute;
- (void)pt_postNotificationName:(NSNotificationName)name object:(id)obj;
@end

@implementation NSObject (PTAudioHooks)

// Fix 1a — strip duckOthers from setCategory:options:error:
// On macOS this maps to a real HAL property that lowers all other apps' audio.
- (BOOL)pt_setCategory:(id)category options:(NSUInteger)options error:(NSError **)e {
    // AVAudioSessionCategoryOptionDuckOthers = 0x2
    NSUInteger safe = options & ~0x2UL;
    return [self pt_setCategory:category options:safe error:e];
}

// Fix 1b — same for setCategory:mode:options:error:
- (BOOL)pt_setCategory:(id)category mode:(id)mode options:(NSUInteger)options error:(NSError **)e {
    NSUInteger safe = options & ~0x2UL;
    return [self pt_setCategory:category mode:mode options:safe error:e];
}

// Fix 2a — after setActive(true), prod the audio route open via RemoteIO.
// kAudioUnitSubType_DefaultOutput is macOS-only; kAudioUnitSubType_RemoteIO
// is the iOS equivalent and is available in AudioToolbox on both platforms.
- (BOOL)pt_setActive:(BOOL)active error:(NSError **)e {
    BOOL result = [self pt_setActive:active error:e];
    if (active && result) {
        AudioComponentDescription desc = {
            kAudioUnitType_Output,
            kAudioUnitSubType_RemoteIO,  // iOS SDK compatible; resolves on macOS too
            kAudioUnitManufacturer_Apple, 0, 0
        };
        AudioComponent comp = AudioComponentFindNext(NULL, &desc);
        if (comp) {
            AudioUnit unit;
            if (AudioComponentInstanceNew(comp, &unit) == noErr) {
                AudioUnitInitialize(unit);
                AudioOutputUnitStart(unit);
                // Left open intentionally as a HAL keepalive.
            }
        }
    }
    return result;
}

// Fix 2b — delegate withOptions variant through fix 2a.
- (BOOL)pt_setActive:(BOOL)active withOptions:(NSUInteger)options error:(NSError **)e {
    return [self pt_setActive:active error:e];
}

// Fix 3 — return real macOS system volume instead of 0 / stale cached value.
- (float)pt_outputVolume {
    return PT_systemVolume();
}

// Fix 4 — return a route whose port type reflects the real CoreAudio device.
// AVAudioSessionPortType is NSString * on iOS — not a typedef enum.
// We use the string constants directly.
- (id)pt_currentRoute {
    UInt32 transport = PT_transportType();

    // AVAudioSessionPort* constants are NSString * on iOS SDK
    NSString *portType;
    if (transport == PT_kAudioDeviceTransportTypeUSB) {
        portType = AVAudioSessionPortUSBAudio;
    } else if (transport == PT_kAudioDeviceTransportTypeBluetooth ||
               transport == PT_kAudioDeviceTransportTypeBluetoothLE) {
        portType = AVAudioSessionPortBluetoothA2DP;
    } else {
        portType = AVAudioSessionPortBuiltInSpeaker;
    }

    // AVAudioSessionPortDescription and RouteDescription have no public inits;
    // use KVC on internal ivars — stable across iOS/Catalyst versions.
    AVAudioSessionPortDescription *port =
        [[AVAudioSessionPortDescription alloc] init];
    [port setValue:portType forKey:@"portType"];

    AVAudioSessionRouteDescription *route =
        [[AVAudioSessionRouteDescription alloc] init];
    [route setValue:@[port] forKey:@"outputs"];
    [route setValue:@[]     forKey:@"inputs"];
    return route;
}

// Fix 5 — replace applicationDidEnterBackground with the softer
// willResignActive when PTSuppressBackgroundNotification is set.
// Prevents .playback apps from pausing when the window is minimised.
- (void)pt_postNotificationName:(NSNotificationName)name object:(id)obj {
    static NSString *const kKey = @"PTSuppressBackgroundNotification";
    if ([[NSUserDefaults standardUserDefaults] boolForKey:kKey] &&
        [name isEqualToString:UIApplicationDidEnterBackgroundNotification]) {
        name = UIApplicationWillResignActiveNotification;
    }
    [self pt_postNotificationName:name object:obj];
}

@end

// ---------------------------------------------------------------------------
// Loader — installs all hooks at dylib load time via +load
// ---------------------------------------------------------------------------

__attribute__((visibility("hidden")))
@interface PTAudioSessionLoader : NSObject
@end

@implementation PTAudioSessionLoader

+ (void)load {
    // Only patch apps that declare audio background mode.
    // Games (PlayCover's primary use case) rarely do, so they are unaffected.
    NSArray *bgModes = [[NSBundle mainBundle]
                        objectForInfoDictionaryKey:@"UIBackgroundModes"];
    if (![bgModes containsObject:@"audio"]) {
        NSLog(@"[PlayTools/AudioSession] No audio background mode — skipping");
        return;
    }

    NSLog(@"[PlayTools/AudioSession] Installing 5 audio patches");

    // Default background suppression to ON; can be toggled via NSUserDefaults.
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    if (![ud objectForKey:@"PTSuppressBackgroundNotification"])
        [ud setBool:YES forKey:@"PTSuppressBackgroundNotification"];

    Class avs = objc_getClass("AVAudioSession");
    Class nc  = [NSNotificationCenter class];

    if (!avs) {
        NSLog(@"[PlayTools/AudioSession] AVAudioSession not found — aborting");
        return;
    }

// Macro: copy the pt_ IMP from NSObject(PTAudioHooks) onto the target class,
// then exchange with the original. Required because swizzleInstanceMethod:withMethod:
// looks up BOTH selectors on the same class object.
#define PT_INSTALL(cls, orig, repl) \
    do { \
        Method _src = class_getInstanceMethod([NSObject class], (repl)); \
        if (_src) class_addMethod((cls), (repl), \
                                   method_getImplementation(_src), \
                                   method_getTypeEncoding(_src)); \
        [(cls) swizzleInstanceMethod:(orig) withMethod:(repl)]; \
    } while(0)

// AVAudioSession selectors are not declared on NSObject; suppress the
// -Wundeclared-selector diagnostic for this block only.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"

    // Fix 1 — strip duckOthers
    PT_INSTALL(avs,
        @selector(setCategory:options:error:),
        @selector(pt_setCategory:options:error:));
    PT_INSTALL(avs,
        @selector(setCategory:mode:options:error:),
        @selector(pt_setCategory:mode:options:error:));

    // Fix 2 — HAL activation prod
    PT_INSTALL(avs,
        @selector(setActive:error:),
        @selector(pt_setActive:error:));
    PT_INSTALL(avs,
        @selector(setActive:withOptions:error:),
        @selector(pt_setActive:withOptions:error:));

    // Fix 3 — real volume
    PT_INSTALL(avs,
        @selector(outputVolume),
        @selector(pt_outputVolume));

    // Fix 4 — correct route
    PT_INSTALL(avs,
        @selector(currentRoute),
        @selector(pt_currentRoute));

    // Fix 5 — background suppression
    PT_INSTALL(nc,
        @selector(postNotificationName:object:),
        @selector(pt_postNotificationName:object:));

#pragma clang diagnostic pop

#undef PT_INSTALL

    NSLog(@"[PlayTools/AudioSession] All 5 patches installed");
}

@end
