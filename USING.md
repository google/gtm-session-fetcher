# Introduction

The Google Toolbox for Mac Session Fetcher is a set of classes to simplify HTTP operations in iOS and macOS applications. It provides a wrapper around NSURLSession for performing typical network fetches.

## When would you use the fetcher?

- When you just want a result from one or more requests without writing much networking code
- When you want the "standard" behavior for connections, such as redirection handling
- When you want automatic retry on failures
- When you want to make many requests of a host, but avoid overwhelming the host with simultaneous requests
- When you want a convenient log of HTTP requests and responses
- When you need to set a credential for the HTTP operation
- When you want to support a synchronous or asynchronous authorization of requests, such as for OAuth 2

# Using the Fetcher

## Adding the Fetcher to Your Project

Only the `GTMSessionFetcher.h/m` source files are strictly required, though using the Service class is highly recommended. If your application will make multiple fetches, the Service class will improve performance and provide added convenience methods and properties. The Logging class file is optional but useful for all applications.

| **Source files** | **Purpose** |
| ---------------- | ----------- |
| GTMSessionFetcher.h/m | required |
| GTMSessionFetcherLogging.h/m | HTTP logging (often helpful) |
| GTMSessionFetcherService.h/m | coordination across fetches, better performance |
| GTMMIMEDocument.h/m, GTMGatherInputStream.h/m | multipart MIME uploads and downloads |
| GTMSessionUploadFetcher.h/m | [resumable-uploads](https://developers.google.com/gdata/docs/resumable_upload) |

### ARC Compatibility

The fetcher source files can be compiled directly into a project that has ARC enabled. If the project doesn't have ARC enabled, it will need to be enabled for these files.

## Usage

### Fetching a Request

Because the fetcher is implemented as a wrapper on NSURLSession, it is inherently asynchronous. Starting a fetch will never block the current thread, and the callback will always be executed on the callback queue, which by default is the main queue.

The fetcher can be used most simply by adding the fetcher and fetcher service class files to your project, and fetching a URL like this:

```Objective-C
#import "GTMSessionFetcher.h"
#import "GTMSessionFetcherService.h"

_fetcherService = [[GTMSessionFetcherService alloc] init];

GTMSessionFetcher *myFetcher = [_fetcherService fetcherWithURLString:myURLString];
myFetcher.retryEnabled = YES;
myFetcher.comment = @"First profile image";

// Optionally specify a file URL or NSData for the request body to upload.
myFetcher.bodyData = [postString dataUsingEncoding:NSUTF8StringEncoding];

[myFetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
  if (error != nil) {
    // Server status code or network error.
    //
    // If the domain is kGTMSessionFetcherStatusDomain then the error code
    // is a failure status from the server.
  } else {
    // Fetch succeeded.
  }
}];
```

Each fetcher object is good for "one shot" usage; do not reuse an instance for a second fetch. The fetcher retains itself implicitly as long as a connection is pending.

Upload data may be optionally specified with one of the fetcher's `bodyData`, `bodyFileURL`, or `bodyStreamProvider` properties. A download destination may be optionally specified via one of the `destinationFileURL` or `accumulateDataBlock` properties.

### Background Fetches in iOS Applications

On iOS, the fetcher will maintain a UIBackgroundTask between start and completion of a fetch. Extensions can disable this by building with the `GTM_BACKGROUND_TASK_FETCHING` flag or by setting the fetcher's `skipBackgroundTask` property.

### Cookies

The fetcher can store HTTP cookies globally, segregated by fetcher service object, or discard them after the fetch. See the discussion under "Cookies" in `GTMSessionFetcher.h`.

### Monitoring Progress

The fetcher provides multiple progress monitoring block properties: `sendProgressBlock`, `receivedProgressBlock`, and `downloadProgressBlock`. See the discussion under "Monitoring data transfers" in `GTMSessionFetcher.h`.

### Notifications for the Network Activity Indicator

The fetcher posts notifications `kGTMSessionFetcherStartedNotification` and `kGTMSessionFetcherStoppedNotification` to indicate when its network activity has started and stopped. A started notification is always balanced by a single stopped notification from the same fetcher instance. Your application can observe those notifications in its code to start and stop the network activity indicator.

When the fetcher is paused between retry attempts, it posts `kGTMSessionFetcherRetryDelayStartedNotification` and `kGTMSessionFetcherRetryDelayStoppedNotification` notifications. The retry delay periods are between network activity, not during it.

### Proxies

Proxy handling is invisible so long as the system has a valid credential in the keychain, which is normally true (else most NSURL-based apps would encounter proxy errors).

But when there is a proxy authetication error, the the fetcher will invoke the callback method with the NSURLChallenge in the error's userInfo. The error method can get the challenge info like this:

```Objective-C
NSURLAuthenticationChallenge *challenge = [error.userInfo objectForKey:kGTMSessionFetcherErrorChallengeKey];
BOOL isProxyChallenge = challenge.protectionSpace.isProxy;
```

If a proxy error occurs, you can ask the user for the proxy username/password and call the next fetcher's setProxyCredential: to provide the credentials for the next attempt to fetch.

### Automatic Retry

The fetcher can optionally create a timer and reattempt certain kinds of fetch failures (status codes 408, request timeout; 502, gateway failure; 503, service unavailable; 504, gateway timeout; networking errors NSURLErrorTimedOut and NSURLErrorNetworkConnectionLost.) The user may set the fetcher's retry block to customize the errors which will be retried.

Retries are done in an exponential-backoff fashion (that is, after 1 second, 2, 4, 8, and so on, with a bit of randomness added to the initial interval.)

Enabling automatic retries looks like this:

```Objective-C
myFetcher.retryEnabled = YES;
```

With retries enabled, the success or failure callbacks are invoked only when no more retries will be attempted. Calling the fetcher's `stopFetching` method will terminate the retry timer, without the finished or failure selectors being invoked.

Optionally, the client may set the maximum retry interval:

```Objective-C
myFetcher.maxRetryInterval = 60.0; // in seconds; default is 60 seconds
                                   // for downloads, 600 for uploads
```

Also optionally, the client may provide a callback block to determine if a status code or other error should be retried.

```Objective-C
myFetcher.retryBlock = ^(BOOL suggestedWillRetry, NSError *error,
                         GTMSessionFetcherRetryResponse response) {
  // Perhaps examine error.domain and error.code, fetcher.request, or fetcher.retryCount
  //
  // Respond with YES to start the retry timer, NO to proceed to the failure
  // callback, or suggestedWillRetry to get default behavior for the
  // current error domain and code values.
  response(suggestedWillRetry);
};
```

Server status codes are present in the error argument, and have the domain kGTMSessionFetcherStatusDomain.

### Creating and Parsing Multipart MIME Documents

The library includes a class for efficiently generating and parsing multipart MIME documents. This is documented in `GTMMIMEDocument.h`.

### Per-Host Throttling

The fetcher service limits the number of running fetchers making requests from the same host. If more than the limit is reached, additional requests to that host are deferred until existing fetches complete. By default, the number of running fetchers is 10, but it may be adjusted by setting the fetcher service's `maxRunningFetchersPerHost` property. Setting the property to zero allows an unlimited number of running fetchers per host.

### Stopping Fetchers

All fetchers issues by a fetcher service instance may be stopped immediately with the service object's `-stopAllFetchers` method.

### Fetching With Background Sessions

For rare downloads or uploads of huge files on iOS, the fetcher can use NSURLSession's background sessions. See the description of the fetcher's `useBackgroundSession` property for additional details.

## HTTP Logging

All traffic using GTMSessionFetcher can be easily logged. Call

```Objective-C
[GTMSessionFetcher setLoggingEnabled:YES];
```

to begin generating log files. The project building the fetcher class must also include `GTMSessionFetcherLogging.h` and `.m`.

### Finding the Log Files

For macOS applications, log files are put into a folder on the desktop called `GTMHTTPDebugLogs`.

In the iOS simulator, the default logs location is the project derived data directory in ~/Library/Application Support. On the device, the default logs location is the application's documents directory on the device.

**Tip**: Search the Xcode console for the message **GTMSessionFetcher logging to** followed by the path of the logs folder. Copy the path, including the quote marks, and open it from the Mac’s terminal window, like

```
open "/Users/username/Library/Application Support/iPhone Simulator/6.1/Applications/C2D1B09D-2BF7-4FC9-B4F6-BDB617DE76D5/GTMSessionDebugLogs"
```

**Tip**: Use the Finder's "Sort By Date" to find the most recent logs.

Each run of an application generates a separate log. For each run, an html file is created to simplify browsing the run's HTTP requests and responses.

To view the most recently saved logs, use a web browser to open the symlink named MyAppName\_log\_newest.html (for whatever your application's name is) in the logging directory.

**Tip**: Set the fetcher's `comment` property or call `setCommentWithFormat:` before beginning a fetch to assign a short description for the request's log entry. These brief comment strings make it easier to browse the fetcher's HTTP logs.

Each request's log is also available via the fetcher `log` property when the fetcher completes; this makes viewing a fetcher's log convenient during debugging.

**iOS Tip**: The library includes an iOS view controller, `GTMSessionFetcherLogViewController`, for browsing the HTTP logs on the device.

**iOS Note**: Logging support is stripped out in non-DEBUG builds on iOS by default. This can be overridden by defining DEBUG=1 for the project, or by explicitly defining `STRIP_GTM_FETCH_LOGGING=0` for the project.

# Questions and Comments

Additional documentation is available in the header files.

If you have any questions or comments about the library or this documentation, please join the [discussion group](https://groups.google.com/group/google-toolbox-for-mac).
