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

#import "GTMMIMEDocument.h"

// /Developer/Tools/otest LighthouseAPITest.octest

@interface GTMMIMEDocumentTest : XCTestCase
@end

@implementation GTMMIMEDocumentTest

- (void)doReadTestForInputStream:(NSInputStream *)inputStream
                  expectedString:(NSString *)expectedResultString
                      testMethod:(SEL)callingMethod {
  // This routine, called by the later test methods,
  // reads the data from the input stream and verifies that it matches the expected string.

  NSInteger expectedLength = [expectedResultString length];

  // now read the document from the input stream
  unsigned char buffer[9999];
  memset(buffer, 0, sizeof(buffer));

  [inputStream open];
  NSInteger bytesRead = [inputStream read:buffer maxLength:sizeof(buffer)];
  [inputStream close];

  NSString *readString = @((const char *)buffer);

  XCTAssertEqual(bytesRead, expectedLength, @"bad read length (%@)",
                 NSStringFromSelector(callingMethod));
  XCTAssertEqualObjects(readString, expectedResultString, @"bad read (%@)",
                        NSStringFromSelector(callingMethod));
}

- (void)testEmptyDoc {
  GTMMIMEDocument *doc = [GTMMIMEDocument MIMEDocument];

  NSInputStream *stream = nil;
  NSString *boundary = nil;
  unsigned long long length = -1;

  // generate the boundary and the input stream
  [doc generateInputStream:&stream
                    length:&length
                  boundary:&boundary];

  XCTAssertEqualObjects(boundary, @"END_OF_PART", @"bad boundary");

  NSString *expectedString = @"\r\n--END_OF_PART--\r\n";
  NSUInteger expectedLength = [expectedString length];

  XCTAssertEqual((NSUInteger)length, expectedLength,
                 @"Reported document length should be expected length.");

  [self doReadTestForInputStream:stream
                  expectedString:expectedString
                      testMethod:_cmd];
}

- (void)testSinglePartDoc {
  GTMMIMEDocument *doc = [GTMMIMEDocument MIMEDocument];

  NSDictionary *h1 = @{@"hfoo": @"bar", @"hfaz" : @"baz"};
  NSData *b1 = [@"Hi mom" dataUsingEncoding:NSUTF8StringEncoding];
  [doc addPartWithHeaders:h1 body:b1];

  // Generate the boundary and the input stream.
  NSInputStream *stream = nil;
  NSString *boundary = nil;
  unsigned long long length = -1;

  [doc generateInputStream:&stream
                    length:&length
                  boundary:&boundary];

  NSString* expectedResultString = [NSString stringWithFormat:
                                    @"\r\n--%@\r\n"
                                    "hfaz: baz\r\n"
                                    "hfoo: bar\r\n"
                                    "\r\n"    // Newline after headers.
                                    "Hi mom"
                                    "\r\n--%@--\r\n", boundary, boundary];

  XCTAssertEqualObjects(boundary, @"END_OF_PART", @"bad boundary");

  NSUInteger expectedLength = [expectedResultString length];

  XCTAssertEqual((NSUInteger)length, expectedLength,
                 @"Reported document length should be expected length.");

  // Now read the document from the input stream.

  [self doReadTestForInputStream:stream
                  expectedString:expectedResultString
                      testMethod:_cmd];

}


- (void)testMultiPartDoc {
  GTMMIMEDocument *doc = [GTMMIMEDocument MIMEDocument];

  NSDictionary *h1 = @{@"hfoo": @"bar", @"hfaz" : @"baz"};
  NSData *b1 = [@"Hi mom" dataUsingEncoding:NSUTF8StringEncoding];

  NSDictionary *h2 = [NSDictionary dictionary];
  NSData *b2 = [@"Hi dad" dataUsingEncoding:NSUTF8StringEncoding];

  NSDictionary *h3 = @{@"Content-Type": @"text/html", @"Content-Disposition": @"angry"};
  NSData* b3 = [@"Hi brother" dataUsingEncoding:NSUTF8StringEncoding];

  [doc addPartWithHeaders:h1 body:b1];
  [doc addPartWithHeaders:h2 body:b2];
  [doc addPartWithHeaders:h3 body:b3];

  // generate the boundary and the input stream
  NSInputStream *stream = nil;
  NSString *boundary = nil;
  unsigned long long length = -1;

  [doc generateInputStream:&stream
                    length:&length
                  boundary:&boundary];

  NSString* expectedResultString = [NSString stringWithFormat:
    @"\r\n--%@\r\n"
    "hfaz: baz\r\n"
    "hfoo: bar\r\n"
    "\r\n"    // Newline after headers.
    "Hi mom"
    "\r\n--%@\r\n"
    "\r\n"    // No header here, but still need the newline.
    "Hi dad"
    "\r\n--%@\r\n"
    "Content-Disposition: angry\r\n"
    "Content-Type: text/html\r\n"
    "\r\n"    // Newline after headers.
    "Hi brother"
    "\r\n--%@--\r\n",
    boundary, boundary, boundary, boundary];

  // Now read the document from the input stream.
  [self doReadTestForInputStream:stream
                  expectedString:expectedResultString
                      testMethod:_cmd];
}

