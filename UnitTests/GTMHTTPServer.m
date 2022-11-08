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

#import <TargetConditionals.h>

#if !TARGET_OS_WATCH

#if !defined(__has_feature) || !__has_feature(objc_arc)
#error "This file requires ARC support."
#endif

//
//  Based a little on HTTPServer, part of the CocoaHTTPServer sample code
//  http://developer.apple.com/samplecode/CocoaHTTPServer/index.html
//

#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#define GTMHTTPSERVER_DEFINE_GLOBALS
#import "GTMHTTPServer.h"

#ifndef GTMHTTPSERVER_LOG_VERBOSE
#define GTMHTTPSERVER_LOG_VERBOSE 0
#endif

// keys for our connection dictionaries
static NSString *kInputStream = @"InputStream";
static NSString *kOutputStream = @"OutputStream";
static NSString *kRequest = @"Request";
static NSString *kResponse = @"Response";
static NSString *kResponseOffset = @"ResponseOffset";

@interface GTMChunkReader : NSObject
@property(nonatomic, readonly, getter=isComplete) BOOL complete;
@property(nonatomic, readonly) NSData *accumulatedData;
@end

@implementation GTMChunkReader {
  int64_t _chunkLengthToRead;
  NSMutableData *_accumulatedData;
}

@synthesize accumulatedData = _accumulatedData;

- (instancetype)init {
  self = [super init];
  if (self) {
    _accumulatedData = [[NSMutableData alloc] init];
  }
  return self;
}

- (BOOL)isComplete {
  return _chunkLengthToRead == -1;
}

- (BOOL)writeData:(NSData *)data {
  // Format reference: http://en.wikipedia.org/wiki/Chunked_transfer_encoding
  if ([self isComplete]) {
    NSAssert(NO, @"Chunk already written");
    return NO;
  }
  const char *charPtrBegin = data.bytes;
  const char *charPtrEnd = charPtrBegin + data.length;
  for (const char *charPtr = charPtrBegin; charPtrBegin < charPtrEnd; charPtrBegin = charPtr) {
    if (_chunkLengthToRead == 0) {
      // charPtr should now point to the next chunk length, delimited by \r\n.
      // Search for the delimiter character and verify the delimited sequence.
      for (;;) {
        // Found the delimiter character, ending the chunk length.
        if (*charPtr == '\r') {
          charPtr++;
          // Confirm the expected delimiter sequence.
          if ((charPtr == charPtrEnd) || (*charPtr++ != '\n')) {
            NSAssert(NO, @"Newline expected after carriage return");
            return NO;
          }
          if ((charPtr - charPtrBegin) == 2) {
            // Happens when a block's footer ends up in the next NSData.
            break;
          }
          _chunkLengthToRead = strtol(charPtrBegin, NULL, 16);
          if (_chunkLengthToRead == 0) {
            // Found last chunk, denoted by a 0 length.
            _chunkLengthToRead = -1;
            return YES;
          }
          break;
        }
        // Chunk length should only include hex digits.
        if (!ishexnumber(*charPtr)) {
          NSAssert(NO, @"Invalid hex character found in parsing chunk length");
          return NO;
        }
        // Shouldn't hit the end of chunk without encountering the delimited sequence.
        charPtr++;
        if (charPtr == charPtrEnd) {
          NSAssert(NO, @"Carriage return expected to delimit chunk length");
          return NO;
        }
      }
      if (_chunkLengthToRead == 0) {
        // Just found the footer, so jump to beginning to find next header.
        continue;
      }
    }
    long dataLengthRemaining = charPtrEnd - charPtr;
    // Just append the remaining characters if the current chunk exceeds the extent of data.
    if (_chunkLengthToRead >= dataLengthRemaining) {
      [_accumulatedData appendBytes:charPtr length:(NSUInteger)dataLengthRemaining];
      _chunkLengthToRead -= dataLengthRemaining;
      return YES;
    }
    // Append the remaining characters in the current chunk,
    // which should position charPtr at the \r\n footer for this chunk.
    [_accumulatedData appendBytes:charPtr length:(NSUInteger)_chunkLengthToRead];
    charPtr += _chunkLengthToRead;
    _chunkLengthToRead = 0;
    if (*charPtr++ != '\r') {
      NSAssert(NO, @"Expected trailing carriage return");
      return NO;
    }
    if ((charPtr == charPtrEnd) || (*charPtr++ != '\n')) {
      NSAssert(NO, @"Expected trailing newline after carriage return");
      return NO;
    }
  }
  return YES;
}

