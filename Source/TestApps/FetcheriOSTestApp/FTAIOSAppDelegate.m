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

// Sample iOS application for using GTMSessionFetcher.

#import "FTAIOSAppDelegate.h"
#import "GTMSessionFetcherLogging.h"

// Supports running a test case test within this app.
// Update the kTestCase... constants to run the desired test.
#define ENABLE_TEST_CASE_TESTING                0

// Supports the out of process download acceptance test, since unit tests are not feasible for it.
// When enabled, this app will download a test file and verify it downloaded the expected content.
// Tap the Home button after the progress indicator starts. This kills the app, while not stopping
// the download. The app will either be re-launched by the system if the download finishes or you
// can re-launch the app to re-attach to the download and continue updating the progress bar.
#define ENABLE_OUT_OF_PROCESS_DOWNLOAD_TESTING  0

// Supports the out of process chunked upload acceptance test, since unit tests are not feasible for
// it. When enabled, this app will upload a dynamically created test file to the test upload endpoint.
// Tap the Home button after the progress indicator starts. This kills the app, while not stopping
// the upload. The app will be re-launched when the current upload chunk finishes, so the app can
// queue up the next chunk, if applicable. You can re-launch the app to re-attach to the upload
// and continue updating the progress bar.
#define ENABLE_OUT_OF_PROCESS_UPLOAD_TESTING    0

#define ENABLE_POST_TESTING 0

#if ENABLE_TEST_CASE_TESTING

#import <XCTest/XCTest.h>

// Set to the XCTestCase derived class whose test method you want to invoke.
static NSString *const kTestCaseClassString = @"GTMSessionFetcherFetchingTest";
// Set to the method on testCaseClass that you want to invoke.
static NSString *const kTestCaseSelectorString = @"testCancelAndResumeFetchToFile";

#endif  // ENABLE_TEST_CASE_TESTING


#import "GTMSessionFetcherService.h"

#if ENABLE_OUT_OF_PROCESS_DOWNLOAD_TESTING

// Set to an URL, which will trigger a download.
#error Point kDownloadTestURLString URL string at a >= ~5 MB file.
static NSString *const kDownloadTestURLString = @"http://";

#endif  // ENABLE_OUT_OF_PROCESS_DOWNLOAD_TESTING


#if ENABLE_OUT_OF_PROCESS_UPLOAD_TESTING

#import "GTMSessionFetcherTestServer.h"
#import "GTMSessionUploadFetcher.h"

// Test upload > 2GB.
static NSString *const kUploadTestURLString = @"http://0.upload.google.com/null";  // null upload server.
static NSUInteger const kBigUploadChunkSize = 500 * 1024 * 1024;
static NSUInteger const kBigUploadChunkCount = 5;

#endif  // ENABLE_OUT_OF_PROCESS_UPLOAD_TESTING


#if ENABLE_POST_TESTING

#import "GTMSessionFetcherTestServer.h"

static NSUInteger const kPostDataSize = 512 * 1024;

#endif  // ENABLE_POST_TESTING


@interface FTAIOSAppRootViewController : UIViewController

@property(nonatomic, weak) IBOutlet UIProgressView *progressView;

- (void)displayProgress:(float)progress;

@end

@implementation FTAIOSAppRootViewController

@synthesize progressView = _progressView;

- (void)displayProgress:(float)progress {
  _progressView.progress = progress;
}

@end

@implementation FTAIOSAppDelegate {
  BOOL _wasSystemLaunchedForBackgroundURLSession;
#if ENABLE_OUT_OF_PROCESS_UPLOAD_TESTING
  UIAlertView *__weak _outOfProcessUploadCompletedAlertView;
#endif
}

@synthesize window = _window;

#pragma mark - UIApplicationDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
  [GTMSessionFetcher setLoggingEnabled:YES];
  return YES;
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
#if ENABLE_TEST_CASE_TESTING
  [self invokeTestSelectorString:kTestCaseSelectorString
                   onClassString:kTestCaseClassString];
#endif

#if ENABLE_POST_TESTING
  [self testPlainBodyPost];
#endif

#if ENABLE_OUT_OF_PROCESS_DOWNLOAD_TESTING
  if (!_wasSystemLaunchedForBackgroundURLSession) {
    [self testOutOfProcessDownload];
  } else {
    [self setProgress:1];
  }