- (void)testExplicitBoundary {
  GTMMIMEDocument *doc = [GTMMIMEDocument MIMEDocument];

  NSDictionary *h1 = @{@"hfoo": @"bar", @"hfaz" : @"baz"};
  NSData *b1 = [@"Hi mom" dataUsingEncoding:NSUTF8StringEncoding];

  NSDictionary *h2 = [NSDictionary dictionary];
  NSData *b2 = [@"Hi dad" dataUsingEncoding:NSUTF8StringEncoding];

  [doc addPartWithHeaders:h1 body:b1];
  [doc addPartWithHeaders:h2 body:b2];

  NSString *birdy = @"Look at that magic bird!";
  doc.boundary = birdy;

  // generate the boundary and the input stream
  NSInputStream *stream = nil;
  NSString *boundary = nil;
  unsigned long long length = -1;

  [doc generateInputStream:&stream
                    length:&length
                  boundary:&boundary];

  NSString* expectedResultString = [NSString stringWithFormat:
                                    @"\r\n--%@\r\n"
                                    "hfaz: baz\r\n"
                                    "hfoo: bar\r\n"
                                    "\r\n"    // Newline after headers.
                                    "Hi mom"
                                    "\r\n--%@\r\n"
                                    "\r\n"    // No header here, but still need the newline.
                                    "Hi dad"
                                    "\r\n--%@--\r\n",
                                    birdy, birdy, birdy];
  
  // Now read the document from the input stream.
  [self doReadTestForInputStream:stream
                  expectedString:expectedResultString
                      testMethod:_cmd];
}

- (void)testBoundaryConflict {
  GTMMIMEDocument *doc = [GTMMIMEDocument MIMEDocument];

  // We'll insert the text END_OF_PART_6b8b4567 which conflicts with
  // both the normal boundary ("END_OF_PART") and the first alternate
  // guess (given a random seed of 1, done below).

  NSDictionary *h1 = @{@"hfoo": @"bar", @"hfaz" : @"baz"};
  NSData *b1 = [@"Hi mom END_OF_PART" dataUsingEncoding:NSUTF8StringEncoding];

  NSDictionary *h2 = [NSDictionary dictionary];
  NSData *b2 = [@"Hi dad" dataUsingEncoding:NSUTF8StringEncoding];

  NSDictionary *h3 = @{@"Content-Type": @"text/html", @"Content-Disposition": @"angry"};
  NSData *b3 = [@"Hi brother END_OF_PART_6b8b4567" dataUsingEncoding:NSUTF8StringEncoding];

  [doc addPartWithHeaders:h1 body:b1];
  [doc addPartWithHeaders:h2 body:b2];
  [doc addPartWithHeaders:h3 body:b3];

  // Generate the boundary and the input stream.
  NSInputStream *stream = nil;
  NSString *boundary = nil;
  unsigned long long length = -1;

  [doc seedRandomWith:1];

  NSString *resultBoundary = doc.boundary;
  NSString *expectedBoundary = @"END_OF_PART_00000001";
  XCTAssertEqualObjects(resultBoundary, expectedBoundary);

  [doc generateInputStream:&stream
                    length:&length
                  boundary:&boundary];

  // The second alternate boundary, given the random seed.

  NSString* expectedResultString = [NSString stringWithFormat:
    @"\r\n--%@\r\n"
    "hfaz: baz\r\n"
    "hfoo: bar\r\n"
    "\r\n"    // Newline after headers.
    "Hi mom END_OF_PART"  // Intentional conflict.
    "\r\n--%@\r\n"
    "\r\n"    // No header here, but still need the newline.
    "Hi dad"
    "\r\n--%@\r\n"
    "Content-Disposition: angry\r\n"
    "Content-Type: text/html\r\n"
    "\r\n"    // Newline after headers.
    "Hi brother END_OF_PART_6b8b4567" // Conflict with the first guess.
    "\r\n--%@--\r\n",
    boundary, boundary, boundary, boundary];

  // Now read the document from the input stream.
  [self doReadTestForInputStream:stream
                  expectedString:expectedResultString
                      testMethod:_cmd];
}

@end
