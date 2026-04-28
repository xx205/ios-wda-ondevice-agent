#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface OnDeviceAgentTraceRecorder : NSObject
+ (NSString *)defaultRootDirectory;
+ (NSArray<NSDictionary *> *)traceSummariesAtRootDirectory:(NSString *)rootDirectory;
+ (NSDictionary *)manifestForRunId:(NSString *)runId rootDirectory:(NSString *)rootDirectory;
+ (NSString *)textFileForRunId:(NSString *)runId name:(NSString *)name rootDirectory:(NSString *)rootDirectory;
+ (NSDictionary *)fileBase64ForRunId:(NSString *)runId relativePath:(NSString *)relativePath rootDirectory:(NSString *)rootDirectory;
- (instancetype)initWithRootDirectory:(NSString *)rootDirectory;
- (NSDictionary *)startRunWithConfig:(NSDictionary *)config
                                 task:(NSString *)task
                 renderedSystemPrompt:(NSString *)systemPrompt
                       defaultTemplate:(NSString *)defaultTemplate;
- (void)appendLogLine:(NSString *)line;
- (NSDictionary *)saveImagePNG:(NSData *)png step:(NSInteger)step stage:(NSString *)stage;
- (void)appendEvent:(NSString *)type payload:(NSDictionary *)payload;
- (void)appendTurn:(NSDictionary *)turn;
- (void)finishRunWithSuccess:(BOOL)success message:(NSString *)message stopReason:(NSString *)stopReason;
- (NSDictionary *)statusSnapshot;
@end

@interface OnDeviceAgentTraceRecorder ()
@property (nonatomic, copy) NSString *rootDirectory;
@property (nonatomic, copy) NSString *runDirectory;
@property (nonatomic, copy) NSString *runId;
@property (nonatomic, copy) NSString *startedAt;
@property (nonatomic, copy) NSString *finishedAt;
@property (nonatomic, copy) NSDictionary *manifest;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, assign) long long seq;
@property (nonatomic, assign) NSInteger logCount;
@property (nonatomic, assign) NSInteger eventCount;
@property (nonatomic, assign) NSInteger turnCount;
@property (nonatomic, assign) NSInteger imageCount;
@property (nonatomic, assign) BOOL recording;
@property (nonatomic, strong) NSMutableArray<NSString *> *warnings;
@end

static NSString *OnDeviceAgentTraceNowString(void)
{
  NSDateFormatter *fmt = [NSDateFormatter new];
  fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
  fmt.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ";
  return [fmt stringFromDate:[NSDate date]] ?: @"";
}

static NSString *OnDeviceAgentTraceRunTimestamp(void)
{
  NSDateFormatter *fmt = [NSDateFormatter new];
  fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
  fmt.dateFormat = @"yyyy-MM-dd_HH-mm-ss";
  return [fmt stringFromDate:[NSDate date]] ?: @"unknown";
}

static NSData *OnDeviceAgentTraceJSONData(id obj)
{
  if (obj == nil || ![NSJSONSerialization isValidJSONObject:obj]) {
    obj = @{};
  }
  NSError *err = nil;
  NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:&err];
  return (data.length > 0 && err == nil) ? data : [@"{}" dataUsingEncoding:NSUTF8StringEncoding];
}

static NSString *OnDeviceAgentTraceJSONString(id obj)
{
  NSData *data = OnDeviceAgentTraceJSONData(obj);
  return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"{}";
}

static NSDictionary *OnDeviceAgentTraceJSONObjectFromFile(NSString *path)
{
  NSData *data = [NSData dataWithContentsOfFile:path ?: @""];
  if (data.length == 0) {
    return @{};
  }
  id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  return [obj isKindOfClass:NSDictionary.class] ? (NSDictionary *)obj : @{};
}

static NSString *OnDeviceAgentTraceSafeName(NSString *raw)
{
  NSString *s = raw ?: @"";
  NSMutableString *out = [NSMutableString string];
  NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-."];
  for (NSUInteger i = 0; i < s.length; i++) {
    unichar ch = [s characterAtIndex:i];
    if ([allowed characterIsMember:ch]) {
      [out appendFormat:@"%C", ch];
    }
  }
  return out.length > 0 ? out.copy : @"";
}

