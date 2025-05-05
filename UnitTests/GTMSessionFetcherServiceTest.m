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

#import <XCTest/XCTest.h>
#include <stdlib.h>
#include <sys/sysctl.h>
#include <unistd.h>

#import <GTMSessionFetcher/GTMSessionFetcherService.h>
#import "GTMSessionFetcherService+Internal.h"

#import "GTMSessionFetcherFetchingTest.h"
#import "GTMSessionFetcherTestServer.h"

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

static NSDictionary<NSString *, NSString *> *FetcherHeadersWithoutUserAgent(
    GTMSessionFetcher *fetcher) {
  NSMutableDictionary<NSString *, NSString *> *headers =
      [fetcher.request.allHTTPHeaderFields mutableCopy];
  [headers removeObjectForKey:@"User-Agent"];
  return headers;
}

typedef void (^FetcherWillStartBlock)(GTMSessionFetcher *,
                                      GTMFetcherDecoratorFetcherWillStartCompletionHandler);

@interface GTMSessionFetcherTestDecorator : NSObject <GTMFetcherDecoratorProtocol>

@property(nonatomic, readonly) FetcherWillStartBlock fetcherWillStartBlock;
@property(nonatomic, readonly) BOOL synchronous;
@property(nonatomic, readonly, nullable) NSData *fetchedData;
@property(nonatomic, readonly, nullable) NSError *fetchError;

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithHeaders:(NSDictionary<NSString *, NSString *> *)headersToAdd;
- (instancetype)initWithHeadersSynchronous:(NSDictionary<NSString *, NSString *> *)headersToAdd;
- (instancetype)initWithFetcherWillStartBlock:(FetcherWillStartBlock)fetcherWillStartBlock
                                  synchronous:(BOOL)synchronous NS_DESIGNATED_INITIALIZER;

@end

@implementation GTMSessionFetcherTestDecorator

@synthesize fetcherWillStartBlock = _fetcherWillStartBlock, synchronous = _synchronous,
            fetchedData = _fetchedData, fetchError = _fetchError;

- (instancetype)initWithHeaders:(NSDictionary<NSString *, NSString *> *)headersToAdd {
  return [self
      initWithFetcherWillStartBlock:^(
          GTMSessionFetcher *fetcher,
          GTMFetcherDecoratorFetcherWillStartCompletionHandler completionHandler) {
        NSMutableURLRequest *request = [fetcher.request mutableCopy];
        for (NSString *field in headersToAdd) {
          [request setValue:headersToAdd[field] forHTTPHeaderField:field];
        }
        completionHandler(request, /*error=*/nil);
      }
                        synchronous:NO];
}

- (instancetype)initWithHeadersSynchronous:(NSDictionary<NSString *, NSString *> *)headersToAdd {
  return [self
      initWithFetcherWillStartBlock:^(
          GTMSessionFetcher *fetcher,
          GTMFetcherDecoratorFetcherWillStartCompletionHandler completionHandler) {
        NSMutableURLRequest *request = [fetcher.request mutableCopy];
        for (NSString *field in headersToAdd) {
          [request setValue:headersToAdd[field] forHTTPHeaderField:field];
        }
        completionHandler(request, /*error=*/nil);
      }
                        synchronous:YES];
}

- (instancetype)initWithFetcherWillStartBlock:(FetcherWillStartBlock)fetcherWillStartBlock
                                  synchronous:(BOOL)synchronous {
  self = [super init];
  if (self) {
    _fetcherWillStartBlock = fetcherWillStartBlock;
    _synchronous = synchronous;
  }
  return self;
}

- (void)fetcherWillStart:(GTMSessionFetcher *)fetcher
       completionHandler:(GTMFetcherDecoratorFetcherWillStartCompletionHandler)handler {
  if (self.synchronous) {
    _fetcherWillStartBlock(fetcher, handler);
  } else {
    __weak __typeof__(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
      __strong __typeof__(self) strongSelf = weakSelf;
      if (!strongSelf) {
        return;
      }
      strongSelf.fetcherWillStartBlock(fetcher, handler);
    });
  }
}

- (void)fetcherDidFinish:(GTMSessionFetcher *)fetcher
                withData:(nullable NSData *)data
                   error:(nullable NSError *)error
       completionHandler:(void (^)(void))handler {
  _fetchedData = [data copy];
  _fetchError = error;
  if (self.synchronous) {
    handler();
  } else {
    dispatch_async(dispatch_get_main_queue(), ^{
      handler();
    });
  }
}

@end

@interface GTMSessionFetcherService (GTMSessionFetcherServiceInternal)

- (id)delegateDispatcherForFetcher:(GTMSessionFetcher *)fetcher;

@end

@interface GTMSessionFetcherServiceTestObjectProxy : NSProxy
@end

@implementation GTMSessionFetcherServiceTestObjectProxy {
  id _proxiedObject;
}

+ (instancetype)proxyForObject:(id)object {
  GTMSessionFetcherServiceTestObjectProxy *proxy = [self alloc];
  proxy->_proxiedObject = object;
  return proxy;
}

- (BOOL)isKindOfClass:(Class)aClass {
  return [_proxiedObject isKindOfClass:aClass];
}

- (void)forwardInvocation:(NSInvocation *)invocation {
  [invocation invokeWithTarget:_proxiedObject];
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
  return [_proxiedObject methodSignatureForSelector:sel];
}

@end

@interface GTMSessionFetcherServiceTest : XCTestCase {
  GTMSessionFetcherTestServer *_testServer;
  BOOL _isServerRunning;
  NSTimeInterval _timeoutInterval;
}

@end

// File available in Tests folder.
static NSString *const kValidFileName = @"gettysburgaddress.txt";

@implementation GTMSessionFetcherServiceTest

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

- (void)setUp {
  _testServer = [[GTMSessionFetcherTestServer alloc] init];
  _isServerRunning = _testServer != nil;
  _timeoutInterval = IsCurrentProcessBeingDebugged() ? 3600.0 : 30.0;

  XCTAssertTrue(_isServerRunning,
                @">>> http test server failed to launch; skipping service tests\n");

  [super setUp];
}

- (void)tearDown {
  _testServer = nil;
  _isServerRunning = NO;

  [super tearDown];
}

- (void)testFetcherService {
  if (!_isServerRunning) return;

  // Utility blocks for counting array entries for a specific host.
  NSUInteger (^URLsPerHost)(NSArray *, NSString *) = ^(NSArray *URLs, NSString *host) {
    NSUInteger counter = 0;
    for (NSURL *url in URLs) {
      if ([host isEqual:url.host]) {
        counter++;
      }
    }
    return counter;
  };

  NSUInteger (^FetchersPerHost)(NSArray *, NSString *) = ^(NSArray *fetchers, NSString *host) {
    NSArray *fetcherURLs = [fetchers valueForKeyPath:@"request.URL"];
    return URLsPerHost(fetcherURLs, host);
  };

  // Utility block for finding the minimum priority fetcher for a specific host.
  NSInteger (^PriorityPerHost)(NSArray *, NSString *) = ^(NSArray *fetchers, NSString *host) {
    NSInteger val = NSIntegerMax;
    for (GTMSessionFetcher *fetcher in fetchers) {
      if ([host isEqual:fetcher.request.URL.host]) {
        val = MIN(val, fetcher.servicePriority);
      }
    }
    return val;
  };

  // We'll verify we fetched from the server the same data that is on disk.
  NSData *gettysburgAddress = [_testServer documentDataAtPath:kValidFileName];

  // We'll create several fetchers.  Only 2 should run simultaneously (per host).
  // 1 should fail; a few will be stopped the rest should succeeed.
  const NSUInteger kMaxRunningFetchersPerHost = 2;

  NSString *const kUserAgent = @"ServiceTest-UA";

  GTMSessionFetcherService *service = [[GTMSessionFetcherService alloc] init];
  service.maxRunningFetchersPerHost = kMaxRunningFetchersPerHost;
  service.userAgent = kUserAgent;
  service.allowLocalhostRequest = YES;

  // Make URLs for a valid fetch, a fetch that returns a status error,
  // and a valid fetch with a different host.
  NSURL *validFileURL = [_testServer localURLForFile:kValidFileName];

  NSString *invalidFile = [kValidFileName stringByAppendingString:@"?status=400"];
  NSURL *invalidFileURL = [_testServer localURLForFile:invalidFile];

  NSString *stopSilentFile = [kValidFileName stringByAppendingString:@"?stop=silent"];
  NSURL *stopSilentFileURL = [_testServer localURLForFile:stopSilentFile];

  NSString *stopCallbackFile = [kValidFileName stringByAppendingString:@"?stop=callback"];
  NSURL *stopCallbackFileURL = [_testServer localURLForFile:stopCallbackFile];

  NSURL *altValidURL = [_testServer localv6URLForFile:invalidFile];

  XCTAssertEqualObjects(validFileURL.host, @"localhost", @"unexpected host");
  XCTAssertEqualObjects(invalidFileURL.host, @"localhost", @"unexpected host");
  XCTAssertEqualObjects(stopSilentFileURL.host, @"localhost", @"unexpected host");
  XCTAssertEqualObjects(stopCallbackFileURL.host, @"localhost", @"unexpected host");
  XCTAssertEqualObjects(altValidURL.host, @"::1", @"unexpected host");

  // Make an array with the urls from the different hosts, including one
  // that will fail with a status 400 error.
  NSMutableArray *urlArray = [NSMutableArray array];
  for (int idx = 1; idx <= 4; idx++) [urlArray addObject:validFileURL];
  [urlArray addObject:invalidFileURL];
  // Ensure things will get queued due to the per host limit.
  XCTAssertGreaterThan(urlArray.count, kMaxRunningFetchersPerHost);
  for (int idx = 1; idx <= 5; idx++) [urlArray addObject:validFileURL];
  for (int idx = 1; idx <= 3; idx++) [urlArray addObject:stopSilentFileURL];
  for (int idx = 1; idx <= 5; idx++) [urlArray addObject:altValidURL];
  for (int idx = 1; idx <= 3; idx++) [urlArray addObject:stopCallbackFileURL];
  for (int idx = 1; idx <= 5; idx++) [urlArray addObject:validFileURL];
  for (int idx = 1; idx <= 2; idx++) [urlArray addObject:stopCallbackFileURL];
  for (int idx = 1; idx <= 2; idx++) [urlArray addObject:stopSilentFileURL];
  NSUInteger totalNumberOfFetchers = urlArray.count;

  // These are used to track the fetchers via notifications.
  __block NSMutableArray *pending = [NSMutableArray array];
  __block NSMutableArray *running = [NSMutableArray array];
  __block NSMutableArray *completed = [NSMutableArray array];
  // Fetchers that will get stopped.
  NSMutableArray *stopped = [NSMutableArray array];

  NSInteger priorityVal = 0;

  // Create all the fetchers.
  NSMutableArray *fetchersInFlight = [NSMutableArray array];
  NSMutableArray *observers = [NSMutableArray array];
  NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
  NSMutableArray *expectations = [NSMutableArray array];
  for (NSURL *fileURL in urlArray) {
    GTMSessionFetcher *fetcher = [service fetcherWithURL:fileURL];
    XCTestExpectation *expectation =
        [self expectationWithDescription:(id _Nonnull)fileURL.absoluteString];
    [expectations addObject:expectation];

    // Fetcher start notification.
    id startObserver = [nc
        addObserverForName:kGTMSessionFetcherStartedNotification
                    object:fetcher
                     queue:nil
                usingBlock:^(NSNotification *note) {
                  XCTAssertTrue([pending containsObject:fetcher]);

                  // Verify that we have at most two fetchers running for this fetcher's host.
                  [running addObject:fetcher];
                  [pending removeObject:fetcher];

                  NSURLRequest *fetcherReq = fetcher.request;
                  NSURL *fetcherReqURL = fetcherReq.URL;

                  NSString *host = fetcherReqURL.host;
                  NSUInteger numberRunning = FetchersPerHost(running, host);
                  XCTAssertTrue(numberRunning > 0, @"count error");
                  XCTAssertTrue(numberRunning <= kMaxRunningFetchersPerHost, @"too many running");

                  NSInteger pendingPriority = PriorityPerHost(pending, host);
                  XCTAssertTrue(fetcher.servicePriority <= pendingPriority,
                                @"a pending fetcher has greater priority");

                  XCTAssert([service.issuedFetchers containsObject:fetcher], @"%@", fetcher);

                  NSArray *matches = [service issuedFetchersWithRequestURL:fetcherReqURL];
                  NSUInteger idx = NSNotFound;
                  if (matches) {
                    idx = [matches indexOfObjectIdenticalTo:fetcher];
                  }
                  XCTAssertTrue(idx != NSNotFound, @"Missing %@ in %@", fetcherReqURL, matches);
                  NSURL *fakeURL = [NSURL URLWithString:@"http://example.com/bad"];
                  matches = [service issuedFetchersWithRequestURL:fakeURL];
                  XCTAssertEqual(matches.count, (NSUInteger)0);

                  NSString *agent = [fetcherReq valueForHTTPHeaderField:@"User-Agent"];
                  XCTAssertEqualObjects(agent, kUserAgent);
                }];
    [observers addObject:startObserver];

    // Fetcher stopped notification.
    id stopObserver =
        [nc addObserverForName:kGTMSessionFetcherStoppedNotification
                        object:fetcher
                         queue:nil
                    usingBlock:^(NSNotification *note) {
                      XCTAssertTrue([running containsObject:fetcher]);

                      // Verify that we only have two fetchers running.
                      [completed addObject:fetcher];
                      [running removeObject:fetcher];

                      // A fetcher that gets stopped should not trigger any notifications.
                      NSURL *fetcherReqURL = fetcher.request.URL;
                      XCTAssertFalse([fetcherReqURL.query hasPrefix:@"stop="]);

                      NSString *host = fetcherReqURL.host;
                      NSUInteger numberRunning = FetchersPerHost(running, host);
                      NSUInteger numberPending = FetchersPerHost(pending, host);
                      NSUInteger numberCompleted = FetchersPerHost(completed, host);
                      NSUInteger numberStopped = FetchersPerHost(stopped, host);

                      XCTAssertLessThanOrEqual(numberRunning, kMaxRunningFetchersPerHost,
                                               @"too many running");
                      XCTAssertLessThanOrEqual(
                          numberPending + numberRunning + numberCompleted + numberStopped,
                          URLsPerHost(urlArray, host),
                          @"%d issued running (pending:%u running:%u completed:%u stopped: %u)",
                          (unsigned int)totalNumberOfFetchers, (unsigned int)numberPending,
                          (unsigned int)numberRunning, (unsigned int)numberCompleted,
                          (unsigned int)numberStopped);

                      // The stop notification may be posted on the main thread before or after the
                      // fetcher service has been notified the fetcher has stopped.
                    }];
    [observers addObject:stopObserver];

    // Set the fetch priority to a value that cycles 0, 1, -1, 0, ...
    priorityVal++;
    if (priorityVal > 1) priorityVal = -1;
    fetcher.servicePriority = priorityVal;

    BOOL stopFetch = [fileURL.query hasPrefix:@"stop="];
    BOOL stopWithCallback = [fileURL.query isEqual:@"stop=callback"];
    if (stopWithCallback) {
      fetcher.stopFetchingTriggersCompletionHandler = YES;
    }

    if (stopFetch) {
      // All the fetchers that will be stopped should end up queued, as we're
      // also testing that they are handled correctly for callbacks and the
      // general per host limits. So make sure we've got atleast the max per
      // host pending already.
      NSUInteger numberPending = FetchersPerHost(pending, fetcher.request.URL.host);
      XCTAssertGreaterThanOrEqual(numberPending, kMaxRunningFetchersPerHost);
    } else {
      [pending addObject:fetcher];
    }

    // Start this fetcher.
    [fetchersInFlight addObject:fetcher];
    [fetcher beginFetchWithCompletionHandler:^(NSData *fetchData, NSError *fetchError) {
      // Callback.
      XCTAssert([fetchersInFlight containsObject:fetcher]);
      [fetchersInFlight removeObjectIdenticalTo:fetcher];

      // The query should be empty except for the URL with a status code or the ones
      // marked for stopping.
      NSString *query = [fetcher.request.URL query];
      BOOL isValidRequest = (query.length == 0);
      if (isValidRequest) {
        XCTAssertEqualObjects(fetchData, gettysburgAddress, @"Bad fetch data");
        XCTAssertNil(fetchError, @"unexpected %@ %@", fetchError, fetchError.userInfo);
      } else {
        if ([query isEqual:@"stop=callback"]) {
          XCTAssertEqualObjects(fetchError.domain, kGTMSessionFetcherErrorDomain,
                                @"expected error");
          XCTAssertEqual(fetchError.code, GTMSessionFetcherErrorUserCancelled, @"expected error");
        } else if ([query hasPrefix:@"stop="]) {
          XCTFail(@"Should not have gotten completion for stopped call");
        } else {
          // This is the query with ?status=400.
          XCTAssertEqual(fetchError.code, (NSInteger)400, @"expected error");
        }
      }
      [expectation fulfill];
    }];
    if (stopFetch) {
      [fetcher stopFetching];
      [stopped addObject:fetcher];
      if (stopWithCallback) {
        // The completion will remove it from inflight and complete the expectation.
      } else {
        [fetchersInFlight removeObject:fetcher];
        [expectation fulfill];
      }
    }
  }

  [self waitForExpectations:expectations timeout:_timeoutInterval];

  // Check the notification counts.
  XCTAssertEqual(pending.count, (NSUInteger)0, @"still pending: %@", pending);
  XCTAssertEqual(running.count, (NSUInteger)0, @"still running: %@", running);
  XCTAssertEqual(completed.count + stopped.count, (NSUInteger)totalNumberOfFetchers, @"incomplete");
  // All the expected callbacks happened.
  XCTAssertEqual(fetchersInFlight.count, (NSUInteger)0, @"Uncompleted: %@", fetchersInFlight);

  XCTAssertEqual([service numberOfFetchers], (NSUInteger)0, @"service non-empty");

  for (id observer in observers) {
    [[NSNotificationCenter defaultCenter] removeObserver:observer];
  }
}

