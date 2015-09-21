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

#import "GTMSessionFetcherFetchingTest.h"

static bool IsCurrentProcessBeingDebugged(void);

static NSString *const kGoodBearerValue = @"Bearer good";
static NSString *const kExpiredBearerValue = @"Bearer expired";

// The test file available in the Tests/Data folder.
NSString *const kGTMGettysburgFileName = @"gettysburgaddress.txt";

// Base class for fetcher and chunked upload tests.
@implementation GTMSessionFetcherBaseTest

- (void)setUp {
  // The wrong-fetch test can take >10s to pass.
  //
  // During debugging of the unit tests, we want to avoid timeouts.
  _timeoutInterval = IsCurrentProcessBeingDebugged() ? 3600.0 : 30.0;

  NSString *docRoot = [self docRootPath];

  _testServer = [[GTMSessionFetcherTestServer alloc] initWithDocRoot:docRoot];
  _isServerRunning = (_testServer != nil);
  XCTAssertTrue(_isServerRunning,
                @">>> http test server failed to launch; skipping fetcher tests\n");
}

- (void)tearDown {
  _testServer = nil;
  _isServerRunning = NO;

  [[GTMSessionFetcher staticCookieStorage] removeAllCookies];
}

#pragma mark -

- (NSString *)docRootPath {
  // Make a path to the test folder containing documents to be returned by the http server.
  NSBundle *testBundle = [NSBundle bundleForClass:[self class]];
  XCTAssertNotNil(testBundle);

  NSString *docFolder = [testBundle resourcePath];
  return docFolder;
}

- (NSData *)gettysburgAddress {
  // Return the raw data of our test file.
  NSString *gettysburgPath = [_testServer localPathForFile:kGTMGettysburgFileName];
  NSData *gettysburgAddress = [NSData dataWithContentsOfFile:gettysburgPath];
  return gettysburgAddress;
}

- (NSURL *)temporaryFileURLWithBaseName:(NSString *)baseName {
  static int counter = 0;
  NSString *fileName = [NSString stringWithFormat:@"GTMFetcherTest_%@_%@_%d",
                        baseName, [NSDate date], ++counter];
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

  // Just for sanity, let's make sure we see the file locally, so
  // we can expect the http server to find it too.
  //
  // We exclude parameters when looking for the file name locally.
  NSRange range = [name rangeOfString:@"?"];
  if (range.location != NSNotFound) {
    name = [name substringToIndex:range.location];
  }

  NSString *filePath = [_testServer localPathForFile:name];

  BOOL doesExist = [[NSFileManager defaultManager] fileExistsAtPath:filePath];
  XCTAssertTrue(doesExist, @"Missing test file %@", filePath);

  return localURLString;
}

- (NSString *)localURLStringToTestFileName:(NSString *)name
                                parameters:(NSDictionary *)params {
  NSString *localURLString = [self localURLStringToTestFileName:name];

  // Add any parameters from the dictionary.
  if ([params count]) {
    NSMutableArray *array = [NSMutableArray array];
    for (NSString *key in params) {
      [array addObject:[NSString stringWithFormat:@"%@=%@",
                        key, [[params objectForKey:key] description]]];
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
                        (int)[data length], (int)fetcher.statusCode,
                        fetcher.mutableRequest, error);
  XCTAssertNotNil(fetcher.response);
  XCTAssertNotNil(fetcher.mutableRequest, @"Missing request");
  XCTAssertEqual(fetcher.statusCode, (NSInteger)200, @"%@", fetcher.mutableRequest);
}

- (void)testFetch {
  if (!_isServerRunning) return;

  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  //
  // Fetch our test file.
  //
  NSString *localURLString = [self localURLStringToTestFileName:kGTMGettysburgFileName];
  GTMSessionFetcher *fetcher = [self fetcherWithURLString:localURLString];
  __block NSHTTPCookieStorage *cookieStorage;

  __block NSCachedURLResponse *proposedResponseToCache;
  fetcher.willCacheURLResponseBlock = ^(NSCachedURLResponse *responseProposed,
                                        GTMSessionFetcherWillCacheURLResponseResponse response) {
      proposedResponseToCache = responseProposed;
      response(responseProposed);
  };

  __block NSURLResponse *initialResponse;
  fetcher.didReceiveResponseBlock = ^(NSURLResponse *response,
                                      GTMSessionFetcherDidReceiveResponseDispositionBlock dispositionBlock) {
      XCTAssertNil(initialResponse);
      initialResponse = response;
      dispositionBlock(NSURLSessionResponseAllow);
  };

  fetcher.willRedirectBlock = ^(NSHTTPURLResponse *redirectResponse,
                                NSURLRequest *redirectRequest,
                                GTMSessionFetcherWillRedirectResponse response) {
      XCTFail(@"redirect not expected");
  };

  NSString *cookieExpected = [NSString stringWithFormat:@"TestCookie=%@", kGTMGettysburgFileName];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
      [self assertSuccessfulGettysburgFetchWithFetcher:fetcher
                                                  data:data
                                                 error:error];

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
      NSArray *cookies = [cookieStorage cookiesForURL:[NSURL URLWithString:@"http://localhost/"]];
      XCTAssertEqual([cookies count], (NSUInteger)1);
      NSHTTPCookie *firstCookie = [cookies firstObject];
      XCTAssertEqualObjects([firstCookie value], @"gettysburgaddress.txt");

      // The initial response should be the final response;
      XCTAssertEqualObjects(initialResponse, fetcher.response);

      // The response should've been cached.
      XCTAssertEqualObjects(proposedResponseToCache.response.URL, fetcher.response.URL);
      XCTAssertEqualObjects([(NSHTTPURLResponse *)proposedResponseToCache.response allHeaderFields],
                            [(NSHTTPURLResponse *)fetcher.response allHeaderFields]);
  }];
  XCTAssertTrue([fetcher waitForCompletionWithTimeout:_timeoutInterval], @"timed out");
  [self assertCallbacksReleasedForFetcher:fetcher];

  //
  // Repeat the fetch, reusing the session's cookie storage.
  //
  NSURLSessionConfiguration *priorConfig = fetcher.configuration;
  __block BOOL wasConfigBlockCalled = NO;

  fetcher = [self fetcherWithURLString:localURLString];
  fetcher.configuration = priorConfig;
  // TODO(seh): Shouldn't be needed; without it the cookie isn't being received by the test server.
  // https://b2.corp.google.com/issues/17646646
  [fetcher.mutableRequest setValue:cookieExpected forHTTPHeaderField:@"Cookie"];
  fetcher.configurationBlock = ^(GTMSessionFetcher *configFetcher,
                                 NSURLSessionConfiguration *config) {
      wasConfigBlockCalled = YES;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-retain-cycles"
      XCTAssertEqual(configFetcher, fetcher);
#pragma clang diagnostic pop
      XCTAssertEqualObjects(config.HTTPCookieStorage, cookieStorage);
  };

  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
      XCTAssertEqualObjects(data, [self gettysburgAddress], @"Unexpected data.");

      // The cookie set previously should be sent with this request.  See what cookies the
      // http server found.
      NSDictionary *allHeaderFields = [(NSHTTPURLResponse *)fetcher.response allHeaderFields];
      NSString *cookiesSent = [allHeaderFields objectForKey:@"FoundCookies"];
      XCTAssertEqualObjects(cookiesSent, cookieExpected);
  }];
  XCTAssertTrue([fetcher waitForCompletionWithTimeout:_timeoutInterval], @"timed out");

  XCTAssert(wasConfigBlockCalled);

  [self assertCallbacksReleasedForFetcher:fetcher];

  // Check the notifications.
  XCTAssertEqual(fnctr.fetchStarted, 2);
  XCTAssertEqual(fnctr.fetchStopped, 2);
  XCTAssertEqual(fnctr.uploadChunkFetchStarted, 0);
  XCTAssertEqual(fnctr.uploadChunkFetchStopped, 0);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
}

