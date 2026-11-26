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

#import "FetcherNotificationsCounter.h"
#import "GTMSessionFetcherFetchingTest.h"

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
                    timeout:10.0];

@interface GTMSessionUploadFetcher (Private)
@property(atomic, readonly) NSTimer *uploadRetryTimer;
@end

@interface GTMSessionFetcherChunkedUploadTest : GTMSessionFetcherBaseTest
@end

@implementation GTMSessionFetcherChunkedUploadTest {
  GTMSessionFetcherService *_service;
}

- (void)setUp {
  _service = [[GTMSessionFetcherService alloc] init];
  _service.reuseSession = YES;

  // These tests were originally written with the delegate queue as the main queue; changing
  // the default off the main queue seems to have caused several flaking issues with the tests,
  // not due to incorrect behavior from the fetcher but due to the tests not expecting the
  // multi-threaded behavior in their assertions.
  //
  // Changing the session delegate queue back to the main queue to let the tests run correctly
  // until the can get sorted out.
  _service.sessionDelegateQueue = [NSOperationQueue mainQueue];

  [super setUp];
}

- (void)tearDown {
  _service = nil;

  [super tearDown];
}

#pragma mark - Chunked Upload Fetch Tests

- (void)testChunkedUploadTestBlock {
  // No test server needed.
  _testServer = nil;
  _isServerRunning = NO;

  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(2, 2);

  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  NSData *smallData = [GTMSessionFetcherTestServer generatedBodyDataWithLength:13];
  NSURL *testURL = [NSURL URLWithString:@"http://test.example.com/foo"];
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:testURL];
  request.allowsCellularAccess = NO;

  GTMSessionUploadFetcher *fetcher = [GTMSessionUploadFetcher uploadFetcherWithRequest:request
                                                                        uploadMIMEType:@"text/plain"
                                                                             chunkSize:75000
                                                                        fetcherService:_service];
  XCTAssertFalse(fetcher.allowsCellularAccess);
  fetcher.uploadData = smallData;

  NSData *fakedResultData = [@"Snuffle." dataUsingEncoding:NSUTF8StringEncoding];
  NSHTTPURLResponse *fakedResultResponse =
      [[NSHTTPURLResponse alloc] initWithURL:testURL
                                  statusCode:200
                                 HTTPVersion:@"HTTP/1.1"
                                headerFields:@{@"Bichon" : @"Frise"}];
  NSError *fakedResultError = nil;

  fetcher.testBlock =
      ^(GTMSessionFetcher *fetcherToTest, GTMSessionFetcherTestResponse testResponse) {
        testResponse(fakedResultResponse, fakedResultData, fakedResultError);
      };

  fetcher.useBackgroundSession = NO;
  fetcher.allowedInsecureSchemes = @[ @"http" ];

  XCTestExpectation *expectation =
      [self expectationWithDescription:@"NSData upload test completion"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertEqualObjects(data, fakedResultData);
    XCTAssertNil(error);
    XCTAssertEqual(fetcher.statusCode, (NSInteger)200);
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  //
  // Repeat the test with an upload data provider block rather than an NSData.
  //
  NSData *bigUploadData = [GTMSessionFetcherTestServer generatedBodyDataWithLength:333];
  __block NSRange uploadedRange = NSMakeRange(0, 0);
  NSRange expectedRange = NSMakeRange(0, bigUploadData.length);

  // Try a cellular allowed request.
  request.allowsCellularAccess = YES;
  fetcher = [GTMSessionUploadFetcher uploadFetcherWithRequest:request
                                               uploadMIMEType:@"text/plain"
                                                    chunkSize:75000
                                               fetcherService:_service];
  XCTAssertTrue(fetcher.allowsCellularAccess);
  fetcher.uploadData = nil;
  [fetcher setUploadDataLength:(int64_t)expectedRange.length
                      provider:^(int64_t offset, int64_t length,
                                 GTMSessionUploadFetcherDataProviderResponse response) {
                        NSRange providingRange =
                            NSMakeRange((NSUInteger)offset, (NSUInteger)length);
                        uploadedRange = NSUnionRange(uploadedRange, providingRange);
                        NSData *subdata = [bigUploadData subdataWithRange:providingRange];
                        response(subdata, kGTMSessionUploadFetcherUnknownFileSize, nil);
                      }];

  fakedResultError = nil;

  fetcher.testBlock =
      ^(GTMSessionFetcher *fetcherToTest, GTMSessionFetcherTestResponse testResponse) {
        testResponse(fakedResultResponse, fakedResultData, fakedResultError);
      };

  fetcher.useBackgroundSession = NO;
  fetcher.allowedInsecureSchemes = @[ @"http" ];

  expectation = [self expectationWithDescription:@"upload data provider completion"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertEqualObjects(data, fakedResultData);
    XCTAssertNil(error);
    XCTAssertEqual(fetcher.statusCode, (NSInteger)200);
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  XCTAssertTrue(NSEqualRanges(uploadedRange, expectedRange), @"Uploaded %@ (expected %@)",
                NSStringFromRange(uploadedRange), NSStringFromRange(expectedRange));
  [self assertCallbacksReleasedForFetcher:fetcher];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  XCTAssertEqual(fnctr.fetchStarted, 2);
  XCTAssertEqual(fnctr.fetchStopped, 2);
  XCTAssertEqual(fnctr.uploadChunkFetchStarted, 0);
  XCTAssertEqual(fnctr.uploadChunkFetchStopped, 0);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
}

static const NSUInteger kBigUploadDataLength = 199000;

- (NSData *)bigUploadData {
  return [GTMSessionFetcherTestServer generatedBodyDataWithLength:kBigUploadDataLength];
}

- (NSMutableURLRequest *)validUploadFileRequestWithFileName:(NSString *)fileName {
  NSString *validURLString = [self localURLStringToTestFileName:fileName];
  validURLString = [validURLString stringByAppendingString:@".location"];
  NSMutableURLRequest *request = [self requestWithURLString:validURLString];
  [request setValue:@"UploadTest" forHTTPHeaderField:@"User-Agent"];
  return request;
}

- (NSMutableURLRequest *)validUploadFileRequest {
  return [self validUploadFileRequestWithFileName:kGTMGettysburgFileName];
}

- (NSMutableURLRequest *)validUploadFileRequestWithParameters:(NSDictionary *)params {
  NSString *validURLString = [self localURLStringToTestFileName:kGTMGettysburgFileName];
  validURLString = [validURLString stringByAppendingString:@".location"];
  // Add any parameters from the dictionary.
  if (params.count) {
    NSMutableArray *array = [NSMutableArray array];
    for (NSString *key in params) {
      [array addObject:[NSString stringWithFormat:@"%@=%@", key,
                                                  [[params objectForKey:key] description]]];
    }
    NSString *paramsStr = [array componentsJoinedByString:@"&"];
    validURLString = [validURLString stringByAppendingFormat:@"?%@", paramsStr];
  }
  NSMutableURLRequest *request = [self requestWithURLString:validURLString];
  [request setValue:@"UploadTest" forHTTPHeaderField:@"User-Agent"];
  return request;
}

// We use the sendBytes callback to pause and restart an upload,
// and to change the upload location URL to cause a chunk upload
// failure and retry.

static NSString *const kPauseAtKey = @"pauseAt";
static NSString *const kCancelAtKey = @"cancelAt";
static NSString *const kRetryAtKey = @"retryAt";
static NSString *const kOriginalURLKey = @"originalURL";

static void TestProgressBlock(GTMSessionUploadFetcher *fetcher, int64_t bytesSent,
                              int64_t totalBytesSent, int64_t totalBytesExpectedToSend) {
  NSNumber *pauseAtNum = [fetcher propertyForKey:kPauseAtKey];
  if (pauseAtNum) {
    int pauseAt = [pauseAtNum intValue];
    if (pauseAt < totalBytesSent) {
      // We won't be paused again
      [fetcher setProperty:nil forKey:kPauseAtKey];

      // We've reached the point where we should pause.
      //
      // Use perform selector to avoid pausing immediately, as that would nuke
      // the chunk upload fetcher that is calling us back now.
      [fetcher performSelector:@selector(pauseFetching) withObject:nil afterDelay:0.0];

      [fetcher performSelector:@selector(resumeFetching) withObject:nil afterDelay:1.0];
    }
  }

  NSNumber *cancelAtNum = [fetcher propertyForKey:kCancelAtKey];
  if (cancelAtNum) {
    int cancelAt = [cancelAtNum intValue];
    if (cancelAt < totalBytesSent) {
      [fetcher setProperty:nil forKey:kCancelAtKey];

      // We've reached the point where we should cancel.
      //
      // Use perform selector to avoid stopping immediately, as that would nuke
      // the chunk upload fetcher that is calling us back now.
      [fetcher performSelector:@selector(stopFetching) withObject:nil afterDelay:0.0];
    }
  }

  NSNumber *retryAtNum = [fetcher propertyForKey:kRetryAtKey];
  if (retryAtNum) {
    int retryAt = [retryAtNum intValue];
    if (retryAt < totalBytesSent) {
      // We won't be retrying again
      [fetcher setProperty:nil forKey:kRetryAtKey];

      // save the current locationURL before appending &status=503
      NSURL *origURL = fetcher.uploadLocationURL;
      [fetcher setProperty:origURL forKey:kOriginalURLKey];

      NSString *newURLStr = [[origURL absoluteString] stringByAppendingString:@"?status=503"];
      fetcher.uploadLocationURL = [NSURL URLWithString:newURLStr];
    }
  }
}

- (void)testSmallDataChunkedUploadFetch {
  if (!_isServerRunning) return;

  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(2, 2);

  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  NSData *smallData = [GTMSessionFetcherTestServer generatedBodyDataWithLength:13];
  NSURLRequest *request = [self validUploadFileRequest];
  GTMSessionUploadFetcher *fetcher = [GTMSessionUploadFetcher uploadFetcherWithRequest:request
                                                                        uploadMIMEType:@"text/plain"
                                                                             chunkSize:75000
                                                                        fetcherService:_service];
  fetcher.uploadData = smallData;
  fetcher.allowLocalhostRequest = YES;

  // The unit tests run in a process without a signature, so they are not allowed to
  // use background sessions.
  fetcher.useBackgroundSession = NO;

  XCTAssertEqualObjects([fetcher.request.allHTTPHeaderFields valueForKey:@"User-Agent"],
                        @"UploadTest (GTMSUF/1)", @"%@", fetcher.request.allHTTPHeaderFields);

  XCTestExpectation *expectation = [self expectationWithDescription:@"fetched"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertEqualObjects(data, [self gettysburgAddress]);
    XCTAssertNil(error);
    XCTAssertEqual(fetcher.statusCode, (NSInteger)200);
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  [self assertSmallUploadFetchNotificationsWithCounter:fnctr];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  XCTAssertEqual(fnctr.fetchStarted, 2);
  XCTAssertEqual(fnctr.fetchStopped, 2);
  XCTAssertEqual(fnctr.uploadChunkFetchStarted, 1);
  XCTAssertEqual(fnctr.uploadChunkFetchStopped, 1);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
  XCTAssertEqual(fnctr.uploadLocationObtained, 1);
}

- (void)testSmallDataProviderChunkedUploadFetch {
  if (!_isServerRunning) return;

  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(2, 2);

  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  NSData *smallData = [GTMSessionFetcherTestServer generatedBodyDataWithLength:13];
  NSMutableURLRequest *request = [self validUploadFileRequest];

  // Test the default upload user-agent when none was present in the request.
  [request setValue:nil forHTTPHeaderField:@"User-Agent"];

  GTMSessionUploadFetcher *fetcher = [GTMSessionUploadFetcher uploadFetcherWithRequest:request
                                                                        uploadMIMEType:@"text/plain"
                                                                             chunkSize:75000
                                                                        fetcherService:_service];
  [fetcher setUploadDataLength:(int64_t)smallData.length
                      provider:^(int64_t offset, int64_t length,
                                 GTMSessionUploadFetcherDataProviderResponse response) {
                        NSRange range = NSMakeRange((NSUInteger)offset, (NSUInteger)length);
                        NSData *responseData = [smallData subdataWithRange:range];
                        response(responseData, kGTMSessionUploadFetcherUnknownFileSize, nil);
                      }];

  // The unit tests run in a process without a signature, so they are not allowed to
  // use background sessions.
  fetcher.useBackgroundSession = NO;
  fetcher.allowLocalhostRequest = YES;

  NSString *expectedUserAgent =
      [NSString stringWithFormat:@"%@ (GTMSUF/1)", GTMFetcherStandardUserAgentString(nil)];
  XCTAssertEqualObjects([fetcher.request.allHTTPHeaderFields valueForKey:@"User-Agent"],
                        expectedUserAgent, @"%@", fetcher.request.allHTTPHeaderFields);

  XCTestExpectation *expectation = [self expectationWithDescription:@"fetched"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertEqualObjects(data, [self gettysburgAddress]);
    XCTAssertNil(error);
    XCTAssertEqual(fetcher.statusCode, (NSInteger)200);
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  [self assertSmallUploadFetchNotificationsWithCounter:fnctr];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  XCTAssertEqual(fnctr.fetchStarted, 2);
  XCTAssertEqual(fnctr.fetchStopped, 2);
  XCTAssertEqual(fnctr.uploadChunkFetchStarted, 1);
  XCTAssertEqual(fnctr.uploadChunkFetchStopped, 1);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
  XCTAssertEqual(fnctr.uploadLocationObtained, 1);
}

- (void)testSmallDataProviderWithUnknownFileLengthChunkedUploadFetch {
  if (!_isServerRunning) return;

  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(2, 2);

  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  NSData *smallData = [GTMSessionFetcherTestServer generatedBodyDataWithLength:13];
  NSMutableURLRequest *request = [self validUploadFileRequest];

  // Test the default upload user-agent when none was present in the request.
  [request setValue:nil forHTTPHeaderField:@"User-Agent"];

  GTMSessionUploadFetcher *fetcher = [GTMSessionUploadFetcher uploadFetcherWithRequest:request
                                                                        uploadMIMEType:@"text/plain"
                                                                             chunkSize:75000
                                                                        fetcherService:_service];
  [fetcher setUploadDataLength:kGTMSessionUploadFetcherUnknownFileSize
                      provider:^(int64_t offset, int64_t length,
                                 GTMSessionUploadFetcherDataProviderResponse response) {
                        length = MIN(length, (int64_t)smallData.length);
                        NSRange range = NSMakeRange((NSUInteger)offset, (NSUInteger)length);
                        NSData *responseData = [smallData subdataWithRange:range];
                        response(responseData, (int64_t)smallData.length, nil);
                      }];

  // The unit tests run in a process without a signature, so they are not allowed to
  // use background sessions.
  fetcher.useBackgroundSession = NO;
  fetcher.allowLocalhostRequest = YES;

  NSString *expectedUserAgent =
      [NSString stringWithFormat:@"%@ (GTMSUF/1)", GTMFetcherStandardUserAgentString(nil)];
  XCTAssertEqualObjects([fetcher.request.allHTTPHeaderFields valueForKey:@"User-Agent"],
                        expectedUserAgent, @"%@", fetcher.request.allHTTPHeaderFields);

  XCTestExpectation *expectation = [self expectationWithDescription:@"fetched"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertEqualObjects(data, [self gettysburgAddress]);
    XCTAssertNil(error);
    XCTAssertEqual(fetcher.statusCode, (NSInteger)200);
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  [self assertSmallUploadFetchNotificationsWithCounter:fnctr];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  XCTAssertEqual(fnctr.fetchStarted, 2);
  XCTAssertEqual(fnctr.fetchStopped, 2);
  XCTAssertEqual(fnctr.uploadChunkFetchStarted, 1);
  XCTAssertEqual(fnctr.uploadChunkFetchStopped, 1);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
  XCTAssertEqual(fnctr.uploadLocationObtained, 1);
}

- (void)testSmallDataProviderChunkedErrorUploadFetch {
  if (!_isServerRunning) return;

  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(1, 1);

  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  NSData *smallData = [GTMSessionFetcherTestServer generatedBodyDataWithLength:13];
  NSURLRequest *request = [self validUploadFileRequest];
  GTMSessionUploadFetcher *fetcher = [GTMSessionUploadFetcher uploadFetcherWithRequest:request
                                                                        uploadMIMEType:@"text/plain"
                                                                             chunkSize:75000
                                                                        fetcherService:_service];
  [fetcher setUploadDataLength:(int64_t)smallData.length
                      provider:^(int64_t offset, int64_t length,
                                 GTMSessionUploadFetcherDataProviderResponse response) {
                        // Fail to provide NSData.
                        NSError *error = [NSError errorWithDomain:@"domain" code:-123 userInfo:nil];
                        response(nil, kGTMSessionUploadFetcherUnknownFileSize, error);
                      }];

  // The unit tests run in a process without a signature, so they are not allowed to
  // use background sessions.
  fetcher.useBackgroundSession = NO;
  fetcher.allowLocalhostRequest = YES;

  XCTestExpectation *expectation = [self expectationWithDescription:@"fetched"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertNil(data);
    XCTAssertEqual(error.code, -123);
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  XCTAssertEqual(fnctr.fetchStarted, 1);
  XCTAssertEqual(fnctr.fetchStopped, 1);
  XCTAssertEqual(fnctr.uploadChunkFetchStarted, 0);
  XCTAssertEqual(fnctr.uploadChunkFetchStopped, 0);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
  XCTAssertEqual(fnctr.uploadLocationObtained, 1);
}

- (void)assertSmallUploadFetchNotificationsWithCounter:(FetcherNotificationsCounter *)fnctr {
  NSArray *expectedURLStrings = @[ @"/gettysburgaddress.txt.upload" ];
  NSArray *expectedCommands = @[ @"upload, finalize" ];
  NSArray *expectedOffsets = @[ @0 ];
  NSArray *expectedLengths = @[ @13 ];
  XCTAssertEqualObjects(fnctr.uploadChunkRequestPaths, expectedURLStrings);
  XCTAssertEqualObjects(fnctr.uploadChunkCommands, expectedCommands);
  XCTAssertEqualObjects(fnctr.uploadChunkOffsets, expectedOffsets);
  XCTAssertEqualObjects(fnctr.uploadChunkLengths, expectedLengths);
}

- (void)assertBigUploadFetchNotificationsWithCounter:(FetcherNotificationsCounter *)fnctr {
  // These are for the big upload tests that require no resume or retry fetches.
  NSArray *expectedURLStrings = @[
    @"/gettysburgaddress.txt.upload", @"/gettysburgaddress.txt.upload",
    @"/gettysburgaddress.txt.upload"
  ];
  NSArray *expectedCommands = @[ @"upload", @"upload", @"upload, finalize" ];
  NSArray *expectedOffsets = @[ @0, @75000, @150000 ];
  NSArray *expectedLengths = @[ @75000, @75000, @49000 ];
  XCTAssertEqualObjects(fnctr.uploadChunkRequestPaths, expectedURLStrings);
  XCTAssertEqualObjects(fnctr.uploadChunkCommands, expectedCommands);
  XCTAssertEqualObjects(fnctr.uploadChunkOffsets, expectedOffsets);
  XCTAssertEqualObjects(fnctr.uploadChunkLengths, expectedLengths);
}

- (NSURL *)bigFileToUploadURLWithBaseName:(NSString *)baseName {
  // Write the big data into a temp file.
  return [self fileToUploadURLWithData:[self bigUploadData] baseName:baseName];
}

- (NSURL *)hugeFileToUploadURLWithBaseName:(NSString *)baseName {
  // Write the huge data into a temp file.

  // For a huge upload, we want bigger than the sanity check size to ensure no chunks are too big.
  NSUInteger kHugeUploadDataLength =
      (NSUInteger)kGTMSessionUploadFetcherMaximumDemandBufferSize + 654321;
  NSURL *result;

  // Local pool, kGTMSessionUploadFetcherMaximumDemandBufferSize is 100MB on
  // macOS, so make sure this NSData doesn't hang around too long.
  @autoreleasepool {
    NSData *data = [GTMSessionFetcherTestServer generatedBodyDataWithLength:kHugeUploadDataLength];
    result = [self fileToUploadURLWithData:data baseName:baseName];
  }

  return result;
}

- (NSURL *)fileToUploadURLWithData:(NSData *)data baseName:(NSString *)baseName {
  NSString *bigBaseName = [NSString stringWithFormat:@"%@_BigFile", baseName];
  NSURL *bigFileURL = [self temporaryFileURLWithBaseName:bigBaseName];
  [data writeToURL:bigFileURL atomically:YES];
  return bigFileURL;
}

- (void)testBigFileHandleChunkedUploadFetch {
  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(4, 4);
  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  NSError *fhError;
  NSURL *readFromURL = [self bigFileToUploadURLWithBaseName:NSStringFromSelector(_cmd)];
  NSFileHandle *bigFileHandle = [NSFileHandle fileHandleForReadingFromURL:readFromURL
                                                                    error:&fhError];
  XCTAssertNil(fhError);

  NSURLRequest *request = [self validUploadFileRequest];
  GTMSessionUploadFetcher *fetcher = [GTMSessionUploadFetcher uploadFetcherWithRequest:request
                                                                        uploadMIMEType:@"text/plain"
                                                                             chunkSize:75000
                                                                        fetcherService:_service];
  fetcher.uploadFileHandle = bigFileHandle;
  fetcher.useBackgroundSession = NO;
  fetcher.allowLocalhostRequest = YES;

  XCTestExpectation *expectation = [self expectationWithDescription:@"fetched"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertEqualObjects(data, [self gettysburgAddress]);
    XCTAssertNil(error);
    XCTAssertEqual(fetcher.statusCode, (NSInteger)200);
    [expectation fulfill];
  }];

  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  [self assertBigUploadFetchNotificationsWithCounter:fnctr];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  XCTAssertEqual(fnctr.fetchStarted, 4);
  XCTAssertEqual(fnctr.fetchStopped, 4);
  XCTAssertEqual(fnctr.uploadChunkFetchStarted, 3);
  XCTAssertEqual(fnctr.uploadChunkFetchStopped, 3);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
  XCTAssertEqual(fnctr.uploadLocationObtained, 1);

  [self removeTemporaryFileURL:readFromURL];
}

- (void)testBigFileURLChunkedUploadFetch {
  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(4, 4);
  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  NSURL *bigFileURL = [self bigFileToUploadURLWithBaseName:NSStringFromSelector(_cmd)];

  NSURLRequest *request = [self validUploadFileRequest];

  GTMSessionUploadFetcher *fetcher = [GTMSessionUploadFetcher uploadFetcherWithRequest:request
                                                                        uploadMIMEType:@"text/plain"
                                                                             chunkSize:75000
                                                                        fetcherService:_service];
  fetcher.uploadFileURL = bigFileURL;
  fetcher.useBackgroundSession = NO;
  fetcher.allowLocalhostRequest = YES;

  XCTestExpectation *expectation = [self expectationWithDescription:@"fetched"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertEqualObjects(data, [self gettysburgAddress]);
    XCTAssertNil(error);
    XCTAssertEqual(fetcher.statusCode, (NSInteger)200);
    [expectation fulfill];
  }];

  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  [self assertBigUploadFetchNotificationsWithCounter:fnctr];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  XCTAssertEqual(fnctr.fetchStarted, 4);
  XCTAssertEqual(fnctr.fetchStopped, 4);
  XCTAssertEqual(fnctr.uploadChunkFetchStarted, 3);
  XCTAssertEqual(fnctr.uploadChunkFetchStopped, 3);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);

  [self removeTemporaryFileURL:bigFileURL];
}

- (void)testBigFileURLChunkedGranulatedUploadFetch {
  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(4, 4);
  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  NSURL *bigFileURL = [self bigFileToUploadURLWithBaseName:NSStringFromSelector(_cmd)];

  const int64_t kGranularity = 66666;
  NSMutableURLRequest *request = [[self validUploadFileRequest] mutableCopy];
  [request setValue:@(kGranularity).stringValue
      forHTTPHeaderField:@"GTM-Upload-Granularity-Request"];
  GTMSessionUploadFetcher *fetcher = [GTMSessionUploadFetcher uploadFetcherWithRequest:request
                                                                        uploadMIMEType:@"text/plain"
                                                                             chunkSize:75000
                                                                        fetcherService:_service];
  fetcher.uploadFileURL = bigFileURL;
  fetcher.useBackgroundSession = NO;
  fetcher.allowLocalhostRequest = YES;

  XCTestExpectation *expectation = [self expectationWithDescription:@"completion handler"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertEqualObjects(data, [self gettysburgAddress]);
    XCTAssertNil(error);
    XCTAssertEqual(fetcher.statusCode, (NSInteger)200);
    [expectation fulfill];
  }];

  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  NSArray *expectedURLStrings = @[
    @"/gettysburgaddress.txt.upload", @"/gettysburgaddress.txt.upload",
    @"/gettysburgaddress.txt.upload"
  ];
  NSArray *expectedCommands = @[ @"upload", @"upload", @"upload, finalize" ];
  NSArray *expectedOffsets = @[ @0, @66666, @133332 ];
  NSArray *expectedLengths = @[ @66666, @66666, @65668 ];
  XCTAssertEqualObjects(fnctr.uploadChunkRequestPaths, expectedURLStrings);
  XCTAssertEqualObjects(fnctr.uploadChunkCommands, expectedCommands);
  XCTAssertEqualObjects(fnctr.uploadChunkOffsets, expectedOffsets);
  XCTAssertEqualObjects(fnctr.uploadChunkLengths, expectedLengths);

  // The final Content-Length should be the residual bytes considering the granularity;
  // the final offset should be a multiple of the granularity.
  int64_t lastOffset = ((NSNumber *)fnctr.uploadChunkOffsets.lastObject).longLongValue;
  XCTAssertTrue(lastOffset > 0 && (lastOffset % kGranularity) == 0, @"%lld not a multiple of %lld",
                lastOffset, kGranularity);
  int64_t lastLength = ((NSNumber *)fnctr.uploadChunkLengths.lastObject).longLongValue;
  XCTAssertEqual(lastLength, (int64_t)(kBigUploadDataLength % kGranularity));

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  XCTAssertEqual(fnctr.fetchStarted, 4);
  XCTAssertEqual(fnctr.fetchStopped, 4);
  XCTAssertEqual(fnctr.uploadChunkFetchStarted, 3);
  XCTAssertEqual(fnctr.uploadChunkFetchStopped, 3);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
  XCTAssertEqual(fnctr.uploadLocationObtained, 1);

  [self removeTemporaryFileURL:bigFileURL];
}

- (void)testBigFileURLSingleChunkedUploadFetch {
  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(2, 2);
  // Like the previous, but we upload in a single chunk, needed for an out-of-process upload.
  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  NSURL *bigFileURL = [self bigFileToUploadURLWithBaseName:NSStringFromSelector(_cmd)];

  NSURLRequest *request = [self validUploadFileRequest];
  GTMSessionUploadFetcher *fetcher =
      [GTMSessionUploadFetcher uploadFetcherWithRequest:request
                                         uploadMIMEType:@"text/plain"
                                              chunkSize:kGTMSessionUploadFetcherStandardChunkSize
                                         fetcherService:_service];
  fetcher.uploadFileURL = bigFileURL;
  fetcher.useBackgroundSession = NO;
  fetcher.allowLocalhostRequest = YES;

  XCTestExpectation *expectation = [self expectationWithDescription:@"completion handler"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertEqualObjects(data, [self gettysburgAddress]);
    XCTAssertNil(error);
    XCTAssertEqual(fetcher.statusCode, (NSInteger)200);
    [expectation fulfill];
  }];

  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  // Check that we uploaded the expected chunks.
  NSArray *expectedURLStrings = @[ @"/gettysburgaddress.txt.upload" ];
  NSArray *expectedCommands = @[ @"upload, finalize" ];
  NSArray *expectedOffsets = @[ @0 ];
  NSArray *expectedLengths = @[ @(kBigUploadDataLength) ];
  XCTAssertEqualObjects(fnctr.uploadChunkRequestPaths, expectedURLStrings);
  XCTAssertEqualObjects(fnctr.uploadChunkCommands, expectedCommands);
  XCTAssertEqualObjects(fnctr.uploadChunkOffsets, expectedOffsets);
  XCTAssertEqualObjects(fnctr.uploadChunkLengths, expectedLengths);

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  XCTAssertEqual(fnctr.fetchStarted, 2);
  XCTAssertEqual(fnctr.fetchStopped, 2);
  XCTAssertEqual(fnctr.uploadChunkFetchStarted, 1);
  XCTAssertEqual(fnctr.uploadChunkFetchStopped, 1);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
  XCTAssertEqual(fnctr.uploadLocationObtained, 1);

  [self removeTemporaryFileURL:bigFileURL];
}

