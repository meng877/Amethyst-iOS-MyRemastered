#import <SafariServices/SafariServices.h>

#include "jni.h"
#include <dlfcn.h>
#include <assert.h>
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <dirent.h>
#include <sys/mman.h>

#include "utils.h"

CFTypeRef SecTaskCopyValueForEntitlement(void* task, NSString* entitlement, CFErrorRef  _Nullable *error);
void* SecTaskCreateFromSelf(CFAllocatorRef allocator);

BOOL getEntitlementValue(NSString *key) {
    void *secTask = SecTaskCreateFromSelf(NULL);
    CFTypeRef value = SecTaskCopyValueForEntitlement(secTask, key, nil);
    CFRelease(secTask);
    if (value == nil) {
        return NO;
    }
    id bridgedValue = (__bridge id)value;
    BOOL result = ![bridgedValue isKindOfClass:NSNumber.class] || [bridgedValue boolValue];
    CFRelease(value);
    return result;
}

BOOL isJITEnabled(BOOL checkCSFlags) {
    if (!checkCSFlags && (getEntitlementValue(@"dynamic-codesigning") || isJailbroken)) {
        return YES;
    }

    int flags = 0;
    if (csops(getpid(), 0, &flags, sizeof(flags)) != 0 || (flags & CS_DEBUGGED) == 0) {
        return NO;
    }
    if (!DeviceHasJITFlags(JIT_FLAG_FORCE_MIRRORED | JIT_FLAG_HAS_TXM)) {
        return YES;
    }
    // iOS 26+ devices with TXM need the debugger to remain attached so the
    // Universal script can service executable-memory breakpoints.
    return JIT26IsLikelyDebuggerKeepAttached();
}


void openLink(UIViewController* sender, NSURL* link) {
    if (NSClassFromString(@"SFSafariViewController") == nil) {
        NSData *data = [link.absoluteString dataUsingEncoding:NSUTF8StringEncoding];
        CIFilter *filter = [CIFilter filterWithName:@"CIQRCodeGenerator"];
        [filter setValue:data forKey:@"inputMessage"];
        UIImage *image = [UIImage imageWithCIImage:filter.outputImage scale:1.0 orientation:UIImageOrientationUp];
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(300, 300), NO, 0.0);
        CGRect frame = CGRectMake(0, 0, 300, 300);
        [image drawInRect:frame];
        UIImageView *imageView = [[UIImageView alloc] initWithFrame:frame];
        imageView.image = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();

        UIAlertController* alert = [UIAlertController alertControllerWithTitle:nil
            message:link.absoluteString
            preferredStyle:UIAlertControllerStyleAlert];

        UIViewController *vc = UIViewController.new;
        vc.view = imageView;
        [alert setValue:vc forKey:@"contentViewController"];

        UIAlertAction* doneAction = [UIAlertAction actionWithTitle:localize(@"Done", nil) style:UIAlertActionStyleCancel handler:nil];
        [alert addAction:doneAction];
        [sender presentViewController:alert animated:YES completion:nil];
    } else {
        SFSafariViewController *vc = [[SFSafariViewController alloc] initWithURL:link];
        [sender presentViewController:vc animated:YES completion:nil];
    }
}

NSMutableDictionary* parseJSONFromFile(NSString *path) {
    NSError *error;

    NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&error];
    if (content == nil) {
        NSLog(@"[ParseJSON] Error: could not read %@: %@", path, error.localizedDescription);
        return @{@"NSErrorObject": error}.mutableCopy;
    }

    NSData* data = [content dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:&error];
    if (error) {
        NSLog(@"[ParseJSON] Error: could not parse JSON: %@", error.localizedDescription);
        return @{@"NSErrorObject": error}.mutableCopy;
    }
    return dict;
}

NSError* saveJSONToFile(NSDictionary *dict, NSString *path) {
    // TODO: handle rename
    NSError *error;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:dict options:NSJSONWritingPrettyPrinted error:&error];
    if (jsonData == nil) {
        return error;
    }
    BOOL success = [jsonData writeToFile:path options:NSDataWritingAtomic error:&error];
    if (!success) {
        return error;
    }
    return nil;
}

