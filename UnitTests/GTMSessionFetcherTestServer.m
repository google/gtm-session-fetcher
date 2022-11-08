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

#import "GTMSessionFetcherTestServer.h"

#import <CommonCrypto/CommonDigest.h>

#import "GTMHTTPServer.h"

static NSString *const kEtag = @"GoodETag";

@interface NSString (GTMHTTPAuthorization)

- (BOOL)hasCaseInsensitivePrefix:(NSString *)prefix;
- (NSString *)stringByTrimmingWhitespace;
- (NSDictionary *)allDigestAuthorizationHeaderFields;
- (NSString *)MD5DigestString;
- (NSString *)base64DecodedString;

@end

@implementation NSString (GTMHTTPAuthorization)

- (BOOL)hasCaseInsensitivePrefix:(NSString *)prefix {
  NSUInteger prefixLength = prefix.length;
  if (self.length < prefixLength) return NO;

  NSComparisonResult hasPrefixResult = [self compare:prefix
                                             options:NSCaseInsensitiveSearch
                                               range:NSMakeRange(0, prefixLength)];
  return hasPrefixResult == NSOrderedSame;
}

- (NSString *)stringByTrimmingWhitespace {
  NSCharacterSet *whitespaceCharacterSet = [NSCharacterSet whitespaceCharacterSet];
  NSString *trimmedString = [self stringByTrimmingCharactersInSet:whitespaceCharacterSet];
  return trimmedString;
}

- (NSDictionary *)allDigestAuthorizationHeaderFields {
  // For an example, refer to http://en.wikipedia.org/wiki/Digest_access_authentication
  // Authorization: Digest username="Mufasa",
  //                       realm="testrealm@host.com",
  //                       nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093",
  //                       uri="/dir/index.html",
  //                       qop=auth,
  //                       nc=00000001,
  //                       cnonce="0a4f113b",
  //                       response="6629fae49393a05397450978507c4ef1"
  NSMutableDictionary *headerFields = [NSMutableDictionary dictionary];
  NSScanner *scanner = [NSScanner scannerWithString:self];

  NSString *key = nil;
  NSString *value = nil;
  NSString *const kKeyValueDelimiter = @"=";
  NSString *const kValueQuote = @"\"";
  NSString *const kHeaderFieldDelimiter = @",";

  // Specifically setting whitespace skip character set, since it needs to be disabled when
  // scanning value fields that include ""'s.
  NSCharacterSet *whitespaceCharacterSet = [NSCharacterSet whitespaceAndNewlineCharacterSet];
  [scanner setCharactersToBeSkipped:whitespaceCharacterSet];
  for (;;) {
    [scanner scanUpToString:kKeyValueDelimiter intoString:&key];
    if (![scanner scanString:kKeyValueDelimiter intoString:NULL]) {
      // No more keys found.
      break;
    }
    // Skip value leading whitespace, checking for "
    [scanner scanCharactersFromSet:whitespaceCharacterSet intoString:NULL];
    if ([scanner scanString:kValueQuote intoString:NULL]) {
      // Scan to closing quote and don't skip whitespace, since value is in quotes.
      [scanner setCharactersToBeSkipped:nil];
      if (![scanner scanUpToString:kValueQuote intoString:&value]) {
        // No value found.
        break;
      }
      // Revert whitespace skipping.
      [scanner setCharactersToBeSkipped:whitespaceCharacterSet];
      // Scan to field delimiter
      [scanner scanUpToString:kHeaderFieldDelimiter intoString:NULL];
    } else {
      // Scan value to field delimiter. Assumes no delimiter in value without quotes.
      if (![scanner scanUpToString:kHeaderFieldDelimiter intoString:&value]) {
        // No value found.
        break;
      }
    }
    [headerFields setObject:value forKey:key];
    // Skip field delimiter
    [scanner scanString:kHeaderFieldDelimiter intoString:NULL];
  }
  return headerFields;
}

