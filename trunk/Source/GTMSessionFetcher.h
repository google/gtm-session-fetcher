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

// GTMSessionFetcher is a wrapper around NSURLSession for http operations.
//
// What does this offer on top of of NSURLSession?
//
// - Block-style callbacks for useful functionality like progress rather than delegate methods.
// - Out-of-process uploads and downloads using NSURLSession, including management of fetches after
//   relaunch.
// - Integration with GTMOAuth2 for invisible management and refresh of authorization tokens.
// - Pretty-printed http logging.
// - Cookies handling that does not interfere with or get interfered with by WebKit cookies
//   or on Mac by Safari and other apps.
// - Credentials handling for the http operation.
// - Rate-limiting and cookie grouping when fetchers are created with GTMSessionFetcherService.
//
// If the bodyData or bodyFileURL property is set, then a POST request is assumed.
//
// Each fetcher is assumed to be for a one-shot fetch request; don't reuse the object
// for a second fetch.
//
// The fetcher will be self-retained as long as a connection is pending.
//
// To keep user activity private, URLs must have an https scheme (unless the property
// allowedInsecureSchemes is set to permit the scheme.)
//
// Callbacks will be released when the fetch completes or is stopped, so there is no need
// to use weak self references in the callback blocks.
//
// Sample usage:
//
//  GTMSessionFetcher *myFetcher = [GTMSessionFetcher fetcherWithURLString:myURLString];
//
//  // Optionally specify a file URL or NSData for the request body to upload.
//  myFetcher.bodyData = [postString dataUsingEncoding:NSUTF8StringEncoding];
//
//  // Optionally specify if the transfer should be done in another process.
//  myFetcher.useBackgroundSession = YES;
//
//  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
//    if (error != nil) {
//      // Status code or network error
//    } else {
//      // Succeeded
//    }
//  }];
//
// There is also a beginFetch call that takes a pointer and selector for the completion handler;
// a pointer and selector is a better style when the callback is a substantial, separate method.
//
// NOTE:  Fetches may retrieve data from the server even though the server
//        returned an error.  The completion handler is called when the server
//        status is >= 300 with an NSError having domain
//        kGTMSessionFetcherStatusDomain and code set to the server status.
//
//        Status codes are at <http://www.w3.org/Protocols/rfc2616/rfc2616-sec10.html>
//
//
// Background session support:
//
// Out-of-process uploads and downloads may be created by setting the useBackgroundSession property.
// Data to be uploaded should be provided with a file URL; the download destination should also
// specified with a file URL.
//
// When background sessions are used in iOS apps, the application delegate must pass
// through the parameters from UIApplicationDelegate's
// application:handleEventsForBackgroundURLSession:completionHandler: to the fetcher class.
//
// When the application has been relaunched, it may also create a new fetcher instance
// to handle completion of the transfers.
//
//  - (void)application:(UIApplication *)application
//      handleEventsForBackgroundURLSession:(NSString *)identifier
//                        completionHandler:(void (^)())completionHandler {
//    // Application was re-launched on completing an out-of-process download.
//
//    // Pass the URLSession info related to this re-launch to the fetcher class.
//    [GTMSessionFetcher application:application
//        handleEventsForBackgroundURLSession:identifier
//                          completionHandler:completionHandler];
//
//    // Get a fetcher related to this re-launch and re-hook up a completionHandler to it.
//    GTMSessionFetcher *fetcher = [GTMSessionFetcher fetcherWithSessionIdentifier:identifier];
//    NSURL *destinationFileURL = fetcher.destinationFileURL;
//    fetcher.completionHandler = ^(NSData *data, NSError *error) {
//      [self downloadCompletedToFile:destinationFileURL error:error];
//    };
//
//
// Threading and queue support:
//
// Callbacks are run on the main thread; alternatively, the app may set the
// fetcher's callbackQueue to a dispatch queue.
//
// Once the fetcher's beginFetch method has been called, the fetcher's methods and
// properties may be accessed from any thread.
//
// Downloading to disk:
//
// To have downloaded data saved directly to disk, specify a file URL for the
// destinationFileURL property.
//
// HTTP methods and headers:
//
// Alternative HTTP methods, like PUT, and custom headers can be specified by
// creating the fetcher with an appropriate NSMutableURLRequest
//
//
// Cookies:
//
// There are three supported mechanisms for remembering cookies between fetches.
//
// By default, a standalone GTMSessionFetcher uses a mutable array held statically to track
// cookies for all instantiated fetchers.  This avoids cookies being set by servers for the
// application from interfering with Safari and WebKit cookie settings, and vice versa.
// The fetcher cookies are lost when the application quits.
//
// To rely instead on WebKit's global NSHTTPCookieStorage, set the fetcher's
// cookieStorage property:
//   myFetcher.cookieStorage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
//
// To ignore cookies entirely, make a temporary cookie storage object:
//   myFetcher.cookieStorage = [[GTMSessionCookieStorage alloc] init];
//
// If the fetcher is created from a GTMHTTPFetcherService object
// then the cookie storage mechanism is set to use the cookie storage in the
// service object rather than the static storage.
//
//
// Monitoring data transfers.
//
// The fetcher supports a variety of properties for progress monitoring progress with callback
// blocks.
//  GTMSessionFetcherSendProgressBlock sendProgressBlock
//  GTMSessionFetcherReceivedProgressBlock receivedProgressBlock
//  GTMSessionFetcherDownloadProgressBlock downloadProgressBlock
//
// If supplied by the server, the anticipated total download size is available
// as [[myFetcher response] expectedContentLength] (and may be -1 for unknown
// download sizes.)
//
//
// Automatic retrying of fetches
//
// The fetcher can optionally create a timer and reattempt certain kinds of
// fetch failures (status codes 408, request timeout; 502, gateway failure;
// 503, service unavailable; 504, gateway timeout; networking errors
// NSURLErrorTimedOut and NSURLErrorNetworkConnectionLost.)  The user may
// set a retry selector to customize the type of errors which will be retried.
//
// Retries are done in an exponential-backoff fashion (that is, after 1 second,
// 2, 4, 8, and so on.)
//
// Enabling automatic retries looks like this:
//  myFetcher.retryEnabled = YES;
//
// With retries enabled, the completion callbacks are called only
// when no more retries will be attempted. Calling the fetcher's stopFetching
// method will terminate the retry timer, without the finished or failure
// selectors being invoked.
//
// Optionally, the client may set the maximum retry interval:
//  myFetcher.maxRetryInterval = 60.0; // in seconds; default is 60 seconds
//                                     // for downloads, 600 for uploads
//
// Also optionally, the client may provide a block to determine if a status code or other error
// should be retried. The block returns YES to set the retry timer or NO to fail without additional
// fetch attempts.
//
// The retry method may return the |suggestedWillRetry| argument to get the
// default retry behavior.  Server status codes are present in the
// error argument, and have the domain kGTMSessionFetcherStatusDomain. The
// user's method may look something like this:
//
//  myFetcher.retryBlock = ^(BOOL suggestedWillRetry, NSError *error,
//                           GTMSessionFetcherRetryResponse response) {
//    // Perhaps examine [error domain] and [error code], or [fetcher retryCount]
//    //
//    // Respond with YES to start the retry timer, NO to proceed to the failure
//    // callback, or suggestedWillRetry to get default behavior for the
//    // current error domain and code values.
//    response(suggestedWillRetry);
//  };


