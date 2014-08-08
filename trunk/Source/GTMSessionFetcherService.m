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

#import "GTMSessionFetcherService.h"

@interface GTMSessionFetcher (ServiceMethods)

- (BOOL)beginFetchMayDelay:(BOOL)mayDelay
              mayAuthorize:(BOOL)mayAuthorize;

@end

@interface GTMSessionFetcherService ()

@property(atomic, strong, readwrite) NSDictionary *delayedFetchersByHost;
@property(atomic, strong, readwrite) NSDictionary *runningFetchersByHost;

- (void)detachAuthorizer;

@end

@implementation GTMSessionFetcherService {
  NSMutableDictionary *_delayedFetchersByHost;
  NSMutableDictionary *_runningFetchersByHost;
  NSUInteger _maxRunningFetchersPerHost;

  dispatch_queue_t _callbackQueue;
  NSHTTPCookieStorage *_cookieStorage;
  NSString *_userAgent;
  NSTimeInterval _timeout;

  NSURLCredential *_credential;       // Username & password.
  NSURLCredential *_proxyCredential;  // Credential supplied to proxy servers.

  NSInteger _cookieStorageMethod;

  id<GTMFetcherAuthorizationProtocol> _authorizer;

  // For waitForCompletionOfAllFetchersWithTimeout: we need to wait on stopped fetchers since
  // they've not yet finished invoking their queued callbacks. This array is nil except when
  // waiting on fetchers.
  NSMutableArray *_stoppedFetchersToWaitFor;
}

@synthesize maxRunningFetchersPerHost = _maxRunningFetchersPerHost,
            configuration = _configuration,
            configurationBlock = _configurationBlock,
            cookieStorage = _cookieStorage,
            userAgent = _userAgent,
            callbackQueue = _callbackQueue,
            credential = _credential,
            proxyCredential = _proxyCredential,
            allowedInsecureSchemes = _allowedInsecureSchemes,
            allowLocalhostRequest = _allowLocalhostRequest,
            allowInvalidServerCertificates = _allowInvalidServerCertificates;

- (id)init {
  self = [super init];
  if (self) {
    _delayedFetchersByHost = [[NSMutableDictionary alloc] init];
    _runningFetchersByHost = [[NSMutableDictionary alloc] init];
    _maxRunningFetchersPerHost = 10;
    _cookieStorageMethod = -1;
  }
  return self;
}

- (void)dealloc {
  [self detachAuthorizer];
}

#pragma mark Generate a new fetcher

- (id)fetcherWithRequest:(NSURLRequest *)request
            fetcherClass:(Class)fetcherClass {
  GTMSessionFetcher *fetcher = [[fetcherClass alloc] initWithRequest:request
                                                       configuration:self.configuration];
  if (self.callbackQueue) {
    fetcher.callbackQueue = self.callbackQueue;
  }
  fetcher.credential = self.credential;
  fetcher.proxyCredential = self.proxyCredential;
  fetcher.authorizer = self.authorizer;
  fetcher.cookieStorage = self.cookieStorage;
  fetcher.allowedInsecureSchemes = self.allowedInsecureSchemes;
  fetcher.allowLocalhostRequest = self.allowLocalhostRequest;
  fetcher.allowInvalidServerCertificates = self.allowInvalidServerCertificates;
  fetcher.configurationBlock = self.configurationBlock;
  fetcher.service = self;
  if (_cookieStorageMethod >= 0) {
    [fetcher setCookieStorageMethod:_cookieStorageMethod];
  }

  NSString *userAgent = self.userAgent;
  if ([userAgent length] > 0
      && [request valueForHTTPHeaderField:@"User-Agent"] == nil) {
    [fetcher.mutableRequest setValue:userAgent
                  forHTTPHeaderField:@"User-Agent"];
  }
  fetcher.testBlock = self.testBlock;

  return fetcher;
}

- (GTMSessionFetcher *)fetcherWithRequest:(NSURLRequest *)request {
  return [self fetcherWithRequest:request
                     fetcherClass:[GTMSessionFetcher class]];
}

- (GTMSessionFetcher *)fetcherWithURL:(NSURL *)requestURL {
  return [self fetcherWithRequest:[NSURLRequest requestWithURL:requestURL]];
}

- (GTMSessionFetcher *)fetcherWithURLString:(NSString *)requestURLString {
  return [self fetcherWithURL:[NSURL URLWithString:requestURLString]];
}