@end

@interface GTMHTTPRequestMessage ()
- (BOOL)isComplete;
- (BOOL)appendData:(NSData *)data;
- (int64_t)contentLength;
- (void)setBody:(NSData *)body;
@end

@interface GTMHTTPResponseMessage ()
- (NSData *)serializedData;
@end

@interface GTMHTTPServer () <NSStreamDelegate>

@property(nonatomic, readonly) CFSocketRef socket;

- (void)acceptConnection:(int)fd;

@end

static void AcceptCallback(CFSocketRef socket, CFSocketCallBackType callBackType, CFDataRef address,
                           const void *data, void *info) {
  NSCAssert(callBackType == kCFSocketAcceptCallBack, @"Unexpected callBackType: %lu", callBackType);
  NSCAssert(data != NULL, @"Unexpected NULL data, socket wasn't included in callback");

  GTMHTTPServer *server = (__bridge GTMHTTPServer *)info;
  NSCAssert(server != nil, @"Expected a valid GTMHTTPServer in info");
  NSCAssert(socket == server.socket, @"Callback socket does not match server's socket");

  [server acceptConnection:*(int *)data];
}

@implementation GTMHTTPServer {
  id<GTMHTTPServerDelegate> __weak _delegate;
  uint16_t _port;
  CFSocketRef _socket;
  CFRunLoopSourceRef _runLoopSource;
  NSMutableArray *_connections;
}

@synthesize delegate = _delegate;
@synthesize port = _port;
@synthesize socket = _socket;

+ (instancetype)startedServerWithDelegate:(id<GTMHTTPServerDelegate>)delegate {
  GTMHTTPServer *server = [(GTMHTTPServer *)[self alloc] initWithDelegate:delegate];
  NSError *error = nil;
  if (![server start:&error]) {
    NSLog(@"Failed to start up %@ (error=%@)", NSStringFromClass(self), error);
    return nil;
  }
#if GTMHTTPSERVER_LOG_VERBOSE
  NSLog(@"Started up %@ on port %d", NSStringFromClass(self), server.port);
#endif
  return server;
}

- (instancetype)init {
  return [self initWithDelegate:nil];
}

- (instancetype)initWithDelegate:(id<GTMHTTPServerDelegate>)delegate {
  self = [super init];
  if (self) {
    if (!delegate) {
      return nil;
    }
    _delegate = delegate;
    _connections = [[NSMutableArray alloc] init];
  }
  return self;
}

- (void)dealloc {
  [self stop];
}