- (void)testConcurrentCallbackQueue {
  if (!_isServerRunning) return;

  GTMSessionFetcherService *service = [[GTMSessionFetcherService alloc] init];
  service.allowLocalhostRequest = YES;
  [service setConcurrentCallbackQueue:dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0)];

  XCTestExpectation *progressExpectation = [self expectationWithDescription:@"progress block"];
  XCTestExpectation *completionExpectation = [self expectationWithDescription:@"completion"];

  NSURL *fileURL = [_testServer localURLForFile:kValidFileName];
  GTMSessionFetcher *fetcher = [service fetcherWithURL:fileURL];
  fetcher.receivedProgressBlock = ^(int64_t bytesReceived, int64_t totalBytesReceived) {
    // Sleep for a time before fulfilling the expectation.
    sleep(1);
    [progressExpectation fulfill];
  };

  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(1, 1);
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    [completionExpectation fulfill];
  }];

  // The progress block should be executed prior to the completion block, even though
  // they will be dispatched at essentially the same time; if they are executing on
  // the global concurrent queue, the completion will fulfill its expectation first
  // due to the sleep in the progress block.
  [self waitForExpectations:@[ progressExpectation, completionExpectation ]
                    timeout:_timeoutInterval
               enforceOrder:YES];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();
}

- (void)testStopAllFetchers {
  [self stopAllFetchersHelperUseStopAllAPI:YES callbacksAfterStop:NO];
}

- (void)testStopAllFetchersSeparately {
  [self stopAllFetchersHelperUseStopAllAPI:NO callbacksAfterStop:NO];
}

- (void)testStopAllFetchersWithCallbacks {
  [self stopAllFetchersHelperUseStopAllAPI:YES callbacksAfterStop:YES];
}

- (void)testStopAllFetchersSeparatelyWithCallbacks {
  [self stopAllFetchersHelperUseStopAllAPI:NO callbacksAfterStop:YES];
}

- (void)stopAllFetchersHelperUseStopAllAPI:(BOOL)useStopAllAPI
                        callbacksAfterStop:(BOOL)doStopCallbacks {
  if (!_isServerRunning) return;

  GTMSessionFetcherService *service = [[GTMSessionFetcherService alloc] init];
  service.maxRunningFetchersPerHost = 2;
  service.allowLocalhostRequest = YES;

  // Create three fetchers for each of two URLs, so there should be
  // two running and one delayed for each.
  NSURL *validFileURL = [_testServer localURLForFile:kValidFileName];
  NSURL *altValidURL = [_testServer localv6URLForFile:kValidFileName];

  // Add three fetches for each URL.
  NSArray *urlArray =
      @[ validFileURL, altValidURL, validFileURL, altValidURL, validFileURL, altValidURL ];

  // Expect two started/stopped fetchers for each host, for 4 total.
  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(4, 4);

  XCTestExpectation *fetcherCallbackExpectation =
      [[XCTNSNotificationExpectation alloc] initWithName:@"callback"];
  if (doStopCallbacks) {
    fetcherCallbackExpectation.expectedFulfillmentCount = urlArray.count;
    fetcherCallbackExpectation.assertForOverFulfill = YES;
  } else {
    // No callbacks, just complete this expectation now.
    [fetcherCallbackExpectation fulfill];
  }

  // Create and start all the fetchers.
  for (NSURL *fileURL in urlArray) {
    GTMSessionFetcher *fetcher = [service fetcherWithURL:fileURL];
    fetcher.stopFetchingTriggersCompletionHandler = doStopCallbacks;
    [fetcher beginFetchWithCompletionHandler:^(NSData *fetchData, NSError *fetchError) {
      if (doStopCallbacks) {
        // Since they are getting stopped, they should all produce errors, not data.
        XCTAssertNil(fetchData);
        XCTAssertNotNil(fetchError);
        [fetcherCallbackExpectation fulfill];
      } else {
        // We shouldn't reach any of the callbacks.
        XCTFail(@"Fetcher completed but should have been stopped");
      }
    }];
  }

  // Two hosts.
  XCTAssertEqual(service.runningFetchersByHost.count, (NSUInteger)2, @"hosts running");
  XCTAssertEqual(service.delayedFetchersByHost.count, (NSUInteger)2, @"hosts delayed");

  // We should see two fetchers running and one delayed for each host.
  NSArray *localhosts = [service.runningFetchersByHost objectForKey:@"localhost"];
  XCTAssertEqual(localhosts.count, (NSUInteger)2, @"hosts running");
  NSArray *localv6hosts = [service.runningFetchersByHost objectForKey:@"::1"];
  XCTAssertEqual(localv6hosts.count, (NSUInteger)2, @"hosts running");

  localhosts = [service.delayedFetchersByHost objectForKey:@"localhost"];
  XCTAssertEqual(localhosts.count, (NSUInteger)1, @"hosts delayed");
  localv6hosts = [service.delayedFetchersByHost objectForKey:@"::1"];
  XCTAssertEqual(localv6hosts.count, (NSUInteger)1, @"hosts delayed");

  XCTAssertNil(service.stoppedAllFetchersDate);

  if (useStopAllAPI) {
    [service stopAllFetchers];
  } else {
    // Stop the delayed fetchers first so a delayed one doesn't get started when canceling
    // a running one.
    NSArray *delayedFetchersByHost = service.delayedFetchersByHost.allValues;
    NSArray *runningFetchersByHost = service.runningFetchersByHost.allValues;
    for (NSArray *delayedForHost in delayedFetchersByHost) {
      NSArray *delayed = [delayedForHost copy];
      for (GTMSessionFetcher *fetcher in delayed) {
        [fetcher stopFetching];
      }
    }
    for (NSArray *runningForHost in runningFetchersByHost) {
      NSArray *running = [runningForHost copy];
      for (GTMSessionFetcher *fetcher in running) {
        [fetcher stopFetching];
      }
    }
  }

  [self waitForExpectations:@[
    fetcherCallbackExpectation, fetcherStartedExpectation__, fetcherStoppedExpectation__
  ]
                    timeout:10.0];

  XCTAssertEqual(service.runningFetchersByHost.count, (NSUInteger)0, @"hosts running");
  XCTAssertEqual(service.delayedFetchersByHost.count, (NSUInteger)0, @"hosts delayed");

  if (useStopAllAPI) {
    XCTAssertNotNil(service.stoppedAllFetchersDate);
  } else {
    XCTAssertNil(service.stoppedAllFetchersDate);
  }
}

