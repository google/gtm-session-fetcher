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

#import <XCTest/XCTest.h>
#import <sys/sysctl.h>
#import <unistd.h>
#import <stdlib.h>

#import "GTMSessionFetcherTestServer.h"
#import "GTMSessionFetcher.h"
#import "GTMSessionFetcherLogging.h"
#import "GTMSessionUploadFetcher.h"

GTM_ASSUME_NONNULL_BEGIN

extern NSString *const kGTMGettysburgFileName;

@interface GTMSessionFetcherBaseTest : XCTestCase {
  // Setup/teardown ivars.
  GTMSessionFetcherTestServer *_testServer;
  BOOL _isServerRunning;
  NSTimeInterval _timeoutInterval;
  GTMSessionFetcherService *_fetcherService;
}

// A path to the test folder containing documents to be returned by the http server.
- (NSString *)docRootPath;

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
- (NSString *)localURLStringToTestFileName:(NSString *)name
                                parameters:(NSDictionary *)params;

// Utility method for making a request with the object's timeout.
- (NSMutableURLRequest *)requestWithURLString:(NSString *)urlString;

@end


@interface GTMSessionFetcher (FetchingTest)
// During testing only, we may want to modify the request being fetched
// after beginFetch has been called.
- (GTM_NULLABLE NSMutableURLRequest *)mutableRequestForTesting;
@end


// Authorization testing.
@interface TestAuthorizer : NSObject <GTMFetcherAuthorizationProtocol>

@property(atomic, assign, getter=isAsync) BOOL async;
@property(atomic, assign, getter=isExpired) BOOL expired;
@property(atomic, assign) BOOL willFailWithError;

+ (instancetype)syncAuthorizer;
+ (instancetype)asyncAuthorizer;
+ (instancetype)expiredSyncAuthorizer;
+ (instancetype)expiredAsyncAuthorizer;

@end

#if GTM_BACKGROUND_TASK_FETCHING

// A fake of UIApplication that posts notifications when a background task begins
// and ends.
@class SubstituteUIApplicationTaskInfo;

typedef void (^SubstituteUIApplicationExpirationCallback)
    (NSUInteger numberOfBackgroundTasksToExpire,
     NSArray <SubstituteUIApplicationTaskInfo *> * _Nullable tasksFailingToExpire);

@interface SubstituteUIApplication : NSObject<GTMUIApplicationProtocol>

- (UIBackgroundTaskIdentifier)beginBackgroundTaskWithName:(nullable NSString *)taskName
                                        expirationHandler:(nullable dispatch_block_t)handler;
- (void)endBackgroundTask:(UIBackgroundTaskIdentifier)identifier;

- (void)expireAllBackgroundTasksWithCallback:(SubstituteUIApplicationExpirationCallback)handler;

@end

extern NSString *const kSubUIAppBackgroundTaskBegan;
extern NSString *const kSubUIAppBackgroundTaskEnded;

#endif  // GTM_BACKGROUND_TASK_FETCHING


@interface FetcherNotificationsCounter : NSObject
@property(nonatomic) int fetchStarted;
@property(nonatomic) int fetchStopped;
@property(nonatomic) int fetchCompletionInvoked;
@property(nonatomic) int uploadChunkFetchStarted;  // Includes query fetches.
@property(nonatomic) int uploadChunkFetchStopped;  // Includes query fetches.
@property(nonatomic) int retryDelayStarted;
@property(nonatomic) int retryDelayStopped;
@property(nonatomic) int uploadLocationObtained;

@property(nonatomic) NSMutableArray *uploadChunkRequestPaths; // of NSString
@property(nonatomic) NSMutableArray *uploadChunkCommands; // of NSString
@property(nonatomic) NSMutableArray *uploadChunkOffsets; // of NSUInteger
@property(nonatomic) NSMutableArray *uploadChunkLengths; // of NSUInteger

@property(nonatomic) NSMutableArray *fetchersStartedDescriptions; // of NSString
@property(nonatomic) NSMutableArray *fetchersStoppedDescriptions; // of NSString

@property(nonatomic) NSMutableArray *backgroundTasksStarted;  // of boxed UIBackgroundTaskIdentifier
@property(nonatomic) NSMutableArray *backgroundTasksEnded;  // of boxed UIBackgroundTaskIdentifier

@end

GTM_ASSUME_NONNULL_END

