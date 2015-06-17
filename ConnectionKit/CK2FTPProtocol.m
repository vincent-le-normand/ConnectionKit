//
//  CK2FTPProtocol.m
//  Connection
//
//  Created by Mike on 12/10/2012.
//
//

#import "CK2FTPProtocol.h"

#import <CURLHandle/CURLHandle.h>


@interface CK2FTPSProtectionSpace : NSURLProtectionSpace
{
  @private
    SecTrustRef _trust;
}
- initWithServerTrust:(SecTrustRef)trust host:(NSString *)host port:(NSInteger)port;
@end


#pragma mark -

@interface CK2FTPProtocol(NSURLAuthenticationChallengeSender) <NSURLAuthenticationChallengeSender>
@end

@implementation CK2FTPProtocol

#pragma mark URLs

+ (BOOL)canHandleURL:(NSURL *)url;
{
    NSString *scheme = [url scheme];
    
    return ([@"ftp" caseInsensitiveCompare:scheme] == NSOrderedSame ||
            [@"ftpes" caseInsensitiveCompare:scheme] == NSOrderedSame ||
            [@"ftps" caseInsensitiveCompare:scheme] == NSOrderedSame);
}

+ (NSURL *)URLWithPath:(NSString *)path relativeToURL:(NSURL *)baseURL;
{
    // FTP is special. Absolute paths need to specified with an extra prepended slash <http://curl.haxx.se/libcurl/c/curl_easy_setopt.html#CURLOPTURL>
    // According to libcurl's docs that should be enough. But with our current build of it, it seems they've gotten stricter
    // The FTP spec could be interpreted that the only way to refer to the root directly is with the sequence @"%2F", which decodes as a slash
    // That makes it very clear to the library etc. this particular slash is meant to be transmitted to the server, rather than treated as a path component separator
    // Happily it also simplifies our code, as coaxing a double slash into NSURL is a mite tricky
    if ([path isAbsolutePath])
    {
        // Pare it back to just a plain path of @"/" and no latter components
        NSString *urlString = [[NSURL URLWithString:@"/" relativeToURL:baseURL] absoluteString];
        
        // Tack on the path given to us
        // http://www.mikeabdullah.net/escaping-url-paths-in-cocoa.html
        CFStringRef escaped = CFURLCreateStringByAddingPercentEscapes(NULL,
                                                                      (CFStringRef)path,
                                                                      NULL,
                                                                      CFSTR(";?#"),
                                                                      kCFStringEncodingUTF8);
        
        NSURL *result = [NSURL URLWithString:[urlString stringByAppendingString:(NSString *)escaped]];
        CFRelease(escaped);
        
        return result;
    }
    
    return [super URLWithPath:path relativeToURL:baseURL];
}

