#import <Foundation/Foundation.h>

typedef NS_OPTIONS(NSUInteger, OnDeviceAgentTokenSources) {
  OnDeviceAgentTokenSourceHeader = 1 << 0,
  OnDeviceAgentTokenSourceQuery = 1 << 1,
  OnDeviceAgentTokenSourceCookie = 1 << 2,
};

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

