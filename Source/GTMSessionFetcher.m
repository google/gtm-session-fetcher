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

#import "GTMSessionFetcher.h"

#import <sys/utsname.h>

// For iOS, the fetcher can declare itself a background task to allow fetches to finish
// up when the app leaves the foreground.  This is distinct from providing a background
// configuration, which allows out-of-process uploads and downloads.
#if TARGET_OS_IPHONE && !defined(GTM_BACKGROUND_TASK_FETCHING)
#define GTM_BACKGROUND_TASK_FETCHING 1
#endif

NSString *const kGTMSessionFetcherStartedNotification           = @"kGTMSessionFetcherStartedNotification";
NSString *const kGTMSessionFetcherStoppedNotification           = @"kGTMSessionFetcherStoppedNotification";
NSString *const kGTMSessionFetcherRetryDelayStartedNotification = @"kGTMSessionFetcherRetryDelayStartedNotification";
NSString *const kGTMSessionFetcherRetryDelayStoppedNotification = @"kGTMSessionFetcherRetryDelayStoppedNotification";

NSString *const kGTMSessionFetcherErrorDomain       = @"com.google.GTMSessionFetcher";
NSString *const kGTMSessionFetcherStatusDomain      = @"com.google.HTTPStatus";
NSString *const kGTMSessionFetcherStatusDataKey     = @"data";  // data returned with a kGTMSessionFetcherStatusDomain error

static NSString *const kGTMSessionIdentifierPrefix = @"com.google.GTMSessionFetcher";
static NSString *const kGTMSessionIdentifierDestinationFileURLMetadataKey = @"_destURL";
static NSString *const kGTMSessionIdentifierBodyFileURLMetadataKey        = @"_bodyURL";

// The default max retry interview is 10 minutes for uploads (POST/PUT/PATCH),
// 1 minute for downloads.
static const NSTimeInterval kUnsetMaxRetryInterval = -1.0;
static const NSTimeInterval kDefaultMaxDownloadRetryInterval = 60.0;
static const NSTimeInterval kDefaultMaxUploadRetryInterval = 60.0 * 10.;

#ifdef GTMSESSION_PERSISTED_DESTINATION_KEY
// Projects using unique class names should also define a unique persisted destination key.
static NSString * const kGTMSessionFetcherPersistedDestinationKey =
    GTMSESSION_PERSISTED_DESTINATION_KEY;
#else
static NSString * const kGTMSessionFetcherPersistedDestinationKey =
    @"com.google.GTMSessionFetcher.downloads";
#endif

//
// GTMSessionFetcher
//

#if 0
#define GTM_LOG_BACKGROUND_SESSION(...) GTMSESSION_LOG_DEBUG(__VA_ARGS__)
#else
#define GTM_LOG_BACKGROUND_SESSION(...)
#endif

#ifndef GTM_TARGET_SUPPORTS_APP_TRANSPORT_SECURITY
  #if (!TARGET_OS_IPHONE && defined(MAC_OS_X_VERSION_10_11) && MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_11) \
      || (TARGET_OS_IPHONE && defined(__IPHONE_9_0) && __IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_9_0)
    #define GTM_TARGET_SUPPORTS_APP_TRANSPORT_SECURITY 1
  #endif
#endif

@interface GTMSessionFetcher ()

@property(strong, readwrite) NSData *downloadedData;
@property(strong, readwrite) NSMutableURLRequest *mutableRequest;

@end

@interface GTMSessionFetcher (GTMSessionFetcherLoggingInternal)
- (void)logFetchWithError:(NSError *)error;
- (void)logNowWithError:(NSError *)error;
- (NSInputStream *)loggedInputStreamForInputStream:(NSInputStream *)inputStream;
- (GTMSessionFetcherBodyStreamProvider)loggedStreamProviderForStreamProvider:
    (GTMSessionFetcherBodyStreamProvider)streamProvider;
@end

static NSTimeInterval InitialMinRetryInterval(void) {
  return 1.0 + ((double)(arc4random_uniform(0x0FFFF)) / (double) 0x0FFFF);
}

static BOOL IsLocalhost(NSString *host) {
  // We check if there's host, and then make the comparisons.
  if (host == nil) return NO;
  return ([host caseInsensitiveCompare:@"localhost"] == NSOrderedSame
          || [host isEqual:@"::1"]
          || [host isEqual:@"127.0.0.1"]);
}

static GTMSessionFetcherTestBlock gGlobalTestBlock;

@implementation GTMSessionFetcher {
  NSMutableURLRequest *_request;
  NSURLSession *_session;
  BOOL _shouldInvalidateSession;
  NSURLSessionConfiguration *_configuration;
  NSURLSessionTask *_sessionTask;
  NSString *_taskDescription;
  float _taskPriority;
  NSURLResponse *_response;
  NSString *_sessionIdentifier;
  BOOL _didCreateSessionIdentifier;
  NSString *_sessionIdentifierUUID;
  BOOL _useBackgroundSession;
  NSMutableData *_downloadedData;
  NSError *_downloadFinishedError;
  NSData *_downloadResumeData;
  NSURL *_destinationFileURL;
  int64_t _downloadedLength;
  NSURLCredential *_credential;     // username & password
  NSURLCredential *_proxyCredential; // credential supplied to proxy servers
  BOOL _isStopNotificationNeeded;   // set when start notification has been sent
  BOOL _isUsingTestBlock;  // set when a test block was provided (remains set when the block is released)
#if GTM_BACKGROUND_TASK_FETCHING
  UIBackgroundTaskIdentifier _backgroundTaskIdentifer;  // set when fetch begins; accessed only on main thread
#endif
  id _userData;                     // retained, if set by caller
  NSMutableDictionary *_properties; // more data retained for caller
  dispatch_queue_t _callbackQueue;
  dispatch_group_t _callbackGroup;  // read-only after creation
  NSOperationQueue *_delegateQueue;

  id<GTMFetcherAuthorizationProtocol> _authorizer;

  // The service object that created and monitors this fetcher, if any
  id<GTMSessionFetcherServiceProtocol> _service;
  NSString *_serviceHost;
  NSInteger _servicePriority;
  BOOL _userStoppedFetching;

  BOOL _isRetryEnabled;             // user wants auto-retry
  NSTimer *_retryTimer;
  NSUInteger _retryCount;
  NSTimeInterval _maxRetryInterval; // default 60 (download) or 600 (upload) seconds
  NSTimeInterval _minRetryInterval; // random between 1 and 2 seconds
  NSTimeInterval _retryFactor;      // default interval multiplier is 2
  NSTimeInterval _lastRetryInterval;
  NSDate *_initialRequestDate;
  BOOL _hasAttemptedAuthRefresh;

  NSString *_comment;               // comment for log
  NSString *_log;
#if !STRIP_GTM_FETCH_LOGGING
  NSMutableData *_loggedStreamData;
  NSURL *_redirectedFromURL;
  NSString *_logRequestBody;
  NSString *_logResponseBody;
  BOOL _hasLoggedError;
  BOOL _deferResponseBodyLogging;
#endif
}

+ (void)load {
  [self fetchersForBackgroundSessions];
}

+ (instancetype)fetcherWithRequest:(NSURLRequest *)request {
  return [[self alloc] initWithRequest:request configuration:nil];
}

+ (instancetype)fetcherWithURL:(NSURL *)requestURL {
  return [self fetcherWithRequest:[NSURLRequest requestWithURL:requestURL]];
}

+ (instancetype)fetcherWithURLString:(NSString *)requestURLString {
  return [self fetcherWithURL:[NSURL URLWithString:requestURLString]];
}

+ (instancetype)fetcherWithDownloadResumeData:(NSData *)resumeData {
  GTMSessionFetcher *fetcher = [self fetcherWithRequest:nil];
  fetcher.comment = @"Resuming download";
  fetcher.downloadResumeData = resumeData;
  return fetcher;
}

+ (instancetype)fetcherWithSessionIdentifier:(NSString *)sessionIdentifier {
  GTMSESSION_ASSERT_DEBUG(sessionIdentifier != nil, @"Invalid session identifier");
  NSMapTable *sessionIdentifierToFetcherMap = [self sessionIdentifierToFetcherMap];
  GTMSessionFetcher *fetcher = [sessionIdentifierToFetcherMap objectForKey:sessionIdentifier];
  if (!fetcher && [sessionIdentifier hasPrefix:kGTMSessionIdentifierPrefix]) {
    fetcher = [self fetcherWithRequest:nil];
    [fetcher setSessionIdentifier:sessionIdentifier];
    [sessionIdentifierToFetcherMap setObject:fetcher forKey:sessionIdentifier];
    [fetcher setCommentWithFormat:@"Resuming %@",
     fetcher && fetcher->_sessionIdentifierUUID ? fetcher->_sessionIdentifierUUID : @"?"];
  }
  return fetcher;
}

+ (NSMapTable *)sessionIdentifierToFetcherMap {
  // TODO: What if a service is involved in creating the fetcher? Currently, when re-creating
  // fetchers, if a service was involved, it is not re-created. Should the service maintain a map?
  static NSMapTable *gSessionIdentifierToFetcherMap = nil;

  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    gSessionIdentifierToFetcherMap = [NSMapTable strongToWeakObjectsMapTable];
  });
  return gSessionIdentifierToFetcherMap;
}

#if !GTM_ALLOW_INSECURE_REQUESTS
+ (BOOL)appAllowsInsecureRequests {
  // If the main bundle Info.plist key NSAppTransportSecurity is present, and it specifies
  // NSAllowsArbitraryLoads, then we need to explicitly enforce secure schemes.
#if GTM_TARGET_SUPPORTS_APP_TRANSPORT_SECURITY
  static BOOL allowsInsecureRequests;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    NSBundle *mainBundle = [NSBundle mainBundle];
    NSDictionary *appTransportSecurity =
        [mainBundle objectForInfoDictionaryKey:@"NSAppTransportSecurity"];
    allowsInsecureRequests =
        [[appTransportSecurity objectForKey:@"NSAllowsArbitraryLoads"] boolValue];
  });
  return allowsInsecureRequests;
#else
  // For builds targeting iOS 8 or 10.10 and earlier, we want to require fetcher
  // security checks.
  return YES;
#endif  // GTM_TARGET_SUPPORTS_APP_TRANSPORT_SECURITY
}
#else  // GTM_ALLOW_INSECURE_REQUESTS
+ (BOOL)appAllowsInsecureRequests {
  return YES;
}
#endif  // !GTM_ALLOW_INSECURE_REQUESTS


- (instancetype)init {
  return [self initWithRequest:nil configuration:nil];
}

- (instancetype)initWithRequest:(NSURLRequest *)request  {
  return [self initWithRequest:request configuration:nil];
}

- (instancetype)initWithRequest:(NSURLRequest *)request
                  configuration:(NSURLSessionConfiguration *)configuration {
  self = [super init];
  if (self) {
    if (![NSURLSession class]) {
      Class oldFetcherClass = NSClassFromString(@"GTMHTTPFetcher");
      if (oldFetcherClass) {
        self = [[oldFetcherClass alloc] initWithRequest:request];
      } else {
        self = nil;
      }
      return self;
    }
#if GTM_BACKGROUND_TASK_FETCHING
    _backgroundTaskIdentifer = UIBackgroundTaskInvalid;
#endif
    _request = [request mutableCopy];
    _configuration = configuration;

    NSData *bodyData = [request HTTPBody];
    if (bodyData) {
      _bodyLength = (int64_t)[bodyData length];
    } else {
      _bodyLength = NSURLSessionTransferSizeUnknown;
    }

    _callbackQueue = dispatch_get_main_queue();
    _callbackGroup = dispatch_group_create();
    _delegateQueue = [NSOperationQueue mainQueue];

    _minRetryInterval = InitialMinRetryInterval();
    _maxRetryInterval = kUnsetMaxRetryInterval;

    _taskPriority = -1.0f;  // Valid values if set are 0.0...1.0.

#if !STRIP_GTM_FETCH_LOGGING
    // Encourage developers to set the comment property or use
    // setCommentWithFormat: by providing a default string.
    _comment = @"(No fetcher comment set)";
#endif
  }
  return self;
}

- (id)copyWithZone:(NSZone *)zone {
  // disallow use of fetchers in a copy property
  [self doesNotRecognizeSelector:_cmd];
  return nil;
}

- (NSString *)description {
  return [NSString stringWithFormat:@"%@ %p (%@)",
          [self class], self, [self.mutableRequest URL]];
}

- (void)dealloc {
  GTMSESSION_ASSERT_DEBUG(!_isStopNotificationNeeded,
                          @"unbalanced fetcher notification for %@", [_request URL]);
  [self forgetSessionIdentifierForFetcher];

  // Note: if a session task or a retry timer was pending, then this instance
  // would be retained by those so it wouldn't be getting dealloc'd,
  // hence we don't need to stopFetch here
}

#pragma mark -

// Begin fetching the URL (or begin a retry fetch).  The delegate is retained
// for the duration of the fetch connection.

- (void)beginFetchWithCompletionHandler:(GTMSessionFetcherCompletionHandler)handler {
  _completionHandler = [handler copy];

  // The user may have called setDelegate: earlier if they want to use other
  // delegate-style callbacks during the fetch; otherwise, the delegate is nil,
  // which is fine.
  [self beginFetchMayDelay:YES mayAuthorize:YES];
}

- (GTMSessionFetcherCompletionHandler)completionHandlerWithTarget:(id)target
                                                didFinishSelector:(SEL)finishedSelector {
  GTMSessionFetcherAssertValidSelector(target, finishedSelector, @encode(GTMSessionFetcher *),
                                       @encode(NSData *), @encode(NSError *), 0);
  GTMSessionFetcherCompletionHandler completionHandler = ^(NSData *data, NSError *error) {
      if (target && finishedSelector) {
        id selfArg = self;  // Placate ARC.
        NSMethodSignature *sig = [target methodSignatureForSelector:finishedSelector];
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:sig];
        [invocation setSelector:finishedSelector];
        [invocation setTarget:target];
        [invocation setArgument:&selfArg atIndex:2];
        [invocation setArgument:&data atIndex:3];
        [invocation setArgument:&error atIndex:4];
        [invocation invoke];
      }
  };
  return completionHandler;
}

- (void)beginFetchWithDelegate:(id)target
             didFinishSelector:(SEL)finishedSelector {
  GTMSessionFetcherCompletionHandler handler =  [self completionHandlerWithTarget:target
                                                                didFinishSelector:finishedSelector];
  [self beginFetchWithCompletionHandler:handler];
}