static BOOL OnDeviceAgentTraceIsDotOnlyName(NSString *name)
{
  NSString *s = name ?: @"";
  if (s.length == 0) {
    return YES;
  }
  NSCharacterSet *notDot = [[NSCharacterSet characterSetWithCharactersInString:@"."] invertedSet];
  return [s rangeOfCharacterFromSet:notDot].location == NSNotFound;
}

static NSString *OnDeviceAgentTraceSafeRunId(NSString *raw)
{
  NSString *s = raw ?: @"";
  NSString *safe = OnDeviceAgentTraceSafeName(s);
  if (safe.length == 0 || ![safe isEqualToString:s] || OnDeviceAgentTraceIsDotOnlyName(safe)) {
    return @"";
  }
  return safe;
}

static id OnDeviceAgentTraceJSONValue(id value)
{
  if (value == nil || value == [NSNull null]) {
    return nil;
  }
  if (![NSJSONSerialization isValidJSONObject:@{@"value": value}]) {
    return nil;
  }
  return value;
}

static void OnDeviceAgentTraceSetConfigAlias(NSMutableDictionary *out, NSDictionary *config, NSString *alias, NSString *rawKey)
{
  id value = OnDeviceAgentTraceJSONValue(config[alias]);
  if (value == nil) {
    value = OnDeviceAgentTraceJSONValue(config[rawKey]);
  }
  if (value != nil) {
    out[alias] = value;
  }
}

static BOOL OnDeviceAgentTraceConfigValuePresent(NSDictionary *config, NSString *alias, NSString *rawKey)
{
  id value = config[alias];
  if (value == nil || value == [NSNull null]) {
    value = config[rawKey];
  }
  if ([value isKindOfClass:NSString.class]) {
    return ((NSString *)value).length > 0;
  }
  return value != nil && value != [NSNull null];
}

static NSDictionary *OnDeviceAgentTraceNormalizedConfigAliases(NSDictionary *config)
{
  NSMutableDictionary *aliases = [NSMutableDictionary dictionary];
  NSArray<NSArray<NSString *> *> *pairs = @[
    @[@"task", @"ONDEVICE_AGENT_TASK"],
    @[@"base_url", @"ONDEVICE_AGENT_BASE_URL"],
    @[@"model", @"ONDEVICE_AGENT_MODEL"],
    @[@"api_mode", @"ONDEVICE_AGENT_API_MODE"],
    @[@"use_custom_system_prompt", @"ONDEVICE_AGENT_USE_CUSTOM_SYSTEM_PROMPT"],
    @[@"system_prompt", @"ONDEVICE_AGENT_CUSTOM_SYSTEM_PROMPT"],
    @[@"reasoning_effort", @"ONDEVICE_AGENT_REASONING_EFFORT"],
    @[@"doubao_seed_enable_session_cache", @"ONDEVICE_AGENT_DOUBAO_SEED_ENABLE_SESSION_CACHE"],
    @[@"half_res_screenshot", @"ONDEVICE_AGENT_HALF_RES_SCREENSHOT"],
    @[@"use_w3c_actions_for_swipe", @"ONDEVICE_AGENT_USE_W3C_ACTIONS_FOR_SWIPE"],
    @[@"restart_responses_by_plan", @"ONDEVICE_AGENT_RESTART_RESPONSES_BY_PLAN"],
    @[@"max_completion_tokens", @"ONDEVICE_AGENT_MAX_COMPLETION_TOKENS"],
    @[@"max_steps", @"ONDEVICE_AGENT_MAX_STEPS"],
    @[@"timeout_seconds", @"ONDEVICE_AGENT_TIMEOUT_SECONDS"],
    @[@"step_delay_seconds", @"ONDEVICE_AGENT_STEP_DELAY_SECONDS"],
    @[@"insecure_skip_tls_verify", @"ONDEVICE_AGENT_INSECURE_SKIP_TLS_VERIFY"],
    @[@"debug_log_raw_assistant", @"ONDEVICE_AGENT_DEBUG_LOG_RAW_ASSISTANT"],
    @[@"remember_api_key", @"ONDEVICE_AGENT_REMEMBER_API_KEY"],
  ];
  for (NSArray<NSString *> *pair in pairs) {
    if (pair.count < 2) {
      continue;
    }
    OnDeviceAgentTraceSetConfigAlias(aliases, config, pair[0], pair[1]);
  }
  aliases[@"api_key_set"] = @(OnDeviceAgentTraceConfigValuePresent(config, @"api_key", @"ONDEVICE_AGENT_API_KEY"));
  aliases[@"agent_token_set"] = @(OnDeviceAgentTraceConfigValuePresent(config, @"agent_token", @"ONDEVICE_AGENT_AGENT_TOKEN"));
  return aliases.copy;
}

