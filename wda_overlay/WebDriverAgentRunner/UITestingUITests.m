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

static NSData *OnDeviceAgentDownscalePNGHalf(NSData *png);

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

#import "OnDeviceAgentRedaction.m"
#import "OnDeviceAgentSecurity.m"

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

#import "OnDeviceAgentPrompts.m"

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

#import "OnDeviceAgentMemory.m"
#import "OnDeviceAgentModelClient.m"
#import "OnDeviceAgentActions.m"

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

#import "OnDeviceAgentExports.m"

#import "OnDeviceAgentWebUI.m"

#import "OnDeviceAgentRoutes.m"

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