#import <Foundation/Foundation.h>

#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#endif

#ifndef GTMSESSION_LOG_DEBUG
  #if DEBUG
    #define GTMSESSION_LOG_DEBUG(...) NSLog(__VA_ARGS__)
  #else
    #define GTMSESSION_LOG_DEBUG(...)
  #endif
#endif

#ifndef GTMSESSION_LOG_DEBUG_IF
  #if DEBUG
    #define GTMSESSION_LOG_DEBUG_IF(cond, ...) if (cond) { NSLog(__VA_ARGS__); }
  #else
    #define GTMSESSION_LOG_DEBUG_IF(cond, ...) do { } while (0)
  #endif
#endif

#ifndef GTMSESSION_ASSERT_DEBUG
  #if DEBUG && !GTMSESSION_ASSERT_AS_LOG
    #define GTMSESSION_ASSERT_DEBUG(...) NSAssert(__VA_ARGS__)
  #else
    #define GTMSESSION_ASSERT_DEBUG(pred, ...) GTMSESSION_LOG_DEBUG_IF(!(pred), __VA_ARGS__)
  #endif
#endif

#ifdef __cplusplus
extern "C" {
#endif

#if !defined(GTMBridgeFetcher)
  // These bridge macros should be identical in GTMHTTPFetcher.h and GTMSessionFetcher.h
  #if GTM_USE_SESSION_FETCHER
  // Macros to new fetcher class.
    #define GTMBridgeFetcher GTMSessionFetcher
    #define GTMBridgeFetcherService GTMSessionFetcherService
    #define GTMBridgeFetcherServiceProtocol GTMSessionFetcherServiceProtocol
    #define GTMBridgeAssertValidSelector GTMSessionFetcherAssertValidSelector
    #define GTMBridgeCookieStorage GTMSessionCookieStorage
    #define GTMBridgeCleanedUserAgentString GTMFetcherCleanedUserAgentString
    #define GTMBridgeSystemVersionString GTMFetcherSystemVersionString
    #define GTMBridgeApplicationIdentifier GTMFetcherApplicationIdentifier
    #define kGTMBridgeFetcherStatusDomain kGTMSessionFetcherStatusDomain
    #define kGTMBridgeFetcherStatusBadRequest kGTMSessionFetcherStatusBadRequest
  #else
    // Macros to old fetcher class.
    #define GTMBridgeFetcher GTMHTTPFetcher
    #define GTMBridgeFetcherService GTMHTTPFetcherService
    #define GTMBridgeFetcherServiceProtocol GTMHTTPFetcherServiceProtocol
    #define GTMBridgeAssertValidSelector GTMAssertSelectorNilOrImplementedWithArgs
    #define GTMBridgeCookieStorage GTMCookieStorage
    #define GTMBridgeCleanedUserAgentString GTMCleanedUserAgentString
    #define GTMBridgeSystemVersionString GTMSystemVersionString
    #define GTMBridgeApplicationIdentifier GTMApplicationIdentifier
    #define kGTMBridgeFetcherStatusDomain kGTMHTTPFetcherStatusDomain
    #define kGTMBridgeFetcherStatusBadRequest kGTMHTTPFetcherStatusBadRequest
  #endif  // GTM_USE_SESSION_FETCHER
#endif

// Notifications
//
// fetch started and stopped, and fetch retry delay started and stopped
extern NSString *const kGTMSessionFetcherStartedNotification;
extern NSString *const kGTMSessionFetcherStoppedNotification;
extern NSString *const kGTMSessionFetcherRetryDelayStartedNotification;
extern NSString *const kGTMSessionFetcherRetryDelayStoppedNotification;

// callback constants
extern NSString *const kGTMSessionFetcherErrorDomain;
extern NSString *const kGTMSessionFetcherStatusDomain;
extern NSString *const kGTMSessionFetcherStatusDataKey;  // data returned with a kGTMSessionFetcherStatusDomain error

// Background session support requires access to NSUserDefaults.
// If [NSUserDefaults standardUserDefaults] doesn't yield the correct NSUserDefaults for your usage,
// ie for an App Extension, then implement this class/method to return the correct NSUserDefaults.
// https://developer.apple.com/library/ios/documentation/General/Conceptual/ExtensibilityPG/ExtensionScenarios.html#//apple_ref/doc/uid/TP40014214-CH21-SW6
@interface GTMSessionFetcherUserDefaultsFactory : NSObject

+ (NSUserDefaults *)fetcherUserDefaults;

@end

#ifdef __cplusplus
}
#endif