- (void)testAccumulatingFetch {
  if (!_isServerRunning) return;

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

  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
      XCTAssertNil(data);
      [self assertSuccessfulGettysburgFetchWithFetcher:fetcher
                                                  data:accumulatedData
                                                 error:error];
  }];
  XCTAssertTrue([fetcher waitForCompletionWithTimeout:_timeoutInterval], @"timed out");
  [self assertCallbacksReleasedForFetcher:fetcher];

  // Check the notifications.
  XCTAssertEqual(fnctr.fetchStarted, 1);
  XCTAssertEqual(fnctr.fetchStopped, 1);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
}

- (void)testWrongFetch {
  if (!_isServerRunning) return;

  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  //
  // Fetch a live, invalid URL
  //
  NSString *badURLString = @"http://localhost:86/";

  GTMSessionFetcher *fetcher = [self fetcherWithURLString:badURLString];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
      if (data) {
        NSString *str = [[NSString alloc] initWithData:data
                                              encoding:NSUTF8StringEncoding];
        XCTAssertNil(data, @"Unexpected data: %@", str);
      }
      XCTAssertNotNil(error);
      XCTAssertEqual(fetcher.statusCode, (NSInteger)0);
  }];
  XCTAssertTrue([fetcher waitForCompletionWithTimeout:_timeoutInterval], @"timed out");
  [self assertCallbacksReleasedForFetcher:fetcher];

  //
  // Fetch requesting a specific status code from our http server.
  //
  NSString *statusURLString = [self localURLStringToTestFileName:kGTMGettysburgFileName
                                                      parameters:@{ @"status": @"400" }];

  fetcher = [self fetcherWithURLString:statusURLString];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
      NSString *statusStr = [[_testServer class] JSONBodyStringForStatus:400];
      NSData *errorBodyData = [statusStr dataUsingEncoding:NSUTF8StringEncoding];
      XCTAssertEqualObjects(data, errorBodyData);

      XCTAssertNotNil(error);
      XCTAssertEqual(fetcher.statusCode, (NSInteger)400, @"%@", error);

      NSData *statusData = [[error userInfo] objectForKey:kGTMSessionFetcherStatusDataKey];
      XCTAssertNotNil(statusData, @"Missing data in error");
      if (statusData) {
        NSString *dataStr = [[NSString alloc] initWithData:statusData
                                                  encoding:NSUTF8StringEncoding];
        NSString *expectedStr = [[_testServer class] JSONBodyStringForStatus:400];
        XCTAssertEqualObjects(dataStr, expectedStr, @"Expected JSON status data");
      }
  }];
  XCTAssertTrue([fetcher waitForCompletionWithTimeout:_timeoutInterval], @"timed out");
  [self assertCallbacksReleasedForFetcher:fetcher];

  // Check the notifications.
  XCTAssertEqual(fnctr.fetchStarted, 2);
  XCTAssertEqual(fnctr.fetchStopped, 2);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
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

  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertNil(data);
    XCTAssertEqual(error.code, NSFileReadNoSuchFileError);
  }];
  XCTAssertTrue([fetcher waitForCompletionWithTimeout:_timeoutInterval], @"timed out");
  [self assertCallbacksReleasedForFetcher:fetcher];

  // Check the notifications.
  XCTAssertEqual(fnctr.fetchStarted, 0);
  XCTAssertEqual(fnctr.fetchStopped, 0);
}

- (void)testDataBodyFetch {
  if (!_isServerRunning) return;

  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  //
  // Fetch our test file with an NSData body in the request.
  //
  const int kBodyLength = 133;
  NSString *localURLString =
      [self localURLStringToTestFileName:kGTMGettysburgFileName
                              parameters:@{ @"requestBodyLength": [@(kBodyLength) stringValue] }];
  GTMSessionFetcher *fetcher = [self fetcherWithURLString:localURLString];

  fetcher.bodyData = [GTMSessionFetcherTestServer generatedBodyDataWithLength:kBodyLength];

  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
      // We'll verify we fetched from the server the actual data on disk.
      [self assertSuccessfulGettysburgFetchWithFetcher:fetcher
                                                  data:data
                                                 error:error];
  }];
  XCTAssertTrue([fetcher waitForCompletionWithTimeout:_timeoutInterval], @"timed out");
  [self assertCallbacksReleasedForFetcher:fetcher];

  // Check the notifications.
  XCTAssertEqual(fnctr.fetchStarted, 1);
  XCTAssertEqual(fnctr.fetchStopped, 1);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
}

- (void)testCallbackQueue {
  // We should improve this to test the queue of all callback blocks.
  if (!_isServerRunning) return;

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
    [self assertSuccessfulGettysburgFetchWithFetcher:fetcher
                                                data:data
                                               error:error];
    XCTAssertTrue([NSThread isMainThread], @"Unexpected queue %s",
                  dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL));
    [finishExpectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval
                               handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  //
  // Setting a specific queue should call back on that queue.
  //
  fetcher = [self fetcherWithURLString:localURLString];
  fetcher.bodyData = bodyData;

  dispatch_queue_t bgQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0);
  fetcher.callbackQueue = bgQueue;

  finishExpectation =
      [self expectationWithDescription:@"testCallbackQueue specific"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    [self assertSuccessfulGettysburgFetchWithFetcher:fetcher
                                                data:data
                                               error:error];
    BOOL areSame = (strcmp(dispatch_queue_get_label(bgQueue),
                           dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL)) == 0);
    XCTAssert(areSame, @"Unexpected queue: %s ≠ %s",
              dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL),
              dispatch_queue_get_label(bgQueue)
              );
    [finishExpectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval
                               handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];
}

- (void)testStreamProviderFetch {
  if (!_isServerRunning) return;

  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  //
  // Fetch our test file with an NSInputStream provider block.
  //
  const int kBodyLength = 1024 * 1024;
  NSString *localURLString =
      [self localURLStringToTestFileName:kGTMGettysburgFileName
                              parameters:@{ @"requestBodyLength" : @(kBodyLength) }];

  GTMSessionFetcher *fetcher = [self fetcherWithURLString:localURLString];

  fetcher.bodyStreamProvider = ^(GTMSessionFetcherBodyStreamProviderResponse response) {
      NSData *bodyData = [GTMSessionFetcherTestServer generatedBodyDataWithLength:kBodyLength];
      NSInputStream *stream = [NSInputStream inputStreamWithData:bodyData];
      response(stream);
  };

  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
      // We'll verify we fetched from the server the actual data on disk.
      [self assertSuccessfulGettysburgFetchWithFetcher:fetcher
                                                  data:data
                                                 error:error];
  }];
  XCTAssertTrue([fetcher waitForCompletionWithTimeout:_timeoutInterval], @"timed out");
  [self assertCallbacksReleasedForFetcher:fetcher];

  // Check the notifications.
  XCTAssertEqual(fnctr.fetchStarted, 1);
  XCTAssertEqual(fnctr.fetchStopped, 1);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
}

- (void)testHTTPBodyStreamFetch {
  // NOTE: This test is not compatible with redirects, while testStreamProviderFetch is.
  // Setting HTTPBodyStream and redirecting the initial request causes NSURLSession to hang after
  // notifying the delegate of the redirect. This occurs with our test server and Google.org.
  if (!_isServerRunning) return;

  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  //
  // Fetch our test file with an NSInputStream provider block.
  //
  const int kBodyLength = 1024 * 1024;
  NSString *localURLString =
      [self localURLStringToTestFileName:kGTMGettysburgFileName
                              parameters:@{ @"requestBodyLength" : @(kBodyLength) }];

  NSMutableURLRequest *request = [self requestWithURLString:localURLString];
  NSData *bodyData = [GTMSessionFetcherTestServer generatedBodyDataWithLength:kBodyLength];
  NSInputStream *stream = [NSInputStream inputStreamWithData:bodyData];
  [request setHTTPBodyStream:stream];
  GTMSessionFetcher *fetcher = [GTMSessionFetcher fetcherWithRequest:request];
  fetcher.allowLocalhostRequest = YES;
  XCTAssertNotNil(fetcher);

  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
      // We'll verify we fetched from the server the actual data on disk.
      [self assertSuccessfulGettysburgFetchWithFetcher:fetcher
                                                  data:data
                                                 error:error];
  }];
  XCTAssertTrue([fetcher waitForCompletionWithTimeout:_timeoutInterval], @"timed out");
  [self assertCallbacksReleasedForFetcher:fetcher];

  // Check the notifications.
  XCTAssertEqual(fnctr.fetchStarted, 1);
  XCTAssertEqual(fnctr.fetchStopped, 1);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
}