- (NSString *)MD5DigestString {
  NSData *data = [self dataUsingEncoding:NSUTF8StringEncoding];

  unsigned char MD5Digest[CC_MD5_DIGEST_LENGTH];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  // MD5 is deprecated in the iOS 13/OSX 10.15 headers, but is the explicit hash used for digest
  // authentication, used here only for tests.
  CC_MD5(data.bytes, (CC_LONG)data.length, MD5Digest);
#pragma clang diagnostic pop
  NSMutableString *MD5DigestString = [NSMutableString stringWithCapacity:2 * CC_MD5_DIGEST_LENGTH];
  for (int i = 0; i < CC_MD5_DIGEST_LENGTH; ++i) {
    [MD5DigestString appendFormat:@"%02x", (unsigned int)MD5Digest[i]];
  }
  return MD5DigestString;
}

- (NSString *)base64DecodedString {
  NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:self options:0];
  NSString *decodedString = [[NSString alloc] initWithData:decodedData
                                                  encoding:NSUTF8StringEncoding];
  return decodedString;
}

@end

@interface GTMSessionFetcherTestServer () <GTMHTTPServerDelegate>
@end

@implementation GTMSessionFetcherTestServer {
  GTMHTTPServer *_server;
  GTMHTTPServer *_redirectServer;
  GTMHTTPAuthenticationType _httpAuthenticationType;
  GTMHTTPAuthenticationType _lastHTTPAuthenticationType;
  NSDictionary<NSString *, NSData *> *_resourceMap;
  NSString *_username;
  NSString *_password;
  NSString *_nonce;
  long long _uploadBytesExpected;
  long long _uploadBytesReceived;
}

@synthesize defaultContentType = _defaultContentType,
            lastHTTPAuthenticationType = _lastHTTPAuthenticationType;

- (instancetype)init {
  self = [super init];
  if (self) {
    _server = [GTMHTTPServer startedServerWithDelegate:self];
    if (!_server) return nil;

    _defaultContentType = @"text/plain";

    NSString *gettysburg =
        @"Four score and seven years ago our fathers brought forth on this continent, a"
         " new nation, conceived in liberty, and dedicated to the proposition that all men"
         " are created equal.";
    NSString *empty = [[NSString alloc] init];
    _resourceMap = @{
      @"gettysburgaddress.txt" : (NSData *)[gettysburg dataUsingEncoding:NSUTF8StringEncoding],
      @"empty.txt" : (NSData *)[empty dataUsingEncoding:NSUTF8StringEncoding]
    };

    _uploadBytesExpected = -1;
#if GTMHTTPSERVER_LOG_VERBOSE
    NSLog(@"Started GTMSessionFetcherTestServer");
#endif
  }
  return self;
}

- (void)dealloc {
  [self stopServers];
}

- (BOOL)isRedirectEnabled {
  return _redirectServer != nil;
}

- (void)setRedirectEnabled:(BOOL)isRedirectEnabled {
  if ([self isRedirectEnabled] == isRedirectEnabled) return;

  if (isRedirectEnabled) {
    if (_server) {
      _redirectServer = [GTMHTTPServer startedServerWithDelegate:self];
      if (_redirectServer) {
#if GTMHTTPSERVER_LOG_VERBOSE
        NSLog(@"Started redirect target server");
#endif
      }
    }
  } else {
    _redirectServer = nil;
  }
}

- (void)setHTTPAuthenticationType:(GTMHTTPAuthenticationType)authenticationType
                         username:(NSString *)username
                         password:(NSString *)password {
  _httpAuthenticationType = authenticationType;
  _username = [username copy];
  _password = [password copy];
}

- (void)clearHTTPAuthentication {
  _httpAuthenticationType = kGTMHTTPAuthenticationTypeInvalid;
}

- (NSURL *)localURLForFile:(NSString *)name {
  NSString *urlString = [NSString stringWithFormat:@"http://localhost:%d/%@", _server.port, name];
  return [NSURL URLWithString:urlString];
}

- (NSURL *)localv6URLForFile:(NSString *)name {
  NSString *urlString = [NSString stringWithFormat:@"http://[::1]:%d/%@", _server.port, name];
  return [NSURL URLWithString:urlString];
}

- (NSData *)documentDataAtPath:(NSString *)requestPath {
  if ([requestPath hasPrefix:@"/"]) {
    requestPath = [requestPath substringFromIndex:1];
  }
  return _resourceMap[requestPath];
}