typedef NS_ENUM(NSInteger, GTMSessionFetcherErrorCode) {
  kGTMSessionFetcherErrorDownloadFailed = -1,
  kGTMSessionFetcherErrorUploadChunkUnavailable = -2,
  kGTMSessionFetcherErrorBackgroundExpiration = -3,
  kGTMSessionFetcherErrorBackgroundFetchFailed = -4,
  kGTMSessionFetcherErrorInsecureRequest = -5,

  // Standard http status codes.
  kGTMSessionFetcherStatusNotModified = 304,
  kGTMSessionFetcherStatusBadRequest = 400,
  kGTMSessionFetcherStatusUnauthorized = 401,
  kGTMSessionFetcherStatusForbidden = 403,
  kGTMSessionFetcherStatusPreconditionFailed = 412
};

#ifdef __cplusplus
extern "C" {
#endif

@class GTMSessionCookieStorage;
@class GTMSessionFetcher;

typedef void (^GTMSessionFetcherConfigurationBlock)(GTMSessionFetcher *fetcher,
                                                    NSURLSessionConfiguration *configuration);
typedef void (^GTMSessionFetcherSystemCompletionHandler)(void);
typedef void (^GTMSessionFetcherCompletionHandler)(NSData *data, NSError *error);
typedef void (^GTMSessionFetcherBodyStreamProviderResponse)(NSInputStream *bodyStream);
typedef void (^GTMSessionFetcherBodyStreamProvider)(GTMSessionFetcherBodyStreamProviderResponse response);
typedef void (^GTMSessionFetcherDidReceiveResponseDispositionBlock)(NSURLSessionResponseDisposition disposition);
typedef void (^GTMSessionFetcherDidReceiveResponseBlock)(NSURLResponse *response,
                                                         GTMSessionFetcherDidReceiveResponseDispositionBlock dispositionBlock);
typedef void (^GTMSessionFetcherWillRedirectResponse)(NSURLRequest *redirectedRequest);
typedef void (^GTMSessionFetcherWillRedirectBlock)(NSHTTPURLResponse *redirectResponse,
                                                   NSURLRequest *redirectRequest,
                                                   GTMSessionFetcherWillRedirectResponse response);
typedef void (^GTMSessionFetcherAccumulateDataBlock)(NSData *buffer);
typedef void (^GTMSessionFetcherReceivedProgressBlock)(int64_t bytesWritten,
                                                       int64_t totalBytesWritten);
typedef void (^GTMSessionFetcherDownloadProgressBlock)(int64_t bytesWritten,
                                                       int64_t totalBytesWritten,
                                                       int64_t totalBytesExpectedToWrite);
typedef void (^GTMSessionFetcherSendProgressBlock)(int64_t bytesSent,
                                                   int64_t totalBytesSent,
                                                   int64_t totalBytesExpectedToSend);
typedef void (^GTMSessionFetcherWillCacheURLResponseResponse)(NSCachedURLResponse *cachedResponse);
typedef void (^GTMSessionFetcherWillCacheURLResponseBlock)(NSCachedURLResponse *proposedResponse,
                                                           GTMSessionFetcherWillCacheURLResponseResponse responseBlock);
typedef void (^GTMSessionFetcherRetryResponse)(BOOL shouldRetry);
typedef void (^GTMSessionFetcherRetryBlock)(BOOL suggestedWillRetry, NSError *error,
                                            GTMSessionFetcherRetryResponse response);

typedef void (^GTMSessionFetcherTestResponse)(NSHTTPURLResponse *response,
                                              NSData *data,
                                              NSError *error);
typedef void (^GTMSessionFetcherTestBlock)(GTMSessionFetcher *fetcherToTest,
                                           GTMSessionFetcherTestResponse testResponse);

void GTMSessionFetcherAssertValidSelector(id obj, SEL sel, ...);

// Utility functions for applications self-identifying to servers via a
// user-agent header

// Make a proper app name without whitespace from the given string, removing
// whitespace and other characters that may be special parsed marks of
// the full user-agent string.
NSString *GTMFetcherCleanedUserAgentString(NSString *str);

// Make an identifier like "MacOSX/10.7.1" or "iPod_Touch/4.1 hw/iPod1_1"
NSString *GTMFetcherSystemVersionString(void);

// Make a generic name and version for the current application, like
// com.example.MyApp/1.2.3 relying on the bundle identifier and the
// CFBundleShortVersionString or CFBundleVersion.
//
// The bundle ID may be overridden as the base identifier string by
// adding to the bundle's Info.plist a "GTMUserAgentID" key.
//
// If no bundle ID or override is available, the process name preceded
// by "proc_" is used.
NSString *GTMFetcherApplicationIdentifier(NSBundle *bundle);

#ifdef __cplusplus
}  // extern "C"
#endif


