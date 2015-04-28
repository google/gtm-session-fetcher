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

// This is a simple class to create a MIME document.  To use, allocate
// a new GTMMIMEDocument and start adding parts as necessary.  When you are
// done adding parts, call generateInputStream to get an NSInputStream
// containing the contents of your MIME document.
//
// A good reference for MIME is http://en.wikipedia.org/wiki/MIME

#import <Foundation/Foundation.h>

#ifndef GTM_NONNULL
  #if defined(__has_attribute)
    #if __has_attribute(nonnull)
      #define GTM_NONNULL(x) __attribute__((nonnull x))
    #else
      #define GTM_NONNULL(x)
    #endif
  #else
    #define GTM_NONNULL(x)
  #endif
#endif


@interface GTMMIMEDocument : NSObject

// Get or set the unique boundary for the parts that have been added.
@property(nonatomic, copy) NSString *boundary;

+ (instancetype)MIMEDocument;

// Adds a new part to this mime document with the given headers and body.
// The headers keys and values should be NSStrings.
// Adding a part may cause the boundary string to change.
- (void)addPartWithHeaders:(NSDictionary *)headers
                      body:(NSData *)body GTM_NONNULL((1,2));

// An inputstream that can be used to efficiently read the contents of the mime document.
- (void)generateInputStream:(NSInputStream **)outStream
                     length:(unsigned long long *)outLength
                   boundary:(NSString **)outBoundary;

// ------ UNIT TESTING ONLY BELOW ------

// For unit testing only, seeds the random number generator.
- (void)seedRandomWith:(u_int32_t)seed;

@end