- (void)testSessionReuse {
  if (!_isServerRunning) return;

  GTMSessionFetcherService *service = [[GTMSessionFetcherService alloc] init];
  service.allowLocalhostRequest = YES;

  const NSTimeInterval kUnusedSessionTimeout = 3.0;
  service.unusedSessionTimeout = kUnusedSessionTimeout;

  NSURL *validFileURL = [_testServer localURLForFile:kValidFileName];

  NSArray *urlArray = @[ validFileURL, validFileURL, validFileURL, validFileURL ];
  NSMutableSet *uniqueSessions = [NSMutableSet set];
  NSMutableSet *uniqueTasks = [NSMutableSet set];

  // Creating tasks for the array twice, so double expected counts.
  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(urlArray.count * 2, urlArray.count * 2);

  //
  // Create and start all the fetchers without reusing the session.
  //
  service.reuseSession = NO;
  XCTestExpectation *completionExpectation =
      [self expectationWithDescription:@"non-reuse completion"];
  completionExpectation.expectedFulfillmentCount = urlArray.count;
  for (NSURL *fileURL in urlArray) {
    GTMSessionFetcher *fetcher = [service fetcherWithURL:fileURL];
    [fetcher beginFetchWithCompletionHandler:^(NSData *fetchData, NSError *fetchError) {
      XCTAssertNotNil(fetchData);
      XCTAssertNil(fetchError);
      [completionExpectation fulfill];
    }];
    [uniqueSessions addObject:[NSValue valueWithNonretainedObject:fetcher.session]];
    [uniqueTasks addObject:[NSValue valueWithNonretainedObject:fetcher.sessionTask]];

    XCTAssertEqual(fetcher.session.delegate, fetcher);
  }

  [self waitForExpectations:@[ completionExpectation ] timeout:_timeoutInterval];

  // We should have one unique session per fetcher.
  XCTAssertEqual(uniqueTasks.count, urlArray.count);
  XCTAssertEqual(uniqueSessions.count, urlArray.count, @"%@", uniqueSessions);
  XCTAssertNil([service session]);
  XCTAssertNil([service sessionDelegate]);

  // Inside the delegate dispatcher, there should now be a nil map of tasks to fetchers.
  NSDictionary *taskMap = [(id)service.sessionDelegate valueForKey:@"taskToFetcherMap"];
  XCTAssertNil(taskMap);

  //
  // Now reuse the session for multiple fetches.
  //
  [uniqueSessions removeAllObjects];
  [uniqueTasks removeAllObjects];
  [service resetSession];

  service.reuseSession = YES;
  completionExpectation = [self expectationWithDescription:@"reuse completion"];
  completionExpectation.expectedFulfillmentCount = urlArray.count;
  for (NSURL *fileURL in urlArray) {
    GTMSessionFetcher *fetcher = [service fetcherWithURL:fileURL];
    [fetcher beginFetchWithCompletionHandler:^(NSData *fetchData, NSError *fetchError) {
      XCTAssertNotNil(fetchData);
      XCTAssertNil(fetchError);
      [completionExpectation fulfill];
    }];
    [uniqueSessions addObject:[NSValue valueWithNonretainedObject:fetcher.session]];
    [uniqueTasks addObject:[NSValue valueWithNonretainedObject:fetcher.sessionTask]];

    XCTAssertEqual(fetcher.session.delegate, service.sessionDelegate);
  }

  [self waitForExpectations:@[ completionExpectation ] timeout:_timeoutInterval];

  // We should have used two sessions total.
  XCTAssertEqual(uniqueTasks.count, urlArray.count);
  XCTAssertEqual(uniqueSessions.count, (NSUInteger)1, @"%@", uniqueSessions);

  // Inside the delegate dispatcher, there should be an empty map of tasks to fetchers.
  taskMap = [(id)service.sessionDelegate valueForKey:@"taskToFetcherMap"];
  XCTAssertEqualObjects(taskMap, @{});

  // Because we set kUnusedSessionDiscardInterval to 3 seconds earlier, there
  // should still be a remembered session immediately after the fetches finish.
  NSURLSession *session = [service session];
  XCTAssertNotNil(session);

  // Wait up to 5 seconds for the sessions to become invalid.
  XCTestExpectation *exp =
      [self expectationForNotification:kGTMSessionFetcherServiceSessionBecameInvalidNotification
                                object:service
                               handler:^(NSNotification *notification) {
                                 NSURLSession *invalidSession = [notification.userInfo
                                     objectForKey:kGTMSessionFetcherServiceSessionKey];
                                 XCTAssertEqualObjects(invalidSession, session);
                                 return YES;
                               }];

  [self waitForExpectations:@[ exp ] timeout:_timeoutInterval];

  // Ensure all started fetchers have stopped.
  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  // Unlike right after the fetches finish, now the session should be nil.
  XCTAssertNil(service.session);
}

- (void)testSessionAbandonment {
  if (!_isServerRunning) return;

  GTMSessionFetcherService *service = [[GTMSessionFetcherService alloc] init];
  service.allowLocalhostRequest = YES;
  service.reuseSession = YES;
  service.maxRunningFetchersPerHost = 2;

  // A race condition exists that was exposed by changing the service's sessionDelegateQueue
  // from the mainQueue to a serial background queue. Because of that change, this race condition
  // began to manifest as a flake in this test.
  //
  // Inside beginFetchWithCompletionHandler:, the fetcher gets the NSURLSession from the fetcher
  // service before creating its NSURLSessionTask. The locks protecting the NSURLSession within
  // the service only protect it during that getter call, and it's possible that before the
  // fetcher's NSURLSessionTask is created another thread could come along and reset the
  // NSURLSession, invalidating it and preventing new NSURLSessionTasks from being created on it.
  //
  // Migrating from the main to a background queue for the session's delegate queue made it
  // possible for this test to encounter this race condition, as the first fetcher's completion
  // handler was never be called before all fetchers were created and the test waited for all
  // fetchers to be complete.
  //
  // This race condition is similar to another one known in the service's delegate dispatcher,
  // and the most sure way to fix is likely to refactor to require every fetcher is created from
  // a service, letting the service protect the entire process of creating the NSURLSession and
  // the session tasks.
  //
  // Until then, stopping this test from flaking by setting the session delegate queue to
  // be the main queue.
  service.sessionDelegateQueue = [NSOperationQueue mainQueue];

  const NSTimeInterval kUnusedSessionTimeout = 3.0;
  service.unusedSessionTimeout = kUnusedSessionTimeout;

  XCTestExpectation *expectation = [self expectationWithDescription:@"fetcher completions"];

  NSURL *validFileURL = [_testServer localURLForFile:kValidFileName];
  NSArray *urlArray = @[ validFileURL, validFileURL, validFileURL, validFileURL ];
  [expectation setExpectedFulfillmentCount:urlArray.count];

  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(urlArray.count, urlArray.count);

  __block int numberOfCallsBack = 0;
  __block int numberOfErrors = 0;

  for (NSURL *fileURL in urlArray) {
    GTMSessionFetcher *fetcher = [service fetcherWithURL:fileURL];
    [fetcher beginFetchWithCompletionHandler:^(NSData *fetchData, NSError *fetchError) {
      if (fetchError != nil) {
        ++numberOfErrors;
      }

      // If NSURLSession had a suspended task, it won't have called its delegate,
      // so the fetcher will have manufactured a callback with a cancellation error.
      XCTAssert((fetchData != nil && fetchError == nil) ||
                    (fetchData == nil && fetchError.code == NSURLErrorCancelled),
                @"error=%@, data=%@", fetchError, fetchData);

      // On the first completion, we'll reset the session.
      ++numberOfCallsBack;
      if (numberOfCallsBack == 1) {
        [service resetSession];

        // Inside the delegate dispatcher, there should be a nil map of tasks to fetchers.
        NSDictionary *taskMap = [(id)service.sessionDelegate valueForKey:@"taskToFetcherMap"];
        XCTAssertNil(taskMap);
      }

      [expectation fulfill];
    }];
  }
  [self waitForExpectations:@[ expectation ] timeout:_timeoutInterval];

  // Here we verify that all fetchers were called back.
  XCTAssertEqual(numberOfCallsBack, (int)urlArray.count);

  // On some builds (Mac/iOS and certain machines), all are succeeding; on some,
  // one finishes with an error, apparently a task ending up suspended when we
  // reset the session.  This may resolve as all builds migrate to a common version of
  // NSURLSession; if not, we should try to figure out why this is inconsistent.
  // On the simulator, all are succeeding.
  XCTAssertLessThanOrEqual(numberOfErrors, 1);

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();
}

- (void)testThreadingStress {
  if (!_isServerRunning) return;

  // We'll create and start a lot of fetchers on three different queues.
  dispatch_queue_t mainQueue = dispatch_get_main_queue();
  dispatch_queue_t bgParallel = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0);
  dispatch_queue_t bgSerial = dispatch_queue_create("com.example.bgSerial", DISPATCH_QUEUE_SERIAL);
  NSArray *queues = @[ mainQueue, bgParallel, bgSerial ];

  GTMSessionFetcherService *service = [[GTMSessionFetcherService alloc] init];
  service.allowLocalhostRequest = YES;

  NSURL *validFileURL = [_testServer localURLForFile:kValidFileName];

  __block int completedFetchCounter = 0;
  int const kNumberOfFetchersToCreate = 100;

  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(kNumberOfFetchersToCreate, kNumberOfFetchersToCreate);

  // Keep track of fetch failures that are probably due to our test server
  // failing to keep up.
  NSMutableIndexSet *overloadIndexes = [NSMutableIndexSet indexSet];

  for (NSUInteger index = 0; index < kNumberOfFetchersToCreate; index++) {
    NSString *desc = [NSString stringWithFormat:@"Fetcher %lu", (unsigned long)index];
    XCTestExpectation *expectation = [self expectationWithDescription:desc];

    dispatch_queue_t queue = queues[index % queues.count];
    dispatch_async(queue, ^{
      GTMSessionFetcher *fetcher = [service fetcherWithURL:validFileURL];
      fetcher.callbackQueue = queues[(index / queues.count) % queues.count];  // epicycle of queues

      [fetcher beginFetchWithCompletionHandler:^(NSData *fetchData, NSError *fetchError) {
        @synchronized(self) {
          ++completedFetchCounter;
          [expectation fulfill];

          if (fetchError.code == EINVAL) {
            // Overloads of our test server are showing up as mysterious "invalid argument"
            // POSIX domain errors. We'll check afterwards that most of the fetches succeeded.
            [overloadIndexes addIndex:(NSUInteger)index];
            return;
          }

          const char *expectedQueueLabel =
              dispatch_queue_get_label(queues[(index / 3) % queues.count]);
          const char *actualQueueLabel = dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL);
          XCTAssert(strcmp(actualQueueLabel, expectedQueueLabel) == 0,
                    @"queue mismatch on index %lu: %s (expected %s)", (unsigned long)index,
                    actualQueueLabel, expectedQueueLabel);

          XCTAssertNotNil(fetchData, @"index %lu", (unsigned long)index);
          XCTAssertNil(fetchError, @"index %lu", (unsigned long)index);
        }
      }];
    });
  }

  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];

  XCTAssertLessThan(overloadIndexes.count, 10U);
  if (overloadIndexes.count) {
    NSLog(@"Server overloads: %@", overloadIndexes);
  }

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  // We should have one unique session per fetcher.
  XCTAssertEqual(completedFetchCounter, kNumberOfFetchersToCreate);
}