#pragma mark Queue Management

- (void)addRunningFetcher:(GTMSessionFetcher *)fetcher
                  forHost:(NSString *)host {
  // Add to the array of running fetchers for this host, creating the array if needed.
  NSMutableArray *runningForHost = [_runningFetchersByHost objectForKey:host];
  if (runningForHost == nil) {
    runningForHost = [NSMutableArray arrayWithObject:fetcher];
    [_runningFetchersByHost setObject:runningForHost forKey:host];
  } else {
    [runningForHost addObject:fetcher];
  }
}

- (void)addDelayedFetcher:(GTMSessionFetcher *)fetcher
                  forHost:(NSString *)host {
  // Add to the array of delayed fetchers for this host, creating the array if needed.
  NSMutableArray *delayedForHost = [_delayedFetchersByHost objectForKey:host];
  if (delayedForHost == nil) {
    delayedForHost = [NSMutableArray arrayWithObject:fetcher];
    [_delayedFetchersByHost setObject:delayedForHost forKey:host];
  } else {
    [delayedForHost addObject:fetcher];
  }
}

- (BOOL)isDelayingFetcher:(GTMSessionFetcher *)fetcher {
  @synchronized(self) {
    NSString *host = [[[fetcher mutableRequest] URL] host];
    if (host == nil) {
      return NO;
    }
    NSArray *delayedForHost = [_delayedFetchersByHost objectForKey:host];
    NSUInteger idx = [delayedForHost indexOfObjectIdenticalTo:fetcher];
    BOOL isDelayed = (delayedForHost != nil) && (idx != NSNotFound);
    return isDelayed;
  }
}

- (BOOL)fetcherShouldBeginFetching:(GTMSessionFetcher *)fetcher {
  // Entry point from the fetcher
  @synchronized(self) {
    NSURL *requestURL = [[fetcher mutableRequest] URL];
    NSString *host = [requestURL host];

    // Addresses "file:///path" case where localhost is the implicit host.
    if ([host length] == 0 && [requestURL isFileURL]) {
      host = @"localhost";
    }

    if ([host length] == 0) {
      // Data URIs legitimately have no host, reject other hostless URLs.
      GTMSESSION_ASSERT_DEBUG([[requestURL scheme] isEqual:@"data"], @"%@ lacks host", fetcher);
      return YES;
    }

    NSMutableArray *runningForHost = [_runningFetchersByHost objectForKey:host];
    if (runningForHost != nil
        && [runningForHost indexOfObjectIdenticalTo:fetcher] != NSNotFound) {
      GTMSESSION_ASSERT_DEBUG(NO, @"%@ was already running", fetcher);
      return YES;
    }

    // We'll save the host that serves as the key for this fetcher's array
    // to avoid any chance of the underlying request changing, stranding
    // the fetcher in the wrong array
    fetcher.serviceHost = host;

    if (fetcher.useBackgroundSession
        || _maxRunningFetchersPerHost == 0
        || _maxRunningFetchersPerHost >
           [[self class] numberOfNonBackgroundSessionFetchers:runningForHost]) {
      [self addRunningFetcher:fetcher forHost:host];
      return YES;
    } else {
      [self addDelayedFetcher:fetcher forHost:host];
      return NO;
    }
  }
  return YES;
}

- (void)startFetcher:(GTMSessionFetcher *)fetcher {
  [fetcher beginFetchMayDelay:NO
                 mayAuthorize:YES];
}

- (void)stopFetcher:(GTMSessionFetcher *)fetcher {
  [fetcher stopFetching];
}

