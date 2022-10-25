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

#import <TargetConditionals.h>

#if !TARGET_OS_WATCH

#import <Foundation/Foundation.h>

typedef enum {
  kGTMHTTPAuthenticationTypeInvalid = 0,
  kGTMHTTPAuthenticationTypeBasic,
  kGTMHTTPAuthenticationTypeDigest
} GTMHTTPAuthenticationType;

// This is a HTTP Server that responds to requests by returning the requested file.
// It takes extra url arguments to tell it what to return for testing the code using it.
@interface GTMSessionFetcherTestServer : NSObject

// Returns the most recent GTMHTTPAuthenticationType checked, whether it passed or not.
@property(nonatomic, readonly) GTMHTTPAuthenticationType lastHTTPAuthenticationType;

- (BOOL)isRedirectEnabled;
- (void)setRedirectEnabled:(BOOL)isRedirectEnabled;

- (void)setHTTPAuthenticationType:(GTMHTTPAuthenticationType)authenticationType
                         username:(NSString *)username
                         password:(NSString *)password;
- (void)clearHTTPAuthentication;

// Content type normally returned; defaults to text/plain
@property(atomic, copy) NSString *defaultContentType;

// Utilities for users.
- (NSURL *)localURLForFile:(NSString *)name;    // http://localhost:port/filename
- (NSURL *)localv6URLForFile:(NSString *)name;  // http://[::1]:port/filename
- (NSData *)documentDataAtPath:(NSString *)requestPath;

+ (NSString *)JSONBodyStringForStatus:(NSInteger)code;
+ (NSData *)generatedBodyDataWithLength:(NSUInteger)length;

@end

#endif  // !TARGET_OS_WATCH