- (void)testFetcherServiceTestBlock {
  // No test server needed.
  _testServer = nil;
  _isServerRunning = NO;

  GTMSessionFetcherService *service = [[GTMSessionFetcherService alloc] init];
  service.allowedInsecureSchemes = @[ @"http" ];

  // Create four fetchers, with alternating success and failure test blocks.

  NSString *host = @"bad.example.com";
  NSData *resultData = [@"Freebles" dataUsingEncoding:NSUTF8StringEncoding];

  service.testBlock =
      ^(GTMSessionFetcher *fetcherToTest, GTMSessionFetcherTestResponse testResponse) {
        NSData *fakedResultData;
        NSHTTPURLResponse *fakedResultResponse;
        NSError *fakedResultError;

        NSURL *requestURL = fetcherToTest.request.URL;
        NSString *pathStr = requestURL.path.lastPathComponent;
        BOOL isOdd = (([pathStr intValue] % 2) != 0);
        if (isOdd) {
          // Succeed.
          fakedResultData = resultData;
          fakedResultResponse = [[NSHTTPURLResponse alloc] initWithURL:requestURL
                                                            statusCode:200
                                                           HTTPVersion:@"HTTP/1.1"
                                                          headerFields:@{@"Bearded" : @"Collie"}];
          fakedResultError = nil;
        } else {
          // Fail.
          fakedResultData = nil;
          fakedResultResponse = [[NSHTTPURLResponse alloc] initWithURL:requestURL
                                                            statusCode:500
                                                           HTTPVersion:@"HTTP/1.1"
                                                          headerFields:@{@"Afghan" : @"Hound"}];
          fakedResultError = [NSError errorWithDomain:kGTMSessionFetcherErrorDomain
                                                 code:500
                                             userInfo:@{kGTMSessionFetcherStatusDataKey : @"Oops"}];
        }

        testResponse(fakedResultResponse, fakedResultData, fakedResultError);
      };

  const int kNumberOfFetchersToCreate = 4;
  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(kNumberOfFetchersToCreate, kNumberOfFetchersToCreate);

  for (int idx = 1; idx <= kNumberOfFetchersToCreate; idx++) {
    XCTestExpectation *fetcherCompletedExpectation =
        [self expectationWithDescription:[NSString stringWithFormat:@"fetcher completed %d", idx]];
    NSString *urlStr = [NSString stringWithFormat:@"http://%@/%d", host, idx];
    GTMSessionFetcher *fetcher = [service fetcherWithURLString:urlStr];

    [fetcher beginFetchWithCompletionHandler:^(NSData *fetchData, NSError *fetchError) {
      BOOL isOdd = ((idx % 2) != 0);
      if (isOdd) {
        // Should have succeeded.
        XCTAssertEqualObjects(fetchData, resultData);
        XCTAssertNil(fetchError);
        XCTAssertEqual(fetcher.statusCode, (NSInteger)200);
        XCTAssertEqualObjects(fetcher.responseHeaders[@"Bearded"], @"Collie");
      } else {
        // Should have failed.
        XCTAssertNil(fetchData);
        XCTAssertEqual(fetchError.code, (NSInteger)500);
        XCTAssertEqual(fetcher.statusCode, 500);
        XCTAssertEqualObjects(fetcher.responseHeaders[@"Afghan"], @"Hound");
      }
      [fetcherCompletedExpectation fulfill];
    }];
  }

  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  XCTAssertEqual([service.runningFetchersByHost objectForKey:host].count, (NSUInteger)0);
}

