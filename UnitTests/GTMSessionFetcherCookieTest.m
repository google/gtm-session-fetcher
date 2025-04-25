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

#import <XCTest/XCTest.h>

#import <GTMSessionFetcher/GTMSessionFetcher.h>

static NSHTTPCookie *CookieWithProps(NSString *discard, NSString *domain, NSString *name,
                                     NSString *path, NSString *value) {
  NSDictionary *props = @{
    NSHTTPCookieDiscard : discard,
    NSHTTPCookieDomain : domain,
    NSHTTPCookieName : name,
    NSHTTPCookiePath : path,
    NSHTTPCookieValue : value
  };
  return [NSHTTPCookie cookieWithProperties:props];
}

@interface GTMSessionFetcherCookieTest : XCTestCase
@end

@implementation GTMSessionFetcherCookieTest

- (void)testCookieStorage {
  GTMSessionCookieStorage *cookieStorage = [[GTMSessionCookieStorage alloc] init];

  NSURL *fullURL = [NSURL URLWithString:@"http://photos.example.com"];
  NSURL *subdomainURL = [NSURL URLWithString:@"http://frogbreath.example.com"];

  NSArray *foundCookies = [cookieStorage cookiesForURL:fullURL];
  XCTAssertEqual(foundCookies.count, (NSUInteger)0);

  // Make two unique cookies
  NSHTTPCookie *testCookie1 =
      CookieWithProps(@"TRUE", @"photos.example.com", @"Snark", @"/", @"cook1=foo");

  NSHTTPCookie *testCookie2 =
      CookieWithProps(@"FALSE", @".example.com", @"Trump", @"/", @"cook2=gnu");

  // Make a cookie that would replace cookie 2, and make this one expire.
  NSDictionary *cookie2aProps = @{
    NSHTTPCookieVersion : @"1",
    NSHTTPCookieDomain : @".example.com",
    NSHTTPCookieName : @"Trump",
    NSHTTPCookiePath : @"/",
    NSHTTPCookieValue : @"cook2=snu",
    NSHTTPCookieMaximumAge : @"2"  // expire in 2 seconds
  };
  NSHTTPCookie *testCookie2a = [NSHTTPCookie cookieWithProperties:cookie2aProps];

  // Store the first two cookies.
  [cookieStorage setCookies:@[ testCookie1, testCookie2 ]];

  foundCookies = [cookieStorage cookiesForURL:fullURL];
  XCTAssertEqual(foundCookies.count, (NSUInteger)2);

  foundCookies = [cookieStorage cookiesForURL:subdomainURL];
  XCTAssertEqual(foundCookies.count, (NSUInteger)1);

  // Store expiring cookie 2a, replacing cookie 2.
  [cookieStorage setCookies:@[ testCookie2a ]];

  foundCookies = [cookieStorage cookiesForURL:subdomainURL];
  XCTAssertEqual(foundCookies.count, (NSUInteger)1);

  NSHTTPCookie *foundCookie = foundCookies.firstObject;
  XCTAssertEqualObjects([foundCookie value], [testCookie2a value]);

  // Wait for cookie 2a to expire, then remove expired cookies.
  [NSThread sleepForTimeInterval:3.0];
  [cookieStorage setCookies:nil];  // no-op but invokes removeExpiredCookies

  foundCookies = [cookieStorage cookiesForURL:subdomainURL];
  XCTAssertEqual(foundCookies.count, (NSUInteger)0);

  foundCookies = [cookieStorage cookiesForURL:fullURL];
  XCTAssertEqual(foundCookies.count, (NSUInteger)1);

  // Remove all cookies.
  [cookieStorage removeAllCookies];
  foundCookies = [cookieStorage cookiesForURL:fullURL];
  XCTAssertEqual(foundCookies.count, (NSUInteger)0);
}

- (void)testStrictCookieDomain {
  GTMSessionCookieStorage *cookieStorage = [[GTMSessionCookieStorage alloc] init];

  NSHTTPCookie *testCookie1a =
      CookieWithProps(@"TRUE", @"example.com", @"example1a", @"/", @"cook1=foo");
  NSHTTPCookie *testCookie1b =
      CookieWithProps(@"TRUE", @"example.com", @"example1b", @"/", @"cook2=who");
  NSHTTPCookie *testCookie1c =
      CookieWithProps(@"TRUE", @"morg.example.com", @"example1c", @"/", @"zum=oop");
  NSHTTPCookie *testCookie1d =
      CookieWithProps(@"TRUE", @"nurm.example.com", @"example1d", @"/", @"zum4=nar");

  NSHTTPCookie *testCookie2 =
      CookieWithProps(@"TRUE", @"myexample.com", @"myexample", @"/", @"cook5=gnu");

  [cookieStorage
      setCookies:@[ testCookie1a, testCookie1b, testCookie1c, testCookie1d, testCookie2 ]];

  // example.com retrieves the first two
  NSURL *subdomainURL = [NSURL URLWithString:@"http://example.com"];
  NSArray *foundCookies = [cookieStorage cookiesForURL:subdomainURL];
  NSArray *foundNames = [foundCookies valueForKey:@"name"];
  NSArray *expectedNames = @[ @"example1a", @"example1b" ];
  XCTAssertEqualObjects(foundNames, expectedNames);

  // morg.example.com retrieves the first three
  subdomainURL = [NSURL URLWithString:@"http://morg.example.com"];
  foundCookies = [cookieStorage cookiesForURL:subdomainURL];
  foundNames = [foundCookies valueForKey:@"name"];
  expectedNames = @[ @"example1a", @"example1b", @"example1c" ];
  XCTAssertEqualObjects(foundNames, expectedNames);

  // frap.example.com retrieves the first two
  subdomainURL = [NSURL URLWithString:@"http://frap.example.com"];
  foundCookies = [cookieStorage cookiesForURL:subdomainURL];
  foundNames = [foundCookies valueForKey:@"name"];
  expectedNames = @[ @"example1a", @"example1b" ];
  XCTAssertEqualObjects(foundNames, expectedNames);

  // myexample.com retrieves its own but not example.com's
  subdomainURL = [NSURL URLWithString:@"http://myexample.com"];
  foundCookies = [cookieStorage cookiesForURL:subdomainURL];
  foundNames = [foundCookies valueForKey:@"name"];
  expectedNames = @[ @"myexample" ];
  XCTAssertEqualObjects(foundNames, expectedNames);
}

@end