- (void)beginFetchMayDelay:(BOOL)mayDelay
              mayAuthorize:(BOOL)mayAuthorize {
  // This is the internal entry point for re-starting fetches.

  // A utility block for creating error objects when we fail to start the fetch.
  NSError *(^beginFailureError)(NSInteger) = ^(NSInteger code){
    NSString *urlString = [[_request URL] absoluteString];
    NSDictionary *userInfo = @{
      NSURLErrorFailingURLStringErrorKey : (urlString ? urlString : @"(missing URL)")
    };
    return [NSError errorWithDomain:kGTMSessionFetcherErrorDomain
                               code:code
                           userInfo:userInfo];
  };

  if (_sessionTask != nil) {
    // If cached fetcher returned through fetcherWithSessionIdentifier:, then it's
    // already begun, but don't consider this a failure, since the user need not know this.
    if (_sessionIdentifier != nil) {
      return;
    }
    GTMSESSION_ASSERT_DEBUG(NO, @"Fetch object %@ being reused; this should never happen", self);
    [self failToBeginFetchWithError:beginFailureError(GTMSessionFetcherErrorDownloadFailed)];
    return;
  }

  NSURL *requestURL = [_request URL];
  if (requestURL == nil && !_downloadResumeData && !_sessionIdentifier) {
    GTMSESSION_ASSERT_DEBUG(NO, @"Beginning a fetch requires a request with a URL");
    [self failToBeginFetchWithError:beginFailureError(GTMSessionFetcherErrorDownloadFailed)];
    return;
  }

  if (_bodyFileURL) {
    NSError *fileCheckError;
    if (![_bodyFileURL checkResourceIsReachableAndReturnError:&fileCheckError]) {
      // This assert fires when the file being uploaded no longer exists once
      // the fetcher is ready to start the upload.
      GTMSESSION_ASSERT_DEBUG_OR_LOG(0, @"Body file is unreachable: %@\n  %@",
                                     [_bodyFileURL path], fileCheckError);
      [self failToBeginFetchWithError:fileCheckError];
      return;
    }
  }

  NSString *requestScheme = [requestURL scheme];
  BOOL isDataRequest = [requestScheme isEqual:@"data"];
  if (isDataRequest) {
    // NSURLSession does not support data URLs in background sessions.
    _sessionIdentifier = nil;
    _useBackgroundSession = NO;
  }

#if GTM_ALLOW_INSECURE_REQUESTS
  BOOL shouldCheckSecurity = NO;
#else
  BOOL shouldCheckSecurity = (requestURL != nil
                              && !isDataRequest
                              && [[self class] appAllowsInsecureRequests]);
#endif

  if (shouldCheckSecurity) {
    // Allow https only for requests, unless overridden by the client.
    //
    // Non-https requests may too easily be snooped, so we disallow them by default.
    //
    // file: and data: schemes are usually safe if they are hardcoded in the client or provided
    // by a trusted source, but since it's fairly rare to need them, it's safest to make clients
    // explicitly whitelist them.
    BOOL isSecure =
        requestScheme != nil && [requestScheme caseInsensitiveCompare:@"https"] == NSOrderedSame;
    if (!isSecure) {
      BOOL allowRequest = NO;
      NSString *host = [requestURL host];

      // Check schemes first.  A file scheme request may be allowed here, or as a localhost request.
      for (NSString *allowedScheme in _allowedInsecureSchemes) {
        if (requestScheme != nil &&
            [requestScheme caseInsensitiveCompare:allowedScheme] == NSOrderedSame) {
          allowRequest = YES;
          break;
        }
      }
      if (!allowRequest) {
        // Check for localhost requests.  Security checks only occur for non-https requests, so
        // this check won't happen for an https request to localhost.
        BOOL isLocalhostRequest = (host.length == 0 && [requestURL isFileURL]) || IsLocalhost(host);
        if (isLocalhostRequest) {
          if (_allowLocalhostRequest) {
            allowRequest = YES;
          } else {
            GTMSESSION_ASSERT_DEBUG(NO, @"Fetch request for localhost but fetcher"
                                        @" allowLocalhostRequest is not set: %@", requestURL);
          }
        } else {
          GTMSESSION_ASSERT_DEBUG(NO, @"Insecure fetch request has a scheme (%@)"
                                      @" not found in fetcher allowedInsecureSchemes (%@): %@",
                                  requestScheme, _allowedInsecureSchemes ?: @" @[] ", requestURL);
        }
      }

      if (!allowRequest) {
#if !DEBUG
        NSLog(@"Fetch disallowed for %@", requestURL);
#endif
        [self failToBeginFetchWithError:beginFailureError(GTMSessionFetcherErrorInsecureRequest)];
        return;
      }
    }  // !isSecure
  }  // (requestURL != nil) && !isDataRequest

  if (_cookieStorage == nil) {
    _cookieStorage = [[self class] staticCookieStorage];
  }

  BOOL isRecreatingSession = (_sessionIdentifier != nil) && (_request == nil);

  _canShareSession = !isRecreatingSession && !_useBackgroundSession;

  if (!_session && _canShareSession) {
    _session = [_service sessionForFetcherCreation];
    // If _session is nil, then the service's session creation semaphore will block
    // until this fetcher invokes fetcherDidCreateSession: below, so this *must* invoke
    // that method, even if the session fails to be created.
  }

  if (!_session) {
    // Create a session.
    if (!_configuration) {
      if (_sessionIdentifier || _useBackgroundSession) {
        if (!_sessionIdentifier) {
          [self createSessionIdentifierWithMetadata:nil];
        }
        NSMapTable *sessionIdentifierToFetcherMap = [[self class] sessionIdentifierToFetcherMap];
        [sessionIdentifierToFetcherMap setObject:self forKey:_sessionIdentifier];

#if (!TARGET_OS_IPHONE && defined(MAC_OS_X_VERSION_10_10) && MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_10) \
    || (TARGET_OS_IPHONE && defined(__IPHONE_8_0) && __IPHONE_OS_VERSION_MIN_REQUIRED >= __IPHONE_8_0)
        // iOS 8/10.10 builds require the new backgroundSessionConfiguration method name.
        _configuration =
            [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:_sessionIdentifier];
#elif (!TARGET_OS_IPHONE && defined(MAC_OS_X_VERSION_10_10) && MAC_OS_X_VERSION_MIN_REQUIRED < MAC_OS_X_VERSION_10_10) \
    || (TARGET_OS_IPHONE && defined(__IPHONE_8_0) && __IPHONE_OS_VERSION_MIN_REQUIRED < __IPHONE_8_0)
        // Do a runtime check to avoid a deprecation warning about using
        // +backgroundSessionConfiguration: on iOS 8.
        if ([NSURLSessionConfiguration respondsToSelector:@selector(backgroundSessionConfigurationWithIdentifier:)]) {
          // Running on iOS 8+/OS X 10.10+.
          _configuration =
              [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:_sessionIdentifier];
        } else {
          // Running on iOS 7/OS X 10.9.
          _configuration =
              [NSURLSessionConfiguration backgroundSessionConfiguration:_sessionIdentifier];
        }
#else
        // Building with an SDK earlier than iOS 8/OS X 10.10.
        _configuration =
            [NSURLSessionConfiguration backgroundSessionConfiguration:_sessionIdentifier];
#endif
        _useBackgroundSession = YES;
        _canShareSession = NO;
      } else {
        _configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
      }
#if !GTM_ALLOW_INSECURE_REQUESTS
      _configuration.TLSMinimumSupportedProtocol = kTLSProtocol12;
#endif
    }
    _configuration.HTTPCookieStorage = _cookieStorage;

    if (_configurationBlock) {
      _configurationBlock(self, _configuration);
    }

    id<NSURLSessionDelegate> delegate = [_service sessionDelegate];
    if (!delegate || !_canShareSession) {
      delegate = self;
    }
    _session = [NSURLSession sessionWithConfiguration:_configuration
                                             delegate:delegate
                                        delegateQueue:_delegateQueue];
    GTMSESSION_ASSERT_DEBUG(_session, @"Couldn't create session");

    // Tell the service about the session created by this fetcher.  This also signals the
    // service's semaphore to allow other fetchers to request this session.
    [_service fetcherDidCreateSession:self];

    // If this assertion fires, the client probably tried to use a session identifier that was
    // already used. The solution is to make the client use a unique identifier (or better yet let
    // the session fetcher assign the identifier).
    GTMSESSION_ASSERT_DEBUG(_session.delegate == delegate, @"Couldn't assign delegate.");

    if (_session) {
      BOOL isUsingSharedDelegate = (delegate != self);
      if (!isUsingSharedDelegate) {
        _shouldInvalidateSession = YES;
      }
    }
  }

  if (isRecreatingSession) {
    _shouldInvalidateSession = YES;

    // Let's make sure there are tasks still running or if not that we get a callback from a
    // completed one; otherwise, we assume the tasks failed.
    // This is the observed behavior perhaps 25% of the time within the Simulator running 7.0.3 on
    // exiting the app after starting an upload and relaunching the app if we manage to relaunch
    // after the task has completed, but before the system relaunches us in the background.
    [_session getTasksWithCompletionHandler:^(NSArray *dataTasks, NSArray *uploadTasks,
                                              NSArray *downloadTasks) {
      if ([dataTasks count] == 0 && [uploadTasks count] == 0 && [downloadTasks count] == 0) {
        double const kDelayInSeconds = 1.0;  // We should get progress indication or completion soon
        dispatch_time_t checkForFeedbackDelay =
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kDelayInSeconds * NSEC_PER_SEC));
        dispatch_after(checkForFeedbackDelay, dispatch_get_main_queue(), ^{
          if (!_sessionTask && !_request) {
            // If our task and/or request haven't been restored, then we assume task feedback lost.
            [self removePersistedBackgroundSessionFromDefaults];
            NSError *sessionError =
                [NSError errorWithDomain:kGTMSessionFetcherErrorDomain
                                    code:GTMSessionFetcherErrorBackgroundFetchFailed
                                userInfo:nil];
            [self failToBeginFetchWithError:sessionError];
          }
        });
      }
    }];
    return;
  }

  self.downloadedData = nil;
  _downloadedLength = 0;

  if (_servicePriority == NSIntegerMin) {
    mayDelay = NO;
  }
  if (mayDelay && _service) {
    BOOL shouldFetchNow = [_service fetcherShouldBeginFetching:self];
    if (!shouldFetchNow) {
      // The fetch is deferred, but will happen later.
      //
      // If this session is held by the fetcher service, clear the session now so that we don't
      // assume it's still valid after the fetcher is restarted.
      if (_canShareSession) {
        _session = nil;
      }
      return;
    }
  }

  NSString *effectiveHTTPMethod = [_request valueForHTTPHeaderField:@"X-HTTP-Method-Override"];
  if (effectiveHTTPMethod == nil) {
    effectiveHTTPMethod = [_request HTTPMethod];
  }
  BOOL isEffectiveHTTPGet = (effectiveHTTPMethod == nil
                             || [effectiveHTTPMethod isEqual:@"GET"]);

  BOOL needsUploadTask = (_useUploadTask || _bodyFileURL || _bodyStreamProvider);
  if (_bodyData || _bodyStreamProvider || _request.HTTPBodyStream) {
    if (isEffectiveHTTPGet) {
      [_request setHTTPMethod:@"POST"];
      isEffectiveHTTPGet = NO;
    }

    if (_bodyData) {
      if (!needsUploadTask) {
        [_request setHTTPBody:_bodyData];
      }
#if !STRIP_GTM_FETCH_LOGGING
    } else if (_request.HTTPBodyStream) {
      if ([self respondsToSelector:@selector(loggedInputStreamForInputStream:)]) {
        _request.HTTPBodyStream = [self performSelector:@selector(loggedInputStreamForInputStream:)
                                             withObject:_request.HTTPBodyStream];
      }
#endif
    }
  }

  // We authorize after setting up the http method and body in the request
  // because OAuth 1 may need to sign the request body
  if (mayAuthorize && _authorizer && !isDataRequest) {
    BOOL isAuthorized = [_authorizer isAuthorizedRequest:_request];
    if (!isAuthorized) {
      // Authorization needed.
      //
      // If this session is held by the fetcher service, clear the session now so that we don't
      // assume it's still valid after authorization completes.
      if (_canShareSession) {
        _session = nil;
      }

      // Authorizing the request will recursively call this beginFetch:mayDelay:
      // or failToBeginFetchWithError:.
      [self authorizeRequest];
      return;
    }
  }

  // set the default upload or download retry interval, if necessary
  if (_isRetryEnabled && _maxRetryInterval <= 0) {
    if (isEffectiveHTTPGet || [effectiveHTTPMethod isEqual:@"HEAD"]) {
      [self setMaxRetryInterval:kDefaultMaxDownloadRetryInterval];
    } else {
      [self setMaxRetryInterval:kDefaultMaxUploadRetryInterval];
    }
  }

  // finally, start the connection
  BOOL needsDataAccumulator = NO;
  if (_downloadResumeData) {
    _sessionTask = [_session downloadTaskWithResumeData:_downloadResumeData];
    GTMSESSION_ASSERT_DEBUG_OR_LOG(_sessionTask,
        @"Failed downloadTaskWithResumeData for %@, resume data %tu bytes",
        _session, [_downloadResumeData length]);
  } else if (_destinationFileURL && !isDataRequest) {
    _sessionTask = [_session downloadTaskWithRequest:_request];
    GTMSESSION_ASSERT_DEBUG_OR_LOG(_sessionTask, @"Failed downloadTaskWithRequest for %@, %@",
                                   _session, _request);
  } else if (needsUploadTask) {
    if (_bodyFileURL) {
      _sessionTask = [_session uploadTaskWithRequest:_request fromFile:_bodyFileURL];
      GTMSESSION_ASSERT_DEBUG_OR_LOG(_sessionTask,
                                     @"Failed uploadTaskWithRequest for %@, %@, file %@",
                                     _session, _request, [_bodyFileURL path]);
    } else if (_bodyStreamProvider) {
      _sessionTask = [_session uploadTaskWithStreamedRequest:_request];
      GTMSESSION_ASSERT_DEBUG_OR_LOG(_sessionTask,
                                     @"Failed uploadTaskWithStreamedRequest for %@, %@",
                                     _session, _request);
    } else {
      GTMSESSION_ASSERT_DEBUG_OR_LOG(_bodyData != nil,
                                     @"Upload task needs body data, %@", _request);
      _sessionTask = [_session uploadTaskWithRequest:_request fromData:_bodyData];
      GTMSESSION_ASSERT_DEBUG_OR_LOG(_sessionTask,
          @"Failed uploadTaskWithRequest for %@, %@, body data %tu bytes",
          _session, _request, [_bodyData length]);
    }
    needsDataAccumulator = YES;
  } else {
    _sessionTask = [_session dataTaskWithRequest:_request];
    needsDataAccumulator = YES;
    GTMSESSION_ASSERT_DEBUG_OR_LOG(_sessionTask, @"Failed dataTaskWithRequest for %@, %@",
                                   _session, _request);
  }

  if (!_sessionTask) {
    // We shouldn't get here; if we're here, an earlier assertion should have fired to explain
    // which session task creation failed.
    [self failToBeginFetchWithError:beginFailureError(GTMSessionFetcherErrorTaskCreationFailed)];
    return;
  }

  if (needsDataAccumulator && _accumulateDataBlock == nil) {
    self.downloadedData = [NSMutableData data];
  }
  if (_taskDescription) {
    _sessionTask.taskDescription = _taskDescription;
  }
  if (_taskPriority >= 0) {
#if (!TARGET_OS_IPHONE && defined(MAC_OS_X_VERSION_10_10) && MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_10) \
    || (TARGET_OS_IPHONE && defined(__IPHONE_8_0) && __IPHONE_OS_VERSION_MIN_REQUIRED >= __IPHONE_8_0)
    BOOL hasTaskPriority = YES;
#else
    BOOL hasTaskPriority = [_sessionTask respondsToSelector:@selector(setPriority:)];
#endif
    if (hasTaskPriority) {
      _sessionTask.priority = _taskPriority;
    }
  }

#if GTM_DISABLE_FETCHER_TEST_BLOCK
  GTMSESSION_ASSERT_DEBUG(_testBlock == nil && gGlobalTestBlock == nil, @"test blocks disabled");
  _testBlock = nil;
#else
  if (!_testBlock) {
    if (gGlobalTestBlock) {
      // Note that the test block may pass nil for all of its response parameters,
      // indicating that the fetch should actually proceed. This is useful when the
      // global test block has been set, and the app is only testing a specific
      // fetcher.  The block simulation code will then resume the task.
      _testBlock = gGlobalTestBlock;
    }
  }
  _isUsingTestBlock = (_testBlock != nil);
#endif  // GTM_DISABLE_FETCHER_TEST_BLOCK