#endif  // ENABLE_OUT_OF_PROCESS_DOWNLOAD_TESTING

#if ENABLE_OUT_OF_PROCESS_UPLOAD_TESTING
  // If we aren't already displaying the upload complete alert, start a new upload.
  if (!_outOfProcessUploadCompletedAlertView) {
    [self testOutOfProcessChunkedUpload];
  } else {
    [self setProgress:1];
  }
#endif  // ENABLE_OUT_OF_PROCESS_UPLOAD_TESTING
}

#if ENABLE_OUT_OF_PROCESS_DOWNLOAD_TESTING || ENABLE_OUT_OF_PROCESS_UPLOAD_TESTING

- (void)applicationWillResignActive:(UIApplication *)application {
  // Simulate crash
  NSLog(@"Exiting iOS test app on resigning active");
  exit(EXIT_SUCCESS);
}

- (void)application:(UIApplication *)application
    handleEventsForBackgroundURLSession:(NSString *)identifier
                      completionHandler:(void (^)())completionHandler {
  // Application was re-launched on completing an out-of-process download.
  _wasSystemLaunchedForBackgroundURLSession = YES;

  // Pass the URLSession info related to this re-launch to the fetcher.
  [GTMSessionFetcher application:application
      handleEventsForBackgroundURLSession:identifier
                        completionHandler:completionHandler];

  // Get the upload or download fetcher related to this re-launch and re-hook
  // up a completionHandler to it.
#if ENABLE_OUT_OF_PROCESS_UPLOAD_TESTING
  GTMSessionUploadFetcher *uploadFetcher =
      [GTMSessionUploadFetcher uploadFetcherForSessionIdentifier:identifier];
  if (uploadFetcher) {
    uploadFetcher.completionHandler = ^(NSData *data, NSError *error) {
      [self uploadCompletedWithError:error];
    };
    return;
  }
  // If we reach here, it wasn't an upload fetcher.
#endif

#if ENABLE_OUT_OF_PROCESS_DOWNLOAD_TESTING
  GTMSessionFetcher *fetcher = [GTMSessionFetcher fetcherWithSessionIdentifier:identifier];
  NSURL *destinationFileURL = fetcher.destinationFileURL;
  fetcher.completionHandler = ^(NSData *data, NSError *error) {
    [self downloadCompletedToFile:destinationFileURL error:error];
  };
#endif
}

#endif  // ENABLE_OUT_OF_PROCESS_DOWNLOAD_TESTING || ENABLE_OUT_OF_PROCESS_UPLOAD_TESTING

// The XCode Debug menu can initiate this background fetch..
- (void)application:(UIApplication *)application
    performFetchWithCompletionHandler:(void (^)(UIBackgroundFetchResult result))completionHandler {
  NSLog(@"%@", NSStringFromSelector(_cmd));

  GTMSessionFetcher *fetcher = [GTMSessionFetcher fetcherWithURLString:@"https://www.google.com"];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    if (error) {
      NSLog(@"Fetching www.google.com: %@", error);
      completionHandler(UIBackgroundFetchResultFailed);
    } else {
      NSLog(@"Fetched www.google.com (%d bytes)", (int)[data length]);
      completionHandler(UIBackgroundFetchResultNewData);
    }
  }];
}

#if ENABLE_TEST_CASE_TESTING

#pragma mark - Private

- (void)invokeTestSelectorString:(NSString *)testCaseSelectorString
                   onClassString:(NSString *)testCaseClassString {
  SEL testCaseSelector = NSSelectorFromString(testCaseSelectorString);

  XCTestCase *testCase =
      [[NSClassFromString(testCaseClassString) alloc] initWithSelector:testCaseSelector];
  NSAssert(testCase, @"Invalid testCase: %@ or selector: %@",
                     testCaseClassString, testCaseSelectorString);
  XCTestRun *testRun = [[XCTestRun alloc] initWithTest:testCase];
  [testCase invokeTest];

  NSString *message =
      [NSString stringWithFormat:@"Test count: %u\nFailure count: %u",
                                 [testRun testCaseCount], [testRun totalFailureCount]];
  UIAlertView *testResultsAlert =
      [[UIAlertView alloc] initWithTitle:@"Test Run Complete"
                                 message:message
                                delegate:nil
                       cancelButtonTitle:@"Cool"
                       otherButtonTitles:nil];
  [testResultsAlert show];
}

