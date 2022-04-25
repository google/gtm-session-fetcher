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

#import <GTMSessionFetcher/GTMMIMEDocument.h>

@interface GTMMIMEDocumentTest : XCTestCase
@end

// Utility method to create a buffer of predictable bytes.
static NSMutableData *DataForTestWithLength(NSUInteger length);

@implementation GTMMIMEDocumentTest

- (void)doDataTestForDispatchData:(dispatch_data_t)dispatchData
                   expectedString:(NSString *)expectedResultString {
  // This routine, called by the later test methods, verifies that the data matches the
  // expected string.
  NSString *readString = [[NSString alloc] initWithData:(NSData *)dispatchData
                                               encoding:NSUTF8StringEncoding];

  XCTAssertEqualObjects(readString, expectedResultString);
}

- (void)doReadTestForInputStream:(NSInputStream *)inputStream
                  expectedString:(NSString *)expectedResultString {
  // This routine, called by the later test methods, reads the data from the input stream
  // and verifies that it matches the expected string.

  NSInteger expectedLength = (NSInteger)expectedResultString.length;

  // now read the document from the input stream
  unsigned char buffer[9999];
  memset(buffer, 0, sizeof(buffer));

  [inputStream open];
  NSInteger bytesRead = [inputStream read:buffer maxLength:sizeof(buffer)];
  [inputStream close];

  NSString *readString = @((const char *)buffer);

  XCTAssertEqual(bytesRead, expectedLength);
  XCTAssertEqualObjects(readString, expectedResultString);
}

#pragma mark - Joining Part Tests

- (void)testEmptyDoc {
  GTMMIMEDocument *doc = [GTMMIMEDocument MIMEDocument];

  NSInputStream *stream = nil;
  NSString *boundary = nil;
  unsigned long long length = ULONG_MAX;

  NSString *expectedBoundary = @"END_OF_PART";
  NSString *expectedString = @"\r\n--END_OF_PART--\r\n";
  NSUInteger expectedLength = expectedString.length;

  // Generate the boundary and the data.
  dispatch_data_t data;
  [doc generateDispatchData:&data length:&length boundary:&boundary];

  XCTAssertEqualObjects(boundary, expectedBoundary);
  XCTAssertEqual((NSUInteger)length, expectedLength);

  [self doDataTestForDispatchData:data expectedString:expectedString];

  // Generate the boundary and the input stream.
  [doc generateInputStream:&stream length:&length boundary:&boundary];

  XCTAssertEqualObjects(boundary, expectedBoundary);
  XCTAssertEqual((NSUInteger)length, expectedLength);

  [self doReadTestForInputStream:stream expectedString:expectedString];
}

- (void)testSinglePartDoc {
  GTMMIMEDocument *doc = [GTMMIMEDocument MIMEDocument];

  NSDictionary *h1 = @{@"hfoo" : @"bar", @"hfaz" : @"baz"};
  NSData *b1 = [@"Hi mom" dataUsingEncoding:NSUTF8StringEncoding];
  [doc addPartWithHeaders:h1 body:b1];

  NSString *expectedBoundary = @"END_OF_PART";
  NSString *expectedResultString = [NSString stringWithFormat:@"\r\n--%@\r\n"
                                                               "hfaz: baz\r\n"
                                                               "hfoo: bar\r\n"
                                                               "\r\n"  // Newline after headers.
                                                               "Hi mom"
                                                               "\r\n--%@--\r\n",
                                                              expectedBoundary, expectedBoundary];
  NSUInteger expectedLength = expectedResultString.length;

  // Generate the boundary and the input stream.
  NSInputStream *stream = nil;
  NSString *boundary = nil;
  unsigned long long length = ULONG_MAX;

  // Generate the boundary and the data.
  dispatch_data_t data;
  [doc generateDispatchData:&data length:&length boundary:&boundary];

  XCTAssertEqualObjects(boundary, expectedBoundary);
  XCTAssertEqual((NSUInteger)length, expectedLength);

  [self doDataTestForDispatchData:data expectedString:expectedResultString];

  // Generate the boundary and the input stream.
  [doc generateInputStream:&stream length:&length boundary:&boundary];

  XCTAssertEqualObjects(boundary, expectedBoundary);
  XCTAssertEqual((NSUInteger)length, expectedLength);

  [self doReadTestForInputStream:stream expectedString:expectedResultString];
}