- (void)testMockCreationMethod {
  // No test server needed.
  _testServer = nil;
  _isServerRunning = NO;

  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(2, 2);

  // Test with data.
  NSData *data = [@"abcdefg" dataUsingEncoding:NSUTF8StringEncoding];

  GTMSessionFetcherService *service =
      [GTMSessionFetcherService mockFetcherServiceWithFakedData:data fakedError:nil];
  GTMSessionFetcher *fetcher = [service fetcherWithURLString:@"http://example.invalid"];

  XCTestExpectation *expectFinishedWithData = [self expectationWithDescription:@"Called back"];

  [fetcher beginFetchWithCompletionHandler:^(NSData *fetchData, NSError *fetchError) {
    XCTAssertEqualObjects(fetchData, data);
    XCTAssertNil(fetchError);
    [expectFinishedWithData fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];

  // Test with error.
  NSError *error = [NSError errorWithDomain:@"example.com" code:-321 userInfo:nil];
  service = [GTMSessionFetcherService mockFetcherServiceWithFakedData:nil fakedError:error];
  fetcher = [service fetcherWithURLString:@"http://example.invalid"];

  XCTestExpectation *expectFinishedWithError = [self expectationWithDescription:@"Called back"];

  [fetcher beginFetchWithCompletionHandler:^(NSData *fetchData, NSError *fetchError) {
    XCTAssertNil(fetchData);
    XCTAssertEqualObjects(fetchError, error);
    [expectFinishedWithError fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();
}

// Test to ensure that the service's default user-agent does not override a user-agent set on the
// request itself.
- (void)testUserAgentFromRequest {
  NSString *const kUserAgentHeader = @"User-Agent";
  NSString *const kUserAgentValue = @"TestUserAgentFromRequest";
  GTMSessionFetcherService *service = [[GTMSessionFetcherService alloc] init];

  service.allowLocalhostRequest = YES;

  NSURL *validFileURL = [_testServer localURLForFile:kValidFileName];
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:validFileURL];

  [request setValue:kUserAgentValue forHTTPHeaderField:kUserAgentHeader];

  GTMSessionFetcher *fetcher = [service fetcherWithRequest:request];
  NSURLRequest *fetcherRequest = fetcher.request;

  NSString *userAgent = [fetcherRequest valueForHTTPHeaderField:kUserAgentHeader];
  XCTAssertEqualObjects(userAgent, kUserAgentValue);
}

// Test to ensure that setting the service's default user-agent to nil, causes the service to use
// the user-agent in the configuration.
- (void)testUserAgentFromSessionConfiguration {
  if (!_isServerRunning) return;

  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(1, 1);

  NSString *const kUserAgentHeader = @"User-Agent";
  NSString *const kUserAgentValue = @"TestUserAgentFromSessionConfig";

  // Build the session configuration to use, which includes the User-Agent header in the
  // HTTPAdditionalHeaders property.
  NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];

  config.HTTPAdditionalHeaders = @{kUserAgentHeader : kUserAgentValue};

  GTMSessionFetcherService *service = [[GTMSessionFetcherService alloc] init];

  // Clear the default user-agent.
  service.userAgent = nil;
  service.configuration = config;
  service.allowLocalhostRequest = YES;

  XCTestExpectation *expectReceiveResponse = [self expectationWithDescription:@"Received response"];
  NSURL *gettysburgFileURL = [_testServer localURLForFile:kValidFileName];
  NSURLComponents *validFileURLComponents = [[NSURLComponents alloc] initWithURL:gettysburgFileURL
                                                         resolvingAgainstBaseURL:NO];
  validFileURLComponents.query = @"?echo-headers=true";
  NSURL *validFileURL = validFileURLComponents.URL;
  GTMSessionFetcher *fetcher = [service fetcherWithURL:validFileURL];

  [fetcher beginFetchWithCompletionHandler:^(NSData *fetchData, NSError *fetchError) {
    // fetchData should contain the JSON representation of the dictionary of HTTP headers that were
    // sent with the request to the server.
    XCTAssertNotNil(fetchData);
    XCTAssertNil(fetchError);

    NSError *jsonError;
    NSDictionary *requestHeaders = [NSJSONSerialization JSONObjectWithData:fetchData
                                                                   options:0
                                                                     error:&jsonError];
    NSString *userAgent = requestHeaders[kUserAgentHeader];

    XCTAssertEqualObjects(userAgent, kUserAgentValue, @"%@", jsonError);

    [expectReceiveResponse fulfill];
  }];

  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();
}

- (void)testFetcherShouldUseStandardUserAgent {
  GTMSessionFetcherService *service =
      [GTMSessionFetcherService mockFetcherServiceWithFakedData:nil fakedError:nil];
  GTMSessionFetcher *fetcher = [service fetcherWithURLString:@"https://www.html5zombo.com"];
  XCTAssertNil([fetcher.request valueForHTTPHeaderField:@"User-Agent"]);

  XCTestExpectation *fetchCompleteExpectation = [self expectationWithDescription:@"Fetch complete"];
  [fetcher
      beginFetchWithCompletionHandler:^(__unused NSData *fetchData, __unused NSError *fetchError) {
        [fetchCompleteExpectation fulfill];
      }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];

  NSString *userAgent = [fetcher.request valueForHTTPHeaderField:@"User-Agent"];
  NSError *error;
  // Example: com.apple.dt.xctest.tool/14.2 MacOSX/13.3.1
  // Another example: com.apple.dt.xctest.tool/14.2 Apple_TV/16.1 hw/sim
  NSRegularExpression *standardUserAgentRegularExpression =
      [NSRegularExpression regularExpressionWithPattern:@"^.+?/[0-9.]+ .+?/[0-9.]+( .+?/.+?)?$"
                                                options:0
                                                  error:&error];
  XCTAssertNotNil(standardUserAgentRegularExpression, @"Couldn't parse regex: %@", error);
  NSUInteger numMatches =
      [standardUserAgentRegularExpression numberOfMatchesInString:userAgent
                                                          options:0
                                                            range:NSMakeRange(0, userAgent.length)];
  XCTAssertEqual(numMatches, 1UL,
                 @"Standard User-Agent should match expected pattern [Foo/1.2 Bar/1.2]: [%@]",
                 userAgent);
}

- (void)testUserAgentFromProviderShouldFetchFromProviderOffMainQueueWhenNotCached {
  GTMSessionFetcherService *service =
      [GTMSessionFetcherService mockFetcherServiceWithFakedData:nil fakedError:nil];
  service.userAgentProvider = [[TestUserAgentBlockProvider alloc] initWithUserAgentBlock:^{
    dispatch_assert_queue_not(dispatch_get_main_queue());
    return @"NotMainQueue";
  }];
  GTMSessionFetcher *fetcher = [service fetcherWithURLString:@"https://www.html5zombo.com"];
  XCTestExpectation *fetchCompleteExpectation = [self expectationWithDescription:@"Fetch complete"];
  [fetcher beginFetchWithCompletionHandler:^(__unused NSData *fetchData,
                                             __unused NSError *fetchError) {
    XCTAssertEqualObjects([fetcher.request valueForHTTPHeaderField:@"User-Agent"], @"NotMainQueue");
    [fetchCompleteExpectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
}

- (void)testUserAgentFromProviderShouldNotBeCalledWhenAlreadyCached {
  GTMSessionFetcherService *service =
      [GTMSessionFetcherService mockFetcherServiceWithFakedData:nil fakedError:nil];
  TestUserAgentBlockProvider *userAgentProvider =
      [[TestUserAgentBlockProvider alloc] initWithUserAgentBlock:^{
        XCTFail(@"With a cached value, the provider should not be invoked.");
        return @"NotUsed";
      }];
  userAgentProvider.cachedUserAgent = @"MainQueue";
  service.userAgentProvider = userAgentProvider;
  GTMSessionFetcher *fetcher = [service fetcherWithURLString:@"https://www.html5zombo.com"];
  XCTestExpectation *fetchCompleteExpectation = [self expectationWithDescription:@"Fetch complete"];
  [fetcher beginFetchWithCompletionHandler:^(__unused NSData *fetchData,
                                             __unused NSError *fetchError) {
    XCTAssertEqualObjects([fetcher.request valueForHTTPHeaderField:@"User-Agent"], @"MainQueue");
    [fetchCompleteExpectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
}

- (void)testStoppingFetchWhileUserAgentProviderInProgressShouldNotInvokeCompletionHandler {
  GTMSessionFetcherService *service =
      [GTMSessionFetcherService mockFetcherServiceWithFakedData:nil fakedError:nil];
  XCTestExpectation *userAgentProvidedExpectation =
      [self expectationWithDescription:@"User agent provided"];
  service.userAgentProvider =
      [[TestUserAgentBlockProvider alloc] initWithBlockedTimeout:1
                                                  userAgentBlock:^{
                                                    [userAgentProvidedExpectation fulfill];
                                                    return @"NotUsed";
                                                  }];
  GTMSessionFetcher *fetcher = [service fetcherWithURLString:@"https://www.html5zombo.com"];
  [fetcher
      beginFetchWithCompletionHandler:^(__unused NSData *fetchData, __unused NSError *fetchError) {
        XCTFail(@"Completion handler should not be invoked");
      }];
  [fetcher stopFetching];
  [(TestUserAgentBlockProvider *)fetcher.userAgentProvider unblock];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
}

- (void)
    testStoppingFetchWhileUserAgentProviderInProgressShouldInvokeCompletionHandlerIfPropertySet {
  GTMSessionFetcherService *service =
      [GTMSessionFetcherService mockFetcherServiceWithFakedData:nil fakedError:nil];
  XCTestExpectation *userAgentProvidedExpectation =
      [self expectationWithDescription:@"User agent provided"];
  service.userAgentProvider =
      [[TestUserAgentBlockProvider alloc] initWithBlockedTimeout:5
                                                  userAgentBlock:^{
                                                    [userAgentProvidedExpectation fulfill];
                                                    return @"NotUsed";
                                                  }];
  GTMSessionFetcher *fetcher = [service fetcherWithURLString:@"https://www.html5zombo.com"];
  fetcher.stopFetchingTriggersCompletionHandler = YES;
  XCTestExpectation *fetchCompleteExpectation = [self expectationWithDescription:@"Fetch complete"];
  [fetcher
      beginFetchWithCompletionHandler:^(__unused NSData *fetchData, __unused NSError *fetchError) {
        [fetchCompleteExpectation fulfill];
      }];
  [fetcher stopFetching];
  [(TestUserAgentBlockProvider *)fetcher.userAgentProvider unblock];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
}

- (void)testSingleDecoratorSynchronous {
  GTMSessionFetcherTestDecorator *decorator = [[GTMSessionFetcherTestDecorator alloc]
      initWithHeadersSynchronous:@{@"foo" : @"bar", @"baz" : @"blech"}];
  GTMSessionFetcherService *service =
      [GTMSessionFetcherService mockFetcherServiceWithFakedData:nil fakedError:nil];
  [service addDecorator:decorator];
  GTMSessionFetcher *fetcher = [service fetcherWithURLString:@"https://www.html5zombo.com"];
  // Ensure this test always runs the decorators synchronously -- if it's the first
  // test to run, then the `GTMStandardUserAgentProvider` will asynchronously add
  // the User-Agent.
  fetcher.userAgentProvider = [[GTMUserAgentStringProvider alloc] initWithUserAgentString:@"Lynx"];
  XCTestExpectation *fetchCompleteExpectation = [self expectationWithDescription:@"Fetch complete"];
  [fetcher
      beginFetchWithCompletionHandler:^(__unused NSData *fetchData, __unused NSError *fetchError) {
        [fetchCompleteExpectation fulfill];
      }];
  NSDictionary<NSString *, NSString *> *expectedHeaders = @{@"foo" : @"bar", @"baz" : @"blech"};
  XCTAssertEqualObjects(FetcherHeadersWithoutUserAgent(fetcher), expectedHeaders);
  // The wait is intentionally after the assert, as we expect the header decorator to complete its
  // work synchronously (but this test still needs to wait, as otherwise the NSNotifications posted
  // asynchronously can affect other tests).
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
}

- (void)testSingleDecoratorSynchronousAddHeaderOnRetry {
  GTMSessionFetcherService *service = [[GTMSessionFetcherService alloc] init];
  NSURL *url = [NSURL URLWithString:@"https://www.html5zombo.com"];
  service.testBlock =
      ^(GTMSessionFetcher *fetcher, GTMSessionFetcherTestResponse testResponseBlock) {
        NSHTTPURLResponse *response;
        NSData *data;
        NSError *error;
        if (fetcher.retryCount == 0) {
          response = [[NSHTTPURLResponse alloc] initWithURL:url
                                                 statusCode:504
                                                HTTPVersion:@"HTTP/1.1"
                                               headerFields:@{}];
          data = nil;
          error = [NSError errorWithDomain:kGTMSessionFetcherErrorDomain code:504 userInfo:nil];
        } else {
          response = [[NSHTTPURLResponse alloc] initWithURL:url
                                                 statusCode:200
                                                HTTPVersion:@"HTTP/1.1"
                                               headerFields:@{}];
          data = [@"Welcome to ZomboCom" dataUsingEncoding:NSUTF8StringEncoding];
          error = nil;
        }
        testResponseBlock(response, data, error);
      };

  GTMSessionFetcherTestDecorator *decorator = [[GTMSessionFetcherTestDecorator alloc]
      initWithFetcherWillStartBlock:^(
          GTMSessionFetcher *fetcher,
          GTMFetcherDecoratorFetcherWillStartCompletionHandler completion) {
        if (!fetcher.retryCount) {
          completion(/*request=*/nil, /*error=*/nil);
          return;
        }
        // Add a `retry=1` header when the decorator is invoked on a retry.
        NSMutableURLRequest *request = [fetcher.request mutableCopy];
        [request setValue:@"1" forHTTPHeaderField:@"retry"];
        completion(request, /*error=*/nil);
      }
                        synchronous:YES];

  [service addDecorator:decorator];
  GTMSessionFetcher *fetcher = [service fetcherWithURLString:@"https://www.html5zombo.com"];
  fetcher.retryEnabled = YES;
  fetcher.minRetryInterval = 0.01;
  fetcher.maxRetryInterval = 0.05;
  fetcher.userAgentProvider = [[GTMUserAgentStringProvider alloc] initWithUserAgentString:@"Lynx"];
  XCTestExpectation *fetchCompleteExpectation = [self expectationWithDescription:@"Fetch complete"];
  [fetcher
      beginFetchWithCompletionHandler:^(__unused NSData *fetchData, __unused NSError *fetchError) {
        [fetchCompleteExpectation fulfill];
      }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  NSDictionary<NSString *, NSString *> *expectedHeaders = @{@"retry" : @"1"};
  XCTAssertEqualObjects(FetcherHeadersWithoutUserAgent(fetcher), expectedHeaders);
}

- (void)testSingleDecoratorSynchronousWithError {
  NSError *error = [NSError errorWithDomain:@"TestDomain" code:12345 userInfo:nil];
  GTMSessionFetcherTestDecorator *decorator = [[GTMSessionFetcherTestDecorator alloc]
      initWithFetcherWillStartBlock:^(
          GTMSessionFetcher *fetcher,
          GTMFetcherDecoratorFetcherWillStartCompletionHandler completion) {
        completion(/*request=*/nil, error);
      }
                        synchronous:YES];
  GTMSessionFetcherService *service =
      [GTMSessionFetcherService mockFetcherServiceWithFakedData:nil fakedError:nil];
  [service addDecorator:decorator];
  GTMSessionFetcher *fetcher = [service fetcherWithURLString:@"https://www.html5zombo.com"];
  fetcher.userAgentProvider = [[GTMUserAgentStringProvider alloc] initWithUserAgentString:@"Lynx"];
  XCTestExpectation *fetchCompleteExpectation = [self expectationWithDescription:@"Fetch complete"];
  [fetcher beginFetchWithCompletionHandler:^(__unused NSData *fetchData, NSError *fetchError) {
    XCTAssertEqualObjects(fetchError, error);
    [fetchCompleteExpectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  XCTAssertNil(decorator.fetchedData);
  XCTAssertEqualObjects(decorator.fetchError, error);
}

- (void)testMultipleDecoratorsSynchronousWithErrorShouldNotCallSubsequentDecorators {
  NSError *error = [NSError errorWithDomain:@"TestDomain" code:12345 userInfo:nil];
  GTMSessionFetcherTestDecorator *decoratorA = [[GTMSessionFetcherTestDecorator alloc]
      initWithFetcherWillStartBlock:^(
          GTMSessionFetcher *fetcher,
          GTMFetcherDecoratorFetcherWillStartCompletionHandler completion) {
        completion(/*request=*/nil, error);
      }
                        synchronous:YES];
  GTMSessionFetcherTestDecorator *decoratorB = [[GTMSessionFetcherTestDecorator alloc]
      initWithFetcherWillStartBlock:^(
          GTMSessionFetcher *fetcher,
          GTMFetcherDecoratorFetcherWillStartCompletionHandler completion) {
        XCTFail(@"Subsequent decorator should not be invoked");
      }
                        synchronous:YES];
  GTMSessionFetcherService *service =
      [GTMSessionFetcherService mockFetcherServiceWithFakedData:nil fakedError:nil];
  [service addDecorator:decoratorA];
  [service addDecorator:decoratorB];
  GTMSessionFetcher *fetcher = [service fetcherWithURLString:@"https://www.html5zombo.com"];
  fetcher.userAgentProvider = [[GTMUserAgentStringProvider alloc] initWithUserAgentString:@"Lynx"];
  XCTestExpectation *fetchCompleteExpectation = [self expectationWithDescription:@"Fetch complete"];
  [fetcher beginFetchWithCompletionHandler:^(__unused NSData *fetchData, NSError *fetchError) {
    XCTAssertEqualObjects(fetchError, error);
    [fetchCompleteExpectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  XCTAssertNil(decoratorA.fetchedData);
  XCTAssertNil(decoratorB.fetchedData);
  XCTAssertEqualObjects(decoratorA.fetchError, error);
  XCTAssertEqualObjects(decoratorB.fetchError, error);
}

- (void)testMultipleDecoratorsSynchronous {
  GTMSessionFetcherTestDecorator *decoratorA =
      [[GTMSessionFetcherTestDecorator alloc] initWithHeadersSynchronous:@{@"foo" : @"bar"}];
  GTMSessionFetcherTestDecorator *decoratorB = [[GTMSessionFetcherTestDecorator alloc]
      initWithHeadersSynchronous:@{@"baz" : @"blech", @"quux" : @"xyzzy"}];
  GTMSessionFetcherTestDecorator *decoratorC =
      [[GTMSessionFetcherTestDecorator alloc] initWithHeadersSynchronous:@{@"quux" : @"corge"}];
  GTMSessionFetcherService *service =
      [GTMSessionFetcherService mockFetcherServiceWithFakedData:nil fakedError:nil];
  [service addDecorator:decoratorA];
  [service addDecorator:decoratorB];
  [service addDecorator:decoratorC];
  GTMSessionFetcher *fetcher = [service fetcherWithURLString:@"https://www.html5zombo.com"];
  fetcher.userAgentProvider = [[GTMUserAgentStringProvider alloc] initWithUserAgentString:@"Lynx"];
  XCTestExpectation *fetchCompleteExpectation = [self expectationWithDescription:@"Fetch complete"];
  [fetcher
      beginFetchWithCompletionHandler:^(__unused NSData *fetchData, __unused NSError *fetchError) {
        [fetchCompleteExpectation fulfill];
      }];
  NSDictionary<NSString *, NSString *> *expectedHeaders =
      @{@"foo" : @"bar", @"baz" : @"blech", @"quux" : @"corge"};
  XCTAssertEqualObjects(FetcherHeadersWithoutUserAgent(fetcher), expectedHeaders);
  // The wait is intentionally after the assert, as we expect the header decorator to complete its
  // work synchronously (but this test still needs to wait, as otherwise the NSNotifications posted
  // asynchronously can affect other tests).
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
}

- (void)testMultipleDecoratorsSynchronousFetchedDataAndError {
  GTMSessionFetcherTestDecorator *decoratorA =
      [[GTMSessionFetcherTestDecorator alloc] initWithHeadersSynchronous:@{}];
  GTMSessionFetcherTestDecorator *decoratorB =
      [[GTMSessionFetcherTestDecorator alloc] initWithHeadersSynchronous:@{}];
  NSData *data = [@"hello world" dataUsingEncoding:NSUTF8StringEncoding];
  NSError *error = [NSError errorWithDomain:@"TestErrorDomain" code:12345 userInfo:nil];
  GTMSessionFetcherService *service =
      [GTMSessionFetcherService mockFetcherServiceWithFakedData:data fakedError:error];
  [service addDecorator:decoratorA];
  [service addDecorator:decoratorB];
  GTMSessionFetcher *fetcher = [service fetcherWithURLString:@"https://www.html5zombo.com"];
  fetcher.userAgentProvider = [[GTMUserAgentStringProvider alloc] initWithUserAgentString:@"Lynx"];
  XCTestExpectation *fetchCompleteExpectation = [self expectationWithDescription:@"Fetch complete"];
  [fetcher
      beginFetchWithCompletionHandler:^(__unused NSData *fetchData, __unused NSError *fetchError) {
        [fetchCompleteExpectation fulfill];
      }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  XCTAssertEqualObjects(decoratorA.fetchedData, data);
  XCTAssertEqualObjects(decoratorB.fetchedData, data);
  XCTAssertEqualObjects(decoratorA.fetchError, error);
  XCTAssertEqualObjects(decoratorB.fetchError, error);
}

- (void)testSingleDecoratorSynchronousWithDifferentHeadersForEachRequest {
  __block int i = 0;
  GTMSessionFetcherTestDecorator *decorator = [[GTMSessionFetcherTestDecorator alloc]
      initWithFetcherWillStartBlock:^(
          GTMSessionFetcher *fetcher,
          GTMFetcherDecoratorFetcherWillStartCompletionHandler completion) {
        NSMutableURLRequest *request = [fetcher.request mutableCopy];
        [request setValue:[NSString stringWithFormat:@"%d", i++] forHTTPHeaderField:@"foo"];
        completion(request, /*error=*/nil);
      }
                        synchronous:YES];
  GTMSessionFetcherService *service =
      [GTMSessionFetcherService mockFetcherServiceWithFakedData:nil fakedError:nil];
  [service addDecorator:decorator];
  GTMSessionFetcher *fetcherA = [service fetcherWithURLString:@"https://www.html5zombo.com"];
  fetcherA.userAgentProvider = [[GTMUserAgentStringProvider alloc] initWithUserAgentString:@"Lynx"];

  XCTestExpectation *fetchCompleteExpectationA =
      [self expectationWithDescription:@"Fetch complete"];
  [fetcherA
      beginFetchWithCompletionHandler:^(__unused NSData *fetchData, __unused NSError *fetchError) {
        [fetchCompleteExpectationA fulfill];
      }];
  GTMSessionFetcher *fetcherB = [service fetcherWithURLString:@"https://www.html5zombo.com"];
  fetcherB.userAgentProvider = [[GTMUserAgentStringProvider alloc] initWithUserAgentString:@"Lynx"];
  XCTestExpectation *fetchCompleteExpectationB =
      [self expectationWithDescription:@"Fetch complete"];
  [fetcherB
      beginFetchWithCompletionHandler:^(__unused NSData *fetchData, __unused NSError *fetchError) {
        [fetchCompleteExpectationB fulfill];
      }];
  GTMSessionFetcher *fetcherC = [service fetcherWithURLString:@"https://www.html5zombo.com"];
  fetcherC.userAgentProvider = [[GTMUserAgentStringProvider alloc] initWithUserAgentString:@"Lynx"];
  XCTestExpectation *fetchCompleteExpectationC =
      [self expectationWithDescription:@"Fetch complete"];
  [fetcherC
      beginFetchWithCompletionHandler:^(__unused NSData *fetchData, __unused NSError *fetchError) {
        [fetchCompleteExpectationC fulfill];
      }];

  NSDictionary<NSString *, NSString *> *expectedHeadersA = @{@"foo" : @"0"};
  XCTAssertEqualObjects(FetcherHeadersWithoutUserAgent(fetcherA), expectedHeadersA);
  NSDictionary<NSString *, NSString *> *expectedHeadersB = @{@"foo" : @"1"};
  XCTAssertEqualObjects(FetcherHeadersWithoutUserAgent(fetcherB), expectedHeadersB);
  NSDictionary<NSString *, NSString *> *expectedHeadersC = @{@"foo" : @"2"};
  XCTAssertEqualObjects(FetcherHeadersWithoutUserAgent(fetcherC), expectedHeadersC);
  // The wait is intentionally after the assert, as we expect the header decorator to complete its
  // work synchronously (but this test still needs to wait, as otherwise the NSNotifications posted
  // asynchronously can affect other tests).
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
}

- (void)testEmptyDecoratorAsynchronous {
  GTMSessionFetcherTestDecorator *decorator =
      [[GTMSessionFetcherTestDecorator alloc] initWithHeaders:@{}];
  GTMSessionFetcherService *service =
      [GTMSessionFetcherService mockFetcherServiceWithFakedData:nil fakedError:nil];
  [service addDecorator:decorator];
  GTMSessionFetcher *fetcher = [service fetcherWithURLString:@"https://www.html5zombo.com"];
  XCTestExpectation *fetchCompleteExpectation = [self expectationWithDescription:@"Fetch complete"];
  [fetcher
      beginFetchWithCompletionHandler:^(__unused NSData *fetchData, __unused NSError *fetchError) {
        [fetchCompleteExpectation fulfill];
      }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  XCTAssertEqualObjects(FetcherHeadersWithoutUserAgent(fetcher), @{});
}

- (void)testSingleDecoratorAsynchronous {
  GTMSessionFetcherTestDecorator *decorator = [[GTMSessionFetcherTestDecorator alloc]
      initWithHeaders:@{@"foo" : @"bar", @"baz" : @"blech"}];
  GTMSessionFetcherService *service =
      [GTMSessionFetcherService mockFetcherServiceWithFakedData:nil fakedError:nil];
  [service addDecorator:decorator];
  GTMSessionFetcher *fetcher = [service fetcherWithURLString:@"https://www.html5zombo.com"];
  XCTestExpectation *fetchCompleteExpectation = [self expectationWithDescription:@"Fetch complete"];
  [fetcher
      beginFetchWithCompletionHandler:^(__unused NSData *fetchData, __unused NSError *fetchError) {
        [fetchCompleteExpectation fulfill];
      }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  NSDictionary<NSString *, NSString *> *expectedHeaders = @{@"foo" : @"bar", @"baz" : @"blech"};
  XCTAssertEqualObjects(FetcherHeadersWithoutUserAgent(fetcher), expectedHeaders);
}

- (void)testSingleDecoratorAsynchronousWithDifferentHeadersForEachRequest {
  __block int i = 0;
  GTMSessionFetcherTestDecorator *decorator = [[GTMSessionFetcherTestDecorator alloc]
      initWithFetcherWillStartBlock:^(
          GTMSessionFetcher *fetcher,
          GTMFetcherDecoratorFetcherWillStartCompletionHandler completion) {
        NSMutableURLRequest *request = [fetcher.request mutableCopy];
        [request setValue:[NSString stringWithFormat:@"%d", i++] forHTTPHeaderField:@"foo"];
        completion(request, /*error=*/nil);
      }
                        synchronous:NO];
  GTMSessionFetcherService *service =
      [GTMSessionFetcherService mockFetcherServiceWithFakedData:nil fakedError:nil];
  [service addDecorator:decorator];
  GTMSessionFetcher *fetcherA = [service fetcherWithURLString:@"https://www.html5zombo.com"];
  XCTestExpectation *fetchCompleteExpectationA =
      [self expectationWithDescription:@"Fetch complete"];
  [fetcherA
      beginFetchWithCompletionHandler:^(__unused NSData *fetchData, __unused NSError *fetchError) {
        [fetchCompleteExpectationA fulfill];
      }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  GTMSessionFetcher *fetcherB = [service fetcherWithURLString:@"https://www.html5zombo.com"];
  XCTestExpectation *fetchCompleteExpectationB =
      [self expectationWithDescription:@"Fetch complete"];
  [fetcherB
      beginFetchWithCompletionHandler:^(__unused NSData *fetchData, __unused NSError *fetchError) {
        [fetchCompleteExpectationB fulfill];
      }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  GTMSessionFetcher *fetcherC = [service fetcherWithURLString:@"https://www.html5zombo.com"];
  XCTestExpectation *fetchCompleteExpectationC =
      [self expectationWithDescription:@"Fetch complete"];
  [fetcherC
      beginFetchWithCompletionHandler:^(__unused NSData *fetchData, __unused NSError *fetchError) {
        [fetchCompleteExpectationC fulfill];
      }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];

  NSDictionary<NSString *, NSString *> *expectedHeadersA = @{@"foo" : @"0"};
  XCTAssertEqualObjects(FetcherHeadersWithoutUserAgent(fetcherA), expectedHeadersA);
  NSDictionary<NSString *, NSString *> *expectedHeadersB = @{@"foo" : @"1"};
  XCTAssertEqualObjects(FetcherHeadersWithoutUserAgent(fetcherB), expectedHeadersB);
  NSDictionary<NSString *, NSString *> *expectedHeadersC = @{@"foo" : @"2"};
  XCTAssertEqualObjects(FetcherHeadersWithoutUserAgent(fetcherC), expectedHeadersC);
}

- (void)testRemoveSingleDecoratorAsynchronous {
  GTMSessionFetcherTestDecorator *decorator = [[GTMSessionFetcherTestDecorator alloc]
      initWithHeaders:@{@"foo" : @"bar", @"baz" : @"blech"}];
  GTMSessionFetcherService *service =
      [GTMSessionFetcherService mockFetcherServiceWithFakedData:nil fakedError:nil];
  [service addDecorator:decorator];
  [service removeDecorator:decorator];
  GTMSessionFetcher *fetcher = [service fetcherWithURLString:@"https://www.html5zombo.com"];
  XCTestExpectation *fetchCompleteExpectation = [self expectationWithDescription:@"Fetch complete"];
  [fetcher
      beginFetchWithCompletionHandler:^(__unused NSData *fetchData, __unused NSError *fetchError) {
        [fetchCompleteExpectation fulfill];
      }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  XCTAssertEqualObjects(FetcherHeadersWithoutUserAgent(fetcher), @{});
}

- (void)testSingleDecoratorAsynchronousWeakReferenceReleasedBeforeFetcherCreated {
  GTMSessionFetcherService *service =
      [GTMSessionFetcherService mockFetcherServiceWithFakedData:nil fakedError:nil];
  {
    // Reference should be released after this block exits.
    NS_VALID_UNTIL_END_OF_SCOPE GTMSessionFetcherTestDecorator *decorator =
        [[GTMSessionFetcherTestDecorator alloc]
            initWithHeaders:@{@"foo" : @"bar", @"baz" : @"blech"}];
    [service addDecorator:decorator];
  }

  // The header decorator should no longer add its headers after this point.
  GTMSessionFetcher *fetcher = [service fetcherWithURLString:@"https://www.html5zombo.com"];
  XCTestExpectation *fetchCompleteExpectation = [self expectationWithDescription:@"Fetch complete"];
  [fetcher
      beginFetchWithCompletionHandler:^(__unused NSData *fetchData, __unused NSError *fetchError) {
        [fetchCompleteExpectation fulfill];
      }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];

  XCTAssertEqualObjects(FetcherHeadersWithoutUserAgent(fetcher), @{});
}

- (void)testSingleDecoratorAsynchronousUserAgent {
  GTMSessionFetcherTestDecorator *decorator =
      [[GTMSessionFetcherTestDecorator alloc] initWithHeaders:@{@"User-Agent" : @"My User Agent"}];
  GTMSessionFetcherService *service =
      [GTMSessionFetcherService mockFetcherServiceWithFakedData:nil fakedError:nil];
  [service addDecorator:decorator];
  GTMSessionFetcher *fetcher = [service fetcherWithURLString:@"https://www.html5zombo.com"];
  XCTestExpectation *fetchCompleteExpectation = [self expectationWithDescription:@"Fetch complete"];
  [fetcher
      beginFetchWithCompletionHandler:^(__unused NSData *fetchData, __unused NSError *fetchError) {
        [fetchCompleteExpectation fulfill];
      }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  NSDictionary<NSString *, NSString *> *expectedHeaders = @{@"User-Agent" : @"My User Agent"};
  XCTAssertEqualObjects(fetcher.request.allHTTPHeaderFields, expectedHeaders);
}

- (void)testMultipleDecoratorsAsynchronousDifferentFields {
  GTMSessionFetcherTestDecorator *decoratorA =
      [[GTMSessionFetcherTestDecorator alloc] initWithHeaders:@{@"foo" : @"bar"}];
  GTMSessionFetcherTestDecorator *decoratorB =
      [[GTMSessionFetcherTestDecorator alloc] initWithHeaders:@{@"baz" : @"blech"}];
  GTMSessionFetcherService *service =
      [GTMSessionFetcherService mockFetcherServiceWithFakedData:nil fakedError:nil];
  [service addDecorator:decoratorA];
  [service addDecorator:decoratorB];
  GTMSessionFetcher *fetcher = [service fetcherWithURLString:@"https://www.html5zombo.com"];
  XCTestExpectation *fetchCompleteExpectation = [self expectationWithDescription:@"Fetch complete"];
  [fetcher
      beginFetchWithCompletionHandler:^(__unused NSData *fetchData, __unused NSError *fetchError) {
        [fetchCompleteExpectation fulfill];
      }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  NSDictionary<NSString *, NSString *> *expectedHeaders = @{@"foo" : @"bar", @"baz" : @"blech"};
  XCTAssertEqualObjects(FetcherHeadersWithoutUserAgent(fetcher), expectedHeaders);
}

- (void)testMultipleDecoratorsAsynchronousOneRemoved {
  GTMSessionFetcherTestDecorator *decoratorA =
      [[GTMSessionFetcherTestDecorator alloc] initWithHeaders:@{@"foo" : @"bar"}];
  GTMSessionFetcherTestDecorator *decoratorB =
      [[GTMSessionFetcherTestDecorator alloc] initWithHeaders:@{@"baz" : @"blech"}];
  GTMSessionFetcherService *service =
      [GTMSessionFetcherService mockFetcherServiceWithFakedData:nil fakedError:nil];
  [service addDecorator:decoratorA];
  [service addDecorator:decoratorB];
  [service removeDecorator:decoratorA];
  GTMSessionFetcher *fetcher = [service fetcherWithURLString:@"https://www.html5zombo.com"];
  XCTestExpectation *fetchCompleteExpectation = [self expectationWithDescription:@"Fetch complete"];
  [fetcher
      beginFetchWithCompletionHandler:^(__unused NSData *fetchData, __unused NSError *fetchError) {
        [fetchCompleteExpectation fulfill];
      }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  NSDictionary<NSString *, NSString *> *expectedHeaders = @{@"baz" : @"blech"};
  XCTAssertEqualObjects(FetcherHeadersWithoutUserAgent(fetcher), expectedHeaders);
}

- (void)testMultipleDecoratorsAsynchronousOneWeakReferenceReleased {
  GTMSessionFetcherService *service =
      [GTMSessionFetcherService mockFetcherServiceWithFakedData:nil fakedError:nil];
  GTMSessionFetcherTestDecorator *decoratorB =
      [[GTMSessionFetcherTestDecorator alloc] initWithHeaders:@{@"baz" : @"blech"}];
  {
    // Reference should be released after this block exits.
    NS_VALID_UNTIL_END_OF_SCOPE GTMSessionFetcherTestDecorator *decoratorA =
        [[GTMSessionFetcherTestDecorator alloc] initWithHeaders:@{@"foo" : @"bar"}];
    [service addDecorator:decoratorA];
    [service addDecorator:decoratorB];
  }
  GTMSessionFetcher *fetcher = [service fetcherWithURLString:@"https://www.html5zombo.com"];
  XCTestExpectation *fetchCompleteExpectation = [self expectationWithDescription:@"Fetch complete"];
  [fetcher
      beginFetchWithCompletionHandler:^(__unused NSData *fetchData, __unused NSError *fetchError) {
        [fetchCompleteExpectation fulfill];
      }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  NSDictionary<NSString *, NSString *> *expectedHeaders = @{@"baz" : @"blech"};
  XCTAssertEqualObjects(FetcherHeadersWithoutUserAgent(fetcher), expectedHeaders);
}

- (void)testMultipleDecoratorsAsynchronousSameFields {
  GTMSessionFetcherTestDecorator *decoratorA = [[GTMSessionFetcherTestDecorator alloc]
      initWithHeaders:@{@"foo" : @"bar", @"baz" : @"blech"}];
  GTMSessionFetcherTestDecorator *decoratorB = [[GTMSessionFetcherTestDecorator alloc]
      initWithHeaders:@{@"foo" : @"quux", @"baz" : @"xyzzy"}];
  GTMSessionFetcherService *service =
      [GTMSessionFetcherService mockFetcherServiceWithFakedData:nil fakedError:nil];
  [service addDecorator:decoratorA];
  [service addDecorator:decoratorB];
  GTMSessionFetcher *fetcher = [service fetcherWithURLString:@"https://www.html5zombo.com"];
  XCTestExpectation *fetchCompleteExpectation = [self expectationWithDescription:@"Fetch complete"];
  [fetcher
      beginFetchWithCompletionHandler:^(__unused NSData *fetchData, __unused NSError *fetchError) {
        [fetchCompleteExpectation fulfill];
      }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  NSDictionary<NSString *, NSString *> *expectedHeaders = @{@"foo" : @"quux", @"baz" : @"xyzzy"};
  XCTAssertEqualObjects(FetcherHeadersWithoutUserAgent(fetcher), expectedHeaders);
}

- (void)testMultipleDecoratorsAsynchronousSomeFieldsSame {
  GTMSessionFetcherTestDecorator *decoratorA = [[GTMSessionFetcherTestDecorator alloc]
      initWithHeaders:@{@"foo" : @"bar", @"baz" : @"blech"}];
  GTMSessionFetcherTestDecorator *decoratorB = [[GTMSessionFetcherTestDecorator alloc]
      initWithHeaders:@{@"baz" : @"xyzzy", @"quux" : @"corge"}];
  GTMSessionFetcherService *service =
      [GTMSessionFetcherService mockFetcherServiceWithFakedData:nil fakedError:nil];
  [service addDecorator:decoratorA];
  [service addDecorator:decoratorB];
  GTMSessionFetcher *fetcher = [service fetcherWithURLString:@"https://www.html5zombo.com"];
  XCTestExpectation *fetchCompleteExpectation = [self expectationWithDescription:@"Fetch complete"];
  [fetcher
      beginFetchWithCompletionHandler:^(__unused NSData *fetchData, __unused NSError *fetchError) {
        [fetchCompleteExpectation fulfill];
      }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  NSDictionary<NSString *, NSString *> *expectedHeaders =
      @{@"foo" : @"bar", @"baz" : @"xyzzy", @"quux" : @"corge"};
  XCTAssertEqualObjects(FetcherHeadersWithoutUserAgent(fetcher), expectedHeaders);
}

- (void)testMultipleDecoratorsAsyncFetchedDataAndError {
  GTMSessionFetcherTestDecorator *decoratorA =
      [[GTMSessionFetcherTestDecorator alloc] initWithHeaders:@{}];
  GTMSessionFetcherTestDecorator *decoratorB =
      [[GTMSessionFetcherTestDecorator alloc] initWithHeaders:@{}];
  NSData *data = [@"hello world" dataUsingEncoding:NSUTF8StringEncoding];
  NSError *error = [NSError errorWithDomain:@"TestErrorDomain" code:12345 userInfo:nil];
  GTMSessionFetcherService *service =
      [GTMSessionFetcherService mockFetcherServiceWithFakedData:data fakedError:error];
  [service addDecorator:decoratorA];
  [service addDecorator:decoratorB];
  GTMSessionFetcher *fetcher = [service fetcherWithURLString:@"https://www.html5zombo.com"];
  XCTestExpectation *fetchCompleteExpectation = [self expectationWithDescription:@"Fetch complete"];
  [fetcher
      beginFetchWithCompletionHandler:^(__unused NSData *fetchData, __unused NSError *fetchError) {
        [fetchCompleteExpectation fulfill];
      }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  XCTAssertEqualObjects(decoratorA.fetchedData, data);
  XCTAssertEqualObjects(decoratorB.fetchedData, data);
  XCTAssertEqualObjects(decoratorA.fetchError, error);
  XCTAssertEqualObjects(decoratorB.fetchError, error);
}

- (void)testSingleDecoderStopFetchingBeforeBeginNeverInvoked {
  // Note: This test actually results if the per host limits enforcement first noticing the
  // `-stopFetching`, to really trigger the check when entering the delayed state for decorators
  // would take multiple threads and there is no way to synchronize things to set the flag at just
  // the right point.
  GTMSessionFetcherTestDecorator *decorator = [[GTMSessionFetcherTestDecorator alloc]
      initWithFetcherWillStartBlock:^(
          GTMSessionFetcher *fetcher,
          GTMFetcherDecoratorFetcherWillStartCompletionHandler completion) {
        XCTFail(@"Should not have been invoked");
      }
                        synchronous:YES];
  GTMSessionFetcherService *service =
      [GTMSessionFetcherService mockFetcherServiceWithFakedData:nil fakedError:nil];
  [service addDecorator:decorator];
  GTMSessionFetcher *fetcher = [service fetcherWithURLString:@"https://www.html5zombo.com"];
  fetcher.userAgentProvider = [[GTMUserAgentStringProvider alloc] initWithUserAgentString:@"Lynx"];
  fetcher.stopFetchingTriggersCompletionHandler = YES;
  [fetcher stopFetching];
  XCTestExpectation *fetchCompleteExpectation = [self expectationWithDescription:@"Fetch complete"];
  [fetcher beginFetchWithCompletionHandler:^(__unused NSData *fetchData, NSError *fetchError) {
    XCTAssertEqual(fetchError.code, GTMSessionFetcherErrorUserCancelled);
    XCTAssertEqualObjects(fetchError.domain, kGTMSessionFetcherErrorDomain);
    [fetchCompleteExpectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  XCTAssertNil(decorator.fetchedData);
  XCTAssertEqual(decorator.fetchError.code, GTMSessionFetcherErrorUserCancelled);
  XCTAssertEqualObjects(decorator.fetchError.domain, kGTMSessionFetcherErrorDomain);
}

- (void)testSingleDecoderStopFetchingTriggersCallback {
  GTMSessionFetcherTestDecorator *decorator = [[GTMSessionFetcherTestDecorator alloc]
      initWithFetcherWillStartBlock:^(
          GTMSessionFetcher *fetcher,
          GTMFetcherDecoratorFetcherWillStartCompletionHandler completion) {
        [fetcher stopFetching];
        completion(/*request=*/nil, /*error*/ nil);
      }
                        synchronous:YES];
  GTMSessionFetcherService *service =
      [GTMSessionFetcherService mockFetcherServiceWithFakedData:nil fakedError:nil];
  [service addDecorator:decorator];
  GTMSessionFetcher *fetcher = [service fetcherWithURLString:@"https://www.html5zombo.com"];
  fetcher.userAgentProvider = [[GTMUserAgentStringProvider alloc] initWithUserAgentString:@"Lynx"];
  fetcher.stopFetchingTriggersCompletionHandler = YES;
  XCTestExpectation *fetchCompleteExpectation = [self expectationWithDescription:@"Fetch complete"];
  [fetcher beginFetchWithCompletionHandler:^(__unused NSData *fetchData, NSError *fetchError) {
    XCTAssertEqual(fetchError.code, GTMSessionFetcherErrorUserCancelled);
    XCTAssertEqualObjects(fetchError.domain, kGTMSessionFetcherErrorDomain);
    [fetchCompleteExpectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  XCTAssertNil(decorator.fetchedData);
  XCTAssertEqual(decorator.fetchError.code, GTMSessionFetcherErrorUserCancelled);
  XCTAssertEqualObjects(decorator.fetchError.domain, kGTMSessionFetcherErrorDomain);
}

- (void)testMultipleDecodersStopFetchingInFirstPreventsRestTriggersCallback {
  GTMSessionFetcherTestDecorator *decoratorA = [[GTMSessionFetcherTestDecorator alloc]
      initWithFetcherWillStartBlock:^(
          GTMSessionFetcher *fetcher,
          GTMFetcherDecoratorFetcherWillStartCompletionHandler completion) {
        [fetcher stopFetching];
        completion(/*request=*/nil, /*error*/ nil);
      }
                        synchronous:YES];
  GTMSessionFetcherTestDecorator *decoratorB = [[GTMSessionFetcherTestDecorator alloc]
      initWithFetcherWillStartBlock:^(
          GTMSessionFetcher *fetcher,
          GTMFetcherDecoratorFetcherWillStartCompletionHandler completion) {
        XCTFail(@"Subsequent decorator should not be invoked");
      }
                        synchronous:YES];
  GTMSessionFetcherService *service =
      [GTMSessionFetcherService mockFetcherServiceWithFakedData:nil fakedError:nil];
  [service addDecorator:decoratorA];
  [service addDecorator:decoratorB];
  GTMSessionFetcher *fetcher = [service fetcherWithURLString:@"https://www.html5zombo.com"];
  fetcher.userAgentProvider = [[GTMUserAgentStringProvider alloc] initWithUserAgentString:@"Lynx"];
  fetcher.stopFetchingTriggersCompletionHandler = YES;
  XCTestExpectation *fetchCompleteExpectation = [self expectationWithDescription:@"Fetch complete"];
  [fetcher beginFetchWithCompletionHandler:^(__unused NSData *fetchData, NSError *fetchError) {
    XCTAssertEqual(fetchError.code, GTMSessionFetcherErrorUserCancelled);
    XCTAssertEqualObjects(fetchError.domain, kGTMSessionFetcherErrorDomain);
    [fetchCompleteExpectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  XCTAssertNil(decoratorA.fetchedData);
  XCTAssertNil(decoratorB.fetchedData);
  XCTAssertEqual(decoratorA.fetchError.code, GTMSessionFetcherErrorUserCancelled);
  XCTAssertEqualObjects(decoratorA.fetchError.domain, kGTMSessionFetcherErrorDomain);
  XCTAssertEqual(decoratorB.fetchError.code, GTMSessionFetcherErrorUserCancelled);
  XCTAssertEqualObjects(decoratorB.fetchError.domain, kGTMSessionFetcherErrorDomain);
}

- (void)testSingleDecoderStopFetchingAndContinueErrorTriggersCallbackWithRightError {
  NSError *error = [NSError errorWithDomain:@"TestDomain" code:12345 userInfo:nil];
  GTMSessionFetcherTestDecorator *decorator = [[GTMSessionFetcherTestDecorator alloc]
      initWithFetcherWillStartBlock:^(
          GTMSessionFetcher *fetcher,
          GTMFetcherDecoratorFetcherWillStartCompletionHandler completion) {
        [fetcher stopFetching];
        completion(/*request=*/nil, error);
      }
                        synchronous:YES];
  GTMSessionFetcherService *service =
      [GTMSessionFetcherService mockFetcherServiceWithFakedData:nil fakedError:nil];
  [service addDecorator:decorator];
  GTMSessionFetcher *fetcher = [service fetcherWithURLString:@"https://www.html5zombo.com"];
  fetcher.userAgentProvider = [[GTMUserAgentStringProvider alloc] initWithUserAgentString:@"Lynx"];
  fetcher.stopFetchingTriggersCompletionHandler = YES;
  XCTestExpectation *fetchCompleteExpectation = [self expectationWithDescription:@"Fetch complete"];
  [fetcher beginFetchWithCompletionHandler:^(__unused NSData *fetchData, NSError *fetchError) {
    XCTAssertEqual(fetchError.code, GTMSessionFetcherErrorUserCancelled);
    XCTAssertEqualObjects(fetchError.domain, kGTMSessionFetcherErrorDomain);
    [fetchCompleteExpectation fulfill];
  }];
  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
  XCTAssertNil(decorator.fetchedData);
  XCTAssertNotEqualObjects(decorator.fetchError, error);
  XCTAssertEqual(decorator.fetchError.code, GTMSessionFetcherErrorUserCancelled);
  XCTAssertEqualObjects(decorator.fetchError.domain, kGTMSessionFetcherErrorDomain);
}

- (void)testDelegateDispatcherForFetcher {
  GTMSessionFetcherService *service = [[GTMSessionFetcherService alloc] init];
  GTMSessionFetcher *fetcher;
  NSURLSession *session;
  NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];

  // When the NSURLSession delegate is the fetcher itself, the returned delegate dispatcher
  // should be nil.
  fetcher = [service fetcherWithURLString:@"https://www.example.com"];
  session = [NSURLSession sessionWithConfiguration:config
                                          delegate:fetcher
                                     delegateQueue:fetcher.sessionDelegateQueue];

  fetcher.session = session;
  XCTAssertNil([service delegateDispatcherForFetcher:fetcher],
               @"dispatcher should be nil when fetcher is the session delegate");
  [session invalidateAndCancel];

  // When the NSURLSession delegate is a proxy for a GTMSessionFetcher, the returned delegate
  // dispatcher should be nil.
  fetcher = [service fetcherWithURLString:@"https://www.example.com"];
  GTMSessionFetcherServiceTestObjectProxy *fetcherProxy =
      [GTMSessionFetcherServiceTestObjectProxy proxyForObject:fetcher];
  session = [NSURLSession sessionWithConfiguration:config
                                          delegate:(id<NSURLSessionDelegate>)fetcherProxy
                                     delegateQueue:fetcher.sessionDelegateQueue];
  fetcher.session = session;

  XCTAssertNil([service delegateDispatcherForFetcher:fetcher],
               @"dispatcher should be nil when session delegate is a proxy for GTMSessionFetcher");
  [session invalidateAndCancel];

  // When the NSURLSession delegate is the delegate dispatcher, the returned delegate dispatcher
  // should be non-nil.
  fetcher = [service fetcherWithURLString:@"https://www.example.com"];
  session = [NSURLSession sessionWithConfiguration:config
                                          delegate:service.sessionDelegate
                                     delegateQueue:fetcher.sessionDelegateQueue];

  fetcher.session = session;
  XCTAssertNotNil([service delegateDispatcherForFetcher:fetcher],
                  @"dispatcher should be non-nil when fetcher is the session delegate");
  [session invalidateAndCancel];

  // When the NSURLSession delegate is a proxy for a the delegate dispatcher, the returned delegate
  // dispatcher should be non-nil.
  fetcher = [service fetcherWithURLString:@"https://www.example.com"];
  GTMSessionFetcherServiceTestObjectProxy *dispatcherProxy =
      [GTMSessionFetcherServiceTestObjectProxy proxyForObject:service.sessionDelegate];
  session = [NSURLSession sessionWithConfiguration:config
                                          delegate:(id<NSURLSessionDelegate>)dispatcherProxy
                                     delegateQueue:fetcher.sessionDelegateQueue];
  fetcher.session = session;

  XCTAssertNotNil(
      [service delegateDispatcherForFetcher:fetcher],
      @"dispatcher should be non-nil when session delegate is a proxy for the dispatcher");
  [session invalidateAndCancel];
}

- (void)testFetcherUsingMetricsCollectionBlockFromFetcherService {
  if (!_isServerRunning) return;

  CREATE_START_STOP_NOTIFICATION_EXPECTATIONS(1, 1);

  __block NSURLSessionTaskMetrics *collectedMetrics = nil;

  GTMSessionFetcherService *service = [[GTMSessionFetcherService alloc] init];
  service.allowLocalhostRequest = YES;
  service.metricsCollectionBlock = ^(NSURLSessionTaskMetrics *_Nonnull metrics) {
    collectedMetrics = metrics;
  };

  NSURL *fetchURL = [_testServer localURLForFile:kValidFileName];
  GTMSessionFetcher *fetcher = [service fetcherWithURL:fetchURL];
  XCTestExpectation *expectation =
      [self expectationWithDescription:(id _Nonnull)fetchURL.absoluteString];
  [fetcher beginFetchWithCompletionHandler:^(NSData *fetchData, NSError *fetchError) {
    XCTAssertNotNil(fetchData);
    XCTAssertNil(fetchError);
    [expectation fulfill];
  }];

  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];

  WAIT_FOR_START_STOP_NOTIFICATION_EXPECTATIONS();

  XCTAssertNotNil(collectedMetrics);
}

- (void)testFetcherUsesStopFetchingTriggersCompletionHandlerFromFetcherService {
  if (!_isServerRunning) return;

  GTMSessionFetcherService *service = [[GTMSessionFetcherService alloc] init];
  service.allowLocalhostRequest = YES;
  service.stopFetchingTriggersCompletionHandler = YES;
  service.maxRunningFetchersPerHost = 1;

  NSURL *fetchURL = [_testServer localURLForFile:kValidFileName];

  // Use 5 fetchers:
  //  1. Blocking auth, will complete successfully. When it completes, it will stop the 4th fetcher.
  //  2. Uses an auth failing helper, will be stopped, so it shouldn't get to auth.
  //  3. Uses an auth failing helper, will be stopped, so it shouldn't get to auth, also don't
  //  enable the callback.
  //  4. No auth, just complete successfully.
  //  5. No auth, just a complete, but will be stopped.
  // This ensure they get started after each other and get to the point they should.

  GTMSessionFetcher *fetcher1 = [service fetcherWithURL:fetchURL];
  XCTestExpectation *authExpect = [self expectationWithDescription:@"Expect for auth block"];
  fetcher1.authorizer = [TestAuthorizer asyncWithBlockedTimeout:1 testExpectation:authExpect];

  GTMSessionFetcher *fetcher2 = [service fetcherWithURL:fetchURL];
  fetcher2.authorizer = [TestAuthorizer syncAuthorizer];
  ((TestAuthorizer *)fetcher2.authorizer).workBlock = ^{
    XCTFail(@"Fetcher2: Should not get here since it was stopped.");
  };

  GTMSessionFetcher *fetcher3 = [service fetcherWithURL:fetchURL];
  fetcher3.stopFetchingTriggersCompletionHandler = NO;  // Reset back to no
  fetcher3.authorizer = [TestAuthorizer syncAuthorizer];
  ((TestAuthorizer *)fetcher3.authorizer).workBlock = ^{
    XCTFail(@"Fetcher3: Should not get here since it was stopped.");
  };

  GTMSessionFetcher *fetcher4 = [service fetcherWithURL:fetchURL];

  GTMSessionFetcher *fetcher5 = [service fetcherWithURL:fetchURL];

  // Fetchers 1 and 3 will actually run, 2 and 4 should never fully start, so there should be two
  // started/stopped notifications, but all 4 should get completion invoked.
  XCTestExpectation *fetcherStartedExpectation =
      [self expectationForNotification:kGTMSessionFetcherStartedNotification
                                object:nil
                               handler:nil];
  fetcherStartedExpectation.expectedFulfillmentCount = 2;
  XCTestExpectation *fetcherStoppedExpectation =
      [self expectationForNotification:kGTMSessionFetcherStoppedNotification
                                object:nil
                               handler:nil];
  fetcherStoppedExpectation.expectedFulfillmentCount = 2;
  XCTestExpectation *fetcherCompletionInvokedExpecation =
      [self expectationForNotification:kGTMSessionFetcherCompletionInvokedNotification
                                object:nil
                               handler:nil];
  fetcherCompletionInvokedExpecation.expectedFulfillmentCount = 4;

  // Nothing started
  XCTAssertEqual(service.runningFetchersByHost.count, (NSUInteger)0);
  XCTAssertEqual(service.delayedFetchersByHost.count, (NSUInteger)0);

  XCTestExpectation *completionExpectation =
      [self expectationWithDescription:@"Completion expection"];
  completionExpectation.expectedFulfillmentCount = 4;

  [fetcher1 beginFetchWithCompletionHandler:^(NSData *_Nullable data, NSError *_Nullable error) {
    XCTAssertNotNil(data);
    XCTAssertNil(error);
    // and stop the 4th one.
    [fetcher5 stopFetching];
    [completionExpectation fulfill];
  }];

  [fetcher2 beginFetchWithCompletionHandler:^(NSData *_Nullable data, NSError *_Nullable error) {
    XCTAssertNil(data);
    XCTAssertNotNil(error);
    XCTAssertEqual(error.domain, kGTMSessionFetcherErrorDomain);
    XCTAssertEqual(error.code, GTMSessionFetcherErrorUserCancelled);
    [completionExpectation fulfill];
  }];

  [fetcher3 beginFetchWithCompletionHandler:^(NSData *_Nullable data, NSError *_Nullable error) {
    XCTFail(@"Should not get invoked for stopFetcher -- data: %@, error: %@", data, error);
  }];

  [fetcher4 beginFetchWithCompletionHandler:^(NSData *_Nullable data, NSError *_Nullable error) {
    XCTAssertNotNil(data);
    XCTAssertNil(error);
    [completionExpectation fulfill];
  }];

  [fetcher5 beginFetchWithCompletionHandler:^(NSData *_Nullable data, NSError *_Nullable error) {
    XCTAssertNil(data);
    XCTAssertNotNil(error);
    XCTAssertEqual(error.domain, kGTMSessionFetcherErrorDomain);
    XCTAssertEqual(error.code, GTMSessionFetcherErrorUserCancelled);
    [completionExpectation fulfill];
  }];

  // There should be one running for localhost, and four delayed for localhost.
  XCTAssertEqual(service.runningFetchersByHost.count, (NSUInteger)1);
  XCTAssertEqual(service.runningFetchersByHost[@"localhost"].count, 1);
  XCTAssertEqual(service.delayedFetchersByHost.count, (NSUInteger)1, );
  XCTAssertEqual(service.delayedFetchersByHost[@"localhost"].count, 4);

  // Stop first, and then unblock the authorizer to let the rest happen.
  [fetcher2 stopFetching];
  [fetcher3 stopFetching];
  [(TestAuthorizer *)fetcher1.authorizer unblock];

  [self waitForExpectationsWithTimeout:_timeoutInterval handler:nil];
}

@end

#endif  // !TARGET_OS_WATCH
