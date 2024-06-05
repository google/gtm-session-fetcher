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

#import <XCTest/XCTest.h>
#include <stdlib.h>
#include <sys/sysctl.h>
#include <unistd.h>

#import <GTMSessionFetcher/GTMSessionFetcher.h>
#import <GTMSessionFetcher/GTMSessionFetcherLogging.h>
#import <GTMSessionFetcher/GTMSessionUploadFetcher.h>

#import "GTMSessionFetcherTestServer.h"

NS_ASSUME_NONNULL_BEGIN

extern NSString *const kGTMGettysburgFileName;

@interface GTMSessionFetcherBaseTest : XCTestCase {
  // Setup/teardown ivars.
  GTMSessionFetcherTestServer *_testServer;
  BOOL _isServerRunning;
  NSTimeInterval _timeoutInterval;
  GTMSessionFetcherService *_fetcherService;
}

// Return the raw data of our test file.
- (NSData *)gettysburgAddress;

// Check that all callbacks are nil.
- (void)assertCallbacksReleasedForFetcher:(GTMSessionFetcher *)fetcher;

// Create a temporary file URL.
- (NSURL *)temporaryFileURLWithBaseName:(NSString *)baseName;

// Delete a file.
- (void)removeTemporaryFileURL:(NSURL *)url;

// We need to create http URLs referring to the desired
// resource to be found by the http server running locally.
//
// Returns a localhost:port URL for the test file.
- (NSString *)localURLStringToTestFileName:(NSString *)name;
- (NSString *)localURLStringToTestFileName:(NSString *)name parameters:(NSDictionary *)params;

// Utility method for making a request with the object's timeout.
- (NSMutableURLRequest *)requestWithURLString:(NSString *)urlString;

// Retrieves the name of the currently running test for logging.
- (NSString *)currentTestName;

// Utility methods for creating fetchers.
- (GTMSessionFetcher *)fetcherWithURLString:(NSString *)urlString;
- (GTMSessionFetcher *)fetcherWithURL:(NSURL *)url;
- (GTMSessionFetcher *)fetcherForRetryWithURLString:(NSString *)urlString
                                         retryBlock:(GTMSessionFetcherRetryBlock)retryBlock
                                   maxRetryInterval:(NSTimeInterval)maxRetryInterval
                                           userData:(id)userData;

@end

@interface GTMSessionFetcher (FetchingTest)
// During testing only, we may want to modify the request being fetched
// after beginFetch has been called.
- (nullable NSMutableURLRequest *)mutableRequestForTesting;
@end

// Authorization testing.
@interface TestAuthorizer : NSObject <GTMSessionFetcherAuthorizer>

@property(atomic, assign, getter=isAsync) BOOL async;
@property(atomic, assign, getter=isExpired) BOOL expired;
@property(atomic, assign) BOOL willFailWithError;

+ (instancetype)syncAuthorizer;
+ (instancetype)asyncAuthorizer;
+ (instancetype)expiredSyncAuthorizer;
+ (instancetype)expiredAsyncAuthorizer;

@end

NS_ASSUME_NONNULL_END

#endif  // !TARGET_OS_WATCH