+ (NSString *)JSONBodyStringForStatus:(NSInteger)code {
  NSString *const template =
      @"{ \"error\" : { \"message\" : \"Server Status %d\", \"code\" : %d } }";
  NSString *bodyStr = [NSString stringWithFormat:template, (int)code, (int)code];
  return bodyStr;
}

+ (NSData *)generatedBodyDataWithLength:(NSUInteger)length {
  // Fill an NSData.
  NSMutableData *data = [NSMutableData dataWithLength:length];

  unsigned char *bytes = data.mutableBytes;
  for (NSUInteger idx = 0; idx < length; idx++) {
    bytes[idx] = (unsigned char)((idx + 1) % 256);
  }
  return data;
}

- (GTMHTTPAuthenticationType)lastHTTPAuthenticationType {
  return _lastHTTPAuthenticationType;
}

#pragma mark - GTMHTTPServerDelegate

- (GTMHTTPResponseMessage *)httpServer:(GTMHTTPServer *)server
                         handleRequest:(GTMHTTPRequestMessage *)request {
  NSAssert((server == _server) || (server == _redirectServer),
           @"How'd we get a different server?!");

  NSMutableDictionary *responseHeaders = [NSMutableDictionary dictionary];

  GTMHTTPResponseMessage * (^sendResponse)(int, NSData *, NSString *) =
      ^(int status, NSData *data, NSString *contentType) {
        NSAssert(status > 0, @"%d", status);
        GTMHTTPResponseMessage *response = [GTMHTTPResponseMessage responseWithBody:data
                                                                        contentType:contentType
                                                                         statusCode:status];
        [response setHeaderValuesFromDictionary:responseHeaders];
        return response;
      };

  _lastHTTPAuthenticationType = kGTMHTTPAuthenticationTypeInvalid;

  NSURL *requestURL = request.URL;
  NSString *requestPath = requestURL.path;
  NSString *requestPathExtension = [requestPath pathExtension];
  NSString *query = [requestURL query];
  NSData *requestBodyData = request.body;
  NSString *requestMethod = request.method;

  NSDictionary *requestHeaders = [request allHeaderFieldValues];
  NSString *contentLengthStr = requestHeaders[@"Content-Length"];
  NSString *ifMatch = requestHeaders[@"If-Match"];
  NSString *ifNoneMatch = requestHeaders[@"If-None-Match"];
  NSString *rangeHeader = requestHeaders[@"Range"];
  NSString *authorization = requestHeaders[@"Authorization"];
  NSString *cookies = requestHeaders[@"Cookie"];
  NSString *host = requestHeaders[@"Host"];

  // Upload protocol headers defined by Google's upload protocol server.
  NSString *xUploadProtocol = requestHeaders[@"X-Goog-Upload-Protocol"];
  NSString *xUploadCommand = requestHeaders[@"X-Goog-Upload-Command"];
  NSString *xUploadContentType = requestHeaders[@"X-Goog-Upload-Content-Type"];
  NSString *xUploadContentLength = requestHeaders[@"X-Goog-Upload-Content-Length"];
  NSString *xUploadOffset = requestHeaders[@"X-Goog-Upload-Offset"];

  // Headers and parameters defined by the Obj-C resumable upload unit tests.
  NSString *uploadGranularityRequest = requestHeaders[@"GTM-Upload-Granularity-Request"];
  NSString *uploadBytesReceivedRequest = [[self class] valueForParameter:@"bytesReceived"
                                                                   query:query];
  NSString *uploadQueryStatus = [[self class] valueForParameter:@"queryStatus" query:query];

  NSString *statusStr = [[self class] valueForParameter:@"status" query:query];
  if (statusStr) {
    // queries that have something like "?status=456" should fail with the status code
    int resultStatus = [statusStr intValue];
    NSString *errorStr = [[self class] JSONBodyStringForStatus:resultStatus];
    NSData *data = [errorStr dataUsingEncoding:NSUTF8StringEncoding];
    return sendResponse(resultStatus, data, @"application/json");
  }

  // Echo request headers in response.
  NSString *echoHeadersStr = [[self class] valueForParameter:@"echo-headers" query:query];
  if (echoHeadersStr.boolValue) {
    NSError *jsonError;
    NSData *data = [NSJSONSerialization dataWithJSONObject:requestHeaders
                                                   options:0
                                                     error:&jsonError];
    if (jsonError) {
      NSLog(@"Error creating JSON data from HTTP request headers: %@", jsonError);
      return sendResponse(500, nil, nil);
    } else {
      return sendResponse(200, data, @"application/json");
    }
  }

  // Chunked (resumable) upload testing: initial location request.
  if ([requestPathExtension isEqual:@"location"]) {
    // This is a request for the upload location URI.
    _uploadBytesReceived = 0;

    BOOL isGet = ([requestMethod caseInsensitiveCompare:@"GET"] == NSOrderedSame);
    if (isGet) {
      NSLog(@"Uploads must be PUT or POST.");
      return sendResponse(503, nil, nil);
    }

    BOOL isResumable = [xUploadProtocol isEqual:@"resumable"];
    BOOL isStartingUpload = [xUploadCommand isEqual:@"start"];
    BOOL hasContentType = xUploadContentType.length > 0;
    if (!isResumable || !isStartingUpload || !hasContentType) {
      NSLog(@"Missing expected upload header.");
      return sendResponse(503, nil, nil);
    }

    _uploadBytesExpected = [xUploadContentLength longLongValue];

    // Return a location header containing the request path with
    // the ".location" suffix changed to ".upload".
    NSString *pathWithoutLoc = [requestPath stringByDeletingPathExtension];
    NSString *fullLocation =
        [NSString stringWithFormat:@"http://%@%@.upload", host, pathWithoutLoc];

    responseHeaders[@"X-Goog-Upload-URL"] = fullLocation;
    responseHeaders[@"X-Goog-Upload-Control-URL"] = fullLocation;
    responseHeaders[@"X-Goog-Upload-Status"] = @"active";
    if (uploadGranularityRequest.length > 0) {
      responseHeaders[@"X-Goog-Upload-Chunk-Granularity"] = uploadGranularityRequest;
    }

    return sendResponse(200, nil, nil);
  }
  if ([requestPathExtension isEqual:@"upload"]) {
    // Chunked (resumable) upload testing
    BOOL isQueryingOffset = [xUploadCommand isEqual:@"query"];
    BOOL isCancelingUpload = [xUploadCommand isEqual:@"cancel"];
    BOOL isUploadingChunk = ([xUploadCommand rangeOfString:@"upload"].location != NSNotFound);
    BOOL isFinalizeRequest = ([xUploadCommand rangeOfString:@"finalize"].location != NSNotFound);
    NSString *uploadStatus = [[self class] valueForParameter:@"uploadStatus" query:query];

    if (!isQueryingOffset && !isUploadingChunk && !isCancelingUpload && !isFinalizeRequest) {
      // This shouldn't happen.
      NSLog(@"Unexpected command: %@", xUploadCommand);
      return sendResponse(503, nil, nil);
    }

    if (isQueryingOffset) {
      // This is a query for where to resume.
      NSData *queryResponseData;
      if (uploadBytesReceivedRequest.length > 0) {
        _uploadBytesReceived = [uploadBytesReceivedRequest longLongValue];
      }

      if ([uploadQueryStatus isEqual:@"final"]) {
        // Pretend that the upload finished successfully.
        //
        // The upload server does not send Size-Received with the status "final" query response.
        NSString *pathWithoutLoc = [requestPath stringByDeletingPathExtension];
        queryResponseData = [self documentDataAtPath:pathWithoutLoc];
      } else if ([uploadQueryStatus isEqual:@"error"]) {
        // Pretend the query failed on server side.
        return sendResponse(502, nil, nil);
      } else if (uploadQueryStatus.length == 0) {
        // Normally, we'll treat queries as being for uploads that are active.
        responseHeaders[@"X-Goog-Upload-Size-Received"] = [@(_uploadBytesReceived) stringValue];
        uploadQueryStatus = @"active";
      }

      responseHeaders[@"X-Goog-Upload-Status"] = uploadQueryStatus;
      return sendResponse(200, queryResponseData, @"text/plain");
    }

    if (isCancelingUpload) {
      responseHeaders[@"X-Goog-Upload-Status"] = @"cancelled";
      return sendResponse(200, nil, nil);
    }

    if (isUploadingChunk || isFinalizeRequest) {
      BOOL isProperOffset = (_uploadBytesReceived == [xUploadOffset longLongValue]);
      if (!isProperOffset) {
        // This shouldn't happen; a good offset should always be provided.
        NSLog(@"Unexpected offset (specified %@, expected %lld)", xUploadOffset,
              _uploadBytesReceived);
        return sendResponse(503, nil, nil);
      }
      if (uploadStatus != nil) {
        int _uploadStatus = [uploadStatus intValue];
        return sendResponse(_uploadStatus, nil, nil);
      }

      long long contentLength = [contentLengthStr longLongValue];
      _uploadBytesReceived += contentLength;
      BOOL areMoreChunksExpected;
      if (_uploadBytesExpected == -1) {
        // Unknown content length
        areMoreChunksExpected = !isFinalizeRequest;
      } else {
        areMoreChunksExpected = _uploadBytesReceived < _uploadBytesExpected;
      }
      if (areMoreChunksExpected) {
        // More chunks are expected.
        responseHeaders[@"X-Goog-Upload-Status"] = @"active";
        return sendResponse(200, nil, nil);
      }

      // All bytes have now been uploaded.
      if (!isFinalizeRequest) {
        // This shouldn't happen; uploading the final chunk should include a finalize command.
        NSLog(@"Expected finalize command");
        return sendResponse(503, nil, nil);
      }
      // The last chunk has uploaded.
      //
      // Remove the ".upload" at the end and fall through to return the requested resource
      // at the original path.
      requestPath = [requestPath stringByDeletingPathExtension];
      responseHeaders[@"X-Goog-Upload-Status"] = @"final";
    }
  }

  // If there's an "auth=foo" query parameter, then the value of the
  // Authorization header should be "foo"
  NSString *authStr = [[self class] valueForParameter:@"oauth2" query:query];
  if (authStr) {
    NSString *bearerStr = [@"Bearer " stringByAppendingString:authStr];
    if (![authorization isEqual:bearerStr]) {
      // return status 401 Unauthorized
      NSString *errStr = [NSString
          stringWithFormat:@"Authorization \"%@\" should be \"%@\"", authorization, bearerStr];
      NSData *errData = [errStr dataUsingEncoding:NSUTF8StringEncoding];
      return sendResponse(401, errData, @"text/plain");
    }
  }

  if (_httpAuthenticationType != kGTMHTTPAuthenticationTypeInvalid) {
    if ([self isAuthenticatedRequest:request
                             forType:_httpAuthenticationType
                 authorizationHeader:authorization]) {
      _lastHTTPAuthenticationType = _httpAuthenticationType;
    } else {
      NSString *errStr = @"Password protected site requires HTTP Authentication";
      NSData *errData = [errStr dataUsingEncoding:NSUTF8StringEncoding];
      NSString *authenticateHeaderValue =
          [self authenticationHeaderValueWithType:_httpAuthenticationType];
      responseHeaders[@"WWW-Authenticate"] = authenticateHeaderValue;
      return sendResponse(401, errData, @"text/plain");
    }
  }

  NSString *sleepStr = [[self class] valueForParameter:@"sleep" query:query];
  if (sleepStr) {
    NSTimeInterval interval = [sleepStr doubleValue];
    [NSThread sleepForTimeInterval:interval];
    return sendResponse(408, nil, nil);  // request timeout
  }
  if (ifMatch != nil && ![ifMatch isEqual:kEtag]) {
    // there is no match, hence this is an inconsistent PUT or DELETE
    return sendResponse(412, nil, nil);  // precondition failed
  }
  if ([ifNoneMatch isEqual:kEtag]) {
    // there is a match, hence this is a repetitive request
    int resultStatus;
    if ([requestMethod isEqual:@"GET"] || [requestMethod isEqual:@"HEAD"]) {
      resultStatus = 304;  // not modified
    } else {
      resultStatus = 412;  // precondition failed
    }
    return sendResponse(resultStatus, nil, nil);
  }
  if ([requestMethod isEqual:@"DELETE"]) {
    // it's an object delete; return empty data
    return sendResponse(200, nil, nil);
  }

  // Verify that the expected body data was present.
  NSString *bodySequenceLenStr = [[self class] valueForParameter:@"requestBodyLength" query:query];
  if (bodySequenceLenStr) {
    int expectedLen = [bodySequenceLenStr intValue];
    NSData *expectedData = [[self class] generatedBodyDataWithLength:(NSUInteger)expectedLen];
    if (![requestBodyData isEqual:expectedData]) {
      NSLog(@"Mismatched request body data (actual %d bytes, expected %d bytes)",
            (int)requestBodyData.length, expectedLen);
      return sendResponse(500, nil, nil);
    }
  }

  // If requested, generate a response body.
  NSString *responseLengthStr = [[self class] valueForParameter:@"responseBodyLength" query:query];
  if (responseLengthStr) {
    int statusCode = 200;
    int responseLength = [responseLengthStr intValue];
    NSData *responseData = [[self class] generatedBodyDataWithLength:(NSUInteger)responseLength];
    if (rangeHeader) {
      NSString *contentRangeHeader;
      responseData = [[self class] trimResponseData:responseData
                                      byRangeHeader:rangeHeader
                              outContentRangeHeader:&contentRangeHeader];
      responseHeaders[@"Content-Range"] = contentRangeHeader;
      statusCode = 206;  // Partial Content request fulfilled.
    }
    // NOTE: resumeData not returned by cancelByProducingResumeData: without an Etag.
    if ([requestMethod isEqual:@"GET"]) {
      responseHeaders[@"Etag"] = kEtag;
    }
    return sendResponse(statusCode, responseData, _defaultContentType);
  }

  if (cookies.length > 0) {
    responseHeaders[@"FoundCookies"] = cookies;
  }
  NSString *cookieToSet =
      [NSString stringWithFormat:@"TestCookie=%@", [requestPath lastPathComponent]];
  responseHeaders[@"Set-Cookie"] = cookieToSet;

  // Cookies expected to be set and checked in tests before a redirect.
  NSURL *redirectURL = [self redirectURLForRequest:request fromServer:server];
  if (redirectURL) {
    responseHeaders[@"Location"] = [redirectURL absoluteString];
    return sendResponse(302, nil, nil);
  }

  // Read and return the document from the path, or status 404 for not found
  NSData *data = [self documentDataAtPath:requestPath];
  int resultStatus = data ? 200 : 404;

  if ([requestMethod isEqual:@"GET"]) {
    responseHeaders[@"Etag"] = kEtag;
  }

  // Finally, package up the response, and return it to the client
  return sendResponse(resultStatus, data, _defaultContentType);
}

