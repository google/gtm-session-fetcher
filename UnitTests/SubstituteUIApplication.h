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

#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#endif

#import <GTMSessionFetcher/GTMSessionFetcher.h>

NS_ASSUME_NONNULL_BEGIN

#if GTM_BACKGROUND_TASK_FETCHING

// A fake of UIApplication that posts notifications when a background task begins
// and ends.
@class SubstituteUIApplicationTaskInfo;

typedef void (^SubstituteUIApplicationExpirationCallback)(
    NSUInteger numberOfBackgroundTasksToExpire,
    NSArray<SubstituteUIApplicationTaskInfo *> *_Nullable tasksFailingToExpire);

@interface SubstituteUIApplication : NSObject <GTMUIApplicationProtocol>

+ (UIBackgroundTaskIdentifier)lastTaskID;

- (UIBackgroundTaskIdentifier)beginBackgroundTaskWithName:(nullable NSString *)taskName
                                        expirationHandler:(nullable dispatch_block_t)handler;
- (void)endBackgroundTask:(UIBackgroundTaskIdentifier)identifier;

- (void)expireAllBackgroundTasksWithCallback:(SubstituteUIApplicationExpirationCallback)handler;

@end

extern NSString *const kSubUIAppBackgroundTaskBegan;
extern NSString *const kSubUIAppBackgroundTaskEnded;

#endif  // GTM_BACKGROUND_TASK_FETCHING

NS_ASSUME_NONNULL_END