- (void)fetcherDidStop:(GTMSessionFetcher *)fetcher {
  // Entry point from the fetcher
  @synchronized(self) {
    NSString *host = fetcher.serviceHost;
    if (!host) {
      // fetcher has been stopped previously
      return;
    }

    // If a test is waiting for all fetchers to stop, it needs to wait for this one
    // to invoke its callbacks on the callback queue.
    [_stoppedFetchersToWaitFor addObject:fetcher];

    NSMutableArray *runningForHost = [_runningFetchersByHost objectForKey:host];
    [runningForHost removeObject:fetcher];

    NSMutableArray *delayedForHost = [_delayedFetchersByHost objectForKey:host];
    [delayedForHost removeObject:fetcher];

    while ([delayedForHost count] > 0
           && [[self class] numberOfNonBackgroundSessionFetchers:runningForHost]
              < _maxRunningFetchersPerHost) {
      // Start another delayed fetcher running, scanning for the minimum
      // priority value, defaulting to FIFO for equal priorities
      GTMSessionFetcher *nextFetcher = nil;
      for (GTMSessionFetcher *delayedFetcher in delayedForHost) {
        if (nextFetcher == nil
            || delayedFetcher.servicePriority < nextFetcher.servicePriority) {
          nextFetcher = delayedFetcher;
        }
      }

      if (nextFetcher) {
        [self addRunningFetcher:nextFetcher forHost:host];
        runningForHost = [_runningFetchersByHost objectForKey:host];

        [delayedForHost removeObjectIdenticalTo:nextFetcher];
        [self startFetcher:nextFetcher];
      }
    }

    if ([runningForHost count] == 0) {
      // None left; remove the empty array
      [_runningFetchersByHost removeObjectForKey:host];
    }

    if ([delayedForHost count] == 0) {
      [_delayedFetchersByHost removeObjectForKey:host];
    }

    // The fetcher is no longer in the running or the delayed array,
    // so remove its host and thread properties
    fetcher.serviceHost = nil;
  }
}

- (NSUInteger)numberOfFetchers {
  @synchronized(self) {
    NSUInteger running = [self numberOfRunningFetchers];
    NSUInteger delayed = [self numberOfDelayedFetchers];
    return running + delayed;
  }
}

- (NSUInteger)numberOfRunningFetchers {
  @synchronized(self) {
    NSUInteger sum = 0;
    for (NSString *host in _runningFetchersByHost) {
      NSArray *fetchers = [_runningFetchersByHost objectForKey:host];
      sum += [fetchers count];
    }
    return sum;
  }
}

- (NSUInteger)numberOfDelayedFetchers {
  @synchronized(self) {
    NSUInteger sum = 0;
    for (NSString *host in _delayedFetchersByHost) {
      NSArray *fetchers = [_delayedFetchersByHost objectForKey:host];
      sum += [fetchers count];
    }
    return sum;
  }
}

- (NSArray *)issuedFetchers {
  @synchronized(self) {
    NSMutableArray *allFetchers = [NSMutableArray array];
    void (^accumulateFetchers)(id, id, BOOL *) = ^(NSString *host,
                                                   NSArray *fetchersForHost,
                                                   BOOL *stop) {
        [allFetchers addObjectsFromArray:fetchersForHost];
    };
    [_runningFetchersByHost enumerateKeysAndObjectsUsingBlock:accumulateFetchers];
    [_delayedFetchersByHost enumerateKeysAndObjectsUsingBlock:accumulateFetchers];

    GTMSESSION_ASSERT_DEBUG([allFetchers count] == [[NSSet setWithArray:allFetchers] count],
                            @"Fetcher appears multiple times\n running: %@\n delayed: %@",
                            _runningFetchersByHost, _delayedFetchersByHost);

    return [allFetchers count] > 0 ? allFetchers : nil;
  }
}

- (NSArray *)issuedFetchersWithRequestURL:(NSURL *)requestURL {
  NSString *host = [requestURL host];
  if ([host length] == 0) return nil;

  NSURL *targetURL = [requestURL absoluteURL];

  NSArray *allFetchers = [self issuedFetchers];
  NSIndexSet *indexes = [allFetchers indexesOfObjectsPassingTest:^BOOL(id fetcher,
                                                                       NSUInteger idx,
                                                                       BOOL *stop) {
      NSURL *fetcherURL = [[[fetcher mutableRequest] URL] absoluteURL];
      return [fetcherURL isEqual:targetURL];
  }];

  NSArray *result = nil;
  if ([indexes count] > 0) {
    result = [allFetchers objectsAtIndexes:indexes];
  }
  return result;
}

- (void)stopAllFetchers {
  @synchronized(self) {
    // Remove fetchers from the delayed list to avoid fetcherDidStop: from
    // starting more fetchers running as a side effect of stopping one
    NSArray *delayedFetchersByHost = [_delayedFetchersByHost allValues];
    [_delayedFetchersByHost removeAllObjects];

    for (NSArray *delayedForHost in delayedFetchersByHost) {
      for (GTMSessionFetcher *fetcher in delayedForHost) {
        [self stopFetcher:fetcher];
      }
    }

    NSArray *runningFetchersByHost = [_runningFetchersByHost allValues];
    [_runningFetchersByHost removeAllObjects];

    for (NSArray *runningForHost in runningFetchersByHost) {
      for (GTMSessionFetcher *fetcher in runningForHost) {
        [self stopFetcher:fetcher];
      }
    }
  }
}