static NSDictionary *OnDeviceAgentTraceSanitizedConfig(NSDictionary *config)
{
  if (![config isKindOfClass:NSDictionary.class]) {
    return @{};
  }
  NSMutableDictionary *out = [NSMutableDictionary dictionary];
  for (id keyObj in config) {
    if (![keyObj isKindOfClass:NSString.class]) {
      continue;
    }
    NSString *key = (NSString *)keyObj;
    id value = config[keyObj];
    NSString *lower = key.lowercaseString ?: @"";
    BOOL apiKeySecret = [lower isEqualToString:@"api_key"]
      || [lower isEqualToString:@"ondevice_agent_api_key"]
      || ([lower hasSuffix:@"_api_key"] && [lower rangeOfString:@"remember"].location == NSNotFound);
    BOOL agentTokenSecret = [lower isEqualToString:@"agent_token"]
      || [lower isEqualToString:@"ondevice_agent_agent_token"]
      || [lower hasSuffix:@"_agent_token"];
    BOOL sensitive = apiKeySecret
      || agentTokenSecret
      || [lower containsString:@"password"]
      || [lower containsString:@"secret"]
      || [lower containsString:@"authorization"]
      || [lower containsString:@"bearer"];
    if (sensitive) {
      NSString *presenceKey = [key stringByAppendingString:@"_set"];
      BOOL present = NO;
      if ([value isKindOfClass:NSString.class]) {
        present = ((NSString *)value).length > 0;
      } else {
        present = value != nil && value != [NSNull null];
      }
      out[presenceKey] = @(present);
      continue;
    }
    if (value == nil) {
      continue;
    }
    if ([NSJSONSerialization isValidJSONObject:@{key: value}]) {
      out[key] = value;
    }
  }
  [out addEntriesFromDictionary:OnDeviceAgentTraceNormalizedConfigAliases(config)];
  return out.copy;
}

static void OnDeviceAgentTraceAppendLine(NSString *path, NSDictionary *obj)
{
  NSString *line = [OnDeviceAgentTraceJSONString(obj) stringByAppendingString:@"\n"];
  NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
  if (data.length == 0) {
    return;
  }
  NSFileManager *fm = NSFileManager.defaultManager;
  if (![fm fileExistsAtPath:path]) {
    [fm createFileAtPath:path contents:nil attributes:nil];
  }
  NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
  if (h == nil) {
    return;
  }
  @try {
    [h seekToEndOfFile];
    [h writeData:data];
  } @catch (__unused NSException *exception) {
  } @finally {
    [h closeFile];
  }
}

@implementation OnDeviceAgentTraceRecorder

+ (NSString *)defaultRootDirectory
{
  NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
  NSString *base = paths.firstObject ?: NSTemporaryDirectory();
  return [base stringByAppendingPathComponent:@"OnDeviceAgentTraces"];
}

+ (NSString *)runDirectoryForRunId:(NSString *)runId rootDirectory:(NSString *)rootDirectory
{
  NSString *safe = OnDeviceAgentTraceSafeRunId(runId);
  if (safe.length == 0) {
    return @"";
  }
  NSString *root = rootDirectory.length > 0 ? rootDirectory : [self defaultRootDirectory];
  NSString *dir = [root stringByAppendingPathComponent:safe];
  BOOL isDir = NO;
  if (![NSFileManager.defaultManager fileExistsAtPath:dir isDirectory:&isDir] || !isDir) {
    return @"";
  }
  return dir;
}