- (void)testHTTPAuthentication {
  if (!_isServerRunning) return;

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
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
      // We'll verify we fetched from the server the actual data on disk.
      [self assertSuccessfulGettysburgFetchWithFetcher:fetcher
                                                  data:data
                                                 error:error];
      XCTAssertEqual(_testServer.lastHTTPAuthenticationType, kGTMHTTPAuthenticationTypeBasic);
  }];
  XCTAssertTrue([fetcher waitForCompletionWithTimeout:_timeoutInterval], @"timed out");
  [self assertCallbacksReleasedForFetcher:fetcher];

  // Verify Digest Authentication.
  fetcher = [self fetcherWithURLString:localURLString];
  fetcher.credential = goodCredential;
  [_testServer setHTTPAuthenticationType:kGTMHTTPAuthenticationTypeDigest
                                username:@"user"
                                password:@"password"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
      // We'll verify we fetched from the server the actual data on disk.
      [self assertSuccessfulGettysburgFetchWithFetcher:fetcher
                                                  data:data
                                                 error:error];
      XCTAssertEqual(_testServer.lastHTTPAuthenticationType, kGTMHTTPAuthenticationTypeDigest);
  }];
  XCTAssertTrue([fetcher waitForCompletionWithTimeout:_timeoutInterval], @"timed out");
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
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
      XCTAssertNil(data);
      XCTAssertEqual([error code], (NSInteger)NSURLErrorCancelled, @"%@", error);
      XCTAssertEqual(_testServer.lastHTTPAuthenticationType, kGTMHTTPAuthenticationTypeInvalid);
  }];
  XCTAssertTrue([fetcher waitForCompletionWithTimeout:_timeoutInterval], @"timed out");
  [self assertCallbacksReleasedForFetcher:fetcher];

  // Check the notifications.
  XCTAssertEqual(fnctr.fetchStarted, 3);
  XCTAssertEqual(fnctr.fetchStopped, 3);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
}

- (void)testAuthorizerFetch {
  if (!_isServerRunning) return;

  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  //
  // Fetch a live, authorized URL.
  //
  NSString *authedURLString = [self localURLStringToTestFileName:kGTMGettysburgFileName
                                                      parameters:@{ @"oauth2": @"good" }];

  GTMSessionFetcher *fetcher = [self fetcherWithURLString:authedURLString];
  fetcher.authorizer = [TestAuthorizer syncAuthorizer];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
      NSString *authHdr =
          [[fetcher.mutableRequest allHTTPHeaderFields] objectForKey:@"Authorization"];
      XCTAssertEqualObjects(authHdr, kGoodBearerValue);
      XCTAssertEqualObjects(data, [self gettysburgAddress]);
      XCTAssertNil(error, @"unexpected error");
  }];
  XCTAssertTrue([fetcher waitForCompletionWithTimeout:_timeoutInterval], @"timed out");
  [self assertCallbacksReleasedForFetcher:fetcher];

  //
  // Repeat with an async authorization.
  //
  fetcher = [self fetcherWithURLString:authedURLString];
  fetcher.authorizer = [TestAuthorizer asyncAuthorizer];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
      NSString *authHdr =
          [[fetcher.mutableRequest allHTTPHeaderFields] objectForKey:@"Authorization"];
      XCTAssertEqualObjects(authHdr, kGoodBearerValue);
      XCTAssertEqualObjects(data, [self gettysburgAddress]);
      XCTAssertNil(error, @"unexpected error");
  }];
  XCTAssertTrue([fetcher waitForCompletionWithTimeout:_timeoutInterval], @"timed out");
  [self assertCallbacksReleasedForFetcher:fetcher];

  //
  // Fetch with an expired sync authorizer, no retry allowed.
  //
  authedURLString = [self localURLStringToTestFileName:kGTMGettysburgFileName
                                            parameters:@{ @"oauth2": @"good" }];

  fetcher = [self fetcherWithURLString:authedURLString];
  fetcher.authorizer = [TestAuthorizer expiredSyncAuthorizer];
  fetcher.retryBlock = ^(BOOL suggestedWillRetry, NSError *error,
                         GTMSessionFetcherRetryResponse response) {
      XCTAssertEqual([error code], (NSInteger)401, @"%@", error);
      response(NO);
  };

  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
      NSString *authHdr = [[fetcher.mutableRequest allHTTPHeaderFields] objectForKey:@"Authorization"];
      XCTAssertNil(authHdr);
      XCTAssertEqual([error code], (NSInteger)401, @"%@", error);
  }];
  XCTAssertTrue([fetcher waitForCompletionWithTimeout:_timeoutInterval], @"timed out");
  [self assertCallbacksReleasedForFetcher:fetcher];

  //
  // Fetch with an expired async authorizer, no retry allowed.
  //
  authedURLString = [self localURLStringToTestFileName:kGTMGettysburgFileName
                                            parameters:@{ @"oauth2": @"good" }];

  fetcher = [self fetcherWithURLString:authedURLString];
  fetcher.authorizer = [TestAuthorizer expiredAsyncAuthorizer];
  fetcher.retryBlock = ^(BOOL suggestedWillRetry, NSError *error,
                         GTMSessionFetcherRetryResponse response) {
      XCTAssertEqual([error code], (NSInteger)401, @"%@", error);
      response(NO);
  };

  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
      NSString *authHdr =
          [[fetcher.mutableRequest allHTTPHeaderFields] objectForKey:@"Authorization"];
      XCTAssertNil(authHdr);
      XCTAssertEqual([error code], (NSInteger)401, @"%@", error);
  }];
  XCTAssertTrue([fetcher waitForCompletionWithTimeout:_timeoutInterval], @"timed out");
  [self assertCallbacksReleasedForFetcher:fetcher];

  //
  // Fetch with an expired sync authorizer, with automatic refresh.
  //
  fetcher = [self fetcherWithURLString:authedURLString];
  fetcher.authorizer = [TestAuthorizer expiredSyncAuthorizer];
  fetcher.retryBlock = ^(BOOL suggestedWillRetry, NSError *error,
                         GTMSessionFetcherRetryResponse response) {
      XCTAssertEqual([error code], (NSInteger)401, @"%@", error);
      response(YES);
  };

  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
      NSString *authHdr = [[fetcher.mutableRequest allHTTPHeaderFields] objectForKey:@"Authorization"];
      XCTAssertEqualObjects(authHdr, kGoodBearerValue);
      XCTAssertEqualObjects(data, [self gettysburgAddress]);
      XCTAssertNil(error);
  }];
  XCTAssertTrue([fetcher waitForCompletionWithTimeout:_timeoutInterval], @"timed out");
  [self assertCallbacksReleasedForFetcher:fetcher];

  //
  // Fetch with an expired async authorizer, with automatic refresh.
  //
  fetcher = [self fetcherWithURLString:authedURLString];
  fetcher.authorizer = [TestAuthorizer expiredAsyncAuthorizer];
  fetcher.retryBlock = ^(BOOL suggestedWillRetry, NSError *error,
                         GTMSessionFetcherRetryResponse response) {
    XCTAssertEqual([error code], (NSInteger)401, @"%@", error);
    response(YES);
  };

  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
      NSString *authHdr =
          [[fetcher.mutableRequest allHTTPHeaderFields] objectForKey:@"Authorization"];
      XCTAssertEqualObjects(authHdr, kGoodBearerValue);
      XCTAssertEqualObjects(data, [self gettysburgAddress]);
      XCTAssertNil(error);
  }];
  XCTAssertTrue([fetcher waitForCompletionWithTimeout:_timeoutInterval], @"timed out");
  [self assertCallbacksReleasedForFetcher:fetcher];

  // Check notifications.
  XCTAssertEqual(fnctr.fetchStarted, 8);
  XCTAssertEqual(fnctr.fetchStopped, 8);
  XCTAssertEqual(fnctr.retryDelayStarted, 2);
  XCTAssertEqual(fnctr.retryDelayStopped, 2);
}