#if !GTM_USE_SESSION_FETCHER
@protocol GTMHTTPFetcherServiceProtocol;
#endif

// This protocol allows abstract references to the fetcher service, primarily for
// fetchers (which may be compiled without the fetcher service class present.)
@protocol GTMSessionFetcherServiceProtocol <NSObject>
// This protocol allows us to call into the service without requiring
// GTMSessionFetcherService sources in this project

@property(strong) dispatch_queue_t callbackQueue;

- (BOOL)fetcherShouldBeginFetching:(GTMSessionFetcher *)fetcher;
- (void)fetcherDidStop:(GTMSessionFetcher *)fetcher;

- (GTMSessionFetcher *)fetcherWithRequest:(NSURLRequest *)request;
- (BOOL)isDelayingFetcher:(GTMSessionFetcher *)fetcher;

// Methods for compatibility with the old GTMHTTPFetcher.
@property(readonly, strong) NSOperationQueue *delegateQueue;

@end  // @protocol GTMSessionFetcherServiceProtocol

#ifndef GTM_FETCHER_AUTHORIZATION_PROTOCOL
#define GTM_FETCHER_AUTHORIZATION_PROTOCOL 1
@protocol GTMFetcherAuthorizationProtocol <NSObject>
@required
// This protocol allows us to call the authorizer without requiring its sources
// in this project.
- (void)authorizeRequest:(NSMutableURLRequest *)request
                delegate:(id)delegate
       didFinishSelector:(SEL)sel;