NSString* localize(NSString* key, NSString* comment) {
    NSString *value = NSLocalizedString(key, nil);
    if (![NSLocale.preferredLanguages[0] isEqualToString:@"en"] && [value isEqualToString:key]) {
        NSString* path = [NSBundle.mainBundle pathForResource:@"en" ofType:@"lproj"];
        NSBundle* languageBundle = [NSBundle bundleWithPath:path];
        value = [languageBundle localizedStringForKey:key value:nil table:nil];

        if ([value isEqualToString:key]) {
            value = [[NSBundle bundleWithIdentifier:@"com.apple.UIKit"] localizedStringForKey:key value:nil table:nil];
        }
    }

    return value;
}

void customNSLog(const char *file, int lineNumber, const char *functionName, NSString *format, ...)
{
    va_list ap; 
    va_start (ap, format);
    NSString *body = [[NSString alloc] initWithFormat:format arguments:ap];
    printf("%s", [body UTF8String]);
    if (![format hasSuffix:@"\n"]) {
        printf("\n");
    }
    va_end (ap);
}

CGFloat MathUtils_dist(CGFloat x1, CGFloat y1, CGFloat x2, CGFloat y2) {
    const CGFloat x = (x2 - x1);
    const CGFloat y = (y2 - y1);
    return (CGFloat) hypot(x, y);
}

//Ported from https://www.arduino.cc/reference/en/language/functions/math/map/
CGFloat MathUtils_map(CGFloat x, CGFloat in_min, CGFloat in_max, CGFloat out_min, CGFloat out_max) {
    return (x - in_min) * (out_max - out_min) / (in_max - in_min) + out_min;
}

CGFloat dpToPx(CGFloat dp) {
    CGFloat screenScale = [[UIScreen mainScreen] scale];
    return dp * screenScale;
}

CGFloat pxToDp(CGFloat px) {
    CGFloat screenScale = [[UIScreen mainScreen] scale];
    return px / screenScale;
}

void setButtonPointerInteraction(UIButton *button) {
    button.pointerInteractionEnabled = YES;
    button.pointerStyleProvider = ^ UIPointerStyle* (UIButton* button, UIPointerEffect* proposedEffect, UIPointerShape* proposedShape) {
        UITargetedPreview *preview = [[UITargetedPreview alloc] initWithView:button];
        return [NSClassFromString(@"UIPointerStyle") styleWithEffect:[NSClassFromString(@"UIPointerHighlightEffect") effectWithPreview:preview] shape:proposedShape];
    };
}

__attribute__((noinline,optnone,naked))
void* JIT26CreateRegionLegacy(size_t len) {
    asm("brk #0x69 \n"
        "ret");
}
__attribute__((noinline,optnone,naked))
void* JIT26PrepareRegion(void *addr, size_t len) {
    asm("mov x16, #1 \n"
        "brk #0xf00d \n"
        "ret");
}
__attribute__((noinline,optnone,naked))
void BreakSendJITScript(char* script, size_t len) {
   asm("mov x16, #2 \n"
       "brk #0xf00d \n"
       "ret");
}
__attribute__((noinline,optnone,naked))
void JIT26SetDetachAfterFirstBr(BOOL value) {
   asm("mov x16, #3 \n"
       "brk #0xf00d \n"
       "ret");
}
__attribute__((noinline,optnone,naked))
void JIT26PrepareRegionForPatching(void *addr, size_t size) {
   asm("mov x16, #4 \n"
       "brk #0xf00d \n"
       "ret");
}
void JIT26SendJITScript(NSString* script) {
    NSCAssert(script, @"Script must not be nil");
    BreakSendJITScript((char*)script.UTF8String, script.length);
}

BOOL JIT26IsLikelyDebuggerKeepAttached(void) {
    // launchd is the parent (PID 1) after a debugger detaches.
    return getppid() != 1;
}

static BOOL DeviceCanCreateRXMap(void) {
    uint32_t *map = mmap(NULL, getpagesize(), PROT_READ | PROT_WRITE,
                         MAP_ANONYMOUS | MAP_SHARED, -1, 0);
    if (map == MAP_FAILED) {
        return NO;
    }
    *map = 0xFFFFFFFF;
    int ret = mprotect(map, getpagesize(), PROT_READ | PROT_EXEC);
    munmap(map, getpagesize());
    return ret == 0;
}

