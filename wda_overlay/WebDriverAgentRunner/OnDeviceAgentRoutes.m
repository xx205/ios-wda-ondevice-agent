#import <Foundation/Foundation.h>

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