#endif  // ENABLE_TEST_CASE_TESTING

#if ENABLE_POST_TESTING

- (void)testPlainBodyPost {
  NSData *postData = [self ASCIIDataWithLength:kPostDataSize];
  GTMSessionFetcherService *service = [[GTMSessionFetcherService alloc] init];
  NSString *urlStr =
      @"http://posttestserver.com/post.php?dump&html&dir=gtm&status_code=200&sleep=5";
  GTMSessionFetcher *fetcher = [service fetcherWithURLString:urlStr];
  fetcher.allowedInsecureSchemes = @[ @"http" ];
  fetcher.bodyData = postData;
  [fetcher.mutableRequest setValue:@"text/plain" forHTTPHeaderField:@"Content-Type"];

  fetcher.sendProgressBlock = ^(int64_t bytesSent,
                                int64_t totalBytesSent,
                                int64_t totalBytesExpectedToSend) {
    NSLog(@"body post fetcher sent %lld/%lld", totalBytesSent, totalBytesExpectedToSend);
  };

  NSLog(@"Starting post fetch");
  [fetcher beginFetchWithCompletionHandler:^(NSData *receivedData, NSError *error) {
    NSString *responseStr = [[NSString alloc] initWithData:receivedData
                                                  encoding:NSUTF8StringEncoding];
    NSLog(@"Post fetch finished with error: %@\n%@", error, responseStr);
  }];
}

- (NSData *)ASCIIDataWithLength:(NSUInteger)length {
  NSMutableData *data = [NSMutableData dataWithLength:length];
  unsigned char *bytes = [data mutableBytes];
  for (NSUInteger idx = 0; idx < length; idx++) {
    bytes[idx] = 'A' + (unsigned char)(idx % 26);
  }
  return data;
}

#endif  // ENABLE_POST_TESTING

#if ENABLE_OUT_OF_PROCESS_DOWNLOAD_TESTING

- (void)testOutOfProcessDownload {
  NSArray *fetchers = [GTMSessionFetcher fetchersForBackgroundSessions];
  GTMSessionFetcher *fetcher = [fetchers firstObject];
  if (fetcher) {
    NSURL *destinationFileURL = fetcher.destinationFileURL;
    fetcher.completionHandler = ^(NSData *data, NSError *error) {
        [self downloadCompletedToFile:destinationFileURL error:error];
    };
  } else {
    NSURL *destinationFileURL = [self downloadDestinationFileURL];
    fetcher = [GTMSessionFetcher fetcherWithURLString:kDownloadTestURLString];
    fetcher.destinationFileURL = destinationFileURL;
    fetcher.useBackgroundSession = YES;
    fetcher.allowLocalhostRequest = YES;
    fetcher.allowedInsecureSchemes = @[ @"http" ];
    [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
        [self downloadCompletedToFile:destinationFileURL error:error];
    }];
  }
  fetcher.downloadProgressBlock = ^(int64_t bytesWritten,
                                    int64_t totalBytesWritten,
                                    int64_t totalBytesExpectedToWrite) {
      float progress = (float)totalBytesWritten / (float)totalBytesExpectedToWrite;
      [self setProgress:progress];
  };
}

- (NSURL *)downloadDestinationFileURL {
  NSString *destFileName =
      [NSString stringWithFormat:@"testOutOfProcessFetchToFile %@", [NSDate date]];
  NSString *destFilePath = [NSTemporaryDirectory() stringByAppendingPathComponent:destFileName];
  NSURL *destFileURL = [NSURL fileURLWithPath:destFilePath];
  return destFileURL;
}

- (void)downloadCompletedToFile:(NSURL *)downloadFileURL error:(NSError *)error {
  NSString *message = nil;
  BOOL didSucceed = NO;
  if (error) {
    message = [NSString stringWithFormat:@"Failure: %@", [error localizedDescription]];
  } else {
    NSData *downloadedData = [NSData dataWithContentsOfURL:downloadFileURL];
    NSURL *downloadURL = [NSURL URLWithString:kDownloadTestURLString];
    NSData *actualData = [NSData dataWithContentsOfURL:downloadURL];
    didSucceed = [downloadedData isEqual:actualData];
    if (didSucceed) {
      message = [NSString stringWithFormat:@"Data is correct"];
    } else {
      message = [NSString stringWithFormat:@"Data is incorrect\n%d of %d bytes\n%@",
                 (int)[downloadedData length], (int)[actualData length], error];
    }
    [self setProgress:1];
  }
  UIAlertView *downloadCompleteAlert =
      [[UIAlertView alloc] initWithTitle:@"Finished download"
                                 message:message
                                delegate:nil
                       cancelButtonTitle:(didSucceed ? @"Success" : @"Failed")
                       otherButtonTitles:nil];
  [downloadCompleteAlert show];
}