#if GTM_BACKGROUND_TASK_FETCHING
  // Background tasks seem to interfere with out-of-process uploads and downloads.
  if (!_useBackgroundSession) {
    // Tell UIApplication that we want to continue even when the app is in the
    // background.
    UIApplication *app = [UIApplication sharedApplication];
#if DEBUG
    NSString *bgTaskName = [NSString stringWithFormat:@"%@-%@",
                            NSStringFromClass([self class]), _request.URL.host];
#else
    NSString *bgTaskName = @"GTMSessionFetcher";
#endif
    _backgroundTaskIdentifer = [app beginBackgroundTaskWithName:bgTaskName
                                              expirationHandler:^{
      // Background task expiration callback - this block is always invoked by
      // UIApplication on the main thread.
      if (_backgroundTaskIdentifer != UIBackgroundTaskInvalid) {
        [[UIApplication sharedApplication] endBackgroundTask:_backgroundTaskIdentifer];

        _backgroundTaskIdentifer = UIBackgroundTaskInvalid;
      }
    }];
  }
#endif

  if (!_initialRequestDate) {
    _initialRequestDate = [[NSDate alloc] init];
  }

  // We don't expect to reach here even on retry or auth until a stop notification has been sent
  // for the previous task, but we should ensure that we don't unbalance that.
  GTMSESSION_ASSERT_DEBUG(!_isStopNotificationNeeded, @"Start notification without a prior stop");
  [self sendStopNotificationIfNeeded];

  [self addPersistedBackgroundSessionToDefaults];

  _isStopNotificationNeeded = YES;
  NSNotificationCenter *defaultNC = [NSNotificationCenter defaultCenter];
  [defaultNC postNotificationName:kGTMSessionFetcherStartedNotification
                           object:self];

  // The service needs to know our task if it is serving as delegate.
  [_service fetcherDidBeginFetching:self];

  if (_testBlock) {
#if !GTM_DISABLE_FETCHER_TEST_BLOCK
    [self simulateFetchForTestBlock];
#endif
  } else {
    // We resume the session task after posting the notification since the
    // delegate callbacks may happen immediately if the fetch is started off
    // the main thread or the session delegate queue is on a background thread,
    // and we don't want to post a start notification after a premature finish
    // of the session task.
    [_sessionTask resume];
  }
}

NSData *GTMDataFromInputStream(NSInputStream *inputStream, NSError **outError) {
  NSMutableData *data = [NSMutableData data];

  [inputStream open];
  NSInteger numberOfBytesRead = 0;
  while ([inputStream hasBytesAvailable]) {
    uint8_t buffer[512];
    numberOfBytesRead = [inputStream read:buffer maxLength:sizeof(buffer)];
    if (numberOfBytesRead > 0) {
      [data appendBytes:buffer length:(NSUInteger)numberOfBytesRead];
    } else {
      break;
    }
  }
  [inputStream close];
  NSError *streamError = inputStream.streamError;

  if (streamError) {
    data = nil;
  }
  if (outError) {
    *outError = streamError;
  }
  return data;
}

#if !GTM_DISABLE_FETCHER_TEST_BLOCK

- (void)simulateFetchForTestBlock {
  // This is invoked on the same thread as the beginFetch method was.
  //
  // Callbacks will all occur on the callback queue.
  _testBlock(self, ^(NSURLResponse *response, NSData *responseData, NSError *error) {
      // Callback from test block.
      if (response == nil && responseData == nil && error == nil) {
        // Assume the fetcher should execute rather than be tested.
        _testBlock = nil;
        _isUsingTestBlock = NO;
        [_sessionTask resume];
        return;
      }

      if (_bodyStreamProvider) {
        _bodyStreamProvider(^(NSInputStream *bodyStream){
          // Read from the input stream into an NSData buffer.  We'll drain the stream
          // explicitly on a background queue.
          [self invokeOnCallbackQueue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0)
                     afterUserStopped:NO
                                block:^{
            NSError *streamError;
            NSData *streamedData = GTMDataFromInputStream(bodyStream, &streamError);

            dispatch_async(dispatch_get_main_queue(), ^{
              // Continue callbacks on the main thread, since serial behavior
              // is more reliable for tests.
              [self simulateDataCallbacksForTestBlockWithBodyData:streamedData
                                                         response:response
                                                     responseData:responseData
                                                            error:(error ?: streamError)];
            });
          }];
        });
      } else {
        // No input stream; use the supplied data or file URL.
        if (_bodyFileURL) {
          NSError *readError;
          _bodyData = [NSData dataWithContentsOfURL:_bodyFileURL
                                            options:NSDataReadingMappedIfSafe
                                              error:&readError];
          error = readError;
        }

        // No body URL or stream provider.
        [self simulateDataCallbacksForTestBlockWithBodyData:_bodyData
                                                   response:response
                                               responseData:responseData
                                                      error:error];
      }
    });
}

- (void)simulateByteTransferReportWithDataLength:(int64_t)totalDataLength
                                           block:(GTMSessionFetcherSendProgressBlock)block {
  // This utility method simulates transfer progress with up to three callbacks.
  // It is used to call back to any of the progress blocks.
  int64_t sendReportSize = totalDataLength / 3 + 1;
  int64_t totalSent = 0;
  while (totalSent < totalDataLength) {
    int64_t bytesRemaining = totalDataLength - totalSent;
    sendReportSize = MIN(sendReportSize, bytesRemaining);
    totalSent += sendReportSize;
    [self invokeOnCallbackQueueUnlessStopped:^{
        block(sendReportSize, totalSent, totalDataLength);
    }];
  }
}

- (void)simulateDataCallbacksForTestBlockWithBodyData:(NSData *)bodyData
                                             response:(NSURLResponse *)response
                                         responseData:(NSData *)responseData
                                                error:(NSError *)error {
  // This method does the test simulation of callbacks once the upload
  // and download data are known.

  // Simulate receipt of redirection.
  if (_willRedirectBlock) {
    [self invokeOnCallbackQueueAfterUserStopped:YES
                                          block:^{
        _willRedirectBlock((NSHTTPURLResponse *)response, _request,
                           ^(NSURLRequest *redirectRequest) {
            // For simulation, we'll assume the app will just continue.
        });
    }];
  }

  // Simulate receipt of an initial response.
  if (_didReceiveResponseBlock) {
    [self invokeOnCallbackQueueAfterUserStopped:YES
                                          block:^{
        _didReceiveResponseBlock(response, ^(NSURLSessionResponseDisposition desiredDisposition) {
            // For simulation, we'll assume the disposition is to continue.
        });
    }];
  }

  // Simulate reporting send progress.
  if (_sendProgressBlock) {
    [self simulateByteTransferReportWithDataLength:(int64_t)[bodyData length]
                                             block:^(int64_t bytesSent,
                                                     int64_t totalBytesSent,
                                                     int64_t totalBytesExpectedToSend) {
        // This is invoked on the callback queue unless stopped.
        _sendProgressBlock(bytesSent, totalBytesSent, totalBytesExpectedToSend);
    }];
  }

  if (_destinationFileURL) {
    // Simulate download to file progress.
    if (_downloadProgressBlock) {
      [self simulateByteTransferReportWithDataLength:(int64_t)[responseData length]
                                               block:^(int64_t bytesDownloaded,
                                                       int64_t totalBytesDownloaded,
                                                       int64_t totalBytesExpectedToDownload) {
        // This is invoked on the callback queue unless stopped.
        _downloadProgressBlock(bytesDownloaded, totalBytesDownloaded, totalBytesExpectedToDownload);
      }];
    }

    NSError *writeError;
    [responseData writeToURL:_destinationFileURL
                     options:NSDataWritingAtomic
                       error:&writeError];
    if (writeError) {
      // Tell the test code that writing failed.
      error = writeError;
    }
  } else {
    // Simulate download to NSData progress.
    if (_accumulateDataBlock) {
      if (responseData) {
        [self invokeOnCallbackQueueUnlessStopped:^{
          _accumulateDataBlock(responseData);
        }];
      }
    } else {
      _downloadedData = [responseData mutableCopy];
    }

    if (_receivedProgressBlock) {
      [self simulateByteTransferReportWithDataLength:(int64_t)[responseData length]
                                               block:^(int64_t bytesReceived,
                                                       int64_t totalBytesReceived,
                                                       int64_t totalBytesExpectedToReceive) {
        // This is invoked on the callback queue unless stopped.
         _receivedProgressBlock(bytesReceived, totalBytesReceived);
       }];
    }

    if (_willCacheURLResponseBlock) {
      // Simulate letting the client inspect and alter the cached response.
      NSCachedURLResponse *cachedResponse =
          [[NSCachedURLResponse alloc] initWithResponse:response
                                                   data:responseData];
      [self invokeOnCallbackQueueAfterUserStopped:YES
                                            block:^{
          _willCacheURLResponseBlock(cachedResponse, ^(NSCachedURLResponse *responseToCache){
              // The app may provide an alternative response, or nil to defeat caching.
          });
      }];
    }
  }
  _response = response;
  dispatch_async(dispatch_get_main_queue(), ^{
    // Rather than invoke failToBeginFetchWithError: we want to simulate completion of
    // a connection that started and ended, so we'll call down to finishWithError:
    NSInteger status = error ? [error code] : 200;
    [self shouldRetryNowForStatus:status error:error response:^(BOOL shouldRetry) {
        [self finishWithError:error shouldRetry:shouldRetry];
    }];
  });
}

#endif  // !GTM_DISABLE_FETCHER_TEST_BLOCK

- (void)setSessionTask:(NSURLSessionTask *)sessionTask {
  @synchronized(self) {
    if (_sessionTask == sessionTask) {
      return;
    }
    _sessionTask = sessionTask;
    if (_sessionTask) {
      // Request could be nil on restoring this fetcher from a background session.
      if (!_request) {
        _request = [_sessionTask.originalRequest mutableCopy];
      }
    }
  }
}

- (NSURLSessionTask *)sessionTask {
  @synchronized(self) {
    return _sessionTask;
  }
}

+ (NSUserDefaults *)fetcherUserDefaults {
  static NSUserDefaults *gFetcherUserDefaults = nil;

  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    Class fetcherUserDefaultsClass = NSClassFromString(@"GTMSessionFetcherUserDefaultsFactory");
    if (fetcherUserDefaultsClass) {
      gFetcherUserDefaults = [fetcherUserDefaultsClass fetcherUserDefaults];
    } else {
      gFetcherUserDefaults = [NSUserDefaults standardUserDefaults];
    }
  });
  return gFetcherUserDefaults;
}

- (void)addPersistedBackgroundSessionToDefaults {
  if (!_sessionIdentifier) {
    return;
  }
  NSArray *oldBackgroundSessions = [[self class] activePersistedBackgroundSessions];
  if ([oldBackgroundSessions containsObject:_sessionIdentifier]) {
    return;
  }
  NSMutableArray *newBackgroundSessions =
      [NSMutableArray arrayWithArray:oldBackgroundSessions];
  [newBackgroundSessions addObject:_sessionIdentifier];
  GTM_LOG_BACKGROUND_SESSION(@"Add to background sessions: %@", newBackgroundSessions);

  NSUserDefaults *userDefaults = [[self class] fetcherUserDefaults];
  [userDefaults setObject:newBackgroundSessions
                   forKey:kGTMSessionFetcherPersistedDestinationKey];
  [userDefaults synchronize];
}

- (void)removePersistedBackgroundSessionFromDefaults {
  NSString *sessionIdentifier;
  @synchronized(self) {
    sessionIdentifier = _sessionIdentifier;
    if (!sessionIdentifier) return;
  }

  NSArray *oldBackgroundSessions = [[self class] activePersistedBackgroundSessions];
  if (!oldBackgroundSessions) {
    return;
  }
  NSMutableArray *newBackgroundSessions =
      [NSMutableArray arrayWithArray:oldBackgroundSessions];
  NSUInteger sessionIndex = [newBackgroundSessions indexOfObject:sessionIdentifier];
  if (sessionIndex == NSNotFound) {
    return;
  }
  [newBackgroundSessions removeObjectAtIndex:sessionIndex];
  GTM_LOG_BACKGROUND_SESSION(@"Remove from background sessions: %@", newBackgroundSessions);

  NSUserDefaults *userDefaults = [[self class] fetcherUserDefaults];
  if ([newBackgroundSessions count] == 0) {
    [userDefaults removeObjectForKey:kGTMSessionFetcherPersistedDestinationKey];
  } else {
    [userDefaults setObject:newBackgroundSessions
                     forKey:kGTMSessionFetcherPersistedDestinationKey];
  }
  [userDefaults synchronize];
}

+ (NSArray *)activePersistedBackgroundSessions {
  NSUserDefaults *userDefaults = [[self class] fetcherUserDefaults];
  NSArray *oldBackgroundSessions =
      [userDefaults arrayForKey:kGTMSessionFetcherPersistedDestinationKey];
  if ([oldBackgroundSessions count] == 0) {
    return nil;
  }
  NSMutableArray *activeBackgroundSessions = nil;
  NSMapTable *sessionIdentifierToFetcherMap = [self sessionIdentifierToFetcherMap];
  for (NSString *sessionIdentifier in oldBackgroundSessions) {
    GTMSessionFetcher *fetcher = [sessionIdentifierToFetcherMap objectForKey:sessionIdentifier];
    if (fetcher) {
      if (!activeBackgroundSessions) {
        activeBackgroundSessions = [[NSMutableArray alloc] init];
      }
      [activeBackgroundSessions addObject:sessionIdentifier];
    }
  }
  return activeBackgroundSessions;
}

+ (NSArray *)fetchersForBackgroundSessions {
  NSUserDefaults *userDefaults = [[self class] fetcherUserDefaults];
  NSArray *backgroundSessions =
      [userDefaults arrayForKey:kGTMSessionFetcherPersistedDestinationKey];
  NSMapTable *sessionIdentifierToFetcherMap = [self sessionIdentifierToFetcherMap];
  NSMutableArray *fetchers = [NSMutableArray array];
  for (NSString *sessionIdentifier in backgroundSessions) {
    GTMSessionFetcher *fetcher = [sessionIdentifierToFetcherMap objectForKey:sessionIdentifier];
    if (!fetcher) {
      fetcher = [self fetcherWithSessionIdentifier:sessionIdentifier];
      GTMSESSION_ASSERT_DEBUG(fetcher != nil,
                              @"Unexpected invalid session identifier: %@", sessionIdentifier);
      [fetcher beginFetchWithCompletionHandler:nil];
    }
    GTM_LOG_BACKGROUND_SESSION(@"%@ restoring session %@ by creating fetcher %@ %p",
                               [self class], sessionIdentifier, fetcher, fetcher);
    if (fetcher != nil) {
      [fetchers addObject:fetcher];
    }
  }
  return fetchers;
}

#if TARGET_OS_IPHONE
+ (void)application:(UIApplication *)application
    handleEventsForBackgroundURLSession:(NSString *)identifier
                      completionHandler:(GTMSessionFetcherSystemCompletionHandler)completionHandler {
  GTMSessionFetcher *fetcher = [self fetcherWithSessionIdentifier:identifier];
  if (fetcher != nil) {
    fetcher.systemCompletionHandler = completionHandler;
  } else {
    GTM_LOG_BACKGROUND_SESSION(@"%@ did not create background session identifier: %@",
                               [self class], identifier);
  }
}
#endif

- (NSString *)sessionIdentifier {
  @synchronized(self) {
    return _sessionIdentifier;
  }
}

- (void)setSessionIdentifier:(NSString *)sessionIdentifier {
  GTMSESSION_ASSERT_DEBUG(sessionIdentifier != nil, @"Invalid session identifier");
  @synchronized(self) {
    GTMSESSION_ASSERT_DEBUG(!_session, @"Unable to set session identifier after session created");
    _sessionIdentifier = [sessionIdentifier copy];
    _useBackgroundSession = YES;
    _canShareSession = NO;
    [self restoreDefaultStateForSessionIdentifierMetadata];
  }
}

