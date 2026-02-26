#import <Foundation/Foundation.h>

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


@interface OnDeviceAgent (Actions)
- (BOOL)performAction:(NSDictionary *)action error:(NSError **)error;
@end

@implementation OnDeviceAgent (Actions)

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

@end