- (void)testRedirectFetch {
  if (!_isServerRunning) return;

  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];
  [_testServer setRedirectEnabled:YES];

  //
  // Fetch our test file.  Ensure the body survives the redirection.
  //
  const int kBodyLength = 137;
  NSDictionary *params = @{ @"requestBodyLength" : [@(kBodyLength) stringValue] };
  NSString *localURLString = [self localURLStringToTestFileName:kGTMGettysburgFileName
                                                     parameters:params];

  GTMSessionFetcher *fetcher = [self fetcherWithURLString:localURLString];
  fetcher.bodyData = [GTMSessionFetcherTestServer generatedBodyDataWithLength:kBodyLength];

  __block BOOL didCallBlock = NO;
  fetcher.willRedirectBlock = ^(NSHTTPURLResponse *redirectResponse,
                                NSURLRequest *redirectRequest,
                                GTMSessionFetcherWillRedirectResponse response) {
      XCTAssert(![redirectResponse.URL.host isEqual:redirectRequest.URL.host] ||
                ![redirectResponse.URL.port isEqual:redirectRequest.URL.port]);
      didCallBlock = YES;
      response(redirectRequest);
  };

  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
      [self assertSuccessfulGettysburgFetchWithFetcher:fetcher
                                                  data:data
                                                 error:error];
      // Check that a redirect was performed
      NSURL *requestURL = [NSURL URLWithString:localURLString];
      NSURL *responseURL = [fetcher.response URL];
      XCTAssertTrue(![requestURL.host isEqual:responseURL.host] ||
                    ![requestURL.port isEqual:responseURL.port], @"failed to redirect");

      // Cookies should have been set by the response; specifically, TestCookie
      // should be set to the name of the file requested.
      NSDictionary *responseHeaders = [(NSHTTPURLResponse *)fetcher.response allHeaderFields];
      NSString *cookiesSetString = [responseHeaders objectForKey:@"Set-Cookie"];
      NSString *cookieExpected = [NSString stringWithFormat:@"TestCookie=%@", kGTMGettysburgFileName];
      XCTAssertEqualObjects(cookiesSetString, cookieExpected);

      // A cookie should've been set.
      NSHTTPCookieStorage *cookieStorage = fetcher.configuration.HTTPCookieStorage;
      NSArray *cookies = [cookieStorage cookiesForURL:[NSURL URLWithString:@"http://localhost/"]];
      XCTAssertEqual([cookies count], (NSUInteger)1);
      NSHTTPCookie *firstCookie = [cookies firstObject];
      XCTAssertEqualObjects([firstCookie value], @"gettysburgaddress.txt");
  }];
  XCTAssertTrue([fetcher waitForCompletionWithTimeout:_timeoutInterval], @"timed out");
  XCTAssertTrue(didCallBlock);
  [self assertCallbacksReleasedForFetcher:fetcher];

  // Check the notifications.
  XCTAssertEqual(fnctr.fetchStarted, 1);
  XCTAssertEqual(fnctr.fetchStopped, 1);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
}

- (void)testRetryFetches {
  if (!_isServerRunning) return;

  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  NSString *invalidFileURLString = [self localURLStringToTestFileName:kGTMGettysburgFileName
                                                           parameters:@{ @"status": @"503" }];

  __block GTMSessionFetcher *fetcher;

  // Block for allowing up to N retries, where N is an NSNumber in the fetcher's userData.
  GTMSessionFetcherRetryBlock countRetriesBlock = ^(BOOL suggestedWillRetry, NSError *error,
                                                    GTMSessionFetcherRetryResponse response) {
    int count = (int)[fetcher retryCount];
    int allowedRetryCount = [[fetcher userData] intValue];

    BOOL shouldRetry = (count < allowedRetryCount);

    XCTAssertEqual([fetcher nextRetryInterval], pow(2.0, [fetcher retryCount]),
                   @"Unexpected next retry interval (expected %f, was %f)",
                   pow(2.0, fetcher.retryCount), fetcher.nextRetryInterval);

    NSData *statusData = [[error userInfo] objectForKey:kGTMSessionFetcherStatusDataKey];
    NSString *dataStr = [[NSString alloc] initWithData:statusData
                                              encoding:NSUTF8StringEncoding];
    NSInteger code = [error code];
    if (code == 503) {
      NSString *expectedStr = [[_testServer class] JSONBodyStringForStatus:503];
      XCTAssertEqualObjects(dataStr, expectedStr);
    }
    response(shouldRetry);
  };

  // Block for retrying and changing the request to one that will succeed.
  GTMSessionFetcherRetryBlock fixRequestBlock = ^(BOOL suggestedWillRetry, NSError *error,
                                                  GTMSessionFetcherRetryResponse response) {
      XCTAssertEqual(fetcher.nextRetryInterval, pow(2.0, fetcher.retryCount),
                     @"Unexpected next retry interval (expected %f, was %f)",
                     pow(2.0, fetcher.retryCount), fetcher.nextRetryInterval);

      // Fix it - change the request to a URL which does not have a status value
      NSString *urlString = [self localURLStringToTestFileName:kGTMGettysburgFileName];
      fetcher.mutableRequest.URL = [NSURL URLWithString:urlString];

      response(YES);  // Do the retry fetch; it should succeed now.
  };

  //
  // Test: retry until timeout, then expect failure with status code.
  //
  fetcher = [self fetcherForRetryWithURLString:invalidFileURLString
                                    retryBlock:countRetriesBlock
                              maxRetryInterval:5.0 // retry intervals of 1, 2, 4
                                      userData:@1000];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
      XCTAssertNotNil(data, @"error data is expected");
      XCTAssertEqual(fetcher.statusCode, (NSInteger)503);
      XCTAssertEqual(fetcher.retryCount, (NSUInteger)3);
   }];
  XCTAssertTrue([fetcher waitForCompletionWithTimeout:_timeoutInterval], @"timed out");
  [self assertCallbacksReleasedForFetcher:fetcher];

  //
  // Test: retry with server sleep to force timeout, then expect failure with status 408
  // after first retry
  //
  NSString *timeoutFileURLString = [self localURLStringToTestFileName:kGTMGettysburgFileName
                                                           parameters:@{ @"sleep": @"10" }];

  fetcher = [self fetcherForRetryWithURLString:timeoutFileURLString
                                    retryBlock:countRetriesBlock
                              maxRetryInterval:5.0 // retry interval of 1, then exceed 3*max timout
                                      userData:@1000];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
      XCTAssertNil(data, @"error data unexpected");
      XCTAssertEqual(fetcher.statusCode, (NSInteger)408, @"%@", error);
      XCTAssertEqual(fetcher.retryCount, (NSUInteger)1);
  }];
  XCTAssertTrue([fetcher waitForCompletionWithTimeout:_timeoutInterval], @"timed out");
  [self assertCallbacksReleasedForFetcher:fetcher];

  //
  // Test:  retry twice, then give up.
  //
  fetcher = [self fetcherForRetryWithURLString:invalidFileURLString
                                    retryBlock:countRetriesBlock
                              maxRetryInterval:10.0 // retry intervals of 1, 2, 4, 8
                                      userData:@2];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
      XCTAssertNotNil(data);
      XCTAssertEqual(fetcher.statusCode, (NSInteger)503, @"%@", error);
      XCTAssertEqual(fetcher.retryCount, (NSUInteger)2);
  }];
  XCTAssertTrue([fetcher waitForCompletionWithTimeout:_timeoutInterval], @"timed out");
  [self assertCallbacksReleasedForFetcher:fetcher];

  //
  // Test:  Retry, making the request succeed on the first retry
  //        by fixing the URL
  //
  fetcher = [self fetcherForRetryWithURLString:invalidFileURLString
                                    retryBlock:fixRequestBlock
                              maxRetryInterval:30.0
                                      userData:@1000];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
      XCTAssertNotNil(data);
      XCTAssertEqual(fetcher.statusCode, (NSInteger)200);
      XCTAssertEqual(fetcher.retryCount, (NSUInteger)1);
  }];
  XCTAssertTrue([fetcher waitForCompletionWithTimeout:_timeoutInterval], @"timed out");
  [self assertCallbacksReleasedForFetcher:fetcher];

  // Check the notifications.
  XCTAssertEqual(fnctr.fetchStarted, 11);
  XCTAssertEqual(fnctr.fetchStopped, 11);
  XCTAssertEqual(fnctr.retryDelayStarted, 7);
  XCTAssertEqual(fnctr.retryDelayStopped, 7);
}