- (NSDictionary *)sessionUserInfo {
  @synchronized(self) {
    if (_sessionUserInfo == nil) {
      // We'll return the metadata dictionary with internal keys removed. This avoids the user
      // re-using the userInfo dictionary later and accidentally including the internal keys.
      NSMutableDictionary *metadata = [[self sessionIdentifierMetadata] mutableCopy];
      NSSet *keysToRemove = [metadata keysOfEntriesPassingTest:^BOOL(id key, id obj, BOOL *stop) {
          return [key hasPrefix:@"_"];
      }];
      [metadata removeObjectsForKeys:[keysToRemove allObjects]];
      if ([metadata count] > 0) {
        _sessionUserInfo = metadata;
      }
    }
    return _sessionUserInfo;
  }
}

- (void)setSessionUserInfo:(NSDictionary *)dictionary {
  @synchronized(self) {
    GTMSESSION_ASSERT_DEBUG(_sessionIdentifier == nil, @"Too late to assign userInfo");
    _sessionUserInfo = dictionary;
  }
}

- (NSDictionary *)sessionIdentifierDefaultMetadata {
  NSMutableDictionary *defaultUserInfo = [[NSMutableDictionary alloc] init];
  if (_destinationFileURL) {
    defaultUserInfo[kGTMSessionIdentifierDestinationFileURLMetadataKey] =
        [_destinationFileURL absoluteString];
  }
  if (_bodyFileURL) {
    defaultUserInfo[kGTMSessionIdentifierBodyFileURLMetadataKey] = [_bodyFileURL absoluteString];
  }
  return ([defaultUserInfo count] > 0) ? defaultUserInfo : nil;
}

- (void)restoreDefaultStateForSessionIdentifierMetadata {
  NSDictionary *metadata = [self sessionIdentifierMetadata];
  NSString *destinationFileURLString = metadata[kGTMSessionIdentifierDestinationFileURLMetadataKey];
  if (destinationFileURLString) {
    _destinationFileURL = [NSURL URLWithString:destinationFileURLString];
    GTM_LOG_BACKGROUND_SESSION(@"Restoring destination file URL: %@", _destinationFileURL);
  }
  NSString *bodyFileURLString = metadata[kGTMSessionIdentifierBodyFileURLMetadataKey];
  if (bodyFileURLString) {
    _bodyFileURL = [NSURL URLWithString:bodyFileURLString];
    GTM_LOG_BACKGROUND_SESSION(@"Restoring body file URL: %@", _bodyFileURL);
  }
}

- (NSDictionary *)sessionIdentifierMetadata {
  // Session Identifier format: "com.google.<ClassName>_<UUID>_<Metadata in JSON format>
  if (!_sessionIdentifier) {
    return nil;
  }
  NSScanner *metadataScanner = [NSScanner scannerWithString:_sessionIdentifier];
  [metadataScanner setCharactersToBeSkipped:nil];
  NSString *metadataString;
  NSString *uuid;
  if ([metadataScanner scanUpToString:@"_" intoString:NULL] &&
      [metadataScanner scanString:@"_" intoString:NULL] &&
      [metadataScanner scanUpToString:@"_" intoString:&uuid] &&
      [metadataScanner scanString:@"_" intoString:NULL] &&
      [metadataScanner scanUpToString:@"\n" intoString:&metadataString]) {
    _sessionIdentifierUUID = uuid;
    NSData *metadataData = [metadataString dataUsingEncoding:NSUTF8StringEncoding];
    NSError *error;
    NSDictionary *metadataDict =
        [NSJSONSerialization JSONObjectWithData:metadataData
                                        options:0
                                          error:&error];
    GTM_LOG_BACKGROUND_SESSION(@"User Info from session identifier: %@ %@",
                               metadataDict, error ? error : @"");
    return metadataDict;
  }
  return nil;
}

- (void)createSessionIdentifierWithMetadata:(NSDictionary *)metadataToInclude {
  // Session Identifier format: "com.google.<ClassName>_<UUID>_<Metadata in JSON format>
  GTMSESSION_ASSERT_DEBUG(!_sessionIdentifier, @"Session identifier already created");
  _sessionIdentifierUUID = [[NSUUID UUID] UUIDString];
  _sessionIdentifier =
      [NSString stringWithFormat:@"%@_%@", kGTMSessionIdentifierPrefix, _sessionIdentifierUUID];
  // Start with user-supplied keys so they cannot accidentally override the fetcher's keys.
  NSMutableDictionary *metadataDict =
      [NSMutableDictionary dictionaryWithDictionary:_sessionUserInfo];

  if (metadataToInclude) {
    [metadataDict addEntriesFromDictionary:metadataToInclude];
  }
  NSDictionary *defaultMetadataDict = [self sessionIdentifierDefaultMetadata];
  if (defaultMetadataDict) {
    [metadataDict addEntriesFromDictionary:defaultMetadataDict];
  }
  if ([metadataDict count] > 0) {
    NSData *metadataData = [NSJSONSerialization dataWithJSONObject:metadataDict
                                                           options:0
                                                             error:NULL];
    GTMSESSION_ASSERT_DEBUG(metadataData != nil,
                            @"Session identifier user info failed to convert to JSON");
    if ([metadataData length] > 0) {
      NSString *metadataString = [[NSString alloc] initWithData:metadataData
                                                       encoding:NSUTF8StringEncoding];
      _sessionIdentifier =
          [_sessionIdentifier stringByAppendingFormat:@"_%@", metadataString];
    }
  }
  _didCreateSessionIdentifier = YES;
}

- (void)failToBeginFetchWithError:(NSError *)error {
  if (error == nil) {
    error = [NSError errorWithDomain:kGTMSessionFetcherErrorDomain
                                code:GTMSessionFetcherErrorDownloadFailed
                            userInfo:nil];
  }

  [self invokeFetchCallbacksOnCallbackQueueWithData:nil
                                              error:error];
  [self releaseCallbacks];

  [_service fetcherDidStop:self];

  self.authorizer = nil;
}

+ (GTMSessionCookieStorage *)staticCookieStorage {
  static GTMSessionCookieStorage *gCookieStorage = nil;

  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    gCookieStorage = [[GTMSessionCookieStorage alloc] init];
  });
  return gCookieStorage;
}

#if GTM_BACKGROUND_TASK_FETCHING

- (void)endBackgroundTask {
  // Whenever the connection stops or background execution expires,
  // we need to tell UIApplication we're done.
  //
  // We'll wait on _callbackGroup to ensure that any callbacks in flight have executed,
  // and that we access _backgroundTaskIdentifer on the main thread, as happens when the
  // task has expired.
  dispatch_group_notify(_callbackGroup, dispatch_get_main_queue(), ^{
    if (_backgroundTaskIdentifer != UIBackgroundTaskInvalid) {
      [[UIApplication sharedApplication] endBackgroundTask:_backgroundTaskIdentifer];

      _backgroundTaskIdentifer = UIBackgroundTaskInvalid;
    }
  });
}

#endif // GTM_BACKGROUND_TASK_FETCHING

- (void)authorizeRequest {
  id authorizer = self.authorizer;
  SEL asyncAuthSel = @selector(authorizeRequest:delegate:didFinishSelector:);
  if ([authorizer respondsToSelector:asyncAuthSel]) {
    SEL callbackSel = @selector(authorizer:request:finishedWithError:);
    [authorizer authorizeRequest:_request
                        delegate:self
               didFinishSelector:callbackSel];
  } else {
    GTMSESSION_ASSERT_DEBUG(authorizer == nil, @"invalid authorizer for fetch");

    // No authorizing possible, and authorizing happens only after any delay;
    // just begin fetching
    [self beginFetchMayDelay:NO
                mayAuthorize:NO];
  }
}

- (void)authorizer:(id<GTMFetcherAuthorizationProtocol>)auth
           request:(NSMutableURLRequest *)request
 finishedWithError:(NSError *)error {
  if (error != nil) {
    // We can't fetch without authorization
    [self failToBeginFetchWithError:error];
  } else {
    [self beginFetchMayDelay:NO
                mayAuthorize:NO];
  }
}


// Returns YES if this is in the process of fetching a URL, or waiting to
// retry, or waiting for authorization, or waiting to be issued by the
// service object
- (BOOL)isFetching {
  if (_sessionTask != nil || _retryTimer != nil) return YES;

  BOOL isAuthorizing = [_authorizer isAuthorizingRequest:_request];
  if (isAuthorizing) return YES;

  BOOL isDelayed = [_service isDelayingFetcher:self];
  return isDelayed;
}

- (NSURLResponse *)response {
  @synchronized(self) {
    NSURLResponse *response = _sessionTask.response;
    if (response) return response;
    return _response;
  }
}

- (NSInteger)statusCode {
  NSURLResponse *response = self.response;
  NSInteger statusCode;

  if ([response respondsToSelector:@selector(statusCode)]) {
    statusCode = [(NSHTTPURLResponse *)response statusCode];
  } else {
    //  Default to zero, in hopes of hinting "Unknown" (we can't be
    //  sure that things are OK enough to use 200).
    statusCode = 0;
  }
  return statusCode;
}


- (NSDictionary *)responseHeaders {
  NSURLResponse *response = self.response;
  if ([response respondsToSelector:@selector(allHeaderFields)]) {
    NSDictionary *headers = [(NSHTTPURLResponse *)response allHeaderFields];
    return headers;
  }
  return nil;
}

- (void)releaseCallbacks {
  // After the fetcher starts, this is called in a @synchronized(self) block.
  _callbackQueue = nil;

  _completionHandler = nil;  // Setter overridden in upload. Setter assumed to be used externally.
  self.configurationBlock = nil;
  self.didReceiveResponseBlock = nil;
  self.willRedirectBlock = nil;
  self.sendProgressBlock = nil;
  self.receivedProgressBlock = nil;
  self.downloadProgressBlock = nil;
  self.accumulateDataBlock = nil;
  self.willCacheURLResponseBlock = nil;
  self.retryBlock = nil;
  self.testBlock = nil;
  self.resumeDataBlock = nil;
}

- (void)forgetSessionIdentifierForFetcher {
  // This should be called inside a @synchronized block (except during dealloc.)
  if (_sessionIdentifier) {
    NSMapTable *sessionIdentifierToFetcherMap = [[self class] sessionIdentifierToFetcherMap];
    [sessionIdentifierToFetcherMap removeObjectForKey:_sessionIdentifier];
    _sessionIdentifier = nil;
    _didCreateSessionIdentifier = NO;
  }
}

// External stop method
- (void)stopFetching {
  @synchronized(self) {
    // Prevent enqueued callbacks from executing.
    _userStoppedFetching = YES;
  }
  [self stopFetchReleasingCallbacks:YES];
}

// Cancel the fetch of the URL that's currently in progress.
//
// If shouldReleaseCallbacks is NO then the fetch will be retried so the callbacks
// need to still be retained.
- (void)stopFetchReleasingCallbacks:(BOOL)shouldReleaseCallbacks {
  [self removePersistedBackgroundSessionFromDefaults];

  id<GTMSessionFetcherServiceProtocol> service;

  // If the task or the retry timer is all that's retaining the fetcher,
  // we want to be sure this instance survives stopping at least long enough for
  // the stack to unwind.
  __autoreleasing GTMSessionFetcher *holdSelf = self;

  BOOL hasCanceledTask = NO;
  [holdSelf destroyRetryTimer];

  @synchronized(self) {
    service = _service;

    if (_sessionTask) {
      // In case cancelling the task or session calls this recursively, we want
      // to ensure that we'll only release the task and delegate once,
      // so first set _sessionTask to nil
      //
      // This may be called in a callback from the task, so use autorelease to avoid
      // releasing the task in its own callback.
      __autoreleasing NSURLSessionTask *oldTask = _sessionTask;
      if (!_isUsingTestBlock) {
        _response = _sessionTask.response;
      }
      _sessionTask = nil;

      if ([oldTask state] != NSURLSessionTaskStateCompleted) {
        // For download tasks, when the fetch is stopped, we may provide resume data that can
        // be used to create a new session.
        BOOL mayResume = (_resumeDataBlock
                          && [oldTask respondsToSelector:@selector(cancelByProducingResumeData:)]);
        if (!mayResume) {
          [oldTask cancel];
        } else {
          void (^resumeBlock)(NSData *) = _resumeDataBlock;
          _resumeDataBlock = nil;

          // Save callbackQueue since releaseCallbacks clears it.
          dispatch_queue_t callbackQueue = _callbackQueue;
          dispatch_group_enter(_callbackGroup);
          [(NSURLSessionDownloadTask *)oldTask cancelByProducingResumeData:^(NSData *resumeData) {
              [self invokeOnCallbackQueue:callbackQueue
                         afterUserStopped:YES
                                    block:^{
                  resumeBlock(resumeData);
                  dispatch_group_leave(_callbackGroup);
              }];
          }];
        }
        hasCanceledTask = YES;
      }
    }

    // If the task was canceled, wait until the URLSession:task:didCompleteWithError: to call
    // finishTasksAndInvalidate, since calling it immediately tends to crash, see radar 18471901.
    if (_session && !hasCanceledTask) {
      BOOL shouldInvalidate = _shouldInvalidateSession;
#if TARGET_OS_IPHONE
      // Don't invalidate if we've got a systemCompletionHandler, since
      // URLSessionDidFinishEventsForBackgroundURLSession: won't be called if invalidated.
      shouldInvalidate = shouldInvalidate && !self.systemCompletionHandler;
#endif
      if (shouldInvalidate) {
        __autoreleasing NSURLSession *oldSession = _session;
        _session = nil;
        [oldSession finishTasksAndInvalidate];
      }
    }
  }  // @synchronized(self)

  // send the stopped notification
  [self sendStopNotificationIfNeeded];

  @synchronized(self) {
    [_authorizer stopAuthorizationForRequest:_request];

    if (shouldReleaseCallbacks) {
      [self releaseCallbacks];

      self.authorizer = nil;
    }
  }  // @synchronized(self)

  [service fetcherDidStop:self];

#if GTM_BACKGROUND_TASK_FETCHING
  [self endBackgroundTask];
#endif
}

- (void)sendStopNotificationIfNeeded {
  BOOL sendNow = NO;
  @synchronized(self) {
    if (_isStopNotificationNeeded) {
      _isStopNotificationNeeded = NO;
      sendNow = YES;
    }
  }

  if (sendNow) {
    [[NSNotificationCenter defaultCenter] postNotificationName:kGTMSessionFetcherStoppedNotification
                                                        object:self];
  }
}

- (void)retryFetch {
  [self stopFetchReleasingCallbacks:NO];

  // A retry will need a configuration with a fresh session identifier.
  @synchronized(self) {
    if (_sessionIdentifier && _didCreateSessionIdentifier) {
      [self forgetSessionIdentifierForFetcher];
      _configuration = nil;
    }
  }

  [self beginFetchWithCompletionHandler:_completionHandler];
}

- (BOOL)waitForCompletionWithTimeout:(NSTimeInterval)timeoutInSeconds {
  // Uncovered in upload fetcher testing, because the chunk fetcher is being waited on, and gets
  // released by the upload code. The uploader just holds onto it with an ivar, and that gets
  // nilled in the chunk fetcher callback.
  // Used once in while loop just to avoid unused variable compiler warning.
  __autoreleasing GTMSessionFetcher *holdSelf = self;

  NSDate *giveUpDate = [NSDate dateWithTimeIntervalSinceNow:timeoutInSeconds];

  BOOL shouldSpinRunLoop = ([NSThread isMainThread] &&
                            (!_callbackQueue || _callbackQueue == dispatch_get_main_queue()));
  BOOL expired = NO;

  // Loop until the callbacks have been called and released, and until
  // the connection is no longer pending, until there are no callback dispatches
  // in flight, or until the timeout has expired.

  int64_t delta = (int64_t)(100 * NSEC_PER_MSEC);  // 100 ms
  while ((holdSelf->_sessionTask && [_sessionTask state] != NSURLSessionTaskStateCompleted)
         || _completionHandler != nil
         || (_callbackGroup
             && dispatch_group_wait(_callbackGroup, dispatch_time(DISPATCH_TIME_NOW, delta)))) {
    expired = ([giveUpDate timeIntervalSinceNow] < 0);
    if (expired) break;

    // Run the current run loop 1/1000 of a second to give the networking
    // code a chance to work
    const NSTimeInterval kSpinInterval = 0.001;
    if (shouldSpinRunLoop) {
      NSDate *stopDate = [NSDate dateWithTimeIntervalSinceNow:kSpinInterval];
      [[NSRunLoop currentRunLoop] runUntilDate:stopDate];
    } else {
      [NSThread sleepForTimeInterval:kSpinInterval];
    }
  }
  return !expired;
}

