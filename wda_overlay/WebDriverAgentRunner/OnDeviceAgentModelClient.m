#import <Foundation/Foundation.h>

static long long OnDeviceAgentLL(id _Nullable v)
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

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"

@interface OnDeviceAgent (ModelClient)
- (NSDictionary *)tokenUsageSnapshot;
- (void)resetTokenUsage;
- (NSDictionary *)accumulateTokenUsageFromResponse:(NSDictionary *)resp;

- (NSURL *)chatCompletionsURL;
- (NSURL *)responsesURL;
- (NSString *)modelServiceHost;

- (NSString *)contentFromOpenAIResponse:(NSDictionary *)json;
- (NSString *)contentFromResponsesResponse:(NSDictionary *)json;
- (NSDictionary *)messageFromOpenAIResponse:(NSDictionary *)json;
- (NSString *)reasoningFromOpenAIResponse:(NSDictionary *)json;
- (NSString *)reasoningFromResponsesResponse:(NSDictionary *)json;

- (NSDictionary *)chatCompletionsRequestBodyForMessages:(NSArray<NSDictionary *> *)messages step:(NSInteger)step forRaw:(BOOL)forRaw;
- (NSDictionary *)responsesRequestBodyForInput:(NSArray<NSDictionary *> *)input previousResponseId:(NSString *)previousResponseId forRaw:(BOOL)forRaw;

- (NSDictionary *)callModelWithMessages:(NSArray<NSDictionary *> *)messages error:(NSError **)error;
- (NSDictionary *)callResponsesWithInput:(NSArray<NSDictionary *> *)input previousResponseId:(NSString *)previousResponseId error:(NSError **)error;
@end

@implementation OnDeviceAgent (ModelClient)

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

#pragma mark - NSURLSessionDelegate

- (void)URLSession:(NSURLSession *)session
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^ _Nonnull)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential * _Nullable credential))completionHandler
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

#pragma clang diagnostic pop
