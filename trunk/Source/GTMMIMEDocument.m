/* Copyright 2014 Google Inc. All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#if !defined(__has_feature) || !__has_feature(objc_arc)
#error "This file requires ARC support."
#endif

#import "GTMMIMEDocument.h"
#import "GTMGatherInputStream.h"

// memsrch
//
// Helper routine to search for the existence of a set of bytes (needle) within
// a presumed larger set of bytes (haystack).
//
static BOOL memsrch(const unsigned char *needle, NSUInteger needle_len,
                    const unsigned char *haystack, NSUInteger haystack_len);

@interface GTMMIMEPart : NSObject {
  NSData *_headerData;  // Header content including the ending "\r\n".
  NSData *_bodyData;    // The body data.
}

+ (instancetype)partWithHeaders:(NSDictionary *)headers body:(NSData *)body;
- (instancetype)initWithHeaders:(NSDictionary *)headers body:(NSData *)body;
- (BOOL)containsBytes:(const unsigned char *)bytes length:(NSUInteger)length;
- (NSData *)header;
- (NSData *)body;
- (NSUInteger)length;
@end

@implementation GTMMIMEPart

+ (instancetype)partWithHeaders:(NSDictionary *)headers body:(NSData *)body {
  return [[self alloc] initWithHeaders:headers body:body];
}

- (instancetype)initWithHeaders:(NSDictionary *)headers body:(NSData *)body {
  self = [super init];
  if (self) {
    _bodyData = body;

    // Generate the header data by coalescing the dictionary as lines of "key: value\r\n".
    NSMutableString* headerString = [NSMutableString string];

    // Sort the header keys so we have a deterministic order for unit testing.
    SEL sortSel = @selector(caseInsensitiveCompare:);
    NSArray *sortedKeys = [[headers allKeys] sortedArrayUsingSelector:sortSel];

    for (NSString *key in sortedKeys) {
      NSString* value = [headers objectForKey:key];

#if DEBUG
      // Look for troublesome characters in the header keys & values.
      static NSCharacterSet *badChars = nil;
      if (!badChars) {
        badChars = [NSCharacterSet characterSetWithCharactersInString:@":\r\n"];
      }

      NSRange badRange = [key rangeOfCharacterFromSet:badChars];
      NSAssert1(badRange.location == NSNotFound, @"invalid key: %@", key);

      badRange = [value rangeOfCharacterFromSet:badChars];
      NSAssert1(badRange.location == NSNotFound, @"invalid value: %@", value);
#endif

      [headerString appendFormat:@"%@: %@\r\n", key, value];
    }
    // Headers end with an extra blank line.
    [headerString appendString:@"\r\n"];

    _headerData = [headerString dataUsingEncoding:NSUTF8StringEncoding];
  }
  return self;
}

// Returns true if the parts contents contain the given set of bytes.
//
// NOTE: We assume that the 'bytes' we are checking for do not contain "\r\n",
// so we don't need to check the concatenation of the header and body bytes.
- (BOOL)containsBytes:(const unsigned char *)bytes length:(NSUInteger)length {

  // This uses custom memsrch() rather than strcpy because the encoded data may contain null values.
  return memsrch(bytes, length, [_headerData bytes], [_headerData length]) ||
         memsrch(bytes, length, [_bodyData bytes],   [_bodyData length]);
}

- (NSData *)header {
  return _headerData;
}

- (NSData *)body {
  return _bodyData;
}

- (NSUInteger)length {
  return [_headerData length] + [_bodyData length];
}

- (NSString *)description {
  return [NSString stringWithFormat:@"%@ %p (header %tu bytes, body %tu bytes)",
          [self class], self, [_headerData length], [_bodyData length]];
}

@end

@implementation GTMMIMEDocument {
  NSMutableArray *_parts;         // Contains an ordered set of MimeParts.
  unsigned long long _length;     // Length in bytes of the document.
  NSString *_boundary;
  u_int32_t _randomSeed;          // For testing.
}

+ (instancetype)MIMEDocument {
  return [[self alloc] init];
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _parts = [[NSMutableArray alloc] init];
  }
  return self;
}

- (NSString *)description {
  return [NSString stringWithFormat:@"%@ %p (%tu parts)",
          [self class], self, [_parts count]];
}

// Adds a new part to this mime document with the given headers and body.
- (void)addPartWithHeaders:(NSDictionary *)headers body:(NSData *)body {
  GTMMIMEPart* part = [GTMMIMEPart partWithHeaders:headers body:body];
  [_parts addObject:part];
  _boundary = nil;
}

// For unit testing only, seeds the random number generator so that we will
// have reproducible boundary strings.
- (void)seedRandomWith:(u_int32_t)seed {
  _randomSeed = seed;
  _boundary = nil;
}

- (u_int32_t)random {
  if (_randomSeed) {
    // For testing only.
    return _randomSeed++;
  } else {
    return arc4random();
  }
}

// Computes the mime boundary to use.  This should only be called
// after all the desired document parts have been added since it must compute
// a boundary that does not exist in the document data.
- (NSString *)boundary {
  if (_boundary) {
    return _boundary;
  }

  // Use an easily-readable boundary string.
  NSString *const kBaseBoundary = @"END_OF_PART";

  _boundary = kBaseBoundary;

  // If the boundary isn't unique, append random numbers, up to 10 attempts;
  // if that's still not unique, use a random number sequence instead, and call it good.
  BOOL didCollide = NO;

  const int maxTries = 10;  // Arbitrarily chosen maximum attempts.
  for (int tries = 0; tries < maxTries; ++tries) {

    NSData *data = [_boundary dataUsingEncoding:NSUTF8StringEncoding];
    const void *dataBytes = [data bytes];
    NSUInteger dataLen = [data length];

    for (GTMMIMEPart *part in _parts) {
      didCollide = [part containsBytes:dataBytes length:dataLen];
      if (didCollide) break;
    }

    if (!didCollide) break; // We're fine, no more attempts needed.

    // Try again with a random number appended.
    _boundary = [NSString stringWithFormat:@"%@_%08x", kBaseBoundary, [self random]];
  }

  if (didCollide) {
    // Fallback... two random numbers.
    _boundary = [NSString stringWithFormat:@"%08x_tedborg_%08x", [self random], [self random]];
  }
  return _boundary;
}

- (void)setBoundary:(NSString *)str {
  _boundary = [str copy];
}

- (void)generateInputStream:(NSInputStream **)outStream
                     length:(unsigned long long *)outLength
                   boundary:(NSString **)outBoundary {

  // The input stream is of the form:
  //   --boundary
  //    [part_1_headers]
  //    [part_1_data]
  //   --boundary
  //    [part_2_headers]
  //    [part_2_data]
  //   --boundary--

  // First we set up our boundary NSData objects.
  NSString *boundary = self.boundary;

  NSString *mainBoundary = [NSString stringWithFormat:@"\r\n--%@\r\n", boundary];
  NSString *endBoundary = [NSString stringWithFormat:@"\r\n--%@--\r\n", boundary];

  NSData *mainBoundaryData = [mainBoundary dataUsingEncoding:NSUTF8StringEncoding];
  NSData *endBoundaryData = [endBoundary dataUsingEncoding:NSUTF8StringEncoding];

  // Now we add them all in proper order to our dataArray.
  NSMutableArray *dataArray = [NSMutableArray array];
  unsigned long long length = 0;

  for (GTMMIMEPart *part in _parts) {
    [dataArray addObject:mainBoundaryData];
    [dataArray addObject:[part header]];
    [dataArray addObject:[part body]];

    length += [part length] + [mainBoundaryData length];
  }

  [dataArray addObject:endBoundaryData];
  length += [endBoundaryData length];

  if (outLength)   *outLength = length;
  if (outStream)   *outStream = [GTMGatherInputStream streamWithArray:dataArray];
  if (outBoundary) *outBoundary = boundary;
}

@end


// memsrch - Return YES if needle is found in haystack, else NO.
static BOOL memsrch(const unsigned char* needle, NSUInteger needleLen,
                    const unsigned char* haystack, NSUInteger haystackLen) {
  // This is a simple approach.  We start off by assuming that both memchr() and
  // memcmp are implemented efficiently on the given platform.  We search for an
  // instance of the first char of our needle in the haystack.  If the remaining
  // size could fit our needle, then we memcmp to see if it occurs at this point
  // in the haystack.  If not, we move on to search for the first char again,
  // starting from the next character in the haystack.
  const unsigned char *ptr = haystack;
  NSUInteger remain = haystackLen;
  while ((ptr = memchr(ptr, needle[0], remain)) != 0) {
    remain = haystackLen - (NSUInteger)(ptr - haystack);
    if (remain < needleLen) {
      return NO;
    }
    if (memcmp(ptr, needle, needleLen) == 0) {
      return YES;
    }
    ptr++;
    remain--;
  }
  return NO;
}