- (void)testMultiPartDoc {
  GTMMIMEDocument *doc = [GTMMIMEDocument MIMEDocument];

  NSDictionary *h1 = @{@"hfoo" : @"bar", @"hfaz" : @"baz"};
  NSData *b1 = [@"Hi mom" dataUsingEncoding:NSUTF8StringEncoding];

  NSDictionary *h2 = [NSDictionary dictionary];
  NSData *b2 = [@"Hi dad" dataUsingEncoding:NSUTF8StringEncoding];

  NSDictionary *h3 = @{
    @"Content-Type" : @"text/html",
    @"Content-Disposition" : @"angry",
    @"Content-ID" : @"MyCat:fluffy",  // Value should allow a colon.
  };
  NSData *b3 = [@"Hi brother" dataUsingEncoding:NSUTF8StringEncoding];

  [doc addPartWithHeaders:h1 body:b1];
  [doc addPartWithHeaders:h2 body:b2];
  [doc addPartWithHeaders:h3 body:b3];

  NSString *const expectedResultTemplate = @"\r\n--%@\r\n"
                                            "hfaz: baz\r\n"
                                            "hfoo: bar\r\n"
                                            "\r\n"  // Newline after headers.
                                            "Hi mom"
                                            "\r\n--%@\r\n"
                                            "\r\n"  // No header here, but still need the newline.
                                            "Hi dad"
                                            "\r\n--%@\r\n"
                                            "Content-Disposition: angry\r\n"
                                            "Content-ID: MyCat:fluffy\r\n"
                                            "Content-Type: text/html\r\n"
                                            "\r\n"  // Newline after headers.
                                            "Hi brother"
                                            "\r\n--%@--\r\n";

  NSString *boundary = nil;
  unsigned long long length = ULONG_MAX;

  // Generate the boundary and the data.
  dispatch_data_t data;
  [doc generateDispatchData:&data length:&length boundary:&boundary];

  NSString *expectedResultString =
      [NSString stringWithFormat:expectedResultTemplate, boundary, boundary, boundary, boundary];

  [self doDataTestForDispatchData:data expectedString:expectedResultString];

  // Generate the boundary and the input stream.
  NSInputStream *stream = nil;

  [doc generateInputStream:&stream length:&length boundary:&boundary];

  expectedResultString =
      [NSString stringWithFormat:expectedResultTemplate, boundary, boundary, boundary, boundary];

  [self doReadTestForInputStream:stream expectedString:expectedResultString];

  //
  // These tests check behavior with NULL parameters.
  //
  NSUInteger expectedLength = (NSUInteger)length;
  NSString *expectedBoundary = boundary;

  // Generate the length and boundary only via data request.
  [doc generateDispatchData:NULL length:&length boundary:&boundary];

  XCTAssertEqualObjects(boundary, expectedBoundary);
  XCTAssertEqual((NSUInteger)length, expectedLength);

  // Generate the length and boundary only via stream request.
  [doc generateInputStream:NULL length:&length boundary:&boundary];

  XCTAssertEqualObjects(boundary, expectedBoundary);
  XCTAssertEqual((NSUInteger)length, expectedLength);

  // Generate the data only.
  [doc generateDispatchData:&data length:NULL boundary:NULL];

  [self doDataTestForDispatchData:data expectedString:expectedResultString];

  // Generate the stream only.
  [doc generateInputStream:&stream length:NULL boundary:NULL];

  [self doReadTestForInputStream:stream expectedString:expectedResultString];
}

- (void)testExplicitBoundary {
  GTMMIMEDocument *doc = [GTMMIMEDocument MIMEDocument];

  NSDictionary *h1 = @{@"hfoo" : @"bar", @"hfaz" : @"baz"};
  NSData *b1 = [@"Hi mom" dataUsingEncoding:NSUTF8StringEncoding];

  NSDictionary *h2 = [NSDictionary dictionary];
  NSData *b2 = [@"Hi dad" dataUsingEncoding:NSUTF8StringEncoding];

  [doc addPartWithHeaders:h1 body:b1];
  [doc addPartWithHeaders:h2 body:b2];

  NSString *birdy = @"Look at that magic bird!";
  doc.boundary = birdy;

  NSInputStream *stream = nil;
  NSString *boundary = nil;
  unsigned long long length = ULONG_MAX;

  NSString *const expectedResultTemplate = @"\r\n--%@\r\n"
                                            "hfaz: baz\r\n"
                                            "hfoo: bar\r\n"
                                            "\r\n"  // Newline after headers.
                                            "Hi mom"
                                            "\r\n--%@\r\n"
                                            "\r\n"  // No header here, but still need the newline.
                                            "Hi dad"
                                            "\r\n--%@--\r\n";

  // Generate the boundary and the data.
  dispatch_data_t data;
  [doc generateDispatchData:&data length:&length boundary:&boundary];

  NSString *expectedResultString =
      [NSString stringWithFormat:expectedResultTemplate, birdy, birdy, birdy];

  [self doDataTestForDispatchData:data expectedString:expectedResultString];

  // Generate the boundary and the input stream.
  [doc generateInputStream:&stream length:&length boundary:&boundary];

  expectedResultString = [NSString stringWithFormat:expectedResultTemplate, birdy, birdy, birdy];

  // Now read the document from the input stream.
  [self doReadTestForInputStream:stream expectedString:expectedResultString];
}

