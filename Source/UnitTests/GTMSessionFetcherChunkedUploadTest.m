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

@interface GTMSessionFetcherChunkedUploadTest : GTMSessionFetcherBaseTest
@end

@implementation GTMSessionFetcherChunkedUploadTest {
  GTMSessionFetcherService *_service;
}

- (void)setUp {
  _service = [[GTMSessionFetcherService alloc] init];
  _service.reuseSession = YES;

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

  FetcherNotificationsCounter *fnctr = [[FetcherNotificationsCounter alloc] init];

  NSData *smallData = [GTMSessionFetcherTestServer generatedBodyDataWithLength:13];
  NSURL *testURL = [NSURL URLWithString:@"http://test.example.com/foo"];
  NSURLRequest *request = [NSURLRequest requestWithURL:testURL];

  GTMSessionUploadFetcher *fetcher = [GTMSessionUploadFetcher uploadFetcherWithRequest:request
                                                                        uploadMIMEType:@"text/plain"
                                                                             chunkSize:75000
                                                                        fetcherService:_service];
  fetcher.uploadData = smallData;

  NSData *fakedResultData = [@"Snuffle." dataUsingEncoding:NSUTF8StringEncoding];
  NSHTTPURLResponse *fakedResultResponse =
      [[NSHTTPURLResponse alloc] initWithURL:testURL
                                  statusCode:200
                                 HTTPVersion:@"HTTP/1.1"
                                headerFields:@{ @"Bichon" : @"Frise" }];
  NSError *fakedResultError = nil;

  fetcher.testBlock = ^(GTMSessionFetcher *fetcherToTest,
                        GTMSessionFetcherTestResponse testResponse) {
      testResponse(fakedResultResponse, fakedResultData, fakedResultError);
  };

  fetcher.useBackgroundSession = NO;
  fetcher.allowedInsecureSchemes = @[ @"http" ];

  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
      XCTAssertEqualObjects(data, fakedResultData);
      XCTAssertNil(error);
      XCTAssertEqual(fetcher.statusCode, (NSInteger)200);
  }];
  XCTAssertTrue([fetcher waitForCompletionWithTimeout:_timeoutInterval], @"timed out");
  [self assertCallbacksReleasedForFetcher:fetcher];

  //
  // Repeat the test with an upload data provider block rather than an NSData.
  //
  NSData *bigUploadData = [GTMSessionFetcherTestServer generatedBodyDataWithLength:333];
  __block NSRange uploadedRange = NSMakeRange(0, 0);
  NSRange expectedRange = NSMakeRange(0, bigUploadData.length);

  fetcher = [GTMSessionUploadFetcher uploadFetcherWithRequest:request
                                               uploadMIMEType:@"text/plain"
                                                    chunkSize:75000
                                               fetcherService:_service];
  fetcher.uploadData = nil;
  [fetcher setUploadDataLength:(int64_t)expectedRange.length
                      provider:^(int64_t offset, int64_t length,
                                 GTMSessionUploadFetcherDataProviderResponse response) {
      NSRange providingRange = NSMakeRange((NSUInteger)offset, (NSUInteger)length);
      uploadedRange = NSUnionRange(uploadedRange, providingRange);
      NSData *subdata = [bigUploadData subdataWithRange:providingRange];
      response(subdata, nil);
  }];

  fakedResultError = nil;

  fetcher.testBlock = ^(GTMSessionFetcher *fetcherToTest,
                        GTMSessionFetcherTestResponse testResponse) {
      testResponse(fakedResultResponse, fakedResultData, fakedResultError);
  };

  fetcher.useBackgroundSession = NO;
  fetcher.allowedInsecureSchemes = @[ @"http" ];

  XCTestExpectation *expectation = [self expectationWithDescription:@"fetched"];
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

- (NSMutableURLRequest *)validUploadFileRequest {
  NSString *validURLString = [self localURLStringToTestFileName:kGTMGettysburgFileName];
  validURLString = [validURLString stringByAppendingString:@".location"];
  NSMutableURLRequest *request = [self requestWithURLString:validURLString];
  [request setValue:@"UploadTest" forHTTPHeaderField:@"User-Agent"];
  return request;
}

// We use the sendBytes callback to pause and restart an upload,
// and to change the upload location URL to cause a chunk upload
// failure and retry.

static NSString* const kPauseAtKey = @"pauseAt";
static NSString* const kCancelAtKey = @"cancelAt";
static NSString* const kRetryAtKey = @"retryAt";
static NSString* const kOriginalURLKey = @"originalURL";