#endif  // ENABLE_OUT_OF_PROCESS_DOWNLOAD_TESTING

#if ENABLE_OUT_OF_PROCESS_UPLOAD_TESTING

- (void)testOutOfProcessChunkedUpload {
  NSArray *uploadFetchers = [GTMSessionUploadFetcher uploadFetchersForBackgroundSessions];
  GTMSessionUploadFetcher *uploadFetcher = [uploadFetchers firstObject];
  if (uploadFetcher) {
    uploadFetcher.completionHandler = ^(NSData *data, NSError *error) {
        [self uploadCompletedWithError:error];
    };
  } else {
    NSURL *requestURL = [NSURL URLWithString:kUploadTestURLString];
    NSMutableURLRequest *request =
        [NSMutableURLRequest requestWithURL:requestURL
                                cachePolicy:NSURLRequestReloadIgnoringCacheData
                            timeoutInterval:60*60];
    NSURL *bigFileURL = [self bigFileToUploadURL];
    uploadFetcher =
        [GTMSessionUploadFetcher uploadFetcherWithRequest:request
                                           uploadMIMEType:@"text/plain"
                                                chunkSize:kBigUploadChunkSize
                                           fetcherService:nil];
    uploadFetcher.allowedInsecureSchemes = @[ @"http" ];
    uploadFetcher.uploadFileURL = bigFileURL;
    uploadFetcher.retryEnabled = YES;

    // Start the upload.
    [uploadFetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
        [self uploadCompletedWithError:error];
    }];
  }
  uploadFetcher.sendProgressBlock =
      ^(int64_t bytesSent, int64_t totalBytesSent, int64_t totalBytesExpectedToSend) {
          float progress = (float)totalBytesSent / (float)totalBytesExpectedToSend;
          [self setProgress:progress];
  };
}

- (NSURL *)bigFileToUploadURL {
  // Write the big data into a temp file.
  NSString *bigFileName = @"GTMChunkedUploadTest_BigFile";
  NSString *bigFilePath = [NSTemporaryDirectory() stringByAppendingPathComponent:bigFileName];
  NSData *bigDataChunk =
      [GTMSessionFetcherTestServer generatedBodyDataWithLength:kBigUploadChunkSize];
  if (![[NSFileManager defaultManager] createFileAtPath:bigFilePath
                                               contents:bigDataChunk
                                             attributes:nil]) {
    return nil;
  }
  NSFileHandle *bigFile = [NSFileHandle fileHandleForWritingAtPath:bigFilePath];
  [bigFile seekToEndOfFile];
  for (NSUInteger chunkCount = 2; chunkCount <= kBigUploadChunkCount; ++chunkCount) {
    [bigFile writeData:bigDataChunk];
  }
  NSURL *bigFileURL = [NSURL fileURLWithPath:bigFilePath];
  return bigFileURL;
}

- (void)uploadCompletedWithError:(NSError *)error {
  NSString *message = nil;
  if (error) {
    message = [NSString stringWithFormat:@"Failure: %@", [error localizedDescription]];
  } else {
    message = @"Upload successful";
    [self setProgress:1];
  }
  UIAlertView *uploadCompletedAlertView =
      [[UIAlertView alloc] initWithTitle:@"Finished upload"
                                 message:message
                                delegate:nil
                       cancelButtonTitle:(error == nil ? @"Success" : @"Failed")
                       otherButtonTitles:nil];
  [uploadCompletedAlertView show];
  _outOfProcessUploadCompletedAlertView = uploadCompletedAlertView;
}

#endif

- (void)setProgress:(float)progress {
  FTAIOSAppRootViewController *rootViewController =
      (FTAIOSAppRootViewController *)_window.rootViewController;
  [rootViewController displayProgress:progress];
}

@end