#pragma mark - Private

+ (NSString *)valueForParameter:(NSString *)paramName query:(NSString *)query {
  if (!query) return nil;

  // search the query for a parameter beginning with "paramName=" and
  // ending with & or the end-of-string
  NSString *result = nil;
  NSString *paramWithEquals = [paramName stringByAppendingString:@"="];
  NSRange paramNameRange = [query rangeOfString:paramWithEquals];
  if (paramNameRange.location != NSNotFound) {
    // we found the param name; find the end of the parameter
    NSCharacterSet *endSet = [NSCharacterSet characterSetWithCharactersInString:@"&\n"];
    NSUInteger startOfParam = paramNameRange.location + paramNameRange.length;
    NSRange endSearchRange = NSMakeRange(startOfParam, query.length - startOfParam);
    NSRange endRange = [query rangeOfCharacterFromSet:endSet options:0 range:endSearchRange];
    if (endRange.location == NSNotFound) {
      // param goes to end of string
      result = [query substringFromIndex:startOfParam];
    } else {
      // found an end marker
      NSUInteger paramLen = endRange.location - startOfParam;
      NSRange foundRange = NSMakeRange(startOfParam, paramLen);
      result = [query substringWithRange:foundRange];
    }
  } else {
    // param not found
  }
  return result;
}