+ (NSString *)pathOfURLRelativeToHomeDirectory:(NSURL *)URL;
{
    // FTP is special. The first slash of the path is to be ignored <http://curl.haxx.se/libcurl/c/curl_easy_setopt.html#CURLOPTURL>
    // As above, the library seems to be stricter on how the slash is to be encoded these days. I'm not sure whether we should be similarly strict when decoding. Leaving it be for now
    CFStringRef strictPath = CFURLCopyStrictPath((CFURLRef)[URL absoluteURL], NULL);
    NSString *result = [(NSString *)strictPath stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    if (strictPath) CFRelease(strictPath);
    return result;
}

#pragma mark URL Requests

- (id)initWithRequest:(NSURLRequest *)request client:(id<CK2ProtocolClient>)client;
{
    // libcurl doesn't understand ftpes: URLs natively, so convert them back into ftp: with the appropriate connection settings
    NSURL *url = request.URL;
    if ([url.scheme caseInsensitiveCompare:@"ftpes"] == NSOrderedSame)
    {
        url = [NSURL URLWithString:[url.absoluteString stringByReplacingCharactersInRange:NSMakeRange(0, 5) // bit hacky
                                                                               withString:@"ftp"]];
        
        NSMutableURLRequest *mutableRequest = [[request mutableCopy] autorelease];
        mutableRequest.URL = url;
        [mutableRequest curl_setDesiredSSLLevel:CURLUSESSL_ALL];
        request = mutableRequest;
    }
    
    return [super initWithRequest:request client:client];
}

#pragma mark Operations

- (id)initWithCustomCommands:(NSArray *)commands request:(NSURLRequest *)childRequest createIntermediateDirectories:(BOOL)createIntermediates client:(id<CK2ProtocolClient>)client completionHandler:(void (^)(NSError *))handler;
{
    NSMutableURLRequest *request = [childRequest mutableCopy];
    request.URL = [childRequest.URL URLByDeletingLastPathComponent];
    
    self = [super initWithCustomCommands:commands
                                 request:request
           createIntermediateDirectories:createIntermediates
                                  client:client
                       completionHandler:handler];
    
    [request release];
    return self;
}

- (id)initForCreatingDirectoryWithRequest:(NSURLRequest *)request withIntermediateDirectories:(BOOL)createIntermediates openingAttributes:(NSDictionary *)attributes client:(id<CK2ProtocolClient>)client;
{
    return [self initWithCustomCommands:[NSArray arrayWithObject:[@"MKD " stringByAppendingString:[[request URL] lastPathComponent]]]
             request:request
          createIntermediateDirectories:createIntermediates
                                 client:client
                      completionHandler:^(NSError *error) {

                          if (error)
                          {
                              error = [self translateStandardErrors:error];
                          }

                          [self reportToProtocolWithError:error];
                      }

            ];
}

- (id)initForCreatingFileWithRequest:(NSURLRequest *)request size:(int64_t)size withIntermediateDirectories:(BOOL)createIntermediates openingAttributes:(NSDictionary *)attributes client:(id<CK2ProtocolClient>)client;
{
    return [self initForCreatingFileWithRequest:request size:size withIntermediateDirectories:createIntermediates client:client completionHandler:^(NSError *error) {
        
        if (error) {
            if ([self looksLikeFTPIdleTimeoutProblem:error])
            {
                error = nil;
            }
            // Give a bit of a clue for debugging how far we got through
            else if (self.totalBytesWritten) {
                NSMutableDictionary *info = [error.userInfo mutableCopy];
                
                NSString *description;
                if (self.totalBytesExpectedToWrite == NSURLResponseUnknownLength) {
                    description = [[info objectForKey:NSLocalizedDescriptionKey] stringByAppendingFormat:
                                   @" (%@ KB sent.)",
                                   @(self.totalBytesWritten / 1024)];
                }
                else {
                    description = [[info objectForKey:NSLocalizedDescriptionKey] stringByAppendingFormat:
                                   @" (%@ of %@ KB sent.)",
                                   @(self.totalBytesWritten / 1024),
                                   @(self.totalBytesExpectedToWrite / 1024)];
                }
                
                [info setObject:description forKey:NSLocalizedDescriptionKey];
                error = [NSError errorWithDomain:error.domain code:error.code userInfo:info];
                [info release];
            }
        }
        
        [client protocol:self didCompleteWithError:error];
    }];
}

- (id)initForRenamingItemWithRequest:(NSURLRequest *)request newName:(NSString *)newName client:(id<CK2ProtocolClient>)client
{
    NSString* sourcePath = [[request URL] lastPathComponent];

    return [self initWithCustomCommands:[NSArray arrayWithObjects:
                                         [@"RNFR " stringByAppendingString:sourcePath],
                                         [@"RNTO " stringByAppendingString:newName],
                                         nil
                                         ]
                                request:request
          createIntermediateDirectories:NO
                                 client:client
                      completionHandler:^(NSError *error) {
                          error = [self translateStandardErrors:error];
                          [self reportToProtocolWithError:error];
                      }];
}

- (id)initForRemovingItemWithRequest:(NSURLRequest *)request client:(id<CK2ProtocolClient>)client;
{
    NSURL *url = request.URL;
    
    // Pick an appropriate command
    // DELE is only intended to delete files, but in our testing, some FTP servers happily support deleting a directory using it
    NSString *command = @"DELE ";
    
    NSNumber *isDirectory;
    if ([url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:NULL] && isDirectory.boolValue)
    {
        command = @"RMD ";
    }
    else if (CFURLHasDirectoryPath((CFURLRef)url))
    {
        command = @"RMD ";
    }
    
    return [self initWithCustomCommands:[NSArray arrayWithObject:[command stringByAppendingString:url.lastPathComponent]]
             request:request
          createIntermediateDirectories:NO
                                 client:client
                      completionHandler:^(NSError *error) {
                          if (error)
                          {
                              error = [self translateStandardErrors:error];
                          }

                          [self reportToProtocolWithError:error];
                      }];
}

- (id)initForSettingAttributes:(NSDictionary *)keyedValues ofItemWithRequest:(NSURLRequest *)request client:(id<CK2ProtocolClient>)client;
{
    NSNumber *permissions = [keyedValues objectForKey:NSFilePosixPermissions];
    if (permissions)
    {
        NSString* path = [[request URL] lastPathComponent];
        NSArray *commands = [NSArray arrayWithObject:[NSString stringWithFormat:
                                                      @"SITE CHMOD %lo %@",
                                                      [permissions unsignedLongValue],
                                                      path]];
        
        return [self initWithCustomCommands:commands
                 request:request
              createIntermediateDirectories:NO
                                     client:client
                          completionHandler:^(NSError *error) {
                              
                              if (error)
                              {
                                  NSString* domain = error.domain;
                                  NSInteger code = error.code;

                                  // CHMOD failures for unsupported or unrecognized command should go ignored
                                  if (code== CURLE_QUOTE_ERROR && [domain isEqualToString:CURLcodeErrorDomain])
                                  {
                                      NSUInteger responseCode = [error curlResponseCode];
                                      if (responseCode == 500 || responseCode == 502 || responseCode == 504)
                                      {
                                          error = nil;
                                      }
                                  }

                                  if (error)
                                  {
                                      error = [self translateStandardErrors:error];
                                  }
                              }

                              [self reportToProtocolWithError:error];
                          }];
    }
    else
    {
        self = [self initWithRequest:nil client:client];
        return self;
    }
}

- (void)dealloc;
{
    [_credential release];
    [super dealloc];
}

#pragma mark Errors

- (NSError*)translateStandardErrors:(NSError*)error
{
    NSString* domain = error.domain;
    NSInteger code = error.code;
    
    if (code == CURLE_QUOTE_ERROR && [domain isEqualToString:CURLcodeErrorDomain])
    {
        NSUInteger responseCode = [error curlResponseCode];
        if (responseCode == 550)
        {
            error = [self standardCouldntWriteErrorWithUnderlyingError:error];
        }
    }
    else if (code == CURLE_REMOTE_ACCESS_DENIED && [domain isEqualToString:CURLcodeErrorDomain])
    {
        // Could be a permissions problem, or could be that a CWD command failed because the directory doesn't exist
        error = [self standardCouldntReadErrorWithUnderlyingError:error];
    }
    else if ((code == NSURLErrorNoPermissionsToReadFile) && ([domain isEqualToString:NSURLErrorDomain]))
    {
        // CURLTransfer helpfully returns a URL error here, but we want to return a cocoa error instead
        error = [self standardCouldntWriteErrorWithUnderlyingError:error];
    }
    else
    {
        NSLog(@"untranslated error for %@ %@", NSStringFromSelector(_cmd), error);
    }

    return error;
}

/**
 FTP suffers a fairly notorious problem. During a long upload, the control connection is completely
 idle. As such, there's a tendency for internet routers to then cut it off. When the data connection
 completes, Curl goes to use the control connection to finish up and finds that it no longer can,
 thanks to that cutoff. The really nasty thing is Curl can't know for sure if the cutoff was because
 of idling (and the upload finished successfully), or if there was a proper connection problem while
 the last packet of data was being sent.
 
 Understandably, users can be rather annoyed if they keep being told their long uploads have failed
 (particularly in an app like Sandvox where a failure will result in the upload being retried on
 another occasion until it does succeed).
 
 So our best bet seems to be a heuristic: If all file data was *transmitted* (not necessarily *received*)
 and the failure could be caused by an idle timeout, assume the upload was actually a success.
 */
- (BOOL)looksLikeFTPIdleTimeoutProblem:(NSError *)error {
    if (!_atEnd) return NO;
    
    // We've seen more than a single error code so far!
    if (error.code == NSURLErrorTimedOut && [error.domain isEqualToString:NSURLErrorDomain]) return YES;
    if (error.code == CURLE_RECV_ERROR && [error.domain isEqualToString:CURLcodeErrorDomain]) return YES; // https://karelia.fogbugz.com/f/cases/248867/
    
    return NO;
}

#pragma mark Lifecycle

- (void)start;
{
    // If there's no request, that means we were asked to do nothing possible over FTP. Most likely, storing attributes that aren't POSIX permissions
    // So jump straight to completion
    NSURLRequest *request = self.request;
    if (!request)
    {
        [[self client] protocol:self didCompleteWithError:nil];
        return;
    }

    NSURL *url = request.URL;
    NSString *scheme = url.scheme;
    
    NSNumber *port = url.port;
    if (!port)
    {
        port = ([scheme isEqualToString:@"ftps"] ? @(990) : @(21));
    }
    
    NSString *protocol = NSURLProtectionSpaceFTP;
    if (request.curl_desiredSSLLevel >= CURLUSESSL_CONTROL ||
        [@"ftps" caseInsensitiveCompare:scheme] == NSOrderedSame)
    {
        protocol = @"ftps";
    }
    
    NSURLProtectionSpace *space = [[NSURLProtectionSpace alloc] initWithHost:[url host]
                                                                        port:port.integerValue
                                                                    protocol:protocol
                                                                       realm:nil
                                                        authenticationMethod:NSURLAuthenticationMethodDefault];
    
    [self startWithProtectionSpace:space];
    [space release];
}

- (void)startWithRequest:(NSURLRequest *)request credential:(NSURLCredential *)credential;
{
    // Cache the credential in case we need to retry FTPS
    [credential retain];
    [_credential release]; _credential = credential;
    
    [super startWithRequest:request credential:credential];
}

#pragma mark Home Directory

/*- (void)findHomeDirectoryWithCompletionHandler:(void (^)(NSString *path, NSError *error))handler;
{
    // Deliberately want a request that should avoid doing any work
    NSMutableURLRequest *request = [[self request] mutableCopy];
    [request setURL:[NSURL URLWithString:@"/" relativeToURL:[request URL]]];
    [request setHTTPMethod:@"HEAD"];

    [self sendRequest:request dataHandler:nil completionHandler:^(CURLTransfer *transfer, NSError *error) {
        if (error)
        {
            handler(nil, error);
        }
        else
        {
            handler([transfer initialFTPPath], error);
        }
    }];
    
    [request release];
}*/

#pragma mark CURLTransferDelegate

- (void)transfer:(CURLTransfer *)transfer didCompleteWithError:(NSError *)error;
{
    // For SSL errors, report extra info
    SecTrustRef trust = (SecTrustRef)[error.userInfo objectForKey:NSURLErrorFailingURLPeerTrustErrorKey];
    if (trust)
    {
        NSURL *url = self.request.URL;
        
        NSURLProtectionSpace *space = [[CK2FTPSProtectionSpace alloc] initWithServerTrust:trust
                                                                                     host:url.host
                                                                            port:url.port.integerValue];
        
        _sslFailures++;
        
        NSURLAuthenticationChallenge *challenge = [[NSURLAuthenticationChallenge alloc] initWithProtectionSpace:space
                                                                                             proposedCredential:nil
                                                                                           previousFailureCount:_sslFailures
                                                                                                failureResponse:nil
                                                                                                          error:error
                                                                                                         sender:self];
        
        [self.client protocol:self didReceiveChallenge:challenge completionHandler:^(CK2AuthChallengeDisposition disposition, NSURLCredential *credential) {
            
            if (disposition == CK2AuthChallengeUseCredential && credential)
            {
                // Retry
                // Ideally we'd adjust libcurl to only accept this one new
                // certificate, but I can't spot a proper API for that, so we'll
                // have to live with a minor security flaw for now.
                NSMutableURLRequest *request = [self.request mutableCopy];
                [request curl_setShouldVerifySSLHost:NO];   // disabling host check is all Sandvox needs
                [self startWithRequest:request credential:_credential];
                [request release];
            }
            else if (disposition == CK2AuthChallengeCancelAuthenticationChallenge)
            {
                [super transfer:transfer didCompleteWithError:[NSError errorWithDomain:NSURLErrorDomain
                                                                                  code:NSURLErrorUserCancelledAuthentication
                                                                              userInfo:nil]];
            }
            else
            {
                [super transfer:transfer didCompleteWithError:error];
            }
        }];
        
        [challenge release];
        [space release];
        
        return;
    }
    
    [super transfer:transfer didCompleteWithError:error];
}

- (void)transfer:(CURLTransfer *)transfer willSendBodyDataOfLength:(NSUInteger)bytesWritten;
{
    // Watch for the file end being reached before passing onto the original requester
    if (bytesWritten == 0) _atEnd = YES;
    
    [super transfer:transfer willSendBodyDataOfLength:bytesWritten];
}

- (void)transfer:(CURLTransfer *)transfer didReceiveDebugInformation:(NSString *)string ofType:(curl_infotype)type;
{
    // Don't want to include password in transcripts usually!
    if (type == CURLINFO_HEADER_OUT &&
        [string hasPrefix:@"PASS"] &&
        ![[NSUserDefaults standardUserDefaults] boolForKey:@"AllowPasswordToBeLogged"])
    {
        string = @"PASS ####";
    }
    
    [super transfer:transfer didReceiveDebugInformation:string ofType:type];
}

@end


#pragma mark -


@implementation CK2FTPSProtectionSpace

- initWithServerTrust:(SecTrustRef)trust host:(NSString *)host port:(NSInteger)port;
{
    if (self = [self initWithHost:host port:port protocol:@"ftps" realm:nil authenticationMethod:NSURLAuthenticationMethodServerTrust])
    {
        _trust = trust;
        CFRetain(_trust);
    }
    return self;
}

- (void)dealloc;
{
    CFRelease(_trust);
    [super dealloc];
}

- (SecTrustRef)serverTrust; { return _trust; }

@end


@implementation CK2FTPProtocol(NSURLAuthenticationChallengeSender)
- (void)useCredential:(NSURLCredential *)credential forAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge {
	NSLog(@"CK2FTPProtocol - NSURLAuthenticationChallengeSender not implemented");
}

- (void)continueWithoutCredentialForAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge {
	NSLog(@"CK2FTPProtocol - NSURLAuthenticationChallengeSender not implemented");
}

- (void)cancelAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge {
	NSLog(@"CK2FTPProtocol - NSURLAuthenticationChallengeSender not implemented");
}
@end