- (void)stopAuthorization;

- (void)stopAuthorizationForRequest:(NSURLRequest *)request;

- (BOOL)isAuthorizingRequest:(NSURLRequest *)request;

- (BOOL)isAuthorizedRequest:(NSURLRequest *)request;

@property(strong, readonly) NSString *userEmail;

@optional

// Indicate if authorization may be attempted. Even if this succeeds,
// authorization may fail if the user's permissions have been revoked.
@property(readonly) BOOL canAuthorize;

// For development only, allow authorization of non-SSL requests, allowing
// transmission of the bearer token unencrypted.
@property(assign) BOOL shouldAuthorizeAllRequests;

- (void)authorizeRequest:(NSMutableURLRequest *)request
       completionHandler:(void (^)(NSError *error))handler;

#if GTM_USE_SESSION_FETCHER
@property (weak) id<GTMSessionFetcherServiceProtocol> fetcherService;
#else
@property (weak) id<GTMHTTPFetcherServiceProtocol> fetcherService;
#endif

- (BOOL)primeForRefresh;

@end
#endif  // GTM_FETCHER_AUTHORIZATION_PROTOCOL

#pragma mark -

// GTMSessionFetcher objects are used for async retrieval of an http get or post
//
// See additional comments at the beginning of this file
@interface GTMSessionFetcher : NSObject <NSURLSessionDelegate>

// Create a fetcher
//
// fetcherWithRequest will return an autoreleased fetcher, but if
// the connection is successfully created, the connection should retain the
// fetcher for the life of the connection as well. So the caller doesn't have
// to retain the fetcher explicitly unless they want to be able to cancel it.
+ (instancetype)fetcherWithRequest:(NSURLRequest *)request;

// Convenience methods that make a request, like +fetcherWithRequest
+ (instancetype)fetcherWithURL:(NSURL *)requestURL;
+ (instancetype)fetcherWithURLString:(NSString *)requestURLString;

// Methods for creating fetchers to continue previous fetches.
+ (instancetype)fetcherWithDownloadResumeData:(NSData *)resumeData;
+ (instancetype)fetcherWithSessionIdentifier:(NSString *)sessionIdentifier;

// Returns an array of currently active fetchers for background sessions,
// both restarted and newly created ones.
+ (NSArray *)fetchersForBackgroundSessions;

// Designated initializer.
- (instancetype)initWithRequest:(NSURLRequest *)request
                  configuration:(NSURLSessionConfiguration *)configuration;

// The fetcher's request
//
// The underlying request is mutable and may be modified by the caller.  Request changes will not
// affect a fetch after it has begun.
@property(readonly) NSMutableURLRequest *mutableRequest;

// Data used for resuming a download task.
@property(strong) NSData *downloadResumeData;

// The configuration; this must be set before the fetch begins. If no configuration is
// set or inherited from the fetcher service, then the fetcher uses an ephemeral config.
@property(strong) NSURLSessionConfiguration *configuration;

// A block the client may use to customize the configuration used to create the session.
//
// This is called synchronously, either on the thread that begins the fetch or, during a retry,
// on the main thread. The configuration block may be called repeatedly if multiple fetchers are
// created.
@property(copy) GTMSessionFetcherConfigurationBlock configurationBlock;

// A session is created for each fetch.
@property(readonly) NSURLSession *session;

// The task in flight.
@property(readonly) NSURLSessionTask *sessionTask;