- (void)testBoundaryConflict {
  GTMMIMEDocument *doc = [GTMMIMEDocument MIMEDocument];

  // We'll insert the text END_OF_PART_6b8b4567 which conflicts with
  // both the normal boundary ("END_OF_PART") and the first alternate
  // guess (given a random seed of 1, done below).

  NSDictionary *h1 = @{@"hfoo" : @"bar", @"hfaz" : @"baz"};
  NSData *b1 = [@"Hi mom END_OF_PART" dataUsingEncoding:NSUTF8StringEncoding];

  NSDictionary *h2 = [NSDictionary dictionary];
  NSData *b2 = [@"Hi dad" dataUsingEncoding:NSUTF8StringEncoding];

  NSDictionary *h3 = @{@"Content-Type" : @"text/html", @"Content-Disposition" : @"angry"};
  NSData *b3 = [@"Hi brother END_OF_PART_6b8b4567" dataUsingEncoding:NSUTF8StringEncoding];

  [doc addPartWithHeaders:h1 body:b1];
  [doc addPartWithHeaders:h2 body:b2];
  [doc addPartWithHeaders:h3 body:b3];

  NSString *const expectedResultTemplate =
      @"\r\n--%@\r\n"
       "hfaz: baz\r\n"
       "hfoo: bar\r\n"
       "\r\n"                // Newline after headers.
       "Hi mom END_OF_PART"  // Intentional conflict.
       "\r\n--%@\r\n"
       "\r\n"  // No header here, but still need the newline.
       "Hi dad"
       "\r\n--%@\r\n"
       "Content-Disposition: angry\r\n"
       "Content-Type: text/html\r\n"
       "\r\n"                             // Newline after headers.
       "Hi brother END_OF_PART_6b8b4567"  // Conflict with the first guess.
       "\r\n--%@--\r\n";

  // Generate the boundary and the data.
  dispatch_data_t data;
  NSString *boundary = nil;
  unsigned long long length = ULONG_MAX;

  [doc generateDispatchData:&data length:&length boundary:&boundary];

  NSString *expectedResultString =
      [NSString stringWithFormat:expectedResultTemplate, boundary, boundary, boundary, boundary];

  [self doDataTestForDispatchData:data expectedString:expectedResultString];

  // Generate the boundary and the input stream.
  NSInputStream *stream = nil;

  [doc seedRandomWith:1];

  NSString *resultBoundary = doc.boundary;
  NSString *expectedBoundary = @"END_OF_PART_00000001";
  XCTAssertEqualObjects(resultBoundary, expectedBoundary);

  [doc generateInputStream:&stream length:&length boundary:&boundary];

  // The second alternate boundary, given the random seed.

  expectedResultString =
      [NSString stringWithFormat:expectedResultTemplate, boundary, boundary, boundary, boundary];

  // Now read the document from the input stream.
  [self doReadTestForInputStream:stream expectedString:expectedResultString];
}

#pragma mark - Separating Parts Tests

