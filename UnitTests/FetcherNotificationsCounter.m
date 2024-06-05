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

#import "FetcherNotificationsCounter.h"

#import <Foundation/Foundation.h>

#import <GTMSessionFetcher/GTMSessionFetcher.h>
#import <GTMSessionFetcher/GTMSessionUploadFetcher.h>
#import "SubstituteUIApplication.h"

@implementation FetcherNotificationsCounter {
  NSDate *_counterCreationDate;
#if GTM_BACKGROUND_TASK_FETCHING
  UIBackgroundTaskIdentifier _priorTaskID;
#endif
}

@synthesize fetchStarted = _fetchStarted, fetchStopped = _fetchStopped,
            fetchCompletionInvoked = _fetchCompletionInvoked,
            uploadChunkFetchStarted = _uploadChunkFetchStarted,
            uploadChunkFetchStopped = _uploadChunkFetchStopped,
            retryDelayStarted = _retryDelayStarted, retryDelayStopped = _retryDelayStopped,
            uploadLocationObtained = _uploadLocationObtained,
            uploadChunkRequestPaths = _uploadChunkRequestPaths,
            uploadChunkCommands = _uploadChunkCommands, uploadChunkOffsets = _uploadChunkOffsets,
            uploadChunkLengths = _uploadChunkLengths,
            fetchersStartedDescriptions = _fetchersStartedDescriptions,
            fetchersStoppedDescriptions = _fetchersStoppedDescriptions,
            backgroundTasksStarted = _backgroundTasksStarted,
            backgroundTasksEnded = _backgroundTasksEnded;

- (instancetype)init {
  self = [super init];
  if (self) {
    _counterCreationDate = [[NSDate alloc] init];

    _uploadChunkRequestPaths = [[NSMutableArray alloc] init];
    _uploadChunkCommands = [[NSMutableArray alloc] init];
    _uploadChunkOffsets = [[NSMutableArray alloc] init];
    _uploadChunkLengths = [[NSMutableArray alloc] init];
    _fetchersStartedDescriptions = [[NSMutableArray alloc] init];
    _fetchersStoppedDescriptions = [[NSMutableArray alloc] init];
    _backgroundTasksStarted = [[NSMutableArray alloc] init];
    _backgroundTasksEnded = [[NSMutableArray alloc] init];
#if GTM_BACKGROUND_TASK_FETCHING
    _priorTaskID = [SubstituteUIApplication lastTaskID];
#endif

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self
           selector:@selector(fetchStateChanged:)
               name:kGTMSessionFetcherStartedNotification
             object:nil];
    [nc addObserver:self
           selector:@selector(fetchStateChanged:)
               name:kGTMSessionFetcherStoppedNotification
             object:nil];
    [nc addObserver:self
           selector:@selector(fetchCompletionInvoked:)
               name:kGTMSessionFetcherCompletionInvokedNotification
             object:nil];
    [nc addObserver:self
           selector:@selector(retryDelayStateChanged:)
               name:kGTMSessionFetcherRetryDelayStartedNotification
             object:nil];
    [nc addObserver:self
           selector:@selector(retryDelayStateChanged:)
               name:kGTMSessionFetcherRetryDelayStoppedNotification
             object:nil];
    [nc addObserver:self
           selector:@selector(uploadLocationObtained:)
               name:kGTMSessionFetcherUploadLocationObtainedNotification
             object:nil];
#if GTM_BACKGROUND_TASK_FETCHING
    [nc addObserver:self
           selector:@selector(backgroundTaskBegan:)
               name:kSubUIAppBackgroundTaskBegan
             object:nil];
    [nc addObserver:self
           selector:@selector(backgroundTaskEnded:)
               name:kSubUIAppBackgroundTaskEnded
             object:nil];
#endif
  }
  return self;
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (BOOL)shouldIgnoreNotification:(NSNotification *)note {
  GTMSessionFetcher *fetcher = note.object;
  NSDate *fetcherBeginDate = fetcher.initialBeginFetchDate;
  BOOL isTooOld =
      (fetcherBeginDate && [fetcherBeginDate compare:_counterCreationDate] == NSOrderedAscending);
  return isTooOld;
}

