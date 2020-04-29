/* Copyright (c) 2014 Google Inc.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import <TargetConditionals.h>

#if TARGET_OS_IOS || TARGET_OS_MACCATALYST

#if !defined(__has_feature) || !__has_feature(objc_arc)
#error "This file requires ARC support."
#endif

#import "GTMSessionFetcherLogViewController.h"

#import <objc/runtime.h>

#import "GTMSessionFetcher.h"
#import "GTMSessionFetcherLogging.h"

#ifndef STRIP_GTM_FETCH_LOGGING
  #error GTMSessionFetcher headers should have defaulted this if it wasn't already defined.
#endif

#if !STRIP_GTM_FETCH_LOGGING && !STRIP_GTM_SESSIONLOGVIEWCONTROLLER

#if ((TARGET_OS_IOS && __IPHONE_OS_VERSION_MIN_REQUIRED >= __IPHONE_10_0) || \
     (TARGET_OS_OSX && __MAC_OS_X_VERSION_MIN_REQUIRED >= __MAC_10_12))
  // For apps targetting recent only versions of iOS/Mac, use WKWebView rather
  // than UIWebView/NSWebView.
  #define GTM_USE_WKWEBVIEW 1
  #import <WebKit/WebKit.h>
  typedef WKWebView GTMWebView;
#else
  #define GTM_USE_WKWEBVIEW 0
  typedef UIWebView GTMWebView;
#endif

static NSString *const kHTTPLogsCell = @"kGTMHTTPLogsCell";

// A minimal controller will be used to wrap a web view for displaying the
// log files.
@interface GTMSessionFetcherLoggingWebViewController : UIViewController
- (id)initWithURL:(NSURL *)htmlURL title:(NSString *)title opensScrolledToEnd:(BOOL)opensScrolled;
@end

#if GTM_USE_WKWEBVIEW
@interface GTMSessionFetcherLoggingWebViewController () <WKNavigationDelegate>
@end
#else
@interface GTMSessionFetcherLoggingWebViewController () <UIWebViewDelegate>
@end
#endif

#pragma mark - Table View Controller

@interface GTMSessionFetcherLogViewController ()
@property (nonatomic, copy) void (^callbackBlock)(void);
@end

@implementation GTMSessionFetcherLogViewController {
  NSMutableArray *logsFolderURLs_;
  BOOL opensScrolledToEnd_;
}

@synthesize callbackBlock = callbackBlock_;

- (instancetype)initWithStyle:(UITableViewStyle)style {
  self = [super initWithStyle:style];
  if (self) {
    self.title = @"HTTP Logs";

    // Find all folders containing logs.
    NSError *error;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *logsFolderPath = [GTMSessionFetcher loggingDirectory];
    NSString *processName = [GTMSessionFetcher loggingProcessName];

    NSURL *logsURL = [NSURL fileURLWithPath:logsFolderPath];
    NSMutableArray *mutableURLs =
        [[fm contentsOfDirectoryAtURL:logsURL
           includingPropertiesForKeys:@[ NSURLCreationDateKey ]
                              options:0
                                error:&error] mutableCopy];

    // Remove non-log files that lack the process name prefix,
    // and remove the "newest" symlink.
    NSString *symlinkSuffix = [GTMSessionFetcher symlinkNameSuffix];
    NSIndexSet *nonLogIndexes = [mutableURLs indexesOfObjectsPassingTest:
        ^BOOL(id obj, NSUInteger idx, BOOL *stop) {
      NSString *name = [obj lastPathComponent];
         return (![name hasPrefix:processName]
                 || [name hasSuffix:symlinkSuffix]);
    }];
    [mutableURLs removeObjectsAtIndexes:nonLogIndexes];

    // Sort to put the newest logs at the top of the list.
    [mutableURLs sortUsingComparator:^NSComparisonResult(NSURL *url1,
                                                         NSURL *url2) {
      NSDate *date1, *date2;
      [url1 getResourceValue:&date1 forKey:NSURLCreationDateKey error:NULL];
      [url2 getResourceValue:&date2 forKey:NSURLCreationDateKey error:NULL];
      return [date2 compare:date1];
    }];
    logsFolderURLs_ = mutableURLs;
  }
  return self;
}

- (void)viewDidLoad {
  [super viewDidLoad];

  // Avoid silent failure if this was not added to a UINavigationController.
  //
  // The method +controllerWithTarget:selector: can be used to create a
  // temporary UINavigationController.
  NSAssert(self.navigationController != nil, @"Need a UINavigationController");
}

- (void)setOpensScrolledToEnd:(BOOL)opensScrolledToEnd {
  opensScrolledToEnd_ = opensScrolledToEnd;
}

#pragma mark -

- (NSString *)shortenedNameForURL:(NSURL *)url {
  // Remove "Processname_log_" from the start of the file name.
  NSString *name = [url lastPathComponent];
  NSString *prefix = [GTMSessionFetcher processNameLogPrefix];
  if ([name hasPrefix:prefix]) {
    name = [name substringFromIndex:[prefix length]];
  }
  return name;
}

#pragma mark - Table view data source

- (NSInteger)tableView:(UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section {
  return (NSInteger)logsFolderURLs_.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  UITableViewCell *cell =
      [tableView dequeueReusableCellWithIdentifier:kHTTPLogsCell];
  if (cell == nil) {
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                  reuseIdentifier:kHTTPLogsCell];
    [cell.textLabel setAdjustsFontSizeToFitWidth:YES];
  }

  NSURL *url = logsFolderURLs_[(NSUInteger)indexPath.row];
  cell.textLabel.text = [self shortenedNameForURL:url];

  return cell;
}

#pragma mark - Table view delegate

- (void)tableView:(UITableView *)tableView
    didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  NSURL *folderURL = logsFolderURLs_[(NSUInteger)indexPath.row];
  NSString *htmlName = [GTMSessionFetcher htmlFileName];
  NSURL *htmlURL = [folderURL URLByAppendingPathComponent:htmlName isDirectory:NO];

  // Show the webview controller.
  NSString *title = [self shortenedNameForURL:folderURL];
  UIViewController *webViewController =
      [[GTMSessionFetcherLoggingWebViewController alloc] initWithURL:htmlURL
                                                               title:title
                                                  opensScrolledToEnd:opensScrolledToEnd_];

  UINavigationController *navController = [self navigationController];
  [navController pushViewController:webViewController animated:YES];

  [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

- (void)tableView:(UITableView *)tableView
    commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
     forRowAtIndexPath:(NSIndexPath *)indexPath {
  if (UITableViewCellEditingStyleDelete == editingStyle) {
    NSURL *folderURL = logsFolderURLs_[(NSUInteger)indexPath.row];
    if ([[NSFileManager defaultManager] removeItemAtURL:folderURL error:NULL]) {
      [logsFolderURLs_ removeObjectAtIndex:(NSUInteger)indexPath.row];
      [tableView deleteRowsAtIndexPaths:@[indexPath]
                       withRowAnimation:UITableViewRowAnimationAutomatic];
    }
  }
}

#pragma mark -

+ (UINavigationController *)controllerWithTarget:(id)target
                                        selector:(SEL)selector {
  UINavigationController *navController = [[UINavigationController alloc] init];
  GTMSessionFetcherLogViewController *logViewController =
      [[GTMSessionFetcherLogViewController alloc] init];
  UIBarButtonItem *barButtonItem =
      [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                    target:logViewController
                                                    action:@selector(doneButtonClicked:)];
  logViewController.navigationItem.leftBarButtonItem = barButtonItem;

  // Make a block to capture the callback and nav controller.
  void (^block)(void) = ^{
    if (target && selector) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
      [target performSelector:selector withObject:navController];
#pragma clang diagnostic pop
    }
  };
  logViewController.callbackBlock = block;

  navController.modalTransitionStyle = UIModalTransitionStyleFlipHorizontal;

  [navController pushViewController:logViewController animated:NO];
  return navController;
}

- (void)doneButtonClicked:(UIBarButtonItem *)barButtonItem {
  void (^block)() = self.callbackBlock;
  block();
  self.callbackBlock = nil;
}

@end

#pragma mark - Minimal WebView Controller

@implementation GTMSessionFetcherLoggingWebViewController {
  BOOL opensScrolledToEnd_;
  NSURL *htmlURL_;
}

- (instancetype)initWithURL:(NSURL *)htmlURL
                      title:(NSString *)title
         opensScrolledToEnd:(BOOL)opensScrolledToEnd {
  self = [super initWithNibName:nil bundle:nil];
  if (self) {
    self.title = title;
    htmlURL_ = htmlURL;
    opensScrolledToEnd_ = opensScrolledToEnd;
  }
  return self;
}

- (void)loadView {
  GTMWebView *webView = [[GTMWebView alloc] init];
  webView.autoresizingMask = (UIViewAutoresizingFlexibleWidth
                              | UIViewAutoresizingFlexibleHeight);
#if GTM_USE_WKWEBVIEW
  webView.navigationDelegate = self;
#else
  webView.delegate = self;
#endif
  self.view = webView;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  NSURLRequest *request = [NSURLRequest requestWithURL:htmlURL_];
  [[self webView] loadRequest:request];
}

- (void)didTapBackButton:(UIButton *)button {
  [[self webView] goBack];
}

- (GTMWebView *)webView {
  return (GTMWebView *)self.view;
}

- (void)didFinishLoadingHTML {
  if (opensScrolledToEnd_) {
    // Scroll to the bottom, because the most recent entry is at the end.
    NSString *javascript = [NSString stringWithFormat:@"window.scrollBy(0, %ld);", (long)NSIntegerMax];
#if GTM_USE_WKWEBVIEW
    [[self webView] evaluateJavaScript:javascript completionHandler:nil];
#else
    [[self webView] stringByEvaluatingJavaScriptFromString:javascript];
#endif
    opensScrolledToEnd_ = NO;
  }

  // Instead of the nav controller's back button, provide a simple
  // webview back button when it's needed.
  BOOL canGoBack = [[self webView] canGoBack];
  UIBarButtonItem *backItem = nil;
  if (canGoBack) {
    // This hides the nav back button.
    backItem = [[UIBarButtonItem alloc] initWithTitle:@"⏎"
                                                style:UIBarButtonItemStylePlain
                                               target:self
                                               action:@selector(didTapBackButton:)];
  }
  self.navigationItem.leftBarButtonItem = backItem;
}

#pragma mark - WebView delegate

#if GTM_USE_WKWEBVIEW
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
  [self didFinishLoadingHTML];
}
#else
- (void)webViewDidFinishLoad:(UIWebView *)webView {
  [self didFinishLoadingHTML];
}
#endif  // GTM_USE_WKWEBVIEW

@end

#endif  // !STRIP_GTM_FETCH_LOGGING && !STRIP_GTM_SESSIONLOGVIEWCONTROLLER

#endif  // TARGET_OS_IOS || TARGET_OS_MACCATALYST
