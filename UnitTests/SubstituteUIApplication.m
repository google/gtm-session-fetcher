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

#import "SubstituteUIApplication.h"

#if GTM_BACKGROUND_TASK_FETCHING
@interface SubstituteUIApplicationTaskInfo : NSObject
@property(atomic, assign) UIBackgroundTaskIdentifier taskIdentifier;
@property(atomic, copy) NSString *taskName;
@property(atomic, copy) dispatch_block_t expirationHandler;
@end

NSString *const kSubUIAppBackgroundTaskBegan = @"kSubUIAppBackgroundTaskBegan";
NSString *const kSubUIAppBackgroundTaskEnded = @"kSubUIAppBackgroundTaskEnded";

@implementation SubstituteUIApplication {
  UIBackgroundTaskIdentifier _identifier;
  NSMutableDictionary<NSNumber *, SubstituteUIApplicationTaskInfo *> *_identifierToTaskInfoMap;
}

UIBackgroundTaskIdentifier gTaskID = 1000;

+ (UIBackgroundTaskIdentifier)lastTaskID {
  @synchronized(self) {
    return gTaskID;
  }
}

+ (UIBackgroundTaskIdentifier)reserveTaskID {
  @synchronized(self) {
    return ++gTaskID;
  }
}

- (UIBackgroundTaskIdentifier)beginBackgroundTaskWithName:(NSString *)taskName
                                        expirationHandler:(dispatch_block_t)handler {
  // Threading stress is tested in [GTMSessionFetcherServiceTest testThreadingStress].
  // For the simple fetcher tests, the fetchers start on the main thread, so the background
  // tasks start on the main thread. Since moving the NSURLSession delegate queue to default
  // to a background queue, this SubstituteUIApplication, gTaskID access, and
  // FetcherNotificationsCounter must be safe from arbitrary threads.
  UIBackgroundTaskIdentifier taskID = [SubstituteUIApplication reserveTaskID];

  SubstituteUIApplicationTaskInfo *taskInfo = [[SubstituteUIApplicationTaskInfo alloc] init];
  taskInfo.taskIdentifier = taskID;
  taskInfo.taskName = taskName;
  taskInfo.expirationHandler = handler;

  @synchronized(self) {
    if (!_identifierToTaskInfoMap) _identifierToTaskInfoMap = [[NSMutableDictionary alloc] init];
    _identifierToTaskInfoMap[@(taskID)] = taskInfo;
  }

  // Post the notification synchronously from the current thread.
  [[NSNotificationCenter defaultCenter] postNotificationName:kSubUIAppBackgroundTaskBegan
                                                      object:@(taskID)];
  return taskID;
}

- (void)endBackgroundTask:(UIBackgroundTaskIdentifier)taskID {
  @synchronized(self) {
    NSAssert(_identifierToTaskInfoMap[@(taskID)] != nil,
             @"endBackgroundTask failed to find task: %lu", (unsigned long)taskID);

    [_identifierToTaskInfoMap removeObjectForKey:@(taskID)];
  }

  // Post the notification synchronously from the current thread.
  [[NSNotificationCenter defaultCenter] postNotificationName:kSubUIAppBackgroundTaskEnded
                                                      object:@(taskID)];
}

- (void)expireAllBackgroundTasksWithCallback:(SubstituteUIApplicationExpirationCallback)handler {
  NSUInteger count;
  @synchronized([SubstituteUIApplication class]) {
    count = _identifierToTaskInfoMap.count;
  }
  if (count == 0) {
    handler(0, nil);
    return;
  }

  @synchronized(self) {
    for (NSNumber *taskID in _identifierToTaskInfoMap) {
      SubstituteUIApplicationTaskInfo *taskInfo = _identifierToTaskInfoMap[taskID];
      taskInfo.expirationHandler();
    }
  }
  // We expect that all background tasks ended themselves soon after their handlers were called.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   NSArray<SubstituteUIApplicationTaskInfo *> *failedToExpire;
                   @synchronized(self) {
                     failedToExpire = self->_identifierToTaskInfoMap.allValues;
                   }
                   handler(count, failedToExpire);
                 });
}

@end

@implementation SubstituteUIApplicationTaskInfo
@synthesize taskIdentifier = _taskIdentifier;
@synthesize taskName = _taskName;
@synthesize expirationHandler = _expirationHandler;

- (NSString *)description {
  return
      [NSString stringWithFormat:@"<task %lu \"%@\">", (unsigned long)_taskIdentifier, _taskName];
}

@end

#endif  // GTM_BACKGROUND_TASK_FETCHING
