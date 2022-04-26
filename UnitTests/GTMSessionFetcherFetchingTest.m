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

#if !defined(__has_feature) || !__has_feature(objc_arc)
#error "This file requires ARC support."
#endif

#import "GTMSessionFetcherFetchingTest.h"

static bool IsCurrentProcessBeingDebugged(void);

static NSString *const kGoodBearerValue = @"Bearer good";
static NSString *const kExpiredBearerValue = @"Bearer expired";

// The test file available in the Tests/Data folder.
NSString *const kGTMGettysburgFileName = @"gettysburgaddress.txt";

// Helper macro to create fetcher start/stop notification expectations. These use alloc/init
// directly to prevent them being waited for by wait helper methods on XCTestCase.
#define CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(START_COUNT, STOP_COUNT)                     \
  XCTestExpectation *fetcherStartedExpectation__ =                                               \
      [[XCTNSNotificationExpectation alloc] initWithName:kGTMSessionFetcherStartedNotification]; \
  XCTestExpectation *fetcherStoppedExpectation__ =                                               \
      [[XCTNSNotificationExpectation alloc] initWithName:kGTMSessionFetcherStoppedNotification]; \
  fetcherStartedExpectation__.expectedFulfillmentCount = (START_COUNT);                          \
  fetcherStartedExpectation__.assertForOverFulfill = YES;                                        \
  fetcherStoppedExpectation__.expectedFulfillmentCount = (STOP_COUNT);                           \
  fetcherStoppedExpectation__.assertForOverFulfill = YES;

// Helper macro to wait on the notification expectations created by the CREATE_START_STOP macro.
// Using -[XCTestCase waitForExpectations...] methods will NOT wait for them.
#define WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS()                                   \
  [self waitForExpectations:@[ fetcherStartedExpectation__, fetcherStoppedExpectation__ ] \
                    timeout:5.0];

@interface GTMSessionFetcher (ExposedForTesting)
+ (nullable NSURL *)redirectURLWithOriginalRequestURL:(nullable NSURL *)originalRequestURL
                                   redirectRequestURL:(nullable NSURL *)redirectRequestURL;
@end

// Base class for fetcher and chunked upload tests.
@implementation GTMSessionFetcherBaseTest

#if GTM_BACKGROUND_TASK_FETCHING

+ (void)setUp {
  SubstituteUIApplication *app = [[SubstituteUIApplication alloc] init];
  [GTMSessionFetcher setSubstituteUIApplication:app];

  [super setUp];
}

+ (void)tearDown {
  [GTMSessionFetcher setSubstituteUIApplication:nil];

  [super tearDown];
}

#endif  // GTM_BACKGROUND_TASK_FETCHING

- (void)setUp {
  // The wrong-fetch test can take >10s to pass.
  //
  // During debugging of the unit tests, we want to avoid timeouts.
  _timeoutInterval = IsCurrentProcessBeingDebugged() ? 3600.0 : 30.0;

  // For tests that create fetchers without a fetcher service, _fetcherService will
  // be set to nil by the test.
  _fetcherService = [[GTMSessionFetcherService alloc] init];

  _testServer = [[GTMSessionFetcherTestServer alloc] init];
  _isServerRunning = (_testServer != nil);
  XCTAssertTrue(_isServerRunning,
                @">>> http test server failed to launch; skipping fetcher tests\n");

  [super setUp];
}

- (void)tearDown {
  _testServer = nil;
  _isServerRunning = NO;

  [_fetcherService stopAllFetchers];
  _fetcherService = nil;

  [[GTMSessionFetcher staticCookieStorage] removeAllCookies];

  [super tearDown];
}

#pragma mark -

- (NSData *)gettysburgAddress {
  return [_testServer documentDataAtPath:kGTMGettysburgFileName];
}

- (NSURL *)temporaryFileURLWithBaseName:(NSString *)baseName {
  static int counter = 0;
  NSString *fileName =
      [NSString stringWithFormat:@"GTMFetcherTest_%@_%@_%d", baseName, [NSDate date], ++counter];
  NSURL *tempURL = [NSURL fileURLWithPath:NSTemporaryDirectory()];
  NSURL *fileURL = [tempURL URLByAppendingPathComponent:fileName];
  return fileURL;
}

- (void)removeTemporaryFileURL:(NSURL *)url {
  NSError *fileError;
  [[NSFileManager defaultManager] removeItemAtURL:url error:&fileError];
  XCTAssertNil(fileError);
}

- (NSString *)localURLStringToTestFileName:(NSString *)name {
  NSString *localURLString = [[_testServer localURLForFile:name] absoluteString];
  return localURLString;
}

- (NSString *)localURLStringToTestFileName:(NSString *)name parameters:(NSDictionary *)params {
  NSString *localURLString = [self localURLStringToTestFileName:name];

  // Add any parameters from the dictionary.
  if (params.count) {
    NSMutableArray *array = [NSMutableArray array];
    for (NSString *key in params) {
      [array addObject:[NSString stringWithFormat:@"%@=%@", key,
                                                  [[params objectForKey:key] description]]];
    }
    NSString *paramsStr = [array componentsJoinedByString:@"&"];
    localURLString = [localURLString stringByAppendingFormat:@"?%@", paramsStr];
  }
  return localURLString;
}

- (NSMutableURLRequest *)requestWithURLString:(NSString *)urlString {
  NSURL *url = [NSURL URLWithString:urlString];
  NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                     cachePolicy:NSURLRequestReloadIgnoringCacheData
                                                 timeoutInterval:_timeoutInterval];
  XCTAssertNotNil(req);
  return req;
}

- (void)assertCallbacksReleasedForFetcher:(GTMSessionFetcher *)fetcher {
  // Because the sessionDelegateQueue no longer defaults to the main queue, there is a race
  // condition when asserting the release of all fetcher callback blocks, which will usually
  // occur on the sessionDelegateQueue and may not have finished running. Bounce through the
  // delegate queue to ensure any operation currently running there has had a chance to release
  // the callbacks before making the test assertions.
  //
  // This is not a race condition for production, only the tests, which are asserting they are
  // nil after the fetch has completed.
  NSOperationQueue *queue = fetcher.sessionDelegateQueue;
  if (queue) {
    XCTestExpectation *expectation = [self expectationWithDescription:@"delegate queue op"];
    [queue addOperationWithBlock:^{
      // With the execution of this block, the session delegate queue will have completed the
      // post-dispatch operation that might trigger arriving at these assertions.
      [expectation fulfill];
    }];
    // The expectation should complete almost immediately.
    [self waitForExpectations:@[ expectation ] timeout:1.0];
  }

  XCTAssertNil(fetcher.completionHandler);
  XCTAssertNil(fetcher.configurationBlock);
  XCTAssertNil(fetcher.didReceiveResponseBlock);
  XCTAssertNil(fetcher.willRedirectBlock);
  XCTAssertNil(fetcher.accumulateDataBlock);
  XCTAssertNil(fetcher.sendProgressBlock);
  XCTAssertNil(fetcher.receivedProgressBlock);
  XCTAssertNil(fetcher.downloadProgressBlock);
  XCTAssertNil(fetcher.willCacheURLResponseBlock);
  XCTAssertNil(fetcher.retryBlock);
  if (@available(iOS 10.0, *)) {
    XCTAssertNil(fetcher.metricsCollectionBlock);
  }
  XCTAssertNil(fetcher.testBlock);

  if ([fetcher isKindOfClass:[GTMSessionUploadFetcher class]]) {
    XCTAssertNil(((GTMSessionUploadFetcher *)fetcher).delegateCallbackQueue);
    XCTAssertNil(((GTMSessionUploadFetcher *)fetcher).delegateCompletionHandler);
    XCTAssertNil(((GTMSessionUploadFetcher *)fetcher).uploadDataProvider);
  }
}

@end

@interface GTMSessionFetcherFetchingTest : GTMSessionFetcherBaseTest
@end

@implementation GTMSessionFetcherFetchingTest

#pragma mark - Fetcher Tests

- (void)assertSuccessfulGettysburgFetchWithFetcher:(GTMSessionFetcher *)fetcher
                                              data:(NSData *)data
                                             error:(NSError *)error {
  XCTAssertNil(error);
  if (error) return;

  NSData *gettysburgAddress = [self gettysburgAddress];
  XCTAssertEqualObjects(data, gettysburgAddress,
                        @"Failed to retrieve Gettysburg Address."
                        @"  %d bytes, status:%d request:%@ error:%@",
                        (int)data.length, (int)fetcher.statusCode, fetcher.request, error);
  XCTAssertNotNil(fetcher.response);
  XCTAssertNotNil(fetcher.request, @"Missing request");
  XCTAssertEqual(fetcher.statusCode, (NSInteger)200, @"%@", fetcher.request);
}

- (void)testFetch {
  if (!_isServerRunning) return;

  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(2, 2);

  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  //
  // Fetch our test file.
  //
  NSString *localURLString = [self localURLStringToTestFileName:kGTMGettysburgFileName];
  GTMSessionFetcher *fetcher = [self fetcherWithURLString:localURLString];
  __block NSHTTPCookieStorage *cookieStorage;

  // Prior to 10.11, our delegate method URLSession:dataTask:willCacheResponse:completionHandler:
  // would be invoked during tests. Perhaps it no longer is invoked because the tests are to
  // localhost, and the system is optimizing.
  __block NSCachedURLResponse *proposedResponseToCache;
  fetcher.willCacheURLResponseBlock = ^(NSCachedURLResponse *responseProposed,
                                        GTMSessionFetcherWillCacheURLResponseResponse response) {
    proposedResponseToCache = responseProposed;
    response(responseProposed);
  };

  __block NSURLResponse *initialResponse;
  fetcher.didReceiveResponseBlock =
      ^(NSURLResponse *response,
        GTMSessionFetcherDidReceiveResponseDispositionBlock dispositionBlock) {
        XCTAssertNil(initialResponse);
        initialResponse = response;
        dispositionBlock(NSURLSessionResponseAllow);
      };

  fetcher.willRedirectBlock = ^(NSHTTPURLResponse *redirectResponse, NSURLRequest *redirectRequest,
                                GTMSessionFetcherWillRedirectResponse response) {
    XCTFail(@"redirect not expected");
  };

  __block BOOL wasConfigBlockCalled = NO;
  fetcher.configurationBlock =
      ^(GTMSessionFetcher *configFetcher, NSURLSessionConfiguration *config) {
        wasConfigBlockCalled = YES;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-retain-cycles"
        XCTAssertEqual(configFetcher, fetcher);
#pragma clang diagnostic pop
      };

  XCTestExpectation *expectation = [self expectationWithDescription:localURLString];
  NSString *cookieExpected = [NSString stringWithFormat:@"TestCookie=%@", kGTMGettysburgFileName];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    [self assertSuccessfulGettysburgFetchWithFetcher:fetcher data:data error:error];

    // No cookies should be sent with our first request.  Check what cookies the server found.
    NSDictionary *responseHeaders = [(NSHTTPURLResponse *)fetcher.response allHeaderFields];
    NSString *cookiesSent = [responseHeaders objectForKey:@"FoundCookies"];
    XCTAssertNil(cookiesSent, @"Cookies sent unexpectedly: %@", cookiesSent);

    // Cookies should have been set by the response; specifically, TestCookie
    // should be set to the name of the file requested.
    NSString *cookiesSetString = [responseHeaders objectForKey:@"Set-Cookie"];
    XCTAssertEqualObjects(cookiesSetString, cookieExpected);

    // A cookie should've been set.
    cookieStorage = fetcher.configuration.HTTPCookieStorage;
    NSURL *localhostURL = [NSURL URLWithString:@"http://localhost/"];
    NSArray *cookies = [cookieStorage cookiesForURL:localhostURL];
    XCTAssertEqual(cookies.count, (NSUInteger)1);
    NSHTTPCookie *firstCookie = cookies.firstObject;
    XCTAssertEqualObjects([firstCookie value], @"gettysburgaddress.txt");

    // The initial response should be the final response;
    XCTAssertEqualObjects(initialResponse, fetcher.response);

    // The response should've been cached.  See the comment above at the declaration of
    // proposedResponseToCache
    if (proposedResponseToCache) {
      XCTAssertEqualObjects(proposedResponseToCache.response.URL, fetcher.response.URL);
      XCTAssertEqualObjects([(NSHTTPURLResponse *)proposedResponseToCache.response allHeaderFields],
                            [(NSHTTPURLResponse *)fetcher.response allHeaderFields]);
    }
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  XCTAssert(wasConfigBlockCalled);

  //
  // Repeat the fetch, reusing the session's cookie storage.
  //
  NSURLSessionConfiguration *priorConfig = fetcher.configuration;
  wasConfigBlockCalled = NO;

  fetcher = [self fetcherWithURLString:localURLString];
  fetcher.configuration = priorConfig;
  // TODO(seh): Shouldn't be needed; without it the cookie isn't being received by the test server.
  // b/17646646
  [fetcher setRequestValue:cookieExpected forHTTPHeaderField:@"Cookie"];
  fetcher.configurationBlock =
      ^(GTMSessionFetcher *configFetcher, NSURLSessionConfiguration *config) {
        wasConfigBlockCalled = YES;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-retain-cycles"
        XCTAssertEqual(configFetcher, fetcher);
#pragma clang diagnostic pop
        XCTAssertEqualObjects(config.HTTPCookieStorage, cookieStorage);
      };

  expectation = [self expectationWithDescription:@"Cookies found"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertEqualObjects(data, [self gettysburgAddress], @"Unexpected data.");

    // The cookie set previously should be sent with this request.  See what cookies the
    // http server found.
    NSDictionary *allHeaderFields = [(NSHTTPURLResponse *)fetcher.response allHeaderFields];
    NSString *cookiesSent = [allHeaderFields objectForKey:@"FoundCookies"];
    XCTAssertEqualObjects(cookiesSent, cookieExpected);
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];

  if (!_fetcherService) {
    XCTAssert(wasConfigBlockCalled);
  } else {
    // Since this fetcher has a reused session from the service, the config block will not
    // be invoked.
    XCTAssertFalse(wasConfigBlockCalled);
  }

  // Wait for all expected fetchers to stop before asserting other counters.
  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();
  [self assertCallbacksReleasedForFetcher:fetcher];

  // Check the notifications.
  XCTAssertEqual(fnctr.fetchStarted, 2, @"%@", fnctr.fetchersStartedDescriptions);
  XCTAssertEqual(fnctr.fetchStopped, 2, @"%@", fnctr.fetchersStoppedDescriptions);
  XCTAssertEqual(fnctr.fetchCompletionInvoked, 2);
  XCTAssertEqual(fnctr.uploadChunkFetchStarted, 0, @"%@", fnctr.fetchersStartedDescriptions);
  XCTAssertEqual(fnctr.uploadChunkFetchStopped, 0, @"%@", fnctr.fetchersStoppedDescriptions);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
#if GTM_BACKGROUND_TASK_FETCHING
  [self waitForBackgroundTaskEndedNotifications:fnctr];
  XCTAssertEqual(fnctr.backgroundTasksStarted.count, (NSUInteger)2);
  XCTAssertEqualObjects(fnctr.backgroundTasksStarted, fnctr.backgroundTasksEnded);
#endif
}

- (void)testFetch_WithoutFetcherService {
  _fetcherService = nil;
  [self testFetch];
}