- (BOOL)start:(NSError *__autoreleasing *)error {
  NSAssert(_socket == NULL, @"start called when we already have a _socket");

  if (error) *error = NULL;

  const int kDefaultProtocol = 0;
  __block int fd = socket(AF_INET6, SOCK_STREAM, kDefaultProtocol);

  void (^startFailed)(NSInteger) = ^(NSInteger startFailureCode) {
    if (error) {
      *error = [[NSError alloc] initWithDomain:kGTMHTTPServerErrorDomain
                                          code:startFailureCode
                                      userInfo:nil];
    }
    if (fd > 0) {
      close(fd);
      fd = 0;
    }
  };

  if (fd <= 0) {
    // COV_NF_START - we'd need to use up *all* sockets to test this?
    startFailed(kGTMHTTPServerSocketCreateFailedError);
    return NO;
    // COV_NF_END
  }

  // Set socket options
  int status = fcntl(fd, F_SETFL, O_NONBLOCK);
  if (status == -1) {
    NSLog(@"failed to enable non-blocking IO");
  }

  // enable address reuse quicker after we are done w/ our socket
  int yes = 1;
  int sock_opt = SO_REUSEADDR;
  if (setsockopt(fd, SOL_SOCKET, sock_opt, (void *)&yes, (socklen_t)sizeof(yes)) != 0) {
    NSLog(@"failed to mark the socket as reusable");  // COV_NF_LINE
  }

  // bind
  struct sockaddr_in6 addr;
  memset(&addr, 0, sizeof(addr));
  addr.sin6_len = sizeof(addr);
  addr.sin6_family = AF_INET6;
  addr.sin6_port = htons(_port);

  // localhost-only
  addr.sin6_addr = in6addr_loopback;

  if (bind(fd, (struct sockaddr *)(&addr), (socklen_t)sizeof(addr)) != 0) {
    startFailed(kGTMHTTPServerBindFailedError);
    return NO;
  }

  // collect the port back out
  if (_port == 0) {
    socklen_t len = (socklen_t)sizeof(addr);
    if (getsockname(fd, (struct sockaddr *)(&addr), &len) == 0) {
      _port = ntohs(addr.sin6_port);
    }
  }

  // tell it to listen for connections
  const int kMaxPendingConnections = 5;
  if (listen(fd, kMaxPendingConnections) != 0) {
    // COV_NF_START
    startFailed(kGTMHTTPServerListenFailedError);
    return NO;
  }

  CFSocketContext context = {0, (__bridge void *)self, NULL, NULL, NULL};
  _socket = CFSocketCreateWithNative(kCFAllocatorDefault, fd, kCFSocketAcceptCallBack,
                                     AcceptCallback, &context);
  if (_socket == NULL) {
    startFailed(kGTMHTTPServerCFSocketCreateFailedError);
    return NO;
  }

  _runLoopSource = CFSocketCreateRunLoopSource(kCFAllocatorDefault, _socket, 0);
  NSAssert(_runLoopSource, @"Failed to create CFRunLoopSourceRef");
  CFRunLoopAddSource(CFRunLoopGetCurrent(), _runLoopSource, kCFRunLoopDefaultMode);

  return YES;
}