+ (void)setGlobalTestBlock:(GTMSessionFetcherTestBlock)block {
#if GTM_DISABLE_FETCHER_TEST_BLOCK
  GTMSESSION_ASSERT_DEBUG(block == nil, @"test blocks disabled");
#endif
  gGlobalTestBlock = [block copy];
}

#pragma mark NSURLSession Delegate Methods

// NSURLSession documentation indicates that redirectRequest can be passed to the handler
// but empirically redirectRequest lacks the HTTP body, so passing it will break POSTs.
// Instead, we construct a new request, a copy of the original, with overrides from the
// redirect.

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
willPerformHTTPRedirection:(NSHTTPURLResponse *)redirectResponse
        newRequest:(NSURLRequest *)redirectRequest
 completionHandler:(void (^)(NSURLRequest *))handler {
  [self setSessionTask:task];
  GTM_LOG_SESSION_DELEGATE(@"%@ %p URLSession:%@ task:%@ willPerformHTTPRedirection:%@ newRequest:%@",
                           [self class], self, session, task, redirectResponse, redirectRequest);

  @synchronized(self) {
    if (_userStoppedFetching) {
      handler(nil);
      return;
    }
    if (redirectRequest && redirectResponse) {
      // Copy the original request, including the body.
      NSMutableURLRequest *newRequest = [_request mutableCopy];

      // Disallow scheme changes (say, from https to http).
      NSURL *originalRequestURL = [_request URL];
      NSURL *redirectRequestURL = [redirectRequest URL];

      NSString *originalScheme = [originalRequestURL scheme];
      NSString *redirectScheme = [redirectRequestURL scheme];

      if (originalScheme != nil
          && [originalScheme caseInsensitiveCompare:@"http"] == NSOrderedSame
          && redirectScheme != nil
          && [redirectScheme caseInsensitiveCompare:@"https"] == NSOrderedSame) {
        // Allow the change from http to https.
      } else {
        // Disallow any other scheme changes.
        redirectScheme = originalScheme;
      }
      // The new requests's URL overrides the original's URL.
      NSURLComponents *components = [NSURLComponents componentsWithURL:redirectRequestURL
                                               resolvingAgainstBaseURL:NO];
      components.scheme = redirectScheme;
      NSURL *newURL = [components URL];
      [newRequest setURL:newURL];

      // Any headers in the redirect override headers in the original.
      NSDictionary *redirectHeaders = [redirectRequest allHTTPHeaderFields];
      for (NSString *key in redirectHeaders) {
        NSString *value = [redirectHeaders objectForKey:key];
        [newRequest setValue:value forHTTPHeaderField:key];
      }

      redirectRequest = newRequest;

      // Log the response we just received
      _response = redirectResponse;
      [self logNowWithError:nil];

      GTMSessionFetcherWillRedirectBlock willRedirectBlock = _willRedirectBlock;
      if (willRedirectBlock) {
        [self invokeOnCallbackQueueAfterUserStopped:YES
                                              block:^{
            willRedirectBlock(redirectResponse, redirectRequest, ^(NSURLRequest *clientRequest) {
                @synchronized(self) {
                  // Update the request for future logging
                  self.mutableRequest = [clientRequest mutableCopy];
                }
                handler(clientRequest);
            });
        }];
        return;
      }
      // Continues here if the client did not provide a redirect block.

      // Update the request for future logging
      self.mutableRequest = [redirectRequest mutableCopy];
    }
    handler(redirectRequest);
  }  // @synchronized(self)
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))handler {
  [self setSessionTask:dataTask];
  GTM_LOG_SESSION_DELEGATE(@"%@ %p URLSession:%@ dataTask:%@ didReceiveResponse:%@",
                           [self class], self, session, dataTask, response);
  void (^accumulateAndFinish)(NSURLSessionResponseDisposition) =
      ^(NSURLSessionResponseDisposition dispositionValue) {
      // This method is called when the server has determined that it
      // has enough information to create the NSURLResponse
      // it can be called multiple times, for example in the case of a
      // redirect, so each time we reset the data.
      @synchronized(self) {
        BOOL hadPreviousData = _downloadedLength > 0;

        [_downloadedData setLength:0];
        _downloadedLength = 0;

        if (hadPreviousData && (dispositionValue != NSURLSessionResponseCancel)) {
          // Tell the accumulate block to discard prior data.
          GTMSessionFetcherAccumulateDataBlock accumulateBlock = _accumulateDataBlock;
          if (accumulateBlock) {
            [self invokeOnCallbackQueueUnlessStopped:^{
                accumulateBlock(nil);
            }];
          }
        }
      }
      handler(dispositionValue);
  };

  GTMSessionFetcherDidReceiveResponseBlock receivedResponseBlock;
  @synchronized(self) {
    receivedResponseBlock = _didReceiveResponseBlock;
  }

  if (receivedResponseBlock == nil) {
    accumulateAndFinish(NSURLSessionResponseAllow);
  } else {
    // We will ultimately need to call back to NSURLSession's handler with the disposition value
    // for this delegate method even if the user has stopped the fetcher.
    [self invokeOnCallbackQueueAfterUserStopped:YES
                                          block:^{
        receivedResponseBlock(response, ^(NSURLSessionResponseDisposition desiredDisposition) {
            accumulateAndFinish(desiredDisposition);
        });
    }];
  }
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didBecomeDownloadTask:(NSURLSessionDownloadTask *)downloadTask {
  GTM_LOG_SESSION_DELEGATE(@"%@ %p URLSession:%@ dataTask:%@ didBecomeDownloadTask:%@",
                           [self class], self, session, dataTask, downloadTask);
  [self setSessionTask:downloadTask];
}


- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition,
                             NSURLCredential *credential))handler {
  [self setSessionTask:task];
  GTM_LOG_SESSION_DELEGATE(@"%@ %p URLSession:%@ task:%@ didReceiveChallenge:%@",
                           [self class], self, session, task, challenge);

  @synchronized(self) {
    NSInteger previousFailureCount = [challenge previousFailureCount];
    if (previousFailureCount <= 2) {
      NSURLProtectionSpace *protectionSpace = [challenge protectionSpace];
      NSString *authenticationMethod = [protectionSpace authenticationMethod];
      if ([authenticationMethod isEqual:NSURLAuthenticationMethodServerTrust]) {
        // SSL.
        //
        // Background sessions seem to require an explicit check of the server trust object
        // rather than default handling.
        SecTrustRef serverTrust = challenge.protectionSpace.serverTrust;
        if (serverTrust == NULL) {
          // No server trust information is available.
          handler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
        } else {
          // Server trust information is available.
          void (^callback)(SecTrustRef, BOOL) = ^(SecTrustRef trustRef, BOOL allow){
            if (allow) {
              NSURLCredential *trustCredential = [NSURLCredential credentialForTrust:trustRef];
              handler(NSURLSessionAuthChallengeUseCredential, trustCredential);
            } else {
              GTMSESSION_LOG_DEBUG(@"Cancelling authentication challenge for %@", [_request URL]);
              handler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
            }
          };
          if (_allowInvalidServerCertificates) {
            callback(serverTrust, YES);
          } else {
            // Retain the trust object to avoid a SecTrustEvaluate() crash on iOS 7.
            CFRetain(serverTrust);

            // Evaluate the certificate chain.
            //
            // The delegate queue may be the main thread. Trust evaluation could cause some
            // blocking network activity, so we must evaluate async, as documented at
            // https://developer.apple.com/library/ios/technotes/tn2232/
            //
            // We must also avoid multiple uses of the trust object, per docs:
            // "It is not safe to call this function concurrently with any other function that uses
            // the same trust management object, or to re-enter this function for the same trust
            // management object."
            //
            // SecTrustEvaluateAsync both does sync execution of Evaluate and calls back on the
            // queue passed to it, according to at sources in
            // http://www.opensource.apple.com/source/libsecurity_keychain/libsecurity_keychain-55050.9/lib/SecTrust.cpp
            // It would require a global serial queue to ensure the evaluate happens only on a
            // single thread at a time, so we'll stick with using SecTrustEvaluate on a background
            // thread.
            dispatch_queue_t evaluateBackgroundQueue =
                dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
            dispatch_async(evaluateBackgroundQueue, ^{
              // It looks like the implementation of SecTrustEvaluate() on Mac grabs a global lock,
              // so it may be redundant for us to also lock, but it's easy to synchronize here
              // anyway.
              SecTrustResultType trustEval = kSecTrustResultInvalid;
              BOOL shouldAllow;
              OSStatus trustError;
              @synchronized([GTMSessionFetcher class]) {
                trustError = SecTrustEvaluate(serverTrust, &trustEval);
              }
              if (trustError != errSecSuccess) {
                GTMSESSION_LOG_DEBUG(@"Error %d evaluating trust for %@",
                                     (int)trustError, _request);
                shouldAllow = NO;
              } else {
                // Having a trust level "unspecified" by the user is the usual result, described at
                //   https://developer.apple.com/library/mac/qa/qa1360
                if (trustEval == kSecTrustResultUnspecified
                    || trustEval == kSecTrustResultProceed) {
                  shouldAllow = YES;
                } else {
                  shouldAllow = NO;
                  GTMSESSION_LOG_DEBUG(@"Challenge SecTrustResultType %u for %@, properties: %@",
                                       trustEval, _request.URL.host,
                                       CFBridgingRelease(SecTrustCopyProperties(serverTrust)));
                }
              }
              callback(serverTrust, shouldAllow);

              CFRelease(serverTrust);
            });
          }
        }
        return;
      }

      NSURLCredential *credential = _credential;

      if ([[challenge protectionSpace] isProxy] && _proxyCredential != nil) {
        credential = _proxyCredential;
      }

      if (credential) {
        handler(NSURLSessionAuthChallengeUseCredential, credential);
      } else {
        // The credential is still nil; tell the OS to use the default handling. This is needed
        // for things that can come out of the keychain (proxies, client certificates, etc.).
        //
        // Note: Looking up a credential with NSURLCredentialStorage's
        // defaultCredentialForProtectionSpace: is *not* the same invoking the handler with
        // NSURLSessionAuthChallengePerformDefaultHandling. In the case of
        // NSURLAuthenticationMethodClientCertificate, you can get nil back from
        // NSURLCredentialStorage, while using this code path instead works.
        handler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
      }

    } else {
      // We've failed auth 3 times.  The completion handler will be called with code
      // NSURLErrorCancelled.
      handler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
    }
  }  // @synchronized(self)
}

- (void)invokeOnCallbackQueueUnlessStopped:(void (^)(void))block {
  [self invokeOnCallbackQueueAfterUserStopped:NO
                                        block:block];
}

- (void)invokeOnCallbackQueueAfterUserStopped:(BOOL)afterStopped
                                        block:(void (^)(void))block {
  [self invokeOnCallbackQueue:self.callbackQueue
             afterUserStopped:afterStopped
                        block:block];
}

- (void)invokeOnCallbackQueue:(dispatch_queue_t)callbackQueue
             afterUserStopped:(BOOL)afterStopped
                        block:(void (^)(void))block {
  if (callbackQueue) {
    dispatch_group_async(_callbackGroup, callbackQueue, ^{
        if (!afterStopped) {
          @synchronized(self) {
            // Avoid a race between stopFetching and the callback.
            if (_userStoppedFetching) return;
          }
        }
        block();
    });
  }
}

- (void)invokeFetchCallbacksOnCallbackQueueWithData:(NSData *)data
                                              error:(NSError *)error {
  // Callbacks will be released in the method stopFetchReleasingCallbacks:
  void (^handler)(NSData *, NSError *);
  @synchronized(self) {
    handler = _completionHandler;
  }
  if (handler) {
    [self invokeOnCallbackQueueUnlessStopped:^{
        handler(data, error);
    }];
  }
}


- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)uploadTask
 needNewBodyStream:(void (^)(NSInputStream *bodyStream))completionHandler {
  [self setSessionTask:uploadTask];
  GTM_LOG_SESSION_DELEGATE(@"%@ %p URLSession:%@ task:%@ needNewBodyStream:",
                           [self class], self, session, uploadTask);
  @synchronized(self) {
    GTMSessionFetcherBodyStreamProvider provider = _bodyStreamProvider;
#if !STRIP_GTM_FETCH_LOGGING
    if ([self respondsToSelector:@selector(loggedStreamProviderForStreamProvider:)]) {
      provider = [self performSelector:@selector(loggedStreamProviderForStreamProvider:)
                            withObject:provider];
    }
#endif
    if (provider) {
      [self invokeOnCallbackQueueUnlessStopped:^{
          provider(completionHandler);
      }];
    } else {
      GTMSESSION_ASSERT_DEBUG(NO, @"NSURLSession expects a stream provider");

      completionHandler(nil);
    }
  }
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
   didSendBodyData:(int64_t)bytesSent
    totalBytesSent:(int64_t)totalBytesSent
totalBytesExpectedToSend:(int64_t)totalBytesExpectedToSend {
  [self setSessionTask:task];
  GTM_LOG_SESSION_DELEGATE(@"%@ %p URLSession:%@ task:%@ didSendBodyData:%lld"
                           @" totalBytesSent:%lld totalBytesExpectedToSend:%lld",
                           [self class], self, session, task, bytesSent, totalBytesSent,
                           totalBytesExpectedToSend);
  @synchronized(self) {
    if (!_sendProgressBlock) return;
  }

  // We won't hold on to send progress block; it's ok to not send it if the upload finishes.
  [self invokeOnCallbackQueueUnlessStopped:^{
      GTMSessionFetcherSendProgressBlock progressBlock;
      @synchronized(self) {
        progressBlock = _sendProgressBlock;
      }
      if (progressBlock) {
        progressBlock(bytesSent, totalBytesSent, totalBytesExpectedToSend);
      }
  }];
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
  [self setSessionTask:dataTask];
  NSUInteger bufferLength = [data length];
  GTM_LOG_SESSION_DELEGATE(@"%@ %p URLSession:%@ dataTask:%@ didReceiveData:%p (%llu bytes)",
                           [self class], self, session, dataTask, data,
                           (unsigned long long)bufferLength);
  if (bufferLength == 0) {
    // Observed on completing an out-of-process upload.
    return;
  }
  @synchronized(self) {
    GTMSessionFetcherAccumulateDataBlock accumulateBlock = _accumulateDataBlock;
    if (accumulateBlock) {
      // Let the client accumulate the data.
      _downloadedLength += bufferLength;
      [self invokeOnCallbackQueueUnlessStopped:^{
          accumulateBlock(data);
      }];
    } else if (!_userStoppedFetching) {
      // Append to the mutable data buffer unless the fetch has been cancelled.

      // Resumed upload tasks may not yet have a data buffer.
      if (_downloadedData == nil) {
        // Using NSClassFromString for iOS 6 compatibility.
        GTMSESSION_ASSERT_DEBUG(
            ![dataTask isKindOfClass:NSClassFromString(@"NSURLSessionDownloadTask")],
            @"Resumed download tasks should not receive data bytes");
        _downloadedData = [[NSMutableData alloc] init];
      }

      [_downloadedData appendData:data];
      _downloadedLength = (int64_t)[_downloadedData length];

      // We won't hold on to receivedProgressBlock here; it's ok to not send
      // it if the transfer finishes.
      if (_receivedProgressBlock) {
        [self invokeOnCallbackQueueUnlessStopped:^{
            GTMSessionFetcherReceivedProgressBlock progressBlock;
            @synchronized(self) {
              progressBlock = _receivedProgressBlock;
            }
            if (progressBlock) {
              progressBlock((int64_t)bufferLength, _downloadedLength);
            }
        }];
      }
    }
  }  // @synchronized(self)
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
 willCacheResponse:(NSCachedURLResponse *)proposedResponse
 completionHandler:(void (^)(NSCachedURLResponse *cachedResponse))completionHandler {
  GTM_LOG_SESSION_DELEGATE(@"%@ %p URLSession:%@ dataTask:%@ willCacheResponse:%@ %@",
                           [self class], self, session, dataTask,
                           proposedResponse, proposedResponse.response);
  GTMSessionFetcherWillCacheURLResponseBlock callback;
  @synchronized(self) {
    callback = _willCacheURLResponseBlock;
  }

  if (callback) {
    [self invokeOnCallbackQueueAfterUserStopped:YES
                                          block:^{
        callback(proposedResponse, completionHandler);
    }];
  } else {
    completionHandler(proposedResponse);
  }
}


- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
  GTM_LOG_SESSION_DELEGATE(@"%@ %p URLSession:%@ downloadTask:%@ didWriteData:%lld"
                           @" bytesWritten:%lld totalBytesExpectedToWrite:%lld",
                           [self class], self, session, downloadTask, bytesWritten,
                           totalBytesWritten, totalBytesExpectedToWrite);
  [self setSessionTask:downloadTask];
  if ((totalBytesExpectedToWrite != NSURLSessionTransferSizeUnknown) &&
      (totalBytesExpectedToWrite < totalBytesWritten)) {
    // Have observed cases were bytesWritten == totalBytesExpectedToWrite,
    // but totalBytesWritten > totalBytesExpectedToWrite, so setting to unkown in these cases.
    totalBytesExpectedToWrite = NSURLSessionTransferSizeUnknown;
  }
  // We won't hold on to download progress block during the enqueue;
  // it's ok to not send it if the upload finishes.
  [self invokeOnCallbackQueueUnlessStopped:^{
      GTMSessionFetcherDownloadProgressBlock progressBlock;
      @synchronized(self) {
        progressBlock = _downloadProgressBlock;
      }
      if (progressBlock) {
        progressBlock(bytesWritten, totalBytesWritten, totalBytesExpectedToWrite);
      }
  }];
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
 didResumeAtOffset:(int64_t)fileOffset
expectedTotalBytes:(int64_t)expectedTotalBytes {
  GTM_LOG_SESSION_DELEGATE(@"%@ %p URLSession:%@ downloadTask:%@ didResumeAtOffset:%lld"
                           @" expectedTotalBytes:%lld",
                           [self class], self, session, downloadTask, fileOffset,
                           expectedTotalBytes);
  [self setSessionTask:downloadTask];
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)downloadLocationURL {
  // Download may have relaunched app, so update _sessionTask.
  [self setSessionTask:downloadTask];
  GTM_LOG_SESSION_DELEGATE(@"%@ %p URLSession:%@ downloadTask:%@ didFinishDownloadingToURL:%@",
                           [self class], self, session, downloadTask, downloadLocationURL);
  NSFileManager *fileMgr = [NSFileManager defaultManager];
  NSDictionary *attributes = [fileMgr attributesOfItemAtPath:[downloadLocationURL path]
                                                       error:NULL];
  @synchronized(self) {
    NSURL *destinationURL = self.destinationFileURL;

    _downloadedLength = (int64_t)[attributes fileSize];

    // Overwrite any previous file at the destination URL.
    [fileMgr removeItemAtURL:destinationURL error:NULL];

    NSError *error;
    if (![fileMgr moveItemAtURL:downloadLocationURL
                          toURL:destinationURL
                          error:&error]) {
      _downloadFinishedError = error;
    }
    GTM_LOG_BACKGROUND_SESSION(@"%@ %p Moved download from \"%@\" to \"%@\"  %@",
                               [self class], self,
                               [downloadLocationURL path], [destinationURL path],
                               error ? error : @"");
  }
}

/* Sent as the last message related to a specific task.  Error may be
 * nil, which implies that no error occurred and this task is complete.
 */
- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
  [self setSessionTask:task];
  GTM_LOG_SESSION_DELEGATE(@"%@ %p URLSession:%@ task:%@ didCompleteWithError:%@",
                           [self class], self, session, task, error);

  NSInteger status = self.statusCode;
  BOOL succeeded = NO;
  @synchronized(self) {
    if (error == nil) {
      error = _downloadFinishedError;
    }
    succeeded = (error == nil && status >= 0 && status < 300);
    if (succeeded) {
      // Succeeded.
      _bodyLength = task.countOfBytesSent;
    }
  }

  if (succeeded) {
    [self finishWithError:nil shouldRetry:NO];
    return;
  }
  // For background redirects, no delegate method is called, so we cannot restore a stripped
  // Authorization header, so if a 403 was generated due to a missing OAuth header, set the current
  // request's URL to the redirected URL, so we in effect restore the Authorization header.
  if ((status == 403) && _useBackgroundSession) {
    NSURL *redirectURL = [self.response URL];
    if (![[_request URL] isEqual:redirectURL]) {
      NSString *authorizationHeader =
          [[_request allHTTPHeaderFields] objectForKey:@"Authorization"];
      if (authorizationHeader != nil) {
        [_request setURL:redirectURL];
        [self retryFetch];
        return;
      }
    }
  }
  // Failed.
  [self shouldRetryNowForStatus:status error:error response:^(BOOL shouldRetry) {
    [self finishWithError:error shouldRetry:shouldRetry];
  }];
}

#if TARGET_OS_IPHONE
- (void)URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)session {
  GTM_LOG_SESSION_DELEGATE(@"%@ %p URLSessionDidFinishEventsForBackgroundURLSession:%@",
                           [self class], self, session);
  [self removePersistedBackgroundSessionFromDefaults];

  GTMSessionFetcherSystemCompletionHandler handler;
  @synchronized(self) {
    handler = self.systemCompletionHandler;
    self.systemCompletionHandler = nil;
  }
  if (handler) {
    GTM_LOG_BACKGROUND_SESSION(@"%@ %p Calling system completionHandler", [self class], self);
    handler();

    @synchronized(self) {
      NSURLSession *oldSession = _session;
      _session = nil;
      if (_shouldInvalidateSession) {
        [oldSession finishTasksAndInvalidate];
      }
    }
  }
}
#endif

- (void)URLSession:(NSURLSession *)session didBecomeInvalidWithError:(NSError *)error {
  // This may happen repeatedly for retries.  On authentication callbacks, the retry
  // may begin before the prior session sends the didBecomeInvalid delegate message.
  GTM_LOG_SESSION_DELEGATE(@"%@ %p URLSession:%@ didBecomeInvalidWithError:%@",
                           [self class], self, session, error);
}

- (void)finishWithError:(NSError *)error shouldRetry:(BOOL)shouldRetry {
  [self removePersistedBackgroundSessionFromDefaults];

  BOOL shouldStopFetching = YES;
  NSData *downloadedData = nil;
#if !STRIP_GTM_FETCH_LOGGING
  BOOL shouldDeferLogging = NO;
#endif
  BOOL shouldBeginRetryTimer = NO;

  @synchronized(self) {

    NSInteger status = [self statusCode];
#if !STRIP_GTM_FETCH_LOGGING
    shouldDeferLogging = _deferResponseBodyLogging;
#endif
    if (error == nil && status >= 0 && status < 300) {
      // Success
      NSURL *destinationURL = self.destinationFileURL;
      if (([_downloadedData length] > 0) && (destinationURL != nil)) {
        // Overwrite any previous file at the destination URL.
        [[NSFileManager defaultManager] removeItemAtURL:destinationURL error:NULL];
        if ([_downloadedData writeToURL:destinationURL options:NSDataWritingAtomic error:&error]) {
          _downloadedData = nil;
        } else {
          _downloadFinishedError = error;
        }
      }
      downloadedData = _downloadedData;
    } else {
      // Unsuccessful
#if !STRIP_GTM_FETCH_LOGGING
      if (!shouldDeferLogging && !_hasLoggedError) {
        [self logNowWithError:error];
        _hasLoggedError = YES;
      }
#endif
      // Status over 300; retry or notify the delegate of failure
      if (shouldRetry) {
        // retrying
        shouldBeginRetryTimer = YES;
        shouldStopFetching = NO;
      } else {
        if (error == nil) {
          // Create an error.
          NSDictionary *userInfo = nil;
          if ([_downloadedData length] > 0) {
            userInfo = @{ kGTMSessionFetcherStatusDataKey : _downloadedData };
          }
          error = [NSError errorWithDomain:kGTMSessionFetcherStatusDomain
                                      code:status
                                  userInfo:userInfo];
        } else {
          // If the error had resume data, and the client supplied a resume block, pass the
          // data to the client.
          void (^resumeBlock)(NSData *) = _resumeDataBlock;
          _resumeDataBlock = nil;
          if (resumeBlock) {
            NSData *resumeData = [[error userInfo] objectForKey:NSURLSessionDownloadTaskResumeData];
            if (resumeData) {
              [self invokeOnCallbackQueueAfterUserStopped:YES block:^{
                  resumeBlock(resumeData);
              }];
            }
          }
        }
        if ([_downloadedData length] > 0) {
          downloadedData = _downloadedData;
        }
      }
    }
  }  // @synchronized(self)

  if (shouldBeginRetryTimer) {
    [self beginRetryTimer];
  }

  // We want to send the stop notification before calling the delegate's
  // callback selector, since the callback selector may release all of
  // the fetcher properties that the client is using to track the fetches.
  //
  // We'll also stop now so that, to any observers watching the notifications,
  // it doesn't look like our wait for a retry (which may be long,
  // 30 seconds or more) is part of the network activity.
  [self sendStopNotificationIfNeeded];

  if (shouldStopFetching) {
    [self invokeFetchCallbacksOnCallbackQueueWithData:downloadedData
                                                error:error];
    // The upload subclass doesn't want to release callbacks until upload chunks have completed.
    BOOL shouldRelease = [self shouldReleaseCallbacksUponCompletion];
    [self stopFetchReleasingCallbacks:shouldRelease];
  }

#if !STRIP_GTM_FETCH_LOGGING
  @synchronized(self) {
    if (!shouldDeferLogging && !_hasLoggedError) {
      [self logNowWithError:error];
    }
  }
#endif
}

- (BOOL)shouldReleaseCallbacksUponCompletion {
  // A subclass can override this to keep callbacks around after the
  // connection has finished successfully
  return YES;
}

- (void)logNowWithError:(NSError *)error {
  // If the logging category is available, then log the current request,
  // response, data, and error
  if ([self respondsToSelector:@selector(logFetchWithError:)]) {
    [self performSelector:@selector(logFetchWithError:) withObject:error];
  }
}

#pragma mark Retries

- (BOOL)isRetryError:(NSError *)error {
  struct RetryRecord {
    __unsafe_unretained NSString *const domain;
    int code;
  };

  struct RetryRecord retries[] = {
    { kGTMSessionFetcherStatusDomain, 408 }, // request timeout
    { kGTMSessionFetcherStatusDomain, 502 }, // failure gatewaying to another server
    { kGTMSessionFetcherStatusDomain, 503 }, // service unavailable
    { kGTMSessionFetcherStatusDomain, 504 }, // request timeout
    { NSURLErrorDomain, NSURLErrorTimedOut },
    { NSURLErrorDomain, NSURLErrorNetworkConnectionLost },
    { nil, 0 }
  };

  // NSError's isEqual always returns false for equal but distinct instances
  // of NSError, so we have to compare the domain and code values explicitly

  for (int idx = 0; retries[idx].domain != nil; idx++) {

    if ([[error domain] isEqual:retries[idx].domain]
        && [error code] == retries[idx].code) {

      return YES;
    }
  }
  return NO;
}

// shouldRetryNowForStatus:error: responds with YES if the user has enabled retries
// and the status or error is one that is suitable for retrying.  "Suitable"
// means either the isRetryError:'s list contains the status or error, or the
// user's retry block is present and returns YES when called, or the
// authorizer may be able to fix.
- (void)shouldRetryNowForStatus:(NSInteger)status
                          error:(NSError *)error
                       response:(GTMSessionFetcherRetryResponse)response {
  // Determine if a refreshed authorizer may avoid an authorization error
  BOOL willRetry = NO;

  @synchronized(self) {
    BOOL shouldRetryForAuthRefresh = NO;
    BOOL isFirstAuthError = (_authorizer != nil
                             && !_hasAttemptedAuthRefresh
                             && status == GTMSessionFetcherStatusUnauthorized); // 401

    if (isFirstAuthError) {
      if ([_authorizer respondsToSelector:@selector(primeForRefresh)]) {
        BOOL hasPrimed = [_authorizer primeForRefresh];
        if (hasPrimed) {
          shouldRetryForAuthRefresh = YES;
          _hasAttemptedAuthRefresh = YES;
          [_request setValue:nil forHTTPHeaderField:@"Authorization"];
        }
      }
    }
    BOOL shouldDoRetry = [self isRetryEnabled];
    if (shouldDoRetry && ![self hasRetryAfterInterval]) {

      // Determine if we're doing exponential backoff retries
      shouldDoRetry = [self nextRetryInterval] < [self maxRetryInterval];

      if (shouldDoRetry) {
        // If an explicit max retry interval was set, we expect repeated backoffs to take
        // up to roughly twice that for repeated fast failures.  If the initial attempt is
        // already more than 3 times the max retry interval, then failures have taken a long time
        // (such as from network timeouts) so don't retry again to avoid the app becoming
        // unexpectedly unresponsive.
        if (_maxRetryInterval > 0) {
          NSTimeInterval maxAllowedIntervalBeforeRetry = _maxRetryInterval * 3;
          NSTimeInterval timeSinceInitialRequest = -[_initialRequestDate timeIntervalSinceNow];
          if (timeSinceInitialRequest > maxAllowedIntervalBeforeRetry) {
            shouldDoRetry = NO;
          }
        }
      }
    }
    BOOL canRetry = shouldRetryForAuthRefresh || shouldDoRetry;
    if (canRetry) {
      NSDictionary *userInfo = nil;
      if ([_downloadedData length] > 0) {
        userInfo = @{ kGTMSessionFetcherStatusDataKey : _downloadedData };
      }
      NSError *statusError = [NSError errorWithDomain:kGTMSessionFetcherStatusDomain
                                                 code:status
                                             userInfo:userInfo];
      if (error == nil) {
        error = statusError;
      }
      willRetry = shouldRetryForAuthRefresh ||
                  [self isRetryError:error] ||
                  ((error != statusError) && [self isRetryError:statusError]);

      // If the user has installed a retry callback, consult that.
      GTMSessionFetcherRetryBlock retryBlock = _retryBlock;
      if (retryBlock) {
        [self invokeOnCallbackQueueUnlessStopped:^{
            retryBlock(willRetry, error, response);
        }];
        return;
      }
    }
  }
  response(willRetry);
}

- (BOOL)hasRetryAfterInterval {
  NSDictionary *responseHeaders = [self responseHeaders];
  NSString *retryAfterValue = [responseHeaders valueForKey:@"Retry-After"];
  return (retryAfterValue != nil);
}

