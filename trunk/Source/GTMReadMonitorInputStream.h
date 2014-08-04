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

#import <Foundation/Foundation.h>

@interface GTMReadMonitorInputStream : NSInputStream <NSStreamDelegate> {
 @protected
  NSInputStream *inputStream_; // Encapsulated stream that does the work.

  NSThread *thread_;      // Thread in which this object was created.
  NSArray *runLoopModes_; // Modes for calling callbacks, when necessary.
}

+ (id)inputStreamWithStream:(NSInputStream *)input;

- (id)initWithStream:(NSInputStream *)input;

// The read monitor selector is called when bytes have been read. It should have this signature:
//
// - (void)inputStream:(GTMReadMonitorInputStream *)stream
//      readIntoBuffer:(uint8_t *)buffer
//              length:(int64_t)length;

@property(weak) id readDelegate;
@property(assign) SEL readSelector;

// Modes for invoking callbacks, when necessary.
@property(strong) NSArray *runLoopModes;

@end