- (void)stopServers {
  if (_server) {
#if GTMHTTPSERVER_LOG_VERBOSE
    NSLog(@"Stopped GTMSessionFetcherTestServer on port %d", _server.port);
#endif
    _server = nil;
  }
  if (_redirectServer) {
#if GTMHTTPSERVER_LOG_VERBOSE
    NSLog(@"Stopped redirect target server on port %d", _redirectServer.port);
#endif
    _redirectServer = nil;
  }
}

- (NSURL *)redirectURLForRequest:(GTMHTTPRequestMessage *)request
                      fromServer:(GTMHTTPServer *)server {
  if ((server != _server) || !_redirectServer) return nil;
  NSURL *originalURL = request.URL;
  if (!originalURL) return nil;

  NSURLComponents *urlComponents = [[NSURLComponents alloc] initWithURL:originalURL
                                                resolvingAgainstBaseURL:YES];
  urlComponents.port = @(_redirectServer.port);
  NSURL *redirectURL = urlComponents.URL;
  return redirectURL;
}

- (id)JSONFromData:(NSData *)data {
  NSError *error = nil;
  id obj = [NSJSONSerialization JSONObjectWithData:data
                                           options:NSJSONReadingMutableContainers
                                             error:&error];
  if (obj == nil) {
    NSString *jsonStr = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSLog(@"JSON parse error: %@\n  for JSON string: %@", error, jsonStr);
  }
  return obj;
}