- (void)acceptConnection:(int)fd {
  CFReadStreamRef readStream;
  CFWriteStreamRef writeStream;
  CFStreamCreatePairWithSocket(kCFAllocatorDefault, fd, &readStream, &writeStream);
  NSInputStream *inputStream = CFBridgingRelease(readStream);
  [inputStream setProperty:(id)kCFBooleanTrue
                    forKey:(NSString *)kCFStreamPropertyShouldCloseNativeSocket];
  inputStream.delegate = self;
  [inputStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
  [inputStream open];

  NSOutputStream *outputStream = CFBridgingRelease(writeStream);
  outputStream.delegate = self;
  // Defer opening and scheduling on run loop until we have a response to write to it.

  NSMutableDictionary *connDict = [NSMutableDictionary dictionary];
  connDict[kInputStream] = inputStream;
  connDict[kOutputStream] = outputStream;
  GTMHTTPRequestMessage *request = [[GTMHTTPRequestMessage alloc] init];
  connDict[kRequest] = request;
  [_connections addObject:connDict];
}

- (void)stop {
  while (_connections.count > 0) {
    NSMutableDictionary *connDict = _connections.lastObject;
    [self closeConnection:connDict];
  }
  if (_runLoopSource) {
    CFRunLoopRemoveSource(CFRunLoopGetCurrent(), _runLoopSource, kCFRunLoopDefaultMode);
    CFRelease(_runLoopSource);
    _runLoopSource = NULL;
  }
  if (_socket) {
    CFSocketInvalidate(_socket);
    CFRelease(_socket);
    _socket = NULL;
  }
}

- (NSUInteger)activeRequestCount {
  return _connections.count;
}

- (NSString *)description {
  NSString *result = [NSString stringWithFormat:@"%@<%p>{ port=%d status=%@ }", [self class], self,
                                                _port, (_socket != NULL ? @"Started" : @"Stopped")];
  return result;
}

#pragma mark - NSStreamDelegate

- (void)stream:(NSStream *)aStream handleEvent:(NSStreamEvent)eventCode {
  NSMutableDictionary *connDict = [self lookupConnection:aStream];
  if (connDict == nil) return;  // we are no longer tracking this one

  switch (eventCode) {
    case NSStreamEventNone:
      NSAssert(NO, @"Unexpected none event sent to stream");
      break;
    case NSStreamEventOpenCompleted:
      break;
    case NSStreamEventHasBytesAvailable: {
      NSInputStream *inputStream = connDict[kInputStream];
      NSAssert(aStream == inputStream, @"Unexpected output stream has bytes");

      enum EnumType : NSUInteger { kMaxReadDataChunkSize = 32768 };
      NSMutableData *readData = [[NSMutableData alloc] init];
      uint8_t readDataBytes[kMaxReadDataChunkSize];
      NSInteger readDataSize = [inputStream read:readDataBytes maxLength:kMaxReadDataChunkSize];
      if (readDataSize == -1) {
        NSLog(@"..Read stream error = %@", [aStream streamError]);
        [self closeConnection:connDict];
        return;
      }
      if (readDataSize == 0) {
        // remote side closed
        [self closeReadConnection:connDict];
        return;
      }
      [readData appendBytes:readDataBytes length:(NSUInteger)readDataSize];

      @try {
        GTMHTTPRequestMessage *request = connDict[kRequest];
        [request appendData:readData];

        // Is the request complete yet?
        if ([request isComplete]) {
          [self closeReadConnection:connDict];
          GTMHTTPResponseMessage *response = nil;
          @try {
            // Off to the delegate
            response = [_delegate httpServer:self handleRequest:request];
          } @catch (NSException *e) {
            NSLog(@"Exception trying to handle http request: %@", e);
          }  // COV_NF_LINE - radar 5851992 only reachable w/ an uncaught exception, un-testable

          if (!response) {
            // No response, shut it down
            NSLog(@"..No applicable response, so closing connection");
            [self closeConnection:connDict];
          } else {
            // We don't support connection reuse,
            // so we add (force) the header to close every connection.
            [response setValue:@"close" forHeaderField:@"Connection"];
            connDict[kResponse] = [response serializedData];
            connDict[kResponseOffset] = @0;
            NSOutputStream *outputStream = connDict[kOutputStream];
            [outputStream scheduleInRunLoop:[NSRunLoop currentRunLoop]
                                    forMode:NSDefaultRunLoopMode];
            [outputStream open];
          }
        }
      } @catch (NSException *e) {  // COV_NF_START
        NSLog(@"exception while read data: %@", e);
        // exception while dealing with the connection, close it
      }  // COV_NF_END
      break;
    }
    case NSStreamEventHasSpaceAvailable: {
      NSOutputStream *outputStream = connDict[kOutputStream];
      NSAssert(aStream == outputStream, @"Unexpected input stream has space");

      // Slow the test server down; otherwise, downloads usually happen to fast to cancel.
      dispatch_async(dispatch_get_main_queue(), ^{
        NSNumber *responseOffset = connDict[kResponseOffset];
        NSUInteger offset = [responseOffset unsignedIntegerValue];
        NSData *response = connDict[kResponse];
        NSUInteger responseLength = response.length;
        if (offset >= responseLength) {
          [self closeConnection:connDict];
          return;
        }
        NSUInteger kMaxWriteDataChunkSize = 32768;
        const uint8_t *buffer = response.bytes;
        NSUInteger maxLength = MIN((responseLength - offset), kMaxWriteDataChunkSize);
        NSInteger bytesWritten = [outputStream write:&buffer[offset] maxLength:maxLength];
        if (bytesWritten == -1) {
          [self closeConnection:connDict];
          return;
        }
        offset += (NSUInteger)bytesWritten;
        connDict[kResponseOffset] = @(offset);
      });
      break;
    }
    case NSStreamEventErrorOccurred:
      NSLog(@"..stream error = %@", [aStream streamError]);
      break;
    case NSStreamEventEndEncountered:
      NSLog(@"..End of stream encountered");
      break;
  }
}

#pragma mark - Private

- (NSMutableDictionary *)lookupConnection:(NSStream *)aStream {
  for (NSMutableDictionary *connDict in _connections) {
    if (aStream == connDict[kInputStream]) {
      return connDict;
    }
    if (aStream == connDict[kOutputStream]) {
      return connDict;
    }
  }
  return nil;
}

- (void)closeReadConnection:(NSMutableDictionary *)connDict {
  NSInputStream *inputStream = connDict[kInputStream];
  inputStream.delegate = nil;
  [inputStream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
  [inputStream close];
}

- (void)closeWriteConnection:(NSMutableDictionary *)connDict {
  NSOutputStream *outputStream = connDict[kOutputStream];
  outputStream.delegate = nil;
  [outputStream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
  [outputStream close];
}

- (void)closeConnection:(NSMutableDictionary *)connDict {
  [self closeReadConnection:connDict];
  [self closeWriteConnection:connDict];
  [_connections removeObjectIdenticalTo:connDict];
}

@end

@implementation GTMHTTPRequestMessage {
  CFHTTPMessageRef _message;
  GTMChunkReader *_chunkReader;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _message = CFHTTPMessageCreateEmpty(kCFAllocatorDefault, YES);
  }
  return self;
}

- (void)dealloc {
  if (_message) {
    CFRelease(_message);
  }
}

- (NSString *)version {
  return CFBridgingRelease(CFHTTPMessageCopyVersion(_message));
}

- (NSURL *)URL {
  return CFBridgingRelease(CFHTTPMessageCopyRequestURL(_message));
}

- (NSString *)method {
  return CFBridgingRelease(CFHTTPMessageCopyRequestMethod(_message));
}

- (NSData *)body {
  return CFBridgingRelease(CFHTTPMessageCopyBody(_message));
}

- (NSDictionary *)allHeaderFieldValues {
  return CFBridgingRelease(CFHTTPMessageCopyAllHeaderFields(_message));
}

- (NSString *)description {
  CFStringRef desc = CFCopyDescription(_message);
  NSString *result = [NSString stringWithFormat:@"%@<%p>{ message=%@ }", [self class], self, desc];
  CFRelease(desc);
  return result;
}

#pragma mark - Private

- (BOOL)isComplete {
  if (![self isHeaderComplete]) {
    return NO;
  }
  if (_chunkReader != nil) {
    return NO;
  }
  int64_t contentLength = [self contentLength];
  if (contentLength == 0) {
    return YES;
  }
  NSData *body = self.body;
  NSUInteger bodyLength = body.length;
  if (contentLength > (int64_t)bodyLength) {
    return NO;
  }
  return YES;
}

- (BOOL)isHeaderComplete {
  // Convert type Boolean to BOOL when returning.
  return CFHTTPMessageIsHeaderComplete(_message) ? YES : NO;
}

- (BOOL)appendData:(NSData *)data {
  CFIndex dataLength = (CFIndex)data.length;
  if (dataLength == 0) {
    return NO;
  }
  // If currently processing a Chunked encode, then continue processing it.
  if ([self isHeaderComplete] && (_chunkReader != nil)) {
    if (![_chunkReader writeData:data]) {
      return NO;
    }
  } else {
    // Not currently handling a Chunked encode, so pass data to system handler.
    Boolean didAppend = CFHTTPMessageAppendBytes(_message, data.bytes, (CFIndex)data.length);
    NSAssert(didAppend, @"Failed to append bytes to request message");
    if (!didAppend) {
      return NO;
    }
    if ([self isHeaderComplete]) {
      // Header is complete. Check if this is a Chunked encode.
      NSData *body = self.body;
      if ([self isChunked]) {
        _chunkReader = [[GTMChunkReader alloc] init];
        if (body != nil) {
          [self setBody:nil];
          if (![_chunkReader writeData:body]) {
            return NO;
          }
        }
      } else {
        int64_t contentLength = [self contentLength];
        NSUInteger bodyLength = body.length;
        if (contentLength < (int64_t)bodyLength) {
          // We got extra (probably someone trying to pipeline on us), trim the extra data.
          NSData *newBody = [NSData dataWithBytes:body.bytes length:(NSUInteger)contentLength];
          [self setBody:newBody];
          NSLog(@"Got %lu extra bytes on http request, ignoring them",
                (unsigned long)(bodyLength - (unsigned long)contentLength));
        }
      }
    }
  }
  // Chunked encode received in its entirety, so make it the body of the message.
  if (_chunkReader.isComplete) {
    [self setBody:_chunkReader.accumulatedData];
    _chunkReader = nil;
  }
  return YES;
}

- (NSString *)headerFieldValueForKey:(NSString *)key {
  CFStringRef value = NULL;
  if (key) {
    value = CFHTTPMessageCopyHeaderFieldValue(_message, (__bridge CFStringRef)key);
  }
  return CFBridgingRelease(value);
}

- (int64_t)contentLength {
  return (int64_t)[[self headerFieldValueForKey:@"Content-Length"] longLongValue];
}

- (BOOL)isChunked {
  NSString *value = [self headerFieldValueForKey:@"Transfer-Encoding"];
  if (value == nil) {
    return NO;
  }
  return [value caseInsensitiveCompare:@"Chunked"] == NSOrderedSame;
}

- (void)setBody:(NSData *)body {
  if (!body) {
    body = [NSData data];  // COV_NF_LINE - can only happen if we fail to make the new data object
  }
  CFHTTPMessageSetBody(_message, (__bridge CFDataRef)body);
}

@end

@implementation GTMHTTPResponseMessage {
  CFHTTPMessageRef _message;
}

- (instancetype)init {
  return [self initWithBody:nil contentType:nil statusCode:0];
}

- (void)dealloc {
  if (_message) {
    CFRelease(_message);
  }
}

+ (instancetype)responseWithString:(NSString *)plainText {
  NSData *body = [plainText dataUsingEncoding:NSUTF8StringEncoding];
  return [self responseWithBody:body contentType:@"text/plain; charset=UTF-8" statusCode:200];
}

+ (instancetype)responseWithHTMLString:(NSString *)htmlString {
  return [self responseWithBody:[htmlString dataUsingEncoding:NSUTF8StringEncoding]
                    contentType:@"text/html; charset=UTF-8"
                     statusCode:200];
}

+ (instancetype)responseWithBody:(NSData *)body
                     contentType:(NSString *)contentType
                      statusCode:(int)statusCode {
  return [[self alloc] initWithBody:body contentType:contentType statusCode:statusCode];
}

+ (instancetype)emptyResponseWithCode:(int)statusCode {
  return [[self alloc] initWithBody:nil contentType:nil statusCode:statusCode];
}

+ (instancetype)redirectResponseWithRedirectURL:(NSURL *)redirectURL {
  GTMHTTPResponseMessage *response = [[self alloc] initWithBody:nil contentType:nil statusCode:302];
  [response setValue:[redirectURL absoluteString] forHeaderField:@"Location"];
  return response;
}

- (int)statusCode {
  return (int)CFHTTPMessageGetResponseStatusCode(_message);
}

- (NSData *)body {
  NSData *body = CFBridgingRelease(CFHTTPMessageCopyBody(_message));
  return body;
}

- (void)setBody:(NSData *)body {
  NSAssert(body != nil, @"Invalid response body");
  NSUInteger bodyLength = body.length;
  CFHTTPMessageSetBody(_message, (__bridge CFDataRef)body);
  NSString *bodyLenStr = [NSString stringWithFormat:@"%lu", (unsigned long)bodyLength];
  [self setValue:bodyLenStr forHeaderField:@"Content-Length"];
}

- (void)setValue:(NSString *)value forHeaderField:(NSString *)headerField {
  if (headerField.length == 0) return;
  if (value == nil) {
    value = @"";
  }
  CFHTTPMessageSetHeaderFieldValue(_message, (__bridge CFStringRef)headerField,
                                   (__bridge CFStringRef)value);
}

- (void)setHeaderValuesFromDictionary:(NSDictionary *)dict {
  for (id key in dict) {
    id value = dict[key];
    [self setValue:value forHeaderField:key];
  }
}

- (NSString *)description {
  CFStringRef desc = CFCopyDescription(_message);
  NSString *result = [NSString stringWithFormat:@"%@<%p>{ message=%@ }", [self class], self, desc];
  CFRelease(desc);
  return result;
}

#pragma mark - Private

- (instancetype)initWithBody:(NSData *)body
                 contentType:(NSString *)contentType
                  statusCode:(int)statusCode {
  self = [super init];
  if (self) {
    if ((statusCode < 100) || (statusCode > 599)) {
      return nil;
    }
    _message =
        CFHTTPMessageCreateResponse(kCFAllocatorDefault, statusCode, NULL, kCFHTTPVersion1_1);
    if (!_message) {
      // COV_NF_START
      return nil;
      // COV_NF_END
    }
    if (body) {
      self.body = body;
      if (contentType.length == 0) {
        contentType = @"text/html";
      }
      [self setValue:contentType forHeaderField:@"Content-Type"];
    }
  }
  return self;
}

- (NSData *)serializedData {
  return CFBridgingRelease(CFHTTPMessageCopySerializedMessage(_message));
}

@end

#endif  // !TARGET_OS_WATCH