- (void)testFindBytes {
  NSUInteger (^find)(NSData *, NSData *, NSUInteger *) =
      ^(NSData *needle, NSData *haystack, NSUInteger *foundOffset) {
        return [GTMMIMEDocument findBytesWithNeedle:needle.bytes
                                       needleLength:needle.length
                                           haystack:haystack.bytes
                                     haystackLength:haystack.length
                                        foundOffset:foundOffset];
      };

  NSUInteger numberOfBytesMatched, foundOffset;

  NSData *needleData = [@"catpaw" dataUsingEncoding:NSUTF8StringEncoding];
  NSMutableData *haystackData;

  // Find the needle in the beginning of the haystack.
  haystackData = [needleData mutableCopy];
  [haystackData appendData:DataForTestWithLength(1000)];

  numberOfBytesMatched = find(needleData, haystackData, &foundOffset);
  XCTAssertEqual(numberOfBytesMatched, needleData.length);
  XCTAssertEqual(foundOffset, (NSUInteger)0);

  // Find the needle in the middle of the haystack
  haystackData = DataForTestWithLength(1000);
  [haystackData appendData:needleData];
  [haystackData appendData:DataForTestWithLength(1000)];

  numberOfBytesMatched = find(needleData, haystackData, &foundOffset);
  XCTAssertEqual(numberOfBytesMatched, needleData.length);
  XCTAssertEqual(foundOffset, (NSUInteger)1000);

  // Find the needle in the end of the haystack.
  haystackData = DataForTestWithLength(1000);
  [haystackData appendData:needleData];

  numberOfBytesMatched = find(needleData, haystackData, &foundOffset);
  XCTAssertEqual(numberOfBytesMatched, needleData.length);
  XCTAssertEqual(foundOffset, (NSUInteger)1000);

  // Find unsuccessfully with only a partial needle in the middle of the haystack.
  haystackData = DataForTestWithLength(100);
  [haystackData appendData:[needleData subdataWithRange:NSMakeRange(0, 1)]];  // One byte of needle.
  [haystackData appendData:DataForTestWithLength(100)];

  numberOfBytesMatched = find(needleData, haystackData, &foundOffset);
  XCTAssertEqual(numberOfBytesMatched, (NSUInteger)0);
  XCTAssertEqual(foundOffset, (NSUInteger)0);

  haystackData = DataForTestWithLength(100);
  [haystackData
      appendData:[needleData subdataWithRange:NSMakeRange(0, 5)]];  // Five bytes of needle.
  [haystackData appendData:DataForTestWithLength(100)];

  numberOfBytesMatched = find(needleData, haystackData, &foundOffset);
  XCTAssertEqual(numberOfBytesMatched, (NSUInteger)0);
  XCTAssertEqual(foundOffset, (NSUInteger)0);

  // Find a partial needle at the end of the haystack.
  haystackData = DataForTestWithLength(1000);
  [haystackData appendData:[needleData subdataWithRange:NSMakeRange(0, 1)]];  // One byte of needle.

  numberOfBytesMatched = find(needleData, haystackData, &foundOffset);
  XCTAssertEqual(numberOfBytesMatched, (NSUInteger)1);
  XCTAssertEqual(foundOffset, (NSUInteger)1000);

  haystackData = DataForTestWithLength(1000);
  [haystackData
      appendData:[needleData subdataWithRange:NSMakeRange(0, 5)]];  // Five bytes of needle.

  numberOfBytesMatched = find(needleData, haystackData, &foundOffset);
  XCTAssertEqual(numberOfBytesMatched, (NSUInteger)5);
  XCTAssertEqual(foundOffset, (NSUInteger)1000);

  // Test an empty haystack.
  haystackData = [NSMutableData data];

  numberOfBytesMatched = find(needleData, haystackData, &foundOffset);
  XCTAssertEqual(numberOfBytesMatched, (NSUInteger)0);
  XCTAssertEqual(foundOffset, (NSUInteger)0);

  // Test an empty needle.
  //
  // Note that [NSData data].bytes is nil, so we use a mutable data to get
  // a non-nil buffer pointer.
  haystackData = DataForTestWithLength(1000);

  NSData *emptyNeedleData = [NSMutableData data];
  XCTAssertNotEqual(emptyNeedleData.bytes, (void *)0);  // Confirm a non-null needle pointer.

  numberOfBytesMatched = find(emptyNeedleData, haystackData, &foundOffset);
  XCTAssertEqual(numberOfBytesMatched, (NSUInteger)0);
  XCTAssertEqual(foundOffset, (NSUInteger)0);

  // Test with a whole haystack that is a partial needle.
  haystackData = [[needleData subdataWithRange:NSMakeRange(0, 3)] mutableCopy];

  numberOfBytesMatched = find(needleData, haystackData, &foundOffset);
  XCTAssertEqual(numberOfBytesMatched, (NSUInteger)3);
  XCTAssertEqual(foundOffset, (NSUInteger)0);
}