#pragma mark Synchronous Wait for Unit Testing

- (void)waitForCompletionOfAllFetchersWithTimeout:(NSTimeInterval)timeoutInSeconds {
  NSDate *giveUpDate = [NSDate dateWithTimeIntervalSinceNow:timeoutInSeconds];
  _stoppedFetchersToWaitFor = [NSMutableArray array];

  BOOL shouldSpinRunLoop = [NSThread isMainThread];
  const NSTimeInterval kSpinInterval = 0.001;
  while (([self numberOfFetchers] > 0 || [_stoppedFetchersToWaitFor count] > 0)
         && [giveUpDate timeIntervalSinceNow] > 0) {
    GTMSessionFetcher *stoppedFetcher = [_stoppedFetchersToWaitFor firstObject];
    if (stoppedFetcher) {
      [_stoppedFetchersToWaitFor removeObject:stoppedFetcher];
      [stoppedFetcher waitForCompletionWithTimeout:10.0 * kSpinInterval];
    }

    if (shouldSpinRunLoop) {
      NSDate *stopDate = [NSDate dateWithTimeIntervalSinceNow:kSpinInterval];
      [[NSRunLoop currentRunLoop] runUntilDate:stopDate];
    } else {
      [NSThread sleepForTimeInterval:kSpinInterval];
    }
  }
  _stoppedFetchersToWaitFor = nil;
}

#pragma mark Accessors

- (NSDictionary *)runningFetchersByHost {
  return _runningFetchersByHost;
}

- (void)setRunningFetchersByHost:(NSDictionary *)dict {
  _runningFetchersByHost = [dict mutableCopy];
}

- (NSDictionary *)delayedFetchersByHost {
  return _delayedFetchersByHost;
}

- (void)setDelayedFetchersByHost:(NSDictionary *)dict {
  _delayedFetchersByHost = [dict mutableCopy];
}

- (id<GTMFetcherAuthorizationProtocol>)authorizer {
  return _authorizer;
}

- (void)setAuthorizer:(id<GTMFetcherAuthorizationProtocol>)obj {
  if (obj != _authorizer) {
    [self detachAuthorizer];
  }

  _authorizer = obj;

  // Use the fetcher service for the authorization fetches if the auth
  // object supports fetcher services
  if ([_authorizer respondsToSelector:@selector(setFetcherService:)]) {
#if GTM_USE_SESSION_FETCHER
    [_authorizer setFetcherService:self];
#else
    [_authorizer setFetcherService:(id)self];
#endif
  }
}

- (void)detachAuthorizer {
  // This method is called by the fetcher service's dealloc and setAuthorizer:
  // methods; do not override.
  //
  // The fetcher service retains the authorizer, and the authorizer has a
  // weak pointer to the fetcher service (a non-zeroing pointer for
  // compatibility with iOS 4 and Mac OS X 10.5/10.6.)
  //
  // When this fetcher service no longer uses the authorizer, we want to remove
  // the authorizer's dependence on the fetcher service.  Authorizers can still
  // function without a fetcher service.
  if ([_authorizer respondsToSelector:@selector(fetcherService)]) {
    id authFetcherService = [_authorizer fetcherService];
    if (authFetcherService == self) {
      [_authorizer setFetcherService:nil];
    }
  }
}

- (NSOperationQueue *)delegateQueue {
  // Provided for compatibility with the old fetcher service.  The gtm-oauth2 code respects
  // any custom delegate queue for calling the app.
  return nil;
}

+ (NSUInteger)numberOfNonBackgroundSessionFetchers:(NSArray *)fetchers {
  NSUInteger sum = 0;
  for (GTMSessionFetcher *fetcher in fetchers) {
    if (!fetcher.useBackgroundSession) {
      ++sum;
    }
  }
  return sum;
}

@end

@implementation GTMSessionFetcherService (BackwardsCompatibilityOnly)

- (NSInteger)cookieStorageMethod {
  return _cookieStorageMethod;
}

- (void)setCookieStorageMethod:(NSInteger)cookieStorageMethod {
  _cookieStorageMethod = cookieStorageMethod;
}

@end