- (void)testFetchExpiringBackgroundTask {
  // Xcode test UI is happier if the method exists for both OS X and iOS builds.
#if GTM_BACKGROUND_TASK_FETCHING
  if (!_isServerRunning) return;

  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(1, 1);

  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  NSString *localURLString = [self localURLStringToTestFileName:kGTMGettysburgFileName];
  GTMSessionFetcher *fetcher = [self fetcherWithURLString:localURLString];

  // Soon after the background task begins, invoke its expiration handler.
  XCTestExpectation *expirationExp = [self expectationWithDescription:@"expired"];

  NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
  id notification =
      [nc addObserverForName:kSubUIAppBackgroundTaskBegan
                      object:nil
                       queue:nil
                  usingBlock:^(NSNotification *note) {
                    SubstituteUIApplication *app = [GTMSessionFetcher substituteUIApplication];
                    dispatch_async(dispatch_get_main_queue(), ^{
                      [app expireAllBackgroundTasksWithCallback:^(
                               NSUInteger numberOfBackgroundTasksToExpire,
                               NSArray<SubstituteUIApplicationTaskInfo *> *tasksFailingToExpire) {
                        XCTAssertEqual(numberOfBackgroundTasksToExpire, (NSUInteger)1);
                        XCTAssertEqual(tasksFailingToExpire.count, (NSUInteger)0, @"%@",
                                       tasksFailingToExpire);
                        [expirationExp fulfill];
                      }];
                    });
                  }];

  XCTestExpectation *expectation = [self expectationWithDescription:localURLString];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    [self assertSuccessfulGettysburgFetchWithFetcher:fetcher data:data error:error];
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  // Check the notifications.
  XCTAssertEqual(fnctr.fetchStarted, 1, @"%@", fnctr.fetchersStartedDescriptions);
  XCTAssertEqual(fnctr.fetchStopped, 1, @"%@", fnctr.fetchersStoppedDescriptions);
  XCTAssertEqual(fnctr.fetchCompletionInvoked, 1);
  XCTAssertEqual(fnctr.uploadChunkFetchStarted, 0, @"%@", fnctr.fetchersStartedDescriptions);
  XCTAssertEqual(fnctr.uploadChunkFetchStopped, 0, @"%@", fnctr.fetchersStoppedDescriptions);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);

  [self waitForBackgroundTaskEndedNotifications:fnctr];
  XCTAssertEqual(fnctr.backgroundTasksStarted.count, (NSUInteger)1);
  XCTAssertEqualObjects(fnctr.backgroundTasksStarted, fnctr.backgroundTasksEnded);

  [nc removeObserver:notification];
#endif  // GTM_BACKGROUND_TASK_FETCHING
}

- (void)testFetchExpiringBackgroundTask_WithoutFetcherService {
  _fetcherService = nil;
  [self testFetchExpiringBackgroundTask];
}

- (void)testAccumulatingFetch {
  if (!_isServerRunning) return;

  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(1, 1);

  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  //
  // Fetch our test file.
  //
  NSString *localURLString = [self localURLStringToTestFileName:kGTMGettysburgFileName];
  GTMSessionFetcher *fetcher = [self fetcherWithURLString:localURLString];
  __block NSMutableData *accumulatedData = [NSMutableData data];
  fetcher.accumulateDataBlock = ^(NSData *downloadChunk) {
    if (downloadChunk) {
      [accumulatedData appendData:downloadChunk];
    } else {
      [accumulatedData setLength:0];
    }
  };

  XCTestExpectation *expectation = [self expectationWithDescription:localURLString];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertNil(data);
    [self assertSuccessfulGettysburgFetchWithFetcher:fetcher data:accumulatedData error:error];
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  // Check the notifications.
  XCTAssertEqual(fnctr.fetchStarted, 1, @"%@", fnctr.fetchersStartedDescriptions);
  XCTAssertEqual(fnctr.fetchStopped, 1, @"%@", fnctr.fetchersStoppedDescriptions);
  XCTAssertEqual(fnctr.fetchCompletionInvoked, 1);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
#if GTM_BACKGROUND_TASK_FETCHING
  [self waitForBackgroundTaskEndedNotifications:fnctr];
  XCTAssertEqual(fnctr.backgroundTasksStarted.count, (NSUInteger)1);
  XCTAssertEqualObjects(fnctr.backgroundTasksStarted, fnctr.backgroundTasksEnded);
#endif
}

- (void)testAccumulatingFetch_WithoutFetcherService {
  _fetcherService = nil;
  [self testAccumulatingFetch];
}