- (NSTimeInterval)retryAfterInterval {
  NSDictionary *responseHeaders = [self responseHeaders];
  NSString *retryAfterValue = [responseHeaders valueForKey:@"Retry-After"];
  if (retryAfterValue == nil) {
    return 0;
  }
  // Retry-After formatted as HTTP-date | delta-seconds
  // Reference: http://www.w3.org/Protocols/rfc2616/rfc2616-sec14.html
  NSDateFormatter *rfc1123DateFormatter = [[NSDateFormatter alloc] init];
  rfc1123DateFormatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US"];
  rfc1123DateFormatter.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"GMT"];
  rfc1123DateFormatter.dateFormat = @"EEE',' dd MMM yyyy HH':'mm':'ss z";
  NSDate *retryAfterDate = [rfc1123DateFormatter dateFromString:retryAfterValue];
  NSTimeInterval retryAfterInterval = (retryAfterDate != nil) ?
      [retryAfterDate timeIntervalSinceNow] : [retryAfterValue intValue];
  retryAfterInterval = MAX(0, retryAfterInterval);
  return retryAfterInterval;
}

- (void)beginRetryTimer {
  if (![NSThread isMainThread]) {
    // Defer creating and starting the timer until we're on the main thread to ensure it has
    // a run loop.
    dispatch_group_async(_callbackGroup, dispatch_get_main_queue(), ^{
        [self beginRetryTimer];
    });
    return;
  }

  NSTimeInterval nextInterval = [self nextRetryInterval];
  NSTimeInterval maxInterval = [self maxRetryInterval];
  NSTimeInterval newInterval = MIN(nextInterval, (maxInterval > 0 ? maxInterval : DBL_MAX));

  [self destroyRetryTimer];

  @synchronized(self) {
    _lastRetryInterval = newInterval;

    _retryTimer = [NSTimer timerWithTimeInterval:newInterval
                                          target:self
                                        selector:@selector(retryTimerFired:)
                                        userInfo:nil
                                         repeats:NO];
    [[NSRunLoop mainRunLoop] addTimer:_retryTimer
                              forMode:NSDefaultRunLoopMode];
  }

  NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
  [nc postNotificationName:kGTMSessionFetcherRetryDelayStartedNotification
                    object:self];
}

- (void)retryTimerFired:(NSTimer *)timer {
  [self destroyRetryTimer];

  @synchronized(self) {
    _retryCount++;

    [self retryFetch];
  }
}

- (void)destroyRetryTimer {
  BOOL shouldNotify = NO;
  @synchronized(self) {
    if (_retryTimer) {
      [_retryTimer invalidate];
      _retryTimer = nil;
      shouldNotify = YES;
    }
  }  // @synchronized(self)

  if (shouldNotify) {
    NSNotificationCenter *defaultNC = [NSNotificationCenter defaultCenter];
    [defaultNC postNotificationName:kGTMSessionFetcherRetryDelayStoppedNotification
                             object:self];
  }
}

- (NSUInteger)retryCount {
  return _retryCount;
}

- (NSTimeInterval)nextRetryInterval {
  NSInteger statusCode = [self statusCode];
  if ((statusCode == 503) && [self hasRetryAfterInterval]) {
    NSTimeInterval secs = [self retryAfterInterval];
    return secs;
  }
  // The next wait interval is the factor (2.0) times the last interval,
  // but never less than the minimum interval.
  NSTimeInterval secs = _lastRetryInterval * _retryFactor;
  if (_maxRetryInterval > 0) {
    secs = MIN(secs, _maxRetryInterval);
  }
  secs = MAX(secs, _minRetryInterval);

  return secs;
}

- (NSTimer *)retryTimer {
  return _retryTimer;
}

- (BOOL)isRetryEnabled {
  return _isRetryEnabled;
}

- (void)setRetryEnabled:(BOOL)flag {

  if (flag && !_isRetryEnabled) {
    // We defer initializing these until the user calls setRetryEnabled
    // to avoid using the random number generator if it's not needed.
    // However, this means min and max intervals for this fetcher are reset
    // as a side effect of calling setRetryEnabled.
    //
    // Make an initial retry interval random between 1.0 and 2.0 seconds
    [self setMinRetryInterval:0.0];
    [self setMaxRetryInterval:kUnsetMaxRetryInterval];
    [self setRetryFactor:2.0];
    _lastRetryInterval = 0.0;
  }
  _isRetryEnabled = flag;
};

- (NSTimeInterval)maxRetryInterval {
  return _maxRetryInterval;
}

- (void)setMaxRetryInterval:(NSTimeInterval)secs {
  if (secs > 0) {
    _maxRetryInterval = secs;
  } else {
    _maxRetryInterval = kUnsetMaxRetryInterval;
  }
}

- (double)minRetryInterval {
  return _minRetryInterval;
}

- (void)setMinRetryInterval:(NSTimeInterval)secs {
  if (secs > 0) {
    _minRetryInterval = secs;
  } else {
    // Set min interval to a random value between 1.0 and 2.0 seconds
    // so that if multiple clients start retrying at the same time, they'll
    // repeat at different times and avoid overloading the server
    _minRetryInterval = InitialMinRetryInterval();
  }
}

#pragma mark iOS System Completion Handlers

#if TARGET_OS_IPHONE
static NSMutableDictionary *gSystemCompletionHandlers = nil;

- (GTMSessionFetcherSystemCompletionHandler)systemCompletionHandler {
  return [[self class] systemCompletionHandlerForSessionIdentifier:_sessionIdentifier];
}

- (void)setSystemCompletionHandler:(GTMSessionFetcherSystemCompletionHandler)systemCompletionHandler {
  [[self class] setSystemCompletionHandler:systemCompletionHandler
                      forSessionIdentifier:_sessionIdentifier];
}

+ (void)setSystemCompletionHandler:(GTMSessionFetcherSystemCompletionHandler)systemCompletionHandler
              forSessionIdentifier:(NSString *)sessionIdentifier {
  @synchronized([GTMSessionFetcher class]) {
    if (gSystemCompletionHandlers == nil && systemCompletionHandler != nil) {
      gSystemCompletionHandlers = [[NSMutableDictionary alloc] init];
    }
    // Use setValue: to remove the object if completionHandler is nil.
    [gSystemCompletionHandlers setValue:systemCompletionHandler
                                 forKey:sessionIdentifier];
  }
}

+ (GTMSessionFetcherSystemCompletionHandler)systemCompletionHandlerForSessionIdentifier:(NSString *)sessionIdentifier {
  if (!sessionIdentifier) {
    return nil;
  }
  @synchronized([GTMSessionFetcher class]) {
    return [gSystemCompletionHandlers objectForKey:sessionIdentifier];
  }
}
#endif  // TARGET_OS_IPHONE

#pragma mark Getters and Setters

@synthesize mutableRequest = _request,
            downloadResumeData = _downloadResumeData,
            configuration = _configuration,
            configurationBlock = _configurationBlock,
            sessionTask = _sessionTask,
            sessionUserInfo = _sessionUserInfo,
            taskDescription = _taskDescription,
            useBackgroundSession = _useBackgroundSession,
            canShareSession = _canShareSession,
            completionHandler = _completionHandler,
            credential = _credential,
            proxyCredential = _proxyCredential,
            bodyData = _bodyData,
            bodyFileURL = _bodyFileURL,
            bodyLength = _bodyLength,
            bodyStreamProvider = _bodyStreamProvider,
            authorizer = _authorizer,
            service = _service,
            serviceHost = _serviceHost,
            servicePriority = _servicePriority,
            accumulateDataBlock = _accumulateDataBlock,
            receivedProgressBlock = _receivedProgressBlock,
            downloadProgressBlock = _downloadProgressBlock,
            resumeDataBlock = _resumeDataBlock,
            didReceiveResponseBlock = _didReceiveResponseBlock,
            willRedirectBlock = _willRedirectBlock,
            sendProgressBlock = _sendProgressBlock,
            willCacheURLResponseBlock = _willCacheURLResponseBlock,
            retryBlock = _retryBlock,
            retryFactor = _retryFactor,
            downloadedLength = _downloadedLength,
            downloadedData = _downloadedData,
            useUploadTask = _useUploadTask,
            allowedInsecureSchemes = _allowedInsecureSchemes,
            allowLocalhostRequest = _allowLocalhostRequest,
            allowInvalidServerCertificates = _allowInvalidServerCertificates,
            cookieStorage = _cookieStorage,
            callbackQueue = _callbackQueue,
            testBlock = _testBlock,
            comment = _comment,
            log = _log;

#if !STRIP_GTM_FETCH_LOGGING
@synthesize redirectedFromURL = _redirectedFromURL,
            logRequestBody = _logRequestBody,
            logResponseBody = _logResponseBody,
            hasLoggedError = _hasLoggedError;
#endif

- (int64_t)bodyLength {
  @synchronized(self) {
    if (_bodyLength == NSURLSessionTransferSizeUnknown) {
      if (_bodyData) {
        _bodyLength = (int64_t)[_bodyData length];
      } else if (_bodyFileURL) {
        NSNumber *fileSizeNum = nil;
        NSError *fileSizeError = nil;
        if ([_bodyFileURL getResourceValue:&fileSizeNum
                                    forKey:NSURLFileSizeKey
                                     error:&fileSizeError]) {
          _bodyLength = [fileSizeNum longLongValue];
        }
      }
    }
    return _bodyLength;
  }
}

- (dispatch_queue_t)callbackQueue {
  @synchronized(self) {
    return _callbackQueue;
  }
}

- (void)setCallbackQueue:(dispatch_queue_t)queue {
  @synchronized(self) {
    _callbackQueue = queue;
  }
}

- (NSURLSession *)session {
  @synchronized(self) {
    return _session;
  }
}

- (void)setSession:(NSURLSession *)session {
  @synchronized(self) {
    if (_session != session) {
      _session = session;

      _shouldInvalidateSession = (session != nil);
    }
  }
}

- (BOOL)canShareSession {
  @synchronized(self) {
    return _canShareSession;
  }
}

- (id)userData {
  @synchronized(self) {
    return _userData;
  }
}

- (void)setUserData:(id)theObj {
  @synchronized(self) {
    _userData = theObj;
  }
}

- (NSURL *)destinationFileURL {
  @synchronized(self) {
    return _destinationFileURL;
  }
}

- (void)setDestinationFileURL:(NSURL *)destinationFileURL {
  @synchronized(self) {
    if (((_destinationFileURL == nil) && (destinationFileURL == nil)) ||
        [_destinationFileURL isEqual:destinationFileURL]) {
      return;
    }
    if (_sessionIdentifier) {
      // This is something we don't expect to happen in production.
      // However if it ever happen, leave a system log.
      NSLog(@"%@: Destination File URL changed from (%@) to (%@) after session identifier has "
            @"been created.",
            [self class], _destinationFileURL, destinationFileURL);
#if DEBUG
      // On both the simulator and devices, the path can change to the download file, but the name
      // shouldn't change. Technically, this isn't supported in the fetcher, but the change of
      // URL is expected to happen only across development runs through Xcode.
      NSString *oldFilename = [_destinationFileURL lastPathComponent];
      NSString *newFilename = [destinationFileURL lastPathComponent];
      GTMSESSION_ASSERT_DEBUG([oldFilename isEqualToString:newFilename],
          @"Destination File URL cannot be changed after session identifier has been created");
#endif
    }
    _destinationFileURL = destinationFileURL;
  }
}

- (void)setProperties:(NSDictionary *)dict {
  @synchronized(self) {
    _properties = [dict mutableCopy];
  }
}

- (NSDictionary *)properties {
  @synchronized(self) {
    return _properties;
  }
}

- (void)setProperty:(id)obj forKey:(NSString *)key {
  @synchronized(self) {
    if (_properties == nil && obj != nil) {
      [self setProperties:[NSMutableDictionary dictionary]];
    }
    [_properties setValue:obj forKey:key];
  }
}

- (id)propertyForKey:(NSString *)key {
  @synchronized(self) {
    return [_properties objectForKey:key];
  }
}

- (void)addPropertiesFromDictionary:(NSDictionary *)dict {
  @synchronized(self) {
    if (_properties == nil && dict != nil) {
      [self setProperties:[dict mutableCopy]];
    } else {
      [_properties addEntriesFromDictionary:dict];
    }
  }
}

- (void)setCommentWithFormat:(id)format, ... {
#if !STRIP_GTM_FETCH_LOGGING
  NSString *result = format;
  if (format) {
    va_list argList;
    va_start(argList, format);

    result = [[NSString alloc] initWithFormat:format
                                    arguments:argList];
    va_end(argList);
  }
  [self setComment:result];
#endif
}

#if !STRIP_GTM_FETCH_LOGGING
- (NSData *)loggedStreamData {
  return _loggedStreamData;
}

- (void)appendLoggedStreamData:dataToAdd {
  if (!_loggedStreamData) {
    _loggedStreamData = [NSMutableData data];
  }
  [_loggedStreamData appendData:dataToAdd];
}

- (void)clearLoggedStreamData {
  _loggedStreamData = nil;
}

- (void)setDeferResponseBodyLogging:(BOOL)deferResponseBodyLogging {
  @synchronized(self) {
    if (deferResponseBodyLogging != _deferResponseBodyLogging) {
      _deferResponseBodyLogging = deferResponseBodyLogging;
      if (!deferResponseBodyLogging && !self.hasLoggedError) {
        [_delegateQueue addOperationWithBlock:^{
          @synchronized(self) {
            [self logNowWithError:nil];
          }
        }];
      }
    }
  }
}

- (BOOL)deferResponseBodyLogging {
  @synchronized(self) {
    return _deferResponseBodyLogging;
  }
}

#else
+ (void)setLoggingEnabled:(BOOL)flag {
}

+ (BOOL)isLoggingEnabled {
  return NO;
}
#endif // STRIP_GTM_FETCH_LOGGING

@end

@implementation GTMSessionFetcher (BackwardsCompatibilityOnly)

- (void)setCookieStorageMethod:(NSInteger)method {
  // For backwards compatibility with the old fetcher, we'll support the old constants.
  //
  // Clients using the GTMSessionFetcher class should set the cookie storage explicitly
  // themselves.
  NSHTTPCookieStorage *storage = nil;
  switch(method) {
    case 0:  // kGTMHTTPFetcherCookieStorageMethodStatic
             // nil storage will use [[self class] staticCookieStorage] when the fetch begins.
      break;
    case 1:  // kGTMHTTPFetcherCookieStorageMethodFetchHistory
             // Do nothing; use whatever was set by the fetcher service.
      return;
    case 2:  // kGTMHTTPFetcherCookieStorageMethodSystemDefault
      storage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
      break;
    case 3:  // kGTMHTTPFetcherCookieStorageMethodNone
             // Create temporary storage for this fetcher only.
      storage = [[GTMSessionCookieStorage alloc] init];
      break;
    default:
      GTMSESSION_ASSERT_DEBUG(0, @"Invalid cookie storage method: %d", (int)method);
  }
  self.cookieStorage = storage;
}

@end

@implementation GTMSessionCookieStorage {
  NSMutableArray *_cookies;
  NSHTTPCookieAcceptPolicy _policy;
}

- (id)init {
  self = [super init];
  if (self != nil) {
    _cookies = [[NSMutableArray alloc] init];
  }
  return self;
}

- (NSArray *)cookies {
  @synchronized(self) {
    return [_cookies copy];
  }
}

- (void)setCookie:(NSHTTPCookie *)cookie {
  if (!cookie) return;
  if (_policy == NSHTTPCookieAcceptPolicyNever) return;

  @synchronized(self) {
    [self internalSetCookie:cookie];
  }
}