- (void)testBigFileURLSingleChunkedUploadFetchRetry {
  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(3, 3);
  // Like testBigFileURLSingleChunkedUploadFetch, but the initial request will fail
  // with HTTP 503, triggering a retry.
  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  NSURL *bigFileURL = [self bigFileToUploadURLWithBaseName:NSStringFromSelector(_cmd)];

  NSMutableURLRequest *request = [self validUploadFileRequest];

  NSURL *originalURL = request.URL;
  NSString *failureURL = [originalURL.absoluteString stringByAppendingString:@"?status=503"];
  request.URL = [NSURL URLWithString:failureURL];

  GTMSessionUploadFetcher *fetcher =
      [GTMSessionUploadFetcher uploadFetcherWithRequest:request
                                         uploadMIMEType:@"text/plain"
                                              chunkSize:kGTMSessionUploadFetcherStandardChunkSize
                                         fetcherService:_service];
  fetcher.uploadFileURL = bigFileURL;
  fetcher.useBackgroundSession = NO;
  fetcher.allowLocalhostRequest = YES;

  BOOL (^shouldRetryUpload)(GTMSessionUploadFetcher *, BOOL, NSError *) =
      ^BOOL(GTMSessionUploadFetcher *blockFetcher, BOOL suggestedWillRetry, NSError *error) {
        // Change this fetch's request to have the original, non-failure status URL.
        // This will make the retry succeed.
        NSMutableURLRequest *mutableRequest = [blockFetcher mutableRequestForTesting];
        mutableRequest.URL = originalURL;
        blockFetcher.uploadLocationURL = originalURL;

        return suggestedWillRetry;  // do the retry fetch; it should succeed now
      };

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-retain-cycles"
  fetcher.retryEnabled = YES;
  fetcher.retryBlock =
      ^(BOOL suggestedWillRetry, NSError *error, GTMSessionFetcherRetryResponse response) {
        BOOL shouldRetry = shouldRetryUpload(fetcher, suggestedWillRetry, error);
        response(shouldRetry);
      };
#pragma clang diagnostic pop

  XCTestExpectation *expectation = [self expectationWithDescription:@"completion handler"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertEqualObjects(data, [self gettysburgAddress]);
    XCTAssertNil(error);
    XCTAssertEqual(fetcher.statusCode, (NSInteger)200);
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  // Check that we uploaded the expected chunks.
  NSArray *expectedURLStrings = @[ @"/gettysburgaddress.txt.upload" ];
  NSArray *expectedCommands = @[ @"upload, finalize" ];
  NSArray *expectedOffsets = @[ @0 ];
  NSArray *expectedLengths = @[ @(kBigUploadDataLength) ];
  XCTAssertEqualObjects(fnctr.uploadChunkRequestPaths, expectedURLStrings);
  XCTAssertEqualObjects(fnctr.uploadChunkCommands, expectedCommands);
  XCTAssertEqualObjects(fnctr.uploadChunkOffsets, expectedOffsets);
  XCTAssertEqualObjects(fnctr.uploadChunkLengths, expectedLengths);

  XCTAssertEqual(fnctr.fetchStarted, 3);
  XCTAssertEqual(fnctr.fetchStopped, 3);
  XCTAssertEqual(fnctr.uploadChunkFetchStarted, 1);
  XCTAssertEqual(fnctr.uploadChunkFetchStopped, 1);
  XCTAssertEqual(fnctr.retryDelayStarted, 1);
  XCTAssertEqual(fnctr.retryDelayStopped, 1);
  XCTAssertEqual(fnctr.uploadLocationObtained, 1);

  [self removeTemporaryFileURL:bigFileURL];
}

// Forces the server to return a 503 every time there is an upload, causing UploadFetcher to retry
// until it has reached the maximum retry limit
- (void)testBigFileURLSingleChunkedUploadFetchLimitedRetry {
  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(10, 10);
  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  NSURL *bigFileURL = [self bigFileToUploadURLWithBaseName:NSStringFromSelector(_cmd)];
  NSString *filename = [NSString stringWithFormat:@"gettysburgaddress.txt.upload?uploadStatus=503"];
  NSURL *uploadLocationURL = [_testServer localURLForFile:filename];

  GTMSessionUploadFetcher *fetcher =
      [GTMSessionUploadFetcher uploadFetcherWithLocation:uploadLocationURL
                                          uploadMIMEType:@"text/plain"
                                               chunkSize:5000
                                          fetcherService:_service];
  fetcher.maxUploadRetryInterval = 15;

  fetcher.uploadFileURL = bigFileURL;
  fetcher.useBackgroundSession = NO;
  fetcher.allowLocalhostRequest = YES;

  fetcher.retryEnabled = YES;

  XCTestExpectation *expectation = [self expectationWithDescription:@"completion handler"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertEqualObjects(error.userInfo[@"description"], @"Retry Limit Reached");
    XCTAssertEqual(fetcher.statusCode, (NSInteger)503);
    XCTAssertNotNil(fetcher.responseHeaders);
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  // Check that we uploaded the expected chunks.
  NSArray *expectedCommands = @[
    @"query", @"upload", @"query", @"upload", @"query", @"upload", @"query", @"upload", @"query",
    @"upload"
  ];
  NSArray *expectedOffsets = @[ @0, @0, @0, @0, @0, @0, @0, @0, @0, @0 ];
  NSArray *expectedLengths = @[ @0, @5000, @0, @5000, @0, @5000, @0, @5000, @0, @5000 ];
  XCTAssertEqualObjects(fnctr.uploadChunkCommands, expectedCommands);
  XCTAssertEqualObjects(fnctr.uploadChunkOffsets, expectedOffsets);
  XCTAssertEqualObjects(fnctr.uploadChunkLengths, expectedLengths);

  XCTAssertEqual(fnctr.fetchStarted, 10);
  XCTAssertEqual(fnctr.fetchStopped, 10);
  XCTAssertEqual(fnctr.uploadChunkFetchStarted, 10);
  XCTAssertEqual(fnctr.uploadChunkFetchStopped, 10);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
  XCTAssertEqual(fnctr.uploadLocationObtained, 0);

  [self removeTemporaryFileURL:bigFileURL];
}

// Forces the server to return a 503 every time there is an upload, cancels the upload in the middle
// of a backoff, and makes sure that the timer has been killed.
- (void)testBigFileURLSingleChunkedUploadFetchLimitedRetryWithCancel {
  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(3, 3);
  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  NSURL *bigFileURL = [self bigFileToUploadURLWithBaseName:NSStringFromSelector(_cmd)];
  NSString *filename = [NSString stringWithFormat:@"gettysburgaddress.txt.upload?uploadStatus=503"];
  NSURL *uploadLocationURL = [_testServer localURLForFile:filename];

  GTMSessionUploadFetcher *fetcher =
      [GTMSessionUploadFetcher uploadFetcherWithLocation:uploadLocationURL
                                          uploadMIMEType:@"text/plain"
                                               chunkSize:5000
                                          fetcherService:_service];

  __weak typeof(fetcher) weakFetcher = fetcher;
  fetcher.uploadFileURL = bigFileURL;
  fetcher.useBackgroundSession = NO;
  fetcher.allowLocalhostRequest = YES;

  XCTestExpectation *expectation = [self expectationWithDescription:@"completion handler"];
  fetcher.retryEnabled = YES;

  fetcher.cancellationHandler = ^(GTMSessionFetcher *_Nullable sessionFetcher,
                                  NSData *_Nullable data, NSError *_Nullable error) {
    __strong typeof(fetcher) strongFetcher = weakFetcher;
    XCTAssertNil(strongFetcher.uploadRetryTimer);
    XCTAssertNotNil(sessionFetcher);
    [expectation fulfill];
  };
  XCTestExpectation *fetcherBackoffStartedExpectation__ = [[XCTNSNotificationExpectation alloc]
      initWithName:kGTMSessionFetcherUploadInitialBackoffStartedNotification];
  fetcherBackoffStartedExpectation__.expectedFulfillmentCount = 1;

  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTFail("Should not attempt to complete task");
  }];
  [self waitForExpectations:@[ fetcherBackoffStartedExpectation__ ] timeout:10.0];

  __strong typeof(fetcher) strongFetcher = weakFetcher;
  XCTAssertNotNil(strongFetcher.uploadRetryTimer);
  XCTAssertTrue(strongFetcher.isFetching);
  [strongFetcher performSelector:@selector(stopFetching) withObject:nil afterDelay:0.0];

  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  // Check that we uploaded the expected chunks.
  NSArray *expectedCommands = @[ @"query", @"upload", @"cancel" ];
  NSArray *expectedOffsets = @[ @0, @0, @0 ];
  NSArray *expectedLengths = @[
    @0,
    @5000,
    @0,
  ];
  XCTAssertEqualObjects(fnctr.uploadChunkCommands, expectedCommands);
  XCTAssertEqualObjects(fnctr.uploadChunkOffsets, expectedOffsets);
  XCTAssertEqualObjects(fnctr.uploadChunkLengths, expectedLengths);

  XCTAssertEqual(fnctr.fetchStarted, 3);
  XCTAssertEqual(fnctr.fetchStopped, 3);
  XCTAssertEqual(fnctr.uploadChunkFetchStarted, 3);
  XCTAssertEqual(fnctr.uploadChunkFetchStopped, 3);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
  XCTAssertEqual(fnctr.uploadLocationObtained, 0);

  [self removeTemporaryFileURL:bigFileURL];
}