static void TestProgressBlock(GTMSessionUploadFetcher *fetcher,
                              int64_t bytesSent,
                              int64_t totalBytesSent,
                              int64_t totalBytesExpectedToSend) {
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
      [fetcher performSelector:@selector(pauseFetching)
                    withObject:nil
                    afterDelay:0.0];

      [fetcher performSelector:@selector(resumeFetching)
                    withObject:nil
                    afterDelay:1.0];
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
      [fetcher performSelector:@selector(stopFetching)
                    withObject:nil
                    afterDelay:0.0];
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
                        @"UploadTest (GTMSUF/1)",
                        @"%@", fetcher.request.allHTTPHeaderFields);

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
      response(responseData, nil);
  }];

  // The unit tests run in a process without a signature, so they are not allowed to
  // use background sessions.
  fetcher.useBackgroundSession = NO;
  fetcher.allowLocalhostRequest = YES;

  NSString *expectedUserAgent = [NSString stringWithFormat:@"%@ (GTMSUF/1)",
                                 GTMFetcherStandardUserAgentString(nil)];
  XCTAssertEqualObjects([fetcher.request.allHTTPHeaderFields valueForKey:@"User-Agent"],
                        expectedUserAgent,
                        @"%@", fetcher.request.allHTTPHeaderFields);

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
    response(nil, error);
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
  NSArray *expectedURLStrings = @[ @"/gettysburgaddress.txt.upload",
                                   @"/gettysburgaddress.txt.upload",
                                   @"/gettysburgaddress.txt.upload" ];
  NSArray *expectedCommands = @[ @"upload",
                                 @"upload",
                                 @"upload, finalize" ];
  NSArray *expectedOffsets = @[ @0,
                                @75000,
                                @150000 ];
  NSArray *expectedLengths = @[ @75000,
                                @75000,
                                @49000 ];
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

  XCTAssertEqual(fnctr.fetchStarted, 4);
  XCTAssertEqual(fnctr.fetchStopped, 4);
  XCTAssertEqual(fnctr.uploadChunkFetchStarted, 3);
  XCTAssertEqual(fnctr.uploadChunkFetchStopped, 3);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);

  [self removeTemporaryFileURL:bigFileURL];
}