- (void)testSearchDataForBytes {
  void (^search)(NSData *, NSData *, NSArray **, NSArray **) = ^(
      NSData *fullBuffer, NSData *needleData, NSArray **foundOffsets, NSArray **foundBlockNumbers) {
    [GTMMIMEDocument searchData:fullBuffer
                    targetBytes:needleData.bytes
                   targetLength:needleData.length
                   foundOffsets:foundOffsets
              foundBlockNumbers:foundBlockNumbers];
  };

  NSArray *offsets, *foundBlockNumbers, *expectedOffsets, *expectedBlockNums;
  dispatch_data_t fullBuffer;

  NSData *catpawTargetData = [@"catpaw" dataUsingEncoding:NSUTF8StringEncoding];
  NSData *catTargetData = [@"cat" dataUsingEncoding:NSUTF8StringEncoding];
  NSData *pawTargetData = [@"paw" dataUsingEncoding:NSUTF8StringEncoding];

  NSMutableData *catpawPlusTestBlock = [catpawTargetData mutableCopy];
  [catpawPlusTestBlock appendData:DataForTestWithLength(100)];

  NSMutableData *testPlusCatPawBlock = DataForTestWithLength(100);
  [testPlusCatPawBlock appendData:catpawTargetData];

  //
  // One data range.
  //

  // One data range, no target.
  fullBuffer = [self concatenatedDispatchDataWithDatas:@[ DataForTestWithLength(100) ]];
  search((NSData *)fullBuffer, catpawTargetData, &offsets, &foundBlockNumbers);
  XCTAssertEqualObjects(offsets, [NSArray array]);
  XCTAssertEqualObjects(foundBlockNumbers, [NSArray array]);

  // One data range, target alone.
  fullBuffer = [self concatenatedDispatchDataWithDatas:@[ catpawTargetData ]];
  search((NSData *)fullBuffer, catpawTargetData, &offsets, &foundBlockNumbers);
  expectedOffsets = @[ @0 ];
  expectedBlockNums = @[ @0 ];
  XCTAssertEqualObjects(offsets, expectedOffsets);
  XCTAssertEqualObjects(foundBlockNumbers, expectedBlockNums);

  // One data range, target at beginning.
  fullBuffer = [self concatenatedDispatchDataWithDatas:@[ catpawPlusTestBlock ]];
  search((NSData *)fullBuffer, catpawTargetData, &offsets, &foundBlockNumbers);
  expectedOffsets = @[ @0 ];
  expectedBlockNums = @[ @0 ];
  XCTAssertEqualObjects(offsets, expectedOffsets);
  XCTAssertEqualObjects(foundBlockNumbers, expectedBlockNums);

  // One data range, target at end.
  fullBuffer = [self concatenatedDispatchDataWithDatas:@[ testPlusCatPawBlock ]];
  search((NSData *)fullBuffer, catpawTargetData, &offsets, &foundBlockNumbers);
  expectedOffsets = @[ @100 ];
  expectedBlockNums = @[ @0 ];
  XCTAssertEqualObjects(offsets, expectedOffsets);
  XCTAssertEqualObjects(foundBlockNumbers, expectedBlockNums);

  // Five data ranges, targets in middle.
  fullBuffer = [self concatenatedDispatchDataWithDatas:@[
    DataForTestWithLength(100), catpawTargetData, DataForTestWithLength(100), catpawTargetData,
    DataForTestWithLength(100)
  ]];
  search((NSData *)fullBuffer, catpawTargetData, &offsets, &foundBlockNumbers);

  expectedOffsets = @[ @100, @206 ];
  expectedBlockNums = @[ @1, @3 ];
  XCTAssertEqualObjects(offsets, expectedOffsets);
  XCTAssertEqualObjects(foundBlockNumbers, expectedBlockNums);

  // Five data ranges, target once in first and twice in last.
  NSMutableData *repeatedTargetData = [catpawTargetData mutableCopy];
  [repeatedTargetData appendData:DataForTestWithLength(100)];
  [repeatedTargetData appendData:catpawTargetData];

  fullBuffer = [self concatenatedDispatchDataWithDatas:@[
    catpawTargetData, DataForTestWithLength(100), DataForTestWithLength(100),
    DataForTestWithLength(100), repeatedTargetData
  ]];
  search((NSData *)fullBuffer, catpawTargetData, &offsets, &foundBlockNumbers);

  expectedOffsets = @[ @0, @306, @412 ];
  expectedBlockNums = @[ @0, @4, @4 ];
  XCTAssertEqualObjects(offsets, expectedOffsets);
  XCTAssertEqualObjects(foundBlockNumbers, expectedBlockNums);

  // Target spans first and second blocks.
  NSMutableData *testPlusCatBlock = DataForTestWithLength(100);
  [testPlusCatBlock appendData:catTargetData];
  NSMutableData *pawPlusTestBlock = [pawTargetData mutableCopy];
  [pawPlusTestBlock appendData:DataForTestWithLength(100)];

  fullBuffer = [self concatenatedDispatchDataWithDatas:@[
    testPlusCatBlock,
    pawPlusTestBlock,
  ]];
  search((NSData *)fullBuffer, catpawTargetData, &offsets, &foundBlockNumbers);

  expectedOffsets = @[ @100 ];
  expectedBlockNums = @[ @0 ];
  XCTAssertEqualObjects(offsets, expectedOffsets);
  XCTAssertEqualObjects(foundBlockNumbers, expectedBlockNums);

  // Target spans first and second blocks but interrupted at the beginning of the
  // second block.
  NSMutableData *testPlusPawBlock = DataForTestWithLength(100);
  [testPlusPawBlock appendData:pawTargetData];

  fullBuffer = [self concatenatedDispatchDataWithDatas:@[
    testPlusCatBlock,
    testPlusPawBlock,
  ]];
  search((NSData *)fullBuffer, catpawTargetData, &offsets, &foundBlockNumbers);

  XCTAssertEqualObjects(offsets, [NSArray array]);
  XCTAssertEqualObjects(foundBlockNumbers, [NSArray array]);

  // Target spans second and third blocks.
  fullBuffer = [self concatenatedDispatchDataWithDatas:@[
    DataForTestWithLength(100),
    testPlusCatBlock,
    pawPlusTestBlock,
  ]];
  search((NSData *)fullBuffer, catpawTargetData, &offsets, &foundBlockNumbers);

  expectedOffsets = @[ @200 ];
  expectedBlockNums = @[ @1 ];
  XCTAssertEqualObjects(offsets, expectedOffsets);
  XCTAssertEqualObjects(foundBlockNumbers, expectedBlockNums);

  // Target finishes first and start fourth blocks, and spans second and third blocks.
  fullBuffer = [self concatenatedDispatchDataWithDatas:@[
    testPlusCatPawBlock, testPlusCatBlock, pawPlusTestBlock, catpawPlusTestBlock
  ]];
  search((NSData *)fullBuffer, catpawTargetData, &offsets, &foundBlockNumbers);

  expectedOffsets = @[ @100, @206, @312 ];
  expectedBlockNums = @[ @0, @1, @3 ];
  XCTAssertEqualObjects(offsets, expectedOffsets);
  XCTAssertEqualObjects(foundBlockNumbers, expectedBlockNums);

  // Target spans second, third, and fourth block, plus a target in the fifth block.
  NSMutableData *testPlusCaBlock = DataForTestWithLength(100);
  [testPlusCaBlock appendData:[catpawTargetData subdataWithRange:NSMakeRange(0, 2)]];
  NSMutableData *tpBlock = [[catpawTargetData subdataWithRange:NSMakeRange(2, 2)] mutableCopy];
  NSMutableData *awPlusTestBlock =
      [[catpawTargetData subdataWithRange:NSMakeRange(4, 2)] mutableCopy];
  [awPlusTestBlock appendData:DataForTestWithLength(100)];

  fullBuffer = [self concatenatedDispatchDataWithDatas:@[
    DataForTestWithLength(100),
    testPlusCaBlock,
    tpBlock,
    awPlusTestBlock,
    catpawTargetData,
  ]];
  search((NSData *)fullBuffer, catpawTargetData, &offsets, &foundBlockNumbers);

  expectedOffsets = @[ @200, @306 ];
  expectedBlockNums = @[ @1, @4 ];
  XCTAssertEqualObjects(offsets, expectedOffsets);
  XCTAssertEqualObjects(foundBlockNumbers, expectedBlockNums);

  // Target starts but doesn't complete in first and third blocks.
  fullBuffer = [self concatenatedDispatchDataWithDatas:@[
    testPlusCatBlock,
    DataForTestWithLength(100),
    testPlusCatBlock,
  ]];
  search((NSData *)fullBuffer, catpawTargetData, &offsets, &foundBlockNumbers);

  XCTAssertEqualObjects(offsets, [NSArray array]);
  XCTAssertEqualObjects(foundBlockNumbers, [NSArray array]);

  // Ignore partial matches across blocks.
  fullBuffer = [self concatenatedDispatchDataWithDatas:@[ catTargetData, testPlusPawBlock ]];
  search((NSData *)fullBuffer, catpawTargetData, &offsets, &foundBlockNumbers);

  XCTAssertEqualObjects(offsets, [NSArray array]);
  XCTAssertEqualObjects(foundBlockNumbers, [NSArray array]);

  fullBuffer = [self concatenatedDispatchDataWithDatas:@[
    catTargetData, DataForTestWithLength(1), pawTargetData
  ]];
  search((NSData *)fullBuffer, catpawTargetData, &offsets, &foundBlockNumbers);

  XCTAssertEqualObjects(offsets, [NSArray array]);
  XCTAssertEqualObjects(foundBlockNumbers, [NSArray array]);

  // Overlapping targets should be ignored.
  NSData *catscatsTargetData = [@"catscats" dataUsingEncoding:NSUTF8StringEncoding];
  NSMutableData *blockWithOverlap = DataForTestWithLength(100);
  [blockWithOverlap appendData:catscatsTargetData];
  [blockWithOverlap appendData:[catscatsTargetData subdataWithRange:NSMakeRange(0, 4)]];
  [blockWithOverlap appendData:DataForTestWithLength(100)];

  fullBuffer = [self concatenatedDispatchDataWithDatas:@[
    blockWithOverlap,
  ]];
  search((NSData *)fullBuffer, catscatsTargetData, &offsets, &foundBlockNumbers);

  expectedOffsets = @[ @100 ];
  expectedBlockNums = @[ @0 ];
  XCTAssertEqualObjects(offsets, expectedOffsets);
  XCTAssertEqualObjects(foundBlockNumbers, expectedBlockNums);

  // Overlaps at the character and block level should be ignored.
  NSData *zzTarget = [@"zz" dataUsingEncoding:NSUTF8StringEncoding];
  NSData *zzzzData = [@"zzzz" dataUsingEncoding:NSUTF8StringEncoding];
  NSMutableData *dataWithCharacterOverlapsFirst = DataForTestWithLength(100);
  [dataWithCharacterOverlapsFirst appendData:zzzzData];
  NSMutableData *dataWithCharacterOverlapsSecond = [zzzzData mutableCopy];
  [dataWithCharacterOverlapsSecond appendData:DataForTestWithLength(100)];

  fullBuffer = [self concatenatedDispatchDataWithDatas:@[
    dataWithCharacterOverlapsFirst,
    dataWithCharacterOverlapsSecond,
  ]];
  search((NSData *)fullBuffer, zzTarget, &offsets, &foundBlockNumbers);

  expectedOffsets = @[ @100, @102, @104, @106 ];
  expectedBlockNums = @[ @0, @0, @1, @1 ];
  XCTAssertEqualObjects(offsets, expectedOffsets);
  XCTAssertEqualObjects(foundBlockNumbers, expectedBlockNums);

  // Full buffer is empty.
  char *empty = "";
  fullBuffer = dispatch_data_create(empty, 0, nil, nil);
  search((NSData *)fullBuffer, catpawTargetData, &offsets, &foundBlockNumbers);

  XCTAssertEqualObjects(offsets, [NSArray array]);
  XCTAssertEqualObjects(foundBlockNumbers, [NSArray array]);
}