+ (NSArray<NSDictionary *> *)traceSummariesAtRootDirectory:(NSString *)rootDirectory
{
  NSString *root = rootDirectory.length > 0 ? rootDirectory : [self defaultRootDirectory];
  NSArray<NSString *> *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil] ?: @[];
  NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
  for (NSString *name in names) {
    NSString *safe = OnDeviceAgentTraceSafeName(name);
    if (safe.length == 0 || ![safe isEqualToString:name] || OnDeviceAgentTraceIsDotOnlyName(safe)) {
      continue;
    }
    NSString *dir = [root stringByAppendingPathComponent:name];
    BOOL isDir = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:dir isDirectory:&isDir] || !isDir) {
      continue;
    }
    NSDictionary *m = OnDeviceAgentTraceJSONObjectFromFile([dir stringByAppendingPathComponent:@"manifest.json"]);
    if (m.count == 0) {
      continue;
    }
    NSMutableDictionary *summary = [NSMutableDictionary dictionary];
    summary[@"run_id"] = [m[@"run_id"] isKindOfClass:NSString.class] ? m[@"run_id"] : name;
    summary[@"started_at"] = [m[@"started_at"] isKindOfClass:NSString.class] ? m[@"started_at"] : @"";
    summary[@"finished_at"] = [m[@"finished_at"] isKindOfClass:NSString.class] ? m[@"finished_at"] : @"";
    summary[@"schema"] = [m[@"schema"] isKindOfClass:NSString.class] ? m[@"schema"] : @"";
    summary[@"counts"] = [m[@"counts"] isKindOfClass:NSDictionary.class] ? m[@"counts"] : @{};
    summary[@"final_status"] = [m[@"final_status"] isKindOfClass:NSDictionary.class] ? m[@"final_status"] : @{};
    [items addObject:summary.copy];
  }
  [items sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
    NSString *as = [a[@"started_at"] isKindOfClass:NSString.class] ? a[@"started_at"] : @"";
    NSString *bs = [b[@"started_at"] isKindOfClass:NSString.class] ? b[@"started_at"] : @"";
    return [bs compare:as];
  }];
  return items.copy;
}

+ (NSDictionary *)manifestForRunId:(NSString *)runId rootDirectory:(NSString *)rootDirectory
{
  NSString *dir = [self runDirectoryForRunId:runId rootDirectory:rootDirectory];
  if (dir.length == 0) {
    return @{};
  }
  return OnDeviceAgentTraceJSONObjectFromFile([dir stringByAppendingPathComponent:@"manifest.json"]);
}

+ (NSString *)textFileForRunId:(NSString *)runId name:(NSString *)name rootDirectory:(NSString *)rootDirectory
{
  NSString *safeName = OnDeviceAgentTraceSafeName(name);
  if (safeName.length == 0 || ![safeName isEqualToString:name]) {
    return @"";
  }
  NSString *dir = [self runDirectoryForRunId:runId rootDirectory:rootDirectory];
  if (dir.length == 0) {
    return @"";
  }
  NSString *path = [dir stringByAppendingPathComponent:safeName];
  NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
  return text ?: @"";
}

+ (NSDictionary *)fileBase64ForRunId:(NSString *)runId relativePath:(NSString *)relativePath rootDirectory:(NSString *)rootDirectory
{
  NSString *rel = relativePath ?: @"";
  if (rel.length == 0 || [rel hasPrefix:@"/"] || [rel containsString:@".."] || [rel containsString:@"\\"]) {
    return @{@"ok": @NO, @"error": @"Invalid path"};
  }
  NSString *dir = [self runDirectoryForRunId:runId rootDirectory:rootDirectory];
  if (dir.length == 0) {
    return @{@"ok": @NO, @"error": @"Invalid run_id"};
  }
  NSString *path = [dir stringByAppendingPathComponent:rel];
  NSData *data = [NSData dataWithContentsOfFile:path];
  if (data.length == 0) {
    return @{@"ok": @NO, @"error": @"File not found"};
  }
  NSString *lower = rel.lowercaseString;
  NSString *contentType = [lower hasSuffix:@".png"] ? @"image/png" : @"application/octet-stream";
  return @{
    @"ok": @YES,
    @"run_id": OnDeviceAgentTraceSafeName(runId),
    @"path": rel,
    @"content_type": contentType,
    @"base64": [data base64EncodedStringWithOptions:0] ?: @"",
    @"bytes": @(data.length),
  };
}

- (instancetype)initWithRootDirectory:(NSString *)rootDirectory
{
  self = [super init];
  if (!self) {
    return nil;
  }
  _rootDirectory = [rootDirectory copy] ?: [OnDeviceAgentTraceRecorder defaultRootDirectory];
  _queue = dispatch_queue_create("ondevice_agent.trace_recorder", DISPATCH_QUEUE_SERIAL);
  _warnings = [NSMutableArray array];
  return self;
}

- (NSString *)eventsPath
{
  return [self.runDirectory stringByAppendingPathComponent:@"events.jsonl"];
}

- (NSString *)logsPath
{
  return [self.runDirectory stringByAppendingPathComponent:@"logs.jsonl"];
}