- (void)testBigFileURLChunkedGranulatedUploadFetch {
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

  XCTestExpectation *expectation = [self expectationWithDescription:@"fetched"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
      XCTAssertEqualObjects(data, [self gettysburgAddress]);
      XCTAssertNil(error);
      XCTAssertEqual(fetcher.statusCode, (NSInteger)200);
      [expectation fulfill];
  }];

  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  NSArray *expectedURLStrings = @[ @"/gettysburgaddress.txt.upload",
                                   @"/gettysburgaddress.txt.upload",
                                   @"/gettysburgaddress.txt.upload" ];
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
  XCTAssertTrue(lastOffset > 0 && (lastOffset % kGranularity) == 0,
                @"%lld not a multiple of %lld", lastOffset, kGranularity);
  int64_t lastLength = ((NSNumber *)fnctr.uploadChunkLengths.lastObject).longLongValue;
  XCTAssertEqual(lastLength, (int64_t)(kBigUploadDataLength % kGranularity));


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

  XCTestExpectation *expectation = [self expectationWithDescription:@"fetched"];
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

  XCTAssertEqual(fnctr.fetchStarted, 2);
  XCTAssertEqual(fnctr.fetchStopped, 2);
  XCTAssertEqual(fnctr.uploadChunkFetchStarted, 1);
  XCTAssertEqual(fnctr.uploadChunkFetchStopped, 1);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
  XCTAssertEqual(fnctr.uploadLocationObtained, 1);

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

  XCTestExpectation *expectation = [self expectationWithDescription:@"fetched"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
      XCTAssertEqualObjects(data, [self gettysburgAddress]);
      XCTAssertNil(error);
      XCTAssertEqual(fetcher.statusCode, (NSInteger)200);
      [expectation fulfill];
  }];

  // Add four minutes for the timeout of the huge upload test.
  [self waitForExpectationsWithTimeout:_timeoutInterval + (4 * 60)
                               handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

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

  XCTestExpectation *expectation = [self expectationWithDescription:@"fetched"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
      XCTAssertEqualObjects(data, [self gettysburgAddress]);
      XCTAssertNil(error);

      NSURLRequest *lastChunkRequest = fetcher.lastChunkRequest;
      NSDictionary *lastChunkRequestHdrs = [lastChunkRequest allHTTPHeaderFields];

      XCTAssertEqual([[lastChunkRequestHdrs objectForKey:@"Content-Length"] intValue], 4000);
      XCTAssertEqualObjects([lastChunkRequestHdrs objectForKey:@"X-Goog-Upload-Offset"],
                            @"195000");
      XCTAssertEqualObjects([lastChunkRequestHdrs objectForKey:@"X-Goog-Upload-Command"],
                            @"upload, finalize");
      [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

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

  XCTestExpectation *expectation = [self expectationWithDescription:@"fetched"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
      XCTAssertEqualObjects(data, [self gettysburgAddress]);
      XCTAssertNil(error);
      [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  XCTAssertEqual(fnctr.fetchStarted, 1);
  XCTAssertEqual(fnctr.fetchStopped, 1);
  XCTAssertEqual(fnctr.uploadChunkFetchStarted, 1);
  XCTAssertEqual(fnctr.uploadChunkFetchStopped, 1);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
  XCTAssertEqual(fnctr.uploadLocationObtained, 0);

  [self removeTemporaryFileURL:bigFileURL];
}

- (void)testBigFileURLQueryUploadFetchWithServerError {
  // Force a query that fails.
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

  XCTestExpectation *expectation = [self expectationWithDescription:@"fetched"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    XCTAssertNil(data);
    XCTAssertEqual(error.code, (NSInteger)502);
    [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  XCTAssertEqual(fnctr.fetchStarted, 1);
  XCTAssertEqual(fnctr.fetchStopped, 1);
  XCTAssertEqual(fnctr.uploadChunkFetchStarted, 1);
  XCTAssertEqual(fnctr.uploadChunkFetchStopped, 1);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
  XCTAssertEqual(fnctr.uploadLocationObtained, 0);

  [self removeTemporaryFileURL:bigFileURL];
}

- (void)testBigFileURLQueryCanceledUploadFetch {
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

  XCTestExpectation *expectation = [self expectationWithDescription:@"fetched"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
      XCTAssertEqualObjects(data, [NSData data]);
      XCTAssertEqual(error.code, (NSInteger)501);
      [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  XCTAssertEqual(fnctr.fetchStarted, 1);
  XCTAssertEqual(fnctr.fetchStopped, 1);
  XCTAssertEqual(fnctr.uploadChunkFetchStarted, 1);
  XCTAssertEqual(fnctr.uploadChunkFetchStopped, 1);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
  XCTAssertEqual(fnctr.uploadLocationObtained, 0);

  [self removeTemporaryFileURL:bigFileURL];
}

- (void)testBigDataChunkedUploadFetch {
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

  XCTAssertEqual(fnctr.fetchStarted, 4);
  XCTAssertEqual(fnctr.fetchStopped, 4);
  XCTAssertEqual(fnctr.uploadChunkFetchStarted, 3);
  XCTAssertEqual(fnctr.uploadChunkFetchStopped, 3);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
  XCTAssertEqual(fnctr.uploadLocationObtained, 1);
}

- (void)testBigDataProviderChunkedUploadFetch {
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
      response(responseData, nil);
  }];
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
  // know when to pause and resume the upload
  fetcher.sendProgressBlock = ^(int64_t bytesSent, int64_t totalBytesSent,
                                int64_t totalBytesExpectedToSend) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-retain-cycles"
    TestProgressBlock(fetcher, bytesSent, totalBytesSent, totalBytesExpectedToSend);
#pragma clang diagnostic pop
  };
  [fetcher setProperty:@20000
                forKey:kPauseAtKey];

  XCTestExpectation *expectation = [self expectationWithDescription:@"fetched"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
      XCTAssertEqualObjects(data, [self gettysburgAddress]);
      XCTAssertNil(error);
      XCTAssertEqual(fetcher.statusCode, (NSInteger)200);
      [expectation fulfill];
  }];
  [fetcher waitForCompletionWithTimeout:_timeoutInterval];

  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  NSArray *expectedURLStrings = @[
    @"/gettysburgaddress.txt.upload",
    @"/gettysburgaddress.txt.upload",
    @"/gettysburgaddress.txt.upload",
    @"/gettysburgaddress.txt.upload"
  ];
  NSArray *expectedCommands = @[
    @"upload",
    @"query",
    @"upload",
    @"upload, finalize"
  ];
  NSArray *expectedOffsets = @[
    @0,
    @0,
    @75000,
    @150000
  ];
  NSArray *expectedLengths = @[
    @75000,
    @0,
    @75000,
    @49000
  ];
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
  fetcher.sendProgressBlock = ^(int64_t bytesSent, int64_t totalBytesSent,
                                int64_t totalBytesExpectedToSend) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-retain-cycles"
    TestProgressBlock(fetcher, bytesSent, totalBytesSent, totalBytesExpectedToSend);
#pragma clang diagnostic pop
  };
  [fetcher setProperty:@20000
                forKey:kCancelAtKey];

  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
      XCTFail(@"Canceled fetcher should not have called back");
  }];
  XCTAssertTrue([fetcher waitForCompletionWithTimeout:_timeoutInterval], @"timed out");
  [self assertCallbacksReleasedForFetcher:fetcher];

  XCTAssertEqual(fnctr.fetchStarted, 3);
  XCTAssertEqual(fnctr.fetchStopped, 3);
  XCTAssertEqual(fnctr.uploadChunkFetchStarted, 2);
  XCTAssertEqual(fnctr.uploadChunkFetchStopped, 2);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
  XCTAssertEqual(fnctr.uploadLocationObtained, 1);
}

- (void)testBigDataChunkedUploadWithRetry {
  // Repeat the upload, and after sending 40,000 bytes the progress
  // callback will change the request URL for the next chunk fetch to make
  // it fail with a retryable status error.

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
  fetcher.retryBlock = ^(BOOL suggestedWillRetry, NSError *error,
                         GTMSessionFetcherRetryResponse response) {
    BOOL shouldRetry = shouldRetryUpload(fetcher, suggestedWillRetry, error);
    response(shouldRetry);
  };

  fetcher.sendProgressBlock = ^(int64_t bytesSent, int64_t totalBytesSent,
                                int64_t totalBytesExpectedToSend) {
    TestProgressBlock(fetcher, bytesSent, totalBytesSent, totalBytesExpectedToSend);
  };
#pragma clang diagnostic pop

  // Add a property to the fetcher that our progress callback will look for to
  // know when to retry the upload.
  [fetcher setProperty:@40000
                forKey:kRetryAtKey];

  fnctr = [[FetcherNotificationsCounter alloc] init];

  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
      XCTAssertEqualObjects(data, [self gettysburgAddress]);
      XCTAssertNil(error);
      XCTAssertEqual(fetcher.statusCode, (NSInteger)200);
  }];
  XCTAssertTrue([fetcher waitForCompletionWithTimeout:_timeoutInterval], @"timed out");
  [self assertCallbacksReleasedForFetcher:fetcher];

  NSArray *expectedURLStrings = @[ @"/gettysburgaddress.txt.upload",
                                   @"/gettysburgaddress.txt.upload",
                                   @"/gettysburgaddress.txt.upload",
                                   @"/gettysburgaddress.txt.upload",
                                   @"/gettysburgaddress.txt.upload" ];
  NSArray *expectedCommands = @[ @"upload",
                                 @"upload",
                                 @"query",
                                 @"upload",
                                 @"upload, finalize" ];
  NSArray *expectedOffsets = @[ @0,
                                @75000,
                                @0,
                                @75000,
                                @150000 ];
  NSArray *expectedLengths = @[ @75000,
                                @75000,
                                @0,
                                @75000,
                                @49000 ];
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

- (void)testBigDataChunkedUploadWithShortCircuit {
  // Force the server to prematurely finalize the upload on the initial request.
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

  // Our test server looks for zero content length as a cue to prematurely stop the upload.
  [fetcher setRequestValue:@"0" forHTTPHeaderField:@"X-Goog-Upload-Content-Length"];

  XCTestExpectation *expectation = [self expectationWithDescription:@"fetched"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
      XCTAssertNil(data);
      XCTAssertEqual(error.code, (NSInteger)501);
      [expectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  [self assertCallbacksReleasedForFetcher:fetcher];

  XCTAssertEqual(fnctr.fetchStarted, 1);
  XCTAssertEqual(fnctr.fetchStopped, 1);
  XCTAssertEqual(fnctr.uploadChunkFetchStarted, 0);
  XCTAssertEqual(fnctr.uploadChunkFetchStopped, 0);
  XCTAssertEqual(fnctr.retryDelayStarted, 0);
  XCTAssertEqual(fnctr.retryDelayStopped, 0);
  XCTAssertEqual(fnctr.uploadLocationObtained, 0);
}

@end