- (dispatch_data_t)concatenatedDispatchDataWithDatas:(NSArray *)datas {
  dispatch_queue_t bgQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);

  dispatch_data_t result;

  for (NSData *oneData in datas) {
    dispatch_data_t ddata = dispatch_data_create(oneData.bytes, oneData.length, bgQueue, ^{
      [oneData self];
    });
    if (!result) {
      result = ddata;
    } else {
      result = dispatch_data_create_concat(result, ddata);
    }
  }
  return result;
}

- (void)testPartParsing_SinglePart {
  NSString *const docTemplate = (@"\r\n--%@\r\n"
                                 @"cat-breed: Maine Coon\r\n"
                                 @"dog-breed: German Shepherd\r\n"
                                 @"\r\n"
                                 @"Go Spot, go!"
                                 @"\r\n--%@--\r\n");
  NSString *docBoundary = @"END_OF_PART";
  NSString *docString = [NSString stringWithFormat:docTemplate, docBoundary, docBoundary];
  NSData *docData = [docString dataUsingEncoding:NSUTF8StringEncoding];

  NSArray *parts = [GTMMIMEDocument MIMEPartsWithBoundary:docBoundary data:docData];
  NSDictionary *expectedHeaders =
      @{@"cat-breed" : @"Maine Coon", @"dog-breed" : @"German Shepherd"};
  NSData *expectedBody = [@"Go Spot, go!" dataUsingEncoding:NSUTF8StringEncoding];

  GTMMIMEDocumentPart *part0 = parts[0];
  XCTAssertEqualObjects(part0.headers, expectedHeaders);
  XCTAssertEqualObjects(part0.body, expectedBody);
  XCTAssertEqual(parts.count, (NSUInteger)1);
}