// The background session identifier.
@property(readonly) NSString *sessionIdentifier;

// Additional user-supplied data to encode into the session identifier. Since session identifier
// length limits are unspecified, this should be kept small. Key names beginning with an underscore
// are reserved for use by the fetcher.
@property(strong) NSDictionary *sessionUserInfo;

// The human-readable description to be assigned to the task.
@property(copy) NSString *taskDescription;

// The fetcher encodes information used to resume a session in the session identifier.
// This method, intended for internal use returns the encoded information.  The sessionUserInfo
// dictionary is stored as identifier metadata.
- (NSDictionary *)sessionIdentifierMetadata;

#if TARGET_OS_IPHONE
// The app should pass to this method the completion handler passed in the app delegate method
// application:handleEventsForBackgroundURLSession:completionHandler:
+ (void)application:(UIApplication *)application
    handleEventsForBackgroundURLSession:(NSString *)identifier
                      completionHandler:(GTMSessionFetcherSystemCompletionHandler)completionHandler;
#endif

// Indicate that a newly created session should be a background session.
// A new session identifier will be created by the fetcher.
@property(assign) BOOL useBackgroundSession;

// Indicates if uploads should use an upload task.  This is always set for file or stream-provider
// bodies, but may be set explicitly for NSData bodies.
@property(assign) BOOL useUploadTask;

// By default, the fetcher allows only secure (https) schemes unless this
// property is set, or the GTM_ALLOW_INSECURE_REQUESTS build flag is set.
//
// For example, during debugging when fetching from a development server that lacks SSL support,
// this may be set to @[ @"http" ], or when the fetcher is used to retrieve local files,
// this may be set to @[ @"file" ].
//
// This should be left as nil for release builds to avoid creating the opportunity for
// leaking private user behavior and data.  If a server is providing insecure URLs
// for fetching by the client app, report the problem as server security & privacy bug.
@property(copy) NSArray *allowedInsecureSchemes;

// By default, the fetcher prohibits localhost requests unless this property is set,
// or the GTM_ALLOW_INSECURE_REQUESTS build flag is set.
//
// For localhost requests, the URL scheme is not checked  when this property is set.
@property(assign) BOOL allowLocalhostRequest;

// By default, the fetcher requires valid server certs.  This may be bypassed
// temporarily for development against a test server with an invalid cert.
@property(assign) BOOL allowInvalidServerCertificates;

// Cookie storage object for this fetcher. If nil, the fetcher will use a static cookie
// storage instance shared among fetchers.  If this fetcher was created by a fetcher service
// object, it will be set to use the service object's cookie storage.  To have no cookies
// sent or saved by this fetcher, set this property to use a temporary storage object:
//   fetcher.cookieStorage = [[GTMSessionCookieStorage alloc] init];
//
// Because as of Jan 2014 standalone instances of NSHTTPCookieStorage do not actually
// store any cookies (Radar 15735276) we use our own subclass, GTMSessionCookieStorage,
// to hold cookies in memory.
@property(strong) NSHTTPCookieStorage *cookieStorage;

// Setting the credential is optional; it is used if the connection receives
// an authentication challenge.
@property(strong) NSURLCredential *credential;

// Setting the proxy credential is optional; it is used if the connection
// receives an authentication challenge from a proxy.
@property(strong) NSURLCredential *proxyCredential;

// If body data, body file URL, or body stream provider is not set, then a GET request
// method is assumed.
@property(strong) NSData *bodyData;

// File to use as the request body. This forces use of an upload task.
@property(strong) NSURL *bodyFileURL;

// Length of body to send, expected or actual.
@property(readonly) int64_t bodyLength;

// The body stream provider may be called repeatedly to provide a body.
// Setting a body stream provider forces use of an upload task.
@property(copy) GTMSessionFetcherBodyStreamProvider bodyStreamProvider;

// Object to add authorization to the request, if needed.
@property(strong) id<GTMFetcherAuthorizationProtocol> authorizer;

// The service object that created and monitors this fetcher, if any.
@property(strong) id<GTMSessionFetcherServiceProtocol> service;

// The host, if any, used to classify this fetcher in the fetcher service.
@property(copy) NSString *serviceHost;

// The priority, if any, used for starting fetchers in the fetcher service
//
// Lower values are higher priority; the default is 0, and values may
// be negative or positive. This priority affects only the start order of
// fetchers that are being delayed by a fetcher service.
@property(assign) NSInteger servicePriority;