- (void)testFetchToFile {
  if (!_isServerRunning) return;

  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  // Make the destination URL for downloading.
  NSURL *destFileURL = [self temporaryFileURLWithBaseName:NSStringFromSelector(_cmd)];

  // Get the original file's contents.
  NSString *origContents = [[NSString alloc] initWithData:[self gettysburgAddress]
                                                 encoding:NSUTF8StringEncoding];
  int64_t origLength = (int64_t)[origContents length];
  XCTAssert(origLength > 0, @"Could not read original file");

  //
  // Test the downloading.
  //
  __block int64_t totalWritten = 0;

  NSString *validURLString = [self localURLStringToTestFileName:kGTMGettysburgFileName];
  GTMSessionFetcher *fetcher = [self fetcherWithURLString:validURLString];
  fetcher.destinationFileURL = destFileURL;
  fetcher.downloadProgressBlock = ^(int64_t bytesWritten,
                                    int64_t totalBytesWritten,
                                    int64_t totalBytesExpectedToWrite) {
    // Verify the parameters are reasonable.
    XCTAssertTrue(bytesWritten > 0 && bytesWritten <= origLength, @"%lld", bytesWritten);
    XCTAssertTrue(totalBytesWritten > 0 && totalBytesWritten <= origLength,
                  @"%lld", totalBytesWritten);
    XCTAssertEqual(totalBytesExpectedToWrite, origLength);

    // Total bytes written should increase monotonically.
    XCTAssertTrue(totalBytesWritten > totalWritten,
                  @"%lld !> %lld", totalBytesWritten, totalWritten);
    totalWritten = totalBytesWritten;
  };

  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
      XCTAssertNil(data);
      XCTAssertNil(error);

      NSString *fetchedContents = [NSString stringWithContentsOfURL:destFileURL
                                                           encoding:NSUTF8StringEncoding
                                                              error:NULL];
      XCTAssertEqualObjects(fetchedContents, origContents);
      XCTAssertEqual(totalWritten, origLength, @"downloadProgressBlock not called");
  }];
  XCTAssertTrue([fetcher waitForCompletionWithTimeout:_timeoutInterval], @"timed out");
  [self assertCallbacksReleasedForFetcher:fetcher];

  [self removeTemporaryFileURL:destFileURL];

  // Check the notifications.
  XCTAssertEqual(fnctr.fetchStarted, 1);
  XCTAssertEqual(fnctr.fetchStopped, 1);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
}

- (void)testFetchDataToFile {
  if (!_isServerRunning) return;

  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  // Make the destination URL for downloading.
  NSURL *destFileURL = [self temporaryFileURLWithBaseName:NSStringFromSelector(_cmd)];

  // Get the original file's contents.
  NSString *origContents = [[NSString alloc] initWithData:[self gettysburgAddress]
                                                 encoding:NSUTF8StringEncoding];
  NSString *escapedContents =
      [origContents stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
  NSString *validDataURLString = [NSString stringWithFormat:@"data:,%@", escapedContents];
  GTMSessionFetcher *fetcher = [self fetcherWithURLString:validDataURLString];
  fetcher.destinationFileURL = destFileURL;
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
      XCTAssertNil(data);
      XCTAssertNil(error);

      NSString *fetchedContents = [NSString stringWithContentsOfURL:destFileURL
                                                           encoding:NSUTF8StringEncoding
                                                              error:NULL];
      XCTAssertEqualObjects(fetchedContents, origContents);
  }];
  XCTAssertTrue([fetcher waitForCompletionWithTimeout:_timeoutInterval], @"timed out");
  [self assertCallbacksReleasedForFetcher:fetcher];

  [self removeTemporaryFileURL:destFileURL];

  // Check the notifications.
  XCTAssertEqual(fnctr.fetchStarted, 1);
  XCTAssertEqual(fnctr.fetchStopped, 1);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
}

- (void)testUnsuccessfulFetchToFile {
  if (!_isServerRunning) return;

  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  __block int64_t totalWritten = 0;
  NSString *invalidURLString = [self localURLStringToTestFileName:kGTMGettysburgFileName
                                                       parameters:@{ @"status": @"400" }];
  NSString *statusStr = [[_testServer class] JSONBodyStringForStatus:400];
  NSURL *destFileURL = [self temporaryFileURLWithBaseName:NSStringFromSelector(_cmd)];

  GTMSessionFetcher *fetcher = [self fetcherWithURLString:invalidURLString];
  fetcher.destinationFileURL = destFileURL;
  fetcher.downloadProgressBlock = ^(int64_t bytesWritten,
                                    int64_t totalBytesWritten,
                                    int64_t totalBytesExpectedToWrite) {
      // Verify the parameters are reasonable.
      XCTAssertTrue(totalBytesWritten > 0 && totalBytesWritten <= (int64_t)[statusStr length],
                    @"%lld", totalBytesWritten);

      // Total bytes written should increase monotonically.
      XCTAssertTrue(totalBytesWritten > totalWritten,
                    @"%lld !> %lld", totalBytesWritten, totalWritten);
      totalWritten = totalBytesWritten;
  };

  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
      XCTAssertNil(data);

      // Download tasks seem to return an NSURLErrorDomain error rather than the
      // server status, unless I run only this unit test method, in which case it returns
      // the server status.  TODO: Figure out why the inconsistency.
      BOOL isExpectedCode = ([error code] == NSURLErrorFileDoesNotExist || [error code] == 400);
      XCTAssertTrue(isExpectedCode, @"%@", error);

      // The file should not be copied to the destination URL on status 400 and higher.
      BOOL fileExists = [destFileURL checkResourceIsReachableAndReturnError:NULL];
      XCTAssertFalse(fileExists, @"%@", [destFileURL path]);

      if ([error code] == 400) {
        // Check the body JSON of the status code response.
        XCTAssertEqual(totalWritten, (int64_t)[statusStr length],
                       @"downloadProgressBlock not called");
      } else {
        // If the error was NSURLErrorFileDoesNotExist sometimes downloadProgressBlock was
        // called so totalWritten > 0, sometimes not.
      }
  }];

  XCTAssertTrue([fetcher waitForCompletionWithTimeout:_timeoutInterval], @"timed out");
  [self assertCallbacksReleasedForFetcher:fetcher];

  // There should be no file to delete.
  XCTAssertFalse([destFileURL checkResourceIsReachableAndReturnError:NULL]);

  // Check the notifications.
  XCTAssertEqual(fnctr.fetchStarted, 1);
  XCTAssertEqual(fnctr.fetchStopped, 1);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
}

- (void)testQuickBeginStopFetching {
  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  // This test exercises the workaround for Radar 18471901. See comments in GTMSessionFetcher.m
  int const kFetcherCreationCount = 1000;
  for (int i = 0; i < kFetcherCreationCount; ++i) {
    GTMSessionFetcher *fetcher = [GTMSessionFetcher fetcherWithURLString:@"http://example.com/tst"];
    fetcher.useBackgroundSession = NO;
    fetcher.allowedInsecureSchemes = @[ @"http" ];
    [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
      XCTAssertTrue(NO, @"Download not canceled");
    }];
    [fetcher stopFetching];
    XCTAssertTrue([fetcher waitForCompletionWithTimeout:_timeoutInterval], @"timed out");
  }
  XCTAssertEqual(fnctr.fetchStarted, kFetcherCreationCount);
  XCTAssertEqual(fnctr.fetchStopped, kFetcherCreationCount);
}