- (void)testPartParsing_SinglePart_WithoutHeaders {
  NSString *const docTemplate = (@"\r\n--%@\r\n"
                                 @"\r\n"
                                 @"Go Spot, go!"
                                 @"\r\n--%@--\r\n");
  NSString *docBoundary = @"END_OF_PART";
  NSString *docString = [NSString stringWithFormat:docTemplate, docBoundary, docBoundary];
  NSData *docData = [docString dataUsingEncoding:NSUTF8StringEncoding];

  NSArray *parts = [GTMMIMEDocument MIMEPartsWithBoundary:docBoundary data:docData];
  NSData *expectedBody = [@"Go Spot, go!" dataUsingEncoding:NSUTF8StringEncoding];

  GTMMIMEDocumentPart *part0 = parts[0];
  XCTAssertNil(part0.headers);
  XCTAssertEqualObjects(part0.body, expectedBody);
  XCTAssertEqual(parts.count, (NSUInteger)1);
}

- (void)testPartParsing_SinglePart_EmptyBody {
  NSString *const docTemplate = (@"\r\n--%@\r\n"
                                 @"cat-breed: Maine Coon\r\n"
                                 @"dog-breed: German Shepherd\r\n"
                                 @"\r\n"
                                 @"\r\n--%@--\r\n");
  NSString *docBoundary = @"END_OF_PART";
  NSString *docString = [NSString stringWithFormat:docTemplate, docBoundary, docBoundary];
  NSData *docData = [docString dataUsingEncoding:NSUTF8StringEncoding];

  NSArray *parts = [GTMMIMEDocument MIMEPartsWithBoundary:docBoundary data:docData];
  NSDictionary *expectedHeaders =
      @{@"cat-breed" : @"Maine Coon", @"dog-breed" : @"German Shepherd"};

  GTMMIMEDocumentPart *part0 = parts[0];
  XCTAssertEqualObjects(part0.headers, expectedHeaders);
  XCTAssertEqualObjects(part0.body, [NSData data]);
  XCTAssertEqual(parts.count, (NSUInteger)1);
}

