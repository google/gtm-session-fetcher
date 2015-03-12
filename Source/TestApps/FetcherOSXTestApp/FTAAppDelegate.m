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

//
//  FetcherOSXTestApp
//

#import "FTAAppDelegate.h"
#import "GTMSessionFetcher.h"
#import "GTMSessionUploadFetcher.h"
#import "GTMSessionFetcherLogging.h"

@implementation FTAAppDelegate

- (NSData *)generatedUploadDataWithLength:(NSUInteger)length {
  // Fill an NSData.
  NSMutableData *data = [NSMutableData dataWithLength:length];

  unsigned char *bytes = [data mutableBytes];
  for (NSUInteger idx = 0; idx < length; idx++) {
    bytes[idx] = (unsigned char)((idx + 1) % 256);
  }
  return data;
}

- (void)runBackgroundFetcher {
  NSUInteger kUploadDataSize = 1000000;
  NSData *uploadData = [self generatedUploadDataWithLength:kUploadDataSize];


  NSURL *localUploadURL = [NSURL URLWithString:@"http://0.upload.google.com/null"];
  NSMutableURLRequest *request =
      [NSMutableURLRequest requestWithURL:localUploadURL
                              cachePolicy:NSURLRequestReloadIgnoringCacheData
                          timeoutInterval:60*60];
  [request setHTTPMethod:@"POST"];

  GTMSessionFetcherService *fetcherService = [[GTMSessionFetcherService alloc] init];

  GTMSessionUploadFetcher *fetcher =
      [GTMSessionUploadFetcher uploadFetcherWithRequest:request
                                         uploadMIMEType:@"text/plain"
                                              chunkSize:kUploadDataSize / 100
                                         fetcherService:fetcherService];
  fetcher.uploadData = uploadData;
  fetcher.comment = NSStringFromSelector(_cmd);
  fetcher.allowLocalhostRequest = YES;
  fetcher.allowedInsecureSchemes = @[ @"http" ];
  [fetcher beginFetchWithCompletionHandler:^(NSData *data, NSError *error) {
    NSLog(@"Error: %@", error);
    NSLog(@"%@", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);

    [self exitApp];
  }];
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
  [GTMSessionFetcher setLoggingEnabled:YES];
  [self runBackgroundFetcher];
}

- (void)exitApp {
  [[NSRunningApplication currentApplication] terminate];
}

@end
