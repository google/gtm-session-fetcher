# Google Toolbox for Mac - Session Fetcher

**Project site** <https://github.com/google/gtm-session-fetcher><br>
**Discussion group** <http://groups.google.com/group/google-toolbox-for-mac>

[![Build Status](https://github.com/google/gtm-session-fetcher/actions/workflows/main.yml/badge.svg?branch=main)](https://github.com/google/gtm-session-fetcher/actions/workflows/main.yml)

`GTMSessionFetcher` makes it easy for Cocoa applications to perform http
operations. The fetcher is implemented as a wrapper on `NSURLSession`, so its
behavior is asynchronous and uses operating-system settings.

Features include:
- Simple to build; only one source/header file pair is required
- Simple to use: takes just two lines of code to fetch a request
- Supports upload and download sessions
- Flexible cookie storage
- Automatic retry on errors, with exponential backoff
- Support for generating multipart MIME upload streams
- Easy, convenient logging of http requests and responses
- Supports plug-in authentication such as with GTMAppAuth
- Easily testable; self-mocking
- Automatic rate limiting when created by the `GTMSessionFetcherService` factory class
- Fully independent of other projects

## Development of this Project

You can use CocoaPods or Swift Package Manager.

### Swift Package Manager

* `open Package.swift` or double click `Package.swift` in Finder.
* Xcode will open the project
  * The _GTMSessionFetcher-Package_ scheme seems generally the simplest to build
    everything and run tests.
  * Choose a target platform by selecting the run destination along with the scheme

Note: As of Swift 5.3, testing with SwiftPM has some hacks in the sources to
compile in required resources, tracking the issues:
- https://forums.swift.org/t/5-3-resources-support-not-working-on-with-swift-test/40381
- https://bugs.swift.org/browse/SR-13560

### CocoaPods

Install
  * CocoaPods 1.10.0 (or later)
  * [CocoaPods generate](https://github.com/square/cocoapods-generate) - This is
    not part of the _core_ cocoapods install.

Generate an Xcode project from the podspec:

```
pod gen GTMSessionFetcher.podspec --local-sources=./ --auto-open --platforms=ios
```

Note: Set the `--platforms` option to `macos`, `tvos`, or `watchos` to
develop/test for those platforms.