// Like the previous test, but with stopFetchingTriggersCompletionHandler set, so stopping during
// the backoff must also call the completion handler with a cancellation error.
- (void)testBigFileURLSingleChunkedUploadFetchLimitedRetryWithCancelAndCallback {
  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(3, 3);
  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  NSURL *bigFileURL = [self bigFileToUploadURLWithBaseName:NSStringFromSelector(_cmd)];
  NSString *filename = @"gettysburgaddress.txt.upload?uploadStatus=503";
  NSURL *uploadLocationURL = [_testServer localURLForFile:filename];

  GTMSessionUploadFetcher *fetcher =
      [GTMSessionUploadFetcher uploadFetcherWithLocation:uploadLocationURL
                                          uploadMIMEType:@"text/plain"
                                               chunkSize:5000
                                          fetcherService:_service];
  __weak typeof(fetcher) weakFetcher = fetcher;
  fetcher.uploadFileURL = bigFileURL;
  fetcher.useBackgroundSession = NO;
  fetcher.allowLocalhostRequest = YES;
  fetcher.retryEnabled = YES;
  fetcher.stopFetchingTriggersCompletionHandler = YES;

  XCTestExpectation *cancelExpectation = [self expectationWithDescription:@"cancelled"];
  fetcher.cancellationHandler = ^(GTMSessionFetcher *_Nullable sessionFetcher,
                                  NSData *_Nullable data, NSError *_Nullable error) {
    __strong typeof(fetcher) strongFetcher = weakFetcher;
    XCTAssertNil(strongFetcher.uploadRetryTimer);
    XCTAssertNotNil(sessionFetcher);
    [cancelExpectation fulfill];
  };

  XCTNSNotificationExpectation *backoffExpectation = [[XCTNSNotificationExpectation alloc]
      initWithName:kGTMSessionFetcherUploadInitialBackoffStartedNotification
            object:fetcher];
  backoffExpectation.expectedFulfillmentCount = 1;

  XCTestExpectation *completionExpectation = [self expectationWithDescription:@"completion"];
  completionExpectation.assertForOverFulfill = YES;
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertNil(data);
    XCTAssertEqualObjects(error.domain, kGTMSessionFetcherErrorDomain);
    XCTAssertEqual(error.code, GTMSessionFetcherErrorUserCancelled);
    [completionExpectation fulfill];
  }];

  [self waitForExpectations:@[ backoffExpectation ] timeout:10.0];

  XCTAssertNotNil(fetcher.uploadRetryTimer);
  [fetcher stopFetching];

  [self waitForExpectations:@[ cancelExpectation, completionExpectation ] timeout:_timeoutInterval];
  [self assertCallbacksReleasedForFetcher:fetcher];
  XCTAssertNil(fetcher.cancellationHandler);

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  NSArray *expectedCommands = @[ @"query", @"upload", @"cancel" ];
  XCTAssertEqualObjects(fnctr.uploadChunkCommands, expectedCommands);
  XCTAssertEqual(fnctr.fetchStarted, 3);
  XCTAssertEqual(fnctr.fetchStopped, 3);
  XCTAssertEqual(fnctr.uploadChunkFetchStarted, 3);
  XCTAssertEqual(fnctr.uploadChunkFetchStopped, 3);

  [self removeTemporaryFileURL:bigFileURL];
}