- (void)testWrongFetch {
  if (!_isServerRunning) return;

  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(2, 2);

  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  //
  // Fetch a live, invalid URL
  //
  NSString *badURLString = @"http://localhost:86/";

  GTMSessionFetcher *fetcher = [self fetcherWithURLString:badURLString];
  XCTestExpectation *expectation = [self expectationWithDescription:badURLString];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    if (data) {
      NSString *str = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
      XCTAssertNil(data, @"Unexpected data: %@", str);
    }
    XCTAssertNotNil(error);
    XCTAssertEqual(fetcher.statusCode, (NSInteger)0);

    NSNumber *retriesDone = error.userInfo[kGTMSessionFetcherNumberOfRetriesDoneKey];
    NSNumber *elapsedInterval = error.userInfo[kGTMSessionFetcherElapsedIntervalWithRetriesKey];
    XCTAssertNil(retriesDone);
    XCTAssertNil(elapsedInterval);
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  //
  // Fetch requesting a specific status code from our http server.
  //
  NSString *statusURLString = [self localURLStringToTestFileName:kGTMGettysburgFileName
                                                      parameters:@{@"status" : @"400"}];

  fetcher = [self fetcherWithURLString:statusURLString];
  expectation = [self expectationWithDescription:statusURLString];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    NSString *statusStr = [[self->_testServer class] JSONBodyStringForStatus:400];
    NSData *errorBodyData = [statusStr dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertEqualObjects(data, errorBodyData);

    XCTAssertNotNil(error);
    XCTAssertEqual(fetcher.statusCode, (NSInteger)400, @"%@", error);

    NSString *statusDataContentType =
        [error.userInfo objectForKey:kGTMSessionFetcherStatusDataContentTypeKey];
    XCTAssertEqualObjects(statusDataContentType, @"application/json");

    NSData *statusData = [error.userInfo objectForKey:kGTMSessionFetcherStatusDataKey];
    XCTAssertNotNil(statusData, @"Missing data in error");
    if (statusData) {
      NSString *dataStr = [[NSString alloc] initWithData:statusData encoding:NSUTF8StringEncoding];
      NSString *expectedStr = [[self->_testServer class] JSONBodyStringForStatus:400];
      XCTAssertEqualObjects(dataStr, expectedStr, @"Expected JSON status data");
    }
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  // Check the notifications.
  XCTAssertEqual(fnctr.fetchStarted, 2, @"%@", fnctr.fetchersStartedDescriptions);
  XCTAssertEqual(fnctr.fetchStopped, 2, @"%@", fnctr.fetchersStoppedDescriptions);
  XCTAssertEqual(fnctr.fetchCompletionInvoked, 2);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
#if GTM_BACKGROUND_TASK_FETCHING
  [self waitForBackgroundTaskEndedNotifications:fnctr];
  XCTAssertEqual(fnctr.backgroundTasksStarted.count, (NSUInteger)2);
  XCTAssertEqualObjects(fnctr.backgroundTasksStarted, fnctr.backgroundTasksEnded);
#endif
}

- (void)testWrongFetch_WithoutFetcherService {
  _fetcherService = nil;
  [self testWrongFetch];
}

- (void)testInvalidBodyFile {
  if (!_isServerRunning) return;

  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  //
  // Fetch with a bad bodyFileURL
  //
  NSString *localURLString = [self localURLStringToTestFileName:kGTMGettysburgFileName];
  GTMSessionFetcher *fetcher = [self fetcherWithURLString:localURLString];
  fetcher.bodyFileURL = [NSURL fileURLWithPath:@"/bad/path/here.txt"];

  XCTestExpectation *expectation = [self expectationWithDescription:localURLString];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertNil(data);
    XCTAssertEqual(error.code, NSFileReadNoSuchFileError);
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  // Check the notifications.
  XCTAssertEqual(fnctr.fetchStarted, 0, @"%@", fnctr.fetchersStartedDescriptions);
  XCTAssertEqual(fnctr.fetchStopped, 0, @"%@", fnctr.fetchersStoppedDescriptions);
  XCTAssertEqual(fnctr.fetchCompletionInvoked, 1);
}

- (void)testInvalidBodyFile_WithoutFetcherService {
  _fetcherService = nil;
  [self testInvalidBodyFile];
}

- (void)testDataBodyFetch {
  if (!_isServerRunning) return;

  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(1, 1);

  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  //
  // Fetch our test file with an NSData body in the request.
  //
  const int kBodyLength = 133;
  NSString *localURLString =
      [self localURLStringToTestFileName:kGTMGettysburgFileName
                              parameters:@{@"requestBodyLength" : [@(kBodyLength) stringValue]}];
  GTMSessionFetcher *fetcher = [self fetcherWithURLString:localURLString];

  fetcher.bodyData = [GTMSessionFetcherTestServer generatedBodyDataWithLength:kBodyLength];

  XCTestExpectation *expectation = [self expectationWithDescription:localURLString];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    // We'll verify we fetched from the server the actual data on disk.
    [self assertSuccessfulGettysburgFetchWithFetcher:fetcher data:data error:error];
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  // Check the notifications.
  XCTAssertEqual(fnctr.fetchStarted, 1, @"%@", fnctr.fetchersStartedDescriptions);
  XCTAssertEqual(fnctr.fetchStopped, 1, @"%@", fnctr.fetchersStoppedDescriptions);
  XCTAssertEqual(fnctr.fetchCompletionInvoked, 1);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
#if GTM_BACKGROUND_TASK_FETCHING
  [self waitForBackgroundTaskEndedNotifications:fnctr];
  XCTAssertEqual(fnctr.backgroundTasksStarted.count, (NSUInteger)1);
  XCTAssertEqualObjects(fnctr.backgroundTasksStarted, fnctr.backgroundTasksEnded);
#endif
}

- (void)testDataBodyFetch_WithoutFetcherService {
  _fetcherService = nil;
  [self testDataBodyFetch];
}

- (void)testCallbackQueue {
  // We should improve this to test the queue of all callback blocks.
  if (!_isServerRunning) return;

  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(2, 2);

  const int kBodyLength = 133;
  NSData *bodyData = [GTMSessionFetcherTestServer generatedBodyDataWithLength:kBodyLength];
  NSString *localURLString = [self localURLStringToTestFileName:kGTMGettysburgFileName];

  //
  // Default fetcher callback behavior is to call back on the main queue.
  //
  GTMSessionFetcher *fetcher = [self fetcherWithURLString:localURLString];
  fetcher.bodyData = bodyData;

  XCTestExpectation *finishExpectation =
      [self expectationWithDescription:@"testCallbackQueue main"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    [self assertSuccessfulGettysburgFetchWithFetcher:fetcher data:data error:error];
    XCTAssertTrue([NSThread isMainThread], @"Unexpected queue %s",
                  dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL));
    [finishExpectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  //
  // Setting a specific queue should call back on that queue.
  //
  fetcher = [self fetcherWithURLString:localURLString];
  fetcher.bodyData = bodyData;

  dispatch_queue_t bgQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0);
  fetcher.callbackQueue = bgQueue;

  finishExpectation = [self expectationWithDescription:@"testCallbackQueue specific"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    [self assertSuccessfulGettysburgFetchWithFetcher:fetcher data:data error:error];
    BOOL areSame = (strcmp(dispatch_queue_get_label(bgQueue),
                           dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL)) == 0);
    XCTAssert(areSame, @"Unexpected queue: %s ≠ %s",
              dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL),
              dispatch_queue_get_label(bgQueue));
    [finishExpectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();
}

- (void)testCallbackQueue_WithoutFetcherService {
  _fetcherService = nil;
  [self testCallbackQueue];
}

- (void)testStreamProviderFetch {
  if (!_isServerRunning) return;

  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(1, 1);

  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  //
  // Fetch our test file with an NSInputStream provider block.
  //
  const int kBodyLength = 1024 * 1024;
  NSString *localURLString =
      [self localURLStringToTestFileName:kGTMGettysburgFileName
                              parameters:@{@"requestBodyLength" : @(kBodyLength)}];

  GTMSessionFetcher *fetcher = [self fetcherWithURLString:localURLString];

  fetcher.bodyStreamProvider = ^(GTMSessionFetcherBodyStreamProviderResponse response) {
    NSData *bodyData = [GTMSessionFetcherTestServer generatedBodyDataWithLength:kBodyLength];
    NSInputStream *stream = [NSInputStream inputStreamWithData:bodyData];
    response(stream);
  };

  XCTestExpectation *expectation = [self expectationWithDescription:localURLString];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    // We'll verify we fetched from the server the actual data on disk.
    [self assertSuccessfulGettysburgFetchWithFetcher:fetcher data:data error:error];
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  // Check the notifications.
  XCTAssertEqual(fnctr.fetchStarted, 1, @"%@", fnctr.fetchersStartedDescriptions);
  XCTAssertEqual(fnctr.fetchStopped, 1, @"%@", fnctr.fetchersStoppedDescriptions);
  XCTAssertEqual(fnctr.fetchCompletionInvoked, 1);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
#if GTM_BACKGROUND_TASK_FETCHING
  [self waitForBackgroundTaskEndedNotifications:fnctr];
  XCTAssertEqual(fnctr.backgroundTasksStarted.count, (NSUInteger)1);
  XCTAssertEqualObjects(fnctr.backgroundTasksStarted, fnctr.backgroundTasksEnded);
#endif
}

- (void)testStreamProviderFetch_WithoutFetcherService {
  _fetcherService = nil;
  [self testStreamProviderFetch];
}

- (void)testHTTPBodyStreamFetch {
  // NOTE: This test is not compatible with redirects, while testStreamProviderFetch is.
  // Setting HTTPBodyStream and redirecting the initial request causes NSURLSession to hang after
  // notifying the delegate of the redirect. This occurs with our test server and Google.org.
  if (!_isServerRunning) return;

  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(1, 1);

  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  //
  // Fetch our test file with an NSInputStream provider block.
  //
  const int kBodyLength = 1024 * 1024;
  NSString *localURLString =
      [self localURLStringToTestFileName:kGTMGettysburgFileName
                              parameters:@{@"requestBodyLength" : @(kBodyLength)}];

  NSMutableURLRequest *request = [self requestWithURLString:localURLString];
  NSData *bodyData = [GTMSessionFetcherTestServer generatedBodyDataWithLength:kBodyLength];
  NSInputStream *stream = [NSInputStream inputStreamWithData:bodyData];
  [request setHTTPBodyStream:stream];
  GTMSessionFetcher *fetcher = [GTMSessionFetcher fetcherWithRequest:request];
  fetcher.allowLocalhostRequest = YES;
  XCTAssertNotNil(fetcher);

  XCTestExpectation *expectation = [self expectationWithDescription:localURLString];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    // We'll verify we fetched from the server the actual data on disk.
    [self assertSuccessfulGettysburgFetchWithFetcher:fetcher data:data error:error];
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  // Check the notifications.
  XCTAssertEqual(fnctr.fetchStarted, 1, @"%@", fnctr.fetchersStartedDescriptions);
  XCTAssertEqual(fnctr.fetchStopped, 1, @"%@", fnctr.fetchersStoppedDescriptions);
  XCTAssertEqual(fnctr.fetchCompletionInvoked, 1);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
#if GTM_BACKGROUND_TASK_FETCHING
  [self waitForBackgroundTaskEndedNotifications:fnctr];
  XCTAssertEqual(fnctr.backgroundTasksStarted.count, (NSUInteger)1);
  XCTAssertEqualObjects(fnctr.backgroundTasksStarted, fnctr.backgroundTasksEnded);
#endif
}

- (void)testHTTPBodyStreamFetch_WithoutFetcherService {
  _fetcherService = nil;
  [self testHTTPBodyStreamFetch];
}

- (void)testHTTPAuthentication {
  if (!_isServerRunning) return;

  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(3, 3);

  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];
  NSURLCredential *goodCredential =
      [NSURLCredential credentialWithUser:@"user"
                                 password:@"password"
                              persistence:NSURLCredentialPersistenceNone];
  //
  // Fetch our test file from a server with HTTP Authentication.
  //
  NSString *localURLString = [self localURLStringToTestFileName:kGTMGettysburgFileName];
  GTMSessionFetcher *fetcher = [self fetcherWithURLString:localURLString];
  fetcher.credential = goodCredential;

  // Verify Basic Authentication.
  [_testServer setHTTPAuthenticationType:kGTMHTTPAuthenticationTypeBasic
                                username:@"user"
                                password:@"password"];
  XCTestExpectation *expectation = [self expectationWithDescription:@"basic authentication"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    // We'll verify we fetched from the server the actual data on disk.
    [self assertSuccessfulGettysburgFetchWithFetcher:fetcher data:data error:error];
    XCTAssertEqual(self->_testServer.lastHTTPAuthenticationType, kGTMHTTPAuthenticationTypeBasic);
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  // Verify Digest Authentication.
  fetcher = [self fetcherWithURLString:localURLString];
  fetcher.credential = goodCredential;
  [_testServer setHTTPAuthenticationType:kGTMHTTPAuthenticationTypeDigest
                                username:@"user"
                                password:@"password"];
  expectation = [self expectationWithDescription:@"digest authentication"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    // We'll verify we fetched from the server the actual data on disk.
    [self assertSuccessfulGettysburgFetchWithFetcher:fetcher data:data error:error];
    XCTAssertEqual(self->_testServer.lastHTTPAuthenticationType, kGTMHTTPAuthenticationTypeDigest);
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  //
  // Try a failed Basic authentication.
  //
  NSURLCredential *badCredential =
      [NSURLCredential credentialWithUser:@"nonuser"
                                 password:@"nonpassword"
                              persistence:NSURLCredentialPersistenceNone];

  fetcher = [self fetcherWithURLString:localURLString];
  fetcher.credential = badCredential;

  [_testServer setHTTPAuthenticationType:kGTMHTTPAuthenticationTypeBasic
                                username:@"user"
                                password:@"password"];
  expectation = [self expectationWithDescription:@"bad credential"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertNil(data);
    XCTAssertEqual(error.code, (NSInteger)NSURLErrorCancelled, @"%@", error);
    XCTAssertEqual(self->_testServer.lastHTTPAuthenticationType, kGTMHTTPAuthenticationTypeInvalid);
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  // Check the notifications.
  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  XCTAssertEqual(fnctr.fetchStarted, 3, @"%@", fnctr.fetchersStartedDescriptions);
  XCTAssertEqual(fnctr.fetchStopped, 3, @"%@", fnctr.fetchersStoppedDescriptions);
  XCTAssertEqual(fnctr.fetchCompletionInvoked, 3);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
#if GTM_BACKGROUND_TASK_FETCHING
  [self waitForBackgroundTaskEndedNotifications:fnctr];
  XCTAssertEqual(fnctr.backgroundTasksStarted.count, 3U);
  XCTAssertEqualObjects(fnctr.backgroundTasksStarted, fnctr.backgroundTasksEnded);
#endif
}

- (void)testHTTPAuthentication_WithoutFetcherService {
  _fetcherService = nil;
  [self testHTTPAuthentication];
}

- (void)testHTTPAuthentication_ChallengeBlock {
  if (!_isServerRunning) return;

  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(1, 1);

  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  // Basic Authentication.
  NSURLCredential *goodCredential =
      [NSURLCredential credentialWithUser:@"frogman"
                                 password:@"padhopper"
                              persistence:NSURLCredentialPersistenceNone];

  [_testServer setHTTPAuthenticationType:kGTMHTTPAuthenticationTypeBasic
                                username:goodCredential.user
                                password:goodCredential.password];

  //
  // Fetch our test file from a server with HTTP Authentication.
  //
  NSString *localURLString = [self localURLStringToTestFileName:kGTMGettysburgFileName];
  GTMSessionFetcher *fetcher = [self fetcherWithURLString:localURLString];

  XCTestExpectation *calledChallengeDisposition = [self expectationWithDescription:@"challenged"];

  // All we're testing is that the code path for use of the challenge block is exercised;
  // actual behavior of the disposition is up to NSURLSession and the test server.
  fetcher.challengeBlock =
      ^(GTMSessionFetcher *blockFetcher, NSURLAuthenticationChallenge *challenge,
        GTMSessionFetcherChallengeDispositionBlock dispositionBlock) {
        dispositionBlock(NSURLSessionAuthChallengeUseCredential, goodCredential);

        [calledChallengeDisposition fulfill];
      };

  XCTestExpectation *expectation = [self expectationWithDescription:@"completion handler"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    [self assertSuccessfulGettysburgFetchWithFetcher:fetcher data:data error:error];
    XCTAssertEqual(self->_testServer.lastHTTPAuthenticationType, kGTMHTTPAuthenticationTypeBasic);
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  // Check the notifications.
  XCTAssertEqual(fnctr.fetchStarted, 1, @"%@", fnctr.fetchersStartedDescriptions);
  XCTAssertEqual(fnctr.fetchStopped, 1, @"%@", fnctr.fetchersStoppedDescriptions);
  XCTAssertEqual(fnctr.fetchCompletionInvoked, 1);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
#if GTM_BACKGROUND_TASK_FETCHING
  [self waitForBackgroundTaskEndedNotifications:fnctr];
  XCTAssertEqual(fnctr.backgroundTasksStarted.count, (NSUInteger)1);
  XCTAssertEqualObjects(fnctr.backgroundTasksStarted, fnctr.backgroundTasksEnded);
#endif
}

- (void)testHTTPAuthentication_ChallengeBlock_WithoutFetcherService {
  _fetcherService = nil;
  [self testHTTPAuthentication_ChallengeBlock];
}

- (void)testAuthorizerFetch {
  if (!_isServerRunning) return;

  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(8, 8);

  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  //
  // Fetch a live, authorized URL.
  //
  NSString *authedURLString = [self localURLStringToTestFileName:kGTMGettysburgFileName
                                                      parameters:@{@"oauth2" : @"good"}];

  GTMSessionFetcher *fetcher = [self fetcherWithURLString:authedURLString];
  fetcher.authorizer = [TestAuthorizer syncAuthorizer];
  XCTestExpectation *expectation = [self expectationWithDescription:@"synchronous authorizer"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    NSString *authHdr = [fetcher.request.allHTTPHeaderFields objectForKey:@"Authorization"];
    XCTAssertEqualObjects(authHdr, kGoodBearerValue);
    XCTAssertEqualObjects(data, [self gettysburgAddress]);
    XCTAssertNil(error, @"unexpected error");
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  //
  // Repeat with an async authorization.
  //
  fetcher = [self fetcherWithURLString:authedURLString];
  fetcher.authorizer = [TestAuthorizer asyncAuthorizer];
  expectation = [self expectationWithDescription:@"asynchronous authorizer"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    NSString *authHdr = [fetcher.request.allHTTPHeaderFields objectForKey:@"Authorization"];
    XCTAssertEqualObjects(authHdr, kGoodBearerValue);
    XCTAssertEqualObjects(data, [self gettysburgAddress]);
    XCTAssertNil(error, @"unexpected error");
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  //
  // Repeat with an async authorization that returns an auth error.
  //
  fetcher = [self fetcherWithURLString:authedURLString];
  fetcher.authorizer = [TestAuthorizer asyncAuthorizer];
  ((TestAuthorizer *)fetcher.authorizer).willFailWithError = YES;
  expectation = [self expectationWithDescription:@"asynchronous authorizer error"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    NSString *authHdr = [fetcher.request.allHTTPHeaderFields objectForKey:@"Authorization"];
    XCTAssertNil(authHdr);
    XCTAssertNil(data);
    XCTAssertNotNil(error);
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  //
  // Fetch with an expired sync authorizer, no retry allowed.
  //
  authedURLString = [self localURLStringToTestFileName:kGTMGettysburgFileName
                                            parameters:@{@"oauth2" : @"good"}];

  fetcher = [self fetcherWithURLString:authedURLString];
  fetcher.authorizer = [TestAuthorizer expiredSyncAuthorizer];
  fetcher.retryBlock =
      ^(BOOL suggestedWillRetry, NSError *error, GTMSessionFetcherRetryResponse response) {
        XCTAssertEqual(error.code, (NSInteger)401, @"%@", error);
        response(NO);
      };

  expectation = [self expectationWithDescription:@"expired synchronous authorizer no retry"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    NSString *authHdr = [fetcher.request.allHTTPHeaderFields objectForKey:@"Authorization"];
    XCTAssertNil(authHdr);
    XCTAssertEqual(error.code, (NSInteger)401, @"%@", error);
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  //
  // Fetch with an expired async authorizer, no retry allowed.
  //
  authedURLString = [self localURLStringToTestFileName:kGTMGettysburgFileName
                                            parameters:@{@"oauth2" : @"good"}];

  fetcher = [self fetcherWithURLString:authedURLString];
  fetcher.authorizer = [TestAuthorizer expiredAsyncAuthorizer];
  fetcher.retryBlock =
      ^(BOOL suggestedWillRetry, NSError *error, GTMSessionFetcherRetryResponse response) {
        XCTAssertEqual(error.code, (NSInteger)401, @"%@", error);
        response(NO);
      };

  expectation = [self expectationWithDescription:@"expired asynchronous authorizer no retry"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    NSString *authHdr = [fetcher.request.allHTTPHeaderFields objectForKey:@"Authorization"];
    XCTAssertNil(authHdr);
    XCTAssertEqual(error.code, (NSInteger)401, @"%@", error);
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  //
  // Fetch with an expired sync authorizer, with automatic refresh.
  //
  fetcher = [self fetcherWithURLString:authedURLString];
  fetcher.authorizer = [TestAuthorizer expiredSyncAuthorizer];
  fetcher.retryBlock =
      ^(BOOL suggestedWillRetry, NSError *error, GTMSessionFetcherRetryResponse response) {
        XCTAssertEqual(error.code, (NSInteger)401, @"%@", error);
        response(YES);
      };

  expectation = [self expectationWithDescription:@"expired synchronous authorizer auto refresh"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    NSString *authHdr = [fetcher.request.allHTTPHeaderFields objectForKey:@"Authorization"];
    XCTAssertEqualObjects(authHdr, kGoodBearerValue);
    XCTAssertEqualObjects(data, [self gettysburgAddress]);
    XCTAssertNil(error);
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  //
  // Fetch with an expired async authorizer, with automatic refresh.
  //
  fetcher = [self fetcherWithURLString:authedURLString];
  fetcher.authorizer = [TestAuthorizer expiredAsyncAuthorizer];
  fetcher.retryBlock =
      ^(BOOL suggestedWillRetry, NSError *error, GTMSessionFetcherRetryResponse response) {
        XCTAssertEqual(error.code, (NSInteger)401, @"%@", error);
        response(YES);
      };

  expectation = [self expectationWithDescription:@"expired asynchronous authorizer auto refresh"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    NSString *authHdr = [fetcher.request.allHTTPHeaderFields objectForKey:@"Authorization"];
    XCTAssertEqualObjects(authHdr, kGoodBearerValue);
    XCTAssertEqualObjects(data, [self gettysburgAddress]);
    XCTAssertNil(error);
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  // Check notifications.
  XCTAssertEqual(fnctr.fetchStarted, 8, @"%@", fnctr.fetchersStartedDescriptions);
  XCTAssertEqual(fnctr.fetchStopped, 8, @"%@", fnctr.fetchersStoppedDescriptions);
  XCTAssertEqual(fnctr.fetchCompletionInvoked, 7);
  XCTAssertEqual(fnctr.retryDelayStarted, 2);
  XCTAssertEqual(fnctr.retryDelayStopped, 2);
#if GTM_BACKGROUND_TASK_FETCHING
  [self waitForBackgroundTaskEndedNotifications:fnctr];
  XCTAssertEqual(fnctr.backgroundTasksStarted.count, (NSUInteger)8);
  XCTAssertEqualObjects(fnctr.backgroundTasksStarted, fnctr.backgroundTasksEnded);
#endif
}

- (void)testAuthorizerFetch_WithoutFetcherService {
  _fetcherService = nil;
  [self testAuthorizerFetch];
}

- (void)testRedirectFetch {
  if (!_isServerRunning) return;

  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(1, 1);

  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];
  [_testServer setRedirectEnabled:YES];

  if (![_testServer isRedirectEnabled]) {
    NSLog(@"*** skipping %@: redirectServer failed to start", [self currentTestName]);
    return;
  }

  //
  // Fetch our test file.  Ensure the body survives the redirection.
  //
  const int kBodyLength = 137;
  NSDictionary *params = @{@"requestBodyLength" : [@(kBodyLength) stringValue]};
  NSString *localURLString = [self localURLStringToTestFileName:kGTMGettysburgFileName
                                                     parameters:params];

  GTMSessionFetcher *fetcher = [self fetcherWithURLString:localURLString];
  fetcher.bodyData = [GTMSessionFetcherTestServer generatedBodyDataWithLength:kBodyLength];

  XCTestExpectation *redirectExpectation = [self expectationWithDescription:@"redirect called"];
  fetcher.willRedirectBlock = ^(NSHTTPURLResponse *redirectResponse, NSURLRequest *redirectRequest,
                                GTMSessionFetcherWillRedirectResponse response) {
    XCTAssert(![redirectResponse.URL.host isEqual:redirectRequest.URL.host] ||
              ![redirectResponse.URL.port isEqual:redirectRequest.URL.port]);
    response(redirectRequest);
    [redirectExpectation fulfill];
  };

  XCTestExpectation *expectation = [self expectationWithDescription:@"completion handler"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    [self assertSuccessfulGettysburgFetchWithFetcher:fetcher data:data error:error];
    // Check that a redirect was performed
    NSURL *requestURL = [NSURL URLWithString:localURLString];
    NSURL *responseURL = fetcher.response.URL;
    XCTAssertTrue(
        ![requestURL.host isEqual:responseURL.host] || ![requestURL.port isEqual:responseURL.port],
        @"failed to redirect");

    // Cookies should have been set by the response; specifically, TestCookie
    // should be set to the name of the file requested.
    NSDictionary *responseHeaders = [(NSHTTPURLResponse *)fetcher.response allHeaderFields];
    NSString *cookiesSetString = [responseHeaders objectForKey:@"Set-Cookie"];
    NSString *cookieExpected = [NSString stringWithFormat:@"TestCookie=%@", kGTMGettysburgFileName];
    XCTAssertEqualObjects(cookiesSetString, cookieExpected);

    // A cookie should've been set.
    NSHTTPCookieStorage *cookieStorage = fetcher.configuration.HTTPCookieStorage;
    NSURL *localhostURL = [NSURL URLWithString:@"http://localhost/"];
    NSArray *cookies = [cookieStorage cookiesForURL:localhostURL];
    XCTAssertEqual(cookies.count, (NSUInteger)1);
    NSHTTPCookie *firstCookie = cookies.firstObject;
    XCTAssertEqualObjects([firstCookie value], @"gettysburgaddress.txt");
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  // Check the notifications.
  XCTAssertEqual(fnctr.fetchStarted, 1, @"%@", fnctr.fetchersStartedDescriptions);
  XCTAssertEqual(fnctr.fetchStopped, 1, @"%@", fnctr.fetchersStoppedDescriptions);
  XCTAssertEqual(fnctr.fetchCompletionInvoked, 1);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
#if GTM_BACKGROUND_TASK_FETCHING
  [self waitForBackgroundTaskEndedNotifications:fnctr];
  XCTAssertEqual(fnctr.backgroundTasksStarted.count, (NSUInteger)1);
  XCTAssertEqualObjects(fnctr.backgroundTasksStarted, fnctr.backgroundTasksEnded);
#endif
}

- (void)testRedirectFetch_WithoutFetcherService {
  _fetcherService = nil;
  [self testRedirectFetch];
}

- (void)testCancelRedirectFetch {
  if (!_isServerRunning) return;

  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(1, 1);

  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];
  [_testServer setRedirectEnabled:YES];

  if (![_testServer isRedirectEnabled]) {
    XCTFail(@"*** skipping %@: redirectServer failed to start", [self currentTestName]);
    return;
  }

  //
  // Fetch our test file.  Ensure the body survives the redirection.
  //
  const int kBodyLength = 137;
  NSDictionary *params = @{@"requestBodyLength" : [@(kBodyLength) stringValue]};
  NSString *localURLString = [self localURLStringToTestFileName:kGTMGettysburgFileName
                                                     parameters:params];

  GTMSessionFetcher *fetcher = [self fetcherWithURLString:localURLString];
  fetcher.bodyData = [GTMSessionFetcherTestServer generatedBodyDataWithLength:kBodyLength];

  XCTestExpectation *redirectExpectation = [self expectationWithDescription:@"redirect block"];
  fetcher.willRedirectBlock = ^(NSHTTPURLResponse *redirectResponse, NSURLRequest *redirectRequest,
                                GTMSessionFetcherWillRedirectResponse response) {
    XCTAssert(![redirectResponse.URL.host isEqual:redirectRequest.URL.host] ||
              ![redirectResponse.URL.port isEqual:redirectRequest.URL.port]);
    response(NULL);
    [redirectExpectation fulfill];
  };

  XCTestExpectation *expectation = [self expectationWithDescription:@"completion handler"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    // Check that a redirect was performed
    NSURL *requestURL = [NSURL URLWithString:localURLString];
    NSURL *responseURL = fetcher.response.URL;
    XCTAssertFalse(
        ![requestURL.host isEqual:responseURL.host] || ![requestURL.port isEqual:responseURL.port],
        @"did not receive redirect");

    XCTAssertEqualObjects(error.domain, kGTMSessionFetcherStatusDomain);
    XCTAssertEqual(error.code, 302, @"expect HTTP 302 status code error when cancelling redirect.");

    // Cookies should have been set by the response; specifically, TestCookie
    // should be set to the name of the file requested.
    NSDictionary *responseHeaders = [(NSHTTPURLResponse *)fetcher.response allHeaderFields];
    NSString *cookiesSetString = [responseHeaders objectForKey:@"Set-Cookie"];
    NSString *cookieExpected = [NSString stringWithFormat:@"TestCookie=%@", kGTMGettysburgFileName];
    XCTAssertEqualObjects(cookiesSetString, cookieExpected);

    // A cookie should've been set.
    NSHTTPCookieStorage *cookieStorage = fetcher.configuration.HTTPCookieStorage;
    NSURL *localhostURL = [NSURL URLWithString:@"http://localhost/"];
    NSArray *cookies = [cookieStorage cookiesForURL:localhostURL];
    XCTAssertEqual(cookies.count, (NSUInteger)1);
    NSHTTPCookie *firstCookie = cookies.firstObject;
    XCTAssertEqualObjects([firstCookie value], @"gettysburgaddress.txt");
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  // Check the notifications.
  XCTAssertEqual(fnctr.fetchStarted, 1, @"%@", fnctr.fetchersStartedDescriptions);
  XCTAssertEqual(fnctr.fetchStopped, 1, @"%@", fnctr.fetchersStoppedDescriptions);
  XCTAssertEqual(fnctr.fetchCompletionInvoked, 1);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
#if GTM_BACKGROUND_TASK_FETCHING
  [self waitForBackgroundTaskEndedNotifications:fnctr];
  XCTAssertEqual(fnctr.backgroundTasksStarted.count, (NSUInteger)1);
  XCTAssertEqualObjects(fnctr.backgroundTasksStarted, fnctr.backgroundTasksEnded);
#endif
}

- (void)testCancelRedirectFetch_WithoutFetcherService {
  _fetcherService = nil;
  [self testCancelRedirectFetch];
}

- (void)testRetryFetches {
  if (!_isServerRunning) return;

  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(11, 11);

  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  NSString *invalidFileURLString = [self localURLStringToTestFileName:kGTMGettysburgFileName
                                                           parameters:@{@"status" : @"503"}];

  __block GTMSessionFetcher *fetcher;

  // Block for allowing up to N retries, where N is an NSNumber in the fetcher's userData.
  GTMSessionFetcherRetryBlock countRetriesBlock = ^(BOOL suggestedWillRetry, NSError *error,
                                                    GTMSessionFetcherRetryResponse response) {
    int count = (int)fetcher.retryCount;
    int allowedRetryCount = [[fetcher userData] intValue];

    BOOL shouldRetry = (count < allowedRetryCount);

    XCTAssertEqualWithAccuracy([fetcher nextRetryInterval], pow(2.0, fetcher.retryCount), 0.001,
                               @"Unexpected next retry interval (expected %f, was %f)",
                               pow(2.0, fetcher.retryCount), fetcher.nextRetryInterval);

    NSData *statusData = [error.userInfo objectForKey:kGTMSessionFetcherStatusDataKey];
    NSString *dataStr = [[NSString alloc] initWithData:statusData encoding:NSUTF8StringEncoding];
    NSInteger code = error.code;
    if (code == 503) {
      NSString *statusDataContentType =
          [error.userInfo objectForKey:kGTMSessionFetcherStatusDataContentTypeKey];
      XCTAssertEqualObjects(statusDataContentType, @"application/json");
      NSString *expectedStr = [[self->_testServer class] JSONBodyStringForStatus:503];
      XCTAssertEqualObjects(dataStr, expectedStr);
    }
    response(shouldRetry);
  };

  // Block for retrying and changing the request to one that will succeed.
  GTMSessionFetcherRetryBlock fixRequestBlock =
      ^(BOOL suggestedWillRetry, NSError *error, GTMSessionFetcherRetryResponse response) {
        XCTAssertEqualWithAccuracy(fetcher.nextRetryInterval, pow(2.0, fetcher.retryCount), 0.001,
                                   @"Unexpected next retry interval (expected %f, was %f)",
                                   pow(2.0, fetcher.retryCount), fetcher.nextRetryInterval);

        // Fix it - change the request to a URL which does not have a status value
        NSString *urlString = [self localURLStringToTestFileName:kGTMGettysburgFileName];
        NSMutableURLRequest *mutableRequest = [fetcher mutableRequestForTesting];
        mutableRequest.URL = [NSURL URLWithString:urlString];

        response(YES);  // Do the retry fetch; it should succeed now.
      };

  //
  // Test: retry until timeout, then expect failure with status code.
  //
  fetcher = [self fetcherForRetryWithURLString:invalidFileURLString
                                    retryBlock:countRetriesBlock
                              maxRetryInterval:5.0  // retry intervals of 1, 2, 4
                                      userData:@1000];
  XCTestExpectation *expectation = [self expectationWithDescription:@"retry timeout completion"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertNotNil(data, @"error data is expected");
    XCTAssertEqual(fetcher.statusCode, (NSInteger)503);
    XCTAssertEqual(fetcher.retryCount, (NSUInteger)3);

    NSNumber *retriesDone = error.userInfo[kGTMSessionFetcherNumberOfRetriesDoneKey];
    NSNumber *elapsedInterval = error.userInfo[kGTMSessionFetcherElapsedIntervalWithRetriesKey];
    XCTAssertEqual(retriesDone.integerValue, 3);
    XCTAssertGreaterThan(elapsedInterval.doubleValue, 0);
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  //
  // Test: retry with server sleep to force timeout, then expect failure with status 408
  // after first retry
  //
  NSString *timeoutFileURLString = [self localURLStringToTestFileName:kGTMGettysburgFileName
                                                           parameters:@{@"sleep" : @"10"}];
  fetcher = [self fetcherForRetryWithURLString:timeoutFileURLString
                                    retryBlock:countRetriesBlock
                              maxRetryInterval:5.0  // retry interval of 1, then exceed 3*max timout
                                      userData:@1000];
  expectation = [self expectationWithDescription:@"retry server sleep completion"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertNil(data, @"error data unexpected");
    XCTAssertEqual(fetcher.statusCode, (NSInteger)408, @"%@", error);
    XCTAssertEqual(fetcher.retryCount, (NSUInteger)1);

    NSNumber *retriesDone = error.userInfo[kGTMSessionFetcherNumberOfRetriesDoneKey];
    NSNumber *elapsedInterval = error.userInfo[kGTMSessionFetcherElapsedIntervalWithRetriesKey];
    XCTAssertEqual(retriesDone.integerValue, 1);
    XCTAssertGreaterThan(elapsedInterval.doubleValue, 0);
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  //
  // Test:  retry twice, then give up.
  //
  fetcher = [self fetcherForRetryWithURLString:invalidFileURLString
                                    retryBlock:countRetriesBlock
                              maxRetryInterval:10.0  // retry intervals of 1, 2, 4, 8
                                      userData:@2];
  expectation = [self expectationWithDescription:@"retry twice completion"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertNotNil(data);
    XCTAssertEqual(fetcher.statusCode, (NSInteger)503, @"%@", error);
    XCTAssertEqual(fetcher.retryCount, (NSUInteger)2);

    NSNumber *retriesDone = error.userInfo[kGTMSessionFetcherNumberOfRetriesDoneKey];
    NSNumber *elapsedInterval = error.userInfo[kGTMSessionFetcherElapsedIntervalWithRetriesKey];
    XCTAssertEqual(retriesDone.integerValue, 2);
    XCTAssertGreaterThan(elapsedInterval.doubleValue, 0);
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  //
  // Test:  Retry, making the request succeed on the first retry
  //        by fixing the URL
  //
  fetcher = [self fetcherForRetryWithURLString:invalidFileURLString
                                    retryBlock:fixRequestBlock
                              maxRetryInterval:30.0
                                      userData:@1000];
  expectation = [self expectationWithDescription:@"retry fix URL"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertNotNil(data);
    XCTAssertEqual(fetcher.statusCode, (NSInteger)200);
    XCTAssertEqual(fetcher.retryCount, (NSUInteger)1);
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  // Check the notifications.
  XCTAssertEqual(fnctr.fetchStarted, 11, @"%@", fnctr.fetchersStartedDescriptions);
  XCTAssertEqual(fnctr.fetchStopped, 11, @"%@", fnctr.fetchersStoppedDescriptions);
  XCTAssertEqual(fnctr.fetchCompletionInvoked, 4);
  XCTAssertEqual(fnctr.retryDelayStarted, 7);
  XCTAssertEqual(fnctr.retryDelayStopped, 7);
#if GTM_BACKGROUND_TASK_FETCHING
  [self waitForBackgroundTaskEndedNotifications:fnctr];
  XCTAssertEqual(fnctr.backgroundTasksStarted.count, (NSUInteger)11);
  XCTAssertEqualObjects(fnctr.backgroundTasksStarted, fnctr.backgroundTasksEnded);
#endif
}

- (void)testRetryFetches_WithoutFetcherService {
  _fetcherService = nil;
  [self testRetryFetches];
}

- (void)testFetchToFile {
  if (!_isServerRunning) return;

  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(1, 1);

  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  // Make the destination URL for downloading.
  NSURL *destFileURL = [self temporaryFileURLWithBaseName:NSStringFromSelector(_cmd)];

  // Get the original file's contents.
  NSString *origContents = [[NSString alloc] initWithData:[self gettysburgAddress]
                                                 encoding:NSUTF8StringEncoding];
  int64_t origLength = (int64_t)origContents.length;
  XCTAssert(origLength > 0, @"Could not read original file");

  //
  // Test the downloading.
  //
  __block int64_t totalWritten = 0;

  NSString *validURLString = [self localURLStringToTestFileName:kGTMGettysburgFileName];
  GTMSessionFetcher *fetcher = [self fetcherWithURLString:validURLString];
  fetcher.destinationFileURL = destFileURL;
  fetcher.downloadProgressBlock =
      ^(int64_t bytesWritten, int64_t totalBytesWritten, int64_t totalBytesExpectedToWrite) {
        // Verify the parameters are reasonable.
        XCTAssertTrue(bytesWritten > 0 && bytesWritten <= origLength, @"%lld", bytesWritten);
        XCTAssertTrue(totalBytesWritten > 0 && totalBytesWritten <= origLength, @"%lld",
                      totalBytesWritten);
        XCTAssertEqual(totalBytesExpectedToWrite, origLength);

        // Total bytes written should increase monotonically.
        XCTAssertTrue(totalBytesWritten > totalWritten, @"%lld !> %lld", totalBytesWritten,
                      totalWritten);
        totalWritten = totalBytesWritten;
      };

  XCTestExpectation *expectation = [self expectationWithDescription:@"completion handler"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertNil(data);
    XCTAssertNil(error);

    NSString *fetchedContents = [NSString stringWithContentsOfURL:destFileURL
                                                         encoding:NSUTF8StringEncoding
                                                            error:NULL];
    XCTAssertEqualObjects(fetchedContents, origContents);
    XCTAssertEqual(totalWritten, origLength, @"downloadProgressBlock not called");
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  [self removeTemporaryFileURL:destFileURL];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  // Check the notifications.
  XCTAssertEqual(fnctr.fetchStarted, 1, @"%@", fnctr.fetchersStartedDescriptions);
  XCTAssertEqual(fnctr.fetchStopped, 1, @"%@", fnctr.fetchersStoppedDescriptions);
  XCTAssertEqual(fnctr.fetchCompletionInvoked, 1);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
#if GTM_BACKGROUND_TASK_FETCHING
  [self waitForBackgroundTaskEndedNotifications:fnctr];
  XCTAssertEqual(fnctr.backgroundTasksStarted.count, (NSUInteger)1);
  XCTAssertEqualObjects(fnctr.backgroundTasksStarted, fnctr.backgroundTasksEnded);
#endif
}

- (void)testFetchToFile_WithoutFetcherService {
  _fetcherService = nil;
  [self testFetchToFile];
}

- (void)testFetchDataSchemeToFile {
  if (!_isServerRunning) return;

  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(1, 1);

  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  // Make the destination URL for downloading.
  NSURL *destFileURL = [self temporaryFileURLWithBaseName:NSStringFromSelector(_cmd)];

  // Get the original file's contents.
  NSString *origContents = [[NSString alloc] initWithData:[self gettysburgAddress]
                                                 encoding:NSUTF8StringEncoding];
  NSString *escapedContents = [origContents
      stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet
                                                             URLQueryAllowedCharacterSet]];
  NSString *validDataURLString = [NSString stringWithFormat:@"data:,%@", escapedContents];
  GTMSessionFetcher *fetcher = [self fetcherWithURLString:validDataURLString];
  fetcher.destinationFileURL = destFileURL;
  XCTestExpectation *expectation = [self expectationWithDescription:@"completion handler"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertNil(data);
    XCTAssertNil(error);

    NSString *fetchedContents = [NSString stringWithContentsOfURL:destFileURL
                                                         encoding:NSUTF8StringEncoding
                                                            error:NULL];
    XCTAssertEqualObjects(fetchedContents, origContents);
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  [self removeTemporaryFileURL:destFileURL];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  // Check the notifications.
  XCTAssertEqual(fnctr.fetchStarted, 1, @"%@", fnctr.fetchersStartedDescriptions);
  XCTAssertEqual(fnctr.fetchStopped, 1, @"%@", fnctr.fetchersStoppedDescriptions);
  XCTAssertEqual(fnctr.fetchCompletionInvoked, 1);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
#if GTM_BACKGROUND_TASK_FETCHING
  [self waitForBackgroundTaskEndedNotifications:fnctr];
  XCTAssertEqual(fnctr.backgroundTasksStarted.count, (NSUInteger)1);
  XCTAssertEqualObjects(fnctr.backgroundTasksStarted, fnctr.backgroundTasksEnded);
#endif
}

- (void)testFetchDataSchemeToFile_WithoutFetcherService {
  _fetcherService = nil;
  [self testFetchDataSchemeToFile];
}

- (void)testUnsuccessfulFetchToFile {
  if (!_isServerRunning) return;

  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(1, 1);

  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  __block int64_t totalWritten = 0;
  NSString *invalidURLString = [self localURLStringToTestFileName:kGTMGettysburgFileName
                                                       parameters:@{@"status" : @"400"}];
  NSString *statusStr = [[_testServer class] JSONBodyStringForStatus:400];
  NSURL *destFileURL = [self temporaryFileURLWithBaseName:NSStringFromSelector(_cmd)];

  GTMSessionFetcher *fetcher = [self fetcherWithURLString:invalidURLString];
  fetcher.destinationFileURL = destFileURL;
  fetcher.downloadProgressBlock =
      ^(int64_t bytesWritten, int64_t totalBytesWritten, int64_t totalBytesExpectedToWrite) {
        // Verify the parameters are reasonable.
        XCTAssertTrue(totalBytesWritten > 0 && totalBytesWritten <= (int64_t)statusStr.length,
                      @"%lld", totalBytesWritten);

        // Total bytes written should increase monotonically.
        XCTAssertTrue(totalBytesWritten > totalWritten, @"%lld !> %lld", totalBytesWritten,
                      totalWritten);
        totalWritten = totalBytesWritten;
      };

  XCTestExpectation *expectation = [self expectationWithDescription:@"completion handler"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertNil(data);

    // errorData gets set with http status error only when the client error is nil.
    // on iOS 8, client error gets returned with URLSession:task:didCompleteWithError:
    // on iOS 9 and up, client error is nil and the http status error with errorData
    // gets set in finishWithError:shouldRetry:
    if (error.domain == kGTMSessionFetcherStatusDomain) {
      NSData *errorData = error.userInfo[kGTMSessionFetcherStatusDataKey];
      XCTAssertNotNil(errorData);
      XCTAssertEqual(errorData.length, (NSUInteger)totalWritten,
                     @"The length of error data should match the size of totalBytesWritten.");
      XCTAssertNotNil(error.userInfo[kGTMSessionFetcherStatusDataContentTypeKey]);
    }

    // Check for two error codes because of the discrepancy between iOS 8 and iOS 9 plus
    // described above
    BOOL isExpectedCode = (error.code == NSURLErrorFileDoesNotExist || error.code == 400);
    XCTAssertTrue(isExpectedCode, @"%@", error);

    // The file should not be copied to the destination URL on status 400 and higher.
    BOOL fileExists = [destFileURL checkResourceIsReachableAndReturnError:NULL];
    XCTAssertFalse(fileExists, @"%@ -- %@", error, destFileURL.path);

    if (error.code == 400) {
      // Check the body JSON of the status code response.
      XCTAssertEqual(totalWritten, (int64_t)statusStr.length, @"downloadProgressBlock not called");
    } else {
      // If the error was NSURLErrorFileDoesNotExist sometimes downloadProgressBlock was
      // called so totalWritten > 0, sometimes not.
    }
    [expectation fulfill];
  }];

  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  // There should be no file to delete.
  XCTAssertFalse([destFileURL checkResourceIsReachableAndReturnError:NULL]);

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  // Check the notifications.
  XCTAssertEqual(fnctr.fetchStarted, 1, @"%@", fnctr.fetchersStartedDescriptions);
  XCTAssertEqual(fnctr.fetchStopped, 1, @"%@", fnctr.fetchersStoppedDescriptions);
  XCTAssertEqual(fnctr.fetchCompletionInvoked, 1);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
#if GTM_BACKGROUND_TASK_FETCHING
  [self waitForBackgroundTaskEndedNotifications:fnctr];
  XCTAssertEqual(fnctr.backgroundTasksStarted.count, (NSUInteger)1);
  XCTAssertEqualObjects(fnctr.backgroundTasksStarted, fnctr.backgroundTasksEnded);
#endif
}

- (void)testUnsuccessfulFetchToFile_WithoutFetcherService {
  _fetcherService = nil;
  [self testUnsuccessfulFetchToFile];
}

- (void)testQuickBeginStopFetching {
  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  // This test exercises the workaround for Radar 18471901. See comments in GTMSessionFetcher.m
  int const kFetcherCreationCount = 1000;

  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(kFetcherCreationCount, kFetcherCreationCount);

  for (int i = 0; i < kFetcherCreationCount; ++i) {
    GTMSessionFetcher *fetcher = [GTMSessionFetcher fetcherWithURLString:@"http://example.com/tst"];
    fetcher.useBackgroundSession = NO;
    fetcher.allowedInsecureSchemes = @[ @"http" ];
    [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
      XCTFail(@"Download not canceled");
    }];
    [fetcher stopFetching];
  }

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  XCTAssertEqual(fnctr.fetchStarted, kFetcherCreationCount, @"%@",
                 fnctr.fetchersStartedDescriptions);
  XCTAssertEqual(fnctr.fetchStopped, kFetcherCreationCount, @"%@",
                 fnctr.fetchersStoppedDescriptions);
  XCTAssertEqual(fnctr.fetchCompletionInvoked, 0);
#if GTM_BACKGROUND_TASK_FETCHING
  [self waitForBackgroundTaskEndedNotifications:fnctr];
  XCTAssertEqual(fnctr.backgroundTasksStarted.count, (NSUInteger)1000);
  XCTAssertEqualObjects(fnctr.backgroundTasksStarted, fnctr.backgroundTasksEnded);
#endif
}

- (void)testQuickBeginStopFetching_WithoutFetcherService {
  _fetcherService = nil;
  [self testQuickBeginStopFetching];
}

- (void)testCancelAndResumeFetchToFile {
  if (!_isServerRunning) return;

  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(2, 2);

  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  NSURL *destFileURL = [self temporaryFileURLWithBaseName:NSStringFromSelector(_cmd)];

  const int64_t kExpectedResponseLen = 5 * 1024 * 1024;
  NSData *expectedResponseData =
      [GTMSessionFetcherTestServer generatedBodyDataWithLength:kExpectedResponseLen];

  //
  // Test the downloading.
  //
  __block int64_t totalWritten = 0;

  NSString *validURLString =
      [self localURLStringToTestFileName:kGTMGettysburgFileName
                              parameters:@{
                                @"responseBodyLength" : [@(kExpectedResponseLen) stringValue]
                              }];
  GTMSessionFetcher *fetcher = [self fetcherWithURLString:validURLString];
  fetcher.destinationFileURL = destFileURL;
  GTMSessionFetcher *__weak weakFetcher = fetcher;
  XCTestExpectation *stopExpectation = [self expectationWithDescription:@"stop fetching"];
  fetcher.downloadProgressBlock = ^(int64_t bytesWritten, int64_t totalBytesWritten,
                                    int64_t totalBytesExpectedToWrite) {
    // Verify the parameters are reasonable.
    XCTAssertTrue(bytesWritten > 0 && bytesWritten <= kExpectedResponseLen, @"%lld", bytesWritten);
    XCTAssertTrue(totalBytesWritten > 0 && totalBytesWritten <= kExpectedResponseLen, @"%lld",
                  totalBytesWritten);
    XCTAssertEqual(totalBytesExpectedToWrite, kExpectedResponseLen);

    // Total bytes written should increase monotonically.
    XCTAssertTrue(totalBytesWritten > totalWritten, @"%lld !> %lld", totalBytesWritten,
                  totalWritten);

    if (totalWritten ==
        0) {  // Ensure stopFetching and fulfilling the expectation happens only once
      dispatch_async(dispatch_get_main_queue(), ^{
        [weakFetcher stopFetching];
        [stopExpectation fulfill];
      });
    }
    totalWritten = totalBytesWritten;
  };

  // NSURLSession's invoking of the resume data block is too unreliable to create an
  // expectation for use in continuous testing.
  __block NSData *resumeData = nil;
  XCTestExpectation *resumeDataExpectation =
      [[XCTestExpectation alloc] initWithDescription:@"resume data"];
  fetcher.resumeDataBlock = ^(NSData *data) {
    resumeData = data;
    [resumeDataExpectation fulfill];
  };

  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTFail(@"initial download not canceled");
  }];

  [self waitForExpectations:@[ stopExpectation ] timeout:_timeoutInterval];

  // NSURLSession's invoking of the resume data block has proven too unreliable to use the
  // XCTestCase expectation waiting methods in continuious testing, so instead use an explicit
  // XCTWaiter to wait on the resume data, and examine the result code.
  //
  // Once stopFetching has been called, give NSURLSession a second to provide resume data or
  // bail on this test.
  XCTWaiter *waiter = [[XCTWaiter alloc] initWithDelegate:nil];
  XCTWaiterResult waiterResult = [waiter waitForExpectations:@[ resumeDataExpectation ]
                                                     timeout:1.0];
  [self assertCallbacksReleasedForFetcher:fetcher];

  if (resumeData == nil) {
    // Sometimes NSURLSession decides it cannot resume; bail on the test.
    if (waiterResult == XCTWaiterResultTimedOut) {
      NSLog(@"*** %@ did not have its resumeDataBlock called; skipping test",
            [self currentTestName]);
    } else {
      NSLog(@"*** %@ received nil resumeData; skipping test", [self currentTestName]);
    }
    return;
  }

  fetcher = [GTMSessionFetcher fetcherWithDownloadResumeData:resumeData];
  fetcher.destinationFileURL = destFileURL;
  fetcher.downloadProgressBlock = ^(int64_t bytesWritten, int64_t totalBytesWritten,
                                    int64_t totalBytesExpectedToWrite) {
    // Verify the parameters are reasonable.
    XCTAssertTrue(bytesWritten > 0 && bytesWritten <= kExpectedResponseLen, @"%lld", bytesWritten);
    XCTAssertTrue(totalBytesWritten > 0 && totalBytesWritten <= kExpectedResponseLen, @"%lld",
                  totalBytesWritten);
    XCTAssertEqual(totalBytesExpectedToWrite, kExpectedResponseLen);

    // Total bytes written should increase monotonically.
    XCTAssertTrue(totalBytesWritten > totalWritten, @"%lld !> %lld", totalBytesWritten,
                  totalWritten);
    totalWritten = totalBytesWritten;
  };
  XCTestExpectation *expectation = [self expectationWithDescription:@"completion handler"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertEqual(data.length, (NSUInteger)0);
    XCTAssertNil(error);

    NSData *written = [NSData dataWithContentsOfURL:destFileURL];
    XCTAssertEqual((int64_t)written.length, kExpectedResponseLen,
                   @"Incorrect file size downloaded");
    XCTAssertTrue([written isEqual:expectedResponseData], @"downloaded data not expected");
    XCTAssertEqual(totalWritten, kExpectedResponseLen, @"downloadProgressBlock not called");
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  [self removeTemporaryFileURL:destFileURL];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  // Check the notifications.
  XCTAssertEqual(fnctr.fetchStarted, 2, @"%@", fnctr.fetchersStartedDescriptions);
  XCTAssertEqual(fnctr.fetchStopped, 2, @"%@", fnctr.fetchersStoppedDescriptions);
  XCTAssertEqual(fnctr.fetchCompletionInvoked, 1);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
#if GTM_BACKGROUND_TASK_FETCHING
  [self waitForBackgroundTaskEndedNotifications:fnctr];
  XCTAssertEqual(fnctr.backgroundTasksStarted.count, (NSUInteger)2);
  XCTAssertEqualObjects(fnctr.backgroundTasksStarted, fnctr.backgroundTasksEnded);
#endif
}

- (void)testCancelAndResumeFetchToFile_WithoutFetcherService {
  _fetcherService = nil;
  [self testCancelAndResumeFetchToFile];
}

- (void)testInsecureRequests {
  if (![GTMSessionFetcher appAllowsInsecureRequests]) return;

  // file:///var/folders/...
  NSString *fileURLString = [[NSURL fileURLWithPath:NSTemporaryDirectory()] absoluteString];

  // http://localhost:59757/gettysburgaddress.txt
  NSString *localhostURLString = [self localURLStringToTestFileName:kGTMGettysburgFileName];

  struct TestRecord {
    __unsafe_unretained NSString *urlString;
    NSUInteger flags;
    NSInteger errorCode;
  };

  const NSInteger kInsecureError = GTMSessionFetcherErrorInsecureRequest;
  const NSUInteger kAllowLocalhostFlag = 1UL << 0;
  const NSUInteger kAllowHTTPSchemeFlag = 1UL << 1;
  const NSUInteger kAllowFileSchemeFlag = 1UL << 2;

  struct TestRecord records[] = {
      {@"http://example.com/", 0, kInsecureError},
      {@"https://example.com/", 0, 0},
      {@"http://example.com/", kAllowHTTPSchemeFlag, 0},
      {@"https://example.com/", kAllowHTTPSchemeFlag, 0},
      {localhostURLString, 0, kInsecureError},
      {localhostURLString, kAllowLocalhostFlag, 0},
      {fileURLString, 0, kInsecureError},
      {fileURLString, kAllowHTTPSchemeFlag, kInsecureError},
      {fileURLString, kAllowFileSchemeFlag, 0},  // file URL allowed by scheme
      {fileURLString, kAllowLocalhostFlag, 0},   // file URL allowed as localhost
      {NULL, 0, 0},
  };

  GTMSessionFetcherTestBlock testBlock =
      ^(GTMSessionFetcher *fetcherToTest, GTMSessionFetcherTestResponse testResponse) {
        testResponse(nil, [NSData data], nil);
      };

  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(10, 10);

  for (int i = 0; records[i].urlString; i++) {
    NSString *urlString = records[i].urlString;
    GTMSessionFetcher *fetcher = [GTMSessionFetcher fetcherWithURLString:urlString];
    fetcher.testBlock = testBlock;
    if (records[i].flags & kAllowHTTPSchemeFlag) {
      fetcher.allowedInsecureSchemes = @[ @"http" ];
    };
    if (records[i].flags & kAllowFileSchemeFlag) {
      fetcher.allowedInsecureSchemes = @[ @"file" ];
    };
    if (records[i].flags & kAllowLocalhostFlag) {
      fetcher.allowLocalhostRequest = YES;
    }
    NSInteger expectedErrorCode = records[i].errorCode;
    XCTestExpectation *expectation = [self
        expectationWithDescription:[NSString stringWithFormat:@"completion handler: index %d", i]];
    [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
      if (expectedErrorCode == 0) {
        XCTAssertNotNil(data, @"index %i -- %@", i, urlString);
      } else {
        XCTAssertEqual(error.code, expectedErrorCode, @"index %i -- %@ -- %@", i, urlString, error);
      }
      [expectation fulfill];
    }];
  }
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();
}

- (void)testInsecureRequests_WithoutFetcherService {
  _fetcherService = nil;
  [self testInsecureRequests];
}

- (void)testCollectingMetrics_WithSuccessfulFetch API_AVAILABLE(ios(10.0), macosx(10.12),
                                                                tvos(10.0), watchos(6.0)) {
  if (!_isServerRunning) return;

  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(1, 1);

  NSString *localURLString = [self localURLStringToTestFileName:kGTMGettysburgFileName];
  GTMSessionFetcher *fetcher = [self fetcherWithURLString:localURLString];
  __block NSURLSessionTaskMetrics *collectedMetrics = nil;

  fetcher.metricsCollectionBlock = ^(NSURLSessionTaskMetrics *_Nonnull metrics) {
    collectedMetrics = metrics;
  };

  XCTestExpectation *expectation = [self expectationWithDescription:@"completion handler"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    [self assertSuccessfulGettysburgFetchWithFetcher:fetcher data:data error:error];
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  XCTAssertNotNil(collectedMetrics);
  XCTAssertEqual(collectedMetrics.transactionMetrics.count, 1);
  XCTAssertNotNil(collectedMetrics.transactionMetrics[0].fetchStartDate);
  XCTAssertNotNil(collectedMetrics.transactionMetrics[0].connectStartDate);
  XCTAssertNotNil(collectedMetrics.transactionMetrics[0].connectEndDate);
  XCTAssertNotNil(collectedMetrics.transactionMetrics[0].requestStartDate);
  XCTAssertNotNil(collectedMetrics.transactionMetrics[0].requestEndDate);
  XCTAssertNotNil(collectedMetrics.transactionMetrics[0].responseStartDate);
  XCTAssertNotNil(collectedMetrics.transactionMetrics[0].responseEndDate);
}

- (void)testCollectingMetrics_WithSuccessfulFetch_WithoutFetcherService API_AVAILABLE(
    ios(10.0), macosx(10.12), tvos(10.0), watchos(6.0)) {
  _fetcherService = nil;
  [self testCollectingMetrics_WithSuccessfulFetch];
}

- (void)testCollectingMetrics_WithWrongFetch_FaildToConnect API_AVAILABLE(ios(10.0), macosx(10.12),
                                                                          tvos(10.0),
                                                                          watchos(6.0)) {
  if (!_isServerRunning) return;

  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(1, 1);

  // Fetch a live, invalid URL
  NSString *badURLString = @"http://localhost:86/";

  GTMSessionFetcher *fetcher = [self fetcherWithURLString:badURLString];

  __block NSURLSessionTaskMetrics *collectedMetrics = nil;
  fetcher.metricsCollectionBlock = ^(NSURLSessionTaskMetrics *_Nonnull metrics) {
    collectedMetrics = metrics;
  };

  XCTestExpectation *expectation = [self expectationWithDescription:@"completion handler"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertNotNil(error);
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  XCTAssertNotNil(collectedMetrics);
  XCTAssertEqual(collectedMetrics.transactionMetrics.count, 1);
  XCTAssertNotNil(collectedMetrics.transactionMetrics[0].fetchStartDate);

  // Connetion not established, and therefore the following metrics do not exist.
  XCTAssertNil(collectedMetrics.transactionMetrics[0].connectStartDate);
  XCTAssertNil(collectedMetrics.transactionMetrics[0].connectEndDate);
  XCTAssertNil(collectedMetrics.transactionMetrics[0].requestStartDate);
  XCTAssertNil(collectedMetrics.transactionMetrics[0].requestEndDate);
  XCTAssertNil(collectedMetrics.transactionMetrics[0].responseStartDate);
  XCTAssertNil(collectedMetrics.transactionMetrics[0].responseEndDate);
}

- (void)testCollectingMetrics_WithWrongFetch_FaildToConnect_WithoutFetcherService API_AVAILABLE(
    ios(10.0), macosx(10.12), tvos(10.0), watchos(6.0)) {
  _fetcherService = nil;
  [self testCollectingMetrics_WithWrongFetch_FaildToConnect];
}

- (void)testCollectingMetrics_WithWrongFetch_BadStatusCode API_AVAILABLE(ios(10.0), macosx(10.12),
                                                                         tvos(10.0), watchos(6.0)) {
  if (!_isServerRunning) return;

  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(1, 1);

  NSString *statusURLString = [self localURLStringToTestFileName:kGTMGettysburgFileName
                                                      parameters:@{@"status" : @"400"}];

  GTMSessionFetcher *fetcher = [self fetcherWithURLString:statusURLString];

  __block NSURLSessionTaskMetrics *collectedMetrics = nil;
  XCTestExpectation *metricsExpectation = [self expectationWithDescription:@"metrics collection"];
  fetcher.metricsCollectionBlock = ^(NSURLSessionTaskMetrics *_Nonnull metrics) {
    collectedMetrics = metrics;
    [metricsExpectation fulfill];
  };

  XCTestExpectation *expectation = [self expectationWithDescription:@"completion handler"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertNotNil(error);
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  XCTAssertNotNil(collectedMetrics);
  XCTAssertEqual(collectedMetrics.transactionMetrics.count, 1);

  // A 400 HTTP response is still a complete response, and therefore these metrics exist.
  XCTAssertNotNil(collectedMetrics.transactionMetrics[0].fetchStartDate);
  XCTAssertNotNil(collectedMetrics.transactionMetrics[0].connectStartDate);
  XCTAssertNotNil(collectedMetrics.transactionMetrics[0].connectEndDate);
  XCTAssertNotNil(collectedMetrics.transactionMetrics[0].requestStartDate);
  XCTAssertNotNil(collectedMetrics.transactionMetrics[0].requestEndDate);
  XCTAssertNotNil(collectedMetrics.transactionMetrics[0].responseStartDate);
  XCTAssertNotNil(collectedMetrics.transactionMetrics[0].responseEndDate);
}

- (void)testCollectingMetrics_WithWrongFetch_BadStatusCode_WithoutFetcherService API_AVAILABLE(
    ios(10.0), macosx(10.12), tvos(10.0), watchos(6.0)) {
  _fetcherService = nil;
  [self testCollectingMetrics_WithWrongFetch_BadStatusCode];
}

#pragma mark - TestBlock Tests

- (void)testFetcherTestBlock {
  // No test server needed.
  _testServer = nil;
  _isServerRunning = NO;

  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(1, 1);

  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  //
  // Use the test block to fake fetching our test file.
  //
  NSURL *testURL = [NSURL URLWithString:@"http://test.example.com/foo"];

  GTMSessionFetcher *fetcher = [self fetcherWithURL:testURL];

  NSData *fakedResultData = [@"Snuffle." dataUsingEncoding:NSUTF8StringEncoding];
  NSHTTPURLResponse *fakedResultResponse =
      [[NSHTTPURLResponse alloc] initWithURL:testURL
                                  statusCode:200
                                 HTTPVersion:@"HTTP/1.1"
                                headerFields:@{@"Bichon" : @"Frise"}];
  NSError *fakedResultError = nil;

  fetcher.testBlock =
      ^(GTMSessionFetcher *fetcherToTest, GTMSessionFetcherTestResponse testResponse) {
        XCTAssertEqualObjects(fetcherToTest.request.URL, testURL);
        testResponse(fakedResultResponse, fakedResultData, fakedResultError);
      };

  XCTestExpectation *expectation = [self expectationWithDescription:@"completion handler"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertNil(fakedResultError);
    XCTAssertEqualObjects(data, fakedResultData);
    XCTAssertEqual(fetcher.statusCode, fakedResultResponse.statusCode);
    XCTAssertEqualObjects(fetcher.responseHeaders[@"Bichon"], @"Frise");
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  XCTAssertEqual(fnctr.fetchStarted, 1, @"%@", fnctr.fetchersStartedDescriptions);
  XCTAssertEqual(fnctr.fetchStopped, 1, @"%@", fnctr.fetchersStoppedDescriptions);
  XCTAssertEqual(fnctr.fetchCompletionInvoked, 1);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
#if GTM_BACKGROUND_TASK_FETCHING
  [self waitForBackgroundTaskEndedNotifications:fnctr];
  XCTAssertEqual(fnctr.backgroundTasksStarted.count, (NSUInteger)1);
  XCTAssertEqualObjects(fnctr.backgroundTasksStarted, fnctr.backgroundTasksEnded);
#endif
}

- (void)testFetcherTestBlock_WithoutFetcherService {
  _fetcherService = nil;
  [self testFetcherTestBlock];
}

- (void)testFetcherTestBlockFailsWithRetries {
  // No test server needed.
  _testServer = nil;
  _isServerRunning = NO;

  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(4, 4);

  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];
  //
  // Fake fetching our test file, failing with an error, including retries.
  //
  NSURL *testURL = [NSURL URLWithString:@"http://test.example.com/foo"];

  GTMSessionFetcher *fetcher = [self fetcherWithURL:testURL];
  fetcher.retryEnabled = YES;
  fetcher.minRetryInterval = 1;
  fetcher.maxRetryInterval = 5;

  NSData *fakedResultData = nil;
  NSHTTPURLResponse *fakedResultResponse =
      [[NSHTTPURLResponse alloc] initWithURL:testURL
                                  statusCode:504  // 504 is a retryable error.
                                 HTTPVersion:@"HTTP/1.1"
                                headerFields:@{@"Alaskan" : @"Malamute"}];
  NSError *fakedResultError =
      [NSError errorWithDomain:kGTMSessionFetcherErrorDomain
                          code:504
                      userInfo:@{kGTMSessionFetcherStatusDataKey : @"Oops."}];

  fetcher.testBlock =
      ^(GTMSessionFetcher *fetcherToTest, GTMSessionFetcherTestResponse testResponse) {
        XCTAssertEqualObjects(fetcherToTest.request.URL, testURL);
        testResponse(fakedResultResponse, fakedResultData, fakedResultError);
      };

  XCTestExpectation *retryExpectation = [self expectationWithDescription:@"retry block"];
  retryExpectation.expectedFulfillmentCount = 3;
  fetcher.retryBlock =
      ^(BOOL suggestedWillRetry, NSError *error, GTMSessionFetcherRetryResponse response) {
        // Should retry after 1, 2, 4 seconds.
        response(YES);
        [retryExpectation fulfill];
      };

  XCTestExpectation *expectation = [self expectationWithDescription:@"completion handler"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertEqualObjects(error.domain, fakedResultError.domain);
    XCTAssertEqual(error.code, fakedResultError.code, @"%@", error);
    XCTAssertEqualObjects(error.userInfo[kGTMSessionFetcherStatusDataKey],
                          fakedResultError.userInfo[kGTMSessionFetcherStatusDataKey]);
    XCTAssertNil(data);
    XCTAssertEqual(fetcher.statusCode, fakedResultResponse.statusCode);
    XCTAssertEqualObjects(fetcher.responseHeaders[@"Alaskan"], @"Malamute");
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  XCTAssertEqual(fnctr.fetchStarted, 4, @"%@", fnctr.fetchersStartedDescriptions);
  XCTAssertEqual(fnctr.fetchStopped, 4, @"%@", fnctr.fetchersStoppedDescriptions);
  XCTAssertEqual(fnctr.fetchCompletionInvoked, 1);
  XCTAssertEqual(fnctr.retryDelayStarted, 3);
  XCTAssertEqual(fnctr.retryDelayStopped, 3);
#if GTM_BACKGROUND_TASK_FETCHING
  [self waitForBackgroundTaskEndedNotifications:fnctr];
  XCTAssertEqual(fnctr.backgroundTasksStarted.count, (NSUInteger)4);
  XCTAssertEqualObjects(fnctr.backgroundTasksStarted, fnctr.backgroundTasksEnded);
#endif
}

- (void)testFetcherTestBlockFailsWithRetries_WithoutFetcherService {
  _fetcherService = nil;
  [self testFetcherTestBlockFailsWithRetries];
}

- (void)testFetcherTestBlockSimulateDataCallbacks {
  // No test server needed.
  _testServer = nil;
  _isServerRunning = NO;

  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(3, 3);

  //
  // Test callbacks for data upload and download.
  //
  NSURL *testURL = [NSURL URLWithString:@"http://test.example.com/foo"];

  NSData *uploadData = [GTMSessionFetcherTestServer generatedBodyDataWithLength:33];
  NSData *downloadData = [GTMSessionFetcherTestServer generatedBodyDataWithLength:333];

  GTMSessionFetcher *fetcher = [self fetcherWithURL:testURL];

  fetcher.bodyData = uploadData;
  NSHTTPURLResponse *fakedResultResponse =
      [[NSHTTPURLResponse alloc] initWithURL:testURL
                                  statusCode:200
                                 HTTPVersion:@"HTTP/1.1"
                                headerFields:@{@"Aussie" : @"Shepherd"}];
  NSError *fakedResultError = nil;

  __block NSURLAuthenticationChallenge *challengePresented;
  fetcher.challengeBlock =
      ^(GTMSessionFetcher *blockFetcher, NSURLAuthenticationChallenge *challenge,
        GTMSessionFetcherChallengeDispositionBlock dispositionBlock) {
        challengePresented = challenge;

        dispositionBlock(NSURLSessionAuthChallengePerformDefaultHandling, nil);
      };

  __block NSURLResponse *initialResponse;
  fetcher.didReceiveResponseBlock =
      ^(NSURLResponse *response,
        GTMSessionFetcherDidReceiveResponseDispositionBlock dispositionBlock) {
        XCTAssertNil(initialResponse);
        initialResponse = response;
        dispositionBlock(NSURLSessionResponseAllow);
      };

  __block int64_t bytesSentSum = 0;
  __block int64_t lastTotalBytesSent = 0;
  int64_t expectedTotalBytesWritten = (int64_t)uploadData.length;

  fetcher.sendProgressBlock =
      ^(int64_t bytesSent, int64_t totalBytesSent, int64_t totalBytesExpectedToSend) {
        bytesSentSum += bytesSent;
        lastTotalBytesSent = totalBytesSent;
        XCTAssertEqual(totalBytesExpectedToSend, expectedTotalBytesWritten);
      };

  __block int64_t bytesReceivedSum = 0;
  __block int64_t lastTotalBytesReceived = 0;
  int64_t expectedTotalBytesReceived = (int64_t)downloadData.length;

  fetcher.receivedProgressBlock = ^(int64_t bytesReceived, int64_t totalBytesReceived) {
    bytesReceivedSum += bytesReceived;
    lastTotalBytesReceived = totalBytesReceived;
  };

  __block NSCachedURLResponse *proposedResponseToCache;
  fetcher.willCacheURLResponseBlock = ^(NSCachedURLResponse *responseProposed,
                                        GTMSessionFetcherWillCacheURLResponseResponse response) {
    proposedResponseToCache = responseProposed;
    response(responseProposed);
  };

  fetcher.testBlock =
      ^(GTMSessionFetcher *fetcherToTest, GTMSessionFetcherTestResponse testResponse) {
        testResponse(fakedResultResponse, downloadData, fakedResultError);
      };

  XCTestExpectation *expectation = [self expectationWithDescription:@"data completion handler"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertNil(error);
    XCTAssertEqualObjects(data, downloadData);

    XCTAssertEqual(bytesSentSum, expectedTotalBytesWritten);
    XCTAssertEqual(lastTotalBytesSent, expectedTotalBytesWritten);

    XCTAssertEqual(bytesReceivedSum, expectedTotalBytesReceived);
    XCTAssertEqual(lastTotalBytesReceived, expectedTotalBytesReceived);

    XCTAssertEqualObjects(challengePresented.protectionSpace.host, testURL.host);
    XCTAssertEqualObjects(initialResponse, fetcher.response);

    XCTAssertEqualObjects(proposedResponseToCache.response, fetcher.response);
    [expectation fulfill];
  }];

  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  //
  // Now test file upload and download.
  //
  fetcher = [self fetcherWithURL:testURL];

  NSURL *uploadFileURL = [self temporaryFileURLWithBaseName:@"TestBlockUpload"];
  NSURL *downloadFileURL = [self temporaryFileURLWithBaseName:@"TestBlockDownload"];
  XCTAssertTrue([uploadData writeToURL:uploadFileURL atomically:YES]);
  XCTAssertTrue([downloadData writeToURL:downloadFileURL atomically:YES]);

  fetcher.bodyFileURL = uploadFileURL;
  fetcher.destinationFileURL = downloadFileURL;

  bytesSentSum = 0;
  lastTotalBytesSent = 0;
  expectedTotalBytesWritten = (int64_t)uploadData.length;

  fetcher.sendProgressBlock =
      ^(int64_t bytesWritten, int64_t totalBytesWritten, int64_t totalBytesExpectedToWrite) {
        bytesSentSum += bytesWritten;
        lastTotalBytesSent = totalBytesWritten;
        XCTAssertEqual(totalBytesExpectedToWrite, expectedTotalBytesWritten);
      };

  bytesReceivedSum = 0;
  lastTotalBytesReceived = 0;
  expectedTotalBytesReceived = (int64_t)downloadData.length;

  fetcher.downloadProgressBlock = ^(int64_t bytesDownloaded, int64_t totalBytesDownloaded,
                                    int64_t totalBytesExpectedToDownload) {
    bytesReceivedSum += bytesDownloaded;
    lastTotalBytesReceived = totalBytesDownloaded;
    XCTAssertEqual(totalBytesExpectedToDownload, expectedTotalBytesReceived);
  };

  fakedResultError = nil;
  fetcher.testBlock =
      ^(GTMSessionFetcher *fetcherToTest, GTMSessionFetcherTestResponse testResponse) {
        testResponse(fakedResultResponse, downloadData, fakedResultError);
      };

  expectation = [self expectationWithDescription:@"file completion handler"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertNil(error);
    XCTAssertNil(data);

    NSData *dataFromFile = [NSData dataWithContentsOfURL:downloadFileURL];
    XCTAssertEqualObjects(dataFromFile, downloadData);

    XCTAssertEqual(bytesSentSum, expectedTotalBytesWritten);
    XCTAssertEqual(lastTotalBytesSent, expectedTotalBytesWritten);

    XCTAssertEqual(bytesReceivedSum, expectedTotalBytesReceived);
    XCTAssertEqual(lastTotalBytesReceived, expectedTotalBytesReceived);
    [expectation fulfill];
  }];

  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  [self removeTemporaryFileURL:uploadFileURL];
  [self removeTemporaryFileURL:downloadFileURL];

  //
  // Now test stream upload, and the data accumulation callback.
  //
  fetcher = [self fetcherWithURL:testURL];

  fetcher.bodyStreamProvider = ^(GTMSessionFetcherBodyStreamProviderResponse response) {
    NSInputStream *stream = [NSInputStream inputStreamWithData:uploadData];
    response(stream);
  };

  NSMutableData *accumulatedData = [NSMutableData data];
  fetcher.accumulateDataBlock = ^(NSData *downloadChunk) {
    if (downloadChunk) {
      [accumulatedData appendData:downloadChunk];
    } else {
      [accumulatedData setLength:0];
    }
  };

  bytesSentSum = 0;
  lastTotalBytesSent = 0;
  expectedTotalBytesWritten = (int64_t)uploadData.length;

  fetcher.sendProgressBlock =
      ^(int64_t bytesWritten, int64_t totalBytesWritten, int64_t totalBytesExpectedToWrite) {
        bytesSentSum += bytesWritten;
        lastTotalBytesSent = totalBytesWritten;
        XCTAssertEqual(totalBytesExpectedToWrite, expectedTotalBytesWritten);
      };

  fakedResultError = nil;
  fetcher.testBlock =
      ^(GTMSessionFetcher *fetcherToTest, GTMSessionFetcherTestResponse testResponse) {
        testResponse(fakedResultResponse, downloadData, fakedResultError);
      };

  expectation = [self expectationWithDescription:@"stream completion handler"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertNil(error);
    XCTAssertNil(data);
    XCTAssertEqualObjects(accumulatedData, downloadData);

    XCTAssertEqual(bytesSentSum, expectedTotalBytesWritten);
    XCTAssertEqual(lastTotalBytesSent, expectedTotalBytesWritten);

    XCTAssertEqual(bytesReceivedSum, expectedTotalBytesReceived);
    XCTAssertEqual(lastTotalBytesReceived, expectedTotalBytesReceived);
    [expectation fulfill];
  }];

  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  // Ensure all expected fetchers have stopped so they don't interfere with other tests.
  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();
}

- (void)testFetcherTestBlockSimulateStreamingDataChunks_defaultIsOneStreamedChunk {
  NSURL *testURL = [NSURL URLWithString:@"http://test.example.com/foo"];

  GTMSessionFetcher *fetcher = [self fetcherWithURL:testURL];
  [self accumulateBlockTestHelperWithFetcher:fetcher
                                         url:testURL
                         generatedDataLength:333
                           expectedCallCount:1];
}

- (void)testFetcherTestBlockSimulateStreamingDataChunks_handlesMultipleStreamedChunks {
  NSURL *testURL = [NSURL URLWithString:@"http://test.example.com/foo"];

  GTMSessionFetcher *fetcher = [self fetcherWithURL:testURL];
  fetcher.testBlockAccumulateDataChunkCount = 10;
  [self accumulateBlockTestHelperWithFetcher:fetcher
                                         url:testURL
                         generatedDataLength:333
                           expectedCallCount:10];
}

- (void)testFetcherTestBlockSimulateStreamingDataChunks_handlesDataEvenlyDivisbleByChunkCount {
  NSURL *testURL = [NSURL URLWithString:@"http://test.example.com/foo"];

  GTMSessionFetcher *fetcher = [self fetcherWithURL:testURL];
  fetcher.testBlockAccumulateDataChunkCount = 10;
  [self accumulateBlockTestHelperWithFetcher:fetcher
                                         url:testURL
                         generatedDataLength:300
                           expectedCallCount:10];
}

- (void)testFetcherTestBlockSimulateStreamingDataChunks_treatsChunkCountOfZeroAsOne {
  NSURL *testURL = [NSURL URLWithString:@"http://test.example.com/foo"];

  GTMSessionFetcher *fetcher = [self fetcherWithURL:testURL];
  fetcher.testBlockAccumulateDataChunkCount = 0;
  [self accumulateBlockTestHelperWithFetcher:fetcher
                                         url:testURL
                         generatedDataLength:333
                           expectedCallCount:1];
}

- (void)testFetcherTestBlockSimulateStreamingWithAccumulateDataBlock_sendsOneChunkForOneByteArray {
  NSURL *testURL = [NSURL URLWithString:@"http://test.example.com/foo"];

  GTMSessionFetcher *fetcher = [self fetcherWithURL:testURL];
  fetcher.testBlockAccumulateDataChunkCount = 10;
  [self accumulateBlockTestHelperWithFetcher:fetcher
                                         url:testURL
                         generatedDataLength:1
                           expectedCallCount:1];
}

// Simulates streaming download data via the accumulate block.
- (void)accumulateBlockTestHelperWithFetcher:(GTMSessionFetcher *)fetcher
                                         url:(NSURL *)testURL
                         generatedDataLength:(NSUInteger)generatedDataLength
                           expectedCallCount:(NSUInteger)expectedCallCount {
  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(1, 1);

  NSData *downloadData =
      [GTMSessionFetcherTestServer generatedBodyDataWithLength:generatedDataLength];

  __block int64_t bytesReceivedSum = 0;
  __block int64_t lastTotalBytesReceived = 0;
  __block int64_t expectedTotalBytesReceived = (int64_t)downloadData.length;

  fetcher.receivedProgressBlock = ^(int64_t bytesReceived, int64_t totalBytesReceived) {
    bytesReceivedSum += bytesReceived;
    lastTotalBytesReceived = totalBytesReceived;
  };

  NSMutableData *accumulatedData = [NSMutableData data];
  __block NSUInteger accumulateDataBlockCallCount = 0;
  fetcher.accumulateDataBlock = ^(NSData *downloadChunk) {
    [accumulatedData appendData:downloadChunk];
    accumulateDataBlockCallCount++;
  };

  NSHTTPURLResponse *fakedResultResponse =
      [[NSHTTPURLResponse alloc] initWithURL:testURL
                                  statusCode:200
                                 HTTPVersion:@"HTTP/1.1"
                                headerFields:@{@"Aussie" : @"Shepherd"}];
  NSError *fakedResultError = nil;
  fetcher.testBlock =
      ^(GTMSessionFetcher *fetcherToTest, GTMSessionFetcherTestResponse testResponse) {
        testResponse(fakedResultResponse, downloadData, fakedResultError);
      };

  XCTestExpectation *expectation = [self expectationWithDescription:@"stream download fetch"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertNil(error);
    XCTAssertNil(data);
    XCTAssertEqualObjects(accumulatedData, downloadData);

    XCTAssertEqual(accumulateDataBlockCallCount, expectedCallCount);

    XCTAssertEqual(bytesReceivedSum, expectedTotalBytesReceived);
    XCTAssertEqual(lastTotalBytesReceived, expectedTotalBytesReceived);
    [expectation fulfill];
  }];

  // Since this is a helper method, wait on the specific expectation rather than all.
  [self waitForExpectations:@[ expectation ] timeout:_timeoutInterval];
  [self assertCallbacksReleasedForFetcher:fetcher];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();
}

- (void)testFetcherTestBlockSimulateDataCallbacks_WithoutFetcherService {
  _fetcherService = nil;
  [self testFetcherTestBlockSimulateDataCallbacks];
}

- (void)testFetcherTestBlockDoesNotCallDidReceiveResponse_WithNilResponse {
  // No test server needed.
  _testServer = nil;
  _isServerRunning = NO;

  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(1, 1);

  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  NSURL *testURL = [NSURL URLWithString:@"http://test.example.com/foo"];
  GTMSessionFetcher *fetcher = [self fetcherWithURL:testURL];

  NSError *fakedResultError =
      [NSError errorWithDomain:kGTMSessionFetcherErrorDomain
                          code:504
                      userInfo:@{kGTMSessionFetcherStatusDataKey : @"Oops."}];

  fetcher.didReceiveResponseBlock =
      ^(NSURLResponse *response,
        GTMSessionFetcherDidReceiveResponseDispositionBlock dispositionBlock) {
        XCTFail(@"didReceiveResponseBlock should not be called.");
      };

  fetcher.testBlock =
      ^(GTMSessionFetcher *fetcherToTest, GTMSessionFetcherTestResponse testResponse) {
        XCTAssertEqualObjects(fetcherToTest.request.URL, testURL);
        testResponse(nil, nil, fakedResultError);
      };

  XCTestExpectation *expectation = [self expectationWithDescription:@"completion handler"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertNotNil(error);
    XCTAssertNil(data);
    XCTAssertEqual(fetcher.statusCode, 0);
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  XCTAssertEqual(fnctr.fetchStarted, 1, @"%@", fnctr.fetchersStartedDescriptions);
  XCTAssertEqual(fnctr.fetchStopped, 1, @"%@", fnctr.fetchersStoppedDescriptions);
  XCTAssertEqual(fnctr.fetchCompletionInvoked, 1);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
#if GTM_BACKGROUND_TASK_FETCHING
  [self waitForBackgroundTaskEndedNotifications:fnctr];
  XCTAssertEqual(fnctr.backgroundTasksStarted.count, (NSUInteger)1);
  XCTAssertEqualObjects(fnctr.backgroundTasksStarted, fnctr.backgroundTasksEnded);
#endif
}

- (void)testFetcherGlobalTestBlock {
  if (!_isServerRunning) return;

  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(2, 2);

  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  //
  // Use the test block to fake fetching our test file.
  //
  NSURL *testURL = [NSURL URLWithString:@"http://test.example.com/foo"];

  GTMSessionFetcher *fetcher = [self fetcherWithURL:testURL];

  NSData *fakedResultData = [@"Snuffle." dataUsingEncoding:NSUTF8StringEncoding];
  NSHTTPURLResponse *fakedResultResponse =
      [[NSHTTPURLResponse alloc] initWithURL:testURL
                                  statusCode:200
                                 HTTPVersion:@"HTTP/1.1"
                                headerFields:@{@"Bichon" : @"Frise"}];
  NSError *fakedResultError = nil;

  [GTMSessionFetcher setGlobalTestBlock:^(GTMSessionFetcher *fetcherToTest,
                                          GTMSessionFetcherTestResponse testResponse) {
    if ([fetcherToTest.request.URL.host isEqual:@"test.example.com"]) {
      testResponse(fakedResultResponse, fakedResultData, fakedResultError);
    } else {
      // Actually do the fetch against the test server.
      testResponse(nil, nil, nil);
    }
  }];

  //
  // First fetch should be handled by the test block.
  //
  XCTestExpectation *expectation = [self expectationWithDescription:@"test block fetch"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertNil(fakedResultError);
    XCTAssertEqualObjects(data, fakedResultData);
    XCTAssertEqual(fetcher.statusCode, fakedResultResponse.statusCode);
    XCTAssertEqualObjects(fetcher.responseHeaders[@"Bichon"], @"Frise");
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  //
  // Second fetch should reach the http server.
  //
  NSString *localURLString = [self localURLStringToTestFileName:kGTMGettysburgFileName];

  fetcher = [self fetcherWithURLString:localURLString];
  fetcher.allowLocalhostRequest = YES;

  expectation = [self expectationWithDescription:@"http server fetch"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    [self assertSuccessfulGettysburgFetchWithFetcher:fetcher data:data error:error];
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  XCTAssertEqual(fnctr.fetchStarted, 2, @"%@", fnctr.fetchersStartedDescriptions);
  XCTAssertEqual(fnctr.fetchStopped, 2, @"%@", fnctr.fetchersStoppedDescriptions);
  XCTAssertEqual(fnctr.fetchCompletionInvoked, 2);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
#if GTM_BACKGROUND_TASK_FETCHING
  [self waitForBackgroundTaskEndedNotifications:fnctr];
  XCTAssertEqual(fnctr.backgroundTasksStarted.count, (NSUInteger)2);
  XCTAssertEqualObjects(fnctr.backgroundTasksStarted, fnctr.backgroundTasksEnded);
#endif

  [GTMSessionFetcher setGlobalTestBlock:nil];
}

- (void)testFetcherGlobalTestBlock_WithoutFetcherService {
  _fetcherService = nil;
  [self testFetcherGlobalTestBlock];
}

#pragma mark - Redirect URL Tests

// Test building the redirect URL from the original request URL and redirect request URL to ensure
// that any scheme changes aside from "http" to "https" are disallowed.
- (void)testFetcherRedirectURLHandling {
  NSArray<NSArray<NSString *> *> *testCases = @[
    @[ @"http://original_host/", @"http://redirect_host/", @"http://redirect_host/" ],
    @[ @"https://original_host/", @"https://redirect_host/", @"https://redirect_host/" ],
    // Insecure to secure = allowed.
    @[ @"http://original_host/", @"https://redirect_host/", @"https://redirect_host/" ],
    // Secure to insecure = disallowed.
    @[ @"https://original_host/", @"http://redirect_host/", @"https://redirect_host/" ],
    // Arbitrary change = disallowed.
    @[ @"http://original_host/", @"fake://redirect_host/", @"http://redirect_host/" ],
    // Validate the behavior of nil URLs in the redirect. This should not happen under
    // real conditions, but if one of the redirect URLs are nil, the other one should
    // always be returned. For these tests, use a string that will not parse to a URL
    // due to invalid characters (the backslash \).
    @[ @"invalid:\\url", @"https://redirect_host/", @"https://redirect_host/" ],
    @[ @"http://original_host/", @"invalid:\\url", @"http://original_host/" ],
  ];

  for (NSArray<NSString *> *testCase in testCases) {
    NSURL *redirectURL =
        [GTMSessionFetcher redirectURLWithOriginalRequestURL:[NSURL URLWithString:testCase[0]]
                                          redirectRequestURL:[NSURL URLWithString:testCase[1]]];
    XCTAssertEqualObjects(redirectURL, [NSURL URLWithString:testCase[2]]);
  }
}

#pragma mark - Utilities

- (NSString *)currentTestName {
  NSInvocation *currentTestInvocation = self.invocation;
  NSString *testCaseName = NSStringFromSelector(currentTestInvocation.selector);
  return testCaseName;
}

- (GTMSessionFetcher *)fetcherWithURLString:(NSString *)urlString {
  NSURLRequest *request = [self requestWithURLString:urlString];
  GTMSessionFetcher *fetcher;
  if (_fetcherService) {
    fetcher = [_fetcherService fetcherWithRequest:request];
  } else {
    fetcher = [GTMSessionFetcher fetcherWithRequest:request];
  }
  XCTAssertNotNil(fetcher);
  fetcher.allowLocalhostRequest = YES;
  fetcher.allowedInsecureSchemes = @[ @"http" ];
  fetcher.comment = [self currentTestName];
  return fetcher;
}

- (GTMSessionFetcher *)fetcherWithURL:(NSURL *)url {
  return [self fetcherWithURLString:url.absoluteString];
}

// Utility method for making a fetcher to test for retries.
- (GTMSessionFetcher *)fetcherForRetryWithURLString:(NSString *)urlString
                                         retryBlock:(GTMSessionFetcherRetryBlock)retryBlock
                                   maxRetryInterval:(NSTimeInterval)maxRetryInterval
                                           userData:(id)userData {
  GTMSessionFetcher *fetcher = [self fetcherWithURLString:urlString];

  fetcher.retryEnabled = YES;
  fetcher.retryBlock = retryBlock;
  fetcher.maxRetryInterval = maxRetryInterval;
  fetcher.userData = userData;

  // We force a minimum retry interval for unit testing; otherwise,
  // we'd have no idea how many retries will occur before the max
  // retry interval occurs, since the minimum would be random
  [fetcher setMinRetryInterval:1.0];
  return fetcher;
}

- (void)waitForBackgroundTaskEndedNotifications:(FetcherNotificationsCounter *)fnctr {
#if GTM_BACKGROUND_TASK_FETCHING
  // The callback group does not include the main thread dispatch of notifications, so
  // we need to explicitly wait for those.
  NSMutableArray *remainingNotificationObjects = [fnctr.backgroundTasksStarted mutableCopy];
  [remainingNotificationObjects removeObjectsInArray:fnctr.backgroundTasksEnded];
  if (remainingNotificationObjects.count == 0) return;

  NSMutableArray *expectations NS_VALID_UNTIL_END_OF_SCOPE = [NSMutableArray array];
  for (id obj in remainingNotificationObjects) {
    [expectations addObject:[self expectationForNotification:kSubUIAppBackgroundTaskEnded
                                                      object:obj
                                                     handler:nil]];
  }
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
#endif
}

@end

@implementation TestAuthorizer
@synthesize async = _async, expired = _expired, willFailWithError = _willFailWithError;

+ (instancetype)syncAuthorizer {
  return [[self alloc] init];
}

+ (instancetype)asyncAuthorizer {
  TestAuthorizer *authorizer = [self syncAuthorizer];
  authorizer.async = YES;
  return authorizer;
}

+ (instancetype)expiredSyncAuthorizer {
  TestAuthorizer *authorizer = [self syncAuthorizer];
  authorizer.expired = YES;
  return authorizer;
}

+ (instancetype)expiredAsyncAuthorizer {
  TestAuthorizer *authorizer = [self asyncAuthorizer];
  authorizer.expired = YES;
  return authorizer;
}

- (void)authorizeRequest:(NSMutableURLRequest *)request
                delegate:(id)delegate
       didFinishSelector:(SEL)sel {
  NSError *error = nil;
  if (self.willFailWithError) {
    error = [NSError errorWithDomain:NSURLErrorDomain
                                code:NSURLErrorNotConnectedToInternet
                            userInfo:nil];
  } else {
    NSString *value = self.expired ? kExpiredBearerValue : kGoodBearerValue;
    [request setValue:value forHTTPHeaderField:@"Authorization"];
  }

  if (delegate && sel) {
    id selfParam = self;
    NSMethodSignature *sig = [delegate methodSignatureForSelector:sel];
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:sig];
    [invocation setSelector:sel];
    [invocation setTarget:delegate];
    [invocation setArgument:&selfParam atIndex:2];
    [invocation setArgument:&request atIndex:3];
    [invocation setArgument:&error atIndex:4];
    if (self.async) {
      [invocation retainArguments];
      dispatch_async(dispatch_get_main_queue(), ^{
        [invocation invoke];
      });
    } else {
      [invocation invoke];
    }
  }
}

- (void)stopAuthorization {
}

- (void)stopAuthorizationForRequest:(NSURLRequest *)request {
}

- (BOOL)isAuthorizingRequest:(NSURLRequest *)request {
  return NO;
}

- (BOOL)isAuthorizedRequest:(NSURLRequest *)request {
  NSString *value = [request.allHTTPHeaderFields objectForKey:@"Authorization"];
  BOOL isValid = [value isEqual:kGoodBearerValue];
  return isValid;
}

- (NSString *)userEmail {
  return @"";
}

- (BOOL)primeForRefresh {
  self.expired = NO;
  return YES;
}

@end

#if GTM_BACKGROUND_TASK_FETCHING
@interface SubstituteUIApplicationTaskInfo : NSObject
@property(atomic, assign) UIBackgroundTaskIdentifier taskIdentifier;
@property(atomic, copy) NSString *taskName;
@property(atomic, copy) dispatch_block_t expirationHandler;
@end

NSString *const kSubUIAppBackgroundTaskBegan = @"kSubUIAppBackgroundTaskBegan";
NSString *const kSubUIAppBackgroundTaskEnded = @"kSubUIAppBackgroundTaskEnded";

@implementation SubstituteUIApplication {
  UIBackgroundTaskIdentifier _identifier;
  NSMutableDictionary<NSNumber *, SubstituteUIApplicationTaskInfo *> *_identifierToTaskInfoMap;
}

UIBackgroundTaskIdentifier gTaskID = 1000;

+ (UIBackgroundTaskIdentifier)lastTaskID {
  @synchronized(self) {
    return gTaskID;
  }
}

+ (UIBackgroundTaskIdentifier)reserveTaskID {
  @synchronized(self) {
    return ++gTaskID;
  }
}

- (UIBackgroundTaskIdentifier)beginBackgroundTaskWithName:(NSString *)taskName
                                        expirationHandler:(dispatch_block_t)handler {
  // Threading stress is tested in [GTMSessionFetcherServiceTest testThreadingStress].
  // For the simple fetcher tests, the fetchers start on the main thread, so the background
  // tasks start on the main thread. Since moving the NSURLSession delegate queue to default
  // to a background queue, this SubstituteUIApplication, gTaskID access, and
  // FetcherNotificationsCounter must be safe from arbitrary threads.
  UIBackgroundTaskIdentifier taskID = [SubstituteUIApplication reserveTaskID];

  SubstituteUIApplicationTaskInfo *taskInfo = [[SubstituteUIApplicationTaskInfo alloc] init];
  taskInfo.taskIdentifier = taskID;
  taskInfo.taskName = taskName;
  taskInfo.expirationHandler = handler;

  @synchronized(self) {
    if (!_identifierToTaskInfoMap) _identifierToTaskInfoMap = [[NSMutableDictionary alloc] init];
    _identifierToTaskInfoMap[@(taskID)] = taskInfo;
  }

  // Post the notification synchronously from the current thread.
  [[NSNotificationCenter defaultCenter] postNotificationName:kSubUIAppBackgroundTaskBegan
                                                      object:@(taskID)];
  return taskID;
}

- (void)endBackgroundTask:(UIBackgroundTaskIdentifier)taskID {
  @synchronized(self) {
    NSAssert(_identifierToTaskInfoMap[@(taskID)] != nil,
             @"endBackgroundTask failed to find task: %lu", (unsigned long)taskID);

    [_identifierToTaskInfoMap removeObjectForKey:@(taskID)];
  }

  // Post the notification synchronously from the current thread.
  [[NSNotificationCenter defaultCenter] postNotificationName:kSubUIAppBackgroundTaskEnded
                                                      object:@(taskID)];
}

- (void)expireAllBackgroundTasksWithCallback:(SubstituteUIApplicationExpirationCallback)handler {
  NSUInteger count;
  @synchronized([SubstituteUIApplication class]) {
    count = _identifierToTaskInfoMap.count;
  }
  if (count == 0) {
    handler(0, nil);
    return;
  }

  @synchronized(self) {
    for (NSNumber *taskID in _identifierToTaskInfoMap) {
      SubstituteUIApplicationTaskInfo *taskInfo = _identifierToTaskInfoMap[taskID];
      taskInfo.expirationHandler();
    }
  }
  // We expect that all background tasks ended themselves soon after their handlers were called.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   NSArray<SubstituteUIApplicationTaskInfo *> *failedToExpire;
                   @synchronized(self) {
                     failedToExpire = self->_identifierToTaskInfoMap.allValues;
                   }
                   handler(count, failedToExpire);
                 });
}

@end

@implementation SubstituteUIApplicationTaskInfo
@synthesize taskIdentifier = _taskIdentifier;
@synthesize taskName = _taskName;
@synthesize expirationHandler = _expirationHandler;

- (NSString *)description {
  return
      [NSString stringWithFormat:@"<task %lu \"%@\">", (unsigned long)_taskIdentifier, _taskName];
}

@end

#endif  // GTM_BACKGROUND_TASK_FETCHING

@implementation FetcherNotificationsCounter {
  NSDate *_counterCreationDate;
#if GTM_BACKGROUND_TASK_FETCHING
  UIBackgroundTaskIdentifier _priorTaskID;
#endif
}

@synthesize fetchStarted = _fetchStarted, fetchStopped = _fetchStopped,
            fetchCompletionInvoked = _fetchCompletionInvoked,
            uploadChunkFetchStarted = _uploadChunkFetchStarted,
            uploadChunkFetchStopped = _uploadChunkFetchStopped,
            retryDelayStarted = _retryDelayStarted, retryDelayStopped = _retryDelayStopped,
            uploadLocationObtained = _uploadLocationObtained,
            uploadChunkRequestPaths = _uploadChunkRequestPaths,
            uploadChunkCommands = _uploadChunkCommands, uploadChunkOffsets = _uploadChunkOffsets,
            uploadChunkLengths = _uploadChunkLengths,
            fetchersStartedDescriptions = _fetchersStartedDescriptions,
            fetchersStoppedDescriptions = _fetchersStoppedDescriptions,
            backgroundTasksStarted = _backgroundTasksStarted,
            backgroundTasksEnded = _backgroundTasksEnded;

- (instancetype)init {
  self = [super init];
  if (self) {
    _counterCreationDate = [[NSDate alloc] init];

    _uploadChunkRequestPaths = [[NSMutableArray alloc] init];
    _uploadChunkCommands = [[NSMutableArray alloc] init];
    _uploadChunkOffsets = [[NSMutableArray alloc] init];
    _uploadChunkLengths = [[NSMutableArray alloc] init];
    _fetchersStartedDescriptions = [[NSMutableArray alloc] init];
    _fetchersStoppedDescriptions = [[NSMutableArray alloc] init];
    _backgroundTasksStarted = [[NSMutableArray alloc] init];
    _backgroundTasksEnded = [[NSMutableArray alloc] init];
#if GTM_BACKGROUND_TASK_FETCHING
    _priorTaskID = [SubstituteUIApplication lastTaskID];
#endif

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self
           selector:@selector(fetchStateChanged:)
               name:kGTMSessionFetcherStartedNotification
             object:nil];
    [nc addObserver:self
           selector:@selector(fetchStateChanged:)
               name:kGTMSessionFetcherStoppedNotification
             object:nil];
    [nc addObserver:self
           selector:@selector(fetchCompletionInvoked:)
               name:kGTMSessionFetcherCompletionInvokedNotification
             object:nil];
    [nc addObserver:self
           selector:@selector(retryDelayStateChanged:)
               name:kGTMSessionFetcherRetryDelayStartedNotification
             object:nil];
    [nc addObserver:self
           selector:@selector(retryDelayStateChanged:)
               name:kGTMSessionFetcherRetryDelayStoppedNotification
             object:nil];
    [nc addObserver:self
           selector:@selector(uploadLocationObtained:)
               name:kGTMSessionFetcherUploadLocationObtainedNotification
             object:nil];
#if GTM_BACKGROUND_TASK_FETCHING
    [nc addObserver:self
           selector:@selector(backgroundTaskBegan:)
               name:kSubUIAppBackgroundTaskBegan
             object:nil];
    [nc addObserver:self
           selector:@selector(backgroundTaskEnded:)
               name:kSubUIAppBackgroundTaskEnded
             object:nil];
#endif
  }
  return self;
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (BOOL)shouldIgnoreNotification:(NSNotification *)note {
  GTMSessionFetcher *fetcher = note.object;
  NSDate *fetcherBeginDate = fetcher.initialBeginFetchDate;
  BOOL isTooOld =
      (fetcherBeginDate && [fetcherBeginDate compare:_counterCreationDate] == NSOrderedAscending);
  return isTooOld;
}

- (NSString *)descriptionForFetcher:(GTMSessionFetcher *)fetcher {
  NSString *description =
      [NSString stringWithFormat:@"fetcher %p %@ %@", fetcher, fetcher.comment ?: @"<no comment>",
                                 fetcher.request.URL.absoluteString];
  if (fetcher.retryCount > 0) {
    description =
        [description stringByAppendingFormat:@" retry %lu", (unsigned long)fetcher.retryCount];
  }
  return description;
}

- (void)fetchStateChanged:(NSNotification *)note {
  if ([self shouldIgnoreNotification:note]) return;

  GTMSessionFetcher *fetcher = note.object;
  BOOL isUploadChunkFetcher = ([fetcher parentUploadFetcher] != nil);
  BOOL isFetchStartedNotification = [note.name isEqual:kGTMSessionFetcherStartedNotification];

  if (isFetchStartedNotification) {
    ++_fetchStarted;
    [_fetchersStartedDescriptions addObject:[self descriptionForFetcher:fetcher]];

    if (isUploadChunkFetcher) {
      ++_uploadChunkFetchStarted;

      NSURLRequest *request = fetcher.request;
      NSString *command = [request valueForHTTPHeaderField:@"X-Goog-Upload-Command"];
      NSInteger offset = [[request valueForHTTPHeaderField:@"X-Goog-Upload-Offset"] integerValue];
      NSInteger length = [[request valueForHTTPHeaderField:@"Content-Length"] integerValue];
      NSString *path = request.URL.path;
      [_uploadChunkRequestPaths addObject:path];
      [_uploadChunkCommands addObject:command];
      [_uploadChunkOffsets addObject:@(offset)];
      [_uploadChunkLengths addObject:@(length)];

      NSAssert([[fetcher parentUploadFetcher] isKindOfClass:[GTMSessionUploadFetcher class]],
               @"Unexpected parent");
    }
  } else {
    ++_fetchStopped;
    [_fetchersStoppedDescriptions addObject:[self descriptionForFetcher:fetcher]];

    if (isUploadChunkFetcher) {
      ++_uploadChunkFetchStopped;
    }
  }

  NSAssert(_fetchStopped <= _fetchStarted, @"fetch notification imbalance: starts=%d stops=%d",
           (int)_fetchStarted, (int)_fetchStopped);
}

- (void)fetchCompletionInvoked:(NSNotification *)note {
  if ([self shouldIgnoreNotification:note]) return;

  ++_fetchCompletionInvoked;
}

- (void)retryDelayStateChanged:(NSNotification *)note {
  if ([self shouldIgnoreNotification:note]) return;

  if ([note.name isEqual:kGTMSessionFetcherRetryDelayStartedNotification]) {
    ++_retryDelayStarted;
  } else {
    ++_retryDelayStopped;
  }
  NSAssert(_retryDelayStopped <= _retryDelayStarted,
           @"retry delay notification imbalance: starts=%d stops=%d", (int)_retryDelayStarted,
           (int)_retryDelayStopped);
}

- (void)uploadLocationObtained:(NSNotification *)note {
  if ([self shouldIgnoreNotification:note]) return;

  GTMSessionUploadFetcher *fetcher = note.object;
#pragma unused(fetcher)  // Unused when NS_BLOCK_ASSERTIONS

  NSAssert(fetcher.uploadLocationURL != nil, @"missing upload location: %@", fetcher);

  ++_uploadLocationObtained;
}

#if GTM_BACKGROUND_TASK_FETCHING
- (void)backgroundTaskBegan:(NSNotification *)note {
  // Ignore notifications that predate this object's existence.
  if (((NSNumber *)note.object).unsignedLongLongValue <= _priorTaskID) {
    return;
  }
  @synchronized(self) {
    [_backgroundTasksStarted addObject:(id)note.object];
  }
}

- (void)backgroundTaskEnded:(NSNotification *)note {
  @synchronized(self) {
    // Ignore notifications that were started prior to this object's existence.
    if (![_backgroundTasksStarted containsObject:(NSNumber *)note.object]) return;

    [_backgroundTasksEnded addObject:(id)note.object];
  }
}
#endif  // GTM_BACKGROUND_TASK_FETCHING

@end

static bool IsCurrentProcessBeingDebugged(void) {
  int result = 0;

  pid_t pid = getpid();
  int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
  u_int mibSize = sizeof(mib) / sizeof(int);
  size_t actualSize;

  if (sysctl(mib, mibSize, NULL, &actualSize, NULL, 0) == 0) {
    if (actualSize >= sizeof(struct kinfo_proc)) {
      struct kinfo_proc *info = (struct kinfo_proc *)malloc(actualSize);

      if (info) {
        // This comes from looking at the Darwin xnu Kernel
        if (sysctl(mib, mibSize, info, &actualSize, NULL, 0) == 0)
          result = (info->kp_proc.p_flag & P_TRACED) ? 1 : 0;

        free(info);
      }
    }
  }

  return result;
}

#endif  // !TARGET_OS_WATCH