// Note: this should only be called from inside a @synchronized(self) block.
- (void)internalSetCookie:(NSHTTPCookie *)newCookie {
  if (_policy == NSHTTPCookieAcceptPolicyNever) return;

  BOOL isValidCookie = ([[newCookie name] length] > 0
                        && [[newCookie domain] length] > 0
                        && [[newCookie path] length] > 0);
  GTMSESSION_ASSERT_DEBUG(isValidCookie, @"invalid cookie: %@", newCookie);

  if (isValidCookie) {
    // Remove the cookie if it's currently in the array.
    NSHTTPCookie *oldCookie = [self cookieMatchingCookie:newCookie];
    if (oldCookie) {
      [_cookies removeObjectIdenticalTo:oldCookie];
    }

    if (![[self class] hasCookieExpired:newCookie]) {
      [_cookies addObject:newCookie];
    }
  }
}

// Add all cookies in the new cookie array to the storage,
// replacing stored cookies as appropriate.
//
// Side effect: removes expired cookies from the storage array.
- (void)setCookies:(NSArray *)newCookies {
  @synchronized(self) {
    [self removeExpiredCookies];

    for (NSHTTPCookie *newCookie in newCookies) {
      [self internalSetCookie:newCookie];
    }
  }
}

- (void)setCookies:(NSArray *)cookies forURL:(NSURL *)URL mainDocumentURL:(NSURL *)mainDocumentURL {
  @synchronized(self) {
    if (_policy == NSHTTPCookieAcceptPolicyNever) return;

    if (_policy == NSHTTPCookieAcceptPolicyOnlyFromMainDocumentDomain) {
      NSString *mainHost = [mainDocumentURL host];
      NSString *associatedHost = [URL host];
      if (![associatedHost hasSuffix:mainHost]) {
        return;
      }
    }
  }
  [self setCookies:cookies];
}

- (void)deleteCookie:(NSHTTPCookie *)cookie {
  if (!cookie) return;

  @synchronized(self) {
    NSHTTPCookie *foundCookie = [self cookieMatchingCookie:cookie];
    if (foundCookie) {
      [_cookies removeObjectIdenticalTo:foundCookie];
    }
  }
}

// Retrieve all cookies appropriate for the given URL, considering
// domain, path, cookie name, expiration, security setting.
// Side effect: removed expired cookies from the storage array.
- (NSArray *)cookiesForURL:(NSURL *)theURL {
  NSMutableArray *foundCookies = nil;

  @synchronized(self) {
    [self removeExpiredCookies];

    // We'll prepend "." to the desired domain, since we want the
    // actual domain "nytimes.com" to still match the cookie domain
    // ".nytimes.com" when we check it below with hasSuffix.
    NSString *host = [[theURL host] lowercaseString];
    NSString *path = [theURL path];
    NSString *scheme = [theURL scheme];

    NSString *requestingDomain = nil;
    BOOL isLocalhostRetrieval = NO;

    if (IsLocalhost(host)) {
      isLocalhostRetrieval = YES;
    } else {
      if ([host length] > 0) {
        requestingDomain = [@"." stringByAppendingString:host];
      }
    }

    for (NSHTTPCookie *storedCookie in _cookies) {
      NSString *cookieDomain = [[storedCookie domain] lowercaseString];
      NSString *cookiePath = [storedCookie path];
      BOOL cookieIsSecure = [storedCookie isSecure];

      BOOL isDomainOK;

      if (isLocalhostRetrieval) {
        // Prior to 10.5.6, the domain stored into NSHTTPCookies for localhost
        // is "localhost.local"
        isDomainOK = (IsLocalhost(cookieDomain)
                      || [cookieDomain isEqual:@"localhost.local"]);
      } else {
        // Ensure we're matching exact domain names. We prepended a dot to the
        // requesting domain, so we can also prepend one here if needed before
        // checking if the request contains the cookie domain.
        if (![cookieDomain hasPrefix:@"."]) {
          cookieDomain = [@"." stringByAppendingString:cookieDomain];
        }
        isDomainOK = [requestingDomain hasSuffix:cookieDomain];
      }

      BOOL isPathOK = [cookiePath isEqual:@"/"] || [path hasPrefix:cookiePath];
      BOOL isSecureOK = (!cookieIsSecure
                         || [scheme caseInsensitiveCompare:@"https"] == NSOrderedSame);

      if (isDomainOK && isPathOK && isSecureOK) {
        if (foundCookies == nil) {
          foundCookies = [NSMutableArray array];
        }
        [foundCookies addObject:storedCookie];
      }
    }
  }
  return foundCookies;
}

// Override methods from the NSHTTPCookieStorage (NSURLSessionTaskAdditions) category.
- (void)storeCookies:(NSArray *)cookies forTask:(NSURLSessionTask *)task {
  NSURLRequest *currentRequest = task.currentRequest;
  [self setCookies:cookies forURL:currentRequest.URL mainDocumentURL:nil];
}

- (void)getCookiesForTask:(NSURLSessionTask *)task
        completionHandler:(void (^)(GTM_NSArrayOf(NSHTTPCookie *) *))completionHandler {
  if (completionHandler) {
    NSURLRequest *currentRequest = task.currentRequest;
    NSArray *cookies = [self cookiesForURL:currentRequest.URL];
    completionHandler(cookies);
  }
}

// Return a cookie from the array with the same name, domain, and path as the
// given cookie, or else return nil if none found.
//
// Both the cookie being tested and all cookies in the storage array should
// be valid (non-nil name, domains, paths).
//
// Note: this should only be called from inside a @synchronized(self) block
- (NSHTTPCookie *)cookieMatchingCookie:(NSHTTPCookie *)cookie {
  NSString *name = [cookie name];
  NSString *domain = [cookie domain];
  NSString *path = [cookie path];

  GTMSESSION_ASSERT_DEBUG(name && domain && path,
                          @"Invalid stored cookie (name:%@ domain:%@ path:%@)", name, domain, path);

  for (NSHTTPCookie *storedCookie in _cookies) {
    if ([[storedCookie name] isEqual:name]
        && [[storedCookie domain] isEqual:domain]
        && [[storedCookie path] isEqual:path]) {
      return storedCookie;
    }
  }
  return nil;
}

// Internal routine to remove any expired cookies from the array, excluding
// cookies with nil expirations.
//
// Note: this should only be called from inside a @synchronized(self) block
- (void)removeExpiredCookies {
  // Count backwards since we're deleting items from the array
  for (NSInteger idx = (NSInteger)[_cookies count] - 1; idx >= 0; idx--) {
    NSHTTPCookie *storedCookie = [_cookies objectAtIndex:(NSUInteger)idx];
    if ([[self class] hasCookieExpired:storedCookie]) {
      [_cookies removeObjectAtIndex:(NSUInteger)idx];
    }
  }
}

+ (BOOL)hasCookieExpired:(NSHTTPCookie *)cookie {
  NSDate *expiresDate = [cookie expiresDate];
  if (expiresDate == nil) {
    // Cookies seem to have a Expires property even when the expiresDate method returns nil.
    id expiresVal = [[cookie properties] objectForKey:NSHTTPCookieExpires];
    if ([expiresVal isKindOfClass:[NSDate class]]) {
      expiresDate = expiresVal;
    }
  }
  BOOL hasExpired = (expiresDate != nil && [expiresDate timeIntervalSinceNow] < 0);
  return hasExpired;
}

- (void)removeAllCookies {
  @synchronized(self) {
    [_cookies removeAllObjects];
  }
}

- (NSHTTPCookieAcceptPolicy)cookieAcceptPolicy {
  @synchronized(self) {
    return _policy;
  }
}

- (void)setCookieAcceptPolicy:(NSHTTPCookieAcceptPolicy)cookieAcceptPolicy {
  @synchronized(self) {
    _policy = cookieAcceptPolicy;
  }
}

@end

void GTMSessionFetcherAssertValidSelector(id obj, SEL sel, ...) {
  // Verify that the object's selector is implemented with the proper
  // number and type of arguments
#if DEBUG
  va_list argList;
  va_start(argList, sel);

  if (obj && sel) {
    // Check that the selector is implemented
    if (![obj respondsToSelector:sel]) {
      NSLog(@"\"%@\" selector \"%@\" is unimplemented or misnamed",
                             NSStringFromClass([obj class]),
                             NSStringFromSelector(sel));
      NSCAssert(0, @"callback selector unimplemented or misnamed");
    } else {
      const char *expectedArgType;
      unsigned int argCount = 2; // skip self and _cmd
      NSMethodSignature *sig = [obj methodSignatureForSelector:sel];

      // Check that each expected argument is present and of the correct type
      while ((expectedArgType = va_arg(argList, const char*)) != 0) {

        if ([sig numberOfArguments] > argCount) {
          const char *foundArgType = [sig getArgumentTypeAtIndex:argCount];

          if (0 != strncmp(foundArgType, expectedArgType, strlen(expectedArgType))) {
            NSLog(@"\"%@\" selector \"%@\" argument %d should be type %s",
                  NSStringFromClass([obj class]),
                  NSStringFromSelector(sel), (argCount - 2), expectedArgType);
            NSCAssert(0, @"callback selector argument type mistake");
          }
        }
        argCount++;
      }

      // Check that the proper number of arguments are present in the selector
      if (argCount != [sig numberOfArguments]) {
        NSLog(@"\"%@\" selector \"%@\" should have %d arguments",
              NSStringFromClass([obj class]),
              NSStringFromSelector(sel), (argCount - 2));
        NSCAssert(0, @"callback selector arguments incorrect");
      }
    }
  }

  va_end(argList);
#endif
}

NSString *GTMFetcherCleanedUserAgentString(NSString *str) {
  // Reference http://www.w3.org/Protocols/rfc2616/rfc2616-sec2.html
  // and http://www-archive.mozilla.org/build/user-agent-strings.html

  if (str == nil) return nil;

  NSMutableString *result = [NSMutableString stringWithString:str];

  // Replace spaces and commas with underscores
  [result replaceOccurrencesOfString:@" "
                          withString:@"_"
                             options:0
                               range:NSMakeRange(0, [result length])];
  [result replaceOccurrencesOfString:@","
                          withString:@"_"
                             options:0
                               range:NSMakeRange(0, [result length])];

  // Delete http token separators and remaining whitespace
  static NSCharacterSet *charsToDelete = nil;
  if (charsToDelete == nil) {
    // Make a set of unwanted characters
    NSString *const kSeparators = @"()<>@;:\\\"/[]?={}";

    NSMutableCharacterSet *mutableChars =
        [[NSCharacterSet whitespaceAndNewlineCharacterSet] mutableCopy];
    [mutableChars addCharactersInString:kSeparators];
    charsToDelete = [mutableChars copy]; // hang on to an immutable copy
  }

  while (1) {
    NSRange separatorRange = [result rangeOfCharacterFromSet:charsToDelete];
    if (separatorRange.location == NSNotFound) break;

    [result deleteCharactersInRange:separatorRange];
  };

  return result;
}

NSString *GTMFetcherSystemVersionString(void) {
  static NSString *sSavedSystemString;

  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
#if TARGET_OS_MAC && !TARGET_OS_IPHONE
    // Mac build
    NSProcessInfo *procInfo = [NSProcessInfo processInfo];
#if !defined(MAC_OS_X_VERSION_10_10)
    BOOL hasOperatingSystemVersion = NO;
#elif MAC_OS_X_VERSION_MIN_REQUIRED < MAC_OS_X_VERSION_10_10
    BOOL hasOperatingSystemVersion =
        [procInfo respondsToSelector:@selector(operatingSystemVersion)];
#else
    BOOL hasOperatingSystemVersion = YES;
#endif
    NSString *versString;
    if (hasOperatingSystemVersion) {
#if defined(MAC_OS_X_VERSION_10_10)
      // A reference to NSOperatingSystemVersion requires the 10.10 SDK.
      NSOperatingSystemVersion version = procInfo.operatingSystemVersion;
      versString = [NSString stringWithFormat:@"%zd.%zd.%zd",
                    version.majorVersion, version.minorVersion, version.patchVersion];
#else
#pragma unused(procInfo)
#endif
    } else {
      // With Gestalt inexplicably deprecated in 10.8, we're reduced to reading
      // the system plist file.
      NSString *const kPath = @"/System/Library/CoreServices/SystemVersion.plist";
      NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:kPath];
      versString = [plist objectForKey:@"ProductVersion"];
      if ([versString length] == 0) {
        versString = @"10.?.?";
      }
    }

    sSavedSystemString = [[NSString alloc] initWithFormat:@"MacOSX/%@", versString];
#elif TARGET_OS_IPHONE
    // Compiling against the iPhone SDK
    // Avoid the slowness of calling currentDevice repeatedly on the iPhone
    UIDevice* currentDevice = [UIDevice currentDevice];

    NSString *rawModel = [currentDevice model];
    NSString *model = GTMFetcherCleanedUserAgentString(rawModel);

    NSString *systemVersion = [currentDevice systemVersion];

#if TARGET_IPHONE_SIMULATOR
    NSString *hardwareModel = @"sim";
#else
    NSString *hardwareModel;
    struct utsname unameRecord;
    if (uname(&unameRecord) == 0) {
      NSString *machineName = [NSString stringWithCString:unameRecord.machine
                                                 encoding:NSUTF8StringEncoding];
      hardwareModel = GTMFetcherCleanedUserAgentString(machineName);
    } else {
      hardwareModel = @"unk";
    }
#endif

    sSavedSystemString = [[NSString alloc] initWithFormat:@"%@/%@ hw/%@",
                          model, systemVersion, hardwareModel];
    // Example:  iPod_Touch/2.2 hw/iPod1_1
#elif defined(_SYS_UTSNAME_H)
    // Foundation-only build
    struct utsname unameRecord;
    uname(&unameRecord);

    sSavedSystemString = [NSString stringWithFormat:@"%s/%s",
                          unameRecord.sysname, unameRecord.release]; // "Darwin/8.11.1"
#endif
  });
  return sSavedSystemString;
}

NSString *GTMFetcherStandardUserAgentString(NSBundle *bundle) {
  NSString *result = [NSString stringWithFormat:@"%@ %@",
                      GTMFetcherApplicationIdentifier(bundle),
                      GTMFetcherSystemVersionString()];
  return result;
}

NSString *GTMFetcherApplicationIdentifier(NSBundle *bundle) {
  @synchronized([GTMSessionFetcher class]) {
    static NSMutableDictionary *sAppIDMap = nil;

    // If there's a bundle ID, use that; otherwise, use the process name
    if (bundle == nil) {
      bundle = [NSBundle mainBundle];
    }
    NSString *bundleID = [bundle bundleIdentifier];
    if (bundleID == nil) {
      bundleID = @"";
    }

    NSString *identifier = [sAppIDMap objectForKey:bundleID];
    if (identifier) return identifier;

    // Apps may add a string to the info.plist to uniquely identify different builds.
    identifier = [bundle objectForInfoDictionaryKey:@"GTMUserAgentID"];
    if ([identifier length] == 0) {
      if ([bundleID length] > 0) {
        identifier = bundleID;
      } else {
        // Fall back on the procname, prefixed by "proc" to flag that it's
        // autogenerated and perhaps unreliable
        NSString *procName = [[NSProcessInfo processInfo] processName];
        identifier = [NSString stringWithFormat:@"proc_%@", procName];
      }
    }

    // Clean up whitespace and special characters
    identifier = GTMFetcherCleanedUserAgentString(identifier);

    // If there's a version number, append that
    NSString *version = [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    if ([version length] == 0) {
      version = [bundle objectForInfoDictionaryKey:@"CFBundleVersion"];
    }

    // Clean up whitespace and special characters
    version = GTMFetcherCleanedUserAgentString(version);

    // Glue the two together (cleanup done above or else cleanup would strip the
    // slash)
    if ([version length] > 0) {
      identifier = [identifier stringByAppendingFormat:@"/%@", version];
    }

    if (sAppIDMap == nil) {
      sAppIDMap = [[NSMutableDictionary alloc] init];
    }
    [sAppIDMap setObject:identifier forKey:bundleID];
    return identifier;
  }
}