// This appears to be hang/fail when testing macOS with Xcode 8. The
// waitForExpectationsWithTimeout runs longer than the 4 minutes, before dying.
// And while it is running, something bad seems to happen as the machine can
// become almost unusable.  Once the test is killed things return to normal.
// TODO: Revisit this and the macOS value for
// kGTMSessionUploadFetcherMaximumDemandBufferSize, as it cound be too large.
#if TARGET_OS_IPHONE
- (void)testHugeFileHandleSingleChunkedUploadFetch {
  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(3, 3);

  // Like the previous, but we upload in a single chunk, needed for an out-of-process upload.
  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  NSURL *hugeFileURL = [self hugeFileToUploadURLWithBaseName:NSStringFromSelector(_cmd)];
  NSError *fileHandleError;
  NSFileHandle *fileHandle = [NSFileHandle fileHandleForReadingFromURL:hugeFileURL
                                                                 error:&fileHandleError];
  NSURLRequest *request = [self validUploadFileRequest];
  GTMSessionUploadFetcher *fetcher =
      [GTMSessionUploadFetcher uploadFetcherWithRequest:request
                                         uploadMIMEType:@"text/plain"
                                              chunkSize:kGTMSessionUploadFetcherStandardChunkSize
                                         fetcherService:_service];
  fetcher.uploadFileHandle = fileHandle;
  fetcher.useBackgroundSession = NO;
  fetcher.allowLocalhostRequest = YES;

  XCTestExpectation *expectation = [self expectationWithDescription:@"completion handler"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertEqualObjects(data, [self gettysburgAddress]);
    XCTAssertNil(error);
    XCTAssertEqual(fetcher.statusCode, (NSInteger)200);
    [expectation fulfill];
  }];

  // Add four minutes for the timeout of the huge upload test.
  [self waitForExpectationsWithTimeout:_timeoutInterval + (4 * 60) handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  // Chunk length is constrained to a sane buffer size.
  NSArray *expectedOffsets = @[ @0, @(kGTMSessionUploadFetcherMaximumDemandBufferSize) ];
  NSArray *expectedLengths = @[ @(kGTMSessionUploadFetcherMaximumDemandBufferSize), @654321 ];
  XCTAssertEqualObjects(fnctr.uploadChunkOffsets, expectedOffsets);
  XCTAssertEqualObjects(fnctr.uploadChunkLengths, expectedLengths);

  XCTAssertEqual(fnctr.fetchStarted, 3);
  XCTAssertEqual(fnctr.fetchStopped, 3);
  XCTAssertEqual(fnctr.uploadChunkFetchStarted, 2);
  XCTAssertEqual(fnctr.uploadChunkFetchStopped, 2);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
  XCTAssertEqual(fnctr.uploadLocationObtained, 1);

  [self removeTemporaryFileURL:hugeFileURL];
}
#endif  // TARGET_OS_IPHONE