// The delegate's optional didReceiveResponse block may be used to inspect or alter
// the session response.
//
// This is called on the callback queue.
@property(copy) GTMSessionFetcherDidReceiveResponseBlock didReceiveResponseBlock;

// The delegate's optional willRedirect block may be used to inspect or alter
// the redirection.
//
// This is called on the callback queue.
@property(copy) GTMSessionFetcherWillRedirectBlock willRedirectBlock;

// The optional send progress block reports body bytes uploaded.
//
// This is called on the callback queue.
@property(copy) GTMSessionFetcherSendProgressBlock sendProgressBlock;

// The optional accumulate block may be set by clients wishing to accumulate data
// themselves rather than let the fetcher append each buffer to an NSData.
//
// When this is called with nil data (such as on redirect) the client
// should empty its accumulation buffer.
//
// This is called on the callback queue.
@property(copy) GTMSessionFetcherAccumulateDataBlock accumulateDataBlock;

// The optional received progress block may be used to monitor data
// received from a data task.
//
// This is called on the callback queue.
@property(copy) GTMSessionFetcherReceivedProgressBlock receivedProgressBlock;

// The delegate's optional downloadProgress block may be used to monitor download
// progress in writing to disk.
//
// This is called on the callback queue.
@property(copy) GTMSessionFetcherDownloadProgressBlock downloadProgressBlock;

// The delegate's optional willCacheURLResponse block may be used to alter the cached
// NSURLResponse. The user may prevent caching by passing nil to the block's response.
//
// This is called on the callback queue.
@property(copy) GTMSessionFetcherWillCacheURLResponseBlock willCacheURLResponseBlock;

// Enable retrying; see comments at the top of this file.  Setting
// retryEnabled=YES resets the min and max retry intervals.
@property(assign, getter=isRetryEnabled) BOOL retryEnabled;

// Retry block is optional for retries.
//
// If present, this block should call the response block with YES to cause a retry or NO to end the
// fetch.
// See comments at the top of this file.
@property(copy) GTMSessionFetcherRetryBlock retryBlock;

// Retry intervals must be strictly less than maxRetryInterval, else
// they will be limited to maxRetryInterval and no further retries will
// be attempted.  Setting maxRetryInterval to 0.0 will reset it to the
// default value, 600 seconds.
@property(assign) NSTimeInterval maxRetryInterval;

// Starting retry interval.  Setting minRetryInterval to 0.0 will reset it
// to a random value between 1.0 and 2.0 seconds.  Clients should normally not
// set this except for unit testing.
@property(assign) NSTimeInterval minRetryInterval;

// Multiplier used to increase the interval between retries, typically 2.0.
// Clients should not need to set this.
@property(assign) double retryFactor;

// Number of retries attempted.
@property(readonly) NSUInteger retryCount;

// Interval delay to precede next retry.
@property(readonly) NSTimeInterval nextRetryInterval;

// Begin fetching the request
//
// The delegate may optionally implement the callback or pass nil for the selector or handler.
//
// The delegate and all callback blocks are retained between the beginFetch call until after the
// finish callback, or until the fetch is stopped.
//
// An error is passed to the callback for server statuses 300 or
// higher, with the status stored as the error object's code.
//
// finishedSEL has a signature like:
//   - (void)fetcher:(GTMSessionFetcher *)fetcher
//  finishedWithData:(NSData *)data
//             error:(NSError *)error;
//
// If the application has specified a destinationFileURL
// for the fetcher, the data parameter passed to the callback will be nil.

- (void)beginFetchWithDelegate:(id)delegate
             didFinishSelector:(SEL)finishedSEL;

- (void)beginFetchWithCompletionHandler:(GTMSessionFetcherCompletionHandler)handler;

// Returns YES if this fetcher is in the process of fetching a URL.
@property(readonly, getter=isFetching) BOOL fetching;

// Cancel the fetch of the request that's currently in progress.  The completion handler
// will not be called.
- (void)stopFetching;

// A block to be called when the fetch completes.
@property(copy) GTMSessionFetcherCompletionHandler completionHandler;

// A block to be called if download resume data becomes available.
@property(strong) void (^resumeDataBlock)(NSData *);

// Return the status code from the server response.
@property(readonly) NSInteger statusCode;