- (NSString *)descriptionForFetcher:(GTMSessionFetcher *)fetcher {
  NSString *description =
      [NSString stringWithFormat:@"fetcher %p %@ %@", fetcher, fetcher.comment ?: @"<no comment>",
                                 fetcher.request.URL.absoluteString];
  if (fetcher.retryCount > 0) {
    description =
        [description stringByAppendingFormat:@" retry %lu", (unsigned long)fetcher.retryCount];
  }
  return description;
}

- (void)fetchStateChanged:(NSNotification *)note {
  if ([self shouldIgnoreNotification:note]) return;

  GTMSessionFetcher *fetcher = note.object;
  BOOL isUploadChunkFetcher = ([fetcher parentUploadFetcher] != nil);
  BOOL isFetchStartedNotification = [note.name isEqual:kGTMSessionFetcherStartedNotification];

  if (isFetchStartedNotification) {
    ++_fetchStarted;
    [_fetchersStartedDescriptions addObject:[self descriptionForFetcher:fetcher]];

    if (isUploadChunkFetcher) {
      ++_uploadChunkFetchStarted;

      NSURLRequest *request = fetcher.request;
      NSString *command = [request valueForHTTPHeaderField:@"X-Goog-Upload-Command"];
      NSInteger offset = [[request valueForHTTPHeaderField:@"X-Goog-Upload-Offset"] integerValue];
      NSInteger length = [[request valueForHTTPHeaderField:@"Content-Length"] integerValue];
      NSString *path = request.URL.path;
      [_uploadChunkRequestPaths addObject:path];
      [_uploadChunkCommands addObject:command];
      [_uploadChunkOffsets addObject:@(offset)];
      [_uploadChunkLengths addObject:@(length)];

      NSAssert([[fetcher parentUploadFetcher] isKindOfClass:[GTMSessionUploadFetcher class]],
               @"Unexpected parent");
    }
  } else {
    ++_fetchStopped;
    [_fetchersStoppedDescriptions addObject:[self descriptionForFetcher:fetcher]];

    if (isUploadChunkFetcher) {
      ++_uploadChunkFetchStopped;
    }
  }

  NSAssert(_fetchStopped <= _fetchStarted, @"fetch notification imbalance: starts=%d stops=%d",
           (int)_fetchStarted, (int)_fetchStopped);
}

- (void)fetchCompletionInvoked:(NSNotification *)note {
  if ([self shouldIgnoreNotification:note]) return;

  ++_fetchCompletionInvoked;
}

- (void)retryDelayStateChanged:(NSNotification *)note {
  if ([self shouldIgnoreNotification:note]) return;

  if ([note.name isEqual:kGTMSessionFetcherRetryDelayStartedNotification]) {
    ++_retryDelayStarted;
  } else {
    ++_retryDelayStopped;
  }
  NSAssert(_retryDelayStopped <= _retryDelayStarted,
           @"retry delay notification imbalance: starts=%d stops=%d", (int)_retryDelayStarted,
           (int)_retryDelayStopped);
}

- (void)uploadLocationObtained:(NSNotification *)note {
  if ([self shouldIgnoreNotification:note]) return;

  __unused GTMSessionUploadFetcher *fetcher = note.object;
  NSAssert(fetcher.uploadLocationURL != nil, @"missing upload location: %@", fetcher);

  ++_uploadLocationObtained;
}

#if GTM_BACKGROUND_TASK_FETCHING
- (void)backgroundTaskBegan:(NSNotification *)note {
  // Ignore notifications that predate this object's existence.
  if (((NSNumber *)note.object).unsignedLongLongValue <= _priorTaskID) {
    return;
  }
  @synchronized(self) {
    [_backgroundTasksStarted addObject:(id)note.object];
  }
}

- (void)backgroundTaskEnded:(NSNotification *)note {
  @synchronized(self) {
    // Ignore notifications that were started prior to this object's existence.
    if (![_backgroundTasksStarted containsObject:(NSNumber *)note.object]) return;

    [_backgroundTasksEnded addObject:(id)note.object];
  }
}
#endif  // GTM_BACKGROUND_TASK_FETCHING

@end