- (void)testBigFileURLResumeUploadFetch {
  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(3, 3);
  // Force a query that will resume at 9000 bytes before the file end (status active).
  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  NSURL *bigFileURL = [self bigFileToUploadURLWithBaseName:NSStringFromSelector(_cmd)];
  NSString *filename =
      [NSString stringWithFormat:@"gettysburgaddress.txt.upload?bytesReceived=%lld",
                                 (int64_t)kBigUploadDataLength - 9000];
  NSURL *uploadLocationURL = [_testServer localURLForFile:filename];

  GTMSessionUploadFetcher *fetcher =
      [GTMSessionUploadFetcher uploadFetcherWithLocation:uploadLocationURL
                                          uploadMIMEType:@"text/plain"
                                               chunkSize:5000
                                          fetcherService:_service];
  fetcher.uploadFileURL = bigFileURL;
  fetcher.useBackgroundSession = NO;
  fetcher.allowLocalhostRequest = YES;

  XCTestExpectation *expectation = [self expectationWithDescription:@"completion handler"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertEqualObjects(data, [self gettysburgAddress]);
    XCTAssertNil(error);

    NSURLRequest *lastChunkRequest = fetcher.lastChunkRequest;
    NSDictionary *lastChunkRequestHdrs = [lastChunkRequest allHTTPHeaderFields];

    XCTAssertEqual([[lastChunkRequestHdrs objectForKey:@"Content-Length"] intValue], 4000);
    XCTAssertEqualObjects([lastChunkRequestHdrs objectForKey:@"X-Goog-Upload-Offset"], @"195000");
    XCTAssertEqualObjects([lastChunkRequestHdrs objectForKey:@"X-Goog-Upload-Command"],
                          @"upload, finalize");
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  XCTAssertEqual(fnctr.fetchStarted, 3);
  XCTAssertEqual(fnctr.fetchStopped, 3);
  XCTAssertEqual(fnctr.uploadChunkFetchStarted, 3);
  XCTAssertEqual(fnctr.uploadChunkFetchStopped, 3);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
  XCTAssertEqual(fnctr.uploadLocationObtained, 0);

  [self removeTemporaryFileURL:bigFileURL];
}

- (void)testBigFileURLQueryFinalUploadFetch {
  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(1, 1);
  // Force a query that indicates the upload was done (status final.)
  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  NSURL *bigFileURL = [self bigFileToUploadURLWithBaseName:NSStringFromSelector(_cmd)];
  NSString *filename = @"gettysburgaddress.txt.upload?queryStatus=final";
  NSURL *uploadLocationURL = [_testServer localURLForFile:filename];

  GTMSessionUploadFetcher *fetcher =
      [GTMSessionUploadFetcher uploadFetcherWithLocation:uploadLocationURL
                                          uploadMIMEType:@"text/plain"
                                               chunkSize:5000
                                          fetcherService:_service];
  fetcher.uploadFileURL = bigFileURL;
  fetcher.useBackgroundSession = NO;
  fetcher.allowLocalhostRequest = YES;

  XCTestExpectation *expectation = [self expectationWithDescription:@"completion handler"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertEqualObjects(data, [self gettysburgAddress]);
    XCTAssertNil(error);
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  XCTAssertEqual(fnctr.fetchStarted, 1);
  XCTAssertEqual(fnctr.fetchStopped, 1);
  XCTAssertEqual(fnctr.uploadChunkFetchStarted, 1);
  XCTAssertEqual(fnctr.uploadChunkFetchStopped, 1);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
  XCTAssertEqual(fnctr.uploadLocationObtained, 0);

  [self removeTemporaryFileURL:bigFileURL];
}

- (void)testBigFileURLNewlyInstantiatedFetcherQueryFinalUploadFetch {
  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(1, 1);
  // Force a query that indicates the upload was done (status final.)
  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  NSURL *bigFileURL = [self bigFileToUploadURLWithBaseName:NSStringFromSelector(_cmd)];
  NSString *filename = @"gettysburgaddress.txt.upload?queryStatus=final";
  NSURL *uploadLocationURL = [_testServer localURLForFile:filename];

  GTMSessionUploadFetcher *fetcher =
      [GTMSessionUploadFetcher uploadFetcherWithLocation:uploadLocationURL
                                          uploadMIMEType:@"text/plain"
                                               chunkSize:5000
                                          fetcherService:_service];
  fetcher.uploadFileURL = bigFileURL;
  fetcher.useBackgroundSession = NO;
  fetcher.allowLocalhostRequest = YES;

  XCTestExpectation *expectation = [self expectationWithDescription:@"completion handler"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertEqualObjects(data, [self gettysburgAddress]);
    XCTAssertNil(error);
    XCTAssertEqual(fetcher.statusCode, (NSInteger)200);
    XCTAssertEqualObjects(fetcher.responseHeaders[@"X-Goog-Upload-Status"], @"final");
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  XCTAssertEqual(fnctr.fetchStarted, 1);
  XCTAssertEqual(fnctr.fetchStopped, 1);
  XCTAssertEqual(fnctr.uploadChunkFetchStarted, 1);
  XCTAssertEqual(fnctr.uploadChunkFetchStopped, 1);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
  XCTAssertEqual(fnctr.uploadLocationObtained, 0);

  [self removeTemporaryFileURL:bigFileURL];
}

- (void)testBigFileURLInterruptedFinalChunkUploadQueryFinal {
  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(5, 5);
  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  NSURL *bigFileURL = [self bigFileToUploadURLWithBaseName:NSStringFromSelector(_cmd)];
  // Add a sleep on the server side during each chunk fetch, to ensure there is time to pause
  // the fetcher before all chunk fetches complete.
  NSURLRequest *request = [self validUploadFileRequestWithParameters:@{@"sleep" : @"0.5"}];

  GTMSessionUploadFetcher *fetcher = [GTMSessionUploadFetcher uploadFetcherWithRequest:request
                                                                        uploadMIMEType:@"text/plain"
                                                                             chunkSize:75000
                                                                        fetcherService:_service];
  fetcher.uploadFileURL = bigFileURL;
  fetcher.useBackgroundSession = NO;
  fetcher.allowLocalhostRequest = YES;

  __weak typeof(fetcher) weakFetcher = fetcher;
  fetcher.sendProgressBlock =
      ^(int64_t bytesSent, int64_t totalBytesSent, int64_t totalBytesExpectedToSend) {
        GTMSessionUploadFetcher *strongFetcher = weakFetcher;
        
        NSNumber *pauseAtNum = [strongFetcher propertyForKey:kPauseAtKey];
        if (pauseAtNum) {
          int pauseAt = [pauseAtNum intValue];
          if (pauseAt < totalBytesSent) {
            [strongFetcher setProperty:nil forKey:kPauseAtKey];
            
            // Change the upload target so that the subsequent query returns final.
            NSURL *origURL = strongFetcher.uploadLocationURL;
            NSString *newURLStr = [[origURL absoluteString] stringByAppendingString:@"?queryStatus=final"];
            strongFetcher.uploadLocationURL = [NSURL URLWithString:newURLStr];
            
            // Pause synchronously to ensure the task is cancelled before it finishes downloading the response.
            [strongFetcher pauseFetching];
            [strongFetcher performSelector:@selector(resumeFetching) withObject:nil afterDelay:1.0];
          }
        }
      };
  [fetcher setProperty:@151000 forKey:kPauseAtKey];

  XCTestExpectation *expectation = [self expectationWithDescription:@"completion handler"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertEqualObjects(data, [self gettysburgAddress]);
    XCTAssertNil(error);
    XCTAssertEqual(fetcher.statusCode, (NSInteger)200);
    XCTAssertEqualObjects(fetcher.responseHeaders[@"X-Goog-Upload-Status"], @"final");
    [expectation fulfill];
  }];

  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  NSArray *expectedCommands = @[ @"upload", @"upload", @"upload, finalize", @"query" ];
  NSArray *expectedOffsets = @[ @0, @75000, @150000, @0 ];
  NSArray *expectedLengths = @[ @75000, @75000, @49000, @0 ];
  XCTAssertEqualObjects(fnctr.uploadChunkCommands, expectedCommands);
  XCTAssertEqualObjects(fnctr.uploadChunkOffsets, expectedOffsets);
  XCTAssertEqualObjects(fnctr.uploadChunkLengths, expectedLengths);

  XCTAssertEqual(fnctr.fetchStarted, 5);
  XCTAssertEqual(fnctr.fetchStopped, 5);
  XCTAssertEqual(fnctr.uploadChunkFetchStarted, 4);
  XCTAssertEqual(fnctr.uploadChunkFetchStopped, 4);

  [self removeTemporaryFileURL:bigFileURL];
}

// Tests that currentOffset is set to the offset returned by query
- (void)testBigFileURLQueryFinalUploadFetchWithOffset {
  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(2, 2);
  // Force a query that indicates the upload was done (status final.)
  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  NSURL *bigFileURL = [self bigFileToUploadURLWithBaseName:NSStringFromSelector(_cmd)];
  NSString *filename = @"gettysburgaddress.txt.upload?queryStatus=&bytesReceived=199000";
  NSURL *uploadLocationURL = [_testServer localURLForFile:filename];

  GTMSessionUploadFetcher *fetcher =
      [GTMSessionUploadFetcher uploadFetcherWithLocation:uploadLocationURL
                                          uploadMIMEType:@"text/plain"
                                               chunkSize:5000
                                          fetcherService:_service];
  fetcher.uploadFileURL = bigFileURL;
  fetcher.useBackgroundSession = NO;
  fetcher.allowLocalhostRequest = YES;
  fetcher.retryEnabled = YES;

  XCTestExpectation *expectation = [self expectationWithDescription:@"completion handler"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertEqualObjects(data, [self gettysburgAddress]);
    XCTAssertNil(error);
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();
  NSArray *expectedCommands = @[ @"query", @"finalize" ];
  NSArray *expectedOffsets = @[ @0, @199000 ];
  NSArray *expectedLengths = @[ @0, @0 ];
  XCTAssertEqualObjects(fnctr.uploadChunkCommands, expectedCommands);
  XCTAssertEqualObjects(fnctr.uploadChunkOffsets, expectedOffsets);
  XCTAssertEqualObjects(fnctr.uploadChunkLengths, expectedLengths);

  XCTAssertEqual(fnctr.fetchStarted, 2);
  XCTAssertEqual(fnctr.fetchStopped, 2);
  XCTAssertEqual(fnctr.uploadChunkFetchStarted, 2);
  XCTAssertEqual(fnctr.uploadChunkFetchStopped, 2);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
  XCTAssertEqual(fnctr.uploadLocationObtained, 0);

  [self removeTemporaryFileURL:bigFileURL];
}

- (void)testBigFileURLChunkUploadFetchWith404Error {
  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(2, 2);
  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  NSURL *bigFileURL = [self bigFileToUploadURLWithBaseName:NSStringFromSelector(_cmd)];
  // Use a URL that will return 404 on the first chunk upload.
  NSString *filename = @"gettysburgaddress.txt.upload?uploadStatus=404";
  NSURL *uploadLocationURL = [_testServer localURLForFile:filename];

  GTMSessionUploadFetcher *fetcher =
      [GTMSessionUploadFetcher uploadFetcherWithLocation:uploadLocationURL
                                          uploadMIMEType:@"text/plain"
                                               chunkSize:5000
                                          fetcherService:_service];
  fetcher.uploadFileURL = bigFileURL;
  fetcher.useBackgroundSession = NO;
  fetcher.allowLocalhostRequest = YES;

  XCTestExpectation *expectation = [self expectationWithDescription:@"fetched"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertNil(data);
    XCTAssertEqual(error.code, (NSInteger)404);
    XCTAssertEqual(fetcher.statusCode, (NSInteger)404);
    XCTAssertNotNil(fetcher.responseHeaders);
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  XCTAssertEqual(fnctr.fetchStarted, 2);
  XCTAssertEqual(fnctr.fetchStopped, 2);
  XCTAssertEqual(fnctr.uploadChunkFetchStarted, 2);
  XCTAssertEqual(fnctr.uploadChunkFetchStopped, 2);

  [self removeTemporaryFileURL:bigFileURL];
}

- (void)testInitialFetchUploadError {
  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(1, 1);
  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  NSURL *bigFileURL = [self bigFileToUploadURLWithBaseName:NSStringFromSelector(_cmd)];
  NSString *filename = @"gettysburgaddress.txt.upload?status=502";
  NSURLRequest *request = [self validUploadFileRequestWithFileName:filename];

  GTMSessionUploadFetcher *fetcher =
      [GTMSessionUploadFetcher uploadFetcherWithRequest:request
                                         uploadMIMEType:@"text/plain"
                                              chunkSize:5000
                                         fetcherService:_service];
  fetcher.uploadFileURL = bigFileURL;
  fetcher.useBackgroundSession = NO;
  fetcher.allowLocalhostRequest = YES;

  XCTestExpectation *expectation = [self expectationWithDescription:@"fetched"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertNil(data);
    XCTAssertEqual(error.code, (NSInteger)502);
    XCTAssertEqual(fetcher.statusCode, (NSInteger)502);
    XCTAssertNotNil(fetcher.responseHeaders);
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  XCTAssertEqual(fnctr.fetchStarted, 1);
  XCTAssertEqual(fnctr.fetchStopped, 1);
  XCTAssertEqual(fnctr.uploadChunkFetchStarted, 0);
  XCTAssertEqual(fnctr.uploadChunkFetchStopped, 0);

  [self removeTemporaryFileURL:bigFileURL];
}

- (void)testBigFileURLQueryUploadFetchWithServerError {
  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(1, 1);
  // Force a query that fails immediately when retry is disabled.
  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  NSURL *bigFileURL = [self bigFileToUploadURLWithBaseName:NSStringFromSelector(_cmd)];
  NSString *filename = @"gettysburgaddress.txt.upload?queryStatus=error";
  NSURL *uploadLocationURL = [_testServer localURLForFile:filename];

  GTMSessionUploadFetcher *fetcher =
      [GTMSessionUploadFetcher uploadFetcherWithLocation:uploadLocationURL
                                          uploadMIMEType:@"text/plain"
                                               chunkSize:5000
                                          fetcherService:_service];
  fetcher.uploadFileURL = bigFileURL;
  fetcher.useBackgroundSession = NO;
  fetcher.allowLocalhostRequest = YES;
  fetcher.retryEnabled = NO;

  XCTestExpectation *expectation = [self expectationWithDescription:@"fetched"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertNil(data);
    XCTAssertEqual(error.code, (NSInteger)502);
    XCTAssertEqual(fetcher.statusCode, (NSInteger)502);
    XCTAssertNotNil(fetcher.responseHeaders);
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  XCTAssertEqual(fnctr.fetchStarted, 1);
  XCTAssertEqual(fnctr.fetchStopped, 1);
  XCTAssertEqual(fnctr.uploadChunkFetchStarted, 1);
  XCTAssertEqual(fnctr.uploadChunkFetchStopped, 1);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
  XCTAssertEqual(fnctr.uploadLocationObtained, 0);

  [self removeTemporaryFileURL:bigFileURL];
}

- (void)testBigFileURLQueryUploadFetchLimitedRetry {
  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(4, 4);
  // Force an offset query that repeatedly fails with 502 and verify it retries with exponential
  // backoff until maxUploadRetryInterval is reached.
  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  NSURL *bigFileURL = [self bigFileToUploadURLWithBaseName:NSStringFromSelector(_cmd)];
  NSString *filename = @"gettysburgaddress.txt.upload?queryStatus=error";
  NSURL *uploadLocationURL = [_testServer localURLForFile:filename];

  GTMSessionUploadFetcher *fetcher =
      [GTMSessionUploadFetcher uploadFetcherWithLocation:uploadLocationURL
                                          uploadMIMEType:@"text/plain"
                                               chunkSize:5000
                                          fetcherService:_service];
  fetcher.uploadFileURL = bigFileURL;
  fetcher.useBackgroundSession = NO;
  fetcher.allowLocalhostRequest = YES;
  fetcher.retryEnabled = YES;
  fetcher.minUploadRetryInterval = 0.05;
  fetcher.maxUploadRetryInterval = 0.25;

  XCTNSNotificationExpectation *backoffExpectation = [[XCTNSNotificationExpectation alloc]
      initWithName:kGTMSessionFetcherUploadInitialBackoffStartedNotification
            object:fetcher];
  backoffExpectation.expectedFulfillmentCount = 3;
  backoffExpectation.assertForOverFulfill = YES;

  XCTestExpectation *expectation = [self expectationWithDescription:@"completion handler"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertNil(data);
    XCTAssertEqualObjects(error.userInfo[@"description"], @"Retry Limit Reached");
    XCTAssertEqual(fetcher.statusCode, (NSInteger)502);
    XCTAssertNotNil(fetcher.responseHeaders);
    [expectation fulfill];
  }];
  [self waitForExpectations:@[ backoffExpectation, expectation ] timeout:_timeoutInterval];
  [self assertCallbacksReleasedForFetcher:fetcher];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  NSArray *expectedCommands = @[ @"query", @"query", @"query", @"query" ];
  NSArray *expectedOffsets = @[ @0, @0, @0, @0 ];
  NSArray *expectedLengths = @[ @0, @0, @0, @0 ];
  XCTAssertEqualObjects(fnctr.uploadChunkCommands, expectedCommands);
  XCTAssertEqualObjects(fnctr.uploadChunkOffsets, expectedOffsets);
  XCTAssertEqualObjects(fnctr.uploadChunkLengths, expectedLengths);

  XCTAssertEqual(fnctr.fetchStarted, 4);
  XCTAssertEqual(fnctr.fetchStopped, 4);
  XCTAssertEqual(fnctr.uploadChunkFetchStarted, 4);
  XCTAssertEqual(fnctr.uploadChunkFetchStopped, 4);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
  XCTAssertEqual(fnctr.uploadLocationObtained, 0);

  [self removeTemporaryFileURL:bigFileURL];
}

- (void)testBigFileURLQueryCanceledUploadFetch {
  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(1, 1);
  // Force a query that indicates the upload was abandoned (status cancelled.)
  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  NSURL *bigFileURL = [self bigFileToUploadURLWithBaseName:NSStringFromSelector(_cmd)];
  NSString *filename = @"gettysburgaddress.txt.upload?queryStatus=cancelled";
  NSURL *uploadLocationURL = [_testServer localURLForFile:filename];

  GTMSessionUploadFetcher *fetcher =
      [GTMSessionUploadFetcher uploadFetcherWithLocation:uploadLocationURL
                                          uploadMIMEType:@"text/plain"
                                               chunkSize:5000
                                          fetcherService:_service];
  fetcher.uploadFileURL = bigFileURL;
  fetcher.useBackgroundSession = NO;
  fetcher.allowLocalhostRequest = YES;

  XCTestExpectation *expectation = [self expectationWithDescription:@"completion handler"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertEqualObjects(data, [NSData data]);
    XCTAssertEqual(error.code, (NSInteger)501);
    XCTAssertEqual(fetcher.statusCode, (NSInteger)200);
    XCTAssertEqualObjects(fetcher.responseHeaders[@"X-Goog-Upload-Status"], @"cancelled");
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  XCTAssertEqual(fnctr.fetchStarted, 1);
  XCTAssertEqual(fnctr.fetchStopped, 1);
  XCTAssertEqual(fnctr.uploadChunkFetchStarted, 1);
  XCTAssertEqual(fnctr.uploadChunkFetchStopped, 1);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
  XCTAssertEqual(fnctr.uploadLocationObtained, 0);

  [self removeTemporaryFileURL:bigFileURL];
}

- (void)testEmptyFileURLUploadFetch {
  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(2, 2);
  // Like the previous, but we upload in a single chunk, needed for an out-of-process upload.
  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  NSURL *emptyFileURL = [self fileToUploadURLWithData:[NSData data]
                                             baseName:NSStringFromSelector(_cmd)];

  NSURLRequest *request = [self validUploadFileRequestWithFileName:@"empty.txt"];
  GTMSessionUploadFetcher *fetcher =
      [GTMSessionUploadFetcher uploadFetcherWithRequest:request
                                         uploadMIMEType:@"text/plain"
                                              chunkSize:kGTMSessionUploadFetcherStandardChunkSize
                                         fetcherService:_service];
  fetcher.uploadFileURL = emptyFileURL;
  fetcher.useBackgroundSession = NO;
  fetcher.allowLocalhostRequest = YES;

  XCTestExpectation *expectation = [self expectationWithDescription:@"completion handler"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    // Test that server result is returned (success or failure).
    // The current test server don't accept POST requests with empty body.
    XCTAssertEqual(data.length, 0);
    XCTAssertNil(error);
    [expectation fulfill];
  }];

  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  // Check that we uploaded the expected chunks.
  NSArray *expectedURLStrings = @[ @"/empty.txt.upload" ];
  NSArray *expectedCommands = @[ @"finalize" ];
  NSArray *expectedOffsets = @[ @0 ];
  NSArray *expectedLengths = @[ @0 ];
  XCTAssertEqualObjects(fnctr.uploadChunkRequestPaths, expectedURLStrings);
  XCTAssertEqualObjects(fnctr.uploadChunkCommands, expectedCommands);
  XCTAssertEqualObjects(fnctr.uploadChunkOffsets, expectedOffsets);
  XCTAssertEqualObjects(fnctr.uploadChunkLengths, expectedLengths);

  XCTAssertEqual(fnctr.fetchStarted, 2);
  XCTAssertEqual(fnctr.fetchStopped, 2);
  XCTAssertEqual(fnctr.uploadChunkFetchStarted, 1);
  XCTAssertEqual(fnctr.uploadChunkFetchStopped, 1);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
  XCTAssertEqual(fnctr.uploadLocationObtained, 1);

  [self removeTemporaryFileURL:emptyFileURL];
}

- (void)testNonExistingFileURLUploadFetch {
  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(1, 1);
  // Like the previous, but we upload in a single chunk, needed for an out-of-process upload.
  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  NSURL *nonExistingFileURL = [NSURL fileURLWithPath:@"some/file"];

  NSURLRequest *request = [self validUploadFileRequest];
  GTMSessionUploadFetcher *fetcher =
      [GTMSessionUploadFetcher uploadFetcherWithRequest:request
                                         uploadMIMEType:@"text/plain"
                                              chunkSize:kGTMSessionUploadFetcherStandardChunkSize
                                         fetcherService:_service];
  fetcher.uploadFileURL = nonExistingFileURL;
  fetcher.useBackgroundSession = NO;
  fetcher.allowLocalhostRequest = YES;

  XCTestExpectation *expectation = [self expectationWithDescription:@"completion handler"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    // The current test server don't accept POST requests with empty body.
    XCTAssertNil(data);
    XCTAssertEqual(error.code, 260);
    [expectation fulfill];
  }];

  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  // Check that we uploaded the expected chunks.
  NSArray *expectedURLStrings = @[];
  NSArray *expectedCommands = @[];
  NSArray *expectedOffsets = @[];
  NSArray *expectedLengths = @[];
  XCTAssertEqualObjects(fnctr.uploadChunkRequestPaths, expectedURLStrings);
  XCTAssertEqualObjects(fnctr.uploadChunkCommands, expectedCommands);
  XCTAssertEqualObjects(fnctr.uploadChunkOffsets, expectedOffsets);
  XCTAssertEqualObjects(fnctr.uploadChunkLengths, expectedLengths);

  XCTAssertEqual(fnctr.fetchStarted, 1);
  XCTAssertEqual(fnctr.fetchStopped, 1);
  XCTAssertEqual(fnctr.uploadChunkFetchStarted, 0);
  XCTAssertEqual(fnctr.uploadChunkFetchStopped, 0);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
  XCTAssertEqual(fnctr.uploadLocationObtained, 1);
}

- (void)testBigDataChunkedUploadFetch {
  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(4, 4);
  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  NSURLRequest *request = [self validUploadFileRequest];

  NSData *bigData = [self bigUploadData];
  GTMSessionUploadFetcher *fetcher = [GTMSessionUploadFetcher uploadFetcherWithRequest:request
                                                                        uploadMIMEType:@"text/plain"
                                                                             chunkSize:75000
                                                                        fetcherService:_service];
  fetcher.uploadData = bigData;
  fetcher.useBackgroundSession = NO;
  fetcher.allowLocalhostRequest = YES;

  XCTestExpectation *expectation = [self expectationWithDescription:@"completion handler"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertEqualObjects(data, [self gettysburgAddress]);
    XCTAssertNil(error);
    XCTAssertEqual(fetcher.statusCode, (NSInteger)200);
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  [self assertBigUploadFetchNotificationsWithCounter:fnctr];

  XCTAssertEqual(fnctr.fetchStarted, 4);
  XCTAssertEqual(fnctr.fetchStopped, 4);
  XCTAssertEqual(fnctr.uploadChunkFetchStarted, 3);
  XCTAssertEqual(fnctr.uploadChunkFetchStopped, 3);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
  XCTAssertEqual(fnctr.uploadLocationObtained, 1);
}

- (void)testBigDataProviderChunkedUploadFetch {
  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(4, 4);
  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  NSURLRequest *request = [self validUploadFileRequest];

  NSData *bigData = [self bigUploadData];
  GTMSessionUploadFetcher *fetcher = [GTMSessionUploadFetcher uploadFetcherWithRequest:request
                                                                        uploadMIMEType:@"text/plain"
                                                                             chunkSize:75000
                                                                        fetcherService:_service];
  [fetcher setUploadDataLength:(int64_t)bigData.length
                      provider:^(int64_t offset, int64_t length,
                                 GTMSessionUploadFetcherDataProviderResponse response) {
                        NSRange range = NSMakeRange((NSUInteger)offset, (NSUInteger)length);
                        NSData *responseData = [bigData subdataWithRange:range];
                        response(responseData, kGTMSessionUploadFetcherUnknownFileSize, nil);
                      }];
  fetcher.useBackgroundSession = NO;
  fetcher.allowLocalhostRequest = YES;

  XCTestExpectation *expectation = [self expectationWithDescription:@"completion handler"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertEqualObjects(data, [self gettysburgAddress]);
    XCTAssertNil(error);
    XCTAssertEqual(fetcher.statusCode, (NSInteger)200);
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  [self assertBigUploadFetchNotificationsWithCounter:fnctr];

  XCTAssertEqual(fnctr.fetchStarted, 4);
  XCTAssertEqual(fnctr.fetchStopped, 4);
  XCTAssertEqual(fnctr.uploadChunkFetchStarted, 3);
  XCTAssertEqual(fnctr.uploadChunkFetchStopped, 3);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
  XCTAssertEqual(fnctr.uploadLocationObtained, 1);
}

- (void)testBigDataProviderChunkedUploadFetchSuccessClearsCancellationHandler {
  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(4, 4);
  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  NSURLRequest *request = [self validUploadFileRequest];

  NSData *bigData = [self bigUploadData];
  GTMSessionUploadFetcher *fetcher = [GTMSessionUploadFetcher uploadFetcherWithRequest:request
                                                                        uploadMIMEType:@"text/plain"
                                                                             chunkSize:75000
                                                                        fetcherService:_service];
  [fetcher setUploadDataLength:(int64_t)bigData.length
                      provider:^(int64_t offset, int64_t length,
                                 GTMSessionUploadFetcherDataProviderResponse response) {
                        NSRange range = NSMakeRange((NSUInteger)offset, (NSUInteger)length);
                        NSData *responseData = [bigData subdataWithRange:range];
                        response(responseData, kGTMSessionUploadFetcherUnknownFileSize, nil);
                      }];
  fetcher.useBackgroundSession = NO;
  fetcher.allowLocalhostRequest = YES;
  fetcher.cancellationHandler =
      ^(GTMSessionFetcher *cancellationFetcher, NSData *data, NSError *error) {
        XCTFail("Success should not call cancellation handler.");
      };

  XCTestExpectation *expectation = [self expectationWithDescription:@"completion handler"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertEqualObjects(data, [self gettysburgAddress]);
    XCTAssertNil(error);
    XCTAssertEqual(fetcher.statusCode, (NSInteger)200);
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];
  // Success should clear the cancellationHandler.
  XCTAssertNil(fetcher.cancellationHandler);

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  [self assertBigUploadFetchNotificationsWithCounter:fnctr];

  XCTAssertEqual(fnctr.fetchStarted, 4);
  XCTAssertEqual(fnctr.fetchStopped, 4);
  XCTAssertEqual(fnctr.uploadChunkFetchStarted, 3);
  XCTAssertEqual(fnctr.uploadChunkFetchStopped, 3);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
  XCTAssertEqual(fnctr.uploadLocationObtained, 1);
}

- (void)testBigDataProviderChunkedUploadEarlyCancel {
  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(1, 1);
  NSURLRequest *request = [self validUploadFileRequest];

  NSData *bigData = [self bigUploadData];
  GTMSessionUploadFetcher *fetcher = [GTMSessionUploadFetcher uploadFetcherWithRequest:request
                                                                        uploadMIMEType:@"text/plain"
                                                                             chunkSize:75000
                                                                        fetcherService:_service];
  [fetcher setUploadDataLength:(int64_t)bigData.length
                      provider:^(int64_t offset, int64_t length,
                                 GTMSessionUploadFetcherDataProviderResponse response) {
                        NSRange range = NSMakeRange((NSUInteger)offset, (NSUInteger)length);
                        NSData *responseData = [bigData subdataWithRange:range];
                        response(responseData, kGTMSessionUploadFetcherUnknownFileSize, nil);
                      }];
  fetcher.useBackgroundSession = NO;
  fetcher.allowLocalhostRequest = YES;
  XCTestExpectation *expectation = [self expectationWithDescription:@"cancelled"];
  fetcher.cancellationHandler =
      ^(GTMSessionFetcher *cancellationFetcher, NSData *data, NSError *error) {
        // Should be nil as we cancel before allowing any thing to happen.
        XCTAssertNil(cancellationFetcher);
        [expectation fulfill];
      };

  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTFail("Completion should not fire as fetcher is immediately cancelled.");
  }];
  [fetcher stopFetching];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];
  // Immediate fire should clear out cancellation handler.
  XCTAssertNil(fetcher.cancellationHandler);

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();
}

- (void)testBigDataProviderChunkedUploadEarlyCancelWithCallback {
  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(1, 1);
  NSURLRequest *request = [self validUploadFileRequest];

  NSData *bigData = [self bigUploadData];
  GTMSessionUploadFetcher *fetcher = [GTMSessionUploadFetcher uploadFetcherWithRequest:request
                                                                        uploadMIMEType:@"text/plain"
                                                                             chunkSize:75000
                                                                        fetcherService:_service];
  [fetcher setUploadDataLength:(int64_t)bigData.length
                      provider:^(int64_t offset, int64_t length,
                                 GTMSessionUploadFetcherDataProviderResponse response) {
                        NSRange range = NSMakeRange((NSUInteger)offset, (NSUInteger)length);
                        NSData *responseData = [bigData subdataWithRange:range];
                        response(responseData, kGTMSessionUploadFetcherUnknownFileSize, nil);
                      }];
  fetcher.useBackgroundSession = NO;
  fetcher.allowLocalhostRequest = YES;
  fetcher.stopFetchingTriggersCompletionHandler = YES;
  XCTestExpectation *expectation = [self expectationWithDescription:@"cancelled"];
  fetcher.cancellationHandler =
      ^(GTMSessionFetcher *cancellationFetcher, NSData *data, NSError *error) {
        // Should be nil as we cancel before allowing any thing to happen.
        XCTAssertNil(cancellationFetcher);
        [expectation fulfill];
      };

  XCTestExpectation *completionExpectation = [self expectationWithDescription:@"completion"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    [completionExpectation fulfill];
  }];
  [fetcher stopFetching];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];
  // Immediate fire should clear out cancellation handler.
  XCTAssertNil(fetcher.cancellationHandler);

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();
}

- (void)testBigDataProviderWithUnknownFileLengthChunkedUploadFetch {
  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(4, 4);
  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  NSURLRequest *request = [self validUploadFileRequest];

  NSData *bigData = [self bigUploadData];
  GTMSessionUploadFetcher *fetcher = [GTMSessionUploadFetcher uploadFetcherWithRequest:request
                                                                        uploadMIMEType:@"text/plain"
                                                                             chunkSize:75000
                                                                        fetcherService:_service];
  [fetcher setUploadDataLength:kGTMSessionUploadFetcherUnknownFileSize
                      provider:^(int64_t offset, int64_t length,
                                 GTMSessionUploadFetcherDataProviderResponse response) {
                        int64_t readLength = MIN(length, (int64_t)bigData.length - offset);
                        NSRange range = NSMakeRange((NSUInteger)offset, (NSUInteger)readLength);
                        NSData *responseData = [bigData subdataWithRange:range];

                        if (readLength != length) {
                          response(responseData, (int64_t)bigData.length, nil);
                        } else {
                          response(responseData, -1, nil);
                        }
                      }];
  fetcher.useBackgroundSession = NO;
  fetcher.allowLocalhostRequest = YES;

  XCTestExpectation *expectation = [self expectationWithDescription:@"completion handler"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertEqualObjects(data, [self gettysburgAddress]);
    XCTAssertNil(error);
    XCTAssertEqual(fetcher.statusCode, (NSInteger)200);
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  [self assertBigUploadFetchNotificationsWithCounter:fnctr];

  XCTAssertEqual(fnctr.fetchStarted, 4);
  XCTAssertEqual(fnctr.fetchStopped, 4);
  XCTAssertEqual(fnctr.uploadChunkFetchStarted, 3);
  XCTAssertEqual(fnctr.uploadChunkFetchStopped, 3);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
  XCTAssertEqual(fnctr.uploadLocationObtained, 1);
}

- (void)testBigDataChunkedUploadWithPause {
  // Repeat the previous test, pausing after 20,000 bytes.
  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(5, 5);
  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  // Add a sleep on the server side during each chunk fetch, to ensure there is time to pause
  // the fetcher before all chunk fetches complete.
  NSURLRequest *request = [self validUploadFileRequestWithParameters:@{@"sleep" : @"0.2"}];
  NSData *bigData = [self bigUploadData];
  GTMSessionUploadFetcher *fetcher = [GTMSessionUploadFetcher uploadFetcherWithRequest:request
                                                                        uploadMIMEType:@"text/plain"
                                                                             chunkSize:75000
                                                                        fetcherService:_service];
  fetcher.uploadData = bigData;
  fetcher.useBackgroundSession = NO;
  fetcher.allowLocalhostRequest = YES;

  // Add a property to the fetcher that our progress callback will look for to
  // know when to pause and resume the upload
  fetcher.sendProgressBlock =
      ^(int64_t bytesSent, int64_t totalBytesSent, int64_t totalBytesExpectedToSend) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-retain-cycles"
        TestProgressBlock(fetcher, bytesSent, totalBytesSent, totalBytesExpectedToSend);
#pragma clang diagnostic pop
      };
  [fetcher setProperty:@20000 forKey:kPauseAtKey];

  XCTestExpectation *expectation = [self expectationWithDescription:@"completion handler"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertEqualObjects(data, [self gettysburgAddress]);
    XCTAssertNil(error);
    XCTAssertEqual(fetcher.statusCode, (NSInteger)200);
    [expectation fulfill];
  }];

  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  NSArray *expectedURLStrings = @[
    @"/gettysburgaddress.txt.upload", @"/gettysburgaddress.txt.upload",
    @"/gettysburgaddress.txt.upload", @"/gettysburgaddress.txt.upload"
  ];
  NSArray *expectedCommands = @[ @"upload", @"query", @"upload", @"upload, finalize" ];
  NSArray *expectedOffsets = @[ @0, @0, @75000, @150000 ];
  NSArray *expectedLengths = @[ @75000, @0, @75000, @49000 ];
  XCTAssertEqualObjects(fnctr.uploadChunkRequestPaths, expectedURLStrings);
  XCTAssertEqualObjects(fnctr.uploadChunkCommands, expectedCommands);
  XCTAssertEqualObjects(fnctr.uploadChunkOffsets, expectedOffsets);
  XCTAssertEqualObjects(fnctr.uploadChunkLengths, expectedLengths);

  XCTAssertEqual(fnctr.fetchStarted, 5);
  XCTAssertEqual(fnctr.fetchStopped, 5);
  XCTAssertEqual(fnctr.uploadChunkFetchStarted, 4);
  XCTAssertEqual(fnctr.uploadChunkFetchStopped, 4);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
  XCTAssertEqual(fnctr.uploadLocationObtained, 1);
}