- (BOOL)isAuthenticatedRequest:(GTMHTTPRequestMessage *)request
                       forType:(GTMHTTPAuthenticationType)authenticationType
           authorizationHeader:(NSString *)authorization {
  switch (authenticationType) {
    case kGTMHTTPAuthenticationTypeInvalid:
      return YES;
    // http://en.wikipedia.org/wiki/Basic_access_authentication
    case kGTMHTTPAuthenticationTypeBasic: {
      NSString *const kBasicAuthPrefix = @"Basic ";
      if (![authorization hasCaseInsensitivePrefix:kBasicAuthPrefix]) return NO;

      NSString *basicAuthCredentials =
          [[authorization substringFromIndex:kBasicAuthPrefix.length] stringByTrimmingWhitespace];
      basicAuthCredentials = [basicAuthCredentials base64DecodedString];
      NSArray *credentialComponents = [basicAuthCredentials componentsSeparatedByString:@":"];
      if (credentialComponents.count < 2) return NO;

      NSString *authUsername = credentialComponents[0];
      NSString *authPassword = credentialComponents[1];
      return [_username isEqual:authUsername] && [_password isEqual:authPassword];
    }
    // http://en.wikipedia.org/wiki/Digest_access_authentication
    case kGTMHTTPAuthenticationTypeDigest: {
      NSString *const kDigestAuthPrefix = @"Digest ";
      if (![authorization hasCaseInsensitivePrefix:kDigestAuthPrefix]) return NO;

      NSString *authCredentialsString = [authorization substringFromIndex:kDigestAuthPrefix.length];
      NSDictionary *digestAuthCredentials =
          [authCredentialsString allDigestAuthorizationHeaderFields];
      NSString *username = digestAuthCredentials[@"username"];
      if (![_username isEqual:username]) return NO;

      NSString *urlString = [request.URL relativeString];
      NSString *authUri = digestAuthCredentials[@"uri"];
      if (![urlString isEqual:authUri]) return NO;

      NSString *nonce = digestAuthCredentials[@"nonce"];
      if (![_nonce isEqual:nonce]) return NO;
      NSString *nonceCount = digestAuthCredentials[@"nc"];
      if ([nonceCount integerValue] != 1) return NO;

      NSString *realm = digestAuthCredentials[@"realm"];
      NSString *ha1 = [NSString stringWithFormat:@"%@:%@:%@", _username, realm, _password];
      ha1 = [ha1 MD5DigestString];
      NSString *method = [request method];
      NSString *ha2 = [NSString stringWithFormat:@"%@:%@", method, authUri];
      ha2 = [ha2 MD5DigestString];
      NSString *clientNonce = digestAuthCredentials[@"cnonce"];
      NSString *qop = digestAuthCredentials[@"qop"];
      NSString *authResponse = digestAuthCredentials[@"response"];
      NSString *response = [NSString
          stringWithFormat:@"%@:%@:%@:%@:%@:%@", ha1, nonce, nonceCount, clientNonce, qop, ha2];
      response = [response MD5DigestString];
      return [response isEqual:authResponse];
    }
  }
}

