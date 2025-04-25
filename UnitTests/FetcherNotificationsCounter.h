/* Copyright 2024 Google Inc. All rights reserved.
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

NS_ASSUME_NONNULL_BEGIN

@interface FetcherNotificationsCounter : NSObject
@property(nonatomic) int fetchStarted;
@property(nonatomic) int fetchStopped;
@property(nonatomic) int fetchCompletionInvoked;
@property(nonatomic) int uploadChunkFetchStarted;  // Includes query fetches.
@property(nonatomic) int uploadChunkFetchStopped;  // Includes query fetches.
@property(nonatomic) int retryDelayStarted;
@property(nonatomic) int retryDelayStopped;
@property(nonatomic) int uploadLocationObtained;

@property(nonatomic) NSMutableArray *uploadChunkRequestPaths;  // of NSString
@property(nonatomic) NSMutableArray *uploadChunkCommands;      // of NSString
@property(nonatomic) NSMutableArray *uploadChunkOffsets;       // of NSUInteger
@property(nonatomic) NSMutableArray *uploadChunkLengths;       // of NSUInteger

@property(nonatomic) NSMutableArray *fetchersStartedDescriptions;  // of NSString
@property(nonatomic) NSMutableArray *fetchersStoppedDescriptions;  // of NSString

@property(nonatomic) NSMutableArray *backgroundTasksStarted;  // of boxed UIBackgroundTaskIdentifier
@property(nonatomic) NSMutableArray *backgroundTasksEnded;    // of boxed UIBackgroundTaskIdentifier

@end

NS_ASSUME_NONNULL_END