static BOOL DeviceHasTXMReal(void) {
    DIR *d = opendir("/private/preboot");
    if (!d) {
        // /private/preboot is no longer readable on iOS 26.6+/27. Fall back
        // to the chip/OS heuristic used by current upstream Amethyst.
        NSUInteger (*MGGetSInt64Answer)(NSString *) = dlsym(RTLD_DEFAULT, "MGGetSInt64Answer");
        NSUInteger chipID = MGGetSInt64Answer ? MGGetSInt64Answer(@"ChipID") : 0;
        switch (chipID) {
            case 0x8020: // A12
            case 0x8027: // A12X/Z
                return NO;
            case 0x8030: // A13
            case 0x8101: // A14
            case 0x8103: // M1
                if (@available(iOS 27.0, *)) return YES;
                return NO;
            default:
                if (@available(iOS 19.0, *)) return YES;
                return NO;
        }
    }

    struct dirent *dir;
    char txmPath[PATH_MAX] = {0};
    while ((dir = readdir(d)) != NULL) {
        if (strlen(dir->d_name) == 96) {
            snprintf(txmPath, sizeof(txmPath),
                     "/private/preboot/%s/usr/standalone/firmware/FUD/Ap,TrustedExecutionMonitor.img4",
                     dir->d_name);
            break;
        }
    }
    closedir(d);
    return txmPath[0] != '\0' && access(txmPath, F_OK) == 0;
}

__exported BOOL DeviceHasTXM(void) {
    return DeviceHasJITFlags(JIT_FLAG_HAS_TXM);
}

JITFlags DeviceGetJITFlags(BOOL refresh) {
    static JITFlags cachedFlags = 0;
    static dispatch_once_t onceToken;
    if (refresh) {
        onceToken = 0;
    }
    dispatch_once(&onceToken, ^{
        const char *override = getenv("JIT_FLAGS");
        if (override) {
            if (override[0] == '0' && tolower(override[1]) == 'b') {
                cachedFlags = (JITFlags)strtoul(override + 2, NULL, 2);
            } else {
                cachedFlags = (JITFlags)strtoul(override, NULL, 0);
            }
            NSLog(@"[JIT] Using overridden JIT flags: 0x%X", cachedFlags);
            return;
        }

        cachedFlags = 0;
        if (@available(iOS 26.0, *)) {
            cachedFlags |= JIT_FLAG_IS_IOS_26;
            if (!DeviceCanCreateRXMap()) {
                cachedFlags |= JIT_FLAG_FORCE_MIRRORED;
            }
        }
        if (DeviceHasTXMReal()) {
            cachedFlags |= JIT_FLAG_HAS_TXM;
        }
        if (refresh) {
            NSLog(@"[JIT] Using computed JIT flags: 0x%X", cachedFlags);
        }
    });
    return cachedFlags;
}

BOOL DeviceHasJITFlags(JITFlags flags) {
    return (DeviceGetJITFlags(NO) & flags) == flags;
}

void requestJITForCurrentProcess(void) {
    if (@available(iOS 17.4, *)) {
        NSString *scriptQuery = @"";
        if (DeviceHasJITFlags(JIT_FLAG_FORCE_MIRRORED | JIT_FLAG_HAS_TXM)) {
            NSString *scriptPath = [NSBundle.mainBundle pathForResource:@"UniversalJIT26" ofType:@"js"];
            NSData *scriptData = [NSData dataWithContentsOfFile:scriptPath];
            if (scriptData) {
                scriptQuery = [@"&script-data=" stringByAppendingString:
                    [scriptData base64EncodedStringWithOptions:0]];
            }
        }
        NSString *urlString = [NSString stringWithFormat:
            @"stikjit://enable-jit?bundle-id=%@&pid=%d%@",
            NSBundle.mainBundle.bundleIdentifier, getpid(), scriptQuery];
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:urlString]
                                         options:@{}
                               completionHandler:nil];
    } else {
        NSString *urlString = [NSString stringWithFormat:
            @"sidestore://sidejit-enable?pid=%d", getpid()];
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:urlString]
                                         options:@{}
                               completionHandler:nil];
    }
}


void dismissModalViewController(UIViewController *viewController) {
    [viewController.navigationController dismissViewControllerAnimated:YES completion:nil];
}
