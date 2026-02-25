/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD 3-Clause License from WebDriverAgent.
 * See third_party/WebDriverAgent/LICENSE and LICENSES/WebDriverAgent.BSD-3-Clause.txt.
 */

#import <XCTest/XCTest.h>
#import <UIKit/UIKit.h>
#import <Security/Security.h>
#import <UserNotifications/UserNotifications.h>
#import <math.h>

#import <WebDriverAgentLib/FBDebugLogDelegateDecorator.h>
#import <WebDriverAgentLib/FBConfiguration.h>
#import <WebDriverAgentLib/FBFailureProofTestCase.h>
#import <WebDriverAgentLib/FBWebServer.h>
#import <WebDriverAgentLib/XCTestCase.h>

#import <WebDriverAgentLib/FBCommandHandler.h>
#import <WebDriverAgentLib/FBHTTPStatusCodes.h>
#import <WebDriverAgentLib/FBLogger.h>
#import <WebDriverAgentLib/FBResponsePayload.h>
#import <WebDriverAgentLib/FBRoute.h>
#import <WebDriverAgentLib/FBRouteRequest.h>
#import <WebDriverAgentLib/XCUIApplication+FBHelpers.h>
#import "XCUIApplication+FBTouchAction.h"
#import <WebDriverAgentLib/XCUIElement+FBTyping.h>

#import <ImageIO/ImageIO.h>

#import "RouteResponse.h"
#import "HTTPConnection.h"

static NSString *const kOnDeviceAgentTaskKey = @"ONDEVICE_AGENT_TASK";
static NSString *const kOnDeviceAgentBaseURLKey = @"ONDEVICE_AGENT_BASE_URL";
static NSString *const kOnDeviceAgentModelKey = @"ONDEVICE_AGENT_MODEL";
static NSString *const kOnDeviceAgentApiKeyKey = @"ONDEVICE_AGENT_API_KEY";
static NSString *const kOnDeviceAgentAgentTokenKey = @"ONDEVICE_AGENT_AGENT_TOKEN";
static NSString *const kOnDeviceAgentApiModeKey = @"ONDEVICE_AGENT_API_MODE";
static NSString *const kOnDeviceAgentApiModeChatCompletions = @"chat_completions";
static NSString *const kOnDeviceAgentApiModeResponses = @"responses";
static NSString *const kOnDeviceAgentErrorKindKey = @"ondevice_agent_error_kind";
static NSString *const kOnDeviceAgentErrorKindLaunchNotInMap = @"launch_not_in_map";
static NSString *const kOnDeviceAgentErrorKindInvalidParams = @"invalid_params";
static NSString *const kOnDeviceAgentMaxCompletionTokensKey = @"ONDEVICE_AGENT_MAX_COMPLETION_TOKENS";
static NSString *const kOnDeviceAgentHalfResScreenshotKey = @"ONDEVICE_AGENT_HALF_RES_SCREENSHOT";
static NSString *const kOnDeviceAgentUseCustomSystemPromptKey = @"ONDEVICE_AGENT_USE_CUSTOM_SYSTEM_PROMPT";
static NSString *const kOnDeviceAgentCustomSystemPromptKey = @"ONDEVICE_AGENT_CUSTOM_SYSTEM_PROMPT";
static NSString *const kOnDeviceAgentMaxStepsKey = @"ONDEVICE_AGENT_MAX_STEPS";
static NSString *const kOnDeviceAgentTimeoutSecondsKey = @"ONDEVICE_AGENT_TIMEOUT_SECONDS";
static NSString *const kOnDeviceAgentStepDelaySecondsKey = @"ONDEVICE_AGENT_STEP_DELAY_SECONDS";
static NSString *const kOnDeviceAgentInsecureSkipTLSVerifyKey = @"ONDEVICE_AGENT_INSECURE_SKIP_TLS_VERIFY";
static NSString *const kOnDeviceAgentRememberApiKeyKey = @"ONDEVICE_AGENT_REMEMBER_API_KEY";
static NSString *const kOnDeviceAgentDebugLogRawAssistantKey = @"ONDEVICE_AGENT_DEBUG_LOG_RAW_ASSISTANT";
static NSString *const kOnDeviceAgentReasoningEffortKey = @"ONDEVICE_AGENT_REASONING_EFFORT";
static NSString *const kOnDeviceAgentDoubaoSeedEnableSessionCacheKey = @"ONDEVICE_AGENT_DOUBAO_SEED_ENABLE_SESSION_CACHE";
static NSString *const kOnDeviceAgentUseW3CActionsForSwipeKey = @"ONDEVICE_AGENT_USE_W3C_ACTIONS_FOR_SWIPE";
static NSString *const kOnDeviceAgentRestartResponsesByPlanKey = @"ONDEVICE_AGENT_RESTART_RESPONSES_BY_PLAN";
static NSString *const kOnDeviceAgentAgentTokenHeader = @"X-OnDevice-Agent-Token";
static NSString *const kOnDeviceAgentAgentTokenQueryParam = @"token";
static NSString *const kOnDeviceAgentAgentTokenCookieName = @"ondevice_agent_token";
static NSString *const kOnDeviceAgentKeychainServiceSuffix = @".OnDeviceAgent";
static NSString *const kOnDeviceAgentKeychainAccountAPIKey = @"api_key";

static NSString *const kOnDeviceAgentDefaultBaseURL = @"https://ark.cn-beijing.volces.com/api/v3/responses";
static NSString *const kOnDeviceAgentDefaultModel = @"doubao-seed-1-8-251228";

static NSInteger const kOnDeviceAgentDefaultMaxSteps = 120;
static NSInteger const kOnDeviceAgentDefaultMaxCompletionTokens = 32768;
static double const kOnDeviceAgentDefaultTimeoutSeconds = 90.0;
static double const kOnDeviceAgentDefaultStepDelaySeconds = 0.5;

static NSInteger const kOnDeviceAgentRecoverableFailureLimit = 2;
static NSUInteger const kOnDeviceAgentMaxLogLines = 300;
static NSUInteger const kOnDeviceAgentMaxLogLineChars = 2000;
static NSInteger const kOnDeviceAgentDefaultRefreshIntervalMs = 1500;
// Chat Completions requests grow quickly. Keep a bounded, recent window to avoid context blowups
// and reduce memory usage from embedded screenshots in older rounds.
static NSUInteger const kOnDeviceAgentChatCompletionsMaxNonSystemMessages = 24; // 12 rounds (user+assistant)

@interface OnDeviceAgentManager : NSObject
+ (instancetype)shared;
- (NSString *)agentToken;
- (NSDictionary *)status;
- (NSDictionary *)statusWithDefaultSystemPrompt:(BOOL)includeDefaultSystemPrompt;
- (NSArray<NSString *> *)logs;
- (NSArray<NSDictionary *> *)chat;
@end

static UIWindow *gOnDeviceAgentConnectivityAlertWindow = nil;
static NSObject<UNUserNotificationCenterDelegate> *gOnDeviceAgentNotificationDelegate = nil;

@interface OnDeviceAgentNotificationDelegate : NSObject <UNUserNotificationCenterDelegate>
@end

@implementation OnDeviceAgentNotificationDelegate

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions options))completionHandler
{
  (void)center;
  (void)notification;
  if (@available(iOS 14.0, *)) {
    completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionList | UNNotificationPresentationOptionSound);
  } else {
    completionHandler(UNNotificationPresentationOptionAlert | UNNotificationPresentationOptionSound);
  }
}

@end

static BOOL OnDeviceAgentIsChinesePreferredLanguage(void)
{
  NSString *lang = [NSLocale preferredLanguages].firstObject;
  if (![lang isKindOfClass:NSString.class]) {
    return NO;
  }
  return [lang hasPrefix:@"zh"];
}

static void OnDeviceAgentConfigureNotificationsPromptIfNeeded(void)
{
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    if (@available(iOS 10.0, *)) {
      dispatch_async(dispatch_get_main_queue(), ^{
        UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
        gOnDeviceAgentNotificationDelegate = [OnDeviceAgentNotificationDelegate new];
        center.delegate = (id<UNUserNotificationCenterDelegate>)gOnDeviceAgentNotificationDelegate;

        [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
          if (settings.authorizationStatus != UNAuthorizationStatusNotDetermined) {
            return;
          }
          [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound | UNAuthorizationOptionBadge)
                                completionHandler:^(__unused BOOL granted, NSError * _Nullable error) {
            if (error != nil) {
              [FBLogger log:[NSString stringWithFormat:@"[ONDEVICE] Notification auth request failed: %@", error]];
            }
          }];
        }];
      });
    }
  });
}

static void OnDeviceAgentScheduleRunEndedNotification(NSString *message)
{
  if (@available(iOS 10.0, *)) {
    OnDeviceAgentConfigureNotificationsPromptIfNeeded();
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
      UNAuthorizationStatus s = settings.authorizationStatus;
      BOOL allowed =
        (s == UNAuthorizationStatusAuthorized)
        || (s == UNAuthorizationStatusProvisional)
        || (s == UNAuthorizationStatusEphemeral);
      if (!allowed) {
        return;
      }

      NSString *title = OnDeviceAgentIsChinesePreferredLanguage() ? @"运行结束" : @"Run ended";
      NSString *body = [message isKindOfClass:NSString.class]
        ? [message stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
        : @"";
      if (body.length == 0) {
        body = OnDeviceAgentIsChinesePreferredLanguage() ? @"任务已结束。" : @"Run finished.";
      }

      UNMutableNotificationContent *content = [UNMutableNotificationContent new];
      content.title = title;
      content.body = body;
      content.sound = [UNNotificationSound defaultSound];
      if (@available(iOS 15.0, *)) {
        content.interruptionLevel = UNNotificationInterruptionLevelActive;
      }

      UNTimeIntervalNotificationTrigger *trigger = [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:1 repeats:NO];
      NSString *identifier = [NSString stringWithFormat:@"ondevice_agent.run_ended.%lld", (long long)(NSDate.date.timeIntervalSince1970 * 1000)];
      UNNotificationRequest *req = [UNNotificationRequest requestWithIdentifier:identifier content:content trigger:trigger];
      [center addNotificationRequest:req withCompletionHandler:^(NSError * _Nullable error) {
        if (error != nil) {
          [FBLogger log:[NSString stringWithFormat:@"[ONDEVICE] Failed to schedule local notification: %@", error]];
        }
      }];
    }];
  }
}

static BOOL OnDeviceAgentIsLikelyLocalHost(NSString *host)
{
  if (![host isKindOfClass:NSString.class] || host.length == 0) {
    return NO;
  }

  NSString *h = host.lowercaseString;
  if ([h isEqualToString:@"localhost"] || [h isEqualToString:@"127.0.0.1"] || [h isEqualToString:@"::1"]) {
    return YES;
  }
  if ([h hasSuffix:@".local"]) {
    return YES;
  }

  // IPv4 private ranges
  if ([h hasPrefix:@"10."] || [h hasPrefix:@"192.168."] || [h hasPrefix:@"127."]) {
    return YES;
  }
  if ([h hasPrefix:@"172."]) {
    NSArray<NSString *> *parts = [h componentsSeparatedByString:@"."];
    if (parts.count >= 2) {
      NSInteger secondOctet = parts[1].integerValue;
      if (secondOctet >= 16 && secondOctet <= 31) {
        return YES;
      }
    }
  }

  // IPv6 link-local/ULA prefixes (best-effort).
  if ([h hasPrefix:@"fe80:"] || [h hasPrefix:@"fd"] || [h hasPrefix:@"fc"]) {
    return YES;
  }

  return NO;
}

static BOOL OnDeviceAgentShouldWarnAboutNoInternetAtStartup(void)
{
  NSString *baseURL = [[NSUserDefaults standardUserDefaults] stringForKey:kOnDeviceAgentBaseURLKey];
  NSString *trimmed = [baseURL isKindOfClass:NSString.class]
    ? [baseURL stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
    : @"";
  if (trimmed.length == 0) {
    baseURL = kOnDeviceAgentDefaultBaseURL;
  }

  NSURLComponents *components = [NSURLComponents componentsWithString:baseURL];
  if (components == nil) {
    return YES;
  }
  if (OnDeviceAgentIsLikelyLocalHost(components.host)) {
    // If the user points to a LAN model endpoint, "no internet" is often expected.
    return NO;
  }
  return YES;
}

static UIWindow *OnDeviceAgentFindKeyWindow(void)
{
  UIApplication *app = UIApplication.sharedApplication;
  if (@available(iOS 13.0, *)) {
    for (UIScene *scene in app.connectedScenes) {
      if (scene.activationState != UISceneActivationStateForegroundActive) {
        continue;
      }
      if (![scene isKindOfClass:UIWindowScene.class]) {
        continue;
      }
      for (UIWindow *w in ((UIWindowScene *)scene).windows) {
        if (w.isKeyWindow) {
          return w;
        }
      }
    }
    for (UIScene *scene in app.connectedScenes) {
      if (![scene isKindOfClass:UIWindowScene.class]) {
        continue;
      }
      for (UIWindow *w in ((UIWindowScene *)scene).windows) {
        if (!w.hidden) {
          return w;
        }
      }
    }
  }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  UIWindow *kw = app.keyWindow;
#pragma clang diagnostic pop
  if (kw != nil) {
    return kw;
  }
  if (app.windows.count > 0) {
    return app.windows.firstObject;
  }
  return nil;
}

static UIWindow *OnDeviceAgentEnsureAlertWindow(void)
{
  if (gOnDeviceAgentConnectivityAlertWindow != nil) {
    return gOnDeviceAgentConnectivityAlertWindow;
  }
  if (@available(iOS 13.0, *)) {
    UIWindowScene *scene = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
      if (![s isKindOfClass:UIWindowScene.class]) {
        continue;
      }
      if (s.activationState == UISceneActivationStateForegroundActive) {
        scene = (UIWindowScene *)s;
        break;
      }
    }
    if (scene != nil) {
      gOnDeviceAgentConnectivityAlertWindow = [[UIWindow alloc] initWithWindowScene:scene];
    }
  }
  if (gOnDeviceAgentConnectivityAlertWindow == nil) {
    gOnDeviceAgentConnectivityAlertWindow = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
  }
  gOnDeviceAgentConnectivityAlertWindow.windowLevel = UIWindowLevelAlert + 1;
  gOnDeviceAgentConnectivityAlertWindow.rootViewController = [UIViewController new];
  [gOnDeviceAgentConnectivityAlertWindow makeKeyAndVisible];
  return gOnDeviceAgentConnectivityAlertWindow;
}

static UIViewController *OnDeviceAgentTopViewController(void)
{
  UIWindow *w = OnDeviceAgentFindKeyWindow();
  UIViewController *vc = w.rootViewController;
  if (vc == nil) {
    vc = OnDeviceAgentEnsureAlertWindow().rootViewController;
  }
  if (vc == nil) {
    return nil;
  }

  while (vc.presentedViewController != nil) {
    vc = vc.presentedViewController;
  }
  if ([vc isKindOfClass:UINavigationController.class]) {
    UIViewController *visible = ((UINavigationController *)vc).visibleViewController;
    if (visible != nil) {
      vc = visible;
    }
  }
  if ([vc isKindOfClass:UITabBarController.class]) {
    UIViewController *selected = ((UITabBarController *)vc).selectedViewController;
    if (selected != nil) {
      vc = selected;
    }
  }
  return vc;
}

static void OnDeviceAgentPresentNoInternetAlertOnce(void)
{
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    dispatch_async(dispatch_get_main_queue(), ^{
      void (^present)(void) = ^{
        UIViewController *vc = OnDeviceAgentTopViewController();
        if (vc == nil) {
          return;
        }

        NSString *title = OnDeviceAgentIsChinesePreferredLanguage()
          ? @"网络连接不可用"
          : @"No Internet Connection";
        NSString *message = OnDeviceAgentIsChinesePreferredLanguage()
          ? @"Runner 暂时无法联网。请打开 Wi-Fi 或蜂窝网络，并在 iPhone 设置中为 Runner 开启“无线数据”，然后重新打开 Runner。"
          : @"Runner can't reach the Internet. Turn on Wi-Fi or Cellular Data, and make sure Runner's Wireless Data is enabled in Settings. Then reopen Runner.";

        UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];

        NSString *openSettings = OnDeviceAgentIsChinesePreferredLanguage() ? @"打开设置" : @"Open Settings";
        NSString *dismiss = OnDeviceAgentIsChinesePreferredLanguage() ? @"稍后" : @"Not now";

        __weak UIAlertController *weakAC = ac;
        [ac addAction:[UIAlertAction actionWithTitle:dismiss style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *a) {
          [weakAC dismissViewControllerAnimated:YES completion:nil];
          if (gOnDeviceAgentConnectivityAlertWindow != nil) {
            gOnDeviceAgentConnectivityAlertWindow.hidden = YES;
            gOnDeviceAgentConnectivityAlertWindow.rootViewController = nil;
            gOnDeviceAgentConnectivityAlertWindow = nil;
          }
        }]];
        [ac addAction:[UIAlertAction actionWithTitle:openSettings style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
          NSURL *url = [NSURL URLWithString:UIApplicationOpenSettingsURLString];
          if (url != nil && [UIApplication.sharedApplication canOpenURL:url]) {
            [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
          }
          if (gOnDeviceAgentConnectivityAlertWindow != nil) {
            gOnDeviceAgentConnectivityAlertWindow.hidden = YES;
            gOnDeviceAgentConnectivityAlertWindow.rootViewController = nil;
            gOnDeviceAgentConnectivityAlertWindow = nil;
          }
        }]];

        // Avoid presenting multiple times if something else is already on screen.
        if (vc.presentedViewController != nil) {
          return;
        }
        [vc presentViewController:ac animated:YES completion:nil];
      };

      UIApplication *app = UIApplication.sharedApplication;
      if (app.applicationState == UIApplicationStateActive) {
        present();
        return;
      }

      __block id token = nil;
      token = [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                               object:nil
                                                                queue:NSOperationQueue.mainQueue
                                                           usingBlock:^(__unused NSNotification *n) {
        [[NSNotificationCenter defaultCenter] removeObserver:token];
        token = nil;
        present();
      }];
    });
  });
}

static void OnDeviceAgentTriggerWirelessDataPromptIfNeeded(void)
{
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    BOOL shouldWarnOnFailure = OnDeviceAgentShouldWarnAboutNoInternetAtStartup();
    NSURL *url = [NSURL URLWithString:@"https://www.apple.com/library/test/success.html"];
    if (url == nil) {
      return;
    }

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    cfg.timeoutIntervalForRequest = 1.5;
    cfg.timeoutIntervalForResource = 1.5;
    cfg.waitsForConnectivity = NO;

    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];
    NSURLSessionDataTask *task = [session dataTaskWithURL:url completionHandler:^(__unused NSData *data, __unused NSURLResponse *resp, NSError *err) {
      if (err != nil) {
        [FBLogger log:[NSString stringWithFormat:@"[ONDEVICE] Connectivity probe failed: %@", err]];
        if (shouldWarnOnFailure) {
          OnDeviceAgentPresentNoInternetAlertOnce();
        }
      }
      [session finishTasksAndInvalidate];
    }];
    [task resume];
  });
}

static NSData *OnDeviceAgentDownscalePNGHalf(NSData *png)
{
  if (![png isKindOfClass:NSData.class] || png.length == 0) {
    return png;
  }

  CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)png, NULL);
  if (src == NULL) {
    return png;
  }
  CGImageRef scaled = NULL;

  // Prefer a decode-time thumbnail when available. This avoids decoding the full-resolution image
  // into memory before downscaling, which is both faster and more memory-friendly.
  size_t maxPixel = 0;
  CFDictionaryRef props = CGImageSourceCopyPropertiesAtIndex(src, 0, NULL);
  if (props != NULL) {
    CFNumberRef wNum = (CFNumberRef)CFDictionaryGetValue(props, kCGImagePropertyPixelWidth);
    CFNumberRef hNum = (CFNumberRef)CFDictionaryGetValue(props, kCGImagePropertyPixelHeight);
    long long w = 0;
    long long h = 0;
    if (wNum != NULL && hNum != NULL && CFNumberGetValue(wNum, kCFNumberLongLongType, &w)
        && CFNumberGetValue(hNum, kCFNumberLongLongType, &h) && w > 0 && h > 0) {
      if (w >= 4 && h >= 4) {
        long long m = (w > h) ? w : h;
        maxPixel = (size_t)(m / 2);
      }
    }
    CFRelease(props);
  }

  if (maxPixel >= 2) {
    CFDictionaryRef opts = (__bridge CFDictionaryRef)@{
      (NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
      (NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES,
      (NSString *)kCGImageSourceShouldCacheImmediately: @YES,
      (NSString *)kCGImageSourceThumbnailMaxPixelSize: @(maxPixel),
    };
    scaled = CGImageSourceCreateThumbnailAtIndex(src, 0, opts);
  }

  if (scaled == NULL) {
    // Fallback: full decode + downscale via CoreGraphics.
    CGImageRef image = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    if (image == NULL) {
      CFRelease(src);
      return png;
    }

    size_t w = CGImageGetWidth(image);
    size_t h = CGImageGetHeight(image);
    if (w < 4 || h < 4) {
      CGImageRelease(image);
      CFRelease(src);
      return png;
    }

    size_t nw = w / 2;
    size_t nh = h / 2;
    if (nw < 2 || nh < 2) {
      CGImageRelease(image);
      CFRelease(src);
      return png;
    }

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    if (cs == NULL) {
      CGImageRelease(image);
      CFRelease(src);
      return png;
    }
    CGContextRef ctx = CGBitmapContextCreate(NULL, nw, nh, 8, 0, cs, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (ctx == NULL) {
      CGImageRelease(image);
      CFRelease(src);
      return png;
    }

    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    CGContextDrawImage(ctx, CGRectMake(0, 0, (CGFloat)nw, (CGFloat)nh), image);
    CGImageRelease(image);

    scaled = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    if (scaled == NULL) {
      CFRelease(src);
      return png;
    }
  }
  CFRelease(src);

  CFMutableDataRef outData = CFDataCreateMutable(kCFAllocatorDefault, 0);
  if (outData == NULL) {
    CGImageRelease(scaled);
    return png;
  }

  CGImageDestinationRef dest = CGImageDestinationCreateWithData(outData, CFSTR("public.png"), 1, NULL);
  if (dest == NULL) {
    CGImageRelease(scaled);
    CFRelease(outData);
    return png;
  }

  CGImageDestinationAddImage(dest, scaled, NULL);
  CGImageRelease(scaled);
  BOOL ok = CGImageDestinationFinalize(dest);
  CFRelease(dest);
  if (!ok) {
    CFRelease(outData);
    return png;
  }
  NSData *out = [(__bridge NSData *)outData copy];
  CFRelease(outData);
  return (out.length > 0) ? out : png;
}

static BOOL OnDeviceAgentParseBool(id value, BOOL defaultValue)
{
  if ([value isKindOfClass:NSNumber.class]) {
    return [((NSNumber *)value) boolValue];
  }
  if (![value isKindOfClass:NSString.class]) {
    return defaultValue;
  }
  NSString *lower = [((NSString *)value) lowercaseString];
  if ([lower isEqualToString:@"1"] || [lower isEqualToString:@"true"] || [lower isEqualToString:@"yes"] || [lower isEqualToString:@"y"]) {
    return YES;
  }
  if ([lower isEqualToString:@"0"] || [lower isEqualToString:@"false"] || [lower isEqualToString:@"no"] || [lower isEqualToString:@"n"]) {
    return NO;
  }
  return defaultValue;
}

static NSInteger OnDeviceAgentParseInt(id value, NSInteger defaultValue)
{
  if ([value isKindOfClass:NSNumber.class]) {
    return [((NSNumber *)value) integerValue];
  }
  if (![value isKindOfClass:NSString.class]) {
    return defaultValue;
  }
  NSString *s = [((NSString *)value) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (s.length == 0) {
    return defaultValue;
  }
  return [s integerValue];
}

static double OnDeviceAgentParseDouble(id value, double defaultValue)
{
  if ([value isKindOfClass:NSNumber.class]) {
    return [((NSNumber *)value) doubleValue];
  }
  if (![value isKindOfClass:NSString.class]) {
    return defaultValue;
  }
  NSString *s = [((NSString *)value) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (s.length == 0) {
    return defaultValue;
  }
  return [s doubleValue];
}

static BOOL OnDeviceAgentNSNumberIsBool(NSNumber *value)
{
  if (![value isKindOfClass:NSNumber.class]) {
    return NO;
  }
  return CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

static BOOL OnDeviceAgentParseIntStrict(id value, NSInteger *outValue)
{
  if ([value isKindOfClass:NSNumber.class]) {
    NSNumber *n = (NSNumber *)value;
    if (OnDeviceAgentNSNumberIsBool(n)) {
      return NO;
    }
    const char *objCType = [n objCType];
    BOOL isFloatType = (objCType != NULL) && (strchr("fd", objCType[0]) != NULL);
    if (isFloatType) {
      double d = [n doubleValue];
      if (!isfinite(d) || floor(d) != d) {
        return NO;
      }
      if (d > (double)NSIntegerMax || d < (double)NSIntegerMin) {
        return NO;
      }
      if (outValue) {
        *outValue = (NSInteger)d;
      }
      return YES;
    }
#if !__LP64__
    long long ll = [n longLongValue];
    if (ll > (long long)NSIntegerMax || ll < (long long)NSIntegerMin) {
      return NO;
    }
#endif
    if (outValue) {
      *outValue = [n integerValue];
    }
    return YES;
  }
  if (![value isKindOfClass:NSString.class]) {
    return NO;
  }
  NSString *s = [((NSString *)value) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (s.length == 0) {
    return NO;
  }
  NSScanner *scanner = [NSScanner scannerWithString:s];
  long long parsed = 0;
  if (![scanner scanLongLong:&parsed] || !scanner.isAtEnd) {
    return NO;
  }
#if !__LP64__
  if (parsed > (long long)NSIntegerMax || parsed < (long long)NSIntegerMin) {
    return NO;
  }
#endif
  if (outValue) {
    *outValue = (NSInteger)parsed;
  }
  return YES;
}

static BOOL OnDeviceAgentParseDoubleStrict(id value, double *outValue)
{
  if ([value isKindOfClass:NSNumber.class]) {
    NSNumber *n = (NSNumber *)value;
    if (OnDeviceAgentNSNumberIsBool(n)) {
      return NO;
    }
    double d = [n doubleValue];
    if (!isfinite(d)) {
      return NO;
    }
    if (outValue) {
      *outValue = d;
    }
    return YES;
  }
  if (![value isKindOfClass:NSString.class]) {
    return NO;
  }
  NSString *s = [((NSString *)value) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (s.length == 0) {
    return NO;
  }
  NSScanner *scanner = [NSScanner scannerWithString:s];
  double parsed = 0;
  if (![scanner scanDouble:&parsed] || !scanner.isAtEnd || !isfinite(parsed)) {
    return NO;
  }
  if (outValue) {
    *outValue = parsed;
  }
  return YES;
}

static NSInteger OnDeviceAgentMaxChatSteps(NSDictionary *config)
{
  NSInteger maxSteps = OnDeviceAgentParseInt(config[kOnDeviceAgentMaxStepsKey], kOnDeviceAgentDefaultMaxSteps);
  if (maxSteps <= 0) {
    maxSteps = kOnDeviceAgentDefaultMaxSteps;
  }
  return maxSteps;
}

static NSUInteger OnDeviceAgentMaxChatItemsHardLimit(NSDictionary *config)
{
  NSInteger maxSteps = OnDeviceAgentMaxChatSteps(config);
  // Typical is 2 items/step (request + response). In error cases we may log more (fix_request/fix_response).
  // Use a generous multiplier to keep the whole run while still bounding memory usage.
  NSUInteger hard = (NSUInteger)MAX(200, maxSteps * 8);
  return hard;
}

static void OnDeviceAgentSyncOnMain(dispatch_block_t block)
{
  if (block == nil) {
    return;
  }
  if (NSThread.isMainThread) {
    block();
    return;
  }
  dispatch_sync(dispatch_get_main_queue(), block);
}

static BOOL OnDeviceAgentParsePoint01From1000Array(id value, double *outX, double *outY, NSString **outError)
{
  if (![value isKindOfClass:NSArray.class] || [((NSArray *)value) count] != 2) {
    if (outError) {
      *outError = @"Expected a coordinate array like [x, y]";
    }
    return NO;
  }
  NSArray *arr = (NSArray *)value;
  if (![arr[0] isKindOfClass:NSNumber.class] || ![arr[1] isKindOfClass:NSNumber.class]) {
    if (outError) {
      *outError = @"Coordinate array values must be numbers";
    }
    return NO;
  }
  double x1000 = [arr[0] doubleValue];
  double y1000 = [arr[1] doubleValue];
  if (!(x1000 >= 0.0 && x1000 <= 1000.0 && y1000 >= 0.0 && y1000 <= 1000.0)) {
    if (outError) {
      *outError = @"Coordinate values must be in range [0, 1000]";
    }
    return NO;
  }
  if (outX) {
    *outX = x1000 / 1000.0;
  }
  if (outY) {
    *outY = y1000 / 1000.0;
  }
  return YES;
}

static double OnDeviceAgentClampDouble(double v, double minV, double maxV)
{
  if (v < minV) {
    return minV;
  }
  if (v > maxV) {
    return maxV;
  }
  return v;
}

static NSArray *OnDeviceAgentBuildW3CSwipeActions(XCUIApplication *application,
                                                 double startX01,
                                                 double startY01,
                                                 double endX01,
                                                 double endY01,
                                                 NSInteger durationMs,
                                                 NSInteger holdMs)
{
  CGSize viewport = application.frame.size;
  CGFloat w = viewport.width;
  CGFloat h = viewport.height;
  if (w < 1.0 || h < 1.0) {
    // Fallback: use the device screen bounds in points.
    CGSize screen = UIScreen.mainScreen.bounds.size;
    w = screen.width;
    h = screen.height;
  }
  if (w < 1.0 || h < 1.0) {
    return nil;
  }

  double sx = OnDeviceAgentClampDouble(startX01, 0.0, 1.0) * (double)w;
  double sy = OnDeviceAgentClampDouble(startY01, 0.0, 1.0) * (double)h;
  double ex = OnDeviceAgentClampDouble(endX01, 0.0, 1.0) * (double)w;
  double ey = OnDeviceAgentClampDouble(endY01, 0.0, 1.0) * (double)h;

  NSInteger moveMs = durationMs;
  if (moveMs <= 0) {
    moveMs = 250;
  }
  if (moveMs > 5000) {
    moveMs = 5000;
  }
  NSInteger pauseMs = holdMs;
  if (pauseMs == 0 && holdMs == 0) {
    // Default to a short end-hold so the lift-off velocity is closer to 0, reducing inertial scrolling.
    pauseMs = 120;
  }
  if (pauseMs < 0) {
    pauseMs = 0;
  }
  if (pauseMs > 2000) {
    pauseMs = 2000;
  }

  return @[
    @{
      @"type": @"pointer",
      @"id": @"finger1",
      @"parameters": @{@"pointerType": @"touch"},
      @"actions": @[
        @{@"type": @"pointerMove", @"duration": @0, @"origin": @"viewport", @"x": @(sx), @"y": @(sy)},
        @{@"type": @"pointerDown", @"button": @0},
        @{@"type": @"pointerMove", @"duration": @(moveMs), @"origin": @"viewport", @"x": @(ex), @"y": @(ey)},
        @{@"type": @"pause", @"duration": @(pauseMs)},
        @{@"type": @"pointerUp", @"button": @0},
      ],
    },
  ];
}

static NSString *OnDeviceAgentStringOrEmpty(id value)
{
  return [value isKindOfClass:NSString.class] ? (NSString *)value : @"";
}

static NSString *OnDeviceAgentTrim(NSString *s)
{
  return [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSString *OnDeviceAgentNormalizeApiKey(NSString *raw)
{
  NSString *s = OnDeviceAgentTrim(raw ?: @"");
  if (s.length == 0) {
    return @"";
  }

  NSString *lower = [s lowercaseString];
  if ([lower hasPrefix:@"authorization:"]) {
    s = OnDeviceAgentTrim([s substringFromIndex:@"authorization:".length]);
  }
  lower = [s lowercaseString];
  if ([lower hasPrefix:@"bearer"]) {
    s = OnDeviceAgentTrim([s substringFromIndex:@"bearer".length]);
  }
  return s;
}

static void OnDeviceAgentTrimChatCompletionsContextInPlace(NSMutableArray<NSDictionary *> *messages)
{
  if (messages.count == 0) {
    return;
  }

  NSDictionary *first = [messages.firstObject isKindOfClass:NSDictionary.class] ? (NSDictionary *)messages.firstObject : nil;
  BOOL hasSystem = [OnDeviceAgentStringOrEmpty(first[@"role"]) isEqualToString:@"system"];
  NSUInteger start = hasSystem ? 1 : 0;
  NSUInteger maxTotal = start + kOnDeviceAgentChatCompletionsMaxNonSystemMessages;
  if (messages.count <= maxTotal) {
    return;
  }

  NSUInteger removeCount = messages.count - maxTotal;
  [messages removeObjectsInRange:NSMakeRange(start, removeCount)];
}

static NSString *OnDeviceAgentJSONStringFromObject(id obj)
{
  if (obj == nil) {
    return @"";
  }
  if (![NSJSONSerialization isValidJSONObject:obj]) {
    return [obj description] ?: @"";
  }
  NSError *err = nil;
  NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:&err];
  if (data == nil) {
    return [obj description] ?: @"";
  }
  NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  return s ?: ([obj description] ?: @"");
}

static BOOL OnDeviceAgentRawKeyShouldRedact(NSString *key)
{
  NSString *k = OnDeviceAgentTrim(key ?: @"").lowercaseString;
  if (k.length == 0) {
    return NO;
  }
  return [k isEqualToString:@"authorization"] ||
         [k isEqualToString:@"x-ondevice-agent-token"] ||
         [k isEqualToString:@"api_key"] ||
         [k isEqualToString:@"apikey"] ||
         [k isEqualToString:@"agent_token"] ||
         [k isEqualToString:@"agenttoken"] ||
         [k isEqualToString:@"ondevice_agent_token"] ||
         [k hasSuffix:@"_api_key"];
}

static NSString *OnDeviceAgentRedactStringForRaw(NSString *value, NSString *keyHint)
{
  NSString *v = value ?: @"";
  if (OnDeviceAgentRawKeyShouldRedact(keyHint)) {
    return @"<redacted>";
  }
  NSString *lower = v.lowercaseString;
  if ([lower hasPrefix:@"data:image/"] && [lower containsString:@"base64,"]) {
    return @"data:image/png;base64,<omitted>";
  }
  if ([lower hasPrefix:@"bearer "] || [lower hasPrefix:@"authorization: bearer "]) {
    return @"<redacted>";
  }
  return v;
}

static id OnDeviceAgentRedactObjectForRaw(id obj, NSString *keyHint)
{
  if ([obj isKindOfClass:NSString.class]) {
    return OnDeviceAgentRedactStringForRaw((NSString *)obj, keyHint);
  }

  if ([obj isKindOfClass:NSDictionary.class]) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSDictionary *src = (NSDictionary *)obj;
    for (id kObj in src) {
      NSString *k = [kObj isKindOfClass:NSString.class] ? (NSString *)kObj : @"";
      id v = src[kObj];
      if (OnDeviceAgentRawKeyShouldRedact(k)) {
        out[kObj ?: @""] = @"<redacted>";
      } else {
        out[kObj ?: @""] = OnDeviceAgentRedactObjectForRaw(v, k);
      }
    }
    return out.copy;
  }

  if ([obj isKindOfClass:NSArray.class]) {
    NSMutableArray *arr = [NSMutableArray array];
    for (id item in (NSArray *)obj) {
      [arr addObject:OnDeviceAgentRedactObjectForRaw(item, keyHint)];
    }
    return arr.copy;
  }

  return obj ?: [NSNull null];
}

static NSString *OnDeviceAgentJSONStringFromObjectForRaw(id obj)
{
  id redacted = OnDeviceAgentRedactObjectForRaw(obj, @"");
  return OnDeviceAgentJSONStringFromObject(redacted);
}

static NSString *OnDeviceAgentTruncate(NSString *s, NSUInteger maxChars)
{
  if (s.length <= maxChars) {
    return s;
  }
  return [[s substringToIndex:maxChars] stringByAppendingString:@"..."];
}

static NSDictionary *OnDeviceAgentSanitizeMessageForChat(id msgObj)
{
  if (![msgObj isKindOfClass:NSDictionary.class]) {
    return @{};
  }
  NSDictionary *msg = (NSDictionary *)msgObj;
  NSMutableDictionary *m = [msg mutableCopy];

  id content = m[@"content"];
  if ([content isKindOfClass:NSArray.class]) {
    NSMutableArray *parts = [NSMutableArray array];
    for (id partObj in (NSArray *)content) {
      if (![partObj isKindOfClass:NSDictionary.class]) {
        [parts addObject:partObj];
        continue;
      }
      NSDictionary *part = (NSDictionary *)partObj;
      NSString *type = [part[@"type"] isKindOfClass:NSString.class] ? (NSString *)part[@"type"] : @"";
      if (![type isEqualToString:@"image_url"]) {
        [parts addObject:part];
        continue;
      }
      NSMutableDictionary *p = [part mutableCopy];
      id imageUrlObj = p[@"image_url"];
      if ([imageUrlObj isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *iu = [((NSDictionary *)imageUrlObj) mutableCopy];
        iu[@"url"] = @"data:image/png;base64,<omitted>";
        p[@"image_url"] = iu.copy;
      }
      [parts addObject:p.copy];
    }
    m[@"content"] = parts.copy;
  }

  return m.copy;
}

static NSDictionary *OnDeviceAgentSanitizeResponsesObjectForChat(id obj)
{
  if (![obj isKindOfClass:NSDictionary.class]) {
    return @{};
  }
  NSMutableDictionary *out = [((NSDictionary *)obj) mutableCopy];
  id input = out[@"input"];
  if ([input isKindOfClass:NSArray.class]) {
    NSMutableArray *items = [NSMutableArray array];
    for (id itemObj in (NSArray *)input) {
      if (![itemObj isKindOfClass:NSDictionary.class]) {
        [items addObject:itemObj];
        continue;
      }
      NSMutableDictionary *item = [((NSDictionary *)itemObj) mutableCopy];
      id content = item[@"content"];
      if ([content isKindOfClass:NSArray.class]) {
        NSMutableArray *parts = [NSMutableArray array];
        for (id partObj in (NSArray *)content) {
          if (![partObj isKindOfClass:NSDictionary.class]) {
            [parts addObject:partObj];
            continue;
          }
          NSMutableDictionary *part = [((NSDictionary *)partObj) mutableCopy];
          NSString *type = [part[@"type"] isKindOfClass:NSString.class] ? (NSString *)part[@"type"] : @"";
          NSString *lower = [type lowercaseString];
          if ([lower isEqualToString:@"input_image"] || [lower isEqualToString:@"image_url"]) {
            id imageUrlObj = part[@"image_url"];
            if ([imageUrlObj isKindOfClass:NSString.class]) {
              part[@"image_url"] = @"data:image/png;base64,<omitted>";
            } else if ([imageUrlObj isKindOfClass:NSDictionary.class]) {
              NSMutableDictionary *iu = [((NSDictionary *)imageUrlObj) mutableCopy];
              iu[@"url"] = @"data:image/png;base64,<omitted>";
              part[@"image_url"] = iu.copy;
            }
          }
          [parts addObject:part.copy];
        }
        item[@"content"] = parts.copy;
      }
      [items addObject:item.copy];
    }
    out[@"input"] = items.copy;
  }
  return out.copy;
}

static NSDictionary *OnDeviceAgentSanitizeChatCompletionsResponseForChat(id obj)
{
  if (![obj isKindOfClass:NSDictionary.class]) {
    return @{};
  }
  NSMutableDictionary *out = [((NSDictionary *)obj) mutableCopy];
  id choices = out[@"choices"];
  if ([choices isKindOfClass:NSArray.class]) {
    NSMutableArray *newChoices = [NSMutableArray array];
    for (id choiceObj in (NSArray *)choices) {
      if (![choiceObj isKindOfClass:NSDictionary.class]) {
        [newChoices addObject:choiceObj];
        continue;
      }
      NSMutableDictionary *choice = [((NSDictionary *)choiceObj) mutableCopy];
      id messageObj = choice[@"message"];
      if ([messageObj isKindOfClass:NSDictionary.class]) {
        choice[@"message"] = OnDeviceAgentSanitizeMessageForChat(messageObj);
      }
      id deltaObj = choice[@"delta"];
      if ([deltaObj isKindOfClass:NSDictionary.class]) {
        choice[@"delta"] = OnDeviceAgentSanitizeMessageForChat(deltaObj);
      }
      [newChoices addObject:choice.copy];
    }
    out[@"choices"] = newChoices.copy;
  }
  return out.copy;
}

static NSArray<NSDictionary *> *OnDeviceAgentSanitizeResponsesInputForRaw(NSArray<NSDictionary *> *input)
{
  if (![input isKindOfClass:NSArray.class] || input.count == 0) {
    return @[];
  }
  NSMutableArray<NSDictionary *> *items = [NSMutableArray arrayWithCapacity:input.count];
  for (id itemObj in input) {
    if (![itemObj isKindOfClass:NSDictionary.class]) {
      continue;
    }
	    NSDictionary *item = (NSDictionary *)itemObj;
	    NSMutableDictionary *m = [item mutableCopy];

	    id content = m[@"content"];
    if ([content isKindOfClass:NSString.class]) {
      [items addObject:m.copy];
      continue;
    }
    if (![content isKindOfClass:NSArray.class]) {
      [items addObject:m.copy];
      continue;
    }

    NSMutableArray *parts = [NSMutableArray array];
    for (id partObj in (NSArray *)content) {
      if (![partObj isKindOfClass:NSDictionary.class]) {
        continue;
      }
      NSMutableDictionary *p = [((NSDictionary *)partObj) mutableCopy];
      NSString *type = [p[@"type"] isKindOfClass:NSString.class] ? (NSString *)p[@"type"] : @"";
      NSString *lower = [type lowercaseString];

      if ([lower isEqualToString:@"input_image"] || [lower isEqualToString:@"image_url"]) {
        id imageUrlObj = p[@"image_url"];
        if ([imageUrlObj isKindOfClass:NSString.class]) {
          p[@"image_url"] = @"data:image/png;base64,<omitted>";
        } else if ([imageUrlObj isKindOfClass:NSDictionary.class]) {
          NSMutableDictionary *iu = [((NSDictionary *)imageUrlObj) mutableCopy];
          iu[@"url"] = @"data:image/png;base64,<omitted>";
          p[@"image_url"] = iu.copy;
        }
      }

      [parts addObject:p.copy];
    }
    m[@"content"] = parts.copy;
    [items addObject:m.copy];
  }
  return items.copy;
}

static NSDictionary *OnDeviceAgentOmitChatMessageContentKeepingShape(NSDictionary *msg, NSString *placeholder)
{
  if (![msg isKindOfClass:NSDictionary.class]) {
    return @{};
  }
  NSMutableDictionary *m = [msg mutableCopy];
  id content = m[@"content"];
  if ([content isKindOfClass:NSString.class]) {
    m[@"content"] = placeholder ?: @"";
    return m.copy;
  }
  if ([content isKindOfClass:NSArray.class]) {
    NSMutableArray *parts = [NSMutableArray array];
    for (id partObj in (NSArray *)content) {
      if (![partObj isKindOfClass:NSDictionary.class]) {
        [parts addObject:partObj];
        continue;
      }
      NSMutableDictionary *p = [((NSDictionary *)partObj) mutableCopy];
      NSString *type = [p[@"type"] isKindOfClass:NSString.class] ? (NSString *)p[@"type"] : @"";
      if ([type isEqualToString:@"text"]) {
        p[@"text"] = placeholder ?: @"";
      } else if ([type isEqualToString:@"image_url"]) {
        id imageUrlObj = p[@"image_url"];
        if ([imageUrlObj isKindOfClass:NSDictionary.class]) {
          NSMutableDictionary *iu = [((NSDictionary *)imageUrlObj) mutableCopy];
          iu[@"url"] = @"data:image/png;base64,<omitted>";
          p[@"image_url"] = iu.copy;
        }
      }
      [parts addObject:p.copy];
    }
    m[@"content"] = parts.copy;
    return m.copy;
  }
  m[@"content"] = placeholder ?: @"";
  return m.copy;
}

static NSArray<NSDictionary *> *OnDeviceAgentSummarizeChatCompletionsMessagesForRaw(NSArray<NSDictionary *> *messages, NSInteger currentStep)
{
  if (![messages isKindOfClass:NSArray.class] || messages.count == 0) {
    return @[];
  }
  NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
  NSInteger idx = 0;
  for (id msgObj in messages) {
    NSDictionary *sanitized = OnDeviceAgentSanitizeMessageForChat(msgObj);
    if (sanitized.count == 0) {
      idx++;
      continue;
    }
    if (idx == 0) {
      [out addObject:sanitized];
      idx++;
      continue;
    }
    NSInteger round = (idx - 1) / 2;
    if (round < currentStep) {
      NSString *placeholder = [NSString stringWithFormat:@"<round %ld content omitted>", (long)round];
      [out addObject:OnDeviceAgentOmitChatMessageContentKeepingShape(sanitized, placeholder)];
    } else {
      [out addObject:sanitized];
    }
    idx++;
  }
  return out.copy;
}

static NSDictionary *OnDeviceAgentActionForLogs(NSDictionary *action)
{
  if (![action isKindOfClass:NSDictionary.class]) {
    return @{};
  }
  NSMutableDictionary *out = [action mutableCopy];
  [out removeObjectForKey:@"think"];
  [out removeObjectForKey:@"plan"];
  if ([out[@"action"] isKindOfClass:NSDictionary.class]) {
    NSMutableDictionary *a = [((NSDictionary *)out[@"action"]) mutableCopy];
    if ([a[@"params"] isKindOfClass:NSDictionary.class]) {
      NSMutableDictionary *p = [((NSDictionary *)a[@"params"]) mutableCopy];
      if ([p[@"text"] isKindOfClass:NSString.class]) {
        p[@"text"] = OnDeviceAgentTruncate((NSString *)p[@"text"], 200);
      }
      if ([p[@"message"] isKindOfClass:NSString.class]) {
        p[@"message"] = OnDeviceAgentTruncate((NSString *)p[@"message"], 200);
      }
      a[@"params"] = p.copy;
    }
    out[@"action"] = a.copy;
  }
  return out.copy;
}

static NSString *OnDeviceAgentCollapseSpaces(NSString *s)
{
  NSString *out = s ?: @"";
  while ([out containsString:@"  "]) {
    out = [out stringByReplacingOccurrencesOfString:@"  " withString:@" "];
  }
  return out;
}

static NSString *OnDeviceAgentNormalizeReasoningEffort(NSString *raw)
{
  return OnDeviceAgentTrim(raw ?: @"");
}

static NSString *OnDeviceAgentNormalizeApiMode(NSString *raw)
{
  NSString *s = OnDeviceAgentTrim(raw ?: @"");
  if (s.length == 0) {
    return @"";
  }
  if ([s isEqualToString:kOnDeviceAgentApiModeChatCompletions]) {
    return s;
  }
  if ([s isEqualToString:kOnDeviceAgentApiModeResponses]) {
    return s;
  }
  return @"";
}

static NSString *OnDeviceAgentNormalizeActionName(NSString *raw)
{
  NSString *s = OnDeviceAgentTrim(raw ?: @"");
  if (s.length == 0) {
    return @"";
  }
  s = [[s lowercaseString] stringByReplacingOccurrencesOfString:@"_" withString:@" "];
  s = [s stringByReplacingOccurrencesOfString:@"-" withString:@" "];
  s = OnDeviceAgentCollapseSpaces(s);

  if ([s isEqualToString:@"double tap"] || [s isEqualToString:@"doubletap"]) {
    return @"double_tap";
  }
  if ([s isEqualToString:@"long press"] || [s isEqualToString:@"longpress"]) {
    return @"long_press";
  }
  if ([s isEqualToString:@"finish"]) {
    return @"finish";
  }
  if ([s isEqualToString:@"launch"]) {
    return @"launch";
  }
  if ([s isEqualToString:@"tap"]) {
    return @"tap";
  }
  if ([s isEqualToString:@"type"]) {
    return @"type";
  }
  if ([s isEqualToString:@"swipe"]) {
    return @"swipe";
  }
  if ([s isEqualToString:@"back"]) {
    return @"back";
  }
  if ([s isEqualToString:@"home"]) {
    return @"home";
  }
  if ([s isEqualToString:@"wait"]) {
    return @"wait";
  }
  if ([s isEqualToString:@"note"]) {
    return @"note";
  }

  return s;
}

static NSString *OnDeviceAgentNowString(void)
{
  static NSString *const kKey = @"ondevice_agent.nowString.formatter";
  NSMutableDictionary *td = NSThread.currentThread.threadDictionary;
  NSDateFormatter *f = [td[kKey] isKindOfClass:NSDateFormatter.class] ? (NSDateFormatter *)td[kKey] : nil;
  if (f == nil) {
    f = [NSDateFormatter new];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    td[kKey] = f;
  }
  return [f stringFromDate:[NSDate date]] ?: @"";
}

static id OnDeviceAgentLogCoerceJSONValue(id v);

static NSDictionary *OnDeviceAgentLogCoerceJSONDict(NSDictionary *fields)
{
  if (![fields isKindOfClass:NSDictionary.class]) {
    return @{};
  }
  NSMutableDictionary *out = [NSMutableDictionary dictionary];
  for (id kObj in fields) {
    NSString *k = [kObj isKindOfClass:NSString.class] ? (NSString *)kObj : [[kObj description] ?: @"" copy];
    k = OnDeviceAgentTrim(k ?: @"");
    if (k.length == 0) {
      continue;
    }
    out[k] = OnDeviceAgentLogCoerceJSONValue(fields[kObj]);
  }
  return out.copy;
}

static id OnDeviceAgentLogCoerceJSONValue(id v)
{
  if (v == nil) {
    return [NSNull null];
  }
  if ([v isKindOfClass:NSString.class]) {
    return OnDeviceAgentTruncate((NSString *)v, kOnDeviceAgentMaxLogLineChars);
  }
  if ([v isKindOfClass:NSNumber.class] || [v isKindOfClass:NSNull.class]) {
    return v;
  }
  if ([v isKindOfClass:NSDictionary.class]) {
    return OnDeviceAgentLogCoerceJSONDict((NSDictionary *)v);
  }
  if ([v isKindOfClass:NSArray.class]) {
    NSMutableArray *arr = [NSMutableArray array];
    for (id item in (NSArray *)v) {
      [arr addObject:OnDeviceAgentLogCoerceJSONValue(item)];
    }
    return arr.copy;
  }
  return OnDeviceAgentTruncate([v description] ?: @"", kOnDeviceAgentMaxLogLineChars);
}

static NSString *OnDeviceAgentLogJSONLine(NSString *level, NSString *tag, NSString *event, NSString *message, NSDictionary *fields)
{
  NSMutableDictionary *d = [NSMutableDictionary dictionary];
  d[@"ts"] = OnDeviceAgentNowString();
  d[@"lvl"] = OnDeviceAgentTrim(level ?: @"info");
  d[@"tag"] = OnDeviceAgentTrim(tag ?: @"agent");
  d[@"event"] = OnDeviceAgentTrim(event ?: @"message");
  if ([message isKindOfClass:NSString.class]) {
    NSString *msg = OnDeviceAgentTrim(message);
    if (msg.length > 0) {
      d[@"msg"] = OnDeviceAgentTruncate(msg, kOnDeviceAgentMaxLogLineChars);
    }
  }
  [d addEntriesFromDictionary:OnDeviceAgentLogCoerceJSONDict(fields)];
  return OnDeviceAgentJSONStringFromObject(d) ?: @"";
}

static NSString *OnDeviceAgentFormattedDateZH(void)
{
  NSDate *date = [NSDate date];
  NSDateFormatter *f = [NSDateFormatter new];
  f.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
  f.dateFormat = @"yyyy年MM月dd日";
  NSString *day = [f stringFromDate:date] ?: @"";

  NSArray<NSString *> *weekdays = @[@"星期日", @"星期一", @"星期二", @"星期三", @"星期四", @"星期五", @"星期六"];
  NSCalendar *cal = [NSCalendar currentCalendar];
  NSInteger idx = [[cal components:NSCalendarUnitWeekday fromDate:date] weekday];
  NSString *weekday = (idx >= 1 && idx <= (NSInteger)weekdays.count) ? weekdays[idx - 1] : @"";

  if (weekday.length == 0) {
    return day;
  }
  return [NSString stringWithFormat:@"%@ %@", day, weekday];
}

static NSString *OnDeviceAgentFormattedDateEN(void)
{
  NSDate *date = [NSDate date];

  NSDateFormatter *df = [NSDateFormatter new];
  df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
  df.dateFormat = @"yyyy-MM-dd";
  NSString *day = [df stringFromDate:date] ?: @"";

  NSDateFormatter *wf = [NSDateFormatter new];
  wf.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
  wf.dateFormat = @"EEE";
  NSString *weekday = [wf stringFromDate:date] ?: @"";

  if (weekday.length == 0) {
    return day;
  }
  return [NSString stringWithFormat:@"%@ (%@)", day, weekday];
}

static NSString *OnDeviceAgentHTMLEscape(NSString *s)
{
  NSString *out = s ?: @"";
  out = [out stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"];
  out = [out stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"];
  out = [out stringByReplacingOccurrencesOfString:@">" withString:@"&gt;"];
  out = [out stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"];
  return out;
}

static NSString *OnDeviceAgentJSONStringLiteral(NSString *s)
{
  NSString *value = s ?: @"";
  NSError *err = nil;
  NSData *data = [NSJSONSerialization dataWithJSONObject:@[value] options:0 error:&err];
  if (data == nil) {
    return @"\"\"";
  }
  NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
  // Format: ["..."], return the inner string literal "...".
  if ([json hasPrefix:@"["] && [json hasSuffix:@"]"] && json.length >= 2) {
    return [json substringWithRange:NSMakeRange(1, json.length - 2)];
  }
  return @"\"\"";
}

static NSString *OnDeviceAgentDefaultSystemPromptTemplate(void)
{
  static NSString *const kOnDeviceAgentSystemPromptPreamble =
    @"今天的日期是：{{DATE_ZH}}\n"
    @"\n"
    @"你是一个运行在 iPhone 上的 UI 自动化智能体。\n"
    @"每一步你会收到：任务、当前屏幕截图、屏幕信息（Screen Info，JSON）。请基于当前屏幕选择下一步操作，直到完成任务。\n"
    @"\n";

  static NSString *const kOnDeviceAgentSystemPromptOutputFormat =
    @"【输出格式｜Response JSON】\n"
    @"下面是回复的硬性契约，用于保证可解析与可执行。\n"
    @"- 整段回复必须是且仅是 1 个 JSON 对象（不要输出任何其它文本/解释/Markdown/代码块）。\n"
    @"- JSON 必须包含字段：\n"
    @"  - `think`：字符串\n"
    @"  - `plan`：数组（清单）\n"
    @"  - `action`：对象\n"
    @"- `action` 必须是对象：`{\"name\":\"...\", \"params\":{...}}`（不要把 `action` 写成字符串）。\n"
    @"- `action.name` 必须是字符串；所有动作参数必须放在 `action.params` 中（不要放到顶层）。\n"
    @"- `action.params` 必须是对象；没有参数时也要给 `{}`。\n"
    @"\n";

  static NSString *const kOnDeviceAgentSystemPromptPlan =
    @"【计划｜plan】\n"
    @"你必须维护一个清单（字段 `plan`）来推进长任务。\n"
    @"- 第 0 步：先输出 `plan` 数组，每项为 `{\"text\":\"...\",\"done\":true/false}`。\n"
    @"- 后续每一步：继续输出 `plan`（可原样输出），并按进度更新 `done`。\n"
    @"- 尽量只追加新条目（不要随意删除/重排），避免长任务中丢失进度。\n"
    @"- 对“批量写入/多条提交”类的大项：只有在写入结果已可验证（例如回到列表/总览页可见）后，才将其标记为 `done=true`。\n"
    @"- 清单可包含更多条目（<=50 项）。如果需要记录更多细节，请写入 Notes。\n"
    @"\n";

  static NSString *const kOnDeviceAgentSystemPromptNote =
    @"【工作记忆｜Notes】\n"
    @"Notes 用来保存你已确认的中间事实与阶段性结果，避免长任务跑偏。\n"
    @"- Notes 会在后续每一步提供给你；开始新任务时会自动清空。\n"
    @"- 使用 Note 动作写入 Notes：覆盖写入（不是追加）；你可以自由重写/整理/压缩。\n"
    @"- Notes 适合记录：要填写到表格的文字、已收集列表、账号/链接、统计结果等。\n"
    @"- 批量写入/多条提交任务：请把 Notes 写成“账本（ledger）”，至少包含：目标条数、已确认写入（written）、待写入（pending）、最近一次可验证检查点（last_checkpoint）。\n"
    @"  - written 只包含你已经在屏幕上确认“提交/保存成功”的条目；不确定就先 verify，不要直接加入。\n"
    @"  - 写入前先查重：如果条目已在 written 中，必须跳过，不要重复写。\n"
    @"- 只有在确实需要更新记忆/结果时才使用 Note。\n"
    @"- 只记录你从屏幕上看到/确认的事实；不要编造。\n"
    @"\n";

  static NSString *const kOnDeviceAgentSystemPromptBulkWrite =
    @"【幂等批量写入｜Bulk Write】\n"
    @"当任务涉及“多条写入/多次提交/不可逆操作”（例如向表格逐条录入、批量发送/发布等）时，请遵守：\n"
    @"- Notes 请使用“账本（ledger）”格式，推荐包含：`target_count`、`written`、`pending`、`last_checkpoint`。\n"
    @"- `written` 只记录你已在屏幕上确认“提交/保存成功”的条目；不确定时先 verify（回列表/总览确认）。\n"
    @"- 写入前先查重：若条目已在 `written` 中，必须跳过；不要重复写入。\n"
    @"- 只有当 `written_count == target_count` 且完成一次可验证 checkpoint 后，才允许把“批量写入完成”对应的 plan 条目设为 `done=true`。\n"
    @"- Finish 前必须 verify：回到列表/总览/搜索等可验证页面，确认 `written` 中的条目确实可见。\n"
    @"\n";

  static NSString *const kOnDeviceAgentSystemPromptCoordinates =
    @"【坐标系｜Coordinates】\n"
    @"下面定义所有坐标与手势参数的统一约定。\n"
    @"- 坐标为相对坐标：左上角 (0,0)，右下角 (1000,1000)。\n"
    @"- Tap / Double Tap / Long Press：`action.params.element = [x,y]`\n"
    @"- Swipe：`action.params.start = [x1,y1]`，`action.params.end = [x2,y2]`\n"
    @"\n";

  static NSString *const kOnDeviceAgentSystemPromptActions =
    @"【动作列表｜Actions】\n"
    @"下面列出你可以输出的动作与参数示例（示例仅展示 `action` 字段；实际输出仍必须包含 `think` / `plan`）。\n"
    @"- Launch：启动/切换 App（优先使用）\n"
    @"  `{\"action\":{\"name\":\"Launch\",\"params\":{\"app\":\"某 app 名称\"}}}`\n"
    @"  或 `{\"action\":{\"name\":\"Launch\",\"params\":{\"bundle_id\":\"com.xingin.discover\"}}}`\n"
    @"\n"
    @"- Tap：点击\n"
    @"  `{\"action\":{\"name\":\"Tap\",\"params\":{\"element\":[x,y]}}}`\n"
    @"\n"
    @"- Double Tap：双击\n"
    @"  `{\"action\":{\"name\":\"Double Tap\",\"params\":{\"element\":[x,y]}}}`\n"
    @"\n"
    @"- Long Press：长按\n"
    @"  `{\"action\":{\"name\":\"Long Press\",\"params\":{\"element\":[x,y],\"seconds\":2}}}`\n"
    @"\n"
    @"- Type：向当前聚焦输入框输入文本（会自动清空原内容）\n"
    @"  `{\"action\":{\"name\":\"Type\",\"params\":{\"text\":\"一段文本\"}}}`\n"
    @"\n"
    @"- Swipe：滑动（如果滑动没生效，按下方“失败重试规则”立即重试一次）\n"
    @"  `{\"action\":{\"name\":\"Swipe\",\"params\":{\"start\":[x1,y1],\"end\":[x2,y2],\"seconds\":0.5}}}`\n"
    @"\n"
    @"- Back：返回/关闭（iOS 手势）\n"
    @"  `{\"action\":{\"name\":\"Back\",\"params\":{}}}`\n"
    @"\n"
    @"- Home：回到桌面\n"
    @"  `{\"action\":{\"name\":\"Home\",\"params\":{}}}`\n"
    @"\n"
    @"- Wait：等待页面稳定\n"
    @"  `{\"action\":{\"name\":\"Wait\",\"params\":{\"seconds\":1}}}`\n"
    @"\n"
    @"- Note：写入 Notes（覆盖）\n"
    @"  `{\"action\":{\"name\":\"Note\",\"params\":{\"message\":\"...\"}}}`\n"
    @"\n"
    @"- Finish：结束任务\n"
    @"  `{\"action\":{\"name\":\"Finish\",\"params\":{\"message\":\"...\"}}}`\n"
    @"\n";

  static NSString *const kOnDeviceAgentSystemPromptRetry =
    @"【失败重试规则｜Retry】\n"
    @"下面是常见“看起来没生效”的动作重试策略。\n"
    @"- 当 Swipe 没生效（例如页面没滚动/棋子没移动/没有触发切换）：立刻重试一次，把终点沿同方向延伸到 120% 距离（保持起点不变）。\n"
    @"- 当 Tap 没生效（例如按钮未响应/页面无变化）：先 Wait 0.5–1 秒，再 Tap 一次。\n"
    @"\n";

  static NSString *const kOnDeviceAgentSystemPromptPolicy =
    @"【行为规范｜Policy】\n"
    @"下面是安全与可信性的最低要求。\n"
    @"- 不要声称你已经“填写/发送/提交/记录”，除非你在屏幕上看到了结果。\n"
    @"- 当你认为“任务已完成”时：先做一次可验证检查（回到列表/总览/搜索结果确认结果可见），再 Finish。\n"
    @"- 遇到登录/验证码/权限弹窗等无法继续的情况：请用 Finish 说明需要用户协助，不要猜测性操作。\n"
    @"- 不要输出未在上面列出的 action。\n";

  static NSString *prompt = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    prompt = [@[
      kOnDeviceAgentSystemPromptPreamble,
      kOnDeviceAgentSystemPromptOutputFormat,
      kOnDeviceAgentSystemPromptPlan,
      kOnDeviceAgentSystemPromptNote,
      kOnDeviceAgentSystemPromptBulkWrite,
      kOnDeviceAgentSystemPromptCoordinates,
      kOnDeviceAgentSystemPromptActions,
      kOnDeviceAgentSystemPromptRetry,
      kOnDeviceAgentSystemPromptPolicy,
    ] componentsJoinedByString:@""];
  });
  return prompt;
}

static NSDictionary<NSString *, NSString *> *OnDeviceAgentAppBundleIdMap(void)
{
  static NSDictionary<NSString *, NSString *> *map = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    map = @{
      @"115": @"com.115.personal",
      @"58同城": @"com.taofang.iphone",
      @"App Store": @"com.apple.AppStore",
      @"Apple Store": @"com.apple.store.Jolly",
      @"CSDN": @"net.csdn.CsdnPlus",
      @"Dcard": @"com.dcard.app.Dcard",
      @"FaceTime": @"com.apple.facetime",
      @"Facebook": @"com.facebook.Facebook",
      @"Facetime": @"com.apple.facetime",
      @"Firefox": @"org.mozilla.ios.Firefox",
      @"Gmail": @"com.google.Gmail",
      @"Google Chrome": @"com.google.chrome.ios",
      @"Instagram": @"com.burbn.instagram",
      @"Keynote": @"com.apple.Keynote",
      @"Keynote 讲演": @"com.apple.Keynote",
      @"Line": @"jp.naver.line",
      @"Linkedin": @"com.linkedin.LinkedIn",
      @"Luckin Coffee": @"com.bjlc.luckycoffee",
      @"Messenger": @"com.facebook.Messenger",
      @"Netflix": @"com.netflix.Netflix",
      @"QQ": @"com.tencent.mqq",
      @"QQ 音乐": @"com.tencent.QQMusic",
      @"QQ浏览器": @"com.tencent.mttlite",
      @"QQ邮箱": @"com.tencent.qqmail",
      @"QQ阅读": @"com.tencent.qqreaderiphone",
      @"QQ音乐": @"com.tencent.QQMusic",
      @"Safari": @"com.apple.mobilesafari",
      @"Spotify": @"com.spotify.client",
      @"Starbucks": @"com.starbucks.mystarbucks",
      @"TIM": @"com.tencent.tim",
      @"TestFlight": @"com.apple.TestFlight",
      @"Tiktok": @"com.zhiliaoapp.musically",
      @"Twitter": @"com.atebits.Tweetie2",
      @"UC浏览器": @"com.ucweb.iphone.lowversion",
      @"Watch": @"com.apple.Bridge",
      @"WhatsApp": @"net.whatsapp.WhatsApp",
      @"Xmind": @"net.xmind.brownieapp",
      @"YY": @"yyvoice",
      @"Youtube": @"com.google.ios.youtube",
      @"iMovie": @"com.apple.iMovie",
      @"一淘": @"com.taobao.etaocoupon",
      @"中国银行": @"com.boc.BOCMBCI",
      @"书旗小说": @"com.shuqicenter.reader",
      @"云闪付": @"com.unionpay.chsp",
      @"京东": @"com.360buy.jdmobile",
      @"京东读书": @"com.jd.reader",
      @"亿通行": @"com.ruubypay.yitongxing",
      @"什么值得买": @"com.smzdm.client.ios",
      @"今日头条": @"com.ss.iphone.article.News",
      @"企业微信": @"com.tencent.ww",
      @"优酷": @"com.youku.YouKu",
      @"便利蜂": @"com.bianlifeng.customer.ios",
      @"信息": @"com.apple.MobileSMS",
      @"健康": @"com.apple.Health",
      @"全民k歌": @"com.tencent.QQKSong",
      @"印象笔记": @"com.yinxiang.iPhone",
      @"去哪儿旅行": @"com.qunar.iphoneclient8",
      @"口碑": @"com.taobao.kbmeishi",
      @"名片全能王": @"com.intsig.camcard.lite",
      @"哔哩哔哩": @"tv.danmaku.bilianime",
      @"唯品会": @"com.vipshop.iphone",
      @"唱吧": @"com.changba.ktv",
      @"喜马拉雅": @"com.gemd.iting",
      @"图书": @"com.apple.iBooks",
      @"土豆视频": @"com.tudou.tudouiphone",
      @"地图": @"com.apple.Maps",
      @"墨客": @"com.moke.moke.iphone",
      @"备忘录": @"com.apple.mobilenotes",
      @"多抓鱼": @"com.duozhuyu.dejavu",
      @"多点": @"com.dmall.dmall",
      @"大众点评": @"com.dianping.dpscope",
      @"大都会Metro": @"com.DDH.SHSubway",
      @"天气": @"com.apple.weather",
      @"天猫": @"com.taobao.tmall",
      @"家庭": @"com.apple.Home",
      @"小红书": @"com.xingin.discover",
      @"小鹅拼拼": @"com.tencent.dwdcoco",
      @"库乐队": @"com.apple.mobilegarageband",
      @"得到": @"com.luojilab.LuoJiFM-IOS",
      @"得物": @"com.siwuai.duapp",
      @"微信": @"com.tencent.xin",
      @"微信听书": @"com.tencent.wehear",
      @"微信读书": @"com.tencent.weread",
      @"微博": @"com.sina.weibo",
      @"微博国际": @"com.weibo.international",
      @"微博极速版": @"com.sina.weibolite",
      @"微视": @"com.tencent.microvision",
      @"快手": @"com.jiangjia.gif",
      @"快手极速版": @"com.kuaishou.nebula",
      @"快捷指令": @"com.apple.shortcuts",
      @"抖音": @"com.ss.iphone.ugc.Aweme",
      @"抖音极速版": @"com.ss.iphone.ugc.aweme.lite",
      @"抖音火山版": @"com.ss.iphone.ugc.Live",
      @"拼多多": @"com.xunmeng.pinduoduo",
      @"提醒事项": @"com.apple.reminders",
      @"搜狐新闻": @"com.sohu.newspaper",
      @"搜狐视频": @"com.sohu.iPhoneVideo",
      @"搜狗浏览器": @"com.sogou.SogouExplorerMobile",
      @"携程": @"ctrip.com",
      @"播客": @"com.apple.podcasts",
      @"支付宝": @"com.alipay.iphoneclient",
      @"文件": @"com.apple.DocumentsApp",
      @"斗鱼": @"tv.douyu.live",
      @"新闻": @"com.apple.news",
      @"日历": @"com.apple.mobilecal",
      @"时钟": @"com.apple.mobiletimer",
      @"有道云笔记": @"com.youdao.note.YoudaoNoteMac",
      @"查找": @"com.apple.findmy",
      @"欧陆词典": @"eusoft.eudic.pro",
      @"比心": @"com.yitan.bixin",
      @"淘宝": @"com.taobao.taobao4iphone",
      @"淘票票": @"com.taobao.movie.MoviePhoneClient",
      @"照片": @"com.apple.mobileslideshow",
      @"爱奇艺视频": @"com.qiyi.iphone",
      @"电话": @"com.apple.mobilephone",
      @"番茄小说": @"com.dragon.read",
      @"百度": @"com.baidu.BaiduMobile",
      @"百度地图": @"com.baidu.map",
      @"百度文库": @"com.baidu.Wenku",
      @"百度网盘": @"com.baidu.netdisk",
      @"百度翻译": @"com.baidu.translate",
      @"百度视频": @"com.baidu.videoiphone",
      @"百度贴吧": @"com.baidu.tieba",
      @"百度输入法": @"com.baidu.inputMethod",
      @"百度阅读": @"com.baidu.yuedu",
      @"皮皮虾": @"com.bd.iphone.super",
      @"相机": @"com.apple.camera",
      @"知乎": @"com.zhihu.ios",
      @"绿洲": @"com.sina.oasis",
      @"网易严选": @"com.netease.yanxuan",
      @"网易云音乐": @"com.netease.cloudmusic",
      @"网易公开课": @"com.netease.videoHD",
      @"网易新闻": @"com.netease.news",
      @"网易有道词典": @"youdaoPro",
      @"网易邮箱大师": @"com.netease.macmail",
      @"美团": @"com.meituan.imeituan",
      @"美团买菜": @"com.baobaoaichi.imaicai",
      @"美团众包": @"com.meituan.banma.crowdsource",
      @"美团优选": @"com.meituan.iyouxuan",
      @"美团优选团长": @"com.meituan.igrocery.gh",
      @"美团外卖": @"com.meituan.itakeaway",
      @"美团开店宝": @"com.meituan.imerchantbiz",
      @"美团拍店": @"com.meituan.pai",
      @"美团秀秀": @"com.meitu.mtxx",
      @"美团骑手": @"com.meituan.banma.homebrew",
      @"翻译": @"com.apple.Translate",
      @"股市": @"com.apple.stocks",
      @"腾讯体育": @"com.tencent.sportskbs",
      @"腾讯动漫": @"com.tencent.ied.app.comic",
      @"腾讯地图": @"com.tencent.sosomap",
      @"腾讯微云": @"com.tencent.weiyun",
      @"腾讯文档": @"com.tencent.txdocs",
      @"腾讯新闻": @"com.tencent.info",
      @"腾讯翻译君": @"com.tencent.qqtranslator",
      @"腾讯视频": @"com.tencent.live4iphone",
      @"腾讯课堂": @"com.tencent.edu",
      @"自如": @"com.ziroom.ZiroomProject",
      @"芒果TV": @"com.hunantv.imgotv",
      @"苏宁易购": @"SuningEMall",
      @"菜鸟裹裹": @"com.cainiao.cnwireless",
      @"虎牙": @"com.yy.kiwi",
      @"虾米音乐": @"com.xiami.spark",
      @"西瓜视频": @"com.ss.iphone.article.Video",
      @"视频": @"com.apple.tv",
      @"计算器": @"com.apple.calculator",
      @"设置": @"com.apple.Preferences",
      @"语音备忘录": @"com.apple.VoiceMemos",
      @"豆瓣": @"com.douban.frodo",
      @"起点读书": @"m.qidian.QDReaderAppStore",
      @"转转": @"com.wuba.zhuanzhuan",
      @"通讯录": @"com.apple.MobileAddressBook",
      @"邮件": @"com.apple.mobilemail",
      @"酷狗音乐": @"com.kugou.kugou1002",
      @"钉钉": @"com.laiwang.DingTalk",
      @"钱包": @"com.apple.Passbook",
      @"闲鱼": @"com.taobao.fleamarket",
      @"闹钟": @"com.apple.mobiletimer",
      @"陌陌": @"com.wemomo.momoappdemo1",
      @"音乐": @"com.apple.Music",
      @"飞书": @"com.bytedance.ee.lark",
      @"飞猪": @"com.taobao.travel",
      @"饿了么": @"me.ele.ios.eleme",
      @"高德地图": @"com.autonavi.amap",

      // Common aliases
      @"xhs": @"com.xingin.discover",
      @"xiaohongshu": @"com.xingin.discover",
      @"feishu": @"com.bytedance.ee.lark",
      @"lark": @"com.bytedance.ee.lark",
    };
  });
  return map;
}

static NSString *OnDeviceAgentExplainRecoverableActionError(NSString *kind, NSDictionary *action, NSError *error)
{
  NSString *k = OnDeviceAgentTrim(kind ?: @"");
  NSString *errMsg = OnDeviceAgentTrim(error.localizedDescription ?: @"");
  if ([k isEqualToString:kOnDeviceAgentErrorKindLaunchNotInMap]) {
    NSDictionary *actionObj = [action[@"action"] isKindOfClass:NSDictionary.class] ? (NSDictionary *)action[@"action"] : @{};
    NSDictionary *params = [actionObj[@"params"] isKindOfClass:NSDictionary.class] ? (NSDictionary *)actionObj[@"params"] : @{};
    NSString *appName = OnDeviceAgentTrim(OnDeviceAgentStringOrEmpty(params[@"app"]));
    if (appName.length == 0) {
      appName = @"(unknown)";
    }
    return [NSString stringWithFormat:
      @"Launch(app=\"%@\") 失败：该 App 不在内置映射里，无法通过 Launch 直接打开。\n"
      @"不要再尝试 Launch。请改用系统 UI 搜索打开：Home → Spotlight（桌面下滑）/App 资源库 → 点搜索框 → Type 输入 App 名 → Tap 搜索结果打开。",
      appName];
  }
  if ([k isEqualToString:kOnDeviceAgentErrorKindInvalidParams]) {
    NSDictionary *actionObj = [action[@"action"] isKindOfClass:NSDictionary.class] ? (NSDictionary *)action[@"action"] : @{};
    NSString *name = [actionObj[@"name"] isKindOfClass:NSString.class] ? OnDeviceAgentNormalizeActionName((NSString *)actionObj[@"name"]) : @"";
    NSDictionary *params = [actionObj[@"params"] isKindOfClass:NSDictionary.class] ? (NSDictionary *)actionObj[@"params"] : @{};
    if ([name isEqualToString:@"launch"]) {
      NSString *bundleId = nil;
      if ([params[@"bundle_id"] isKindOfClass:NSString.class]) {
        bundleId = params[@"bundle_id"];
      } else if ([params[@"bundleId"] isKindOfClass:NSString.class]) {
        bundleId = params[@"bundleId"];
      } else if ([params[@"bundleID"] isKindOfClass:NSString.class]) {
        bundleId = params[@"bundleID"];
      }
      bundleId = OnDeviceAgentTrim(bundleId ?: @"");
      if (bundleId.length > 0) {
        if (errMsg.length == 0) {
          errMsg = @"参数不合法";
        }
        return [NSString stringWithFormat:
          @"Launch(bundle_id=\"%@\") 失败：系统找不到该 bundle_id（可能未安装或 bundle_id 错误）。\n"
          @"不要猜 bundle_id。请改用 Launch(app=\"应用名\")，或用系统 UI 搜索打开：Home → Spotlight（桌面下滑）/App 资源库 → 点搜索框 → Type 输入 App 名 → Tap 搜索结果打开。\n"
          @"原始错误：%@",
          bundleId, errMsg];
      }
    }
    if (errMsg.length == 0) {
      errMsg = @"参数不合法";
    }
    return [NSString stringWithFormat:
      @"%@\n"
      @"请修正 action.params 中的参数（坐标为 0..1000 相对坐标；字段名按 schema），然后继续下一步。",
      errMsg];
  }
  return errMsg.length > 0 ? errMsg : @"Action failed";
}

static NSDictionary<NSString *, NSString *> *OnDeviceAgentAppBundleIdMapLower(void)
{
  static NSDictionary<NSString *, NSString *> *map = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    NSDictionary<NSString *, NSString *> *base = OnDeviceAgentAppBundleIdMap();
    NSMutableDictionary<NSString *, NSString *> *m = [NSMutableDictionary dictionaryWithCapacity:base.count];
    for (NSString *key in base) {
      NSString *value = base[key];
      if (![key isKindOfClass:NSString.class] || ![value isKindOfClass:NSString.class]) {
        continue;
      }
      m[[key lowercaseString]] = value;
    }
    map = [m copy];
  });
  return map;
}

static NSString *OnDeviceAgentBundleIdForAppName(NSString *appName)
{
  NSString *name = OnDeviceAgentTrim(appName ?: @"");
  if (name.length == 0) {
    return nil;
  }
  NSString *bundleId = OnDeviceAgentAppBundleIdMap()[name];
  if (bundleId.length > 0) {
    return bundleId;
  }
  bundleId = OnDeviceAgentAppBundleIdMapLower()[[name lowercaseString]];
  if (bundleId.length > 0) {
    return bundleId;
  }
  return nil;
}

static NSDictionary<NSString *, NSString *> *OnDeviceAgentBundleIdToNameMap(void)
{
  static NSDictionary<NSString *, NSString *> *map = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    NSDictionary<NSString *, NSString *> *forward = OnDeviceAgentAppBundleIdMap();
    NSMutableDictionary<NSString *, NSString *> *m = [NSMutableDictionary dictionaryWithCapacity:forward.count];
    for (NSString *name in forward) {
      NSString *bundleId = forward[name];
      if (![name isKindOfClass:NSString.class] || ![bundleId isKindOfClass:NSString.class]) {
        continue;
      }
      // Prefer the first name we see for a given bundle id.
      if (m[bundleId] == nil) {
        m[bundleId] = name;
      }
    }
    map = [m copy];
  });
  return map;
}

static NSString *OnDeviceAgentAppNameForBundleId(NSString *bundleId)
{
  NSString *bid = OnDeviceAgentTrim(bundleId ?: @"");
  if (bid.length == 0) {
    return nil;
  }
  NSString *name = OnDeviceAgentBundleIdToNameMap()[bid];
  return name.length > 0 ? name : nil;
}

static BOOL OnDeviceAgentWaitForActiveBundleId(NSString *bundleId, NSTimeInterval timeoutSeconds)
{
  NSString *targetId = OnDeviceAgentTrim(bundleId ?: @"");
  if (targetId.length == 0) {
    return NO;
  }

  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:MAX(0.0, timeoutSeconds)];
  XCUIApplication *target = [[XCUIApplication alloc] initWithBundleIdentifier:targetId];
  while ([deadline timeIntervalSinceNow] > 0) {
    XCUIApplication *active = XCUIApplication.fb_activeApplication;
    if ([active fb_isSameAppAs:target]) {
      return YES;
    }
    [NSThread sleepForTimeInterval:0.2];
  }
  return NO;
}

static NSString *OnDeviceAgentKeychainService(void)
{
  NSString *bundleId = NSBundle.mainBundle.bundleIdentifier ?: @"com.facebook.WebDriverAgentRunner";
  return [bundleId stringByAppendingString:kOnDeviceAgentKeychainServiceSuffix];
}

static NSString *OnDeviceAgentKeychainGet(NSString *service, NSString *account)
{
  if (service.length == 0 || account.length == 0) {
    return @"";
  }
  NSDictionary *query = @{
    (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
    (__bridge id)kSecAttrService: service,
    (__bridge id)kSecAttrAccount: account,
    (__bridge id)kSecReturnData: @YES,
    (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne,
  };
  CFTypeRef item = NULL;
  OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &item);
  if (status != errSecSuccess || item == NULL) {
    return @"";
  }
  NSData *data = CFBridgingRelease(item);
  if (![data isKindOfClass:NSData.class] || data.length == 0) {
    return @"";
  }
  NSString *value = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  return value ?: @"";
}

static BOOL OnDeviceAgentKeychainSet(NSString *service, NSString *account, NSString *value)
{
  if (service.length == 0 || account.length == 0) {
    return NO;
  }
  NSString *normalized = OnDeviceAgentStringOrEmpty(value);
  NSData *valueData = [normalized dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
  NSDictionary *query = @{
    (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
    (__bridge id)kSecAttrService: service,
    (__bridge id)kSecAttrAccount: account,
  };
  NSDictionary *attrs = @{
    (__bridge id)kSecValueData: valueData,
    (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
  };
  OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)attrs);
  if (status == errSecItemNotFound) {
    NSMutableDictionary *insert = [query mutableCopy];
    [insert addEntriesFromDictionary:attrs];
    status = SecItemAdd((__bridge CFDictionaryRef)insert, NULL);
  }
  return status == errSecSuccess;
}

static BOOL OnDeviceAgentKeychainDelete(NSString *service, NSString *account)
{
  if (service.length == 0 || account.length == 0) {
    return NO;
  }
  NSDictionary *query = @{
    (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
    (__bridge id)kSecAttrService: service,
    (__bridge id)kSecAttrAccount: account,
  };
  OSStatus status = SecItemDelete((__bridge CFDictionaryRef)query);
  return status == errSecSuccess || status == errSecItemNotFound;
}

@interface OnDeviceAgentTextPayload : NSObject <FBResponsePayload>
@property (nonatomic, copy) NSString *text;
@property (nonatomic, copy) NSString *contentType;
@property (nonatomic, assign) NSInteger statusCode;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *headers;
@end

@implementation OnDeviceAgentTextPayload

- (instancetype)initWithText:(NSString *)text contentType:(NSString *)contentType statusCode:(NSInteger)statusCode
{
  self = [super init];
  if (self) {
    _text = [text copy] ?: @"";
    _contentType = [contentType copy] ?: @"text/plain;charset=UTF-8";
    _statusCode = statusCode;
    _headers = @{};
  }
  return self;
}

- (instancetype)initWithText:(NSString *)text
                 contentType:(NSString *)contentType
                  statusCode:(NSInteger)statusCode
                     headers:(NSDictionary<NSString *, NSString *> *)headers
{
  self = [self initWithText:text contentType:contentType statusCode:statusCode];
  if (self) {
    _headers = [headers isKindOfClass:NSDictionary.class] ? [headers copy] : @{};
  }
  return self;
}

- (void)dispatchWithResponse:(RouteResponse *)response
{
  [response setHeader:@"Content-Type" value:self.contentType];
  for (NSString *k in self.headers) {
    NSString *v = self.headers[k];
    if (k.length == 0 || v.length == 0) {
      continue;
    }
    [response setHeader:k value:v];
  }
  [response setStatusCode:self.statusCode];
  [response respondWithString:self.text encoding:NSUTF8StringEncoding];
}

@end

@interface OnDeviceAgentJSONPayload : NSObject <FBResponsePayload>
@property (nonatomic, copy) NSDictionary *object;
@property (nonatomic, assign) NSInteger statusCode;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *headers;
@end

@implementation OnDeviceAgentJSONPayload

- (instancetype)initWithObject:(NSDictionary *)object statusCode:(NSInteger)statusCode
{
  self = [super init];
  if (self) {
    _object = [object isKindOfClass:NSDictionary.class] ? [object copy] : @{};
    _statusCode = statusCode;
    _headers = @{};
  }
  return self;
}

- (instancetype)initWithObject:(NSDictionary *)object statusCode:(NSInteger)statusCode headers:(NSDictionary<NSString *, NSString *> *)headers
{
  self = [self initWithObject:object statusCode:statusCode];
  if (self) {
    _headers = [headers isKindOfClass:NSDictionary.class] ? [headers copy] : @{};
  }
  return self;
}

- (void)dispatchWithResponse:(RouteResponse *)response
{
  [response setHeader:@"Content-Type" value:@"application/json;charset=UTF-8"];
  for (NSString *k in self.headers) {
    NSString *v = self.headers[k];
    if (k.length == 0 || v.length == 0) {
      continue;
    }
    [response setHeader:k value:v];
  }
  [response setStatusCode:self.statusCode];
  NSError *error = nil;
  NSData *data = [NSJSONSerialization dataWithJSONObject:self.object options:0 error:&error];
  if (data.length == 0 || error != nil) {
    [response respondWithString:@"{}" encoding:NSUTF8StringEncoding];
    return;
  }
  NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  [response respondWithString:text ?: @"{}" encoding:NSUTF8StringEncoding];
}

@end

// MARK: - SSE (Console push updates)

@interface OnDeviceAgentEventStreamResponse : NSObject <HTTPResponse>
- (instancetype)initWithConnection:(HTTPConnection *)connection;
- (void)sendEvent:(NSString *)event data:(NSString *)data;
@end

@interface OnDeviceAgentEventHub : NSObject
+ (instancetype)shared;
- (void)addClient:(OnDeviceAgentEventStreamResponse *)client;
- (void)removeClient:(OnDeviceAgentEventStreamResponse *)client;
- (void)broadcastEvent:(NSString *)event data:(NSString *)data;
- (void)broadcastJSONObject:(id)obj event:(NSString *)event;
@end

@implementation OnDeviceAgentEventStreamResponse {
  __weak HTTPConnection *_connection;
  dispatch_queue_t _queue;
  NSMutableData *_buffer;
  BOOL _done;
  UInt64 _offset;
}

- (instancetype)initWithConnection:(HTTPConnection *)connection
{
  self = [super init];
  if (self) {
    _connection = connection;
    _queue = dispatch_queue_create("ondevice_agent.sse.client", DISPATCH_QUEUE_SERIAL);
    _buffer = [NSMutableData data];
    _done = NO;
    _offset = 0;
  }
  return self;
}

- (UInt64)contentLength
{
  return 0;
}

- (UInt64)offset
{
  return _offset;
}

- (void)setOffset:(UInt64)offset
{
  _offset = offset;
}

- (NSData *)readDataOfLength:(NSUInteger)length
{
  __block NSData *out = nil;
  dispatch_sync(_queue, ^{
    if (_buffer.length == 0) {
      out = nil;
      return;
    }
    NSUInteger n = MIN(length, _buffer.length);
    out = [_buffer subdataWithRange:NSMakeRange(0, n)];
    [_buffer replaceBytesInRange:NSMakeRange(0, n) withBytes:NULL length:0];
  });
  return out;
}

- (BOOL)isDone
{
  return _done;
}

- (BOOL)isChunked
{
  return YES;
}

- (void)connectionDidClose
{
  _done = YES;
  _connection = nil;
  [[OnDeviceAgentEventHub shared] removeClient:self];
}

- (void)enqueueData:(NSData *)data
{
  if (data.length == 0 || _done) {
    return;
  }
  dispatch_async(_queue, ^{
    if (self->_done) {
      return;
    }
    [self->_buffer appendData:data];
    HTTPConnection *c = self->_connection;
    if (c != nil) {
      [c responseHasAvailableData:self];
    }
  });
}

- (void)sendEvent:(NSString *)event data:(NSString *)data
{
  NSString *e = OnDeviceAgentTrim(event ?: @"");
  if (e.length == 0) {
    e = @"message";
  }
  NSString *payload = data ?: @"";
  NSMutableString *s = [NSMutableString string];
  [s appendFormat:@"event: %@\n", e];
  for (NSString *line in [payload componentsSeparatedByString:@"\n"]) {
    [s appendFormat:@"data: %@\n", line ?: @""];
  }
  [s appendString:@"\n"];
  NSData *bytes = [s dataUsingEncoding:NSUTF8StringEncoding];
  [self enqueueData:bytes ?: [NSData data]];
}

@end

@implementation OnDeviceAgentEventHub {
  dispatch_queue_t _queue;
  NSHashTable<OnDeviceAgentEventStreamResponse *> *_clients;
  dispatch_source_t _pingTimer;
}

+ (instancetype)shared
{
  static OnDeviceAgentEventHub *inst = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    inst = [OnDeviceAgentEventHub new];
  });
  return inst;
}

- (instancetype)init
{
  self = [super init];
  if (self) {
    _queue = dispatch_queue_create("ondevice_agent.sse.hub", DISPATCH_QUEUE_SERIAL);
    _clients = [NSHashTable weakObjectsHashTable];
    _pingTimer = nil;
  }
  return self;
}

- (void)ensurePingTimerLocked
{
  if (_pingTimer != nil) {
    return;
  }
  _pingTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
  dispatch_source_set_timer(_pingTimer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)), (uint64_t)(15 * NSEC_PER_SEC), (uint64_t)(1 * NSEC_PER_SEC));
  __weak __typeof(self) weakSelf = self;
  dispatch_source_set_event_handler(_pingTimer, ^{
    __strong __typeof(weakSelf) strongSelf = weakSelf;
    if (strongSelf == nil) {
      return;
    }
    [strongSelf broadcastEvent:@"ping" data:OnDeviceAgentNowString()];
  });
  dispatch_resume(_pingTimer);
}

- (void)teardownPingTimerLockedIfUnused
{
  if (_pingTimer == nil) {
    return;
  }
  if (_clients.allObjects.count > 0) {
    return;
  }
  dispatch_source_cancel(_pingTimer);
  _pingTimer = nil;
}

- (void)addClient:(OnDeviceAgentEventStreamResponse *)client
{
  if (client == nil) {
    return;
  }
  dispatch_async(_queue, ^{
    [self->_clients addObject:client];
    [self ensurePingTimerLocked];
  });
}

- (void)removeClient:(OnDeviceAgentEventStreamResponse *)client
{
  if (client == nil) {
    return;
  }
  dispatch_async(_queue, ^{
    [self->_clients removeObject:client];
    [self teardownPingTimerLockedIfUnused];
  });
}

- (void)broadcastEvent:(NSString *)event data:(NSString *)data
{
  NSString *e = OnDeviceAgentTrim(event ?: @"");
  NSString *d = data ?: @"";
  if (e.length == 0) {
    return;
  }
  dispatch_async(_queue, ^{
    for (OnDeviceAgentEventStreamResponse *c in self->_clients.allObjects) {
      [c sendEvent:e data:d];
    }
  });
}

- (void)broadcastJSONObject:(id)obj event:(NSString *)event
{
  NSString *json = OnDeviceAgentJSONStringFromObject(obj);
  [self broadcastEvent:event data:json];
}

@end

@interface OnDeviceAgentEventStreamPayload : NSObject <FBResponsePayload>
@property (nonatomic, assign) BOOL includeDefaultSystemPrompt;
- (instancetype)initWithIncludeDefaultSystemPrompt:(BOOL)includeDefaultSystemPrompt;
@end

@implementation OnDeviceAgentEventStreamPayload

- (instancetype)initWithIncludeDefaultSystemPrompt:(BOOL)includeDefaultSystemPrompt
{
  self = [super init];
  if (self) {
    _includeDefaultSystemPrompt = includeDefaultSystemPrompt;
  }
  return self;
}

- (void)dispatchWithResponse:(RouteResponse *)response
{
  OnDeviceAgentEventStreamResponse *stream = [[OnDeviceAgentEventStreamResponse alloc] initWithConnection:response.connection];
  [[OnDeviceAgentEventHub shared] addClient:stream];

  [response setHeader:@"Content-Type" value:@"text/event-stream;charset=UTF-8"];
  [response setHeader:@"Cache-Control" value:@"no-cache"];
  [response setHeader:@"X-Accel-Buffering" value:@"no"];
  [response setStatusCode:kHTTPStatusCodeOK];
  response.response = stream;

  NSDictionary *snapshot = @{
    @"status": [[OnDeviceAgentManager shared] statusWithDefaultSystemPrompt:self.includeDefaultSystemPrompt],
    @"logs": [[OnDeviceAgentManager shared] logs],
    @"chat": [[OnDeviceAgentManager shared] chat],
  };
  [stream sendEvent:@"snapshot" data:OnDeviceAgentJSONStringFromObject(snapshot)];
}

@end

static NSString *OnDeviceAgentHeaderValueCaseInsensitive(FBRouteRequest *request, NSString *fieldName)
{
  NSDictionary *headers = [request.headers isKindOfClass:NSDictionary.class] ? request.headers : @{};
  if (headers.count == 0) {
    return @"";
  }
  NSString *needle = OnDeviceAgentTrim(fieldName).lowercaseString;
  if (needle.length == 0) {
    return @"";
  }
  for (id key in headers) {
    if (![key isKindOfClass:NSString.class]) {
      continue;
    }
    NSString *name = [((NSString *)key) lowercaseString];
    if (![name isEqualToString:needle]) {
      continue;
    }
    id value = headers[key];
    if ([value isKindOfClass:NSString.class]) {
      return OnDeviceAgentTrim((NSString *)value);
    }
    if ([value isKindOfClass:NSArray.class]) {
      id first = [((NSArray *)value) firstObject];
      if ([first isKindOfClass:NSString.class]) {
        return OnDeviceAgentTrim((NSString *)first);
      }
    }
  }
  return @"";
}

static BOOL OnDeviceAgentIsLoopbackHost(NSString *host)
{
  NSString *h = OnDeviceAgentTrim(host).lowercaseString;
  NSRange zoneSep = [h rangeOfString:@"%"];
  if (zoneSep.location != NSNotFound) {
    h = [h substringToIndex:zoneSep.location];
  }
  if ([h hasPrefix:@"::ffff:"]) {
    h = [h substringFromIndex:@"::ffff:".length];
  }
  if (h.length == 0) {
    return NO;
  }
  if ([h isEqualToString:@"localhost"] || [h isEqualToString:@"127.0.0.1"] || [h isEqualToString:@"::1"] || [h isEqualToString:@"0:0:0:0:0:0:0:1"]) {
    return YES;
  }
  return NO;
}

static BOOL OnDeviceAgentIsLocalhostRequest(FBRouteRequest *request)
{
  // IMPORTANT: do NOT trust the client-controlled "Host" header here.
  // We need to know whether the TCP peer is loopback (127.0.0.1 / ::1).
  NSString *peer = OnDeviceAgentTrim(request.peerIP ?: @"");
  if (peer.length == 0) {
    // Fail closed: if we cannot determine the real peer, require Agent Token.
    return NO;
  }
  return OnDeviceAgentIsLoopbackHost(peer);
}

static NSString *OnDeviceAgentQueryValueCaseInsensitive(NSURL *url, NSString *name)
{
  NSString *needle = OnDeviceAgentTrim(name).lowercaseString;
  if (needle.length == 0 || url == nil) {
    return @"";
  }
  NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
  for (NSURLQueryItem *item in components.queryItems ?: @[]) {
    NSString *itemName = OnDeviceAgentTrim(OnDeviceAgentStringOrEmpty(item.name)).lowercaseString;
    if (![itemName isEqualToString:needle]) {
      continue;
    }
    NSString *v = OnDeviceAgentTrim(OnDeviceAgentStringOrEmpty(item.value));
    if (v.length > 0) {
      return v;
    }
  }
  return @"";
}

static NSString *OnDeviceAgentCookieValueCaseInsensitive(FBRouteRequest *request, NSString *cookieName)
{
  NSString *needle = OnDeviceAgentTrim(cookieName).lowercaseString;
  if (needle.length == 0) {
    return @"";
  }
  NSString *cookieHeader = OnDeviceAgentHeaderValueCaseInsensitive(request, @"Cookie");
  if (cookieHeader.length == 0) {
    return @"";
  }
  NSArray<NSString *> *items = [cookieHeader componentsSeparatedByString:@";"];
  for (NSString *rawItem in items) {
    NSString *item = OnDeviceAgentTrim(rawItem);
    if (item.length == 0) {
      continue;
    }
    NSRange eq = [item rangeOfString:@"="];
    if (eq.location == NSNotFound) {
      continue;
    }
    NSString *name = OnDeviceAgentTrim([item substringToIndex:eq.location]).lowercaseString;
    if (![name isEqualToString:needle]) {
      continue;
    }
    NSString *rawValue = OnDeviceAgentTrim([item substringFromIndex:eq.location + 1]);
    if (rawValue.length == 0) {
      continue;
    }
    NSString *decoded = [rawValue stringByRemovingPercentEncoding];
    NSString *token = OnDeviceAgentTrim(decoded ?: rawValue);
    if (token.length > 0) {
      return token;
    }
  }
  return @"";
}

static NSString *OnDeviceAgentAgentTokenCookieHeaderValue(NSString *token)
{
  NSString *t = OnDeviceAgentTrim(token ?: @"");
  if (t.length == 0) {
    return @"";
  }
  NSString *encoded = [t stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
  if (encoded.length == 0) {
    encoded = t;
  }
  // Session cookie (no Expires/Max-Age). HttpOnly prevents JS access; SameSite=Strict reduces cross-site leakage.
  return [NSString stringWithFormat:@"%@=%@; Path=/agent; SameSite=Strict; HttpOnly", kOnDeviceAgentAgentTokenCookieName, encoded];
}

static NSString *OnDeviceAgentGenerateAgentToken(void)
{
  uint8_t bytes[16] = {0};
  OSStatus rc = SecRandomCopyBytes(kSecRandomDefault, sizeof(bytes), bytes);
  if (rc != errSecSuccess) {
    NSString *uuid = [[NSUUID UUID].UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""];
    return OnDeviceAgentTrim(uuid ?: @"");
  }

  NSMutableString *hex = [NSMutableString stringWithCapacity:32];
  for (NSInteger i = 0; i < 16; i++) {
    [hex appendFormat:@"%02x", bytes[i]];
  }
  return hex.copy;
}

typedef NS_OPTIONS(NSUInteger, OnDeviceAgentTokenSources) {
  OnDeviceAgentTokenSourceHeader = 1 << 0,
  OnDeviceAgentTokenSourceQuery = 1 << 1,
  OnDeviceAgentTokenSourceCookie = 1 << 2,
};

static NSString *OnDeviceAgentAgentTokenFromRequest(FBRouteRequest *request, OnDeviceAgentTokenSources sources)
{
  if ((sources & OnDeviceAgentTokenSourceHeader) != 0) {
    NSString *headerToken = OnDeviceAgentHeaderValueCaseInsensitive(request, kOnDeviceAgentAgentTokenHeader);
    if (headerToken.length > 0) {
      return headerToken;
    }
  }
  if ((sources & OnDeviceAgentTokenSourceQuery) != 0) {
    NSString *queryToken = OnDeviceAgentQueryValueCaseInsensitive(request.URL, kOnDeviceAgentAgentTokenQueryParam);
    if (queryToken.length > 0) {
      return queryToken;
    }
  }
  if ((sources & OnDeviceAgentTokenSourceCookie) != 0) {
    NSString *cookieToken = OnDeviceAgentCookieValueCaseInsensitive(request, kOnDeviceAgentAgentTokenCookieName);
    if (cookieToken.length > 0) {
      return cookieToken;
    }
  }
  return @"";
}

static id<FBResponsePayload> OnDeviceAgentUnauthorizedPayload(NSString *message)
{
  NSString *err = OnDeviceAgentTrim(message);
  if (err.length == 0) {
    err = @"Unauthorized";
  }
  NSDictionary *obj = @{
    @"ok": @NO,
    @"error": err,
  };
  return [[OnDeviceAgentJSONPayload alloc] initWithObject:obj statusCode:kHTTPStatusCodeUnauthorized];
}

static id<FBResponsePayload> OnDeviceAgentBadRequestPayload(NSString *message)
{
  NSString *err = OnDeviceAgentTrim(message);
  if (err.length == 0) {
    err = @"Bad request";
  }
  NSDictionary *obj = @{
    @"ok": @NO,
    @"error": err,
  };
  return [[OnDeviceAgentJSONPayload alloc] initWithObject:obj statusCode:kHTTPStatusCodeBadRequest];
}

static BOOL OnDeviceAgentAuthorizeAgentRouteWithSources(FBRouteRequest *request, OnDeviceAgentTokenSources tokenSources, NSString **outMessage)
{
  if (OnDeviceAgentIsLocalhostRequest(request)) {
    return YES;
  }
  NSString *expected = [[OnDeviceAgentManager shared] agentToken];
  if (expected.length == 0) {
    if (outMessage) {
      *outMessage = @"LAN access denied. Set Agent Token in Console first.";
    }
    return NO;
  }
  NSString *provided = OnDeviceAgentAgentTokenFromRequest(request, tokenSources);
  if (provided.length == 0 || ![provided isEqualToString:expected]) {
    if (outMessage) {
      *outMessage = @"Unauthorized: invalid or missing Agent Token.";
    }
    return NO;
  }
  return YES;
}

static BOOL OnDeviceAgentAuthorizeAgentRoute(FBRouteRequest *request, NSString **outMessage)
{
  // Accept both explicit header token (Console/tools) and HttpOnly cookie token (Runner web UI).
  return OnDeviceAgentAuthorizeAgentRouteWithSources(
    request,
    OnDeviceAgentTokenSourceHeader | OnDeviceAgentTokenSourceCookie,
    outMessage
  );
}

static BOOL OnDeviceAgentAuthorizeAgentPageRoute(FBRouteRequest *request, NSString **outMessage)
{
  return OnDeviceAgentAuthorizeAgentRouteWithSources(
    request,
    OnDeviceAgentTokenSourceHeader | OnDeviceAgentTokenSourceQuery | OnDeviceAgentTokenSourceCookie,
    outMessage
  );
}

typedef void (^OnDeviceAgentLogBlock)(NSString *line);
typedef void (^OnDeviceAgentChatBlock)(NSDictionary *item);
typedef void (^OnDeviceAgentFinishBlock)(BOOL success, NSString *message);
typedef void (^OnDeviceAgentScreenshotBlock)(NSInteger step, NSData *png);

@interface OnDeviceAgent : NSObject <NSURLSessionDelegate>
@property (atomic, assign) BOOL stopRequested;
@property (nonatomic, copy) NSDictionary *config;
@property (nonatomic, copy) OnDeviceAgentLogBlock log;
@property (nonatomic, copy) OnDeviceAgentChatBlock chat;
@property (nonatomic, copy) OnDeviceAgentFinishBlock finish;
@property (nonatomic, copy) OnDeviceAgentScreenshotBlock screenshot;
@property (nonatomic, strong) NSURLSession *session;
@property (atomic, strong) NSURLSessionTask *inflightTask;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *context;
@property (nonatomic, copy) NSString *previousResponseId;
@property (nonatomic, copy) NSArray<NSDictionary *> *planChecklist;
@property (atomic, copy) NSString *workingNote;
@property (atomic, copy) NSString *pendingRestartHintText;

@property (atomic, assign) long long usageRequests;
@property (atomic, assign) long long usageInputTokens;
@property (atomic, assign) long long usageOutputTokens;
@property (atomic, assign) long long usageCachedTokens;
@property (atomic, assign) long long usageTotalTokens;
@end

static NSString *OnDeviceAgentNormalizePlanItemTextKey(NSString *text)
{
  NSString *raw = OnDeviceAgentTrim(text ?: @"").lowercaseString;
  if (raw.length == 0) {
    return @"";
  }

  NSMutableString *buf = [NSMutableString stringWithCapacity:raw.length];
  NSCharacterSet *letters = NSCharacterSet.letterCharacterSet;
  NSCharacterSet *digits = NSCharacterSet.decimalDigitCharacterSet;

  for (NSUInteger i = 0; i < raw.length; i++) {
    unichar ch = [raw characterAtIndex:i];
    if ([letters characterIsMember:ch] || [digits characterIsMember:ch]) {
      [buf appendFormat:@"%C", ch];
    }
  }
  return buf.copy;
}

static NSString *OnDeviceAgentGeneratePlanItemId(void)
{
  NSString *uuid = [[NSUUID UUID].UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""];
  uuid = OnDeviceAgentTrim(uuid ?: @"");
  if (uuid.length >= 12) {
    return [uuid substringToIndex:12];
  }
  return uuid.length > 0 ? uuid : @"plan";
}

@implementation OnDeviceAgent

- (instancetype)initWithConfig:(NSDictionary *)config log:(OnDeviceAgentLogBlock)log chat:(OnDeviceAgentChatBlock)chat screenshot:(OnDeviceAgentScreenshotBlock)screenshot finish:(OnDeviceAgentFinishBlock)finish
{
  self = [super init];
  if (!self) {
    return nil;
  }
  _config = [config copy] ?: @{};
  _log = [log copy];
  _chat = [chat copy];
  _screenshot = [screenshot copy];
  _finish = [finish copy];
  _stopRequested = NO;
  _planChecklist = @[];
  _workingNote = @"";
  _pendingRestartHintText = @"";

  NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
  cfg.timeoutIntervalForRequest = OnDeviceAgentParseDouble(config[kOnDeviceAgentTimeoutSecondsKey], kOnDeviceAgentDefaultTimeoutSeconds);
  cfg.timeoutIntervalForResource = OnDeviceAgentParseDouble(config[kOnDeviceAgentTimeoutSecondsKey], kOnDeviceAgentDefaultTimeoutSeconds);
  _session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];
  _context = [NSMutableArray array];
  _previousResponseId = @"";

  return self;
}

- (NSString *)firstNewlyCompletedPlanItemTextFromOldPlan:(NSArray<NSDictionary *> *)oldPlan newPlan:(NSArray<NSDictionary *> *)newPlan
{
  if (oldPlan.count == 0 || newPlan.count == 0) {
    return @"";
  }

  // Prefer id-based matching, then normalized-text matching.
  NSMutableDictionary<NSString *, NSNumber *> *oldDoneById = [NSMutableDictionary dictionary];
  NSMutableDictionary<NSString *, NSNumber *> *oldDoneByKey = [NSMutableDictionary dictionary];
  for (id item in oldPlan) {
    if (![item isKindOfClass:NSDictionary.class]) {
      continue;
    }
    NSDictionary *d = (NSDictionary *)item;
    NSString *pid = OnDeviceAgentTrim(OnDeviceAgentStringOrEmpty(d[@"id"]));
    NSString *text = OnDeviceAgentTrim(OnDeviceAgentStringOrEmpty(d[@"text"]));
    BOOL done = OnDeviceAgentParseBool(d[@"done"], NO);
    if (pid.length > 0) {
      oldDoneById[pid] = @(done);
    }
    NSString *key = OnDeviceAgentNormalizePlanItemTextKey(text);
    if (key.length > 0 && oldDoneByKey[key] == nil) {
      oldDoneByKey[key] = @(done);
    }
  }

  for (id item in newPlan) {
    if (![item isKindOfClass:NSDictionary.class]) {
      continue;
    }
    NSDictionary *d = (NSDictionary *)item;
    BOOL newDone = OnDeviceAgentParseBool(d[@"done"], NO);
    if (!newDone) {
      continue;
    }
    NSString *pid = OnDeviceAgentTrim(OnDeviceAgentStringOrEmpty(d[@"id"]));
    NSString *text = OnDeviceAgentTrim(OnDeviceAgentStringOrEmpty(d[@"text"]));
    BOOL oldDone = NO;
    if (pid.length > 0 && oldDoneById[pid] != nil) {
      oldDone = OnDeviceAgentParseBool(oldDoneById[pid], NO);
    } else {
      NSString *key = OnDeviceAgentNormalizePlanItemTextKey(text);
      if (key.length > 0 && oldDoneByKey[key] != nil) {
        oldDone = OnDeviceAgentParseBool(oldDoneByKey[key], NO);
      }
    }
    if (!oldDone && text.length > 0) {
      return text;
    }
  }
  return @"";
}

- (void)emit:(NSString *)line
{
  if (!self.log) {
    return;
  }
  NSString *l = line ?: @"";
  NSString *trimmed = OnDeviceAgentTrim(l);
  if ([trimmed hasPrefix:@"{"] && [trimmed hasSuffix:@"}"] && [trimmed rangeOfString:@"\"ts\""].location != NSNotFound) {
    self.log(trimmed);
    return;
  }
  // Wrap non-JSON log strings to keep a single, parseable log format.
  self.log(OnDeviceAgentLogJSONLine(@"info", @"agent", @"legacy", trimmed, nil));
}

- (void)emitChat:(NSDictionary *)item
{
  if (self.chat) {
    self.chat(item ?: @{} );
  }
}

static long long OnDeviceAgentLL(id v)
{
  if ([v isKindOfClass:NSNumber.class]) {
    return [((NSNumber *)v) longLongValue];
  }
  if ([v isKindOfClass:NSString.class]) {
    NSString *s = OnDeviceAgentTrim((NSString *)v);
    if (s.length == 0) {
      return 0;
    }
    return [s longLongValue];
  }
  return 0;
}

- (NSDictionary *)tokenUsageSnapshot
{
  return @{
    @"requests": @(self.usageRequests),
    @"input_tokens": @(self.usageInputTokens),
    @"output_tokens": @(self.usageOutputTokens),
    @"cached_tokens": @(self.usageCachedTokens),
    @"total_tokens": @(self.usageTotalTokens),
  };
}

- (void)resetTokenUsage
{
  self.usageRequests = 0;
  self.usageInputTokens = 0;
  self.usageOutputTokens = 0;
  self.usageCachedTokens = 0;
  self.usageTotalTokens = 0;
}

- (NSDictionary *)accumulateTokenUsageFromResponse:(NSDictionary *)resp
{
  if (![resp isKindOfClass:NSDictionary.class]) {
    return @{};
  }
  NSDictionary *usage = [resp[@"usage"] isKindOfClass:NSDictionary.class] ? (NSDictionary *)resp[@"usage"] : nil;
  if (usage.count == 0) {
    return @{};
  }

  long long input = OnDeviceAgentLL(usage[@"prompt_tokens"]);
  if (input == 0) {
    input = OnDeviceAgentLL(usage[@"input_tokens"]);
  }
  long long output = OnDeviceAgentLL(usage[@"completion_tokens"]);
  if (output == 0) {
    output = OnDeviceAgentLL(usage[@"output_tokens"]);
  }
  long long total = OnDeviceAgentLL(usage[@"total_tokens"]);
  if (total == 0 && (input > 0 || output > 0)) {
    total = input + output;
  }

  long long cached = 0;
  NSDictionary *promptDetails = [usage[@"prompt_tokens_details"] isKindOfClass:NSDictionary.class] ? (NSDictionary *)usage[@"prompt_tokens_details"] : nil;
  NSDictionary *inputDetails = [usage[@"input_tokens_details"] isKindOfClass:NSDictionary.class] ? (NSDictionary *)usage[@"input_tokens_details"] : nil;
  NSDictionary *details = (promptDetails.count > 0) ? promptDetails : inputDetails;
  if (details.count > 0) {
    cached = OnDeviceAgentLL(details[@"cached_tokens"]);
  }

  self.usageRequests += 1;
  self.usageInputTokens += input;
  self.usageOutputTokens += output;
  self.usageCachedTokens += cached;
  self.usageTotalTokens += total;

  return @{
    @"input_tokens": @(input),
    @"output_tokens": @(output),
    @"cached_tokens": @(cached),
    @"total_tokens": @(total),
  };
}

- (NSString *)buildSystemPrompt
{
  return OnDeviceAgentDefaultSystemPromptTemplate();
}

- (NSString *)renderSystemPromptTemplate:(NSString *)template
{
  NSString *out = template ?: @"";
  out = [out stringByReplacingOccurrencesOfString:@"{{DATE_ZH}}" withString:OnDeviceAgentFormattedDateZH()];
  out = [out stringByReplacingOccurrencesOfString:@"{{DATE_EN}}" withString:OnDeviceAgentFormattedDateEN()];
  return out;
}

- (NSArray<NSDictionary *> *)sanitizePlanChecklist:(id)planObj
{
  if (![planObj isKindOfClass:NSArray.class]) {
    return nil;
  }
  NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
  for (id item in (NSArray *)planObj) {
    if ([item isKindOfClass:NSString.class]) {
      NSString *t = OnDeviceAgentTrim((NSString *)item);
      if (t.length == 0) {
        continue;
      }
      [out addObject:@{@"id": @"", @"text": t, @"done": @NO}];
      continue;
    }
    if (![item isKindOfClass:NSDictionary.class]) {
      continue;
    }
    NSDictionary *d = (NSDictionary *)item;
    NSString *pid = @"";
    if ([d[@"id"] isKindOfClass:NSString.class]) {
      pid = OnDeviceAgentTrim((NSString *)d[@"id"]);
      if (pid.length > 64) {
        pid = [pid substringToIndex:64];
      }
    }
    NSString *text = @"";
    if ([d[@"text"] isKindOfClass:NSString.class]) {
      text = OnDeviceAgentTrim((NSString *)d[@"text"]);
    } else if ([d[@"item"] isKindOfClass:NSString.class]) {
      text = OnDeviceAgentTrim((NSString *)d[@"item"]);
    }
    if (text.length == 0) {
      continue;
    }
    BOOL done = OnDeviceAgentParseBool(d[@"done"], NO);
    [out addObject:@{@"id": pid ?: @"", @"text": text, @"done": @(done)}];
  }

  if (out.count == 0) {
    return nil;
  }
  if (out.count > 50) {
    return [out subarrayWithRange:NSMakeRange(0, 50)];
  }
  return out.copy;
}

- (NSArray<NSDictionary *> *)mergePlanChecklistMonotonic:(NSArray<NSDictionary *> *)oldPlan newPlan:(NSArray<NSDictionary *> *)newPlan
{
  if (![oldPlan isKindOfClass:NSArray.class] || oldPlan.count == 0) {
    return newPlan;
  }
  if (![newPlan isKindOfClass:NSArray.class] || newPlan.count == 0) {
    return oldPlan;
  }

  NSMutableDictionary<NSString *, NSDictionary *> *newById = [NSMutableDictionary dictionary];
  NSMutableDictionary<NSString *, NSDictionary *> *newByKey = [NSMutableDictionary dictionary];
  NSMutableSet<NSNumber *> *matchedNewIndexes = [NSMutableSet set];

  for (NSUInteger i = 0; i < newPlan.count; i++) {
    id item = newPlan[i];
    if (![item isKindOfClass:NSDictionary.class]) {
      continue;
    }
    NSDictionary *d = (NSDictionary *)item;
    NSString *pid = OnDeviceAgentTrim(OnDeviceAgentStringOrEmpty(d[@"id"]));
    NSString *text = OnDeviceAgentTrim(OnDeviceAgentStringOrEmpty(d[@"text"]));
    if (pid.length > 0) {
      newById[pid] = @{@"idx": @(i), @"item": d};
    }
    NSString *key = OnDeviceAgentNormalizePlanItemTextKey(text);
    if (key.length > 0 && newByKey[key] == nil) {
      newByKey[key] = @{@"idx": @(i), @"item": d};
    }
  }

  NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
  for (id item in oldPlan) {
    if (![item isKindOfClass:NSDictionary.class]) {
      continue;
    }
    NSDictionary *old = (NSDictionary *)item;
    NSString *oldId = OnDeviceAgentTrim(OnDeviceAgentStringOrEmpty(old[@"id"]));
    NSString *oldText = OnDeviceAgentTrim(OnDeviceAgentStringOrEmpty(old[@"text"]));
    if (oldText.length == 0) {
      continue;
    }
    BOOL oldDone = OnDeviceAgentParseBool(old[@"done"], NO);

    NSDictionary *match = nil;
    if (oldId.length > 0 && newById[oldId] != nil) {
      match = newById[oldId];
    } else {
      NSString *key = OnDeviceAgentNormalizePlanItemTextKey(oldText);
      if (key.length > 0 && newByKey[key] != nil) {
        match = newByKey[key];
      }
    }

    if (match != nil) {
      NSNumber *idx = match[@"idx"];
      NSDictionary *n = [match[@"item"] isKindOfClass:NSDictionary.class] ? (NSDictionary *)match[@"item"] : @{};
      if ([idx isKindOfClass:NSNumber.class]) {
        [matchedNewIndexes addObject:idx];
      }
      BOOL newDone = OnDeviceAgentParseBool(n[@"done"], NO);
      NSString *newText = OnDeviceAgentTrim(OnDeviceAgentStringOrEmpty(n[@"text"]));
      NSString *mergedId = oldId.length > 0 ? oldId : OnDeviceAgentTrim(OnDeviceAgentStringOrEmpty(n[@"id"]));
      if (mergedId.length == 0) {
        mergedId = OnDeviceAgentGeneratePlanItemId();
      }
      // Keep the existing text stable to reduce accidental "rephrase = new item".
      NSString *mergedText = oldText.length > 0 ? oldText : newText;
      [out addObject:@{@"id": mergedId, @"text": mergedText, @"done": @(oldDone || newDone)}];
      continue;
    }

    NSString *mergedId = oldId.length > 0 ? oldId : OnDeviceAgentGeneratePlanItemId();
    [out addObject:@{@"id": mergedId, @"text": oldText, @"done": @(oldDone)}];
  }

  for (NSUInteger i = 0; i < newPlan.count; i++) {
    if ([matchedNewIndexes containsObject:@(i)]) {
      continue;
    }
    id item = newPlan[i];
    if (![item isKindOfClass:NSDictionary.class]) {
      continue;
    }
    NSDictionary *d = (NSDictionary *)item;
    NSString *text = OnDeviceAgentTrim(OnDeviceAgentStringOrEmpty(d[@"text"]));
    if (text.length == 0) {
      continue;
    }
    BOOL done = OnDeviceAgentParseBool(d[@"done"], NO);
    NSString *pid = OnDeviceAgentTrim(OnDeviceAgentStringOrEmpty(d[@"id"]));
    if (pid.length == 0) {
      pid = OnDeviceAgentGeneratePlanItemId();
    }
    [out addObject:@{@"id": pid, @"text": text, @"done": @(done)}];
  }

  if (out.count == 0) {
    return nil;
  }
  if (out.count > 50) {
    return [out subarrayWithRange:NSMakeRange(0, 50)];
  }
  return out.copy;
}

- (NSInteger)doneCountForPlan:(NSArray<NSDictionary *> *)plan
{
  if (![plan isKindOfClass:NSArray.class]) {
    return 0;
  }
  NSInteger count = 0;
  for (id item in plan) {
    if (![item isKindOfClass:NSDictionary.class]) {
      continue;
    }
    NSDictionary *d = (NSDictionary *)item;
    if (OnDeviceAgentParseBool(d[@"done"], NO)) {
      count += 1;
    }
  }
  return count;
}

- (NSString *)planChecklistText
{
  NSArray<NSDictionary *> *plan = self.planChecklist;
  if (plan.count == 0) {
    return @"";
  }
  NSMutableString *s = [NSMutableString string];
  [s appendString:@"** Plan Checklist **\n"];
  NSInteger idx = 1;
  for (NSDictionary *it in plan) {
    NSString *text = [it[@"text"] isKindOfClass:NSString.class] ? (NSString *)it[@"text"] : @"";
    NSString *pid = OnDeviceAgentTrim(OnDeviceAgentStringOrEmpty(it[@"id"]));
    BOOL done = OnDeviceAgentParseBool(it[@"done"], NO);
    if (text.length == 0) {
      continue;
    }
    if (pid.length > 0) {
      [s appendFormat:@"%ld. [%@] [id:%@] %@\n", (long)idx, done ? @"x" : @" ", pid, text];
    } else {
      [s appendFormat:@"%ld. [%@] %@\n", (long)idx, done ? @"x" : @" ", text];
    }
    idx += 1;
  }
  return s.copy;
}

- (NSString *)workingNoteText
{
  NSString *note = self.workingNote ?: @"";
  if (note.length == 0) {
    return @"";
  }
  return [NSString stringWithFormat:@"** Working Notes **\n%@\n", note];
}

- (NSURL *)chatCompletionsURL
{
  NSString *baseURL = OnDeviceAgentTrim(OnDeviceAgentStringOrEmpty(self.config[kOnDeviceAgentBaseURLKey]));
  while ([baseURL hasSuffix:@"/"]) {
    baseURL = [baseURL substringToIndex:baseURL.length - 1];
  }
  NSURL *base = [NSURL URLWithString:baseURL];
  if (base == nil) {
    return nil;
  }

  NSString *path = base.path ?: @"";
  if ([path hasSuffix:@"/chat/completions"]) {
    return base;
  }

  // Some providers expose OpenAI-compatible chat completions under a different version prefix,
  // for example: https://.../api/v3/chat/completions (no /v1).
  if ([path hasSuffix:@"/v1"] || [path hasSuffix:@"/api/v3"]) {
    return [base URLByAppendingPathComponent:@"chat/completions"];
  }

  NSURL *v1 = base;
  if (![path hasSuffix:@"/v1"]) {
    v1 = [base URLByAppendingPathComponent:@"v1"];
  }
  return [v1 URLByAppendingPathComponent:@"chat/completions"];
}

// OpenAI Responses API endpoint: /v1/responses (or provider-specific prefix like /api/v3/responses).
- (NSURL *)responsesURL
{
  NSString *baseURL = OnDeviceAgentTrim(OnDeviceAgentStringOrEmpty(self.config[kOnDeviceAgentBaseURLKey]));
  while ([baseURL hasSuffix:@"/"]) {
    baseURL = [baseURL substringToIndex:baseURL.length - 1];
  }
  NSURL *base = [NSURL URLWithString:baseURL];
  if (base == nil) {
    return nil;
  }

  NSString *path = base.path ?: @"";
  if ([path hasSuffix:@"/responses"]) {
    return base;
  }

  // Some providers expose OpenAI-compatible APIs under a different version prefix,
  // for example: https://.../api/v3/responses (no /v1).
  if ([path hasSuffix:@"/v1"] || [path hasSuffix:@"/api/v3"]) {
    return [base URLByAppendingPathComponent:@"responses"];
  }

  NSURL *v1 = base;
  if (![path hasSuffix:@"/v1"]) {
    v1 = [base URLByAppendingPathComponent:@"v1"];
  }
  return [v1 URLByAppendingPathComponent:@"responses"];
}

- (NSString *)modelServiceHost
{
  NSString *baseURL = OnDeviceAgentTrim(OnDeviceAgentStringOrEmpty(self.config[kOnDeviceAgentBaseURLKey]));
  NSURL *base = [NSURL URLWithString:baseURL];
  NSString *host = OnDeviceAgentTrim(base.host ?: @"");
  return host.lowercaseString;
}

- (NSData *)takeScreenshotPNG
{
  __block NSData *png = nil;
  OnDeviceAgentSyncOnMain(^{
    XCUIScreenshot *shot = [[XCUIScreen mainScreen] screenshot];
    png = shot.PNGRepresentation;
  });
  return png;
}

- (NSString *)buildScreenInfoJSON
{
  __block NSString *bundleId = @"";
  OnDeviceAgentSyncOnMain(^{
    XCUIApplication *active = XCUIApplication.fb_activeApplication;
    NSArray<NSDictionary<NSString *, id> *> *infos = [XCUIApplication fb_activeAppsInfo];

    for (NSDictionary<NSString *, id> *info in infos) {
      NSString *candidateId = [info[@"bundleId"] isKindOfClass:NSString.class] ? (NSString *)info[@"bundleId"] : nil;
      candidateId = OnDeviceAgentTrim(candidateId ?: @"");
      if (candidateId.length == 0 || [candidateId isEqualToString:@"unknown"]) {
        continue;
      }
      XCUIApplication *candidate = [[XCUIApplication alloc] initWithBundleIdentifier:candidateId];
      if ([candidate fb_isSameAppAs:active]) {
        bundleId = candidateId;
        break;
      }
    }

    if (bundleId.length == 0) {
      for (NSDictionary<NSString *, id> *info in infos) {
        NSString *candidateId = [info[@"bundleId"] isKindOfClass:NSString.class] ? (NSString *)info[@"bundleId"] : nil;
        candidateId = OnDeviceAgentTrim(candidateId ?: @"");
        if (candidateId.length == 0 || [candidateId isEqualToString:@"unknown"]) {
          continue;
        }
        bundleId = candidateId;
        break;
      }
    }
  });

  NSString *appName = OnDeviceAgentAppNameForBundleId(bundleId);
  NSString *currentApp = appName.length > 0 ? appName : (bundleId.length > 0 ? bundleId : @"");
  NSDictionary *info = @{
    @"current_app": currentApp,
    @"bundle_id": bundleId ?: @"",
  };
  return OnDeviceAgentJSONStringFromObject(info);
}

- (NSDictionary *)parseActionFromModelText:(NSString *)text error:(NSError **)error
{
  NSString *payload = OnDeviceAgentTrim(text ?: @"");
  if (payload.length == 0) {
    if (error) {
      *error = [NSError errorWithDomain:@"OnDeviceAgent" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Empty model output"}];
    }
    return nil;
  }

  NSData *data = [payload dataUsingEncoding:NSUTF8StringEncoding];
  NSError *jsonErr = nil;
  id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
  if (![obj isKindOfClass:NSDictionary.class]) {
    if (error) {
      *error = jsonErr ?: [NSError errorWithDomain:@"OnDeviceAgent" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Model output is not a JSON object"}];
    }
    return nil;
  }

  NSDictionary *dict = (NSDictionary *)obj;
  if (![dict[@"action"] isKindOfClass:NSDictionary.class]) {
    if (error) {
      *error = [NSError errorWithDomain:@"OnDeviceAgent" code:3 userInfo:@{NSLocalizedDescriptionKey: @"Invalid action JSON: field 'action' must be an object"}];
    }
    return nil;
  }
  NSDictionary *actionObj = (NSDictionary *)dict[@"action"];
  if (![actionObj[@"name"] isKindOfClass:NSString.class] || OnDeviceAgentTrim((NSString *)actionObj[@"name"]).length == 0) {
    if (error) {
      *error = [NSError errorWithDomain:@"OnDeviceAgent" code:4 userInfo:@{NSLocalizedDescriptionKey: @"Invalid action JSON: field 'action.name' must be a non-empty string"}];
    }
    return nil;
  }
  return dict;

  // Unreachable.
}

- (NSString *)contentFromOpenAIResponse:(NSDictionary *)json
{
  NSArray *choices = json[@"choices"];
  if (![choices isKindOfClass:NSArray.class] || choices.count == 0) {
    return nil;
  }
  NSDictionary *choice0 = choices.firstObject;
  NSDictionary *message = [choice0 isKindOfClass:NSDictionary.class] ? choice0[@"message"] : nil;
  if (![message isKindOfClass:NSDictionary.class]) {
    return nil;
  }
  id content = message[@"content"];
  if ([content isKindOfClass:NSString.class]) {
    return (NSString *)content;
  }
  if ([content isKindOfClass:NSArray.class]) {
    NSMutableString *acc = [NSMutableString string];
    for (id part in (NSArray *)content) {
      if (![part isKindOfClass:NSDictionary.class]) {
        continue;
      }
      NSString *type = ((NSDictionary *)part)[@"type"];
      if ([type isEqualToString:@"text"]) {
        NSString *t = ((NSDictionary *)part)[@"text"];
        if ([t isKindOfClass:NSString.class]) {
          [acc appendString:t];
        }
      }
    }
    return acc.copy;
  }
  return nil;
}

- (NSString *)contentFromResponsesResponse:(NSDictionary *)json
{
  NSArray *output = json[@"output"];
  if (![output isKindOfClass:NSArray.class] || output.count == 0) {
    return nil;
  }

  NSMutableString *acc = [NSMutableString string];
  for (id itemObj in output) {
    if (![itemObj isKindOfClass:NSDictionary.class]) {
      continue;
    }
    NSDictionary *item = (NSDictionary *)itemObj;
    NSString *type = [item[@"type"] isKindOfClass:NSString.class] ? (NSString *)item[@"type"] : @"";
    NSString *role = [item[@"role"] isKindOfClass:NSString.class] ? (NSString *)item[@"role"] : @"";
    if (![type isEqualToString:@"message"] || ![role isEqualToString:@"assistant"]) {
      continue;
    }

    id content = item[@"content"];
    if ([content isKindOfClass:NSString.class]) {
      [acc appendString:(NSString *)content];
      continue;
    }
    if (![content isKindOfClass:NSArray.class]) {
      continue;
    }
    for (id partObj in (NSArray *)content) {
      if (![partObj isKindOfClass:NSDictionary.class]) {
        continue;
      }
      NSDictionary *part = (NSDictionary *)partObj;
      NSString *pt = [part[@"type"] isKindOfClass:NSString.class] ? (NSString *)part[@"type"] : @"";
      NSString *lower = [pt lowercaseString];
      if (![pt isEqualToString:@"output_text"] && ![lower isEqualToString:@"text"]) {
        continue;
      }
      NSString *t = [part[@"text"] isKindOfClass:NSString.class] ? (NSString *)part[@"text"] : nil;
      if (t.length > 0) {
        [acc appendString:t];
      }
    }
  }

  NSString *out = OnDeviceAgentTrim(acc.copy);
  return out.length > 0 ? out : nil;
}

- (NSString *)reasoningFromResponsesResponse:(NSDictionary *)json
{
  // Best-effort: some providers may include reasoning text in output items/parts.
  NSArray *output = json[@"output"];
  if (![output isKindOfClass:NSArray.class] || output.count == 0) {
    return @"";
  }

  NSMutableString *acc = [NSMutableString string];
  for (id itemObj in output) {
    if (![itemObj isKindOfClass:NSDictionary.class]) {
      continue;
    }
    NSDictionary *item = (NSDictionary *)itemObj;
    NSString *type = [item[@"type"] isKindOfClass:NSString.class] ? (NSString *)item[@"type"] : @"";
    NSString *lower = [type lowercaseString];
    if (![lower isEqualToString:@"reasoning"] && ![lower isEqualToString:@"analysis"] && ![lower isEqualToString:@"thinking"]) {
      continue;
    }
    id summary = item[@"summary"];
    if ([summary isKindOfClass:NSString.class]) {
      [acc appendString:(NSString *)summary];
      continue;
    }
    if ([summary isKindOfClass:NSArray.class]) {
      for (id sObj in (NSArray *)summary) {
        if (![sObj isKindOfClass:NSDictionary.class]) {
          continue;
        }
        NSString *t = [((NSDictionary *)sObj)[@"text"] isKindOfClass:NSString.class] ? (NSString *)((NSDictionary *)sObj)[@"text"] : nil;
        if (t.length > 0) {
          [acc appendString:t];
        }
      }
    }
  }
  return OnDeviceAgentTrim(acc.copy);
}

- (NSDictionary *)messageFromOpenAIResponse:(NSDictionary *)json
{
  NSArray *choices = json[@"choices"];
  if (![choices isKindOfClass:NSArray.class] || choices.count == 0) {
    return nil;
  }
  NSDictionary *choice0 = choices.firstObject;
  NSDictionary *message = [choice0 isKindOfClass:NSDictionary.class] ? choice0[@"message"] : nil;
  return [message isKindOfClass:NSDictionary.class] ? message : nil;
}

- (NSString *)reasoningFromOpenAIResponse:(NSDictionary *)json
{
  NSArray *choices = json[@"choices"];
  if (![choices isKindOfClass:NSArray.class] || choices.count == 0) {
    return @"";
  }
  NSDictionary *choice0 = choices.firstObject;
  NSDictionary *message = [choice0 isKindOfClass:NSDictionary.class] ? choice0[@"message"] : nil;
  if (![message isKindOfClass:NSDictionary.class]) {
    return @"";
  }

  // Common OpenAI-compatible extensions used by some providers.
  for (NSString *key in @[@"reasoning_content", @"reasoning", @"thinking", @"analysis"]) {
    id v = message[key];
    if ([v isKindOfClass:NSString.class]) {
      NSString *s = OnDeviceAgentTrim((NSString *)v);
      if (s.length > 0) {
        return s;
      }
    }
  }

  // Some providers may return structured content parts, including reasoning/thinking segments.
  id content = message[@"content"];
  if ([content isKindOfClass:NSArray.class]) {
    NSMutableString *acc = [NSMutableString string];
    for (id part in (NSArray *)content) {
      if (![part isKindOfClass:NSDictionary.class]) {
        continue;
      }
      NSString *type = ((NSDictionary *)part)[@"type"];
      if (![type isKindOfClass:NSString.class]) {
        continue;
      }
      NSString *lower = [(NSString *)type lowercaseString];
      if (![lower isEqualToString:@"reasoning"] && ![lower isEqualToString:@"thinking"] && ![lower isEqualToString:@"analysis"]) {
        continue;
      }
      NSString *t = ((NSDictionary *)part)[@"text"];
      if ([t isKindOfClass:NSString.class]) {
        [acc appendString:t];
      }
    }
    return OnDeviceAgentTrim(acc.copy);
  }

  return @"";
}

- (NSDictionary *)chatCompletionsRequestBodyForMessages:(NSArray<NSDictionary *> *)messages step:(NSInteger)step forRaw:(BOOL)forRaw
{
  NSMutableDictionary *body = [NSMutableDictionary dictionary];
  body[@"model"] = OnDeviceAgentStringOrEmpty(self.config[kOnDeviceAgentModelKey]);
  body[@"temperature"] = @1;
  body[@"max_completion_tokens"] = @(OnDeviceAgentParseInt(self.config[kOnDeviceAgentMaxCompletionTokensKey], kOnDeviceAgentDefaultMaxCompletionTokens));

  NSString *effort = OnDeviceAgentNormalizeReasoningEffort(OnDeviceAgentStringOrEmpty(self.config[kOnDeviceAgentReasoningEffortKey]));
  if (effort.length > 0) {
    body[@"reasoning_effort"] = effort;
  }

  NSArray<NSDictionary *> *msgs = [messages isKindOfClass:NSArray.class] ? messages : @[];
  body[@"messages"] = forRaw ? OnDeviceAgentSummarizeChatCompletionsMessagesForRaw(msgs, step) : msgs;
  return body.copy;
}

- (NSDictionary *)responsesRequestBodyForInput:(NSArray<NSDictionary *> *)input previousResponseId:(NSString *)previousResponseId forRaw:(BOOL)forRaw
{
  NSMutableDictionary *body = [NSMutableDictionary dictionary];
  NSString *model = OnDeviceAgentTrim(OnDeviceAgentStringOrEmpty(self.config[kOnDeviceAgentModelKey]));
  body[@"model"] = model;
  body[@"input"] = forRaw ? OnDeviceAgentSanitizeResponsesInputForRaw(input) : (input ?: @[]);
  body[@"temperature"] = @1;
  body[@"store"] = @YES;
  body[@"max_output_tokens"] = @(OnDeviceAgentParseInt(self.config[kOnDeviceAgentMaxCompletionTokensKey], kOnDeviceAgentDefaultMaxCompletionTokens));

  NSString *effort = OnDeviceAgentNormalizeReasoningEffort(OnDeviceAgentStringOrEmpty(self.config[kOnDeviceAgentReasoningEffortKey]));
  if (effort.length > 0) {
    body[@"reasoning"] = @{@"effort": effort};
  }

  if ([model.lowercaseString hasPrefix:@"doubao-seed"]
      && OnDeviceAgentParseBool(self.config[kOnDeviceAgentDoubaoSeedEnableSessionCacheKey], YES)) {
    body[@"caching"] = @{@"type": @"enabled"};
  }

  NSString *prev = OnDeviceAgentTrim(previousResponseId ?: @"");
  if (prev.length > 0) {
    body[@"previous_response_id"] = prev;
  }
  return body.copy;
}

- (NSDictionary *)callModelWithMessages:(NSArray<NSDictionary *> *)messages error:(NSError **)error
{
  NSURL *url = [self chatCompletionsURL];
  if (url == nil) {
    if (error) {
      *error = [NSError errorWithDomain:@"OnDeviceAgent" code:3 userInfo:@{NSLocalizedDescriptionKey: @"Invalid base_url"}];
    }
    return nil;
  }

  NSDictionary *body = [self chatCompletionsRequestBodyForMessages:messages step:0 forRaw:NO];

  NSData *payload = [NSJSONSerialization dataWithJSONObject:body options:0 error:error];
  if (payload == nil) {
    return nil;
  }

  NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
  req.HTTPMethod = @"POST";
  req.HTTPBody = payload;
  [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

  NSString *apiKey = OnDeviceAgentNormalizeApiKey(OnDeviceAgentStringOrEmpty(self.config[kOnDeviceAgentApiKeyKey]));
  if (apiKey.length > 0) {
    [req setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];
  }

  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  __block NSData *respData = nil;
  __block NSError *respErr = nil;
  __block NSInteger statusCode = 0;

  NSURLSessionDataTask *t = [self.session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
    if ([resp isKindOfClass:NSHTTPURLResponse.class]) {
      statusCode = ((NSHTTPURLResponse *)resp).statusCode;
    }
    respData = data;
    respErr = err;
    dispatch_semaphore_signal(sem);
  }];
  self.inflightTask = t;
  [t resume];

  double timeout = OnDeviceAgentParseDouble(self.config[kOnDeviceAgentTimeoutSecondsKey], kOnDeviceAgentDefaultTimeoutSeconds);
  dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC));
  if (dispatch_semaphore_wait(sem, deadline) != 0) {
    [t cancel];
    if (self.inflightTask == t) {
      self.inflightTask = nil;
    }
    if (error) {
      *error = [NSError errorWithDomain:@"OnDeviceAgent" code:4 userInfo:@{NSLocalizedDescriptionKey: @"LLM request timed out"}];
    }
    return nil;
  }

  if (self.inflightTask == t) {
    self.inflightTask = nil;
  }

  if (respErr != nil) {
    if ([respErr.domain isEqualToString:NSURLErrorDomain] && respErr.code == NSURLErrorCancelled && self.stopRequested) {
      if (error) {
        *error = [NSError errorWithDomain:@"OnDeviceAgent" code:40 userInfo:@{NSLocalizedDescriptionKey: @"Stopped"}];
      }
      return nil;
    }
    if (error) {
      *error = respErr;
    }
    return nil;
  }
  if (respData == nil) {
    if (error) {
      *error = [NSError errorWithDomain:@"OnDeviceAgent" code:5 userInfo:@{NSLocalizedDescriptionKey: @"Empty LLM response body"}];
    }
    return nil;
  }
  if (statusCode < 200 || statusCode >= 300) {
    NSString *bodyText = [[NSString alloc] initWithData:respData encoding:NSUTF8StringEncoding] ?: @"";
    if (error) {
      *error = [NSError errorWithDomain:@"OnDeviceAgent" code:6 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"LLM HTTP %ld: %@", (long)statusCode, bodyText]}];
    }
    return nil;
  }

  NSDictionary *json = [NSJSONSerialization JSONObjectWithData:respData options:0 error:error];
  if (![json isKindOfClass:NSDictionary.class]) {
    if (error && *error == nil) {
      *error = [NSError errorWithDomain:@"OnDeviceAgent" code:7 userInfo:@{NSLocalizedDescriptionKey: @"LLM response is not JSON object"}];
    }
    return nil;
  }
  return json;
}

- (NSDictionary *)callResponsesWithInput:(NSArray<NSDictionary *> *)input previousResponseId:(NSString *)previousResponseId error:(NSError **)error
{
  NSURL *url = [self responsesURL];
  if (url == nil) {
    if (error) {
      *error = [NSError errorWithDomain:@"OnDeviceAgent" code:30 userInfo:@{NSLocalizedDescriptionKey: @"Invalid base_url"}];
    }
    return nil;
  }

  NSDictionary *body = [self responsesRequestBodyForInput:input previousResponseId:previousResponseId forRaw:NO];

  NSData *payload = [NSJSONSerialization dataWithJSONObject:body options:0 error:error];
  if (payload == nil) {
    return nil;
  }

  NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
  req.HTTPMethod = @"POST";
  req.HTTPBody = payload;
  [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

  NSString *apiKey = OnDeviceAgentNormalizeApiKey(OnDeviceAgentStringOrEmpty(self.config[kOnDeviceAgentApiKeyKey]));
  if (apiKey.length > 0) {
    [req setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];
  }

  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  __block NSData *respData = nil;
  __block NSError *respErr = nil;
  __block NSInteger statusCode = 0;

  NSURLSessionDataTask *t = [self.session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
    if ([resp isKindOfClass:NSHTTPURLResponse.class]) {
      statusCode = ((NSHTTPURLResponse *)resp).statusCode;
    }
    respData = data;
    respErr = err;
    dispatch_semaphore_signal(sem);
  }];
  self.inflightTask = t;
  [t resume];

  double timeout = OnDeviceAgentParseDouble(self.config[kOnDeviceAgentTimeoutSecondsKey], kOnDeviceAgentDefaultTimeoutSeconds);
  dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC));
  if (dispatch_semaphore_wait(sem, deadline) != 0) {
    [t cancel];
    if (self.inflightTask == t) {
      self.inflightTask = nil;
    }
    if (error) {
      *error = [NSError errorWithDomain:@"OnDeviceAgent" code:31 userInfo:@{NSLocalizedDescriptionKey: @"LLM request timed out"}];
    }
    return nil;
  }

  if (self.inflightTask == t) {
    self.inflightTask = nil;
  }

  if (respErr != nil) {
    if ([respErr.domain isEqualToString:NSURLErrorDomain] && respErr.code == NSURLErrorCancelled && self.stopRequested) {
      if (error) {
        *error = [NSError errorWithDomain:@"OnDeviceAgent" code:41 userInfo:@{NSLocalizedDescriptionKey: @"Stopped"}];
      }
      return nil;
    }
    if (error) {
      *error = respErr;
    }
    return nil;
  }
  if (respData == nil) {
    if (error) {
      *error = [NSError errorWithDomain:@"OnDeviceAgent" code:32 userInfo:@{NSLocalizedDescriptionKey: @"Empty LLM response body"}];
    }
    return nil;
  }
  if (statusCode < 200 || statusCode >= 300) {
    NSString *bodyText = [[NSString alloc] initWithData:respData encoding:NSUTF8StringEncoding] ?: @"";
    if (error) {
      *error = [NSError errorWithDomain:@"OnDeviceAgent" code:33 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"LLM HTTP %ld: %@", (long)statusCode, bodyText]}];
    }
    return nil;
  }

  NSDictionary *json = [NSJSONSerialization JSONObjectWithData:respData options:0 error:error];
  if (![json isKindOfClass:NSDictionary.class]) {
    if (error && *error == nil) {
      *error = [NSError errorWithDomain:@"OnDeviceAgent" code:34 userInfo:@{NSLocalizedDescriptionKey: @"LLM response is not JSON object"}];
    }
    return nil;
  }
  return json;
}

- (BOOL)performAction:(NSDictionary *)action error:(NSError **)error
{
  NSDictionary *actionObj = [action[@"action"] isKindOfClass:NSDictionary.class] ? (NSDictionary *)action[@"action"] : nil;
  NSString *actionName = [actionObj[@"name"] isKindOfClass:NSString.class] ? OnDeviceAgentNormalizeActionName((NSString *)actionObj[@"name"]) : @"";
  NSDictionary *params = [actionObj[@"params"] isKindOfClass:NSDictionary.class] ? (NSDictionary *)actionObj[@"params"] : @{};
  if (actionName.length == 0) {
    if (error) {
      *error = [NSError errorWithDomain:@"OnDeviceAgent" code:8 userInfo:@{NSLocalizedDescriptionKey: @"Missing action name"}];
    }
    return NO;
  }

  // Non-UI actions (do not block the main thread)
  if ([actionName isEqualToString:@"wait"]) {
    double seconds = OnDeviceAgentParseDouble(params[@"seconds"], 0.0);
    if (seconds <= 0.0) {
      NSString *duration = OnDeviceAgentTrim(OnDeviceAgentStringOrEmpty(params[@"duration"]));
      NSString *clean = [[duration lowercaseString] stringByReplacingOccurrencesOfString:@"seconds" withString:@""];
      clean = OnDeviceAgentTrim(clean);
      seconds = [clean doubleValue];
    }
    if (seconds <= 0.0) {
      seconds = 1.0;
    }
    [NSThread sleepForTimeInterval:seconds];
    return YES;
  }
  if ([actionName isEqualToString:@"note"]) {
    NSString *msg = OnDeviceAgentStringOrEmpty(params[@"message"]);
    self.workingNote = msg;
    NSString *note = msg.length > 0 ? OnDeviceAgentTruncate(msg, 800) : @"";
    [self emit:OnDeviceAgentLogJSONLine(@"info", @"agent", @"note", nil, @{@"note": note})];
    return YES;
  }

  __block BOOL ok = YES;
  __block NSError *innerErr = nil;
  __block NSString *launchedBundleId = nil;
  OnDeviceAgentSyncOnMain(^{
    @try {
      XCUIApplication *active = XCUIApplication.fb_activeApplication;

      if ([actionName isEqualToString:@"launch"]) {
        NSString *appName = nil;
        if ([params[@"app"] isKindOfClass:NSString.class]) {
          appName = params[@"app"];
        } else if ([params[@"app_name"] isKindOfClass:NSString.class]) {
          appName = params[@"app_name"];
        }

        NSString *bundleId = nil;
        BOOL hasAppName = (OnDeviceAgentTrim(appName ?: @"").length > 0);
        if (appName.length > 0) {
          bundleId = OnDeviceAgentBundleIdForAppName(appName);
        }
        if (bundleId.length == 0) {
          if ([params[@"bundle_id"] isKindOfClass:NSString.class]) {
            bundleId = params[@"bundle_id"];
          } else if ([params[@"bundleId"] isKindOfClass:NSString.class]) {
            bundleId = params[@"bundleId"];
          } else if ([params[@"bundleID"] isKindOfClass:NSString.class]) {
            bundleId = params[@"bundleID"];
          }
          bundleId = OnDeviceAgentTrim(bundleId ?: @"");
        }

        if (bundleId.length == 0) {
          ok = NO;
          NSMutableDictionary *ui = [NSMutableDictionary dictionary];
          ui[NSLocalizedDescriptionKey] = @"launch requires app (e.g. '小红书') or bundle_id";
          ui[kOnDeviceAgentErrorKindKey] = hasAppName ? kOnDeviceAgentErrorKindLaunchNotInMap : kOnDeviceAgentErrorKindInvalidParams;
          innerErr = [NSError errorWithDomain:@"OnDeviceAgent" code:9 userInfo:ui.copy];
          return;
        }
        [self emit:OnDeviceAgentLogJSONLine(@"info", @"action", @"launch_app", nil, @{@"app": appName ?: @"", @"bundle_id": bundleId ?: @""})];
        XCUIApplication *app = [[XCUIApplication alloc] initWithBundleIdentifier:bundleId];
        if (app.state == XCUIApplicationStateNotRunning) {
          [app launch];
        } else {
          [app activate];
        }
        launchedBundleId = bundleId;
        return;
      }

      if ([actionName isEqualToString:@"home"]) {
        [[XCUIDevice sharedDevice] pressButton:XCUIDeviceButtonHome];
        return;
      }

      if ([actionName isEqualToString:@"back"]) {
        XCUICoordinate *start = [active coordinateWithNormalizedOffset:CGVectorMake(0.03, 0.5)];
        XCUICoordinate *end = [active coordinateWithNormalizedOffset:CGVectorMake(0.6, 0.5)];
        [start pressForDuration:0.1 thenDragToCoordinate:end];
        return;
      }

      if ([actionName isEqualToString:@"type"]) {
        NSString *text = OnDeviceAgentStringOrEmpty(params[@"text"]);
        if (text.length == 0) {
          ok = NO;
          innerErr = [NSError errorWithDomain:@"OnDeviceAgent" code:13 userInfo:@{
            NSLocalizedDescriptionKey: @"type requires action.params.text (non-empty string)",
            kOnDeviceAgentErrorKindKey: kOnDeviceAgentErrorKindInvalidParams,
          }];
          return;
        }
        XCUIElement *focused = [active fb_activeElement];
        if (focused != nil) {
          NSError *typeErr = nil;
          BOOL typed = [focused fb_typeText:text shouldClear:YES error:&typeErr];
          if (!typed) {
            [active typeText:text];
          }
        } else {
          [active typeText:text];
        }
        NSError *kbErr = nil;
        (void)[active fb_dismissKeyboardWithKeyNames:nil error:&kbErr];
        return;
      }

      if ([actionName isEqualToString:@"tap"] || [actionName isEqualToString:@"double_tap"] || [actionName isEqualToString:@"long_press"]) {
        double x = 0.0;
        double y = 0.0;
        NSString *ptErr = nil;
        if (!OnDeviceAgentParsePoint01From1000Array(params[@"element"], &x, &y, &ptErr)) {
          ok = NO;
          innerErr = [NSError errorWithDomain:@"OnDeviceAgent" code:14 userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Invalid 'element' for %@: %@. Expected: {\"action\":{\"name\":\"%@\",\"params\":{\"element\":[x,y]}}} with x/y in [0,1000]", actionName, ptErr ?: @"invalid coordinate", actionObj[@"name"] ?: @""],
            kOnDeviceAgentErrorKindKey: kOnDeviceAgentErrorKindInvalidParams,
          }];
          return;
        }

        XCUICoordinate *coord = [active coordinateWithNormalizedOffset:CGVectorMake(x, y)];
        if ([actionName isEqualToString:@"tap"]) {
          [coord tap];
          return;
        }
        if ([actionName isEqualToString:@"double_tap"]) {
          [coord doubleTap];
          return;
        }
        double seconds = OnDeviceAgentParseDouble(params[@"seconds"], 0.0);
        if (seconds <= 0.0) {
          seconds = 3.0;
        }
        [coord pressForDuration:seconds];
        return;
      }

      if ([actionName isEqualToString:@"swipe"]) {
        double sx = 0.0;
        double sy = 0.0;
        double ex = 0.0;
        double ey = 0.0;
        NSString *stErr = nil;
        NSString *edErr = nil;
        BOOL okStart = OnDeviceAgentParsePoint01From1000Array(params[@"start"], &sx, &sy, &stErr);
        BOOL okEnd = OnDeviceAgentParsePoint01From1000Array(params[@"end"], &ex, &ey, &edErr);
        if (!okStart || !okEnd) {
          ok = NO;
          NSString *detail = nil;
          if (!okStart && !okEnd) {
            detail = [NSString stringWithFormat:@"start=%@, end=%@", stErr ?: @"invalid", edErr ?: @"invalid"];
          } else if (!okStart) {
            detail = [NSString stringWithFormat:@"start=%@", stErr ?: @"invalid"];
          } else {
            detail = [NSString stringWithFormat:@"end=%@", edErr ?: @"invalid"];
          }
          innerErr = [NSError errorWithDomain:@"OnDeviceAgent" code:15 userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Invalid swipe coordinates: %@. Expected: {\"action\":{\"name\":\"Swipe\",\"params\":{\"start\":[x1,y1],\"end\":[x2,y2]}}} with values in [0,1000]", detail ?: @"invalid coordinate"],
            kOnDeviceAgentErrorKindKey: kOnDeviceAgentErrorKindInvalidParams,
          }];
          return;
        }

        BOOL useW3CSwipe = OnDeviceAgentParseBool(self.config[kOnDeviceAgentUseW3CActionsForSwipeKey], YES);
        NSInteger durationMs = OnDeviceAgentParseInt(params[@"duration_ms"], 0);
        if (durationMs <= 0) {
          double seconds = OnDeviceAgentParseDouble(params[@"seconds"], 0.0);
          if (seconds > 0.0) {
            durationMs = (NSInteger)((seconds * 1000.0) + 0.5);
          }
        }
        NSInteger holdMs = OnDeviceAgentParseInt(params[@"hold_ms"], 0);

        if (useW3CSwipe) {
          NSError *w3cErr = nil;
          NSArray *w3c = OnDeviceAgentBuildW3CSwipeActions(active, sx, sy, ex, ey, durationMs, holdMs);
	          if (w3c) {
	            if ([active fb_performW3CActions:w3c elementCache:nil error:&w3cErr]) {
	              return;
	            }
	            [self emit:OnDeviceAgentLogJSONLine(@"warn", @"action", @"swipe_w3c_failed", nil, @{@"error": w3cErr.localizedDescription ?: @"unknown"})];
	          } else {
	            [self emit:OnDeviceAgentLogJSONLine(@"info", @"action", @"swipe_w3c_skipped", nil, @{@"reason": @"invalid_viewport_size"})];
	          }
	        }

        // Fallback: XCUITest drag. Note this is "press then drag" semantics, not a true flick.
        double pressSeconds = OnDeviceAgentParseDouble(params[@"press_seconds"], 0.0);
        if (pressSeconds <= 0.0) {
          pressSeconds = 0.1;
        }
        if (pressSeconds > 3.0) {
          pressSeconds = 3.0;
        }
        XCUICoordinate *start = [active coordinateWithNormalizedOffset:CGVectorMake(sx, sy)];
        XCUICoordinate *end = [active coordinateWithNormalizedOffset:CGVectorMake(ex, ey)];
        [start pressForDuration:pressSeconds thenDragToCoordinate:end];
        return;
      }

      ok = NO;
      innerErr = [NSError errorWithDomain:@"OnDeviceAgent" code:10 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Unknown action: %@", actionName]}];
    } @catch (NSException *exception) {
      ok = NO;
      NSString *reason = exception.reason ?: @"Unknown exception";
      NSMutableDictionary *ui = [NSMutableDictionary dictionary];
      ui[NSLocalizedDescriptionKey] = [NSString stringWithFormat:@"Exception while executing action '%@': %@", actionName, reason];
      // Launch exceptions are commonly caused by an invalid/unknown bundle_id. Treat as recoverable so the model
      // can fall back to Launch(app=...) or use Spotlight search.
      if ([actionName isEqualToString:@"launch"]) {
        ui[kOnDeviceAgentErrorKindKey] = kOnDeviceAgentErrorKindInvalidParams;
      }
      innerErr = [NSError errorWithDomain:@"OnDeviceAgent" code:11 userInfo:ui.copy];
    }
  });

  if (ok && launchedBundleId.length > 0) {
    (void)OnDeviceAgentWaitForActiveBundleId(launchedBundleId, 5.0);
  }

  if (!ok && error) {
    *error = innerErr;
  }
  return ok;
}

- (void)runLoop
{
  NSString *task = OnDeviceAgentTrim(OnDeviceAgentStringOrEmpty(self.config[kOnDeviceAgentTaskKey]));
  NSInteger maxSteps = OnDeviceAgentParseInt(self.config[kOnDeviceAgentMaxStepsKey], kOnDeviceAgentDefaultMaxSteps);
  double stepDelay = OnDeviceAgentParseDouble(self.config[kOnDeviceAgentStepDelaySecondsKey], kOnDeviceAgentDefaultStepDelaySeconds);
  NSInteger consecutiveRecoverableFailures = 0;
  NSString *lastRecoverableFailureText = @"";
  NSString *apiMode = OnDeviceAgentNormalizeApiMode(OnDeviceAgentStringOrEmpty(self.config[kOnDeviceAgentApiModeKey]));
  if (apiMode.length == 0) {
    apiMode = kOnDeviceAgentApiModeResponses;
  }
  BOOL useResponses = [apiMode isEqualToString:kOnDeviceAgentApiModeResponses];
  BOOL restartByPlanEnabled = useResponses && OnDeviceAgentParseBool(self.config[kOnDeviceAgentRestartResponsesByPlanKey], NO);
  BOOL restartResponsesChainNextStep = NO;

  [self emit:OnDeviceAgentLogJSONLine(@"info", @"agent", @"starting", nil, @{
    @"max_steps": @(maxSteps),
    @"step_delay_seconds": @(stepDelay),
    @"api_mode": apiMode ?: @"",
  })];
  [self emit:OnDeviceAgentLogJSONLine(@"info", @"agent", @"task", nil, @{@"task": task ?: @""})];

  [self.context removeAllObjects];
  self.previousResponseId = @"";
  self.planChecklist = @[];
  self.workingNote = @"";
  [self resetTokenUsage];
  NSString *systemTemplate = [self buildSystemPrompt] ?: @"";
  BOOL useCustom = OnDeviceAgentParseBool(self.config[kOnDeviceAgentUseCustomSystemPromptKey], NO);
  if (useCustom) {
    NSString *custom = OnDeviceAgentStringOrEmpty(self.config[kOnDeviceAgentCustomSystemPromptKey]);
    if (custom.length > 0) {
      systemTemplate = custom;
    }
  }
  NSString *renderedSystemPrompt = [self renderSystemPromptTemplate:systemTemplate] ?: @"";
    if (!useResponses) {
      [self.context addObject:@{@"role": @"system", @"content": renderedSystemPrompt}];
    }
  BOOL captureRawConversation = OnDeviceAgentParseBool(self.config[kOnDeviceAgentDebugLogRawAssistantKey], NO);

  for (NSInteger step = 0; step < maxSteps; step++) {
    if (self.stopRequested) {
      [self emit:OnDeviceAgentLogJSONLine(@"warn", @"agent", @"stop_requested", nil, nil)];
      if (self.finish) {
        self.finish(NO, @"Stopped");
      }
      return;
    }

    BOOL restartedThisStep = NO;
    if (restartByPlanEnabled && restartResponsesChainNextStep) {
      restartResponsesChainNextStep = NO;
      self.previousResponseId = @"";
      restartedThisStep = YES;
      [self emit:OnDeviceAgentLogJSONLine(@"info", @"agent", @"responses_chain_restarted", nil, @{@"step": @(step)})];
    }

    NSData *png = [self takeScreenshotPNG];
    if (png.length == 0) {
      [self emit:OnDeviceAgentLogJSONLine(@"error", @"agent", @"screenshot_failed", nil, nil)];
      if (self.finish) {
        self.finish(NO, @"Failed to capture screenshot");
      }
      return;
      }
      if (OnDeviceAgentParseBool(self.config[kOnDeviceAgentHalfResScreenshotKey], NO)) {
        png = OnDeviceAgentDownscalePNGHalf(png);
      }
      if (self.screenshot) {
        self.screenshot(step, png);
      }
      NSString *b64 = [png base64EncodedStringWithOptions:0];
      NSString *imageDataURL = [NSString stringWithFormat:@"data:image/png;base64,%@", b64 ?: @""];

      NSString *screenInfo = [self buildScreenInfoJSON];
      NSString *textContent = nil;
      if (step == 0) {
        textContent = [NSString stringWithFormat:@"%@\n\n%@", task, screenInfo ?: @"{}"];
      } else {
      NSString *planText = [self planChecklistText];
      NSString *noteText = [self workingNoteText];
      NSMutableString *prefix = [NSMutableString string];
      if (lastRecoverableFailureText.length > 0) {
        [prefix appendString:@"上一步执行失败：\n"];
        [prefix appendString:lastRecoverableFailureText];
        if (![prefix hasSuffix:@"\n"]) {
          [prefix appendString:@"\n"];
        }
        [prefix appendString:@"\n"];
      }
      if (planText.length > 0) {
        [prefix appendString:planText];
      }
      if (noteText.length > 0) {
        if (prefix.length > 0 && ![prefix hasSuffix:@"\n"]) {
          [prefix appendString:@"\n"];
        }
        [prefix appendString:noteText];
      }
      NSString *taskHeader = @"";
      if (restartedThisStep && task.length > 0) {
        taskHeader = [NSString stringWithFormat:@"Task: %@\n\n", task];
      }
      NSString *restartHint = @"";
      if (restartedThisStep) {
        NSString *completed = OnDeviceAgentTrim(self.pendingRestartHintText ?: @"");
        if (completed.length > 0) {
          restartHint = [NSString stringWithFormat:@"继续：已完成「%@」。请从下一项开始；如当前界面无法验证结果，请先返回列表/总览确认再继续。\n\n", completed];
          self.pendingRestartHintText = @"";
        }
      }
      if (prefix.length > 0) {
        textContent = [NSString stringWithFormat:@"%@%@%@\n\n** Screen Info **\n\n%@", taskHeader, restartHint, prefix, screenInfo ?: @"{}"];
      } else {
        textContent = [NSString stringWithFormat:@"%@%@** Screen Info **\n\n%@", taskHeader, restartHint, screenInfo ?: @"{}"];
      }
      }

        NSDictionary *chatUserMessage = @{
          @"role": @"user",
          @"content": @[
            @{@"type": @"text", @"text": textContent ?: @""},
            @{@"type": @"image_url", @"image_url": @{@"url": imageDataURL}},
          ],
        };
        if (!useResponses) {
          [self.context addObject:chatUserMessage];
          OnDeviceAgentTrimChatCompletionsContextInPlace(self.context);
        }

        NSArray<NSDictionary *> *responsesInput = nil;
        if (useResponses) {
          NSString *prev = OnDeviceAgentTrim(self.previousResponseId ?: @"");
          NSMutableArray *inp = [NSMutableArray array];
          if (prev.length == 0 && renderedSystemPrompt.length > 0) {
            [inp addObject:@{
              @"role": @"developer",
              @"content": @[@{@"type": @"input_text", @"text": renderedSystemPrompt}],
            }];
          }
          [inp addObject:@{
            @"role": @"user",
            @"content": @[
              @{@"type": @"input_text", @"text": textContent ?: @""},
              @{@"type": @"input_image", @"image_url": imageDataURL},
            ],
          }];
          responsesInput = inp.copy;
        }

        if (self.chat) {
          NSMutableDictionary *chatItem = [NSMutableDictionary dictionary];
          chatItem[@"step"] = @(step);
          chatItem[@"kind"] = @"request";
          chatItem[@"text"] = textContent ?: @"";
            if (captureRawConversation) {
              NSDictionary *reqObj = useResponses
                ? [self responsesRequestBodyForInput:responsesInput previousResponseId:self.previousResponseId forRaw:YES]
                : [self chatCompletionsRequestBodyForMessages:self.context step:step forRaw:YES];
              chatItem[@"raw"] = OnDeviceAgentJSONStringFromObjectForRaw(@{@"request": reqObj ?: @{}});
              }
          [self emitChat:chatItem.copy];
        }

        NSError *callErr = nil;
          NSDictionary *resp = nil;
          if (useResponses) {
            resp = [self callResponsesWithInput:responsesInput previousResponseId:self.previousResponseId error:&callErr];
          } else {
            resp = [self callModelWithMessages:self.context error:&callErr];
        }
      if (resp == nil) {
        if (self.stopRequested) {
          [self emit:OnDeviceAgentLogJSONLine(@"warn", @"agent", @"stop_requested", nil, nil)];
          if (self.finish) {
            self.finish(NO, @"Stopped");
          }
          return;
        }
        [self emit:OnDeviceAgentLogJSONLine(@"error", @"model", @"llm_call_failed", nil, @{@"error": callErr.localizedDescription ?: callErr ?: @"unknown"})];
        if (self.finish) {
          self.finish(NO, callErr.localizedDescription ?: @"LLM call failed");
      }
      return;
    }

    NSString *assistantContent = useResponses ? ([self contentFromResponsesResponse:resp] ?: @"") : ([self contentFromOpenAIResponse:resp] ?: @"");
    NSString *assistantReasoning = useResponses ? [self reasoningFromResponsesResponse:resp] : [self reasoningFromOpenAIResponse:resp];
    NSDictionary *deltaUsage = [self accumulateTokenUsageFromResponse:resp];
    if (deltaUsage.count > 0) {
      NSDictionary *tot = [self tokenUsageSnapshot];
      [self emit:OnDeviceAgentLogJSONLine(@"info", @"tokens", @"token_usage", nil, @{
        @"req": tot[@"requests"] ?: @0,
        @"d_in": deltaUsage[@"input_tokens"] ?: @0,
        @"d_out": deltaUsage[@"output_tokens"] ?: @0,
        @"d_cached": deltaUsage[@"cached_tokens"] ?: @0,
        @"d_total": deltaUsage[@"total_tokens"] ?: @0,
        @"c_in": tot[@"input_tokens"] ?: @0,
        @"c_out": tot[@"output_tokens"] ?: @0,
        @"c_cached": tot[@"cached_tokens"] ?: @0,
        @"c_total": tot[@"total_tokens"] ?: @0,
      })];
    }
    if (useResponses) {
      NSString *rid = [resp[@"id"] isKindOfClass:NSString.class] ? (NSString *)resp[@"id"] : @"";
      rid = OnDeviceAgentTrim(rid);
      if (rid.length == 0) {
        [self emit:OnDeviceAgentLogJSONLine(@"error", @"model", @"responses_missing_id", nil, nil)];
        if (self.finish) {
          self.finish(NO, @"Responses API returned no 'id' (cannot continue statefully).");
        }
        return;
      }
      self.previousResponseId = rid;
    }
      if (self.chat) {
        NSMutableDictionary *chatItem = [NSMutableDictionary dictionary];
        chatItem[@"step"] = @(step);
        chatItem[@"kind"] = @"response";
        chatItem[@"content"] = assistantContent ?: @"";
        if (assistantReasoning.length > 0) {
          chatItem[@"reasoning"] = assistantReasoning;
        }
        if (captureRawConversation) {
          NSDictionary *sanitized = useResponses ? OnDeviceAgentSanitizeResponsesObjectForChat(resp) : OnDeviceAgentSanitizeChatCompletionsResponseForChat(resp);
          chatItem[@"raw"] = OnDeviceAgentJSONStringFromObjectForRaw(@{@"response": sanitized ?: @{}});
        }
        [self emitChat:chatItem.copy];
      }

    NSString *content = assistantContent;
    if (content.length == 0) {
      [self emit:OnDeviceAgentLogJSONLine(@"error", @"model", @"empty_model_content", nil, nil)];
      if (self.finish) {
        self.finish(NO, @"Empty model content");
      }
      return;
    }

    NSInteger maxActionRetries = 2;
    NSString *contentForParse = content;
    NSDictionary *action = nil;
    NSError *parseErr = nil;
    NSInteger actionParseAttemptUsed = 0;

    for (NSInteger attempt = 0; attempt <= maxActionRetries; attempt++) {
      parseErr = nil;
      action = [self parseActionFromModelText:contentForParse error:&parseErr];
      if (action != nil) {
        actionParseAttemptUsed = attempt;
        break;
      }

      NSString *errMsg = parseErr.localizedDescription ?: @"Unknown parse error";
      [self emit:OnDeviceAgentLogJSONLine(@"warn", @"agent", @"parse_action_failed", nil, @{
        @"attempt": @(attempt + 1),
        @"attempt_max": @(maxActionRetries + 1),
        @"error": errMsg ?: @"",
      })];

      if (attempt >= maxActionRetries) {
        break;
      }

        NSString *badOutput = OnDeviceAgentTruncate(OnDeviceAgentTrim(contentForParse), 4000);
        NSString *fixText = [NSString stringWithFormat:
          @"你上一条输出无法解析为合法 JSON（错误：%@）。\n"
          @"请仅输出 1 个合法的 JSON 对象（不要输出任何多余文本、不要输出代码块）。\n"
          @"要求：\n"
          @"- 顶层必须包含字段 \"action\"（object）\n"
          @"- \"action\" 结构必须是：{\"name\":\"Tap\",\"params\":{...}}\n"
          @"- \"action.name\" 必须是字符串；所有动作参数必须放到 \"action.params\"（不要放到顶层）\n"
          @"- 不要输出或修改 plan（如果存在 plan，请留给下一轮正常输出）\n"
          @"并尽量保持与你上一条输出的意图一致。\n"
          @"上一条输出如下：\n%@",
          errMsg,
          badOutput];

        NSDictionary *repairUser = @{
          @"role": @"user",
          @"content": @[
            @{@"type": @"text", @"text": fixText ?: @""},
          ],
        };

        NSArray<NSDictionary *> *responsesFixInput = @[
          @{@"role": @"user", @"content": @[@{@"type": @"input_text", @"text": fixText ?: @""}]}
        ];

        if (self.chat) {
          NSMutableDictionary *chatItem = [NSMutableDictionary dictionary];
          chatItem[@"step"] = @(step);
          chatItem[@"kind"] = @"request";
          chatItem[@"attempt"] = @(attempt + 1);
          chatItem[@"text"] = fixText ?: @"";
            if (captureRawConversation) {
              NSDictionary *reqObj = useResponses
                ? [self responsesRequestBodyForInput:responsesFixInput previousResponseId:self.previousResponseId forRaw:YES]
                : [self chatCompletionsRequestBodyForMessages:[self.context arrayByAddingObject:repairUser] step:step forRaw:YES];
              chatItem[@"raw"] = OnDeviceAgentJSONStringFromObjectForRaw(@{@"request": reqObj ?: @{}});
              }
          [self emitChat:chatItem.copy];
        }
        NSError *fixCallErr = nil;
          NSDictionary *fixResp = nil;
          if (useResponses) {
            fixResp = [self callResponsesWithInput:responsesFixInput previousResponseId:self.previousResponseId error:&fixCallErr];
          } else {
            NSArray *messagesForFix = [self.context arrayByAddingObject:repairUser];
            fixResp = [self callModelWithMessages:messagesForFix error:&fixCallErr];
          }
      if (fixResp == nil) {
        if (self.stopRequested) {
          [self emit:OnDeviceAgentLogJSONLine(@"warn", @"agent", @"stop_requested", nil, nil)];
          if (self.finish) {
            self.finish(NO, @"Stopped");
          }
          return;
        }
        [self emit:OnDeviceAgentLogJSONLine(@"error", @"model", @"llm_fix_call_failed", nil, @{
          @"attempt": @(attempt + 1),
          @"error": fixCallErr.localizedDescription ?: fixCallErr ?: @"unknown",
        })];
        if (self.finish) {
          self.finish(NO, fixCallErr.localizedDescription ?: @"LLM fix call failed");
        }
        return;
      }

      NSString *fixContent = useResponses ? ([self contentFromResponsesResponse:fixResp] ?: @"") : ([self contentFromOpenAIResponse:fixResp] ?: @"");
      NSString *fixReasoning = useResponses ? [self reasoningFromResponsesResponse:fixResp] : [self reasoningFromOpenAIResponse:fixResp];
      NSDictionary *fixDeltaUsage = [self accumulateTokenUsageFromResponse:fixResp];
      if (fixDeltaUsage.count > 0) {
        NSDictionary *tot = [self tokenUsageSnapshot];
        [self emit:OnDeviceAgentLogJSONLine(@"info", @"tokens", @"token_usage", nil, @{
          @"req": tot[@"requests"] ?: @0,
          @"d_in": fixDeltaUsage[@"input_tokens"] ?: @0,
          @"d_out": fixDeltaUsage[@"output_tokens"] ?: @0,
          @"d_cached": fixDeltaUsage[@"cached_tokens"] ?: @0,
          @"d_total": fixDeltaUsage[@"total_tokens"] ?: @0,
          @"c_in": tot[@"input_tokens"] ?: @0,
          @"c_out": tot[@"output_tokens"] ?: @0,
          @"c_cached": tot[@"cached_tokens"] ?: @0,
          @"c_total": tot[@"total_tokens"] ?: @0,
        })];
      }
      if (useResponses) {
        NSString *rid = [fixResp[@"id"] isKindOfClass:NSString.class] ? (NSString *)fixResp[@"id"] : @"";
        rid = OnDeviceAgentTrim(rid);
        if (rid.length == 0) {
          [self emit:OnDeviceAgentLogJSONLine(@"error", @"model", @"responses_missing_id_fix", nil, nil)];
          if (self.finish) {
            self.finish(NO, @"Responses API returned no 'id' for fix call (cannot continue statefully).");
          }
          return;
        }
        self.previousResponseId = rid;
      }
      if (self.chat) {
        NSMutableDictionary *chatItem = [NSMutableDictionary dictionary];
        chatItem[@"step"] = @(step);
        chatItem[@"kind"] = @"response";
        chatItem[@"attempt"] = @(attempt + 1);
          chatItem[@"content"] = fixContent ?: @"";
          if (fixReasoning.length > 0) {
            chatItem[@"reasoning"] = fixReasoning;
          }
          if (captureRawConversation) {
            NSDictionary *sanitized = useResponses ? OnDeviceAgentSanitizeResponsesObjectForChat(fixResp) : OnDeviceAgentSanitizeChatCompletionsResponseForChat(fixResp);
            chatItem[@"raw"] = OnDeviceAgentJSONStringFromObjectForRaw(@{@"response": sanitized ?: @{}});
          }
          [self emitChat:chatItem.copy];
        }

      if (fixContent.length == 0) {
        [self emit:OnDeviceAgentLogJSONLine(@"error", @"model", @"empty_fix_content", nil, @{@"attempt": @(attempt + 1)})];
        break;
      }
      contentForParse = fixContent;
    }

    if (action == nil) {
      NSString *stopMsg = [NSString stringWithFormat:@"模型输出的 action JSON 格式错误，已连续 %ld 次无法解析。为避免误操作，已停止任务。", (long)(maxActionRetries + 1)];
      [self emit:OnDeviceAgentLogJSONLine(@"error", @"agent", @"stop_parse_action_failed", stopMsg, @{@"attempt_max": @(maxActionRetries + 1)})];
      if (self.finish) {
        self.finish(NO, stopMsg);
      }
      return;
    }

    NSArray<NSDictionary *> *oldPlanChecklist = self.planChecklist;
    NSInteger oldDoneCount = [self doneCountForPlan:oldPlanChecklist];
    NSInteger newDoneCount = oldDoneCount;
    BOOL planDoneCountIncreased = NO;
    NSString *newlyCompletedPlanItemText = @"";
    NSArray<NSDictionary *> *newPlan = [self sanitizePlanChecklist:action[@"plan"]];
    if (newPlan != nil) {
      if (actionParseAttemptUsed > 0) {
        [self emit:OnDeviceAgentLogJSONLine(@"info", @"agent", @"plan_update_ignored_repair_attempt", nil, @{
          @"step": @(step),
          @"attempt": @(actionParseAttemptUsed + 1),
        })];
      } else {
        NSArray<NSDictionary *> *mergedPlan = [self mergePlanChecklistMonotonic:oldPlanChecklist newPlan:newPlan];
        if (mergedPlan != nil) {
          newDoneCount = [self doneCountForPlan:mergedPlan];
          planDoneCountIncreased = newDoneCount > oldDoneCount;
          if (planDoneCountIncreased) {
            newlyCompletedPlanItemText = [self firstNewlyCompletedPlanItemTextFromOldPlan:oldPlanChecklist newPlan:mergedPlan] ?: @"";
          }
          self.planChecklist = mergedPlan;
        }
      }
    }

    NSDictionary *actionObj = [action[@"action"] isKindOfClass:NSDictionary.class] ? (NSDictionary *)action[@"action"] : nil;
    NSString *actionName = [actionObj[@"name"] isKindOfClass:NSString.class] ? OnDeviceAgentNormalizeActionName((NSString *)actionObj[@"name"]) : @"";
    [self emit:OnDeviceAgentLogJSONLine(@"info", @"action", @"step", nil, @{
      @"step": @(step),
      @"action": actionName ?: @"",
      @"payload": OnDeviceAgentActionForLogs(action) ?: @{},
    })];

    if ([actionName isEqualToString:@"finish"]) {
      NSDictionary *params = [actionObj[@"params"] isKindOfClass:NSDictionary.class] ? (NSDictionary *)actionObj[@"params"] : @{};
      NSString *msg = OnDeviceAgentStringOrEmpty(params[@"message"]);
      [self emit:OnDeviceAgentLogJSONLine(@"info", @"agent", @"finished", nil, @{@"message": msg ?: @""})];
      if (self.finish) {
        self.finish(YES, msg.length > 0 ? msg : @"Finished");
      }
      return;
    }

    NSError *actErr = nil;
    if (![self performAction:action error:&actErr]) {
      NSString *failMsg = actErr.localizedDescription ?: @"Action failed";
      NSString *kind = [actErr.userInfo[kOnDeviceAgentErrorKindKey] isKindOfClass:NSString.class] ? (NSString *)actErr.userInfo[kOnDeviceAgentErrorKindKey] : @"";
      BOOL recoverable = [kind isEqualToString:kOnDeviceAgentErrorKindLaunchNotInMap] || [kind isEqualToString:kOnDeviceAgentErrorKindInvalidParams];
      if (!recoverable) {
        [self emit:OnDeviceAgentLogJSONLine(@"error", @"action", @"action_failed", nil, @{@"error": failMsg ?: @"", @"kind": kind ?: @""})];
        if (self.finish) {
          self.finish(NO, failMsg);
        }
        return;
      }

      consecutiveRecoverableFailures += 1;
      lastRecoverableFailureText = OnDeviceAgentExplainRecoverableActionError(kind, action, actErr);
      [self emit:OnDeviceAgentLogJSONLine(@"warn", @"action", @"action_failed_recoverable", nil, @{
        @"kind": kind ?: @"",
        @"count": @(consecutiveRecoverableFailures),
        @"limit": @(kOnDeviceAgentRecoverableFailureLimit),
        @"explain": OnDeviceAgentTruncate(lastRecoverableFailureText, kOnDeviceAgentMaxLogLineChars),
      })];

      // Keep assistant history aligned even when the action fails.
      if (!useResponses) {
        [self.context addObject:@{@"role": @"assistant", @"content": OnDeviceAgentJSONStringFromObject(action) ?: @""}];
        OnDeviceAgentTrimChatCompletionsContextInPlace(self.context);
      }

      if (consecutiveRecoverableFailures >= kOnDeviceAgentRecoverableFailureLimit) {
        NSString *stopMsg = [NSString stringWithFormat:@"动作执行失败已连续 %ld 次。为避免误操作，已停止任务。", (long)consecutiveRecoverableFailures];
        [self emit:OnDeviceAgentLogJSONLine(@"error", @"agent", @"stop_recoverable_failures", stopMsg, @{
          @"count": @(consecutiveRecoverableFailures),
          @"limit": @(kOnDeviceAgentRecoverableFailureLimit),
        })];
        if (self.finish) {
          self.finish(NO, stopMsg);
        }
        return;
      }

      if (stepDelay > 0) {
        [NSThread sleepForTimeInterval:stepDelay];
      }
      continue;
    }

    // Keep assistant history aligned with the JSON-only contract.
    if (!useResponses) {
      [self.context addObject:@{@"role": @"assistant", @"content": OnDeviceAgentJSONStringFromObject(action) ?: @""}];
      OnDeviceAgentTrimChatCompletionsContextInPlace(self.context);
    }
    consecutiveRecoverableFailures = 0;
    lastRecoverableFailureText = @"";

    if (restartByPlanEnabled && planDoneCountIncreased) {
      restartResponsesChainNextStep = YES;
      self.pendingRestartHintText = newlyCompletedPlanItemText ?: @"";
      [self emit:OnDeviceAgentLogJSONLine(@"info", @"agent", @"responses_chain_restart_scheduled", nil, @{
        @"step": @(step),
        @"old_done": @(oldDoneCount),
        @"new_done": @(newDoneCount),
      })];
    }

    if (stepDelay > 0) {
      [NSThread sleepForTimeInterval:stepDelay];
    }
  }

  if (self.finish) {
    [self emit:OnDeviceAgentLogJSONLine(@"warn", @"agent", @"max_steps_reached", nil, @{@"max_steps": @(maxSteps)})];
    self.finish(NO, @"Max steps reached");
  }
}

- (void)start
{
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    [self runLoop];
  });
}

- (void)requestStop
{
  self.stopRequested = YES;
  NSURLSessionTask *t = self.inflightTask;
  if (t != nil) {
    [t cancel];
  }
}

#pragma mark - NSURLSessionDelegate

- (void)URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential * _Nullable credential))completionHandler
{
  BOOL insecure = OnDeviceAgentParseBool(self.config[kOnDeviceAgentInsecureSkipTLSVerifyKey], NO);
  if (!insecure) {
    completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
    return;
  }

  // Scope guard: only allow insecure TLS for the configured model-service host.
  NSString *modelHost = [self modelServiceHost];
  NSString *challengeHost = OnDeviceAgentTrim(challenge.protectionSpace.host ?: @"").lowercaseString;
  if (modelHost.length > 0 && challengeHost.length > 0 && ![modelHost isEqualToString:challengeHost]) {
    completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
    return;
  }

  SecTrustRef trust = challenge.protectionSpace.serverTrust;
  if (trust != NULL) {
    NSURLCredential *cred = [NSURLCredential credentialForTrust:trust];
    completionHandler(NSURLSessionAuthChallengeUseCredential, cred);
    return;
  }
  completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
}

@end

@interface OnDeviceAgentManager ()
@property (nonatomic, strong) dispatch_queue_t stateQueue;
@property (nonatomic, strong) NSMutableArray<NSString *> *logLines;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *chatItems;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSData *> *stepScreenshots;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *stepScreenshotOrder;
@property (nonatomic, strong) NSMutableDictionary *config;
@property (nonatomic, strong) OnDeviceAgent *agent;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, copy) NSString *lastMessage;
@property (nonatomic, copy) NSString *notes;
@property (nonatomic, copy) NSDictionary *tokenUsage;
@property (nonatomic, assign) NSInteger runTokenCounter;
@property (nonatomic, assign) NSInteger activeRunToken;
- (void)resetRuntime;
- (void)factoryReset;
@end

static BOOL OnDeviceAgentParseStepActionFromLogLine(NSString *line, NSInteger *outStep, NSString **outActionName)
{
  if (![line isKindOfClass:NSString.class]) {
    return NO;
  }

  NSString *trimmed = OnDeviceAgentTrim(line);
  if (![trimmed hasPrefix:@"{"] || ![trimmed hasSuffix:@"}"]) {
    return NO;
  }

  NSData *data = [trimmed dataUsingEncoding:NSUTF8StringEncoding];
  if (data.length == 0) {
    return NO;
  }

  id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if (![obj isKindOfClass:NSDictionary.class]) {
    return NO;
  }
  NSDictionary *d = (NSDictionary *)obj;

  NSString *event = [d[@"event"] isKindOfClass:NSString.class] ? (NSString *)d[@"event"] : @"";
  if (![event isEqualToString:@"step"]) {
    return NO;
  }

  NSInteger step = OnDeviceAgentParseInt(d[@"step"], -1);
  NSString *action = [d[@"action"] isKindOfClass:NSString.class] ? (NSString *)d[@"action"] : @"";
  action = OnDeviceAgentTrim(action);
  if (step < 0 || action.length == 0) {
    return NO;
  }

  if (outStep != NULL) {
    *outStep = step;
  }
  if (outActionName != NULL) {
    *outActionName = action;
  }
  return YES;
}

@implementation OnDeviceAgentManager

+ (instancetype)shared
{
  static OnDeviceAgentManager *inst = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    inst = [OnDeviceAgentManager new];
  });
  return inst;
}

- (instancetype)init
{
  self = [super init];
  if (!self) {
    return nil;
  }
  _stateQueue = dispatch_queue_create("ondevice_agent.state", DISPATCH_QUEUE_SERIAL);
  _logLines = [NSMutableArray array];
  _chatItems = [NSMutableArray array];
  _stepScreenshots = [NSMutableDictionary dictionary];
  _stepScreenshotOrder = [NSMutableArray array];
  _config = [NSMutableDictionary dictionary];
  _running = NO;
  _lastMessage = @"";
  _notes = @"";
  _tokenUsage = @{};

  [self loadConfigFromDefaults];
  return self;
}

- (void)appendLog:(NSString *)line
{
  [self appendLog:line token:self.activeRunToken];
}

- (void)appendLog:(NSString *)line token:(NSInteger)token
{
  dispatch_async(self.stateQueue, ^{
    if (token != self.activeRunToken) {
      return;
    }
    NSString *l = line ?: @"";
    [self.logLines addObject:l];
    while (self.logLines.count > kOnDeviceAgentMaxLogLines) {
      [self.logLines removeObjectAtIndex:0];
    }

    if (self.running && self.agent != nil && !self.agent.stopRequested && ![self.lastMessage isEqualToString:@"Stopping..."]) {
      NSInteger step = -1;
      NSString *actionName = nil;
      if (OnDeviceAgentParseStepActionFromLogLine(l, &step, &actionName)) {
        self.lastMessage = [NSString stringWithFormat:@"Step %ld: Executing %@", (long)step, actionName];
      }
    }

    [FBLogger log:l];
    [[OnDeviceAgentEventHub shared] broadcastEvent:@"log" data:l];
  });
}

- (void)appendChatItem:(NSDictionary *)item
{
  [self appendChatItem:item token:self.activeRunToken];
}

- (void)appendChatItem:(NSDictionary *)item token:(NSInteger)token
{
  dispatch_async(self.stateQueue, ^{
    if (token != self.activeRunToken) {
      return;
    }
    NSMutableDictionary *d = [[item isKindOfClass:NSDictionary.class] ? item : @{} mutableCopy];
    if (![d[@"ts"] isKindOfClass:NSString.class]) {
      d[@"ts"] = OnDeviceAgentNowString();
    }
    [self.chatItems addObject:d.copy];

    if (self.running && self.agent != nil && !self.agent.stopRequested && ![self.lastMessage isEqualToString:@"Stopping..."]) {
      NSInteger step = OnDeviceAgentParseInt(d[@"step"], -1);
      NSInteger attempt = OnDeviceAgentParseInt(d[@"attempt"], 0);
      NSString *kind = [d[@"kind"] isKindOfClass:NSString.class] ? (NSString *)d[@"kind"] : @"";
      if (step >= 0) {
        if ([kind isEqualToString:@"request"]) {
          self.lastMessage = (attempt > 0)
            ? [NSString stringWithFormat:@"Step %ld: Calling model (attempt %ld)", (long)step, (long)attempt]
            : [NSString stringWithFormat:@"Step %ld: Calling model", (long)step];
        } else if ([kind isEqualToString:@"response"]) {
          self.lastMessage = (attempt > 0)
            ? [NSString stringWithFormat:@"Step %ld: Parsing output (attempt %ld)", (long)step, (long)attempt]
            : [NSString stringWithFormat:@"Step %ld: Parsing output", (long)step];
        }
      }
    }

    NSInteger maxSteps = OnDeviceAgentMaxChatSteps(self.config);
    NSInteger lastStep = OnDeviceAgentParseInt(d[@"step"], -1);
    if (lastStep >= 0 && maxSteps > 0) {
      NSInteger minStep = lastStep - maxSteps + 1;
      if (minStep < 0) {
        minStep = 0;
      }
      while (self.chatItems.count > 0) {
        NSDictionary *first = self.chatItems.firstObject;
        NSInteger s = OnDeviceAgentParseInt(first[@"step"], -1);
        if (s >= 0 && s < minStep) {
          [self.chatItems removeObjectAtIndex:0];
          continue;
        }
        break;
      }
    }

    NSUInteger hardLimit = OnDeviceAgentMaxChatItemsHardLimit(self.config);
    while (self.chatItems.count > hardLimit) {
      [self.chatItems removeObjectAtIndex:0];
    }

    [[OnDeviceAgentEventHub shared] broadcastJSONObject:d.copy event:@"chat"];
  });
}

- (void)resetRuntime
{
  dispatch_sync(self.stateQueue, ^{
    self.runTokenCounter += 1;
    self.activeRunToken = self.runTokenCounter;
    if (self.agent != nil) {
      [self.agent requestStop];
    }
    self.agent = nil;
    self.running = NO;
    self.lastMessage = @"";
    self.notes = @"";
    self.tokenUsage = @{};
    [self.stepScreenshots removeAllObjects];
    [self.stepScreenshotOrder removeAllObjects];
    [self.chatItems removeAllObjects];
    [self.logLines removeAllObjects];
  });

  NSDictionary *snapshot = @{
    @"status": [self status],
    @"logs": [self logs],
    @"chat": [self chat],
  };
  [[OnDeviceAgentEventHub shared] broadcastJSONObject:snapshot event:@"snapshot"];
}

- (void)removePersistedConfigFromDefaults
{
  NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
  NSArray<NSString *> *keys = @[
    kOnDeviceAgentTaskKey,
    kOnDeviceAgentBaseURLKey,
    kOnDeviceAgentModelKey,
    kOnDeviceAgentApiModeKey,
    kOnDeviceAgentAgentTokenKey,
    kOnDeviceAgentRememberApiKeyKey,
    kOnDeviceAgentUseCustomSystemPromptKey,
    kOnDeviceAgentCustomSystemPromptKey,
    kOnDeviceAgentReasoningEffortKey,
    kOnDeviceAgentDoubaoSeedEnableSessionCacheKey,
    kOnDeviceAgentMaxCompletionTokensKey,
    kOnDeviceAgentMaxStepsKey,
    kOnDeviceAgentTimeoutSecondsKey,
    kOnDeviceAgentStepDelaySecondsKey,
    kOnDeviceAgentInsecureSkipTLSVerifyKey,
    kOnDeviceAgentDebugLogRawAssistantKey,
    kOnDeviceAgentHalfResScreenshotKey,
    kOnDeviceAgentUseW3CActionsForSwipeKey,
    kOnDeviceAgentRestartResponsesByPlanKey,
  ];
  for (NSString *k in keys) {
    [d removeObjectForKey:k];
  }
  // Remove legacy plain-text key persisted in older versions.
  [d removeObjectForKey:kOnDeviceAgentApiKeyKey];
  (void)OnDeviceAgentKeychainDelete(OnDeviceAgentKeychainService(), kOnDeviceAgentKeychainAccountAPIKey);
}

- (void)factoryReset
{
  dispatch_sync(self.stateQueue, ^{
    self.runTokenCounter += 1;
    self.activeRunToken = self.runTokenCounter;
    if (self.agent != nil) {
      [self.agent requestStop];
    }
    self.agent = nil;
    self.running = NO;
    self.lastMessage = @"";
    self.notes = @"";
    self.tokenUsage = @{};
    [self.stepScreenshots removeAllObjects];
    [self.stepScreenshotOrder removeAllObjects];
    [self.chatItems removeAllObjects];
    [self.logLines removeAllObjects];

    [self removePersistedConfigFromDefaults];
    [self.config removeAllObjects];
    [self loadConfigFromDefaults];
  });

  NSDictionary *snapshot = @{
    @"status": [self status],
    @"logs": [self logs],
    @"chat": [self chat],
  };
  [[OnDeviceAgentEventHub shared] broadcastJSONObject:snapshot event:@"snapshot"];
}

- (void)storeStepScreenshotPNG:(NSData *)png step:(NSInteger)step token:(NSInteger)token
{
  if (![png isKindOfClass:NSData.class] || png.length == 0) {
    return;
  }
  dispatch_async(self.stateQueue, ^{
    if (token != self.activeRunToken) {
      return;
    }
    NSNumber *k = @(step);
    if (self.stepScreenshots[k] == nil) {
      [self.stepScreenshotOrder addObject:k];
    }
    self.stepScreenshots[k] = png;
    NSUInteger maxSteps = (NSUInteger)MAX(1, OnDeviceAgentMaxChatSteps(self.config));
    while (self.stepScreenshotOrder.count > maxSteps) {
      NSNumber *oldest = self.stepScreenshotOrder.firstObject;
      if (oldest == nil) {
        break;
      }
      [self.stepScreenshotOrder removeObjectAtIndex:0];
      [self.stepScreenshots removeObjectForKey:oldest];
    }
  });
}

- (NSString *)stepScreenshotBase64ForStep:(NSInteger)step
{
  __block NSData *png = nil;
  dispatch_sync(self.stateQueue, ^{
    png = self.stepScreenshots[@(step)];
  });
  if (![png isKindOfClass:NSData.class] || png.length == 0) {
    return @"";
  }
  return [png base64EncodedStringWithOptions:0] ?: @"";
}

- (NSDictionary *)stepScreenshotsBase64WithSteps:(NSArray<NSNumber *> *)steps
                                         limit:(NSInteger)limit
                                        format:(NSString *)format
                                       quality:(double)quality
{
  NSString *fmt = OnDeviceAgentTrim(format ?: @"").lowercaseString;
  BOOL asJPEG = [fmt isEqualToString:@"jpeg"] || [fmt isEqualToString:@"jpg"];
  NSString *mimeType = asJPEG ? @"image/jpeg" : @"image/png";
  fmt = asJPEG ? @"jpeg" : @"png";

  double q = quality;
  if (!isfinite(q) || q <= 0 || q > 1) {
    q = 0.7;
  }

  __block NSArray<NSNumber *> *wantSteps = nil;
  __block NSMutableArray<NSDictionary *> *entries = nil;
  dispatch_sync(self.stateQueue, ^{
    NSArray<NSNumber *> *want = [steps isKindOfClass:NSArray.class] ? steps : @[];
    if (want.count == 0) {
      NSInteger lim = MAX(1, limit);
      NSInteger n = (NSInteger)self.stepScreenshotOrder.count;
      if (n <= 0) {
        want = @[];
      } else if (n > lim) {
        want = [self.stepScreenshotOrder subarrayWithRange:NSMakeRange(n - lim, lim)];
      } else {
        want = self.stepScreenshotOrder.copy ?: @[];
      }
    }

    wantSteps = want ?: @[];
    entries = [NSMutableArray arrayWithCapacity:wantSteps.count];
    for (NSNumber *k in wantSteps) {
      if (![k isKindOfClass:NSNumber.class]) {
        continue;
      }
      NSData *png = self.stepScreenshots[k];
      if ([png isKindOfClass:NSData.class] && png.length > 0) {
        [entries addObject:@{@"step": k, @"png": png}];
      } else {
        [entries addObject:@{@"step": k}];
      }
    }
  });

  NSMutableDictionary *images = [NSMutableDictionary dictionary];
  NSMutableArray<NSNumber *> *missing = [NSMutableArray array];
  for (NSDictionary *e in entries) {
    NSNumber *step = [e[@"step"] isKindOfClass:NSNumber.class] ? (NSNumber *)e[@"step"] : nil;
    NSData *png = [e[@"png"] isKindOfClass:NSData.class] ? (NSData *)e[@"png"] : nil;
    if (step == nil || png == nil || png.length == 0) {
      if (step != nil) {
        [missing addObject:step];
      }
      continue;
    }

    NSData *out = png;
    if (asJPEG) {
      UIImage *img = [UIImage imageWithData:png];
      NSData *jpeg = (img != nil) ? UIImageJPEGRepresentation(img, q) : nil;
      if ([jpeg isKindOfClass:NSData.class] && jpeg.length > 0) {
        out = jpeg;
      }
    }
    NSString *b64 = [out base64EncodedStringWithOptions:0] ?: @"";
    if (b64.length == 0) {
      [missing addObject:step];
      continue;
    }
    images[step.stringValue ?: @""] = b64;
  }

  return @{
    @"ok": @YES,
    @"format": fmt,
    @"mime_type": mimeType,
    @"images": images.copy ?: @{},
    @"missing": missing.copy ?: @[],
  };
}

- (void)loadConfigFromDefaults
{
  NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
  NSString *task = [d stringForKey:kOnDeviceAgentTaskKey] ?: @"";
  NSString *baseURL = [d stringForKey:kOnDeviceAgentBaseURLKey] ?: kOnDeviceAgentDefaultBaseURL;
  if (OnDeviceAgentTrim(baseURL).length == 0) {
    baseURL = kOnDeviceAgentDefaultBaseURL;
  }
  NSString *model = [d stringForKey:kOnDeviceAgentModelKey] ?: kOnDeviceAgentDefaultModel;
  if (OnDeviceAgentTrim(model).length == 0) {
    model = kOnDeviceAgentDefaultModel;
  }
  NSString *apiKey = @"";
  NSString *agentToken = OnDeviceAgentTrim([d stringForKey:kOnDeviceAgentAgentTokenKey] ?: @"");
  BOOL remember = [d boolForKey:kOnDeviceAgentRememberApiKeyKey];
  if (remember) {
    apiKey = OnDeviceAgentKeychainGet(OnDeviceAgentKeychainService(), kOnDeviceAgentKeychainAccountAPIKey);
    if (apiKey.length == 0) {
      // Legacy migration: move plain-text key from defaults to Keychain once.
      NSString *legacy = [d stringForKey:kOnDeviceAgentApiKeyKey] ?: @"";
      if (legacy.length > 0) {
        if (!OnDeviceAgentKeychainSet(OnDeviceAgentKeychainService(), kOnDeviceAgentKeychainAccountAPIKey, legacy)) {
          [FBLogger log:@"[ONDEVICE] Failed to migrate legacy API key to Keychain"];
        }
        apiKey = legacy;
      }
    }
  }
  [d removeObjectForKey:kOnDeviceAgentApiKeyKey];

  BOOL useCustomSystemPrompt = [d boolForKey:kOnDeviceAgentUseCustomSystemPromptKey];
  NSString *customSystemPrompt = [d stringForKey:kOnDeviceAgentCustomSystemPromptKey] ?: @"";
  NSString *apiMode = OnDeviceAgentNormalizeApiMode([d stringForKey:kOnDeviceAgentApiModeKey] ?: @"");
  NSString *reasoningEffort = [d stringForKey:kOnDeviceAgentReasoningEffortKey] ?: @"";
  id cacheObj = [d objectForKey:kOnDeviceAgentDoubaoSeedEnableSessionCacheKey];
  BOOL enableDoubaoCache = (cacheObj == nil) ? YES : [d boolForKey:kOnDeviceAgentDoubaoSeedEnableSessionCacheKey];

  id maxStepsObj = [d objectForKey:kOnDeviceAgentMaxStepsKey];
  NSInteger maxSteps = (maxStepsObj == nil) ? kOnDeviceAgentDefaultMaxSteps : (NSInteger)[d integerForKey:kOnDeviceAgentMaxStepsKey];

  id maxCompletionTokensObj = [d objectForKey:kOnDeviceAgentMaxCompletionTokensKey];
  NSInteger maxCompletionTokens = (maxCompletionTokensObj == nil) ? kOnDeviceAgentDefaultMaxCompletionTokens : (NSInteger)[d integerForKey:kOnDeviceAgentMaxCompletionTokensKey];

  id timeoutObj = [d objectForKey:kOnDeviceAgentTimeoutSecondsKey];
  double timeout = (timeoutObj == nil) ? kOnDeviceAgentDefaultTimeoutSeconds : [d doubleForKey:kOnDeviceAgentTimeoutSecondsKey];

  id stepDelayObj = [d objectForKey:kOnDeviceAgentStepDelaySecondsKey];
  double stepDelay = (stepDelayObj == nil) ? kOnDeviceAgentDefaultStepDelaySeconds : [d doubleForKey:kOnDeviceAgentStepDelaySecondsKey];
  BOOL insecure = [d boolForKey:kOnDeviceAgentInsecureSkipTLSVerifyKey];
  id dbgObj = [d objectForKey:kOnDeviceAgentDebugLogRawAssistantKey];
  BOOL debugRaw = (dbgObj == nil) ? NO : [d boolForKey:kOnDeviceAgentDebugLogRawAssistantKey];
  id halfResObj = [d objectForKey:kOnDeviceAgentHalfResScreenshotKey];
  BOOL halfRes = (halfResObj == nil) ? YES : [d boolForKey:kOnDeviceAgentHalfResScreenshotKey];
  id w3cSwipeObj = [d objectForKey:kOnDeviceAgentUseW3CActionsForSwipeKey];
  BOOL w3cSwipe = (w3cSwipeObj == nil) ? YES : [d boolForKey:kOnDeviceAgentUseW3CActionsForSwipeKey];
  id restartObj = [d objectForKey:kOnDeviceAgentRestartResponsesByPlanKey];
  BOOL restartByPlan = (restartObj == nil) ? NO : [d boolForKey:kOnDeviceAgentRestartResponsesByPlanKey];

  self.config[kOnDeviceAgentTaskKey] = task;
  self.config[kOnDeviceAgentBaseURLKey] = baseURL;
  self.config[kOnDeviceAgentModelKey] = model;
  self.config[kOnDeviceAgentApiModeKey] = apiMode.length > 0 ? apiMode : kOnDeviceAgentApiModeResponses;
  self.config[kOnDeviceAgentApiKeyKey] = apiKey;
  self.config[kOnDeviceAgentAgentTokenKey] = agentToken;
  self.config[kOnDeviceAgentRememberApiKeyKey] = @(remember);
  self.config[kOnDeviceAgentUseCustomSystemPromptKey] = @(useCustomSystemPrompt);
  self.config[kOnDeviceAgentCustomSystemPromptKey] = customSystemPrompt;
  self.config[kOnDeviceAgentReasoningEffortKey] = OnDeviceAgentNormalizeReasoningEffort(reasoningEffort);
  self.config[kOnDeviceAgentDoubaoSeedEnableSessionCacheKey] = @(enableDoubaoCache);
  self.config[kOnDeviceAgentMaxCompletionTokensKey] = @(maxCompletionTokens);
  self.config[kOnDeviceAgentMaxStepsKey] = @(maxSteps);
  self.config[kOnDeviceAgentTimeoutSecondsKey] = @(timeout);
  self.config[kOnDeviceAgentStepDelaySecondsKey] = @(stepDelay);
  self.config[kOnDeviceAgentInsecureSkipTLSVerifyKey] = @(insecure);
  self.config[kOnDeviceAgentDebugLogRawAssistantKey] = @(debugRaw);
  self.config[kOnDeviceAgentHalfResScreenshotKey] = @(halfRes);
  self.config[kOnDeviceAgentUseW3CActionsForSwipeKey] = @(w3cSwipe);
  self.config[kOnDeviceAgentRestartResponsesByPlanKey] = @(restartByPlan);
}

- (void)persistConfigToDefaults
{
  NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
  [d setObject:OnDeviceAgentTrim(OnDeviceAgentStringOrEmpty(self.config[kOnDeviceAgentTaskKey])) forKey:kOnDeviceAgentTaskKey];
  [d setObject:OnDeviceAgentTrim(OnDeviceAgentStringOrEmpty(self.config[kOnDeviceAgentBaseURLKey])) forKey:kOnDeviceAgentBaseURLKey];
  [d setObject:OnDeviceAgentTrim(OnDeviceAgentStringOrEmpty(self.config[kOnDeviceAgentModelKey])) forKey:kOnDeviceAgentModelKey];
  NSString *apiMode = OnDeviceAgentNormalizeApiMode(OnDeviceAgentStringOrEmpty(self.config[kOnDeviceAgentApiModeKey]));
  if (apiMode.length == 0) {
    apiMode = kOnDeviceAgentApiModeResponses;
  }
  [d setObject:apiMode forKey:kOnDeviceAgentApiModeKey];

  [d setObject:OnDeviceAgentTrim(OnDeviceAgentStringOrEmpty(self.config[kOnDeviceAgentAgentTokenKey])) forKey:kOnDeviceAgentAgentTokenKey];

  BOOL remember = OnDeviceAgentParseBool(self.config[kOnDeviceAgentRememberApiKeyKey], NO);
  [d setBool:remember forKey:kOnDeviceAgentRememberApiKeyKey];
  if (remember) {
    NSString *key = OnDeviceAgentTrim(OnDeviceAgentStringOrEmpty(self.config[kOnDeviceAgentApiKeyKey]));
    if (key.length > 0) {
      if (!OnDeviceAgentKeychainSet(OnDeviceAgentKeychainService(), kOnDeviceAgentKeychainAccountAPIKey, key)) {
        [FBLogger log:@"[ONDEVICE] Failed to persist API key to Keychain"];
      }
    } else {
      (void)OnDeviceAgentKeychainDelete(OnDeviceAgentKeychainService(), kOnDeviceAgentKeychainAccountAPIKey);
    }
  } else {
    (void)OnDeviceAgentKeychainDelete(OnDeviceAgentKeychainService(), kOnDeviceAgentKeychainAccountAPIKey);
  }
  [d removeObjectForKey:kOnDeviceAgentApiKeyKey];

  [d setBool:OnDeviceAgentParseBool(self.config[kOnDeviceAgentUseCustomSystemPromptKey], NO) forKey:kOnDeviceAgentUseCustomSystemPromptKey];
  NSString *customSystemPrompt = OnDeviceAgentStringOrEmpty(self.config[kOnDeviceAgentCustomSystemPromptKey]);
  if (customSystemPrompt.length > 0) {
    [d setObject:customSystemPrompt forKey:kOnDeviceAgentCustomSystemPromptKey];
  } else {
    [d removeObjectForKey:kOnDeviceAgentCustomSystemPromptKey];
  }

  NSString *reasoningEffort = OnDeviceAgentNormalizeReasoningEffort(OnDeviceAgentStringOrEmpty(self.config[kOnDeviceAgentReasoningEffortKey]));
  if (reasoningEffort.length > 0) {
    [d setObject:reasoningEffort forKey:kOnDeviceAgentReasoningEffortKey];
  } else {
    [d removeObjectForKey:kOnDeviceAgentReasoningEffortKey];
  }

  [d setBool:OnDeviceAgentParseBool(self.config[kOnDeviceAgentDoubaoSeedEnableSessionCacheKey], YES) forKey:kOnDeviceAgentDoubaoSeedEnableSessionCacheKey];

  [d setInteger:OnDeviceAgentParseInt(self.config[kOnDeviceAgentMaxCompletionTokensKey], kOnDeviceAgentDefaultMaxCompletionTokens)
          forKey:kOnDeviceAgentMaxCompletionTokensKey];
  [d setInteger:OnDeviceAgentParseInt(self.config[kOnDeviceAgentMaxStepsKey], kOnDeviceAgentDefaultMaxSteps) forKey:kOnDeviceAgentMaxStepsKey];
  [d setDouble:OnDeviceAgentParseDouble(self.config[kOnDeviceAgentTimeoutSecondsKey], kOnDeviceAgentDefaultTimeoutSeconds)
        forKey:kOnDeviceAgentTimeoutSecondsKey];
  [d setDouble:OnDeviceAgentParseDouble(self.config[kOnDeviceAgentStepDelaySecondsKey], kOnDeviceAgentDefaultStepDelaySeconds)
        forKey:kOnDeviceAgentStepDelaySecondsKey];
  [d setBool:OnDeviceAgentParseBool(self.config[kOnDeviceAgentInsecureSkipTLSVerifyKey], NO) forKey:kOnDeviceAgentInsecureSkipTLSVerifyKey];
  [d setBool:OnDeviceAgentParseBool(self.config[kOnDeviceAgentDebugLogRawAssistantKey], NO) forKey:kOnDeviceAgentDebugLogRawAssistantKey];
  [d setBool:OnDeviceAgentParseBool(self.config[kOnDeviceAgentHalfResScreenshotKey], NO) forKey:kOnDeviceAgentHalfResScreenshotKey];
  [d setBool:OnDeviceAgentParseBool(self.config[kOnDeviceAgentUseW3CActionsForSwipeKey], YES) forKey:kOnDeviceAgentUseW3CActionsForSwipeKey];
  [d setBool:OnDeviceAgentParseBool(self.config[kOnDeviceAgentRestartResponsesByPlanKey], NO) forKey:kOnDeviceAgentRestartResponsesByPlanKey];
  [d synchronize];
}

- (BOOL)updateConfigWithArguments:(NSDictionary *)args errorMessage:(NSString **)message
{
  NSMutableDictionary *next = [self.config mutableCopy] ?: [NSMutableDictionary dictionary];

  NSString *apiMode = OnDeviceAgentTrim(OnDeviceAgentStringOrEmpty(args[@"api_mode"]));
  NSString *task = OnDeviceAgentStringOrEmpty(args[@"task"]);
  NSString *baseURL = OnDeviceAgentStringOrEmpty(args[@"base_url"]);
  NSString *model = OnDeviceAgentStringOrEmpty(args[@"model"]);
  NSString *apiKey = OnDeviceAgentNormalizeApiKey(OnDeviceAgentStringOrEmpty(args[@"api_key"]));
  NSString *agentToken = OnDeviceAgentTrim(OnDeviceAgentStringOrEmpty(args[@"agent_token"]));

  if ([args objectForKey:@"api_mode"] != nil && apiMode.length > 0) {
    if ([apiMode isEqualToString:kOnDeviceAgentApiModeChatCompletions] || [apiMode isEqualToString:kOnDeviceAgentApiModeResponses]) {
      next[kOnDeviceAgentApiModeKey] = apiMode;
    } else {
      if (message) {
        *message = [NSString stringWithFormat:@"Invalid api_mode: %@", apiMode];
      }
      return NO;
    }
  }
  if (task.length > 0) {
    next[kOnDeviceAgentTaskKey] = task;
  }
  if (baseURL.length > 0) {
    next[kOnDeviceAgentBaseURLKey] = baseURL;
  }
  if (model.length > 0) {
    next[kOnDeviceAgentModelKey] = model;
  }
  if (apiKey.length > 0 || [args objectForKey:@"api_key"] != nil) {
    next[kOnDeviceAgentApiKeyKey] = apiKey;
  }
  if ([args objectForKey:@"agent_token"] != nil) {
    next[kOnDeviceAgentAgentTokenKey] = agentToken;
  }

  if ([args objectForKey:@"use_custom_system_prompt"] != nil) {
    next[kOnDeviceAgentUseCustomSystemPromptKey] = @(OnDeviceAgentParseBool(args[@"use_custom_system_prompt"], NO));
  }
  if ([args objectForKey:@"system_prompt"] != nil) {
    next[kOnDeviceAgentCustomSystemPromptKey] = OnDeviceAgentStringOrEmpty(args[@"system_prompt"]);
  }
  if ([args objectForKey:@"reasoning_effort"] != nil) {
    next[kOnDeviceAgentReasoningEffortKey] = OnDeviceAgentNormalizeReasoningEffort(OnDeviceAgentStringOrEmpty(args[@"reasoning_effort"]));
  }
  if ([args objectForKey:@"doubao_seed_enable_session_cache"] != nil) {
    next[kOnDeviceAgentDoubaoSeedEnableSessionCacheKey] = @(OnDeviceAgentParseBool(args[@"doubao_seed_enable_session_cache"], YES));
  }
  if ([args objectForKey:@"remember_api_key"] != nil) {
    next[kOnDeviceAgentRememberApiKeyKey] = @(OnDeviceAgentParseBool(args[@"remember_api_key"], NO));
  }

  if ([args objectForKey:@"max_completion_tokens"] != nil) {
    NSInteger parsed = 0;
    if (!OnDeviceAgentParseIntStrict(args[@"max_completion_tokens"], &parsed) || parsed <= 0) {
      if (message) {
        *message = @"Invalid max_completion_tokens (must be integer > 0)";
      }
      return NO;
    }
    next[kOnDeviceAgentMaxCompletionTokensKey] = @(parsed);
  }
  if ([args objectForKey:@"max_steps"] != nil) {
    NSInteger parsed = 0;
    if (!OnDeviceAgentParseIntStrict(args[@"max_steps"], &parsed) || parsed <= 0) {
      if (message) {
        *message = @"Invalid max_steps (must be integer > 0)";
      }
      return NO;
    }
    next[kOnDeviceAgentMaxStepsKey] = @(parsed);
  }
  if ([args objectForKey:@"timeout_seconds"] != nil) {
    double parsed = 0;
    if (!OnDeviceAgentParseDoubleStrict(args[@"timeout_seconds"], &parsed) || parsed <= 0) {
      if (message) {
        *message = @"Invalid timeout_seconds (must be number > 0)";
      }
      return NO;
    }
    next[kOnDeviceAgentTimeoutSecondsKey] = @(parsed);
  }
  if ([args objectForKey:@"step_delay_seconds"] != nil) {
    double parsed = 0;
    if (!OnDeviceAgentParseDoubleStrict(args[@"step_delay_seconds"], &parsed) || parsed <= 0) {
      if (message) {
        *message = @"Invalid step_delay_seconds (must be number > 0)";
      }
      return NO;
    }
    next[kOnDeviceAgentStepDelaySecondsKey] = @(parsed);
  }

  if ([args objectForKey:@"insecure_skip_tls_verify"] != nil) {
    next[kOnDeviceAgentInsecureSkipTLSVerifyKey] = @(OnDeviceAgentParseBool(args[@"insecure_skip_tls_verify"], NO));
  }
  if ([args objectForKey:@"debug_log_raw_assistant"] != nil) {
    next[kOnDeviceAgentDebugLogRawAssistantKey] = @(OnDeviceAgentParseBool(args[@"debug_log_raw_assistant"], NO));
  }
  if ([args objectForKey:@"half_res_screenshot"] != nil) {
    next[kOnDeviceAgentHalfResScreenshotKey] = @(OnDeviceAgentParseBool(args[@"half_res_screenshot"], YES));
  }
  if ([args objectForKey:@"use_w3c_actions_for_swipe"] != nil) {
    next[kOnDeviceAgentUseW3CActionsForSwipeKey] = @(OnDeviceAgentParseBool(args[@"use_w3c_actions_for_swipe"], YES));
  }
  if ([args objectForKey:@"restart_responses_by_plan"] != nil) {
    next[kOnDeviceAgentRestartResponsesByPlanKey] = @(OnDeviceAgentParseBool(args[@"restart_responses_by_plan"], NO));
  }

  self.config = next.copy;
  [self persistConfigToDefaults];
  return YES;
}

- (NSDictionary *)safeConfigSnapshotWithDefaultSystemPrompt:(BOOL)includeDefaultSystemPrompt
{
  NSMutableDictionary *cfg = [NSMutableDictionary dictionary];
  cfg[@"task"] = OnDeviceAgentStringOrEmpty(self.config[kOnDeviceAgentTaskKey]);
  cfg[@"base_url"] = OnDeviceAgentStringOrEmpty(self.config[kOnDeviceAgentBaseURLKey]);
  cfg[@"model"] = OnDeviceAgentStringOrEmpty(self.config[kOnDeviceAgentModelKey]);
  cfg[@"api_mode"] = OnDeviceAgentStringOrEmpty(self.config[kOnDeviceAgentApiModeKey]);

  BOOL remember = OnDeviceAgentParseBool(self.config[kOnDeviceAgentRememberApiKeyKey], NO);
  NSString *apiKey = OnDeviceAgentStringOrEmpty(self.config[kOnDeviceAgentApiKeyKey]);
  NSString *agentToken = OnDeviceAgentTrim(OnDeviceAgentStringOrEmpty(self.config[kOnDeviceAgentAgentTokenKey]));
  cfg[@"api_key_set"] = @(apiKey.length > 0);
  cfg[@"agent_token_set"] = @(agentToken.length > 0);
  cfg[@"remember_api_key"] = @(remember);

  cfg[@"use_custom_system_prompt"] = @(OnDeviceAgentParseBool(self.config[kOnDeviceAgentUseCustomSystemPromptKey], NO));
  cfg[@"system_prompt"] = OnDeviceAgentStringOrEmpty(self.config[kOnDeviceAgentCustomSystemPromptKey]);
  if (includeDefaultSystemPrompt) {
    cfg[@"default_system_prompt"] = OnDeviceAgentDefaultSystemPromptTemplate();
  }
  cfg[@"reasoning_effort"] = OnDeviceAgentStringOrEmpty(self.config[kOnDeviceAgentReasoningEffortKey]);
  cfg[@"doubao_seed_enable_session_cache"] = @(OnDeviceAgentParseBool(self.config[kOnDeviceAgentDoubaoSeedEnableSessionCacheKey], YES));
  cfg[@"half_res_screenshot"] = @(OnDeviceAgentParseBool(self.config[kOnDeviceAgentHalfResScreenshotKey], YES));
  cfg[@"use_w3c_actions_for_swipe"] = @(OnDeviceAgentParseBool(self.config[kOnDeviceAgentUseW3CActionsForSwipeKey], YES));
  cfg[@"restart_responses_by_plan"] = @(OnDeviceAgentParseBool(self.config[kOnDeviceAgentRestartResponsesByPlanKey], NO));

  cfg[@"max_completion_tokens"] = @(OnDeviceAgentParseInt(self.config[kOnDeviceAgentMaxCompletionTokensKey], kOnDeviceAgentDefaultMaxCompletionTokens));
  cfg[@"max_steps"] = @(OnDeviceAgentParseInt(self.config[kOnDeviceAgentMaxStepsKey], kOnDeviceAgentDefaultMaxSteps));
  cfg[@"timeout_seconds"] = @(OnDeviceAgentParseDouble(self.config[kOnDeviceAgentTimeoutSecondsKey], kOnDeviceAgentDefaultTimeoutSeconds));
  cfg[@"step_delay_seconds"] = @(OnDeviceAgentParseDouble(self.config[kOnDeviceAgentStepDelaySecondsKey], kOnDeviceAgentDefaultStepDelaySeconds));
  cfg[@"insecure_skip_tls_verify"] = @(OnDeviceAgentParseBool(self.config[kOnDeviceAgentInsecureSkipTLSVerifyKey], NO));
  cfg[@"debug_log_raw_assistant"] = @(OnDeviceAgentParseBool(self.config[kOnDeviceAgentDebugLogRawAssistantKey], NO));
  return cfg.copy;
}

- (NSString *)agentToken
{
  __block NSString *token = @"";
  dispatch_sync(self.stateQueue, ^{
    token = OnDeviceAgentTrim(OnDeviceAgentStringOrEmpty(self.config[kOnDeviceAgentAgentTokenKey]));
  });
  return token ?: @"";
}

- (NSDictionary *)status
{
  return [self statusWithDefaultSystemPrompt:NO];
}

- (NSDictionary *)statusWithDefaultSystemPrompt:(BOOL)includeDefaultSystemPrompt
{
  __block NSDictionary *st = nil;
  dispatch_sync(self.stateQueue, ^{
    NSString *notes = self.notes ?: @"";
    NSDictionary *tokens = self.tokenUsage ?: @{};
    if (self.agent != nil) {
      notes = self.agent.workingNote ?: @"";
      self.notes = notes;
      tokens = [self.agent tokenUsageSnapshot] ?: @{};
      self.tokenUsage = tokens;
    }
    st = @{
      @"running": @(self.running),
      @"last_message": self.lastMessage ?: @"",
      @"config": [self safeConfigSnapshotWithDefaultSystemPrompt:includeDefaultSystemPrompt],
      @"notes": notes,
      @"token_usage": tokens,
      @"log_lines": @(self.logLines.count),
    };
  });
  return st ?: @{};
}

- (NSArray<NSString *> *)logs
{
  __block NSArray<NSString *> *lines = nil;
  dispatch_sync(self.stateQueue, ^{
    lines = self.logLines.copy;
  });
  return lines ?: @[];
}

- (NSArray<NSDictionary *> *)chat
{
  __block NSArray<NSDictionary *> *items = nil;
  dispatch_sync(self.stateQueue, ^{
    items = self.chatItems.copy;
  });
  return items ?: @[];
}

- (BOOL)isConfigValid:(NSDictionary *)cfg message:(NSString **)message
{
  NSString *task = OnDeviceAgentTrim(OnDeviceAgentStringOrEmpty(cfg[kOnDeviceAgentTaskKey]));
  NSString *baseURL = OnDeviceAgentTrim(OnDeviceAgentStringOrEmpty(cfg[kOnDeviceAgentBaseURLKey]));
  NSString *model = OnDeviceAgentTrim(OnDeviceAgentStringOrEmpty(cfg[kOnDeviceAgentModelKey]));
  if (task.length == 0 || baseURL.length == 0 || model.length == 0) {
    if (message) {
      *message = @"Missing task/base_url/model";
    }
    return NO;
  }

  NSInteger maxSteps = 0;
  if (!OnDeviceAgentParseIntStrict(cfg[kOnDeviceAgentMaxStepsKey], &maxSteps) || maxSteps <= 0) {
    if (message) {
      *message = @"Invalid max_steps (must be integer > 0)";
    }
    return NO;
  }

  double timeout = 0;
  if (!OnDeviceAgentParseDoubleStrict(cfg[kOnDeviceAgentTimeoutSecondsKey], &timeout) || timeout <= 0) {
    if (message) {
      *message = @"Invalid timeout_seconds (must be number > 0)";
    }
    return NO;
  }

  double stepDelay = 0;
  if (!OnDeviceAgentParseDoubleStrict(cfg[kOnDeviceAgentStepDelaySecondsKey], &stepDelay) || stepDelay <= 0) {
    if (message) {
      *message = @"Invalid step_delay_seconds (must be number > 0)";
    }
    return NO;
  }

  NSInteger maxTokens = 0;
  if (!OnDeviceAgentParseIntStrict(cfg[kOnDeviceAgentMaxCompletionTokensKey], &maxTokens) || maxTokens <= 0) {
    if (message) {
      *message = @"Invalid max_completion_tokens (must be integer > 0)";
    }
    return NO;
  }
  return YES;
}

- (BOOL)startWithArguments:(NSDictionary *)args error:(NSError **)error
{
  __block BOOL ok = YES;
  __block NSError *err = nil;

  dispatch_sync(self.stateQueue, ^{
    NSString *updateErr = nil;
    if (![self updateConfigWithArguments:args ?: @{} errorMessage:&updateErr]) {
      ok = NO;
      err = [NSError errorWithDomain:@"OnDeviceAgent" code:22 userInfo:@{NSLocalizedDescriptionKey: updateErr ?: @"Invalid config update"}];
      return;
    }

    if (self.running) {
      ok = NO;
      err = [NSError errorWithDomain:@"OnDeviceAgent" code:20 userInfo:@{NSLocalizedDescriptionKey: @"Already running"}];
      return;
    }

    NSString *msg = nil;
    if (![self isConfigValid:self.config message:&msg]) {
      ok = NO;
      err = [NSError errorWithDomain:@"OnDeviceAgent" code:21 userInfo:@{NSLocalizedDescriptionKey: msg ?: @"Invalid config"}];
      return;
    }

    self.runTokenCounter += 1;
    NSInteger token = self.runTokenCounter;
    self.activeRunToken = token;
    self.running = YES;
    self.lastMessage = @"Started";
    self.notes = @"";
    self.tokenUsage = @{};
    [self.chatItems removeAllObjects];
    [self.stepScreenshots removeAllObjects];
    [self.stepScreenshotOrder removeAllObjects];

    __weak __typeof(self) weakSelf = self;
    OnDeviceAgentLogBlock log = ^(NSString *line) {
      __strong __typeof(weakSelf) strongSelf = weakSelf;
      if (strongSelf == nil) {
        return;
      }
      [strongSelf appendLog:line token:token];
    };
    OnDeviceAgentChatBlock chat = ^(NSDictionary *item) {
      __strong __typeof(weakSelf) strongSelf = weakSelf;
      if (strongSelf == nil) {
        return;
      }
      [strongSelf appendChatItem:item token:token];
    };
    OnDeviceAgentScreenshotBlock screenshot = ^(NSInteger step, NSData *png) {
      __strong __typeof(weakSelf) strongSelf = weakSelf;
      if (strongSelf == nil) {
        return;
      }
      [strongSelf storeStepScreenshotPNG:png step:step token:token];
    };
	    OnDeviceAgentFinishBlock finish = ^(BOOL success, NSString *message) {
	      __strong __typeof(weakSelf) strongSelf = weakSelf;
	      if (strongSelf == nil) {
	        return;
	      }
	      NSString *finalMessage = message ?: (success ? @"Finished" : @"Stopped");
	      [strongSelf appendLog:OnDeviceAgentLogJSONLine(success ? @"info" : @"error", @"runner", @"run_finished", finalMessage, @{@"success": @(success)}) token:token];
	      dispatch_async(strongSelf.stateQueue, ^{
	        if (token != strongSelf.activeRunToken) {
	          return;
	        }
        strongSelf.running = NO;
        strongSelf.lastMessage = finalMessage;
        OnDeviceAgentScheduleRunEndedNotification(finalMessage);
        if (strongSelf.agent != nil) {
          strongSelf.notes = strongSelf.agent.workingNote ?: (strongSelf.notes ?: @"");
          strongSelf.tokenUsage = [strongSelf.agent tokenUsageSnapshot] ?: (strongSelf.tokenUsage ?: @{});
        }
        strongSelf.agent = nil;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
          [[OnDeviceAgentEventHub shared] broadcastJSONObject:[strongSelf status] event:@"status"];
        });
      });
	    };

	    self.agent = [[OnDeviceAgent alloc] initWithConfig:self.config log:log chat:chat screenshot:screenshot finish:finish];
	    [self appendLog:OnDeviceAgentLogJSONLine(@"info", @"runner", @"run_started", nil, nil) token:token];
	    [self.agent start];
	  });

  if (!ok && error) {
    *error = err;
  }
  if (ok) {
    NSDictionary *snapshot = @{
      @"status": [self status],
      @"logs": [self logs],
      @"chat": [self chat],
    };
    [[OnDeviceAgentEventHub shared] broadcastJSONObject:snapshot event:@"snapshot"];
  }
  return ok;
}

- (void)stop
{
  dispatch_sync(self.stateQueue, ^{
    if (!self.running || self.agent == nil) {
      self.lastMessage = @"Not running";
      return;
    }
    self.lastMessage = @"Stopping...";
    [self.agent requestStop];
  });

  [[OnDeviceAgentEventHub shared] broadcastJSONObject:[self status] event:@"status"];
}

@end

static NSString *OnDeviceAgentPageHTML(void)
{
  static NSString *const kOnDeviceAgentPageHTMLHead =
    @"<!doctype html>\n"
    @"<html>\n"
    @"<head>\n"
    @"  <meta charset=\"utf-8\" />\n"
    @"  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1, viewport-fit=cover\" />\n"
    @"  <title>iOS WDA On‑Device Agent</title>\n"
    @"  <style>\n";

  static NSString *const kOnDeviceAgentPageCSS =
    @"    :root{color-scheme:light dark;--bg:#fff;--fg:#111;--muted:#666;--card:#f6f6f6;--border:#ccc;--primary:#0a84ff;--danger:#ff3b30;--radius:12px;}\n"
    @"    @media (prefers-color-scheme: dark){:root{--bg:#0b0b0c;--fg:#f2f2f2;--muted:#b0b0b0;--card:#1c1c1e;--border:#3a3a3c;--primary:#0a84ff;--danger:#ff453a;}}\n"
    @"    html,body{height:100%;}\n"
    @"    body{font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Roboto,Helvetica,Arial,sans-serif;background:var(--bg);color:var(--fg);margin:0;padding:16px;padding-left:max(16px,env(safe-area-inset-left));padding-right:max(16px,env(safe-area-inset-right));padding-top:max(16px,env(safe-area-inset-top));padding-bottom:max(16px,env(safe-area-inset-bottom));}\n"
    @"    .container{max-width:900px;margin:0 auto;}\n"
    @"    h2{margin:0 0 8px 0;font-size:20px;}\n"
    @"    h3{margin:16px 0 8px 0;font-size:16px;}\n"
    @"    label{display:block;margin-top:12px;font-weight:600;}\n"
    @"    .label-row{display:flex;align-items:center;justify-content:space-between;gap:10px;margin-top:12px;flex-wrap:wrap;}\n"
    @"    .label-row > label:not(.check){margin:0;font-weight:600;}\n"
    @"    .label-row > .check{margin-top:0;}\n"
    @"    .label-actions{display:flex;align-items:center;justify-content:flex-end;gap:8px;flex-wrap:wrap;}\n"
    @"    .btn-sm{min-height:32px;padding:6px 10px;border-radius:10px;flex:0 0 auto;font-size:13px;}\n"
    @"    input,textarea,select{width:100%;padding:10px 12px;border:1px solid var(--border);border-radius:var(--radius);box-sizing:border-box;font-family:inherit;font-size:16px;background:var(--card);color:inherit;}\n"
    @"    input:focus,textarea:focus,select:focus{outline:none;border-color:var(--primary);box-shadow:0 0 0 3px rgba(10,132,255,0.25);}\n"
    @"    textarea{min-height:120px;resize:vertical;}\n"
    @"    .mono{font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,\"Liberation Mono\",\"Courier New\",monospace;}\n"
    @"    .row{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:12px;}\n"
    @"    @media (max-width: 680px){.row{grid-template-columns:1fr;}}\n"
    @"    .actions{display:flex;flex-wrap:wrap;gap:10px;margin-top:12px;}\n"
    @"    button{min-height:44px;padding:10px 14px;border:0;border-radius:12px;flex:1 1 120px;}\n"
    @"    .primary{background:var(--primary);color:#fff;}\n"
    @"    .danger{background:var(--danger);color:#fff;}\n"
    @"    .ghost{background:var(--card);color:inherit;border:1px solid var(--border);}\n"
	    @"    .muted{color:var(--muted);font-size:13px;line-height:1.45;}\n"
	    @"    .callout{margin-top:10px;border:1px solid var(--border);background:var(--card);border-radius:var(--radius);padding:10px 12px;}\n"
	    @"    .callout-row{display:flex;align-items:flex-start;justify-content:space-between;gap:10px;}\n"
	    @"    .callout-text{font-size:13px;line-height:1.45;color:var(--muted);}\n"
	    @"    .callout-text code{font-size:12px;}\n"
	    @"    .callout-btn{min-height:32px;padding:6px 10px;border-radius:10px;flex:0 0 auto;font-size:13px;}\n"
    @"    .error{color:var(--danger);font-size:13px;line-height:1.45;margin-top:10px;white-space:pre-wrap;}\n"
    @"    input.invalid,textarea.invalid,select.invalid{border-color:var(--danger);box-shadow:0 0 0 3px rgba(255,59,48,0.18);}\n"
    @"    .check{display:flex;align-items:center;gap:10px;margin-top:10px;user-select:none;}\n"
    @"    .check input{width:auto;transform:scale(1.15);}\n"
    @"    code{font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,\"Liberation Mono\",\"Courier New\",monospace;font-size:13px;background:var(--card);padding:2px 6px;border-radius:8px;overflow-wrap:anywhere;}\n"
    @"    pre{background:var(--card);border:1px solid var(--border);padding:10px;border-radius:var(--radius);white-space:pre-wrap;overflow-wrap:anywhere;word-break:break-word;max-height:40vh;overflow:auto;-webkit-overflow-scrolling:touch;font-size:16px;line-height:1.35;}\n"
    @"    #system_prompt{font-size:16px;line-height:1.35;min-height:260px;}\n"
    @"    .placeholder-grid{display:grid;grid-template-columns:auto 1fr;gap:6px 10px;align-items:start;margin-top:6px;}\n"
    @"    .placeholder-grid .ex{overflow-wrap:anywhere;word-break:break-word;}\n"
    @"    @media (max-width: 520px){.placeholder-grid{grid-template-columns:1fr;}}\n"
    @"    button:disabled{opacity:0.55;}\n"
    @"    .chips{display:flex;flex-wrap:wrap;gap:8px;margin-top:10px;}\n"
    @"    .chip{font-size:12px;line-height:1.2;padding:5px 10px;border-radius:999px;border:1px solid var(--border);background:var(--card);}\n"
    @"    .chip.ok{border-color:rgba(10,132,255,0.35);}\n"
    @"    .chip.bad{border-color:rgba(255,59,48,0.35);color:var(--danger);}\n"
    @"    .readiness-detail{white-space:pre-wrap;}\n"
    @"    .chat{display:flex;flex-direction:column;gap:10px;}\n"
    @"    .step-card{border:1px solid var(--border);background:var(--card);border-radius:var(--radius);overflow:hidden;}\n"
    @"    .step-card > summary{cursor:pointer;list-style:none;padding:10px 12px;font-weight:600;}\n"
    @"    .step-card > summary::-webkit-details-marker{display:none;}\n"
    @"    .step-card[open] > summary{border-bottom:1px solid var(--border);}\n"
    @"    .step-body{padding:10px 12px;display:flex;flex-direction:column;gap:10px;}\n"
    @"    .shot{width:100%;border:1px solid var(--border);border-radius:var(--radius);display:block;}\n"
    @"    .msg{border:1px solid var(--border);border-radius:var(--radius);background:var(--bg);padding:10px 10px;}\n"
    @"    .msg-hdr{font-size:12px;color:var(--muted);margin-bottom:6px;display:flex;gap:8px;flex-wrap:wrap;}\n"
    @"    .msg pre{background:transparent;border:0;padding:0;margin:0;max-height:none;overflow:visible;font-size:15px;line-height:1.35;}\n"
    @"    details.raw > summary{cursor:pointer;color:var(--muted);font-size:12px;}\n"
    @"    details.raw > pre{margin-top:8px;}\n"
    @"  </style>\n";

  static NSString *const kOnDeviceAgentPageBody =
    @"</head>\n"
    @"<body>\n"
    @"  <div class=\"container\">\n"
	    @"    <h2 data-i18n=\"h_title\">iOS WDA On‑Device Agent (WDA Runner)</h2>\n"
		    @"    <div class=\"muted\">\n"
		    @"      <div data-i18n-html=\"intro_1\">This page configures and starts an agent running <b>inside</b> WebDriverAgentRunner (XCTest).</div>\n"
		    @"      <div data-i18n-html=\"intro_2\">If LAN access fails, try opening this page with <code>http://127.0.0.1:8100/agent</code> on the iPhone.</div>\n"
		    @"      <div data-i18n-html=\"wireless_hint_short\">Tip: If LAN access is unreachable, enable Runner <b>Wireless Data</b> in iPhone Settings, then reopen Runner.</div>\n"
		    @"    </div>\n"
        @"    <h3 data-i18n=\"h_access\">Access</h3>\n"
        @"    <div class=\"callout\">\n"
        @"      <div class=\"callout-row\">\n"
        @"        <div class=\"callout-text\" data-i18n-html=\"help_agent_token\">Agent Token protects <code>/agent/*</code> over Wi‑Fi/LAN. Rotate it to invalidate existing sessions.</div>\n"
        @"        <button type=\"button\" class=\"ghost callout-btn\" onclick=\"rotateToken()\" data-i18n=\"btn_rotate_token\">Rotate token</button>\n"
        @"      </div>\n"
        @"      <div id=\"rotate_token_row\" style=\"display:none;margin-top:10px\">\n"
        @"        <label style=\"margin-top:0\" data-i18n=\"label_new_token\">New token</label>\n"
        @"        <div style=\"display:flex;gap:8px;align-items:center;flex-wrap:wrap;\">\n"
        @"          <input id=\"rotate_token_value\" class=\"mono\" readonly style=\"flex:1 1 240px;\" />\n"
        @"          <button type=\"button\" class=\"ghost btn-sm\" onclick=\"copyRotatedToken()\" data-i18n=\"btn_copy\">Copy</button>\n"
        @"        </div>\n"
        @"        <div class=\"muted\" style=\"margin-top:6px\" data-i18n=\"help_new_token\">Keep this token secret. Anyone with it can access /agent/* over LAN.</div>\n"
        @"      </div>\n"
        @"    </div>\n"
	    @"    <label data-i18n=\"label_base_url\">Base URL (OpenAI-compatible)</label>\n"
    @"    <input id=\"base_url\" class=\"mono\" placeholder=\"https://...\" autocapitalize=\"none\" autocorrect=\"off\" spellcheck=\"false\" />\n"
    @"    <label data-i18n=\"label_model\">Model</label>\n"
    @"    <input id=\"model\" class=\"mono\" placeholder=\"gpt-4o-mini / ...\" autocapitalize=\"none\" autocorrect=\"off\" spellcheck=\"false\" />\n"
    @"    <label data-i18n=\"label_api_mode\">API Mode</label>\n"
    @"    <select id=\"api_mode\" class=\"ghost\" style=\"width:100%;min-height:44px;padding:10px 12px;border-radius:var(--radius);\">\n"
    @"      <option value=\"responses\" data-i18n=\"opt_responses\">Responses</option>\n"
    @"      <option value=\"chat_completions\" data-i18n=\"opt_chat_completions\">Chat Completions</option>\n"
    @"    </select>\n"
    @"    <div id=\"doubao_seed_cache_row\" style=\"display:none\">\n"
    @"      <label class=\"check muted\"><input type=\"checkbox\" id=\"doubao_seed_enable_session_cache\" checked /> <span data-i18n=\"cb_doubao_cache\">Enable Session Cache (Doubao Seed)</span></label>\n"
    @"    </div>\n"
    @"    <label data-i18n=\"label_api_key\">API Key</label>\n"
    @"    <input id=\"api_key\" class=\"mono\" type=\"password\" placeholder=\"sk-...\" autocapitalize=\"none\" autocorrect=\"off\" spellcheck=\"false\" autocomplete=\"off\" />\n"
    @"    <label class=\"check muted\"><input type=\"checkbox\" id=\"show_api_key\" /> <span data-i18n=\"cb_show_api_key\">Show API key</span></label>\n"
    @"    <label class=\"check muted\"><input type=\"checkbox\" id=\"remember_api_key\" /> <span data-i18n=\"cb_remember_api_key\">Remember API key on device (NOT recommended for shared devices)</span></label>\n"
    @"    <div class=\"label-row\">\n"
    @"      <label for=\"task\" data-i18n=\"label_task\">Task</label>\n"
    @"      <div class=\"label-actions\">\n"
    @"        <button type=\"button\" class=\"ghost btn-sm\" onclick=\"openEditorPage('task')\" data-i18n=\"btn_edit_page\">Edit Page</button>\n"
    @"      </div>\n"
    @"    </div>\n"
    @"    <textarea id=\"task\" placeholder=\"Describe what to do... (e.g., open Xiaohongshu and ...)\" data-i18n-placeholder=\"ph_task\"></textarea>\n"
    @"    <div class=\"row\">\n"
    @"      <div>\n"
    @"        <label data-i18n=\"label_max_steps\">Max Steps (&gt;0)</label>\n"
    @"        <input id=\"max_steps\" placeholder=\"__DEFAULT_MAX_STEPS__\" inputmode=\"numeric\" />\n"
    @"      </div>\n"
    @"      <div>\n"
    @"        <label data-i18n=\"label_timeout\">Timeout (seconds, &gt;0)</label>\n"
    @"        <input id=\"timeout_seconds\" placeholder=\"__DEFAULT_TIMEOUT_SECONDS__\" inputmode=\"numeric\" />\n"
    @"      </div>\n"
    @"      <div>\n"
    @"        <label data-i18n=\"label_step_delay\">Step Delay (seconds, &gt;0)</label>\n"
    @"        <input id=\"step_delay_seconds\" placeholder=\"__DEFAULT_STEP_DELAY_SECONDS__\" inputmode=\"decimal\" />\n"
    @"      </div>\n"
    @"    </div>\n"
    @"    <label id=\"max_tokens_label\">Max Completion Tokens (&gt;0)</label>\n"
    @"    <input id=\"max_completion_tokens\" placeholder=\"__DEFAULT_MAX_COMPLETION_TOKENS__\" inputmode=\"numeric\" />\n"
    @"    <label data-i18n=\"label_reasoning_effort\">Reasoning Effort</label>\n"
    @"    <input id=\"reasoning_effort\" class=\"mono\" placeholder=\"(default) e.g. minimal / low / medium / high\" data-i18n-placeholder=\"ph_reasoning_effort\" autocapitalize=\"none\" autocorrect=\"off\" spellcheck=\"false\" />\n"
    @"    <h3 data-i18n=\"h_system_prompt\">System Prompt</h3>\n"
    @"    <div class=\"muted\">\n"
    @"      <div data-i18n=\"help_system_prompt\">Custom system prompt only takes effect when the checkbox is enabled. Date placeholders (replaced at runtime):</div>\n"
    @"      <div class=\"placeholder-grid\">\n"
    @"        <div><code>{{DATE_ZH}}</code></div><div class=\"ex\">-&gt; __DATE_ZH_EXAMPLE__</div>\n"
    @"        <div><code>{{DATE_EN}}</code></div><div class=\"ex\">-&gt; __DATE_EN_EXAMPLE__</div>\n"
    @"      </div>\n"
    @"    </div>\n"
    @"    <div class=\"label-row\" style=\"margin-top:10px\">\n"
    @"      <label class=\"check muted\"><input type=\"checkbox\" id=\"use_custom_system_prompt\" /> <span data-i18n=\"cb_use_custom_system_prompt\">Use custom system prompt</span></label>\n"
    @"      <div class=\"label-actions\">\n"
    @"        <button type=\"button\" class=\"ghost btn-sm\" onclick=\"restoreSystemPromptDefault()\" data-i18n=\"btn_restore_system_prompt\">Restore default template</button>\n"
    @"        <button type=\"button\" class=\"ghost btn-sm\" onclick=\"openEditorPage('system_prompt')\" data-i18n=\"btn_edit_page\">Edit Page</button>\n"
    @"      </div>\n"
    @"    </div>\n"
    @"    <textarea id=\"system_prompt\" class=\"mono\" placeholder=\"(default system prompt)\" data-i18n-placeholder=\"ph_system_prompt\"></textarea>\n"
    @"    <label class=\"check muted\"><input type=\"checkbox\" id=\"insecure_skip_tls_verify\" /> <span data-i18n=\"cb_insecure_skip_tls\">Insecure TLS (model requests only)</span></label>\n"
    @"    <label class=\"check muted\"><input type=\"checkbox\" id=\"half_res_screenshot\" /> <span data-i18n=\"cb_half_res_screenshot\">Half-resolution screenshots</span></label>\n"
    @"    <label class=\"check muted\"><input type=\"checkbox\" id=\"use_w3c_actions_for_swipe\" /> <span data-i18n=\"cb_use_w3c_actions_for_swipe\">Use W3C actions for swipe</span></label>\n"
    @"    <label class=\"check muted\"><input type=\"checkbox\" id=\"restart_responses_by_plan\" /> <span data-i18n=\"cb_restart_responses_by_plan\">Restart history when a plan item completes (Responses)</span></label>\n"
    @"    <label class=\"check muted\"><input type=\"checkbox\" id=\"debug_log_raw_assistant\" /> <span data-i18n=\"cb_debug_raw\">Debug raw conversation (sensitive fields redacted)</span></label>\n"
    @"    <div id=\"form_error\" class=\"error\" style=\"display:none\"></div>\n"
    @"    <div id=\"readiness\" class=\"chips\" style=\"display:none\"></div>\n"
    @"    <div id=\"readiness_detail\" class=\"muted readiness-detail\" style=\"display:none\"></div>\n"
    @"    <pre id=\"token_summary\" class=\"muted\" style=\"display:none\"></pre>\n"
    @"    <div class=\"actions\">\n"
    @"      <button id=\"btn_save\" class=\"primary\" onclick=\"saveCfg()\" data-i18n=\"btn_save\">Save</button>\n"
    @"      <button id=\"btn_start\" class=\"primary\" onclick=\"start()\" data-i18n=\"btn_start\">Start</button>\n"
    @"      <button id=\"btn_stop\" class=\"danger\" onclick=\"stop()\" data-i18n=\"btn_stop\">Stop</button>\n"
    @"      <button id=\"btn_reset\" class=\"ghost\" onclick=\"resetAll()\" data-i18n=\"btn_reset\">Reset</button>\n"
    @"    </div>\n"
    @"    <h3 data-i18n=\"h_status\">Status</h3>\n"
    @"    <pre id=\"status\">Loading...</pre>\n"
    @"    <h3 data-i18n=\"h_notes\">Notes</h3>\n"
    @"    <pre id=\"notes\"></pre>\n"
    @"    <h3 data-i18n=\"h_conversation\">Conversation</h3>\n"
    @"    <div class=\"muted\" style=\"display:flex;gap:10px;align-items:center;flex-wrap:wrap;\">\n"
    @"      <span data-i18n=\"label_view\">View:</span>\n"
    @"      <select id=\"chat_mode\" class=\"ghost\" style=\"flex:0 0 auto;min-height:38px;padding:6px 10px;border-radius:var(--radius);\">\n"
    @"        <option value=\"structured\" data-i18n=\"opt_structured\">Structured</option>\n"
    @"        <option value=\"raw\" data-i18n=\"opt_raw\">Raw (request/response)</option>\n"
    @"      </select>\n"
    @"      <label class=\"check muted\" style=\"margin-top:0\"><input type=\"checkbox\" id=\"chat_show_screenshots\" /> <span data-i18n=\"cb_show_screenshots\">Show screenshots</span></label>\n"
    @"      <span data-i18n=\"help_raw_view\">Raw shows per-turn API request/response JSON (history content omitted; images are placeholders).</span>\n"
    @"    </div>\n"
    @"    <div id=\"chat\" class=\"chat\"></div>\n"
    @"    <h3 data-i18n=\"h_logs\">Logs</h3>\n"
    @"    <div id=\"logs\" class=\"chat\"></div>\n"
    @"  </div>\n"
    @"  <script>\n";

  static NSString *const kOnDeviceAgentPageJS =
    @"    const DEFAULT_SYSTEM_PROMPT = __DEFAULT_SYSTEM_PROMPT_JSON__;\n"
    @"    const LANG = ((navigator.language || '').toLowerCase().startsWith('zh')) ? 'zh' : 'en';\n"
    @"    const I18N = {\n"
    @"      en: {\n"
    @"        page_title: 'iOS WDA On‑Device Agent',\n"
    @"        h_title: 'iOS WDA On‑Device Agent (WDA Runner)',\n"
    @"        intro_1: 'This page configures and starts an agent running <b>inside</b> WebDriverAgentRunner (XCTest).',\n"
    @"        intro_2: 'If LAN access fails, try opening this page with <code>http://127.0.0.1:8100/agent</code> on the iPhone.',\n"
    @"        wireless_hint_short: 'Tip: If LAN access is unreachable, enable Runner <b>Wireless Data</b> in iPhone Settings, then reopen Runner.',\n"
        @"        h_access: 'Access',\n"
        @"        help_agent_token: 'Agent Token protects <code>/agent/*</code> over Wi‑Fi/LAN. Rotate it to invalidate existing sessions.',\n"
        @"        btn_rotate_token: 'Rotate token',\n"
        @"        label_new_token: 'New token',\n"
        @"        help_new_token: 'Keep this token secret. Anyone with it can access /agent/* over LAN.',\n"
        @"        btn_copy: 'Copy',\n"
    @"        label_base_url: 'Base URL (OpenAI-compatible)',\n"
    @"        label_model: 'Model',\n"
        @"        label_api_mode: 'API Mode',\n"
        @"        opt_chat_completions: 'Chat Completions',\n"
        @"        opt_responses: 'Responses',\n"
        @"        cb_doubao_cache: 'Enable Session Cache (Doubao Seed)',\n"
    @"        label_api_key: 'API Key',\n"
    @"        cb_show_api_key: 'Show API key',\n"
    @"        cb_remember_api_key: 'Remember API key on device (NOT recommended for shared devices)',\n"
    @"        ph_api_key_set: '(set)',\n"
    @"        label_task: 'Task',\n"
    @"        btn_edit_page: 'Edit Page',\n"
    @"        ph_task: 'Describe what to do... (e.g., open Xiaohongshu and ...)',\n"
    @"        label_max_steps: 'Max Steps (>0)',\n"
    @"        label_timeout: 'Timeout (seconds, >0)',\n"
    @"        label_step_delay: 'Step Delay (seconds, >0)',\n"
    @"        label_max_output_tokens_gt0: 'Max Output Tokens (>0)',\n"
    @"        label_max_completion_tokens_gt0: 'Max Completion Tokens (>0)',\n"
    @"        label_max_output_tokens: 'Max Output Tokens',\n"
    @"        label_max_completion_tokens: 'Max Completion Tokens',\n"
    @"        label_reasoning_effort: 'Reasoning Effort',\n"
    @"        ph_reasoning_effort: '(default) e.g. minimal / low / medium / high',\n"
    @"        h_system_prompt: 'System Prompt',\n"
    @"        help_system_prompt: 'Custom system prompt only takes effect when the checkbox is enabled. Date placeholders (replaced at runtime):',\n"
    @"        cb_use_custom_system_prompt: 'Use custom system prompt',\n"
        @"        btn_restore_system_prompt: 'Restore default template',\n"
        @"        ph_system_prompt: '(default system prompt)',\n"
        @"        cb_insecure_skip_tls: 'Insecure TLS (model requests only; debug only; MITM risk)',\n"
        @"        cb_half_res_screenshot: 'Half-resolution screenshots',\n"
        @"        cb_use_w3c_actions_for_swipe: 'Use W3C actions for swipe',\n"
        @"        cb_restart_responses_by_plan: 'Restart history when a plan item completes (Responses)',\n"
        @"        cb_debug_raw: 'Debug raw conversation (OFF by default; API key / Authorization / image base64 are redacted)',\n"
    @"        btn_save: 'Save',\n"
    @"        btn_start: 'Start',\n"
    @"        btn_stop: 'Stop',\n"
    @"        btn_reset: 'Reset',\n"
    @"        h_status: 'Status',\n"
    @"        h_notes: 'Notes',\n"
    @"        h_conversation: 'Conversation',\n"
    @"        label_view: 'View:',\n"
    @"        opt_structured: 'Structured',\n"
    @"        opt_raw: 'Raw (request/response)',\n"
    @"        cb_show_screenshots: 'Show screenshots',\n"
    @"        help_raw_view: 'Raw shows per-turn API request/response JSON (history content omitted; images are placeholders).',\n"
    @"        h_logs: 'Logs',\n"
    @"        chip_runner_ok: 'Runner reachable',\n"
    @"        chip_runner_bad: 'Runner unreachable',\n"
    @"        chip_auth_ok: 'Auth OK',\n"
    @"        chip_auth_bad: 'LAN requires token',\n"
    @"        chip_config_ok: 'Config OK',\n"
    @"        chip_config_bad: 'Config incomplete',\n"
    @"        chip_key_ok: 'API key OK',\n"
    @"        chip_key_bad: 'API key missing',\n"
    @"        chip_running: 'Running',\n"
    @"        chip_stopped: 'Stopped',\n"
    @"        err_base_url_required: 'Base URL is required',\n"
    @"        err_model_required: 'Model is required',\n"
    @"        err_task_required: 'Task is required',\n"
    @"        err_api_key_required: 'API Key is required',\n"
    @"        err_agent_token_required: 'Agent Token is required for LAN access',\n"
    @"        err_unauthorized: 'Unauthorized (missing/invalid Agent Token)',\n"
    @"        err_network: 'Network error',\n"
    @"        err_max_steps_gt0: 'Max Steps must be > 0',\n"
    @"        err_timeout_gt0: 'Timeout (seconds) must be > 0',\n"
    @"        err_step_delay_gt0: 'Step Delay (seconds) must be > 0',\n"
    @"        err_must_be_gt0: 'must be > 0',\n"
    @"        word_step: 'Step',\n"
    @"        word_attempt: 'attempt',\n"
    @"        sep_reasoning: '--- reasoning ---',\n"
    @"        sep_content: '--- content ---',\n"
    @"        raw_disabled: '<raw capture disabled>',\n"
    @"      },\n"
    @"      zh: {\n"
    @"        page_title: 'iOS WDA 设备端智能体',\n"
    @"        h_title: 'iOS WDA 设备端智能体（WDA Runner）',\n"
    @"        intro_1: '此页面用于配置并启动一个运行在 <b>WebDriverAgentRunner (XCTest)</b> 内部的智能体。',\n"
    @"        intro_2: '如果局域网访问失败，请在 iPhone 上用 <code>http://127.0.0.1:8100/agent</code> 打开此页面。',\n"
    @"        wireless_hint_short: '提示：如果局域网不可达，请在 iPhone 设置中为 Runner 开启<b>无线数据</b>，然后重新打开 Runner。',\n"
        @"        h_access: '访问控制',\n"
        @"        help_agent_token: 'Agent Token 用于保护局域网中的 <code>/agent/*</code>。旋转 token 会使已存在的会话失效。',\n"
        @"        btn_rotate_token: '旋转 token',\n"
        @"        label_new_token: '新 token',\n"
        @"        help_new_token: '请妥善保管。任何人拿到它都可以在局域网中访问 /agent/*。',\n"
        @"        btn_copy: '复制',\n"
    @"        label_base_url: 'Base URL（OpenAI 兼容）',\n"
    @"        label_model: '模型',\n"
        @"        label_api_mode: 'API 模式',\n"
        @"        opt_chat_completions: 'Chat Completions',\n"
        @"        opt_responses: 'Responses',\n"
        @"        cb_doubao_cache: '启用会话缓存（豆包 Seed）',\n"
    @"        label_api_key: 'API Key',\n"
    @"        cb_show_api_key: '显示 API key',\n"
    @"        cb_remember_api_key: '在设备上记住 API key（不建议共享设备）',\n"
    @"        ph_api_key_set: '（已设置）',\n"
    @"        label_task: '任务',\n"
    @"        btn_edit_page: '编辑页',\n"
    @"        ph_task: '描述要做什么……（例如：打开小红书并……）',\n"
    @"        label_max_steps: '最大步数（>0）',\n"
    @"        label_timeout: '超时（秒，>0）',\n"
    @"        label_step_delay: '步间延迟（秒，>0）',\n"
    @"        label_max_output_tokens_gt0: '最大输出 tokens（>0）',\n"
    @"        label_max_completion_tokens_gt0: '最大 completion tokens（>0）',\n"
    @"        label_max_output_tokens: '最大输出 tokens',\n"
    @"        label_max_completion_tokens: '最大 completion tokens',\n"
    @"        label_reasoning_effort: '思考强度',\n"
    @"        ph_reasoning_effort: '（默认）例如：minimal / low / medium / high',\n"
    @"        h_system_prompt: '系统提示词',\n"
    @"        help_system_prompt: '自定义系统提示词仅在勾选后生效。日期占位符（运行时替换）：',\n"
    @"        cb_use_custom_system_prompt: '使用自定义系统提示词',\n"
        @"        btn_restore_system_prompt: '恢复默认模板',\n"
        @"        ph_system_prompt: '（默认系统提示词）',\n"
        @"        cb_insecure_skip_tls: '不安全 TLS（仅模型请求；仅调试；有中间人风险）',\n"
        @"        cb_half_res_screenshot: '半分辨率截图',\n"
        @"        cb_use_w3c_actions_for_swipe: 'Swipe 使用 W3C actions',\n"
        @"        cb_restart_responses_by_plan: '计划项完成后重启对话历史（Responses）',\n"
        @"        cb_debug_raw: '调试：记录原始对话（默认关闭；API key / Authorization / 图片 base64 会脱敏）',\n"
    @"        btn_save: '保存',\n"
    @"        btn_start: '开始',\n"
    @"        btn_stop: '停止',\n"
    @"        btn_reset: '重置',\n"
    @"        h_status: '状态',\n"
    @"        h_notes: '备注',\n"
    @"        h_conversation: '对话',\n"
    @"        label_view: '视图：',\n"
    @"        opt_structured: '结构化',\n"
    @"        opt_raw: '原始（请求/响应）',\n"
    @"        cb_show_screenshots: '显示截图',\n"
    @"        help_raw_view: '原始视图显示每轮 API 请求/响应 JSON（历史内容省略；图片会用占位符）。',\n"
    @"        h_logs: '日志',\n"
    @"        chip_runner_ok: 'Runner 可达',\n"
    @"        chip_runner_bad: 'Runner 不可达',\n"
    @"        chip_auth_ok: '已授权',\n"
    @"        chip_auth_bad: '局域网需要 token',\n"
    @"        chip_config_ok: '配置就绪',\n"
    @"        chip_config_bad: '配置未完成',\n"
    @"        chip_key_ok: '密钥就绪',\n"
    @"        chip_key_bad: '缺少密钥',\n"
    @"        chip_running: '运行中',\n"
    @"        chip_stopped: '未运行',\n"
    @"        err_base_url_required: 'Base URL 必填',\n"
    @"        err_model_required: '模型必填',\n"
    @"        err_task_required: '任务必填',\n"
    @"        err_api_key_required: 'API 密钥必填',\n"
    @"        err_agent_token_required: '局域网访问需要 Agent Token',\n"
    @"        err_unauthorized: '未授权（Agent Token 缺失或无效）',\n"
    @"        err_network: '网络错误',\n"
    @"        err_max_steps_gt0: '最大步数必须 > 0',\n"
    @"        err_timeout_gt0: '超时（秒）必须 > 0',\n"
    @"        err_step_delay_gt0: '步间延迟（秒）必须 > 0',\n"
    @"        err_must_be_gt0: '必须 > 0',\n"
    @"        word_step: '步骤',\n"
    @"        word_attempt: '尝试',\n"
    @"        sep_reasoning: '--- 思考 ---',\n"
    @"        sep_content: '--- 内容 ---',\n"
    @"        raw_disabled: '<未开启 raw 记录>',\n"
    @"      }\n"
    @"    };\n"
    @"    function t(key){\n"
    @"      const table = I18N[LANG] || I18N.en;\n"
    @"      return (table && table[key]) ? table[key] : ((I18N.en && I18N.en[key]) ? I18N.en[key] : key);\n"
    @"    }\n"
    @"    function applyI18n(){\n"
    @"      try { document.title = t('page_title'); } catch (e) {}\n"
    @"      const nodes = document.querySelectorAll('[data-i18n]');\n"
    @"      for (const el of nodes) {\n"
    @"        const key = el.getAttribute('data-i18n') || '';\n"
    @"        if (!key) continue;\n"
    @"        el.textContent = t(key);\n"
    @"      }\n"
    @"      const ph = document.querySelectorAll('[data-i18n-placeholder]');\n"
    @"      for (const el of ph) {\n"
    @"        const key = el.getAttribute('data-i18n-placeholder') || '';\n"
    @"        if (!key) continue;\n"
    @"        el.placeholder = t(key);\n"
    @"      }\n"
    @"      const html = document.querySelectorAll('[data-i18n-html]');\n"
    @"      for (const el of html) {\n"
    @"        const key = el.getAttribute('data-i18n-html') || '';\n"
    @"        if (!key) continue;\n"
    @"        el.innerHTML = t(key);\n"
    @"      }\n"
    @"    }\n"
    @"    let dirty = false;\n"
    @"    let lastChatItems = [];\n"
    @"    let lastLogLines = [];\n"
    @"    let lastStatus = null;\n"
    @"    let lastStatusError = '';\n"
    @"    let lastStatusCode = 0;\n"
    @"    let lastRunnerOk = false;\n"
    @"    let lastRunnerError = '';\n"
    @"    let composing = false;\n"
    @"    const shotCache = {};\n"
    @"    const shotLoading = new Set();\n"
    @"    let events = null;\n"
    @"    let eventsReady = false;\n"
    @"    let pollTimer = null;\n"
    @"    let pendingAutoRefresh = false;\n"
    @"    let lastTokenUsage = null;\n"
    @"    const MAX_LOG_LINES = 2000;\n"
    @"    function setInvalid(el, on){\n"
    @"      if (!el || !el.classList) return;\n"
    @"      if (on) el.classList.add('invalid'); else el.classList.remove('invalid');\n"
    @"    }\n"
    @"    function setFormError(lines){\n"
    @"      const el = document.getElementById('form_error');\n"
    @"      const arr = Array.isArray(lines) ? lines.filter(Boolean) : [];\n"
    @"      if (!el) {\n"
    @"        if (arr.length) alert(arr.join('\\n'));\n"
    @"        return;\n"
    @"      }\n"
    @"      if (!arr.length) {\n"
    @"        el.textContent = '';\n"
    @"        el.style.display = 'none';\n"
    @"        return;\n"
    @"      }\n"
    @"      el.textContent = arr.join('\\n');\n"
    @"      el.style.display = '';\n"
    @"    }\n"
    @"    function clearFormError(){\n"
    @"      setFormError([]);\n"
    @"      for (const id of ['base_url','model','api_key','task','max_steps','timeout_seconds','step_delay_seconds','max_completion_tokens']){\n"
    @"        const el = document.getElementById(id);\n"
    @"        if (el) el.classList.remove('invalid');\n"
    @"      }\n"
    @"    }\n"
    @"    function isEditing(){\n"
    @"      const el = document.activeElement;\n"
    @"      if (!el || !el.tagName) return false;\n"
    @"      const tag = el.tagName.toLowerCase();\n"
    @"      return tag === 'input' || tag === 'textarea';\n"
    @"    }\n"
    @"    function markDirty(){ dirty = true; clearFormError(); updateReadinessUI(); }\n"
    @"    function initDirtyTracking(){\n"
    @"      const ids = ['base_url','model','api_mode','api_key','task','max_steps','max_completion_tokens','reasoning_effort','timeout_seconds','step_delay_seconds','system_prompt'];\n"
    @"      for (const id of ids){\n"
    @"        const el = document.getElementById(id);\n"
    @"        if (!el) continue;\n"
    @"        el.addEventListener('input', markDirty);\n"
    @"        el.addEventListener('change', markDirty);\n"
    @"        if (id === 'model') {\n"
    @"          el.addEventListener('input', updateApiModeUI);\n"
    @"          el.addEventListener('change', updateApiModeUI);\n"
    @"        }\n"
    @"        el.addEventListener('compositionstart', () => { composing = true; });\n"
    @"        el.addEventListener('compositionend', () => { composing = false; markDirty(); });\n"
    @"      }\n"
    @"      const cbs = ['remember_api_key','insecure_skip_tls_verify','half_res_screenshot','use_w3c_actions_for_swipe','restart_responses_by_plan','debug_log_raw_assistant','use_custom_system_prompt','doubao_seed_enable_session_cache'];\n"
    @"      for (const id of cbs){\n"
    @"        const el = document.getElementById(id);\n"
    @"        if (!el) continue;\n"
    @"        el.addEventListener('change', markDirty);\n"
    @"      }\n"
    @"      const show = document.getElementById('show_api_key');\n"
    @"      if (show) {\n"
    @"        show.addEventListener('change', () => {\n"
    @"          const keyEl = document.getElementById('api_key');\n"
    @"          if (!keyEl) return;\n"
    @"          keyEl.type = show.checked ? 'text' : 'password';\n"
    @"        });\n"
    @"      }\n"
    @"      const mode = document.getElementById('api_mode');\n"
    @"      if (mode) {\n"
    @"        mode.addEventListener('change', updateApiModeUI);\n"
    @"      }\n"
    @"    }\n"
    @"    async function commitIME(){\n"
    @"      // iOS Safari IME (e.g. Chinese) may not commit the last composed character before click handlers read input.value.\n"
    @"      if (isEditing() && document.activeElement) {\n"
    @"        try { document.activeElement.blur(); } catch (e) {}\n"
    @"        await new Promise(r => setTimeout(r, 50));\n"
    @"      }\n"
    @"      if (composing) {\n"
    @"        await new Promise(r => setTimeout(r, 50));\n"
    @"      }\n"
    @"    }\n"
    @"    function stripTokenFromURL(){\n"
    @"      // Agent Token should never live in the URL longer than the initial page load.\n"
    @"      try {\n"
    @"        const qs = new URLSearchParams(window.location.search || '');\n"
    @"        if (!qs.has('token')) return;\n"
    @"        qs.delete('token');\n"
    @"        const next = window.location.pathname + (qs.toString() ? ('?' + qs.toString()) : '') + (window.location.hash || '');\n"
    @"        window.history.replaceState({}, '', next);\n"
    @"      } catch (e) {}\n"
    @"    }\n"
    @"    async function api(path, method, body){\n"
    @"      const opts = {method: method || 'GET', credentials: 'same-origin'};\n"
    @"      const headers = {};\n"
    @"      if (body) { headers['Content-Type'] = 'application/json'; opts.body = JSON.stringify(body); }\n"
    @"      if (Object.keys(headers).length > 0) { opts.headers = headers; }\n"
    @"      let r;\n"
    @"      try {\n"
    @"        r = await fetch(path, opts);\n"
    @"      } catch (e) {\n"
    @"        const msg = `${t('err_network')}: ${(e && e.message) ? e.message : String(e)}`;\n"
    @"        const err = new Error(msg);\n"
    @"        err.status = 0;\n"
    @"        throw err;\n"
    @"      }\n"
    @"      const j = await r.json().catch(() => ({}));\n"
    @"      if (!r.ok) {\n"
    @"        const msg = ((j.value && j.value.error) || j.error || `HTTP ${r.status}`);\n"
    @"        const err = new Error(msg);\n"
    @"        err.status = r.status;\n"
    @"        err.body = j;\n"
    @"        throw err;\n"
    @"      }\n"
    @"      return j.value || {};\n"
    @"    }\n"
    @"    async function rotateToken(){\n"
    @"      await commitIME();\n"
    @"      clearFormError();\n"
    @"      try {\n"
    @"        const r = await api('/agent/rotate_token','POST');\n"
    @"        const tok = (r.agent_token || '').toString();\n"
    @"        const row = document.getElementById('rotate_token_row');\n"
    @"        const val = document.getElementById('rotate_token_value');\n"
    @"        if (val) { val.value = tok; }\n"
    @"        if (row) { row.style.display = tok.length ? '' : 'none'; }\n"
    @"        await refresh();\n"
    @"      } catch (e) {\n"
    @"        setFormError([e && e.message ? e.message : String(e)]);\n"
    @"      }\n"
    @"    }\n"
    @"    async function copyRotatedToken(){\n"
    @"      const val = document.getElementById('rotate_token_value');\n"
    @"      const tok = val ? (val.value || '').toString() : '';\n"
    @"      if (!tok) return;\n"
    @"      try {\n"
    @"        if (navigator.clipboard && navigator.clipboard.writeText) {\n"
    @"          await navigator.clipboard.writeText(tok);\n"
    @"          return;\n"
    @"        }\n"
    @"      } catch (e) {}\n"
    @"      try {\n"
    @"        if (val) { val.focus(); val.select(); }\n"
    @"        document.execCommand('copy');\n"
    @"      } catch (e) {}\n"
    @"    }\n"
	    @"    function restoreSystemPromptDefault(){\n"
	    @"      const el = document.getElementById('system_prompt');\n"
	    @"      if (!el) return;\n"
	    @"      el.value = DEFAULT_SYSTEM_PROMPT;\n"
	    @"      markDirty();\n"
	    @"    }\n"
	    @"    function openEditorPage(targetId){\n"
    @"      const t = encodeURIComponent((targetId || '').toString());\n"
    @"      window.location.href = `/agent/edit?target=${t}`;\n"
    @"    }\n"
    @"    function cfgFromUI(){\n"
    @"      const cfg = {\n"
    @"        base_url: document.getElementById('base_url').value,\n"
    @"        model: document.getElementById('model').value,\n"
    @"        api_mode: document.getElementById('api_mode').value,\n"
    @"        use_custom_system_prompt: document.getElementById('use_custom_system_prompt').checked,\n"
    @"        system_prompt: document.getElementById('system_prompt').value,\n"
    @"        remember_api_key: document.getElementById('remember_api_key').checked,\n"
    @"        debug_log_raw_assistant: document.getElementById('debug_log_raw_assistant').checked,\n"
    @"        doubao_seed_enable_session_cache: document.getElementById('doubao_seed_enable_session_cache').checked,\n"
    @"        half_res_screenshot: document.getElementById('half_res_screenshot').checked,\n"
    @"        use_w3c_actions_for_swipe: document.getElementById('use_w3c_actions_for_swipe').checked,\n"
    @"        restart_responses_by_plan: document.getElementById('restart_responses_by_plan').checked,\n"
    @"        task: document.getElementById('task').value,\n"
    @"        max_steps: document.getElementById('max_steps').value,\n"
    @"        max_completion_tokens: document.getElementById('max_completion_tokens').value,\n"
    @"        reasoning_effort: document.getElementById('reasoning_effort').value,\n"
    @"        timeout_seconds: document.getElementById('timeout_seconds').value,\n"
    @"        step_delay_seconds: document.getElementById('step_delay_seconds').value,\n"
    @"        insecure_skip_tls_verify: document.getElementById('insecure_skip_tls_verify').checked,\n"
    @"      };\n"
    @"      const key = (document.getElementById('api_key').value || '').trim();\n"
    @"      if (key.length > 0) { cfg.api_key = key; }\n"
    @"      return cfg;\n"
    @"    }\n"
    @"    function isStrictIntegerString(raw){\n"
    @"      return /^[+-]?\\d+$/.test(raw);\n"
    @"    }\n"
    @"    function isStrictNumberString(raw){\n"
    @"      return /^[+-]?(?:\\d+\\.?\\d*|\\.\\d+)(?:[eE][+-]?\\d+)?$/.test(raw);\n"
    @"    }\n"
    @"    function isLoopbackHost(){\n"
    @"      const h = ((window.location && window.location.hostname) ? window.location.hostname : '').toString().toLowerCase();\n"
    @"      return h === '127.0.0.1' || h === 'localhost' || h === '::1';\n"
    @"    }\n"
    @"    function computeStartValidation(){\n"
    @"      const errors = [];\n"
    @"      const invalid = {};\n"
    @"\n"
    @"      const baseUrlEl = document.getElementById('base_url');\n"
    @"      const modelEl = document.getElementById('model');\n"
    @"      const taskEl = document.getElementById('task');\n"
    @"      const apiKeyEl = document.getElementById('api_key');\n"
    @"      const maxStepsEl = document.getElementById('max_steps');\n"
    @"      const timeoutEl = document.getElementById('timeout_seconds');\n"
    @"      const delayEl = document.getElementById('step_delay_seconds');\n"
    @"      const tokensEl = document.getElementById('max_completion_tokens');\n"
    @"      const modeEl = document.getElementById('api_mode');\n"
    @"      const mode = modeEl ? (modeEl.value || 'responses') : 'responses';\n"
    @"      const tokenLabel = (mode === 'responses') ? t('label_max_output_tokens') : t('label_max_completion_tokens');\n"
    @"\n"
    @"      const baseUrl = ((baseUrlEl && baseUrlEl.value) || '').trim();\n"
    @"      if (!baseUrl.length) {\n"
    @"        invalid.base_url = true;\n"
    @"        errors.push(t('err_base_url_required'));\n"
    @"      }\n"
    @"      const model = ((modelEl && modelEl.value) || '').trim();\n"
    @"      if (!model.length) {\n"
    @"        invalid.model = true;\n"
    @"        errors.push(t('err_model_required'));\n"
    @"      }\n"
    @"      const task = ((taskEl && taskEl.value) || '').trim();\n"
    @"      if (!task.length) {\n"
    @"        invalid.task = true;\n"
    @"        errors.push(t('err_task_required'));\n"
    @"      }\n"
    @"\n"
    @"      const apiKey = ((apiKeyEl && apiKeyEl.value) || '').trim();\n"
    @"      const apiKeySet = !!(lastStatus && lastStatus.config && lastStatus.config.api_key_set);\n"
    @"      if (!apiKey.length && !apiKeySet) {\n"
    @"        invalid.api_key = true;\n"
    @"        errors.push(t('err_api_key_required'));\n"
    @"      }\n"
    @"\n"
    @"      if (!lastRunnerOk && lastRunnerError) {\n"
    @"        errors.push(`${t('chip_runner_bad')}: ${lastRunnerError}`);\n"
    @"      }\n"
    @"\n"
    @"      if (!isLoopbackHost() && lastStatusCode === 401) {\n"
    @"        errors.push(`${t('err_agent_token_required')}\\n${t('err_unauthorized')}`);\n"
    @"      } else if (!lastStatus && lastStatusError && lastStatusCode !== 0) {\n"
    @"        // When the Runner is alive but /agent/* is blocked, surface the reason.\n"
    @"        errors.push(lastStatusError);\n"
    @"      }\n"
    @"\n"
    @"      const maxStepsRaw = ((maxStepsEl && maxStepsEl.value) || '').trim();\n"
    @"      let maxStepsBad = false;\n"
    @"      if (maxStepsRaw.length) {\n"
    @"        const maxSteps = Number(maxStepsRaw);\n"
    @"        maxStepsBad = !(isStrictIntegerString(maxStepsRaw) && Number.isFinite(maxSteps) && maxSteps > 0);\n"
    @"      }\n"
    @"      invalid.max_steps = maxStepsBad;\n"
    @"      if (maxStepsBad) errors.push(t('err_max_steps_gt0'));\n"
    @"\n"
    @"      const timeoutRaw = ((timeoutEl && timeoutEl.value) || '').trim();\n"
    @"      let timeoutBad = false;\n"
    @"      if (timeoutRaw.length) {\n"
    @"        const timeout = Number(timeoutRaw);\n"
    @"        timeoutBad = !(isStrictNumberString(timeoutRaw) && Number.isFinite(timeout) && timeout > 0);\n"
    @"      }\n"
    @"      invalid.timeout_seconds = timeoutBad;\n"
    @"      if (timeoutBad) errors.push(t('err_timeout_gt0'));\n"
    @"\n"
    @"      const delayRaw = ((delayEl && delayEl.value) || '').trim();\n"
    @"      let delayBad = false;\n"
    @"      if (delayRaw.length) {\n"
    @"        const delay = Number(delayRaw);\n"
    @"        delayBad = !(isStrictNumberString(delayRaw) && Number.isFinite(delay) && delay > 0);\n"
    @"      }\n"
    @"      invalid.step_delay_seconds = delayBad;\n"
    @"      if (delayBad) errors.push(t('err_step_delay_gt0'));\n"
    @"\n"
    @"      const tokensRaw = ((tokensEl && tokensEl.value) || '').trim();\n"
    @"      let tokensBad = false;\n"
    @"      if (tokensRaw.length) {\n"
    @"        const tokens = Number(tokensRaw);\n"
    @"        tokensBad = !(isStrictIntegerString(tokensRaw) && Number.isFinite(tokens) && tokens > 0);\n"
    @"      }\n"
    @"      invalid.max_completion_tokens = tokensBad;\n"
    @"      if (tokensBad) errors.push(`${tokenLabel} ${t('err_must_be_gt0')}`);\n"
    @"\n"
    @"      return {errors, invalid};\n"
    @"    }\n"
    @"    function applyStartValidationInvalid(invalid){\n"
    @"      const ids = ['base_url','model','task','api_key','max_steps','timeout_seconds','step_delay_seconds','max_completion_tokens'];\n"
    @"      for (const id of ids) {\n"
    @"        const el = document.getElementById(id);\n"
    @"        setInvalid(el, !!(invalid && invalid[id]));\n"
    @"      }\n"
    @"    }\n"
    @"    function tokenUsageFromStatus(){\n"
    @"      if (!lastStatus) return null;\n"
    @"      const u = lastStatus.token_usage || lastStatus.tokenUsage || null;\n"
    @"      if (!u) return null;\n"
    @"      const req = Number(u.requests || u.req || 0);\n"
    @"      const input = Number(u.input_tokens || u.inputTokens || 0);\n"
    @"      const output = Number(u.output_tokens || u.outputTokens || 0);\n"
    @"      const cached = Number(u.cached_tokens || u.cachedTokens || 0);\n"
    @"      const total = Number(u.total_tokens || u.totalTokens || 0);\n"
    @"      return {requests:req, input, output, cached, total};\n"
    @"    }\n"
    @"    function updateTokenSummary(){\n"
    @"      const el = document.getElementById('token_summary');\n"
    @"      if (!el) return;\n"
    @"      const u = lastTokenUsage || tokenUsageFromStatus();\n"
    @"      if (!u || (!u.requests && !u.total && !u.input && !u.output && !u.cached)) {\n"
    @"        el.textContent = '';\n"
    @"        el.style.display = 'none';\n"
    @"        return;\n"
    @"      }\n"
    @"      const summary = (LANG === 'zh')\n"
    @"        ? `Token：请求 ${u.requests} · 输入 ${u.input} · 输出 ${u.output} · 缓存 ${u.cached} · 总计 ${u.total}`\n"
    @"        : `Tokens: req ${u.requests} · in ${u.input} · out ${u.output} · cached ${u.cached} · total ${u.total}`;\n"
    @"      let cacheLine = '';\n"
    @"      try {\n"
    @"        const cfg = (lastStatus && lastStatus.config) ? lastStatus.config : {};\n"
    @"        const enabled = !!(cfg && cfg.doubao_seed_enable_session_cache);\n"
    @"        const apiMode = (cfg.api_mode || '').toString();\n"
    @"        if (apiMode === 'responses') {\n"
    @"          const hit = (u.cached || 0) > 0;\n"
    @"          cacheLine = (LANG === 'zh')\n"
    @"            ? `缓存：${enabled ? '已开启' : '未开启'}${hit ? '（已命中）' : ''}`\n"
    @"            : `Cache: ${enabled ? 'enabled' : 'disabled'}${hit ? ' (hit)' : ''}`;\n"
    @"        }\n"
    @"      } catch (e) {}\n"
    @"      el.textContent = cacheLine ? (summary + '\\n' + cacheLine) : summary;\n"
    @"      el.style.display = '';\n"
    @"    }\n"
    @"    function updateReadinessUI(){\n"
    @"      const chipsEl = document.getElementById('readiness');\n"
    @"      const detailEl = document.getElementById('readiness_detail');\n"
    @"      const tokenEl = document.getElementById('token_summary');\n"
    @"      const startBtn = document.getElementById('btn_start');\n"
    @"      const stopBtn = document.getElementById('btn_stop');\n"
    @"      const saveBtn = document.getElementById('btn_save');\n"
    @"      const running = !!(lastStatus && lastStatus.running);\n"
    @"\n"
    @"      if (stopBtn) stopBtn.disabled = !running;\n"
    @"      if (saveBtn) saveBtn.disabled = running;\n"
    @"\n"
    @"      const v = computeStartValidation();\n"
    @"      const canStart = !running && v.errors.length === 0;\n"
    @"      if (startBtn) startBtn.disabled = !canStart;\n"
    @"\n"
    @"      if (chipsEl) {\n"
    @"        const chips = [];\n"
    @"        if (lastRunnerOk) {\n"
    @"          chips.push({text: t('chip_runner_ok'), ok: true});\n"
    @"        } else {\n"
    @"          chips.push({text: t('chip_runner_bad'), ok: false});\n"
    @"        }\n"
    @"        if (!isLoopbackHost()) {\n"
    @"          if (lastStatusCode === 401) chips.push({text: t('chip_auth_bad'), ok: false});\n"
    @"          else if (lastStatus) chips.push({text: t('chip_auth_ok'), ok: true});\n"
    @"        }\n"
    @"        const configOk = !v.invalid.base_url && !v.invalid.model && !v.invalid.task && !v.invalid.max_steps && !v.invalid.timeout_seconds && !v.invalid.step_delay_seconds && !v.invalid.max_completion_tokens;\n"
    @"        chips.push({text: configOk ? t('chip_config_ok') : t('chip_config_bad'), ok: configOk});\n"
    @"        const keyOk = !v.invalid.api_key;\n"
    @"        chips.push({text: keyOk ? t('chip_key_ok') : t('chip_key_bad'), ok: keyOk});\n"
    @"        chips.push({text: running ? t('chip_running') : t('chip_stopped'), ok: running});\n"
    @"\n"
    @"        chipsEl.innerHTML = '';\n"
    @"        for (const c of chips) {\n"
    @"          const s = document.createElement('span');\n"
    @"          s.className = 'chip ' + (c.ok ? 'ok' : 'bad');\n"
    @"          s.textContent = c.text;\n"
    @"          chipsEl.appendChild(s);\n"
    @"        }\n"
    @"        chipsEl.style.display = '';\n"
    @"      }\n"
    @"\n"
    @"      if (detailEl) {\n"
    @"        const lines = [];\n"
    @"        if (running) {\n"
    @"          lines.push((LANG === 'zh') ? '运行中：停止后可修改配置或重新开始。' : 'Running: stop to edit config or restart.');\n"
    @"        }\n"
    @"        if (!canStart && v.errors.length) {\n"
    @"          for (const x of v.errors) lines.push(x);\n"
    @"        }\n"
    @"        if (lines.length) {\n"
    @"          detailEl.textContent = lines.join('\\n');\n"
    @"          detailEl.style.display = '';\n"
    @"        } else {\n"
    @"          detailEl.textContent = '';\n"
    @"          detailEl.style.display = 'none';\n"
    @"        }\n"
    @"      }\n"
    @"      if (tokenEl) updateTokenSummary();\n"
    @"    }\n"
    @"    function validateBeforeStart(){\n"
    @"      const v = computeStartValidation();\n"
    @"      applyStartValidationInvalid(v.invalid);\n"
    @"      setFormError(v.errors);\n"
    @"      updateReadinessUI();\n"
    @"      return v.errors.length === 0;\n"
    @"    }\n"
    @"    function fillUI(cfg){\n"
    @"      document.getElementById('base_url').value = cfg.base_url || '';\n"
    @"      document.getElementById('model').value = cfg.model || '';\n"
    @"      document.getElementById('api_mode').value = cfg.api_mode || 'responses';\n"
    @"      document.getElementById('task').value = cfg.task || '';\n"
    @"      document.getElementById('max_steps').value = cfg.max_steps || __DEFAULT_MAX_STEPS__;\n"
    @"      document.getElementById('max_completion_tokens').value = cfg.max_completion_tokens || __DEFAULT_MAX_COMPLETION_TOKENS__;\n"
    @"      document.getElementById('reasoning_effort').value = cfg.reasoning_effort || '';\n"
    @"      document.getElementById('timeout_seconds').value = cfg.timeout_seconds || __DEFAULT_TIMEOUT_SECONDS__;\n"
    @"      document.getElementById('step_delay_seconds').value = cfg.step_delay_seconds || __DEFAULT_STEP_DELAY_SECONDS__;\n"
    @"      document.getElementById('use_custom_system_prompt').checked = !!cfg.use_custom_system_prompt;\n"
    @"      const sp = (cfg.system_prompt || '').toString();\n"
    @"      document.getElementById('system_prompt').value = sp.length ? sp : DEFAULT_SYSTEM_PROMPT;\n"
    @"      document.getElementById('remember_api_key').checked = !!cfg.remember_api_key;\n"
    @"      document.getElementById('doubao_seed_enable_session_cache').checked = (cfg.doubao_seed_enable_session_cache !== false);\n"
    @"      document.getElementById('insecure_skip_tls_verify').checked = !!cfg.insecure_skip_tls_verify;\n"
    @"      document.getElementById('half_res_screenshot').checked = !!cfg.half_res_screenshot;\n"
    @"      document.getElementById('use_w3c_actions_for_swipe').checked = (cfg.use_w3c_actions_for_swipe !== false);\n"
    @"      document.getElementById('restart_responses_by_plan').checked = !!cfg.restart_responses_by_plan;\n"
    @"      document.getElementById('debug_log_raw_assistant').checked = !!cfg.debug_log_raw_assistant;\n"
    @"      if (cfg.api_key_set) {\n"
    @"        document.getElementById('api_key').placeholder = t('ph_api_key_set');\n"
    @"      }\n"
    @"      updateApiModeUI();\n"
    @"    }\n"
    @"    function updateApiModeUI(){\n"
    @"      const modeEl = document.getElementById('api_mode');\n"
    @"      const mode = modeEl ? (modeEl.value || 'responses') : 'responses';\n"
    @"      const label = document.getElementById('max_tokens_label');\n"
    @"      if (!label) return;\n"
    @"      label.textContent = (mode === 'responses') ? t('label_max_output_tokens_gt0') : t('label_max_completion_tokens_gt0');\n"
    @"      const cacheRow = document.getElementById('doubao_seed_cache_row');\n"
    @"      const modelEl = document.getElementById('model');\n"
    @"      const model = modelEl ? ((modelEl.value || '').toString().trim().toLowerCase()) : '';\n"
    @"      if (cacheRow) {\n"
    @"        const show = (mode === 'responses') && model.startsWith('doubao-seed');\n"
    @"        cacheRow.style.display = show ? '' : 'none';\n"
    @"      }\n"
    @"    }\n"
    @"    function clearNode(el){\n"
    @"      if (!el) return;\n"
    @"      while (el.firstChild) el.removeChild(el.firstChild);\n"
    @"    }\n"
    @"    function prettyRaw(raw){\n"
    @"      const s = (raw || '').toString();\n"
    @"      const t0 = s.trim();\n"
    @"      if (!t0) return '';\n"
    @"      if ((t0.startsWith('{') && t0.endsWith('}')) || (t0.startsWith('[') && t0.endsWith(']'))) {\n"
    @"        try { return JSON.stringify(JSON.parse(t0), null, 2); } catch (e) {}\n"
    @"      }\n"
    @"      return s;\n"
    @"    }\n"
    @"    function screenshotPlaceholderText(){\n"
    @"      return (LANG === 'zh') ? '正在加载截图…' : 'Loading screenshot…';\n"
    @"    }\n"
    @"    function screenshotNotFoundText(){\n"
    @"      return (LANG === 'zh') ? '未找到截图' : 'Screenshot not found';\n"
    @"    }\n"
    @"    function rawJSONLabel(){\n"
    @"      return (LANG === 'zh') ? '原始 JSON' : 'Raw JSON';\n"
    @"    }\n"
    @"    function otherLogsLabel(){\n"
    @"      return (LANG === 'zh') ? '其它' : 'Other';\n"
    @"    }\n"
    @"    async function ensureStepScreenshot(step, imgEl, placeholderEl){\n"
    @"      if (!imgEl) return;\n"
    @"      const key = String(step);\n"
    @"      if (shotCache[key]) {\n"
    @"        imgEl.src = 'data:image/png;base64,' + shotCache[key];\n"
    @"        imgEl.style.display = 'block';\n"
    @"        if (placeholderEl) placeholderEl.style.display = 'none';\n"
    @"        return;\n"
    @"      }\n"
    @"      if (shotLoading.has(key)) return;\n"
    @"      shotLoading.add(key);\n"
    @"      if (placeholderEl) {\n"
    @"        placeholderEl.textContent = screenshotPlaceholderText();\n"
    @"        placeholderEl.style.display = '';\n"
    @"      }\n"
    @"      try {\n"
    @"        const r = await api('/agent/step_screenshot?step=' + encodeURIComponent(step));\n"
    @"        const b64 = (r && r.png_base64) ? r.png_base64 : '';\n"
    @"        if (r && r.ok && b64) {\n"
    @"          shotCache[key] = b64;\n"
    @"          imgEl.src = 'data:image/png;base64,' + b64;\n"
    @"          imgEl.style.display = 'block';\n"
    @"          if (placeholderEl) placeholderEl.style.display = 'none';\n"
    @"        } else {\n"
    @"          imgEl.style.display = 'none';\n"
    @"          if (placeholderEl) placeholderEl.textContent = (r && r.error) ? String(r.error) : screenshotNotFoundText();\n"
    @"        }\n"
    @"      } catch (e) {\n"
    @"        imgEl.style.display = 'none';\n"
    @"        if (placeholderEl) placeholderEl.textContent = (e && e.message) ? e.message : String(e);\n"
    @"      } finally {\n"
    @"        shotLoading.delete(key);\n"
    @"      }\n"
    @"    }\n"
    @"    function attemptCountLabel(n){\n"
    @"      if (!(Number.isFinite(n) && n > 1)) return '';\n"
    @"      return (LANG === 'zh') ? ` · ${n} 次尝试` : ` · ${n} attempts`;\n"
    @"    }\n"
    @"    function appendChatMsg(body, it, mode){\n"
    @"      if (!body || !it) return;\n"
    @"      const kind = (it.kind || '').toString();\n"
    @"      const attempt = (it.attempt != null) ? Number(it.attempt) : 0;\n"
    @"      const ts = (it.ts || '').toString();\n"
    @"\n"
    @"      const box = document.createElement('div');\n"
    @"      box.className = 'msg';\n"
    @"      const hdr = document.createElement('div');\n"
    @"      hdr.className = 'msg-hdr';\n"
    @"      const parts = [];\n"
    @"      if (ts) parts.push(ts);\n"
    @"      if (kind) parts.push(kind.toUpperCase());\n"
    @"      if (attempt > 0) parts.push(`${t('word_attempt')} ${attempt}`);\n"
    @"      hdr.textContent = parts.join(' · ');\n"
    @"      box.appendChild(hdr);\n"
    @"\n"
    @"      if (mode !== 'raw') {\n"
    @"        const pre = document.createElement('pre');\n"
    @"        if (kind === 'request') {\n"
    @"          pre.textContent = it.text || '';\n"
    @"        } else {\n"
    @"          let text = '';\n"
    @"          if (it.reasoning) {\n"
    @"            text += t('sep_reasoning') + '\\n' + it.reasoning + '\\n\\n';\n"
    @"          }\n"
    @"          text += t('sep_content') + '\\n' + (it.content || '');\n"
    @"          pre.textContent = text;\n"
    @"        }\n"
    @"        box.appendChild(pre);\n"
    @"      }\n"
    @"\n"
    @"      const rawDetails = document.createElement('details');\n"
    @"      rawDetails.className = 'raw';\n"
    @"      if (mode === 'raw') rawDetails.open = true;\n"
    @"      const sum = document.createElement('summary');\n"
    @"      sum.textContent = rawJSONLabel();\n"
    @"      rawDetails.appendChild(sum);\n"
    @"      const rawPre = document.createElement('pre');\n"
    @"      rawPre.textContent = prettyRaw(it.raw || '') || t('raw_disabled');\n"
    @"      rawDetails.appendChild(rawPre);\n"
    @"      box.appendChild(rawDetails);\n"
    @"\n"
    @"      body.appendChild(box);\n"
    @"    }\n"
    @"    function parseLogLine(line){\n"
    @"      const s = (line || '').toString().trim();\n"
    @"      let d = null;\n"
    @"      if (s.startsWith('{') && s.endsWith('}')) {\n"
    @"        try { d = JSON.parse(s); } catch (e) { d = null; }\n"
    @"      }\n"
    @"      if (!d) return {step: -1, text: s};\n"
    @"      const ts = (d.ts || '').toString();\n"
    @"      const lvl = (d.lvl || 'INFO').toString().toUpperCase();\n"
    @"      const tag = (d.tag || '').toString();\n"
    @"      const ev = (d.event || '').toString();\n"
    @"      const msg = (d.msg || '').toString();\n"
    @"      let tail = '';\n"
    @"      if (ev === 'step') {\n"
    @"        tail = `step=${d.step} action=${d.action || ''}`.trim();\n"
    @"      } else if (ev === 'token_usage') {\n"
    @"        tail = `req=${d.req} +in=${d.d_in} +out=${d.d_out} +cached=${d.d_cached} +total=${d.d_total} cum(in=${d.c_in} out=${d.c_out} cached=${d.c_cached} total=${d.c_total})`;\n"
    @"      } else if (d.error) {\n"
    @"        tail = `error=${(d.error || '').toString()}`;\n"
    @"      }\n"
    @"      const hdr = `${ts} [${lvl}]${tag ? ` [${tag}]` : ''}${ev ? ` [${ev}]` : ''}`.trim();\n"
    @"      const main = msg.length ? msg : ev;\n"
    @"      const text = `${hdr} ${main}${tail ? ` ${tail}` : ''}`.trim();\n"
    @"      const step = (d.step != null) ? Number(d.step) : -1;\n"
    @"      return {step: Number.isFinite(step) ? step : -1, text};\n"
    @"    }\n"
    @"    function renderLogs(){\n"
    @"      const el = document.getElementById('logs');\n"
    @"      if (!el) return;\n"
    @"      clearNode(el);\n"
    @"      if (!lastLogLines || !lastLogLines.length) return;\n"
    @"\n"
    @"      const groupMap = new Map();\n"
    @"      const groupOrder = [];\n"
    @"      for (const line of lastLogLines) {\n"
    @"        const parsed = parseLogLine(line);\n"
    @"        const k = (parsed.step >= 0) ? String(parsed.step) : 'other';\n"
    @"        if (!groupMap.has(k)) {\n"
    @"          groupMap.set(k, {key: k, step: parsed.step, lines: []});\n"
    @"          groupOrder.push(k);\n"
    @"        }\n"
    @"        groupMap.get(k).lines.push(parsed.text);\n"
    @"      }\n"
    @"\n"
    @"      const lastKey = groupOrder.length ? groupOrder[groupOrder.length - 1] : '';\n"
    @"      for (const k of groupOrder) {\n"
    @"        const g = groupMap.get(k);\n"
    @"        const card = document.createElement('details');\n"
    @"        card.className = 'step-card';\n"
    @"        if (k === lastKey) card.open = true;\n"
    @"        const sum = document.createElement('summary');\n"
    @"        if (g.step >= 0) sum.textContent = `${t('word_step')} ${g.step}`;\n"
    @"        else sum.textContent = otherLogsLabel();\n"
    @"        card.appendChild(sum);\n"
    @"        const body = document.createElement('div');\n"
    @"        body.className = 'step-body';\n"
    @"        const box = document.createElement('div');\n"
    @"        box.className = 'msg';\n"
    @"        const pre = document.createElement('pre');\n"
    @"        pre.textContent = (g.lines || []).join('\\n');\n"
    @"        box.appendChild(pre);\n"
    @"        body.appendChild(box);\n"
    @"        card.appendChild(body);\n"
    @"        el.appendChild(card);\n"
    @"      }\n"
    @"    }\n"
    @"    function renderChat(){\n"
    @"      const el = document.getElementById('chat');\n"
    @"      if (!el) return;\n"
    @"      const modeEl = document.getElementById('chat_mode');\n"
    @"      const mode = modeEl ? modeEl.value : 'structured';\n"
    @"      clearNode(el);\n"
    @"      if (!lastChatItems || !lastChatItems.length) return;\n"
    @"\n"
    @"      const showShotsEl = document.getElementById('chat_show_screenshots');\n"
    @"      const showShots = !!(showShotsEl && showShotsEl.checked);\n"
    @"\n"
    @"      const stepMap = new Map();\n"
    @"      const stepOrder = [];\n"
    @"      for (const it of lastChatItems) {\n"
    @"        const s = (it.step != null) ? Number(it.step) : NaN;\n"
    @"        if (!Number.isFinite(s)) continue;\n"
    @"        if (!stepMap.has(s)) {\n"
    @"          stepMap.set(s, {step: s, attemptMap: new Map(), attemptOrder: []});\n"
    @"          stepOrder.push(s);\n"
    @"        }\n"
    @"        const g = stepMap.get(s);\n"
    @"        const a = (it.attempt != null) ? Number(it.attempt) : 0;\n"
    @"        if (!g.attemptMap.has(a)) {\n"
    @"          g.attemptMap.set(a, {attempt: a, request: null, response: null});\n"
    @"          g.attemptOrder.push(a);\n"
    @"        }\n"
    @"        const ag = g.attemptMap.get(a);\n"
    @"        const kind = (it.kind || '').toString();\n"
    @"        if (kind === 'request') ag.request = it;\n"
    @"        else if (kind === 'response') ag.response = it;\n"
    @"      }\n"
    @"\n"
    @"      const lastStep = stepOrder.length ? stepOrder[stepOrder.length - 1] : -1;\n"
    @"      for (const step of stepOrder) {\n"
    @"        const g = stepMap.get(step);\n"
    @"        const card = document.createElement('details');\n"
    @"        card.className = 'step-card';\n"
    @"        if (step === lastStep) card.open = true;\n"
    @"\n"
    @"        const sum = document.createElement('summary');\n"
    @"        sum.textContent = `${t('word_step')} ${step}` + attemptCountLabel(g.attemptOrder.length);\n"
    @"        card.appendChild(sum);\n"
    @"\n"
    @"        const body = document.createElement('div');\n"
    @"        body.className = 'step-body';\n"
    @"\n"
    @"        if (showShots) {\n"
    @"          const ph = document.createElement('div');\n"
    @"          ph.className = 'muted';\n"
    @"          ph.textContent = screenshotPlaceholderText();\n"
    @"          const img = document.createElement('img');\n"
    @"          img.className = 'shot';\n"
    @"          img.alt = `${t('word_step')} ${step}`;\n"
    @"          img.style.display = 'none';\n"
    @"          body.appendChild(ph);\n"
    @"          body.appendChild(img);\n"
    @"          const load = () => ensureStepScreenshot(step, img, ph);\n"
    @"          card.addEventListener('toggle', () => { if (card.open) load(); });\n"
    @"          if (card.open) load();\n"
    @"        }\n"
    @"\n"
    @"        for (const a of g.attemptOrder) {\n"
    @"          const ag = g.attemptMap.get(a);\n"
    @"          appendChatMsg(body, ag.request, mode);\n"
    @"          appendChatMsg(body, ag.response, mode);\n"
    @"        }\n"
    @"\n"
    @"        card.appendChild(body);\n"
    @"        el.appendChild(card);\n"
    @"      }\n"
    @"    }\n"
    @"    async function resetAll(){\n"
    @"      await commitIME();\n"
    @"      await api('/agent/reset', 'POST');\n"
    @"      dirty = false;\n"
    @"      await refresh();\n"
    @"    }\n"
    @"    let refreshInFlight = false;\n"
    @"    async function refresh(){\n"
    @"      if (refreshInFlight) return;\n"
    @"      // Avoid UI updates while editing; iOS Safari may jump the caret/scroll when DOM updates frequently.\n"
    @"      if (isEditing() || composing) return;\n"
    @"      refreshInFlight = true;\n"
    @"      try {\n"
    @"        lastRunnerOk = false;\n"
    @"        lastRunnerError = '';\n"
    @"        try {\n"
    @"          await api('/status');\n"
    @"          lastRunnerOk = true;\n"
    @"        } catch (e) {\n"
    @"          lastRunnerOk = false;\n"
    @"          lastRunnerError = (e && e.message) ? e.message : String(e);\n"
    @"        }\n"
    @"\n"
    @"        lastStatus = null;\n"
    @"        lastStatusError = '';\n"
    @"        lastStatusCode = 0;\n"
    @"\n"
    @"        const st = await api('/agent/status');\n"
    @"        lastStatus = st;\n"
    @"        lastTokenUsage = tokenUsageFromStatus();\n"
    @"        lastStatusCode = 200;\n"
    @"        document.getElementById('status').textContent = JSON.stringify(st, null, 2);\n"
    @"        const notes = st.notes || '';\n"
    @"        document.getElementById('notes').textContent = notes;\n"
    @"        if (!dirty && !isEditing()) {\n"
    @"          fillUI((st.config)||{});\n"
    @"        }\n"
    @"        if (!eventsReady) {\n"
    @"          const chat = await api('/agent/chat');\n"
    @"          lastChatItems = (chat.items || []);\n"
    @"          renderChat();\n"
    @"          const logs = await api('/agent/logs');\n"
    @"          lastLogLines = (logs.lines || []);\n"
    @"          renderLogs();\n"
    @"        }\n"
    @"      } catch (e) {\n"
    @"        lastStatus = null;\n"
    @"        lastStatusCode = (e && typeof e.status === 'number') ? e.status : 0;\n"
    @"        lastStatusError = (e && e.message) ? e.message : String(e);\n"
    @"        document.getElementById('status').textContent = lastStatusError;\n"
    @"        document.getElementById('notes').textContent = '';\n"
    @"        lastLogLines = [];\n"
    @"        renderLogs();\n"
    @"        lastChatItems = [];\n"
    @"        renderChat();\n"
    @"      }\n"
	    @"      } finally {\n"
	    @"        refreshInFlight = false;\n"
    @"        updateReadinessUI();\n"
	    @"      }\n"
	    @"    }\n"
    @"    async function saveCfg(){\n"
    @"      await commitIME();\n"
    @"      if (!validateBeforeStart()) return;\n"
    @"      await api('/agent/config', 'POST', cfgFromUI());\n"
    @"      dirty = false;\n"
    @"      await refresh();\n"
    @"    }\n"
    @"    async function start(){\n"
    @"      await commitIME();\n"
    @"      if (!validateBeforeStart()) return;\n"
    @"      const resp = await api('/agent/start', 'POST', cfgFromUI());\n"
    @"      dirty = false;\n"
    @"      await refresh();\n"
    @"      if (resp && resp.ok === false && resp.error) {\n"
    @"        setFormError([resp.error]);\n"
    @"      }\n"
    @"    }\n"
	    @"    async function stop(){\n"
	    @"      await api('/agent/stop', 'POST');\n"
	    @"      await refresh();\n"
	    @"    }\n"
    @"    function isPageVisible(){ return !document.hidden; }\n"
    @"    function closeEvents(){\n"
    @"      if (!events) return;\n"
    @"      try { events.close(); } catch (e) {}\n"
    @"      events = null;\n"
    @"      eventsReady = false;\n"
    @"    }\n"
    @"    function stopPolling(){\n"
    @"      if (!pollTimer) return;\n"
    @"      try { clearInterval(pollTimer); } catch (e) {}\n"
    @"      pollTimer = null;\n"
    @"    }\n"
    @"    function startPolling(){\n"
    @"      if (pollTimer) return;\n"
    @"      pollTimer = setInterval(() => {\n"
    @"        if (!isPageVisible()) return;\n"
    @"        if (events) return;\n"
    @"        if (lastStatus && lastStatus.running) refresh();\n"
    @"        else stopPolling();\n"
    @"      }, __DEFAULT_REFRESH_INTERVAL_MS__);\n"
    @"    }\n"
    @"    function updateAutoUpdates(){\n"
    @"      if (events) {\n"
    @"        stopPolling();\n"
    @"        return;\n"
    @"      }\n"
    @"      if (lastStatus && lastStatus.running) startPolling();\n"
    @"      else stopPolling();\n"
    @"    }\n"
    @"    let renderTimer = null;\n"
    @"    function scheduleRender(){\n"
    @"      if (renderTimer) return;\n"
    @"      renderTimer = setTimeout(() => {\n"
    @"        renderTimer = null;\n"
    @"        if (isEditing() || composing) {\n"
    @"          pendingAutoRefresh = true;\n"
    @"          return;\n"
    @"        }\n"
    @"        renderChat();\n"
    @"        renderLogs();\n"
    @"        updateReadinessUI();\n"
    @"      }, 80);\n"
    @"    }\n"
    @"    function maybeApplyPendingAutoRefresh(){\n"
    @"      if (!pendingAutoRefresh) return;\n"
    @"      if (isEditing() || composing) return;\n"
    @"      pendingAutoRefresh = false;\n"
    @"      try {\n"
    @"        renderChat();\n"
    @"        renderLogs();\n"
    @"        updateReadinessUI();\n"
    @"      } catch (e) {}\n"
    @"      refresh();\n"
    @"    }\n"
    @"    function applyStatusFromPush(st){\n"
    @"      if (!st) return;\n"
    @"      lastStatus = st;\n"
    @"      lastTokenUsage = tokenUsageFromStatus();\n"
    @"      lastStatusError = '';\n"
    @"      lastStatusCode = 200;\n"
    @"      if (isEditing() || composing) {\n"
    @"        pendingAutoRefresh = true;\n"
    @"        return;\n"
    @"      }\n"
    @"      document.getElementById('status').textContent = JSON.stringify(st, null, 2);\n"
    @"      document.getElementById('notes').textContent = st.notes || '';\n"
    @"      if (!dirty && !isEditing()) {\n"
    @"        fillUI((st.config)||{});\n"
    @"      }\n"
    @"      updateReadinessUI();\n"
    @"    }\n"
    @"    function applySnapshotFromPush(snap){\n"
    @"      if (!snap) return;\n"
    @"      if (snap.status) {\n"
    @"        lastRunnerOk = true;\n"
    @"        lastRunnerError = '';\n"
    @"        applyStatusFromPush(snap.status);\n"
    @"      }\n"
    @"      if (Array.isArray(snap.logs)) {\n"
    @"        lastLogLines = snap.logs.slice();\n"
    @"      } else if (snap.logs && Array.isArray(snap.logs.lines)) {\n"
    @"        lastLogLines = snap.logs.lines.slice();\n"
    @"      }\n"
    @"      if (Array.isArray(snap.chat)) {\n"
    @"        lastChatItems = snap.chat.slice();\n"
    @"      } else if (snap.chat && Array.isArray(snap.chat.items)) {\n"
    @"        lastChatItems = snap.chat.items.slice();\n"
    @"      }\n"
    @"      eventsReady = true;\n"
    @"      scheduleRender();\n"
    @"      updateAutoUpdates();\n"
    @"    }\n"
    @"    function appendLogLineFromPush(line){\n"
    @"      const s = (line || '').toString();\n"
    @"      if (!s.length) return;\n"
    @"      lastLogLines.push(s);\n"
    @"      while (lastLogLines.length > MAX_LOG_LINES) lastLogLines.shift();\n"
    @"      try {\n"
    @"        const d = JSON.parse(s);\n"
    @"        if (d && d.event === 'token_usage') {\n"
    @"          lastTokenUsage = {\n"
    @"            requests: Number(d.req || 0),\n"
    @"            input: Number(d.c_in || 0),\n"
    @"            output: Number(d.c_out || 0),\n"
    @"            cached: Number(d.c_cached || 0),\n"
    @"            total: Number(d.c_total || 0),\n"
    @"          };\n"
    @"        }\n"
    @"      } catch (e) {}\n"
    @"      scheduleRender();\n"
    @"    }\n"
    @"    function chatHardLimit(){\n"
    @"      try {\n"
    @"        const ms = Number(((lastStatus && lastStatus.config) ? lastStatus.config.max_steps : 0) || 0);\n"
    @"        const hard = Math.max(200, (Number.isFinite(ms) && ms > 0 ? ms : 60) * 8);\n"
    @"        return hard;\n"
    @"      } catch (e) { return 480; }\n"
    @"    }\n"
    @"    function appendChatItemFromPush(it){\n"
    @"      if (!it) return;\n"
    @"      lastChatItems.push(it);\n"
    @"      const hard = chatHardLimit();\n"
    @"      while (lastChatItems.length > hard) lastChatItems.shift();\n"
    @"      scheduleRender();\n"
    @"    }\n"
    @"    function connectEvents(){\n"
    @"      if (!window.EventSource) return false;\n"
    @"      if (events) return true;\n"
    @"      try {\n"
    @"        const u = new URL('/agent/events', window.location.href);\n"
    @"        u.searchParams.set('include_default_system_prompt','0');\n"
    @"        events = new EventSource(u.toString());\n"
    @"      } catch (e) {\n"
    @"        events = null;\n"
    @"        return false;\n"
    @"      }\n"
    @"      events.addEventListener('snapshot', (ev) => {\n"
    @"        try { applySnapshotFromPush(JSON.parse((ev && ev.data) ? ev.data : '{}')); } catch (e) {}\n"
    @"      });\n"
    @"      events.addEventListener('status', (ev) => {\n"
    @"        try { applyStatusFromPush(JSON.parse((ev && ev.data) ? ev.data : '{}')); } catch (e) {}\n"
    @"      });\n"
    @"      events.addEventListener('log', (ev) => {\n"
    @"        appendLogLineFromPush((ev && ev.data) ? ev.data : '');\n"
    @"      });\n"
    @"      events.addEventListener('chat', (ev) => {\n"
    @"        try { appendChatItemFromPush(JSON.parse((ev && ev.data) ? ev.data : '{}')); } catch (e) {}\n"
    @"      });\n"
    @"      events.addEventListener('ping', (_ev) => {});\n"
    @"      events.onerror = (_ev) => {\n"
    @"        closeEvents();\n"
    @"        updateAutoUpdates();\n"
    @"      };\n"
    @"      return true;\n"
    @"    }\n"
    @"    async function startAutoUpdates(forceRefresh){\n"
    @"      if (!isPageVisible()) return;\n"
    @"      if (isEditing() || composing) { pendingAutoRefresh = true; return; }\n"
    @"      const ok = connectEvents();\n"
    @"      if (!ok || forceRefresh) {\n"
    @"        await refresh();\n"
    @"      }\n"
    @"      updateAutoUpdates();\n"
    @"    }\n"
    @"    document.addEventListener('focusout', () => { setTimeout(maybeApplyPendingAutoRefresh, 0); });\n"
    @"    document.addEventListener('visibilitychange', () => {\n"
    @"      if (document.hidden) {\n"
    @"        closeEvents();\n"
    @"        stopPolling();\n"
    @"      } else {\n"
    @"        startAutoUpdates(true);\n"
    @"      }\n"
    @"    });\n"
    @"    applyI18n();\n"
    @"    initDirtyTracking();\n"
    @"    stripTokenFromURL();\n"
    @"    {\n"
    @"      const modeEl = document.getElementById('chat_mode');\n"
    @"      if (modeEl) {\n"
    @"        const saved = localStorage.getItem('ondevice_agent_chat_mode');\n"
    @"        if (saved) modeEl.value = saved;\n"
    @"        modeEl.addEventListener('change', () => {\n"
    @"          localStorage.setItem('ondevice_agent_chat_mode', modeEl.value);\n"
    @"          renderChat();\n"
    @"        });\n"
    @"      }\n"
    @"    }\n"
    @"    {\n"
    @"      const cb = document.getElementById('chat_show_screenshots');\n"
    @"      if (cb) {\n"
    @"        const saved = localStorage.getItem('ondevice_agent_chat_show_screenshots');\n"
    @"        if (saved === '1') cb.checked = true;\n"
    @"        cb.addEventListener('change', () => {\n"
    @"          localStorage.setItem('ondevice_agent_chat_show_screenshots', cb.checked ? '1' : '');\n"
    @"          renderChat();\n"
    @"        });\n"
    @"      }\n"
    @"    }\n"
    @"    if (document.getElementById('system_prompt') && !document.getElementById('system_prompt').value) {\n"
    @"      document.getElementById('system_prompt').value = DEFAULT_SYSTEM_PROMPT;\n"
    @"    }\n"
    @"    startAutoUpdates(true);\n"
    @"  </script>\n";

  static NSString *const kOnDeviceAgentPageTail =
    @"</body>\n"
    @"</html>\n";

  NSString *html = [@[
    kOnDeviceAgentPageHTMLHead,
    kOnDeviceAgentPageCSS,
    kOnDeviceAgentPageBody,
    kOnDeviceAgentPageJS,
    kOnDeviceAgentPageTail,
  ] componentsJoinedByString:@""];

  NSString *dateZh = OnDeviceAgentFormattedDateZH();
  NSString *dateEn = OnDeviceAgentFormattedDateEN();
  NSString *defaultSystemPrompt = OnDeviceAgentDefaultSystemPromptTemplate();
  NSString *defaultMaxSteps = [NSString stringWithFormat:@"%ld", (long)kOnDeviceAgentDefaultMaxSteps];
  NSString *defaultMaxCompletionTokens = [NSString stringWithFormat:@"%ld", (long)kOnDeviceAgentDefaultMaxCompletionTokens];
  NSString *defaultTimeoutSeconds = [NSString stringWithFormat:@"%g", kOnDeviceAgentDefaultTimeoutSeconds];
  NSString *defaultStepDelaySeconds = [NSString stringWithFormat:@"%g", kOnDeviceAgentDefaultStepDelaySeconds];
  NSString *defaultRefreshIntervalMs = [NSString stringWithFormat:@"%ld", (long)kOnDeviceAgentDefaultRefreshIntervalMs];
  html = [html stringByReplacingOccurrencesOfString:@"__DATE_ZH_EXAMPLE__" withString:OnDeviceAgentHTMLEscape(dateZh)];
  html = [html stringByReplacingOccurrencesOfString:@"__DATE_EN_EXAMPLE__" withString:OnDeviceAgentHTMLEscape(dateEn)];
  html = [html stringByReplacingOccurrencesOfString:@"__DEFAULT_SYSTEM_PROMPT_JSON__" withString:OnDeviceAgentJSONStringLiteral(defaultSystemPrompt)];
  html = [html stringByReplacingOccurrencesOfString:@"__DEFAULT_MAX_STEPS__" withString:defaultMaxSteps];
  html = [html stringByReplacingOccurrencesOfString:@"__DEFAULT_MAX_COMPLETION_TOKENS__" withString:defaultMaxCompletionTokens];
  html = [html stringByReplacingOccurrencesOfString:@"__DEFAULT_TIMEOUT_SECONDS__" withString:defaultTimeoutSeconds];
  html = [html stringByReplacingOccurrencesOfString:@"__DEFAULT_STEP_DELAY_SECONDS__" withString:defaultStepDelaySeconds];
  html = [html stringByReplacingOccurrencesOfString:@"__DEFAULT_REFRESH_INTERVAL_MS__" withString:defaultRefreshIntervalMs];
  return html;
}

static NSString *OnDeviceAgentEditPageHTML(void)
{
  static NSString *const kOnDeviceAgentEditPageHead =
    @"<!doctype html>\n"
    @"<html>\n"
    @"<head>\n"
    @"  <meta charset=\"utf-8\" />\n"
    @"  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1, viewport-fit=cover\" />\n"
    @"  <title>iOS WDA On‑Device Agent Editor</title>\n"
    @"  <style>\n";

  static NSString *const kOnDeviceAgentEditPageCSS =
    @"    :root{color-scheme:light dark;--bg:#fff;--fg:#111;--muted:#666;--card:#f6f6f6;--border:#ccc;--primary:#0a84ff;--danger:#ff3b30;--radius:12px;}\n"
    @"    @media (prefers-color-scheme: dark){:root{--bg:#0b0b0c;--fg:#f2f2f2;--muted:#b0b0b0;--card:#1c1c1e;--border:#3a3a3c;--primary:#0a84ff;--danger:#ff453a;}}\n"
    @"    html,body{height:100%;}\n"
    @"    body{margin:0;background:var(--bg);color:var(--fg);height:100dvh;max-height:100dvh;box-sizing:border-box;padding:16px;padding-left:max(16px,env(safe-area-inset-left));padding-right:max(16px,env(safe-area-inset-right));padding-top:max(16px,env(safe-area-inset-top));padding-bottom:max(16px,env(safe-area-inset-bottom));display:flex;flex-direction:column;gap:10px;font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Roboto,Helvetica,Arial,sans-serif;}\n"
    @"    .bar{display:flex;align-items:center;justify-content:space-between;gap:10px;}\n"
    @"    .title{font-weight:600;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}\n"
    @"    .muted{color:var(--muted);font-size:13px;line-height:1.45;}\n"
    @"    .check{display:flex;align-items:center;gap:10px;user-select:none;}\n"
    @"    .check input{width:auto;transform:scale(1.15);}\n"
    @"    button{min-height:40px;padding:8px 12px;border:0;border-radius:12px;}\n"
    @"    .primary{background:var(--primary);color:#fff;}\n"
    @"    .ghost{background:var(--card);color:inherit;border:1px solid var(--border);}\n"
    @"    textarea{width:100%;flex:1 1 auto;min-height:0;padding:10px 12px;border:1px solid var(--border);border-radius:var(--radius);box-sizing:border-box;font-size:16px;line-height:1.35;background:var(--card);color:inherit;resize:none;}\n"
    @"    textarea:focus{outline:none;border-color:var(--primary);box-shadow:0 0 0 3px rgba(10,132,255,0.25);}\n"
    @"    .mono{font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,\"Liberation Mono\",\"Courier New\",monospace;}\n"
    @"  </style>\n";

	  static NSString *const kOnDeviceAgentEditPageBody =
	    @"</head>\n"
	    @"<body>\n"
	    @"  <div class=\"bar\">\n"
	    @"    <button class=\"ghost\" onclick=\"goBack()\" data-i18n=\"btn_back\">Back</button>\n"
	    @"    <div id=\"title\" class=\"title\">Editor</div>\n"
	    @"    <button id=\"restore_default\" class=\"ghost\" style=\"display:none\" onclick=\"restoreDefault()\" data-i18n=\"btn_restore_default\">Restore default</button>\n"
	    @"    <button class=\"primary\" onclick=\"saveAndClose()\" data-i18n=\"btn_done\">Done</button>\n"
	    @"  </div>\n"
	    @"  <div id=\"hint\" class=\"muted\"></div>\n"
	    @"  <label id=\"custom_row\" class=\"check muted\" style=\"display:none\"><input type=\"checkbox\" id=\"use_custom_system_prompt\" /> <span data-i18n=\"cb_use_custom_system_prompt\">Use custom system prompt</span></label>\n"
	    @"  <textarea id=\"text\" placeholder=\"\"></textarea>\n"
	    @"  <script>\n";

	  static NSString *const kOnDeviceAgentEditPageJS =
	    @"    const DEFAULT_SYSTEM_PROMPT = __DEFAULT_SYSTEM_PROMPT_JSON__;\n"
	    @"    const LANG = ((navigator.language || '').toLowerCase().startsWith('zh')) ? 'zh' : 'en';\n"
	    @"    const I18N = {\n"
	    @"      en: {\n"
	    @"        btn_back: 'Back',\n"
	    @"        btn_restore_default: 'Restore default',\n"
	    @"        btn_done: 'Done',\n"
	    @"        cb_use_custom_system_prompt: 'Use custom system prompt',\n"
	    @"        title_task: 'Task',\n"
	    @"        title_system_prompt: 'System Prompt',\n"
	    @"        title_editor: 'Editor',\n"
	    @"        hint_task: 'Edit the task description.',\n"
	    @"        hint_system_prompt: 'Custom system prompt only takes effect when enabled.',\n"
	    @"        hint_unknown: 'Unknown target.',\n"
	    @"      },\n"
	    @"      zh: {\n"
	    @"        btn_back: '返回',\n"
	    @"        btn_restore_default: '恢复默认',\n"
	    @"        btn_done: '完成',\n"
	    @"        cb_use_custom_system_prompt: '使用自定义系统提示词',\n"
	    @"        title_task: '任务',\n"
	    @"        title_system_prompt: '系统提示词',\n"
	    @"        title_editor: '编辑',\n"
	    @"        hint_task: '编辑任务描述。',\n"
	    @"        hint_system_prompt: '自定义系统提示词仅在勾选后生效。',\n"
	    @"        hint_unknown: '未知目标。',\n"
	    @"      }\n"
	    @"    };\n"
	    @"    function t(key){\n"
	    @"      const table = I18N[LANG] || I18N.en;\n"
	    @"      return (table && table[key]) ? table[key] : ((I18N.en && I18N.en[key]) ? I18N.en[key] : key);\n"
	    @"    }\n"
	    @"    function applyI18n(){\n"
	    @"      const nodes = document.querySelectorAll('[data-i18n]');\n"
	    @"      for (const el of nodes) {\n"
	    @"        const key = el.getAttribute('data-i18n') || '';\n"
	    @"        if (!key) continue;\n"
	    @"        el.textContent = t(key);\n"
	    @"      }\n"
	    @"    }\n"
	    @"    const qs = new URLSearchParams(window.location.search || '');\n"
	    @"    const target = (qs.get('target') || '').toString();\n"
	    @"    let composing = false;\n"
    @"    function isEditing(){\n"
    @"      const el = document.activeElement;\n"
    @"      if (!el || !el.tagName) return false;\n"
    @"      const tag = el.tagName.toLowerCase();\n"
    @"      return tag === 'input' || tag === 'textarea';\n"
    @"    }\n"
    @"    async function commitIME(){\n"
    @"      if (isEditing() && document.activeElement) {\n"
    @"        try { document.activeElement.blur(); } catch (e) {}\n"
    @"        await new Promise(r => setTimeout(r, 50));\n"
    @"      }\n"
    @"      if (composing) {\n"
    @"        await new Promise(r => setTimeout(r, 50));\n"
    @"      }\n"
    @"    }\n"
    @"    function stripTokenFromURL(){\n"
    @"      // Agent Token should never live in the URL longer than the initial page load.\n"
    @"      try {\n"
    @"        const qs = new URLSearchParams(window.location.search || '');\n"
    @"        if (!qs.has('token')) return;\n"
    @"        qs.delete('token');\n"
    @"        const next = window.location.pathname + (qs.toString() ? ('?' + qs.toString()) : '') + (window.location.hash || '');\n"
    @"        window.history.replaceState({}, '', next);\n"
    @"      } catch (e) {}\n"
    @"    }\n"
    @"    async function api(path, method, body){\n"
    @"      const opts = {method: method || 'GET', credentials: 'same-origin'};\n"
    @"      const headers = {};\n"
    @"      if (body){ headers['Content-Type'] = 'application/json'; opts.body = JSON.stringify(body); }\n"
    @"      if (Object.keys(headers).length > 0) { opts.headers = headers; }\n"
    @"      const r = await fetch(path, opts);\n"
    @"      const j = await r.json().catch(() => ({}));\n"
    @"      if (!r.ok) {\n"
    @"        const msg = ((j.value && j.value.error) || j.error || `HTTP ${r.status}`);\n"
    @"        throw new Error(msg);\n"
    @"      }\n"
    @"      return j.value || {};\n"
    @"    }\n"
    @"    function updateViewport(){\n"
    @"      const vv = window.visualViewport;\n"
    @"      if (!vv) return;\n"
    @"      document.body.style.height = vv.height + 'px';\n"
    @"      document.body.style.transform = `translateY(${vv.offsetTop || 0}px)`;\n"
    @"    }\n"
	    @"    async function load(){\n"
	    @"      updateViewport();\n"
	    @"      applyI18n();\n"
	    @"      const st = await api('/agent/status');\n"
	    @"      const cfg = st.config || {};\n"
    @"      const titleEl = document.getElementById('title');\n"
    @"      const hintEl = document.getElementById('hint');\n"
    @"      const ta = document.getElementById('text');\n"
    @"      const customRow = document.getElementById('custom_row');\n"
    @"      const useCustom = document.getElementById('use_custom_system_prompt');\n"
	    @"      const restoreBtn = document.getElementById('restore_default');\n"
	    @"      if (!titleEl || !hintEl || !ta || !customRow || !useCustom || !restoreBtn) return;\n"
	    @"      if (target === 'task') {\n"
	    @"        titleEl.textContent = t('title_task');\n"
	    @"        hintEl.textContent = t('hint_task');\n"
	    @"        ta.className = '';\n"
	    @"        ta.value = (cfg.task || '').toString();\n"
	    @"        customRow.style.display = 'none';\n"
	    @"        restoreBtn.style.display = 'none';\n"
	    @"      } else if (target === 'system_prompt') {\n"
	    @"        titleEl.textContent = t('title_system_prompt');\n"
	    @"        hintEl.textContent = t('hint_system_prompt');\n"
	    @"        ta.className = 'mono';\n"
	    @"        const sp = (cfg.system_prompt || '').toString();\n"
    @"        ta.value = sp.length ? sp : DEFAULT_SYSTEM_PROMPT;\n"
    @"        customRow.style.display = '';\n"
	    @"        useCustom.checked = !!cfg.use_custom_system_prompt;\n"
	    @"        restoreBtn.style.display = '';\n"
	    @"      } else {\n"
	    @"        titleEl.textContent = t('title_editor');\n"
	    @"        hintEl.textContent = t('hint_unknown');\n"
	    @"        ta.className = 'mono';\n"
	    @"        ta.value = '';\n"
    @"        customRow.style.display = 'none';\n"
    @"        restoreBtn.style.display = 'none';\n"
    @"      }\n"
    @"      ta.addEventListener('compositionstart', () => { composing = true; });\n"
    @"      ta.addEventListener('compositionend', () => { composing = false; });\n"
    @"      try { ta.focus(); } catch (e) {}\n"
    @"    }\n"
    @"    function goBack(){ window.location.href = '/agent'; }\n"
    @"    function restoreDefault(){\n"
    @"      if (target !== 'system_prompt') return;\n"
    @"      const ta = document.getElementById('text');\n"
    @"      if (!ta) return;\n"
    @"      ta.value = DEFAULT_SYSTEM_PROMPT;\n"
    @"    }\n"
    @"    async function saveAndClose(){\n"
    @"      await commitIME();\n"
    @"      const ta = document.getElementById('text');\n"
    @"      if (!ta) return;\n"
    @"      const payload = {};\n"
    @"      if (target === 'task') {\n"
    @"        payload.task = (ta.value || '').toString();\n"
    @"      } else if (target === 'system_prompt') {\n"
    @"        payload.system_prompt = (ta.value || '').toString();\n"
    @"        const useCustom = document.getElementById('use_custom_system_prompt');\n"
    @"        payload.use_custom_system_prompt = !!(useCustom && useCustom.checked);\n"
    @"      }\n"
    @"      if (Object.keys(payload).length) {\n"
    @"        await api('/agent/config', 'POST', payload);\n"
    @"      }\n"
    @"      goBack();\n"
    @"    }\n"
    @"    if (window.visualViewport) {\n"
    @"      try {\n"
    @"        window.visualViewport.addEventListener('resize', updateViewport);\n"
    @"        window.visualViewport.addEventListener('scroll', updateViewport);\n"
    @"      } catch (e) {}\n"
    @"    }\n"
    @"    stripTokenFromURL();\n"
    @"    load();\n"
    @"  </script>\n";

  static NSString *const kOnDeviceAgentEditPageTail =
    @"</body>\n"
    @"</html>\n";

  NSString *html = [@[
    kOnDeviceAgentEditPageHead,
    kOnDeviceAgentEditPageCSS,
    kOnDeviceAgentEditPageBody,
    kOnDeviceAgentEditPageJS,
    kOnDeviceAgentEditPageTail,
  ] componentsJoinedByString:@""];

  NSString *defaultSystemPrompt = OnDeviceAgentDefaultSystemPromptTemplate();
  html = [html stringByReplacingOccurrencesOfString:@"__DEFAULT_SYSTEM_PROMPT_JSON__" withString:OnDeviceAgentJSONStringLiteral(defaultSystemPrompt)];
  return html;
}

@interface FBOnDeviceAgentCommands : NSObject <FBCommandHandler>
@end

@implementation FBOnDeviceAgentCommands

+ (NSArray *)routes
{
  return @[
    [[FBRoute GET:@"/agent"].withoutSession respondWithTarget:self action:@selector(handleGetPage:)],
    [[FBRoute GET:@"/agent/edit"].withoutSession respondWithTarget:self action:@selector(handleGetEditPage:)],
    [[FBRoute GET:@"/agent/status"].withoutSession respondWithTarget:self action:@selector(handleGetStatus:)],
    [[FBRoute GET:@"/agent/logs"].withoutSession respondWithTarget:self action:@selector(handleGetLogs:)],
    [[FBRoute GET:@"/agent/chat"].withoutSession respondWithTarget:self action:@selector(handleGetChat:)],
    [[FBRoute GET:@"/agent/events"].withoutSession respondWithTarget:self action:@selector(handleGetEvents:)],
    [[FBRoute GET:@"/agent/step_screenshot"].withoutSession respondWithTarget:self action:@selector(handleGetStepScreenshot:)],
    [[FBRoute GET:@"/agent/step_screenshots"].withoutSession respondWithTarget:self action:@selector(handleGetStepScreenshots:)],
    [[FBRoute POST:@"/agent/config"].withoutSession respondWithTarget:self action:@selector(handlePostConfig:)],
    [[FBRoute POST:@"/agent/rotate_token"].withoutSession respondWithTarget:self action:@selector(handlePostRotateToken:)],
    [[FBRoute POST:@"/agent/start"].withoutSession respondWithTarget:self action:@selector(handlePostStart:)],
    [[FBRoute POST:@"/agent/stop"].withoutSession respondWithTarget:self action:@selector(handlePostStop:)],
    [[FBRoute POST:@"/agent/reset"].withoutSession respondWithTarget:self action:@selector(handlePostReset:)],
    [[FBRoute POST:@"/agent/factory_reset"].withoutSession respondWithTarget:self action:@selector(handlePostFactoryReset:)],
  ];
}

+ (id<FBResponsePayload>)handleGetPage:(FBRouteRequest *)request
{
  NSString *authError = nil;
  if (!OnDeviceAgentAuthorizeAgentPageRoute(request, &authError)) {
    return OnDeviceAgentUnauthorizedPayload(authError);
  }

  // If a valid token is supplied via query (?token=...), upgrade it into a session HttpOnly cookie
  // so subsequent requests don't need a token in the URL.
  NSDictionary<NSString *, NSString *> *headers = @{};
  NSString *queryToken = OnDeviceAgentQueryValueCaseInsensitive(request.URL, kOnDeviceAgentAgentTokenQueryParam);
  if (queryToken.length > 0) {
    NSString *expected = [[OnDeviceAgentManager shared] agentToken];
    if (expected.length > 0 && [queryToken isEqualToString:expected]) {
      NSString *cookie = OnDeviceAgentAgentTokenCookieHeaderValue(queryToken);
      if (cookie.length > 0) {
        headers = @{@"Set-Cookie": cookie};
      }
    }
  }

  if (OnDeviceAgentIsLocalhostRequest(request)) {
    OnDeviceAgentTriggerWirelessDataPromptIfNeeded();
  }

  return [[OnDeviceAgentTextPayload alloc] initWithText:OnDeviceAgentPageHTML()
                                     contentType:@"text/html;charset=UTF-8"
                                      statusCode:kHTTPStatusCodeOK
                                         headers:headers];
}

+ (id<FBResponsePayload>)handleGetEditPage:(FBRouteRequest *)request
{
  NSString *authError = nil;
  if (!OnDeviceAgentAuthorizeAgentPageRoute(request, &authError)) {
    return OnDeviceAgentUnauthorizedPayload(authError);
  }

  NSDictionary<NSString *, NSString *> *headers = @{};
  NSString *queryToken = OnDeviceAgentQueryValueCaseInsensitive(request.URL, kOnDeviceAgentAgentTokenQueryParam);
  if (queryToken.length > 0) {
    NSString *expected = [[OnDeviceAgentManager shared] agentToken];
    if (expected.length > 0 && [queryToken isEqualToString:expected]) {
      NSString *cookie = OnDeviceAgentAgentTokenCookieHeaderValue(queryToken);
      if (cookie.length > 0) {
        headers = @{@"Set-Cookie": cookie};
      }
    }
  }

  return [[OnDeviceAgentTextPayload alloc] initWithText:OnDeviceAgentEditPageHTML()
                                     contentType:@"text/html;charset=UTF-8"
                                      statusCode:kHTTPStatusCodeOK
                                         headers:headers];
}

+ (id<FBResponsePayload>)handleGetStatus:(FBRouteRequest *)request
{
  NSString *authError = nil;
  if (!OnDeviceAgentAuthorizeAgentRoute(request, &authError)) {
    return OnDeviceAgentUnauthorizedPayload(authError);
  }
  BOOL includeDefaultSystemPrompt = OnDeviceAgentParseBool(request.parameters[@"include_default_system_prompt"], NO);
  return FBResponseWithObject([[OnDeviceAgentManager shared] statusWithDefaultSystemPrompt:includeDefaultSystemPrompt]);
}

+ (id<FBResponsePayload>)handleGetLogs:(FBRouteRequest *)request
{
  NSString *authError = nil;
  if (!OnDeviceAgentAuthorizeAgentRoute(request, &authError)) {
    return OnDeviceAgentUnauthorizedPayload(authError);
  }
  return FBResponseWithObject(@{@"lines": [[OnDeviceAgentManager shared] logs]});
}

+ (id<FBResponsePayload>)handleGetChat:(FBRouteRequest *)request
{
  NSString *authError = nil;
  if (!OnDeviceAgentAuthorizeAgentRoute(request, &authError)) {
    return OnDeviceAgentUnauthorizedPayload(authError);
  }
  return FBResponseWithObject(@{@"items": [[OnDeviceAgentManager shared] chat]});
}

+ (id<FBResponsePayload>)handleGetEvents:(FBRouteRequest *)request
{
  NSString *authError = nil;
  if (!OnDeviceAgentAuthorizeAgentRoute(request, &authError)) {
    return OnDeviceAgentUnauthorizedPayload(authError);
  }
  BOOL includeDefaultSystemPrompt = OnDeviceAgentParseBool(request.parameters[@"include_default_system_prompt"], NO);
  return [[OnDeviceAgentEventStreamPayload alloc] initWithIncludeDefaultSystemPrompt:includeDefaultSystemPrompt];
}

+ (id<FBResponsePayload>)handleGetStepScreenshot:(FBRouteRequest *)request
{
  NSString *authError = nil;
  if (!OnDeviceAgentAuthorizeAgentRoute(request, &authError)) {
    return OnDeviceAgentUnauthorizedPayload(authError);
  }
  NSInteger step = -1;
  if (!OnDeviceAgentParseIntStrict(request.parameters[@"step"], &step) || step < 0) {
    return OnDeviceAgentBadRequestPayload(@"Invalid query parameter: step (must be integer >= 0)");
  }
  NSString *b64 = [[OnDeviceAgentManager shared] stepScreenshotBase64ForStep:step] ?: @"";
  if (b64.length == 0) {
    return FBResponseWithObject(@{@"ok": @NO, @"error": @"Screenshot not found"});
  }
  return FBResponseWithObject(@{@"ok": @YES, @"step": @(step), @"png_base64": b64});
}

+ (id<FBResponsePayload>)handleGetStepScreenshots:(FBRouteRequest *)request
{
  NSString *authError = nil;
  if (!OnDeviceAgentAuthorizeAgentRoute(request, &authError)) {
    return OnDeviceAgentUnauthorizedPayload(authError);
  }

  NSString *format = OnDeviceAgentTrim(OnDeviceAgentStringOrEmpty(request.parameters[@"format"]));
  NSString *stepsRaw = OnDeviceAgentTrim(OnDeviceAgentStringOrEmpty(request.parameters[@"steps"]));
  NSInteger limit = 60;
  if ([request.parameters objectForKey:@"limit"] != nil) {
    if (!OnDeviceAgentParseIntStrict(request.parameters[@"limit"], &limit) || limit <= 0) {
      return OnDeviceAgentBadRequestPayload(@"Invalid query parameter: limit (must be integer > 0)");
    }
  }
  double quality = 0.7;
  if ([request.parameters objectForKey:@"quality"] != nil) {
    if (!OnDeviceAgentParseDoubleStrict(request.parameters[@"quality"], &quality) || !isfinite(quality) || quality <= 0 || quality > 1) {
      return OnDeviceAgentBadRequestPayload(@"Invalid query parameter: quality (must be number in (0,1])");
    }
  }

  NSMutableOrderedSet<NSNumber *> *steps = [NSMutableOrderedSet orderedSet];
  if (stepsRaw.length > 0) {
    NSArray<NSString *> *parts = [stepsRaw componentsSeparatedByString:@","];
    for (NSString *p in parts) {
      NSString *t = OnDeviceAgentTrim(p ?: @"");
      if (t.length == 0) {
        continue;
      }
      NSInteger step = -1;
      if (!OnDeviceAgentParseIntStrict(t, &step) || step < 0) {
        return OnDeviceAgentBadRequestPayload(@"Invalid query parameter: steps (must be comma-separated integers >= 0)");
      }
      [steps addObject:@(step)];
    }
  }

  NSArray<NSNumber *> *want = (steps.count > 0) ? steps.array : @[];
  NSDictionary *obj = [[OnDeviceAgentManager shared] stepScreenshotsBase64WithSteps:want limit:limit format:format quality:quality] ?: @{};
  return FBResponseWithObject(obj);
}

+ (id<FBResponsePayload>)handlePostConfig:(FBRouteRequest *)request
{
  NSString *authError = nil;
  if (!OnDeviceAgentAuthorizeAgentRoute(request, &authError)) {
    return OnDeviceAgentUnauthorizedPayload(authError);
  }
  __block BOOL ok = YES;
  __block NSString *errMsg = nil;
  dispatch_sync([OnDeviceAgentManager shared].stateQueue, ^{
    ok = [[OnDeviceAgentManager shared] updateConfigWithArguments:request.arguments ?: @{} errorMessage:&errMsg];
  });
  if (!ok) {
    return OnDeviceAgentBadRequestPayload(errMsg ?: @"Invalid config update");
  }
  NSDictionary *st = [[OnDeviceAgentManager shared] status];
  [[OnDeviceAgentEventHub shared] broadcastJSONObject:st event:@"status"];
  return FBResponseWithObject(st);
}

+ (id<FBResponsePayload>)handlePostRotateToken:(FBRouteRequest *)request
{
  NSString *authError = nil;
  if (!OnDeviceAgentAuthorizeAgentRoute(request, &authError)) {
    return OnDeviceAgentUnauthorizedPayload(authError);
  }

  NSString *newToken = OnDeviceAgentGenerateAgentToken();
  if (newToken.length == 0) {
    return OnDeviceAgentBadRequestPayload(@"Failed to generate token");
  }

  __block BOOL ok = YES;
  __block NSString *errMsg = nil;
  dispatch_sync([OnDeviceAgentManager shared].stateQueue, ^{
    ok = [[OnDeviceAgentManager shared] updateConfigWithArguments:@{@"agent_token": newToken} errorMessage:&errMsg];
  });
  if (!ok) {
    return OnDeviceAgentBadRequestPayload(errMsg ?: @"rotate_token failed");
  }

  NSDictionary *st = [[OnDeviceAgentManager shared] status];
  [[OnDeviceAgentEventHub shared] broadcastJSONObject:st event:@"status"];

  NSString *cookie = OnDeviceAgentAgentTokenCookieHeaderValue(newToken);
  NSDictionary *headers = (cookie.length > 0) ? @{@"Set-Cookie": cookie} : @{};
  NSDictionary *obj = @{
    @"ok": @YES,
    @"agent_token": newToken,
    @"status": st ?: @{},
  };
  return [[OnDeviceAgentJSONPayload alloc] initWithObject:obj statusCode:kHTTPStatusCodeOK headers:headers];
}

+ (id<FBResponsePayload>)handlePostStart:(FBRouteRequest *)request
{
  NSString *authError = nil;
  if (!OnDeviceAgentAuthorizeAgentRoute(request, &authError)) {
    return OnDeviceAgentUnauthorizedPayload(authError);
  }
  NSError *err = nil;
  if (![[OnDeviceAgentManager shared] startWithArguments:request.arguments ?: @{} error:&err]) {
    return FBResponseWithObject(@{@"ok": @NO, @"error": err.localizedDescription ?: @"start failed", @"status": [[OnDeviceAgentManager shared] status]});
  }
  return FBResponseWithObject(@{@"ok": @YES, @"status": [[OnDeviceAgentManager shared] status]});
}

+ (id<FBResponsePayload>)handlePostStop:(FBRouteRequest *)request
{
  NSString *authError = nil;
  if (!OnDeviceAgentAuthorizeAgentRoute(request, &authError)) {
    return OnDeviceAgentUnauthorizedPayload(authError);
  }
  [[OnDeviceAgentManager shared] stop];
  return FBResponseWithObject([[OnDeviceAgentManager shared] status]);
}

+ (id<FBResponsePayload>)handlePostReset:(FBRouteRequest *)request
{
  NSString *authError = nil;
  if (!OnDeviceAgentAuthorizeAgentRoute(request, &authError)) {
    return OnDeviceAgentUnauthorizedPayload(authError);
  }
  [[OnDeviceAgentManager shared] resetRuntime];
  return FBResponseWithObject([[OnDeviceAgentManager shared] status]);
}

+ (id<FBResponsePayload>)handlePostFactoryReset:(FBRouteRequest *)request
{
  NSString *authError = nil;
  if (!OnDeviceAgentAuthorizeAgentRoute(request, &authError)) {
    return OnDeviceAgentUnauthorizedPayload(authError);
  }
  [[OnDeviceAgentManager shared] factoryReset];
  return FBResponseWithObject([[OnDeviceAgentManager shared] status]);
}

@end

@interface UITestingUITests : FBFailureProofTestCase <FBWebServerDelegate>
@end

@implementation UITestingUITests

+ (void)setUp
{
  [FBDebugLogDelegateDecorator decorateXCTestLogger];
  [FBConfiguration disableRemoteQueryEvaluation];
  [FBConfiguration configureDefaultKeyboardPreferences];
  [FBConfiguration disableApplicationUIInterruptionsHandling];
  if (NSProcessInfo.processInfo.environment[@"ENABLE_AUTOMATIC_SCREEN_RECORDINGS"]) {
    [FBConfiguration enableScreenRecordings];
  } else {
    [FBConfiguration disableScreenRecordings];
  }
  if (NSProcessInfo.processInfo.environment[@"ENABLE_AUTOMATIC_SCREENSHOTS"]) {
    [FBConfiguration enableScreenshots];
  } else {
    [FBConfiguration disableScreenshots];
  }
  OnDeviceAgentConfigureNotificationsPromptIfNeeded();
  OnDeviceAgentTriggerWirelessDataPromptIfNeeded();
  [super setUp];
}

/**
 Never ending test used to start WebDriverAgent
 */
- (void)testRunner
{
  FBWebServer *webServer = [[FBWebServer alloc] init];
  webServer.delegate = self;
  [webServer startServing];
}

#pragma mark - FBWebServerDelegate

- (void)webServerDidRequestShutdown:(FBWebServer *)webServer
{
  [webServer stopServing];
}

@end