- (void)testCancelAndResumeFetchToFile {
  if (!_isServerRunning) return;

  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  NSURL *destFileURL = [self temporaryFileURLWithBaseName:NSStringFromSelector(_cmd)];

  const int64_t kExpectedResponseLen = 5 * 1024*1024;
  NSData *expectedResponseData =
      [GTMSessionFetcherTestServer generatedBodyDataWithLength:kExpectedResponseLen];

  //
  // Test the downloading.
  //
  __block int64_t totalWritten = 0;

  NSString *validURLString =
      [self localURLStringToTestFileName:kGTMGettysburgFileName
                              parameters:@{ @"responseBodyLength" : [@(kExpectedResponseLen) stringValue] }];
  GTMSessionFetcher *fetcher = [self fetcherWithURLString:validURLString];
  fetcher.destinationFileURL = destFileURL;
  GTMSessionFetcher* __weak weakFetcher = fetcher;
  fetcher.downloadProgressBlock = ^(int64_t bytesWritten,
                                  int64_t totalBytesWritten,
                                  int64_t totalBytesExpectedToWrite) {
    // Verify the parameters are reasonable.
    XCTAssertTrue(bytesWritten > 0 && bytesWritten <= kExpectedResponseLen, @"%lld", bytesWritten);
    XCTAssertTrue(totalBytesWritten > 0 && totalBytesWritten <= kExpectedResponseLen,
                  @"%lld", totalBytesWritten);
    XCTAssertEqual(totalBytesExpectedToWrite, kExpectedResponseLen);

    // Total bytes written should increase monotonically.
    XCTAssertTrue(totalBytesWritten > totalWritten,
                  @"%lld !> %lld", totalBytesWritten, totalWritten);
    dispatch_async(dispatch_get_main_queue(), ^{
      [weakFetcher stopFetching];
    });
    totalWritten = totalBytesWritten;
  };
  NSData __block *resumeData = nil;
  fetcher.resumeDataBlock = ^(NSData *data){
    resumeData = data;
  };

  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertTrue(NO, @"initial download not canceled");
  }];

  XCTAssertTrue([fetcher waitForCompletionWithTimeout:_timeoutInterval], @"timed out");
  [self assertCallbacksReleasedForFetcher:fetcher];

  XCTAssertNotNil(resumeData, @"resumeData not returned");
  fetcher = [GTMSessionFetcher fetcherWithDownloadResumeData:resumeData];
  fetcher.destinationFileURL = destFileURL;
  fetcher.downloadProgressBlock = ^(int64_t bytesWritten,
                                  int64_t totalBytesWritten,
                                  int64_t totalBytesExpectedToWrite) {
    // Verify the parameters are reasonable.
    XCTAssertTrue(bytesWritten > 0 && bytesWritten <= kExpectedResponseLen, @"%lld", bytesWritten);
    XCTAssertTrue(totalBytesWritten > 0 && totalBytesWritten <= kExpectedResponseLen,
                  @"%lld", totalBytesWritten);
    XCTAssertEqual(totalBytesExpectedToWrite, kExpectedResponseLen);

    // Total bytes written should increase monotonically.
    XCTAssertTrue(totalBytesWritten > totalWritten,
                  @"%lld !> %lld", totalBytesWritten, totalWritten);
    totalWritten = totalBytesWritten;
  };
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertEqual([data length], (NSUInteger)0);
    XCTAssertNil(error);

    NSData *written = [NSData dataWithContentsOfURL:destFileURL];
    XCTAssertEqual((int64_t)[written length], kExpectedResponseLen,
                   @"Incorrect file size downloaded");
    XCTAssertTrue([written isEqual:expectedResponseData], @"downloaded data not expected");
    XCTAssertEqual(totalWritten, kExpectedResponseLen, @"downloadProgressBlock not called");
  }];
  XCTAssertTrue([fetcher waitForCompletionWithTimeout:_timeoutInterval], @"timed out");
  [self assertCallbacksReleasedForFetcher:fetcher];

  [self removeTemporaryFileURL:destFileURL];

  // Check the notifications.
  XCTAssertEqual(fnctr.fetchStarted, 2);
  XCTAssertEqual(fnctr.fetchStopped, 2);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
}

- (void)testInsecureRequests {
  if (![GTMSessionFetcher appAllowsInsecureRequests]) return;

  // file:///Users/.../Resources/gettysburgaddress.txt
  NSString *fileURLString =
      [[NSURL fileURLWithPath:[_testServer localPathForFile:kGTMGettysburgFileName]] absoluteString];

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
    { @"http://example.com/",  0,                    kInsecureError },
    { @"https://example.com/", 0,                    0 },
    { @"http://example.com/",  kAllowHTTPSchemeFlag, 0 },
    { @"https://example.com/", kAllowHTTPSchemeFlag, 0 },
    { localhostURLString,      0,                    kInsecureError },
    { localhostURLString,      kAllowLocalhostFlag,  0 },
    { fileURLString,           0,                    kInsecureError },
    { fileURLString,           kAllowHTTPSchemeFlag, kInsecureError },
    { fileURLString,           kAllowFileSchemeFlag, 0 },  // file URL allowed by scheme
    { fileURLString,           kAllowLocalhostFlag,  0 },  // file URL allowed as localhost
    { NULL, 0, 0 },
  };

  for (int i = 0; records[i].urlString; i++) {
    NSString *urlString = records[i].urlString;
    GTMSessionFetcher *fetcher = [GTMSessionFetcher fetcherWithURLString:urlString];
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
    [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
      if (expectedErrorCode == 0) {
        XCTAssertNil(error, @"index %i -- %@", i, urlString);
      } else {
        XCTAssertEqual(error.code, expectedErrorCode, @"index %i -- %@ -- %@", i, urlString, error);
      }
    }];
    XCTAssertTrue([fetcher waitForCompletionWithTimeout:_timeoutInterval], @"timed out");
  }
}

#pragma mark - TestBlock Tests

- (void)testFetcherTestBlock {
  // No test server needed.
  _testServer = nil;
  _isServerRunning = NO;

  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  //
  // Use the test block to fake fetching our test file.
  //
  NSString *testURLString = @"http://test.example.com/foo";

  GTMSessionFetcher *fetcher = [self fetcherWithURLString:testURLString];

  NSData *fakedResultData = [@"Snuffle." dataUsingEncoding:NSUTF8StringEncoding];
  NSHTTPURLResponse *fakedResultResponse =
      [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:testURLString]
                                  statusCode:200
                                 HTTPVersion:@"HTTP/1.1"
                                headerFields:@{ @"Bichon" : @"Frise" }];
  NSError *fakedResultError = nil;

  fetcher.testBlock = ^(GTMSessionFetcher *fetcherToTest,
                        GTMSessionFetcherTestResponse testResponse) {
      XCTAssertEqualObjects(fetcherToTest.mutableRequest.URL.absoluteString, testURLString);
      testResponse(fakedResultResponse, fakedResultData, fakedResultError);
  };

  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
      XCTAssertNil(fakedResultError);
      XCTAssertEqualObjects(data, fakedResultData);
      XCTAssertEqual(fetcher.statusCode, fakedResultResponse.statusCode);
      XCTAssertEqualObjects(fetcher.responseHeaders[@"Bichon"], @"Frise");
  }];
  XCTAssertTrue([fetcher waitForCompletionWithTimeout:_timeoutInterval], @"timed out");
  [self assertCallbacksReleasedForFetcher:fetcher];

  XCTAssertEqual(fnctr.fetchStarted, 1);
  XCTAssertEqual(fnctr.fetchStopped, 1);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
}

