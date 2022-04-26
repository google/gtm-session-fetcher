// Copyright 2022 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.


#import "GTMSessionFetcher/GTMSessionFetcher.h"
#import "GTMSessionFetcher/GTMSessionUploadFetcher.h"
#import "GTMSessionFetcher/GTMSessionFetcherLogging.h"
#import "GTMSessionFetcher/GTMSessionFetcherService.h"
#import "GTMSessionFetcher/GTMMIMEDocument.h"
#import "GTMSessionFetcher/GTMGatherInputStream.h"
#import "GTMSessionFetcher/GTMReadMonitorInputStream.h"
#import "GTMSessionFetcher/GTMSessionFetcherLogViewController.h"

#import <GTMSessionFetcher/GTMSessionFetcher.h>
#import <GTMSessionFetcher/GTMSessionUploadFetcher.h>
#import <GTMSessionFetcher/GTMSessionFetcherLogging.h>
#import <GTMSessionFetcher/GTMSessionFetcherService.h>
#import <GTMSessionFetcher/GTMMIMEDocument.h>
#import <GTMSessionFetcher/GTMGatherInputStream.h>
#import <GTMSessionFetcher/GTMReadMonitorInputStream.h>
#import <GTMSessionFetcher/GTMSessionFetcherLogViewController.h>

#import <XCTest/XCTest.h>

@interface HeadersImportTest : XCTestCase
@end

@implementation HeadersImportTest

- (void)testImports {
  XCTAssertTrue(YES);
}

@end
