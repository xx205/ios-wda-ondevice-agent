#import <Foundation/Foundation.h>

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