- (NSString *)turnsPath
{
  return [self.runDirectory stringByAppendingPathComponent:@"turns.jsonl"];
}

- (NSString *)manifestPath
{
  return [self.runDirectory stringByAppendingPathComponent:@"manifest.json"];
}

- (void)appendEventLocked:(NSString *)type payload:(NSDictionary *)payload
{
  if (!self.recording || self.runDirectory.length == 0) {
    return;
  }
  self.seq += 1;
  self.eventCount += 1;
  NSMutableDictionary *obj = [NSMutableDictionary dictionaryWithDictionary:[payload isKindOfClass:NSDictionary.class] ? payload : @{}];
  obj[@"seq"] = @(self.seq);
  obj[@"ts"] = OnDeviceAgentTraceNowString();
  obj[@"type"] = type ?: @"event";
  OnDeviceAgentTraceAppendLine([self eventsPath], obj.copy);
}

- (void)rewriteManifestLocked
{
  if (self.runDirectory.length == 0 || self.manifest.count == 0) {
    return;
  }
  NSMutableDictionary *m = [self.manifest mutableCopy];
  if (self.finishedAt.length > 0) {
    m[@"finished_at"] = self.finishedAt;
  }
  m[@"counts"] = @{
    @"logs": @(self.logCount),
    @"events": @(self.eventCount),
    @"turns": @(self.turnCount),
    @"images": @(self.imageCount),
  };
  m[@"warnings"] = self.warnings.copy ?: @[];
  NSData *data = OnDeviceAgentTraceJSONData(m.copy);
  NSString *tmp = [[self manifestPath] stringByAppendingString:@".tmp"];
  [data writeToFile:tmp atomically:YES];
  [NSFileManager.defaultManager removeItemAtPath:[self manifestPath] error:nil];
  [NSFileManager.defaultManager moveItemAtPath:tmp toPath:[self manifestPath] error:nil];
  self.manifest = m.copy;
}

- (NSDictionary *)startRunWithConfig:(NSDictionary *)config
                                 task:(NSString *)task
                 renderedSystemPrompt:(NSString *)systemPrompt
                       defaultTemplate:(NSString *)defaultTemplate
{
  __block NSDictionary *status = @{};
  dispatch_sync(self.queue, ^{
    NSString *uuid = [[NSUUID UUID].UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""];
    NSString *shortId = uuid.length >= 8 ? [uuid substringToIndex:8] : uuid;
    self.runId = [NSString stringWithFormat:@"run_%@_%@", OnDeviceAgentTraceRunTimestamp(), shortId ?: @"00000000"];
    self.startedAt = OnDeviceAgentTraceNowString();
    self.finishedAt = @"";
    self.runDirectory = [self.rootDirectory stringByAppendingPathComponent:self.runId];
    self.seq = 0;
    self.logCount = 0;
    self.eventCount = 0;
    self.turnCount = 0;
    self.imageCount = 0;
    self.recording = YES;
    [self.warnings removeAllObjects];

    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:[self.runDirectory stringByAppendingPathComponent:@"images"] withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createFileAtPath:[self eventsPath] contents:nil attributes:nil];
    [fm createFileAtPath:[self logsPath] contents:nil attributes:nil];
    [fm createFileAtPath:[self turnsPath] contents:nil attributes:nil];

    NSDictionary *safeConfig = OnDeviceAgentTraceSanitizedConfig(config);
    NSMutableDictionary *manifest = [NSMutableDictionary dictionary];
    manifest[@"schema"] = @"wda.training_trace.v1";
    manifest[@"run_id"] = self.runId ?: @"";
    manifest[@"started_at"] = self.startedAt ?: @"";
    manifest[@"finished_at"] = @"";
    manifest[@"task"] = task ?: @"";
    manifest[@"config"] = safeConfig;
    manifest[@"system_prompt"] = @{
      @"rendered": systemPrompt ?: @"",
      @"template": defaultTemplate ?: @"",
    };
    manifest[@"counts"] = @{@"logs": @0, @"events": @0, @"turns": @0, @"images": @0};
    manifest[@"warnings"] = @[];
    self.manifest = manifest.copy;
    [self rewriteManifestLocked];
  });
  status = [self statusSnapshot];
  [self appendEvent:@"run_start" payload:@{@"run_id": status[@"run_id"] ?: @""}];
  return status ?: @{};
}