- (void)testFetcherTestBlockFailsWithRetries {
  // No test server needed.
  _testServer = nil;
  _isServerRunning = NO;

  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];
  //
  // Fake fetching our test file, failing with an error, including retries.
  //
  NSString *testURLString = @"http://test.example.com/foo";

  GTMSessionFetcher *fetcher = [self fetcherWithURLString:testURLString];
  fetcher.retryEnabled = YES;
  fetcher.minRetryInterval = 1;
  fetcher.maxRetryInterval = 5;

  NSData *fakedResultData = nil;
  NSHTTPURLResponse *fakedResultResponse =
      [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:testURLString]
                                  statusCode:504  // 504 is a retryable error.
                                 HTTPVersion:@"HTTP/1.1"
                                headerFields:@{ @"Alaskan" : @"Malamute" }];
  NSError *fakedResultError =
      [NSError errorWithDomain:kGTMSessionFetcherErrorDomain
                          code:504
                      userInfo:@{ kGTMSessionFetcherStatusDataKey : @"Oops." }];

  fetcher.testBlock = ^(GTMSessionFetcher *fetcherToTest,
                        GTMSessionFetcherTestResponse testResponse) {
      XCTAssertEqualObjects(fetcherToTest.mutableRequest.URL.absoluteString, testURLString);
      testResponse(fakedResultResponse, fakedResultData, fakedResultError);
  };

  __block int numberOfRetryBlockInvokes = 0;
  fetcher.retryBlock = ^(BOOL suggestedWillRetry, NSError *error,
                         GTMSessionFetcherRetryResponse response) {
      ++numberOfRetryBlockInvokes;  // Retries after 1, 2, 4 seconds.
      response(YES);
  };

  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
      XCTAssertEqualObjects(error, fakedResultError);
      XCTAssertNil(data);
      XCTAssertEqual(fetcher.statusCode, fakedResultResponse.statusCode);
      XCTAssertEqualObjects(fetcher.responseHeaders[@"Alaskan"], @"Malamute");
  }];
  XCTAssertTrue([fetcher waitForCompletionWithTimeout:_timeoutInterval], @"timed out");
  XCTAssertEqual(numberOfRetryBlockInvokes, 3);
  [self assertCallbacksReleasedForFetcher:fetcher];

  XCTAssertEqual(fnctr.fetchStarted, 3);
  XCTAssertEqual(fnctr.fetchStopped, 3);
  XCTAssertEqual(fnctr.retryDelayStarted, 3);
  XCTAssertEqual(fnctr.retryDelayStopped, 3);
}

- (void)testFetcherTestBlockSimulateDataCallbacks {
  // No test server needed.
  _testServer = nil;
  _isServerRunning = NO;

  //
  // Test callbacks for data upload and download.
  //
  NSString *testURLString = @"http://test.example.com/foo";

  NSData *uploadData = [GTMSessionFetcherTestServer generatedBodyDataWithLength:33];
  NSData *downloadData = [GTMSessionFetcherTestServer generatedBodyDataWithLength:333];

  GTMSessionFetcher *fetcher = [self fetcherWithURLString:testURLString];

  fetcher.bodyData = uploadData;
  NSHTTPURLResponse *fakedResultResponse =
      [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:testURLString]
                                  statusCode:200
                                 HTTPVersion:@"HTTP/1.1"
                                headerFields:@{ @"Aussie" : @"Shepherd" }];
  NSError *fakedResultError = nil;

  __block NSURLResponse *initialResponse;
  fetcher.didReceiveResponseBlock = ^(NSURLResponse *response,
                                      GTMSessionFetcherDidReceiveResponseDispositionBlock dispositionBlock) {
      XCTAssertNil(initialResponse);
      initialResponse = response;
      dispositionBlock(NSURLSessionResponseAllow);
  };

  __block int64_t bytesSentSum = 0;
  __block int64_t lastTotalBytesSent = 0;
  int64_t expectedTotalBytesWritten = (int64_t)[uploadData length];

  fetcher.sendProgressBlock = ^(int64_t bytesSent,
                                int64_t totalBytesSent,
                                int64_t totalBytesExpectedToSend) {
      bytesSentSum += bytesSent;
      lastTotalBytesSent = totalBytesSent;
      XCTAssertEqual(totalBytesExpectedToSend, expectedTotalBytesWritten);
  };

  __block int64_t bytesReceivedSum = 0;
  __block int64_t lastTotalBytesReceived = 0;
  int64_t expectedTotalBytesReceived = (int64_t)[downloadData length];

  fetcher.receivedProgressBlock = ^(int64_t bytesReceived,
                                    int64_t totalBytesReceived) {
      bytesReceivedSum += bytesReceived;
      lastTotalBytesReceived = totalBytesReceived;
  };

  __block NSCachedURLResponse *proposedResponseToCache;
  fetcher.willCacheURLResponseBlock = ^(NSCachedURLResponse *responseProposed,
                                        GTMSessionFetcherWillCacheURLResponseResponse response) {
      proposedResponseToCache = responseProposed;
      response(responseProposed);
  };

  fetcher.testBlock = ^(GTMSessionFetcher *fetcherToTest,
                        GTMSessionFetcherTestResponse testResponse) {
      testResponse(fakedResultResponse, downloadData, fakedResultError);
  };

  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
      XCTAssertNil(error);
      XCTAssertEqualObjects(data, downloadData);

      XCTAssertEqual(bytesSentSum, expectedTotalBytesWritten);
      XCTAssertEqual(lastTotalBytesSent, expectedTotalBytesWritten);

      XCTAssertEqual(bytesReceivedSum, expectedTotalBytesReceived);
      XCTAssertEqual(lastTotalBytesReceived, expectedTotalBytesReceived);

      XCTAssertEqualObjects(initialResponse, fetcher.response);

      XCTAssertEqualObjects(proposedResponseToCache.response, fetcher.response);
  }];

  XCTAssertTrue([fetcher waitForCompletionWithTimeout:_timeoutInterval], @"timed out");
  [self assertCallbacksReleasedForFetcher:fetcher];

  //
  // Now test file upload and download.
  //
  fetcher = [self fetcherWithURLString:testURLString];

  NSURL *uploadFileURL = [self temporaryFileURLWithBaseName:@"TestBlockUpload"];
  NSURL *downloadFileURL = [self temporaryFileURLWithBaseName:@"TestBlockDownload"];
  XCTAssertTrue([uploadData writeToURL:uploadFileURL atomically:YES]);
  XCTAssertTrue([downloadData writeToURL:downloadFileURL atomically:YES]);

  fetcher.bodyFileURL = uploadFileURL;
  fetcher.destinationFileURL = downloadFileURL;

  bytesSentSum = 0;
  lastTotalBytesSent = 0;
  expectedTotalBytesWritten = (int64_t)[uploadData length];

  fetcher.sendProgressBlock = ^(int64_t bytesWritten,
                                int64_t totalBytesWritten,
                                int64_t totalBytesExpectedToWrite) {
    bytesSentSum += bytesWritten;
    lastTotalBytesSent = totalBytesWritten;
    XCTAssertEqual(totalBytesExpectedToWrite, expectedTotalBytesWritten);
  };

  bytesReceivedSum = 0;
  lastTotalBytesReceived = 0;
  expectedTotalBytesReceived = (int64_t)[downloadData length];

  fetcher.downloadProgressBlock = ^(int64_t bytesDownloaded,
                                    int64_t totalBytesDownloaded,
                                    int64_t totalBytesExpectedToDownload) {
    bytesReceivedSum += bytesDownloaded;
    lastTotalBytesReceived = totalBytesDownloaded;
    XCTAssertEqual(totalBytesExpectedToDownload, expectedTotalBytesReceived);
  };

  fakedResultError = nil;
  fetcher.testBlock = ^(GTMSessionFetcher *fetcherToTest,
                        GTMSessionFetcherTestResponse testResponse) {
      testResponse(fakedResultResponse, downloadData, fakedResultError);
  };

  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
      XCTAssertNil(error);
      XCTAssertNil(data);

      NSData *dataFromFile = [NSData dataWithContentsOfURL:downloadFileURL];
      XCTAssertEqualObjects(dataFromFile, downloadData);

      XCTAssertEqual(bytesSentSum, expectedTotalBytesWritten);
      XCTAssertEqual(lastTotalBytesSent, expectedTotalBytesWritten);

      XCTAssertEqual(bytesReceivedSum, expectedTotalBytesReceived);
      XCTAssertEqual(lastTotalBytesReceived, expectedTotalBytesReceived);
  }];

  XCTAssertTrue([fetcher waitForCompletionWithTimeout:_timeoutInterval], @"timed out");
  [self assertCallbacksReleasedForFetcher:fetcher];

  [self removeTemporaryFileURL:uploadFileURL];
  [self removeTemporaryFileURL:downloadFileURL];

  //
  // Now test stream upload, and the data accumulation callback.
  //
  fetcher = [self fetcherWithURLString:testURLString];

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
  expectedTotalBytesWritten = (int64_t)[uploadData length];

  fetcher.sendProgressBlock = ^(int64_t bytesWritten,
                                int64_t totalBytesWritten,
                                int64_t totalBytesExpectedToWrite) {
    bytesSentSum += bytesWritten;
    lastTotalBytesSent = totalBytesWritten;
    XCTAssertEqual(totalBytesExpectedToWrite, expectedTotalBytesWritten);
  };

  fakedResultError = nil;
  fetcher.testBlock = ^(GTMSessionFetcher *fetcherToTest,
                        GTMSessionFetcherTestResponse testResponse) {
      testResponse(fakedResultResponse, downloadData, fakedResultError);
  };

  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
      XCTAssertNil(error);
      XCTAssertNil(data);
      XCTAssertEqualObjects(accumulatedData, downloadData);

      XCTAssertEqual(bytesSentSum, expectedTotalBytesWritten);
      XCTAssertEqual(lastTotalBytesSent, expectedTotalBytesWritten);

      XCTAssertEqual(bytesReceivedSum, expectedTotalBytesReceived);
      XCTAssertEqual(lastTotalBytesReceived, expectedTotalBytesReceived);
  }];

  XCTAssertTrue([fetcher waitForCompletionWithTimeout:_timeoutInterval], @"timed out");
  [self assertCallbacksReleasedForFetcher:fetcher];
}