- (void)testBigDataChunkedUploadWithUnknownFileSizeAndPause {
  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(5, 5);
  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  // Add a sleep on the server side during each chunk fetch, to ensure there is time to pause
  // the fetcher before all chunk fetches complete.
  NSURLRequest *request = [self validUploadFileRequestWithParameters:@{@"sleep" : @"0.2"}];
  NSData *bigData = [self bigUploadData];
  GTMSessionUploadFetcher *fetcher = [GTMSessionUploadFetcher uploadFetcherWithRequest:request
                                                                        uploadMIMEType:@"text/plain"
                                                                             chunkSize:75000
                                                                        fetcherService:_service];
  [fetcher setUploadDataLength:kGTMSessionUploadFetcherUnknownFileSize
                      provider:^(int64_t offset, int64_t length,
                                 GTMSessionUploadFetcherDataProviderResponse response) {
                        length = MIN(length, (int64_t)bigData.length);
                        NSRange range = NSMakeRange((NSUInteger)offset, (NSUInteger)length);
                        NSData *responseData = [bigData subdataWithRange:range];

                        int64_t fileLength = 0;
                        if (offset) {
                          fileLength = (int64_t)bigData.length;
                        }
                        response(responseData, fileLength, nil);
                      }];

  fetcher.useBackgroundSession = NO;
  fetcher.allowLocalhostRequest = YES;

  // Add a property to the fetcher that our progress callback will look for to
  // know when to pause and resume the upload
  fetcher.sendProgressBlock =
      ^(int64_t bytesSent, int64_t totalBytesSent, int64_t totalBytesExpectedToSend) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-retain-cycles"
        TestProgressBlock(fetcher, bytesSent, totalBytesSent, totalBytesExpectedToSend);
#pragma clang diagnostic pop
      };
  [fetcher setProperty:@20000 forKey:kPauseAtKey];

  XCTestExpectation *expectation = [self expectationWithDescription:@"completion handler"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertEqualObjects(data, [self gettysburgAddress]);
    XCTAssertNil(error);
    XCTAssertEqual(fetcher.statusCode, (NSInteger)200);
    [expectation fulfill];
  }];

  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  NSArray *expectedURLStrings = @[
    @"/gettysburgaddress.txt.upload", @"/gettysburgaddress.txt.upload",
    @"/gettysburgaddress.txt.upload", @"/gettysburgaddress.txt.upload"
  ];
  NSArray *expectedCommands = @[ @"upload", @"query", @"upload", @"upload, finalize" ];
  NSArray *expectedOffsets = @[ @0, @0, @75000, @150000 ];
  NSArray *expectedLengths = @[ @75000, @0, @75000, @49000 ];
  XCTAssertEqualObjects(fnctr.uploadChunkRequestPaths, expectedURLStrings);
  XCTAssertEqualObjects(fnctr.uploadChunkCommands, expectedCommands);
  XCTAssertEqualObjects(fnctr.uploadChunkOffsets, expectedOffsets);
  XCTAssertEqualObjects(fnctr.uploadChunkLengths, expectedLengths);

  XCTAssertEqual(fnctr.fetchStarted, 5);
  XCTAssertEqual(fnctr.fetchStopped, 5);
  XCTAssertEqual(fnctr.uploadChunkFetchStarted, 4);
  XCTAssertEqual(fnctr.uploadChunkFetchStopped, 4);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
  XCTAssertEqual(fnctr.uploadLocationObtained, 1);
}