- (void)testPartParsing_SinglePart_WithoutHeadersOrBody {
  NSString *const docTemplate = (@"\r\n--%@\r\n"
                                 @"\r\n"
                                 @"\r\n--%@--\r\n");
  NSString *docBoundary = @"END_OF_PART";
  NSString *docString = [NSString stringWithFormat:docTemplate, docBoundary, docBoundary];
  NSData *docData = [docString dataUsingEncoding:NSUTF8StringEncoding];

  NSArray *parts = [GTMMIMEDocument MIMEPartsWithBoundary:docBoundary data:docData];
  GTMMIMEDocumentPart *part0 = parts[0];
  XCTAssertNil(part0.headers);
  XCTAssertEqualObjects(part0.body, [NSData data]);
  XCTAssertEqual(parts.count, (NSUInteger)1);
}

- (void)testPartParsing_TwoParts {
  NSString *const docTemplate = (@"this should be ignored \r\n--%@\r\n"
                                 @"cat-breed: Maine Coon\r\n"
                                 @"dog-breed: German Shepherd\r\n"
                                 @"\r\n"
                                 @"Go Spot, go!"
                                 @"\r\n--%@\r\n"
                                 @"Horse-breed: Friesian\r\n"
                                 @"\r\n"
                                 @"Hi ho, Silver\nAway!\r\nThat's all, folks."
                                 @"\r\n--%@--\r\n this should be ignored");
  NSString *docBoundary = @"END_OF_PART";
  NSString *docString =
      [NSString stringWithFormat:docTemplate, docBoundary, docBoundary, docBoundary];
  NSData *docData = [docString dataUsingEncoding:NSUTF8StringEncoding];

  NSArray *parts = [GTMMIMEDocument MIMEPartsWithBoundary:docBoundary data:docData];
  XCTAssertEqual(parts.count, (NSUInteger)2);

  NSDictionary *expectedHeaders0 =
      @{@"cat-breed" : @"Maine Coon", @"dog-breed" : @"German Shepherd"};
  NSData *expectedBody0 = [@"Go Spot, go!" dataUsingEncoding:NSUTF8StringEncoding];

  GTMMIMEDocumentPart *part0 = parts[0];
  XCTAssertEqualObjects(part0.headers, expectedHeaders0);
  XCTAssertEqualObjects(part0.body, expectedBody0);

  NSDictionary *expectedHeaders1 = @{@"Horse-breed" : @"Friesian"};
  NSData *expectedBody1 =
      [@"Hi ho, Silver\nAway!\r\nThat's all, folks." dataUsingEncoding:NSUTF8StringEncoding];

  GTMMIMEDocumentPart *part1 = parts[1];
  XCTAssertEqualObjects(part1.headers, expectedHeaders1);
  XCTAssertEqualObjects(part1.body, expectedBody1);
}

- (void)testPartParsing_InvalidDoc {
  // Doc with plain newlines rather than the required CRLF line breaks.
  NSString *const docTemplate = (@"\n--%@\n"
                                 @"cat-breed: Maine Coon\n"
                                 @"dog-breed: German Shepherd\n"
                                 @"\n"
                                 @"Go Spot, go!"
                                 @"\n--%@--\n");
  NSString *docBoundary = @"END_OF_PART";
  NSString *docString = [NSString stringWithFormat:docTemplate, docBoundary, docBoundary];
  NSData *docData = [docString dataUsingEncoding:NSUTF8StringEncoding];

  NSArray *parts = [GTMMIMEDocument MIMEPartsWithBoundary:docBoundary data:docData];
  XCTAssertEqual(parts.count, (NSUInteger)1);
  // Malformed input results in nil headers and an empty NSData body.
  GTMMIMEDocumentPart *part0 = parts[0];
  XCTAssertNil(part0.headers);
  XCTAssertNotNil(part0.body);
  XCTAssertEqual(part0.body.length, 0);
}

@end

// Utility method to create a buffer of predictable bytes.
static NSMutableData *DataForTestWithLength(NSUInteger length) {
  NSMutableData *mutable = [NSMutableData dataWithLength:length];
  const char *bytevals = "0123456789";
  char *ptr = mutable.mutableBytes;
  for (NSUInteger counter = 0; counter < length; counter++) {
    ptr[counter] = bytevals[counter % 10];
  }
  return mutable;
}
