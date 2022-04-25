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
#import <GTMSessionFetcher/GTMSessionFetcherLogging.h>

@interface GTMSessionFetcherUtilityTest : XCTestCase
@end

@interface GTMSessionFetcher (GTMSessionFetcherLoggingInternal)
+ (NSString *)snipSubstringOfString:(NSString *)originalStr
                 betweenStartString:(NSString *)startStr
                          endString:(NSString *)endStr;
@end

@implementation GTMSessionFetcherUtilityTest

#if !STRIP_GTM_FETCH_LOGGING
- (void)testLogSnipping {
  // Enpty string.
  NSString *orig = @"";
  NSString *expected = orig;
  NSString *result = [GTMSessionFetcher snipSubstringOfString:orig
                                           betweenStartString:@"jkl"
                                                    endString:@"mno"];
  XCTAssertEqualObjects(result, expected, @"simple snip to end failure");

  // Snip the middle.
  orig = @"abcdefg";
  expected = @"abcd_snip_fg";
  result = [GTMSessionFetcher snipSubstringOfString:orig
                                 betweenStartString:@"abcd"
                                          endString:@"fg"];
  XCTAssertEqualObjects(result, expected, @"simple snip in the middle failure");

  // Snip to the end.
  orig = @"abcdefg";
  expected = @"abcd_snip_";
  result = [GTMSessionFetcher snipSubstringOfString:orig
                                 betweenStartString:@"abcd"
                                          endString:@"xyz"];
  XCTAssertEqualObjects(result, expected, @"simple snip to end failure");

  // Start string not found, so nothing should be snipped.
  orig = @"abcdefg";
  expected = orig;
  result = [GTMSessionFetcher snipSubstringOfString:orig
                                 betweenStartString:@"jkl"
                                          endString:@"mno"];
  XCTAssertEqualObjects(result, expected, @"simple snip to end failure");

  // Nothing between start and end.
  orig = @"abcdefg";
  expected = @"abcd_snip_efg";
  result = [GTMSessionFetcher snipSubstringOfString:orig
                                 betweenStartString:@"abcd"
                                          endString:@"efg"];
  XCTAssertEqualObjects(result, expected, @"snip of empty string failure");

  // Snip like in OAuth.
  orig = @"OAuth oauth_consumer_key=\"example.net\", "
          "oauth_token=\"1%2FpXi_-mBSegSbB-m9HprlwlxF6NF7IL7_9PDZok\", "
          "oauth_signature=\"blP%2BG72aSQ2XadLLTk%2BNzUV6Wes%3D\"";
  expected = @"OAuth oauth_consumer_key=\"example.net\", "
              "oauth_token=\"_snip_\", "
              "oauth_signature=\"blP%2BG72aSQ2XadLLTk%2BNzUV6Wes%3D\"";
  result = [GTMSessionFetcher snipSubstringOfString:orig
                                 betweenStartString:@"oauth_token=\""
                                          endString:@"\""];
  XCTAssertEqualObjects(result, expected, @"realistic snip failure");
}
#endif

- (void)testGTMFetcherCleanedUserAgentString {
  NSString *result = GTMFetcherCleanedUserAgentString(@"");
  NSString *expected = @"";
  XCTAssertEqualObjects(result, expected);

  result = GTMFetcherCleanedUserAgentString(@"frog in tree/[1.2.3]");
  expected = @"frog_in_tree1.2.3";
  XCTAssertEqualObjects(result, expected);

  result = GTMFetcherCleanedUserAgentString(@"\\iPod ({Touch])\n\r");
  expected = @"iPod_Touch";
  XCTAssertEqualObjects(result, expected);
}

- (void)testGTMDataFromInputStream {
  NSError *streamError;
  NSInputStream *inputStream;
  NSData *inputData, *result;

  // Test empty stream.
  inputData = [NSData data];
  inputStream = [NSInputStream inputStreamWithData:inputData];
  result = GTMDataFromInputStream(inputStream, &streamError);
  XCTAssertEqualObjects(result, inputData);
  XCTAssertNotEqual(result, inputData);  // Pointer comparison.
  XCTAssertNil(streamError);

  // Test small stream.
  inputData = [@"a" dataUsingEncoding:NSUTF8StringEncoding];
  inputStream = [NSInputStream inputStreamWithData:inputData];
  result = GTMDataFromInputStream(inputStream, &streamError);
  XCTAssertEqualObjects(result, inputData);
  XCTAssertNotEqual(result, inputData);  // Pointer comparison.
  XCTAssertNil(streamError);

  // Test big stream.
  inputData = [NSMutableData dataWithLength:50000];
  inputStream = [NSInputStream inputStreamWithData:inputData];
  result = GTMDataFromInputStream(inputStream, &streamError);
  XCTAssertEqualObjects(result, inputData);
  XCTAssertNotEqual(result, inputData);  // Pointer comparison.
  XCTAssertNil(streamError);

  // Test file stream.
  inputData = [NSMutableData dataWithLength:50000];
  NSURL *tempDirURL = [NSURL fileURLWithPath:NSTemporaryDirectory()];
  NSURL *tempFileURL = [tempDirURL URLByAppendingPathComponent:NSStringFromSelector(_cmd)
                                                   isDirectory:NO];
  NSError *fileError;
  XCTAssertTrue([inputData writeToURL:tempFileURL options:NSDataWritingAtomic error:&fileError],
                @"%@", fileError);

  inputStream = [NSInputStream inputStreamWithURL:tempFileURL];
  result = GTMDataFromInputStream(inputStream, &streamError);
  XCTAssertEqualObjects(result, inputData);
  XCTAssertNotEqual(result, inputData);
  XCTAssertNil(streamError);

  XCTAssertTrue([[NSFileManager defaultManager] removeItemAtURL:tempFileURL error:&fileError],
                @"%@", fileError);

  // Test invalid stream.
  inputStream = [NSInputStream inputStreamWithFileAtPath:@"/////"];
  XCTAssertNotNil(inputStream);
  result = GTMDataFromInputStream(inputStream, &streamError);
  XCTAssertNil(result);
  XCTAssertNotNil(streamError);
}
@end