- (void)appendLogLine:(NSString *)line
{
  NSString *copy = [line copy] ?: @"";
  dispatch_async(self.queue, ^{
    if (!self.recording || self.runDirectory.length == 0) {
      return;
    }
    self.seq += 1;
    self.logCount += 1;
    OnDeviceAgentTraceAppendLine([self logsPath], @{
      @"seq": @(self.seq),
      @"ts": OnDeviceAgentTraceNowString(),
      @"line": copy,
    });
  });
}

- (NSDictionary *)saveImagePNG:(NSData *)png step:(NSInteger)step stage:(NSString *)stage
{
  if (![png isKindOfClass:NSData.class] || png.length == 0) {
    return @{};
  }
  __block NSDictionary *info = @{};
  NSData *copy = [png copy];
  NSString *safeStage = OnDeviceAgentTraceSafeName(stage ?: @"model");
  if (safeStage.length == 0) {
    safeStage = @"model";
  }
  dispatch_sync(self.queue, ^{
    if (!self.recording || self.runDirectory.length == 0) {
      return;
    }
    NSString *rel = [NSString stringWithFormat:@"images/step_%04ld_%@.png", (long)step, safeStage];
    NSString *path = [self.runDirectory stringByAppendingPathComponent:rel];
    BOOL ok = [copy writeToFile:path atomically:YES];
    if (!ok) {
      [self.warnings addObject:[NSString stringWithFormat:@"failed_to_write_image_step_%ld", (long)step]];
      return;
    }
    UIImage *img = [UIImage imageWithData:copy];
    CGSize size = img != nil ? img.size : CGSizeZero;
    self.imageCount += 1;
    info = @{
      @"ref": rel,
      @"mime_type": @"image/png",
      @"bytes": @(copy.length),
      @"width": @((NSInteger)size.width),
      @"height": @((NSInteger)size.height),
      @"stage": safeStage,
    };
  });
  [self appendEvent:@"screenshot_saved" payload:@{@"step": @(step), @"image": info ?: @{}}];
  return info ?: @{};
}

- (void)appendEvent:(NSString *)type payload:(NSDictionary *)payload
{
  NSString *eventType = [type copy] ?: @"event";
  NSDictionary *eventPayload = [payload isKindOfClass:NSDictionary.class] ? [payload copy] : @{};
  dispatch_async(self.queue, ^{
    [self appendEventLocked:eventType payload:eventPayload];
  });
}

- (void)appendTurn:(NSDictionary *)turn
{
  NSDictionary *copy = [turn isKindOfClass:NSDictionary.class] ? [turn copy] : @{};
  dispatch_async(self.queue, ^{
    if (!self.recording || self.runDirectory.length == 0 || copy.count == 0) {
      return;
    }
    self.turnCount += 1;
    OnDeviceAgentTraceAppendLine([self turnsPath], copy);
  });
}

- (void)finishRunWithSuccess:(BOOL)success message:(NSString *)message stopReason:(NSString *)stopReason
{
  dispatch_sync(self.queue, ^{
    if (!self.recording || self.runDirectory.length == 0) {
      return;
    }
    self.finishedAt = OnDeviceAgentTraceNowString();
    [self appendEventLocked:@"run_end" payload:@{
      @"success": @(success),
      @"message": message ?: @"",
      @"stop_reason": stopReason ?: @"",
    }];
    NSMutableDictionary *m = [self.manifest mutableCopy];
    m[@"finished_at"] = self.finishedAt ?: @"";
    m[@"final_status"] = @{
      @"success": @(success),
      @"message": message ?: @"",
      @"stop_reason": stopReason ?: @"",
    };
    self.manifest = m.copy;
    [self rewriteManifestLocked];
    self.recording = NO;
  });
}

- (NSDictionary *)statusSnapshot
{
  __block NSDictionary *status = @{};
  dispatch_sync(self.queue, ^{
    status = @{
      @"recording": @(self.recording),
      @"run_id": self.runId ?: @"",
      @"root": self.rootDirectory ?: @"",
      @"run_directory": self.runDirectory ?: @"",
      @"counts": @{
        @"logs": @(self.logCount),
        @"events": @(self.eventCount),
        @"turns": @(self.turnCount),
        @"images": @(self.imageCount),
      },
      @"warnings": self.warnings.copy ?: @[],
    };
  });
  return status ?: @{};
}

@end