- (void)testFetcherGlobalTestBlock {
  if (!_isServerRunning) return;

  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  //
  // Use the test block to fake fetching our test file.
  //
  NSString *testURLString = @"http://test.example.com/foo";

  GTMSessionFetcher *fetcher = [self fetcherWithURLString:testURLString];

  NSData *fakedResultData = [@"Snuffle." dataUsingEncoding:NSUTF8StringEncoding];
  NSHTTPURLResponse *fakedResultResponse =
      [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:testURLString]
                                  statusCode:200
                                 HTTPVersion:@"HTTP/1.1"
                                headerFields:@{ @"Bichon" : @"Frise" }];
  NSError *fakedResultError = nil;

  [GTMSessionFetcher setGlobalTestBlock:^(GTMSessionFetcher *fetcherToTest,
                                          GTMSessionFetcherTestResponse testResponse) {
      if ([fetcherToTest.mutableRequest.URL.host isEqual:@"test.example.com"]) {
        testResponse(fakedResultResponse, fakedResultData, fakedResultError);
      } else {
        // Actually do the fetch against the test server.
        testResponse(nil, nil, nil);
      }
  }];

  //
  // First fetch should be handled by the test block.
  //
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
      XCTAssertNil(fakedResultError);
      XCTAssertEqualObjects(data, fakedResultData);
      XCTAssertEqual(fetcher.statusCode, fakedResultResponse.statusCode);
      XCTAssertEqualObjects(fetcher.responseHeaders[@"Bichon"], @"Frise");
  }];
  XCTAssertTrue([fetcher waitForCompletionWithTimeout:_timeoutInterval], @"timed out");
  [self assertCallbacksReleasedForFetcher:fetcher];

  //
  // Second fetch should reach the http server.
  //
  NSString *localURLString = [self localURLStringToTestFileName:kGTMGettysburgFileName];

  fetcher = [self fetcherWithURLString:localURLString];
  fetcher.allowLocalhostRequest = YES;

  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
      [self assertSuccessfulGettysburgFetchWithFetcher:fetcher
                                                  data:data
                                                 error:error];
  }];
  XCTAssertTrue([fetcher waitForCompletionWithTimeout:_timeoutInterval], @"timed out");
  [self assertCallbacksReleasedForFetcher:fetcher];

  XCTAssertEqual(fnctr.fetchStarted, 2);
  XCTAssertEqual(fnctr.fetchStopped, 2);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);

  [GTMSessionFetcher setGlobalTestBlock:nil];
}

#pragma mark - Utilities

// Utility method for making a fetcher to test.
- (GTMSessionFetcher *)fetcherWithURLString:(NSString *)urlString {
  NSURLRequest *request = [self requestWithURLString:urlString];
  GTMSessionFetcher *fetcher = [GTMSessionFetcher fetcherWithRequest:request];
  XCTAssertNotNil(fetcher);
  fetcher.allowLocalhostRequest = YES;
  fetcher.allowedInsecureSchemes = @[ @"http" ];
  return fetcher;
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

@end

@implementation TestAuthorizer

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
  NSString *value = self.expired ? kExpiredBearerValue : kGoodBearerValue;
  [request setValue:value forHTTPHeaderField:@"Authorization"];
  NSError *error = nil;

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
  NSString *value = [[request allHTTPHeaderFields] objectForKey:@"Authorization"];
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

@implementation FetcherNotificationsCounter

- (instancetype)init {
  self = [super init];
  if (self) {
    _uploadChunkRequestPaths = [[NSMutableArray alloc] init];
    _uploadChunkCommands = [[NSMutableArray alloc] init];
    _uploadChunkOffsets = [[NSMutableArray alloc] init];
    _uploadChunkLengths = [[NSMutableArray alloc] init];

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
  }
  return self;
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)fetchStateChanged:(NSNotification *)note {
  GTMSessionFetcher *fetcher = [note object];
  BOOL isUploadChunkFetcher = ([fetcher parentUploadFetcher] != nil);
  BOOL isFetchStartedNotification = [[note name] isEqual:kGTMSessionFetcherStartedNotification];

  if (isFetchStartedNotification) {
    ++_fetchStarted;

    if (isUploadChunkFetcher) {
      ++_uploadChunkFetchStarted;

      NSURLRequest *request = fetcher.mutableRequest;
      NSString *command = [request valueForHTTPHeaderField:@"X-Goog-Upload-Command"];
      NSInteger offset = [[request valueForHTTPHeaderField:@"X-Goog-Upload-Offset"] integerValue];
      NSInteger length = [[request valueForHTTPHeaderField:@"Content-Length"] integerValue];
      [_uploadChunkRequestPaths addObject:request.URL.path];
      [_uploadChunkCommands addObject:command];
      [_uploadChunkOffsets addObject:@(offset)];
      [_uploadChunkLengths addObject:@(length)];
    }
  } else {
    ++_fetchStopped;

    if (isUploadChunkFetcher) {
      ++_uploadChunkFetchStopped;
    }
  }

  NSAssert(_fetchStopped <= _fetchStarted, @"fetch notification imbalance: starts=%d stops=%d",
           (int)_fetchStarted, (int)_fetchStopped);
}

- (void)retryDelayStateChanged:(NSNotification *)note {
  if ([[note name] isEqual:kGTMSessionFetcherRetryDelayStartedNotification]) {
    ++_retryDelayStarted;
  } else {
    ++_retryDelayStopped;
  }
  NSAssert(_retryDelayStopped <= _retryDelayStarted,
           @"retry delay notification imbalance: starts=%d stops=%d",
           (int)_retryDelayStarted, (int)_retryDelayStopped);
}

- (void)uploadLocationObtained:(NSNotification *)note {
  GTMSessionUploadFetcher *fetcher = [note object];
  NSAssert(fetcher.uploadLocationURL != nil, @"missing upload location: %@", fetcher);

  ++_uploadLocationObtained;
}

@end

static bool IsCurrentProcessBeingDebugged(void) {
  int result = 0;

  pid_t pid = getpid();
  int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
  int mibSize = sizeof(mib) / sizeof(int);
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
