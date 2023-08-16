#import <XCTest/XCTest.h>
#import <stdatomic.h>

#import <GTMSessionFetcher/GTMSessionFetcher.h>

NS_ASSUME_NONNULL_BEGIN

static atomic_bool gShouldStartThreads = ATOMIC_VAR_INIT(false);

typedef NS_ENUM(NSInteger, GTMSessionFetcherUserAgentThreadState) {
  GTMSessionFetcherUserAgentThreadStateDefault = 0,
  GTMSessionFetcherUserAgentThreadStateFinished = 1,
};

@interface GTMSessionFetcherUserAgentThread : NSThread

@property(nonatomic) NSConditionLock *finishedConditionLock;

@end

@implementation GTMSessionFetcherUserAgentThread

- (instancetype)init {
  self = [super init];
  if (self) {
    _finishedConditionLock =
        [[NSConditionLock alloc] initWithCondition:GTMSessionFetcherUserAgentThreadStateDefault];
  }
  return self;
}

- (void)main {
  do {
  } while (atomic_load(&gShouldStartThreads) == false);
  GTMFetcherCleanedUserAgentString(@"foo bar baz [123/a.b.c]");
  [_finishedConditionLock lockWhenCondition:GTMSessionFetcherUserAgentThreadStateDefault];
  [_finishedConditionLock unlockWithCondition:GTMSessionFetcherUserAgentThreadStateFinished];
}

- (void)join {
  [_finishedConditionLock lockWhenCondition:GTMSessionFetcherUserAgentThreadStateFinished];
  [_finishedConditionLock unlockWithCondition:GTMSessionFetcherUserAgentThreadStateFinished];
}

@end

@interface GTMSessionFetcherUserAgentTest : XCTestCase
@end

@implementation GTMSessionFetcherUserAgentTest

- (void)testCleanedUserAgentStringConcurrencyShouldNotCrash {
  static const size_t kNumConcurrentJobs = 500;

  NSMutableArray<GTMSessionFetcherUserAgentThread *> *threads =
      [NSMutableArray arrayWithCapacity:kNumConcurrentJobs];

  for (size_t i = 0; i < kNumConcurrentJobs; i++) {
    GTMSessionFetcherUserAgentThread *thread = [[GTMSessionFetcherUserAgentThread alloc] init];
    [threads addObject:thread];
    [thread start];
  }

  atomic_store(&gShouldStartThreads, true);

  // Wait for all the threads to finish.
  for (GTMSessionFetcherUserAgentThread *thread in threads) {
    [thread join];
  }
}

@end

NS_ASSUME_NONNULL_END