- (void)testBigDataChunkedUploadWithCancel {
  // Repeat the previous test, canceling after 20,000 bytes.
  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(3, 3);
  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  NSURLRequest *request = [self validUploadFileRequest];
  NSData *bigData = [self bigUploadData];
  GTMSessionUploadFetcher *fetcher = [GTMSessionUploadFetcher uploadFetcherWithRequest:request
                                                                        uploadMIMEType:@"text/plain"
                                                                             chunkSize:75000
                                                                        fetcherService:_service];
  fetcher.uploadData = bigData;
  fetcher.useBackgroundSession = NO;
  fetcher.allowLocalhostRequest = YES;

  // Add a property to the fetcher that our progress callback will look for to
  // know when to cancel the upload
  fetcher.sendProgressBlock =
      ^(int64_t bytesSent, int64_t totalBytesSent, int64_t totalBytesExpectedToSend) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-retain-cycles"
        TestProgressBlock(fetcher, bytesSent, totalBytesSent, totalBytesExpectedToSend);
#pragma clang diagnostic pop
      };
  [fetcher setProperty:@20000 forKey:kCancelAtKey];
  XCTestExpectation *expectation = [self expectationWithDescription:@"cancelled"];
  fetcher.cancellationHandler =
      ^(GTMSessionFetcher *cancellationFetcher, NSData *data, NSError *error) {
        XCTAssertNotNil(cancellationFetcher);
        [expectation fulfill];
      };

  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTFail(@"Canceled fetcher should not have called back");
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  XCTAssertEqual(fnctr.fetchCompletionInvoked, 2);
  XCTAssertEqual(fnctr.fetchStarted, 3);
  XCTAssertEqual(fnctr.fetchStopped, 3);
  XCTAssertEqual(fnctr.uploadChunkFetchStarted, 2);
  XCTAssertEqual(fnctr.uploadChunkFetchStopped, 2);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
  XCTAssertEqual(fnctr.uploadLocationObtained, 1);

  // After cancellation fires, it should be removed.
  XCTAssertNil(fetcher.cancellationHandler);
}

- (void)testBigDataChunkedUploadWithCancelAndCallback {
  // Repeat the previous test, canceling after 20,000 bytes.
  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(3, 3);
  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  NSURLRequest *request = [self validUploadFileRequest];
  NSData *bigData = [self bigUploadData];
  GTMSessionUploadFetcher *fetcher = [GTMSessionUploadFetcher uploadFetcherWithRequest:request
                                                                        uploadMIMEType:@"text/plain"
                                                                             chunkSize:75000
                                                                        fetcherService:_service];
  fetcher.uploadData = bigData;
  fetcher.useBackgroundSession = NO;
  fetcher.allowLocalhostRequest = YES;
  fetcher.stopFetchingTriggersCompletionHandler = YES;

  // Add a property to the fetcher that our progress callback will look for to
  // know when to cancel the upload
  fetcher.sendProgressBlock =
      ^(int64_t bytesSent, int64_t totalBytesSent, int64_t totalBytesExpectedToSend) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-retain-cycles"
        TestProgressBlock(fetcher, bytesSent, totalBytesSent, totalBytesExpectedToSend);
#pragma clang diagnostic pop
      };
  [fetcher setProperty:@20000 forKey:kCancelAtKey];
  XCTestExpectation *expectation = [self expectationWithDescription:@"cancelled"];
  fetcher.cancellationHandler =
      ^(GTMSessionFetcher *cancellationFetcher, NSData *data, NSError *error) {
        XCTAssertNotNil(cancellationFetcher);
        [expectation fulfill];
      };

  XCTestExpectation *completionExpectation = [self expectationWithDescription:@"completion"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    [completionExpectation fulfill];
  }];

  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  XCTAssertEqual(fnctr.fetchCompletionInvoked, 3);
  XCTAssertEqual(fnctr.fetchStarted, 3);
  XCTAssertEqual(fnctr.fetchStopped, 3);
  XCTAssertEqual(fnctr.uploadChunkFetchStarted, 2);
  XCTAssertEqual(fnctr.uploadChunkFetchStopped, 2);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
  XCTAssertEqual(fnctr.uploadLocationObtained, 1);

  // After cancellation fires, it should be removed.
  XCTAssertNil(fetcher.cancellationHandler);
}