// Return the http headers from the response.
@property(strong, readonly) NSDictionary *responseHeaders;

// The response, once it's been received.
@property(strong, readonly) NSURLResponse *response;

// Bytes downloaded so far.
@property(readonly) int64_t downloadedLength;

// Buffer of currently-downloaded data, if available.
@property(readonly, strong) NSData *downloadedData;

// Local path to which the downloaded file will be moved.
//
// If a file already exists at the path, it will be overwritten.
@property(strong) NSURL *destinationFileURL;

// userData is retained solely for the convenience of the client.
@property(strong) id userData;

// Stored property values are retained solely for the convenience of the client.
@property(copy) NSDictionary *properties;

- (void)setProperty:(id)obj forKey:(NSString *)key;  // Pass nil for obj to remove the property.
- (id)propertyForKey:(NSString *)key;

- (void)addPropertiesFromDictionary:(NSDictionary *)dict;

// Comments are useful for logging, so are strongly recommended for each fetcher.
@property(copy) NSString *comment;

- (void)setCommentWithFormat:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);

// Log of request and response, if logging is enabled
@property(copy) NSString *log;

// Callbacks are run on this queue.  If none is supplied, the main queue is used.
@property(strong) dispatch_queue_t callbackQueue;

// Spin the run loop or sleep the thread, discarding events, until the fetch has completed.
//
// This is only for use in testing or in tools without a user interface.
//
// Note:  Synchronous fetches should never be used by shipping apps; they are
// sufficient reason for rejection from the app store.
//
// Returns NO if timed out.
- (BOOL)waitForCompletionWithTimeout:(NSTimeInterval)timeoutInSeconds;

// Test block is optional for testing.
//
// If present, this block will cause the fetcher to skip starting the session, and instead
// use the test block response values when calling the completion handler and delegate code.
//
// Test code can set this on the fetcher or on the fetcher service.  For testing libraries
// that use a fetcher without exposing either the fetcher or the fetcher service, the global
// method setGlobalTestBlock: will set the block for all fetchers that do not have a test
// block set.
//
// The test code can pass nil for all response parameters to indicate that the fetch
// should proceed.
@property(copy) GTMSessionFetcherTestBlock testBlock;

+ (void)setGlobalTestBlock:(GTMSessionFetcherTestBlock)block;

// Exposed for testing.
+ (GTMSessionCookieStorage *)staticCookieStorage;

#if STRIP_GTM_FETCH_LOGGING
// If logging is stripped, provide a stub for the main method
// for controlling logging.
+ (void)setLoggingEnabled:(BOOL)flag;

#else

// These methods let an application log specific body text, such as the text description of a binary
// request or response. The application should set the fetcher to defer response body logging until
// the response has been received and the log response body has been set by the app. For example:
//
//   fetcher.logRequestBody = [binaryObject stringDescription];
//   fetcher.deferResponseBodyLogging = YES;
//   [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
//      if (error == nil) {
//        fetcher.logResponseBody = [[[MyThing alloc] initWithData:data] stringDescription];
//      }
//      fetcher.deferResponseBodyLogging = NO;
//   }];

@property(copy) NSString *logRequestBody;
@property(assign) BOOL deferResponseBodyLogging;
@property(copy) NSString *logResponseBody;

// Internal logging support.
@property(readonly) NSData *loggedStreamData;
@property(assign) BOOL hasLoggedError;
@property(strong) NSURL *redirectedFromURL;
- (void)appendLoggedStreamData:(NSData *)dataToAdd;
- (void)clearLoggedStreamData;

#endif // STRIP_GTM_FETCH_LOGGING

@end

@interface GTMSessionFetcher (BackwardsCompatibilityOnly)
// Clients using GTMSessionFetcher should set the cookie storage explicitly themselves.
// This method is just for compatibility with the old GTMHTTPFetcher class.
- (void)setCookieStorageMethod:(NSInteger)method;
@end

// Until we can just instantiate NSHTTPCookieStorage for local use, we'll
// implement all the public methods ourselves.  This stores cookies only in
// memory.  Additional methods are provided for testing.
@interface GTMSessionCookieStorage : NSHTTPCookieStorage

// Add the array off cookies to the storage, replacing duplicates.
// Also removes expired cookies from the storage.
- (void)setCookies:(NSArray *)cookies;

- (void)removeAllCookies;

@end

