#import <Foundation/Foundation.h>

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

@interface OnDeviceAgent (Memory)
- (NSString *)firstNewlyCompletedPlanItemTextFromOldPlan:(NSArray<NSDictionary *> *)oldPlan newPlan:(NSArray<NSDictionary *> *)newPlan;
- (NSArray<NSDictionary *> *)sanitizePlanChecklist:(id)planObj;
- (NSArray<NSDictionary *> *)mergePlanChecklistMonotonic:(NSArray<NSDictionary *> *)oldPlan newPlan:(NSArray<NSDictionary *> *)newPlan;
- (NSInteger)doneCountForPlan:(NSArray<NSDictionary *> *)plan;
- (NSString *)planChecklistText;
- (NSString *)workingNoteText;
@end

@implementation OnDeviceAgent (Memory)

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

@end

