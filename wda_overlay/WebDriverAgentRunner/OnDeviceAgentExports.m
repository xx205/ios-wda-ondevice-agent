#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <ImageIO/ImageIO.h>

@class OnDeviceAgentManager;

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

@interface OnDeviceAgentManager (Exports)
- (void)storeStepScreenshotPNG:(NSData *)png step:(NSInteger)step token:(NSInteger)token;
- (NSString *)stepScreenshotBase64ForStep:(NSInteger)step;
- (NSDictionary *)stepScreenshotsBase64WithSteps:(NSArray<NSNumber *> *)steps
                                           limit:(NSInteger)limit
                                          format:(NSString *)format
                                         quality:(double)quality;
@end

@implementation OnDeviceAgentManager (Exports)

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
      NSData *pngData = self.stepScreenshots[k];
      if ([pngData isKindOfClass:NSData.class] && pngData.length > 0) {
        [entries addObject:@{@"step": k, @"png": pngData}];
      } else {
        [entries addObject:@{@"step": k}];
      }
    }
  });

  NSMutableDictionary *images = [NSMutableDictionary dictionary];
  NSMutableArray<NSNumber *> *missing = [NSMutableArray array];
  for (NSDictionary *e in entries) {
    NSNumber *step = [e[@"step"] isKindOfClass:NSNumber.class] ? (NSNumber *)e[@"step"] : nil;
    NSData *pngData = [e[@"png"] isKindOfClass:NSData.class] ? (NSData *)e[@"png"] : nil;
    if (step == nil || pngData == nil || pngData.length == 0) {
      if (step != nil) {
        [missing addObject:step];
      }
      continue;
    }

    NSData *out = pngData;
    if (asJPEG) {
      UIImage *img = [UIImage imageWithData:pngData];
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

@end