- (NSString *)authenticationHeaderValueWithType:(GTMHTTPAuthenticationType)authenticationType {
  NSString *const kRealm = @"realm@localhost.com";
  NSString *authenticateHeaderValue = nil;
  switch (authenticationType) {
    case kGTMHTTPAuthenticationTypeInvalid:
      NSAssert(NO, @"Unexpected authentication type to build header for");
      break;
    case kGTMHTTPAuthenticationTypeDigest: {
      _nonce = [[NSUUID UUID] UUIDString];
      NSString *const kTemplate = @"Digest realm=\"%@\", qop=\"auth\", nonce=\"%@\"";
      authenticateHeaderValue = [NSString stringWithFormat:kTemplate, kRealm, _nonce];
      break;
    }
    case kGTMHTTPAuthenticationTypeBasic: {
      NSString *const kTemplate = @"Basic realm=\"%@\"";
      authenticateHeaderValue = [NSString stringWithFormat:kTemplate, kRealm];
      break;
    }
  }
  return authenticateHeaderValue;
}

+ (NSData *)trimResponseData:(NSData *)responseData
               byRangeHeader:(NSString *)rangeHeader
       outContentRangeHeader:(NSString *__autoreleasing *)outContentRangeHeader {
  NSAssert([rangeHeader hasPrefix:@"bytes="], @"Invalid Range: %@", rangeHeader);
  rangeHeader = [rangeHeader substringFromIndex:@"bytes=".length];
  NSArray *byteRangeStrings = [rangeHeader componentsSeparatedByString:@","];
  NSRange contentRange = NSMakeRange(0, 0);

  // Reference: http://www.w3.org/Protocols/rfc2616/rfc2616-sec14.html, section 14.35.1
  // - The first 500 bytes (byte offsets 0-499, inclusive): bytes=0-499
  // - The second 500 bytes (byte offsets 500-999, inclusive): bytes=500-999
  // - The final 500 bytes (byte offsets 9500-9999, inclusive): bytes=-500
  // - Or bytes=9500-
  // - The first and last bytes only (bytes 0 and 9999):  bytes=0-0,-1
  // - Several legal but not canonical specifications of the second 500 bytes
  //   (byte offsets 500-999, inclusive):
  //     bytes=500-600,601-999
  //     bytes=500-700,601-999
  for (NSString *byteRangeString in byteRangeStrings) {
    NSRange byteRange;
    if ([byteRangeString hasPrefix:@"-"]) {
      // Final number of bytes
      byteRange.length = (NSUInteger)[[byteRangeString substringFromIndex:1] integerValue];
      byteRange.location = responseData.length - byteRange.length;
    } else if ([byteRangeString hasSuffix:@"-"]) {
      // Final bytes beginning at offset
      NSRange offsetRange = NSMakeRange(0, (byteRangeString.length - 1));
      byteRange.location =
          (NSUInteger)[[byteRangeString substringWithRange:offsetRange] integerValue];
      byteRange.length = responseData.length - byteRange.location;
    } else {
      NSArray *byteOffsets = [byteRangeString componentsSeparatedByString:@"-"];
      NSAssert(byteOffsets.count == 2, @"Unexpected number of values in byte range, %@",
               byteRangeString);
      byteRange.location = (NSUInteger)[byteOffsets[0] integerValue];
      byteRange.length = (NSUInteger)[byteOffsets[1] integerValue] + 1 - byteRange.location;
    }
    contentRange = (contentRange.length == 0) ? byteRange : NSUnionRange(contentRange, byteRange);
  }
  // Section 14.16 for 'Content-Range'
  // Examples of byte-content-range-spec values, assuming that the entity contains 1234 total bytes:
  // . The first 500 bytes: bytes 0-499/1234
  // . The second 500 bytes: bytes 500-999/1234
  // . All except for the first 500 bytes: bytes 500-1233/1234
  // . The last 500 bytes: bytes 734-1233/1234
  *outContentRangeHeader =
      [NSString stringWithFormat:@"bytes %llu-%llu/%llu", (unsigned long long)contentRange.location,
                                 (unsigned long long)(NSMaxRange(contentRange) - 1),
                                 (unsigned long long)responseData.length];
  return [responseData subdataWithRange:contentRange];
}

@end

#endif  // !TARGET_OS_WATCH
