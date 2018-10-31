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

#import <XCTest/XCTest.h>

#import <objc/runtime.h>

#import "GTMSessionFetcher.h"
#import "GTMSessionFetcherService.h"


@interface UrlSessionDelegateMock : NSObject<NSURLSessionDelegate, NSURLSessionTaskDelegate>

// I'm totally dumb object, not like some trust kit or so... just an air in the nsobject ballon

@property (nonatomic, nullable) XCTestExpectation *swizzledMethodsDidCallExpectation;

+ (instancetype)sharedObject;
+ (NSURLSession *)sessionWithConfiguration:(NSURLSessionConfiguration *)configuration delegate:(nullable id <NSURLSessionDelegate>)delegate delegateQueue:(nullable NSOperationQueue *)queue;

@end

@implementation UrlSessionDelegateMock

@synthesize swizzledMethodsDidCallExpectation = _swizzledMethodDidCall;

+ (instancetype)sharedObject
{
    static dispatch_once_t onceToken;
    static UrlSessionDelegateMock *object;
    dispatch_once(&onceToken, ^{
        object = [UrlSessionDelegateMock new];
    });
    
    return object;
}


+ (NSURLSession *)sessionWithConfiguration:(NSURLSessionConfiguration *)configuration delegate:(nullable id <NSURLSessionDelegate>)delegate delegateQueue:(nullable NSOperationQueue *)queue
{
    // THUS WE CALLING TO THE ORIGINAL's METHOD
    
    UrlSessionDelegateMock *sessionDelegateMonster = UrlSessionDelegateMock.sharedObject;
    
    [sessionDelegateMonster.swizzledMethodsDidCallExpectation fulfill];
    
    return [UrlSessionDelegateMock sessionWithConfiguration:configuration delegate:sessionDelegateMonster delegateQueue:queue];
}

@end



@interface GTMSessionFetcherURLSessionDelegateSwapTest : XCTestCase<NSURLSessionDelegate>
@property (nonatomic) GTMSessionFetcherService *fetcherService;

@end

@implementation GTMSessionFetcherURLSessionDelegateSwapTest {
    Method originalMethod;
    Method swizzledMethod;
}

@synthesize fetcherService = _fetcherService;

- (void)setUp
{
    [super setUp];
    
    _fetcherService = [[GTMSessionFetcherService alloc] init];
    
    
    /// SWIZZLE THINGz

    SEL selector = @selector(sessionWithConfiguration:delegate:delegateQueue:);

    originalMethod = class_getClassMethod(NSURLSession.class, selector);
    swizzledMethod = class_getClassMethod(UrlSessionDelegateMock.class, selector);
    
    XCTAssert(originalMethod);
    XCTAssert(swizzledMethod);
    
    method_exchangeImplementations(originalMethod, swizzledMethod);
}

- (void)tearDown
{
    // UNSWIZZLE THAT SH
    method_exchangeImplementations(originalMethod, swizzledMethod);
}

- (void)testUrlSessionWithDelegate
{
    
    // OK, I'm with swizzling error, and this part might need some improvements... anyway...
    
    GTMSessionFetcher *fetcher = [_fetcherService fetcherWithURLString:@"https://google.com"];
    
    XCTestExpectation *swizzleDidActuallyHappenExpectaion = [self expectationWithDescription:@"swizzle expected"];
    
    UrlSessionDelegateMock.sharedObject.swizzledMethodsDidCallExpectation = swizzleDidActuallyHappenExpectaion;
    
    [fetcher beginFetchWithCompletionHandler:^(NSData * _Nullable data, NSError * _Nullable error) {
        NSLog(@"¯\\_(ツ)_/¯ can you help with that please?");
    }];
    
    [self waitForExpectations:@[swizzleDidActuallyHappenExpectaion] timeout:1];
    
    [fetcher stopFetching];
}

@end