- (void)testBigDataChunkedUploadWithRetry {
  // Repeat the upload, and after sending 40,000 bytes the progress
  // callback will change the request URL for the next chunk fetch to make
  // it fail with a retryable status error.

  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(6, 6);
  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  BOOL (^shouldRetryUpload)(GTMSessionUploadFetcher *, BOOL, NSError *) =
      ^BOOL(GTMSessionUploadFetcher *fetcher, BOOL suggestedWillRetry, NSError *error) {
        // Change this fetch's request (and future requests) to have the original URL,
        // not the one with status=503 appended.
        NSURL *origURL = [fetcher propertyForKey:kOriginalURLKey];

        NSMutableURLRequest *mutableRequest = [fetcher mutableRequestForTesting];
        mutableRequest.URL = origURL;
        fetcher.uploadLocationURL = origURL;

        [fetcher setProperty:nil forKey:kOriginalURLKey];

        return suggestedWillRetry;  // do the retry fetch; it should succeed now
      };

  NSURLRequest *request = [self validUploadFileRequest];
  NSData *bigData = [self bigUploadData];
  GTMSessionUploadFetcher *fetcher = [GTMSessionUploadFetcher uploadFetcherWithRequest:request
                                                                        uploadMIMEType:@"text/plain"
                                                                             chunkSize:75000
                                                                        fetcherService:_service];
  fetcher.uploadData = bigData;
  fetcher.useBackgroundSession = NO;
  fetcher.allowLocalhostRequest = YES;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-retain-cycles"
  fetcher.retryEnabled = YES;
  fetcher.retryBlock =
      ^(BOOL suggestedWillRetry, NSError *error, GTMSessionFetcherRetryResponse response) {
        BOOL shouldRetry = shouldRetryUpload(fetcher, suggestedWillRetry, error);
        response(shouldRetry);
      };

  fetcher.sendProgressBlock =
      ^(int64_t bytesSent, int64_t totalBytesSent, int64_t totalBytesExpectedToSend) {
        TestProgressBlock(fetcher, bytesSent, totalBytesSent, totalBytesExpectedToSend);
      };
#pragma clang diagnostic pop

  // Add a property to the fetcher that our progress callback will look for to
  // know when to retry the upload.
  [fetcher setProperty:@40000 forKey:kRetryAtKey];

  XCTestExpectation *expectation = [self expectationWithDescription:@"completion handler"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertEqualObjects(data, [self gettysburgAddress]);
    XCTAssertNil(error);
    XCTAssertEqual(fetcher.statusCode, (NSInteger)200);
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  NSArray *expectedURLStrings = @[
    @"/gettysburgaddress.txt.upload", @"/gettysburgaddress.txt.upload",
    @"/gettysburgaddress.txt.upload", @"/gettysburgaddress.txt.upload",
    @"/gettysburgaddress.txt.upload"
  ];
  NSArray *expectedCommands = @[ @"upload", @"upload", @"query", @"upload", @"upload, finalize" ];
  NSArray *expectedOffsets = @[ @0, @75000, @0, @75000, @150000 ];
  NSArray *expectedLengths = @[ @75000, @75000, @0, @75000, @49000 ];
  XCTAssertEqualObjects(fnctr.uploadChunkRequestPaths, expectedURLStrings);
  XCTAssertEqualObjects(fnctr.uploadChunkCommands, expectedCommands);
  XCTAssertEqualObjects(fnctr.uploadChunkOffsets, expectedOffsets);
  XCTAssertEqualObjects(fnctr.uploadChunkLengths, expectedLengths);

  XCTAssertEqual(fnctr.fetchStarted, 6);
  XCTAssertEqual(fnctr.fetchStopped, 6);
  XCTAssertEqual(fnctr.uploadChunkFetchStarted, 5);
  XCTAssertEqual(fnctr.uploadChunkFetchStopped, 5);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
  XCTAssertEqual(fnctr.uploadLocationObtained, 1);
}

- (void)testBigDataChunkedUploadWithChunkAndQueryRetry {
  // Simulates a server outage during which both a chunk upload and the offset query sent to recover
  // from it fail with a retryable status. The upload must back off and retry the query rather than
  // fail. A second outage then fails the last chunk. Because the backoff restarts after the middle
  // chunk is uploaded, that retry fits within maxUploadRetryInterval; without the restart, the
  // third backoff would reach the limit and fail the upload.
  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(9, 9);
  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  NSURLRequest *request = [self validUploadFileRequest];
  NSData *bigData = [self bigUploadData];
  GTMSessionUploadFetcher *fetcher = [GTMSessionUploadFetcher uploadFetcherWithRequest:request
                                                                        uploadMIMEType:@"text/plain"
                                                                             chunkSize:75000
                                                                        fetcherService:_service];
  fetcher.uploadData = bigData;
  fetcher.useBackgroundSession = NO;
  fetcher.allowLocalhostRequest = YES;
  fetcher.retryEnabled = YES;
  // Consecutive backoffs are 0.05 and 0.1 seconds; the next one would reach the 0.15 second limit.
  fetcher.minUploadRetryInterval = 0.05;
  fetcher.maxUploadRetryInterval = 0.15;

  // An outage is simulated by appending status=502 to the upload location URL.
  __block NSURL *healthyURL = nil;
  __block int64_t outageAtBytesSent = 40000;  // During the first chunk.
  __weak typeof(fetcher) weakFetcher = fetcher;
  fetcher.sendProgressBlock =
      ^(int64_t bytesSent, int64_t totalBytesSent, int64_t totalBytesExpectedToSend) {
        if (outageAtBytesSent > 0 && totalBytesSent > outageAtBytesSent) {
          outageAtBytesSent = 0;
          __strong typeof(fetcher) strongFetcher = weakFetcher;
          healthyURL = strongFetcher.uploadLocationURL;
          NSString *outageURLString =
              [healthyURL.absoluteString stringByAppendingString:@"?status=502"];
          strongFetcher.uploadLocationURL = [NSURL URLWithString:outageURLString];
        }
      };

  __block NSUInteger backoffCount = 0;
  id backoffObserver = [[NSNotificationCenter defaultCenter]
      addObserverForName:kGTMSessionFetcherUploadInitialBackoffStartedNotification
                  object:fetcher
                   queue:nil
              usingBlock:^(NSNotification *note) {
                __strong typeof(fetcher) strongFetcher = weakFetcher;
                ++backoffCount;
                if (backoffCount == 2) {
                  // The offset query failed too. End the outage, and start another one while the
                  // middle chunk is uploaded again so that the last chunk fails.
                  strongFetcher.uploadLocationURL = healthyURL;
                  outageAtBytesSent = 100000;
                } else if (backoffCount == 3) {
                  strongFetcher.uploadLocationURL = healthyURL;
                }
              }];

  XCTestExpectation *expectation = [self expectationWithDescription:@"completion handler"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertEqualObjects(data, [self gettysburgAddress]);
    XCTAssertNil(error);
    XCTAssertEqual(fetcher.statusCode, (NSInteger)200);
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [[NSNotificationCenter defaultCenter] removeObserver:backoffObserver];
  [self assertCallbacksReleasedForFetcher:fetcher];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  XCTAssertEqual(backoffCount, (NSUInteger)3);

  NSArray *expectedCommands = @[
    @"upload", @"upload", @"query", @"query", @"upload", @"upload, finalize", @"query",
    @"upload, finalize"
  ];
  NSArray *expectedOffsets = @[ @0, @75000, @0, @0, @75000, @150000, @0, @150000 ];
  NSArray *expectedLengths = @[ @75000, @75000, @0, @0, @75000, @49000, @0, @49000 ];
  XCTAssertEqualObjects(fnctr.uploadChunkCommands, expectedCommands);
  XCTAssertEqualObjects(fnctr.uploadChunkOffsets, expectedOffsets);
  XCTAssertEqualObjects(fnctr.uploadChunkLengths, expectedLengths);

  XCTAssertEqual(fnctr.fetchStarted, 9);
  XCTAssertEqual(fnctr.fetchStopped, 9);
  XCTAssertEqual(fnctr.uploadChunkFetchStarted, 8);
  XCTAssertEqual(fnctr.uploadChunkFetchStopped, 8);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
  XCTAssertEqual(fnctr.uploadLocationObtained, 1);
}

- (void)testBigDataChunkedUploadWithPauseDuringRetryBackoff {
  // Pausing while waiting to retry a failed chunk must cancel the pending retry; resuming then
  // continues the upload with a new offset query.
  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(6, 6);
  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  NSURLRequest *request = [self validUploadFileRequest];
  NSData *bigData = [self bigUploadData];
  GTMSessionUploadFetcher *fetcher = [GTMSessionUploadFetcher uploadFetcherWithRequest:request
                                                                        uploadMIMEType:@"text/plain"
                                                                             chunkSize:75000
                                                                        fetcherService:_service];
  fetcher.uploadData = bigData;
  fetcher.useBackgroundSession = NO;
  fetcher.allowLocalhostRequest = YES;
  fetcher.retryEnabled = YES;
  fetcher.minUploadRetryInterval = 5.0;

  __weak typeof(fetcher) weakFetcher = fetcher;
  fetcher.sendProgressBlock =
      ^(int64_t bytesSent, int64_t totalBytesSent, int64_t totalBytesExpectedToSend) {
        __strong typeof(fetcher) strongFetcher = weakFetcher;
        if (strongFetcher) {
          TestProgressBlock(strongFetcher, bytesSent, totalBytesSent, totalBytesExpectedToSend);
        }
      };
  // Make the second chunk upload fail.
  [fetcher setProperty:@40000 forKey:kRetryAtKey];

  __block NSUInteger backoffCount = 0;
  id backoffObserver = [[NSNotificationCenter defaultCenter]
      addObserverForName:kGTMSessionFetcherUploadInitialBackoffStartedNotification
                  object:fetcher
                   queue:nil
              usingBlock:^(NSNotification *note) {
                backoffCount++;
              }];

  XCTNSNotificationExpectation *backoffExpectation = [[XCTNSNotificationExpectation alloc]
      initWithName:kGTMSessionFetcherUploadInitialBackoffStartedNotification
            object:fetcher];
  backoffExpectation.expectedFulfillmentCount = 1;

  XCTestExpectation *completionExpectation =
      [self expectationWithDescription:@"completion handler"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertEqualObjects(data, [self gettysburgAddress]);
    XCTAssertNil(error);
    XCTAssertEqual(fetcher.statusCode, (NSInteger)200);
    [completionExpectation fulfill];
  }];

  [self waitForExpectations:@[ backoffExpectation ] timeout:10.0];

  XCTAssertNotNil(fetcher.uploadRetryTimer);
  XCTAssertTrue(fetcher.isFetching);

  [fetcher pauseFetching];
  XCTAssertTrue(fetcher.isPaused);
  XCTAssertNil(fetcher.uploadRetryTimer);
  XCTAssertFalse(fetcher.isFetching);

  fetcher.uploadLocationURL = [fetcher propertyForKey:kOriginalURLKey];
  [fetcher setProperty:nil forKey:kOriginalURLKey];
  [fetcher resumeFetching];
  XCTAssertFalse(fetcher.isPaused);

  [self waitForExpectations:@[ completionExpectation ] timeout:_timeoutInterval];
  [[NSNotificationCenter defaultCenter] removeObserver:backoffObserver];
  [self assertCallbacksReleasedForFetcher:fetcher];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  XCTAssertEqual(backoffCount, (NSUInteger)1);
  NSArray *expectedCommands = @[ @"upload", @"upload", @"query", @"upload", @"upload, finalize" ];
  NSArray *expectedOffsets = @[ @0, @75000, @0, @75000, @150000 ];
  NSArray *expectedLengths = @[ @75000, @75000, @0, @75000, @49000 ];
  XCTAssertEqualObjects(fnctr.uploadChunkCommands, expectedCommands);
  XCTAssertEqualObjects(fnctr.uploadChunkOffsets, expectedOffsets);
  XCTAssertEqualObjects(fnctr.uploadChunkLengths, expectedLengths);

  XCTAssertEqual(fnctr.fetchStarted, 6);
  XCTAssertEqual(fnctr.fetchStopped, 6);
  XCTAssertEqual(fnctr.uploadChunkFetchStarted, 5);
  XCTAssertEqual(fnctr.uploadChunkFetchStopped, 5);
}

// Calls the block on the main queue after the given upload fetcher's first offset query starts.
- (id)observeFirstOffsetQueryOfUploadFetcher:(GTMSessionUploadFetcher *)uploadFetcher
                                       block:(void (^)(void))block {
  __block BOOL hasStartedQuery = NO;
  __weak GTMSessionUploadFetcher *weakUploadFetcher = uploadFetcher;
  return [[NSNotificationCenter defaultCenter]
      addObserverForName:kGTMSessionFetcherStartedNotification
                  object:nil
                   queue:nil
              usingBlock:^(NSNotification *note) {
                GTMSessionFetcher *startedFetcher = note.object;
                NSString *command =
                    [startedFetcher.request valueForHTTPHeaderField:@"X-Goog-Upload-Command"];
                if (hasStartedQuery || startedFetcher.parentUploadFetcher != weakUploadFetcher ||
                    ![command isEqual:@"query"]) {
                  return;
                }
                hasStartedQuery = YES;
                // Run the block once the query is in flight.
                dispatch_async(dispatch_get_main_queue(), block);
              }];
}

- (void)testBigDataChunkedUploadWithPauseDuringRetryQuery {
  // Pausing while the offset query for a retry is in flight must stop the query, so that its
  // completion doesn't continue the upload while paused. The stopped query still calls back since
  // stopFetchingTriggersCompletionHandler is set, which must not complete the upload.
  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(7, 7);
  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  NSURLRequest *request = [self validUploadFileRequest];
  NSData *bigData = [self bigUploadData];
  GTMSessionUploadFetcher *fetcher = [GTMSessionUploadFetcher uploadFetcherWithRequest:request
                                                                        uploadMIMEType:@"text/plain"
                                                                             chunkSize:75000
                                                                        fetcherService:_service];
  fetcher.uploadData = bigData;
  fetcher.useBackgroundSession = NO;
  fetcher.allowLocalhostRequest = YES;
  fetcher.retryEnabled = YES;
  fetcher.minUploadRetryInterval = 0.05;
  fetcher.stopFetchingTriggersCompletionHandler = YES;

  __weak typeof(fetcher) weakFetcher = fetcher;
  fetcher.sendProgressBlock =
      ^(int64_t bytesSent, int64_t totalBytesSent, int64_t totalBytesExpectedToSend) {
        __strong typeof(fetcher) strongFetcher = weakFetcher;
        if (strongFetcher) {
          TestProgressBlock(strongFetcher, bytesSent, totalBytesSent, totalBytesExpectedToSend);
        }
      };
  // Make the second chunk upload fail, so that its retry sends an offset query.
  [fetcher setProperty:@40000 forKey:kRetryAtKey];

  void (^pauseDuringQuery)(void) = ^{
    __strong typeof(fetcher) strongFetcher = weakFetcher;
    [strongFetcher pauseFetching];
    XCTAssertFalse(strongFetcher.isFetching);

    // Give the stopped query time to call back, then resume with the server healthy again.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                     // Nothing should have been uploaded while paused.
                     NSArray *commandsWhilePaused = @[ @"upload", @"upload", @"query" ];
                     XCTAssertEqualObjects(fnctr.uploadChunkCommands, commandsWhilePaused);
                     strongFetcher.uploadLocationURL =
                         [strongFetcher propertyForKey:kOriginalURLKey];
                     [strongFetcher resumeFetching];
                   });
  };
  id queryObserver = [self observeFirstOffsetQueryOfUploadFetcher:fetcher block:pauseDuringQuery];

  XCTestExpectation *expectation = [self expectationWithDescription:@"completion handler"];
  expectation.assertForOverFulfill = YES;
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertEqualObjects(data, [self gettysburgAddress]);
    XCTAssertNil(error);
    XCTAssertEqual(fetcher.statusCode, (NSInteger)200);
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [[NSNotificationCenter defaultCenter] removeObserver:queryObserver];
  [self assertCallbacksReleasedForFetcher:fetcher];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  NSArray *expectedCommands =
      @[ @"upload", @"upload", @"query", @"query", @"upload", @"upload, finalize" ];
  NSArray *expectedOffsets = @[ @0, @75000, @0, @0, @75000, @150000 ];
  NSArray *expectedLengths = @[ @75000, @75000, @0, @0, @75000, @49000 ];
  XCTAssertEqualObjects(fnctr.uploadChunkCommands, expectedCommands);
  XCTAssertEqualObjects(fnctr.uploadChunkOffsets, expectedOffsets);
  XCTAssertEqualObjects(fnctr.uploadChunkLengths, expectedLengths);

  XCTAssertEqual(fnctr.fetchStarted, 7);
  XCTAssertEqual(fnctr.fetchStopped, 7);
  XCTAssertEqual(fnctr.uploadChunkFetchStarted, 6);
  XCTAssertEqual(fnctr.uploadChunkFetchStopped, 6);
}

- (void)testBigDataChunkedUploadWithCancelDuringRetryQuery {
  // Stopping while the offset query for a retry is in flight must stop the query, so that its
  // completion doesn't continue the upload, and must call the completion handler once with a
  // cancellation error since stopFetchingTriggersCompletionHandler is set.
  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(5, 5);
  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  NSURLRequest *request = [self validUploadFileRequest];
  NSData *bigData = [self bigUploadData];
  GTMSessionUploadFetcher *fetcher = [GTMSessionUploadFetcher uploadFetcherWithRequest:request
                                                                        uploadMIMEType:@"text/plain"
                                                                             chunkSize:75000
                                                                        fetcherService:_service];
  fetcher.uploadData = bigData;
  fetcher.useBackgroundSession = NO;
  fetcher.allowLocalhostRequest = YES;
  fetcher.retryEnabled = YES;
  fetcher.minUploadRetryInterval = 0.05;
  fetcher.stopFetchingTriggersCompletionHandler = YES;

  __weak typeof(fetcher) weakFetcher = fetcher;
  fetcher.sendProgressBlock =
      ^(int64_t bytesSent, int64_t totalBytesSent, int64_t totalBytesExpectedToSend) {
        __strong typeof(fetcher) strongFetcher = weakFetcher;
        if (strongFetcher) {
          TestProgressBlock(strongFetcher, bytesSent, totalBytesSent, totalBytesExpectedToSend);
        }
      };
  // Make the second chunk upload fail, so that its retry sends an offset query.
  [fetcher setProperty:@40000 forKey:kRetryAtKey];

  XCTestExpectation *cancelExpectation = [self expectationWithDescription:@"cancelled"];
  fetcher.cancellationHandler =
      ^(GTMSessionFetcher *cancellationFetcher, NSData *data, NSError *error) {
        XCTAssertNotNil(cancellationFetcher);
        [cancelExpectation fulfill];
      };

  void (^stopDuringQuery)(void) = ^{
    [weakFetcher stopFetching];
  };
  id queryObserver = [self observeFirstOffsetQueryOfUploadFetcher:fetcher block:stopDuringQuery];

  XCTestExpectation *completionExpectation = [self expectationWithDescription:@"completion"];
  completionExpectation.assertForOverFulfill = YES;
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertNil(data);
    XCTAssertEqualObjects(error.domain, kGTMSessionFetcherErrorDomain);
    XCTAssertEqual(error.code, GTMSessionFetcherErrorUserCancelled);
    [completionExpectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [[NSNotificationCenter defaultCenter] removeObserver:queryObserver];
  [self assertCallbacksReleasedForFetcher:fetcher];
  XCTAssertNil(fetcher.cancellationHandler);

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  // Nothing should be uploaded after stopping.
  NSArray *expectedCommands = @[ @"upload", @"upload", @"query", @"cancel" ];
  XCTAssertEqualObjects(fnctr.uploadChunkCommands, expectedCommands);
  XCTAssertEqual(fnctr.fetchStarted, 5);
  XCTAssertEqual(fnctr.fetchStopped, 5);
  XCTAssertEqual(fnctr.uploadChunkFetchStarted, 4);
  XCTAssertEqual(fnctr.uploadChunkFetchStopped, 4);
}

@end

#endif  // !TARGET_OS_WATCH
