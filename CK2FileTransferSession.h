//
//  CK2FileTransferSession.h
//  Connection
//
//  Created by Mike on 08/10/2012.
//
//

#import <Foundation/Foundation.h>

#import "CKConnectionProtocol.h"


@protocol CK2FileTransferSessionDelegate;


@interface CK2FileTransferSession : NSObject <NSURLAuthenticationChallengeSender>
{
@private
    NSURLRequest        *_request;
    
    // Auth
    NSURLCredential     *_credential;
    NSOperationQueue    *_opsAwaitingAuth;
    
    id <CK2FileTransferSessionDelegate> _delegate;
}

#pragma mark Discovering Directory Contents

- (void)contentsOfDirectoryAtURL:(NSURL *)url
      includingPropertiesForKeys:(NSArray *)keys
                         options:(NSDirectoryEnumerationOptions)mask
               completionHandler:(void (^)(NSArray *contents, NSError *error))block;

// More advanced version of directory listing
//  * listing results are delivered as they arrive over the wire, if possible
//  * FIRST result is the directory itself, with relative path resolved if possible
//  * MIGHT do true recursion of the directory tree in future, so include NSDirectoryEnumerationSkipsSubdirectoryDescendants for stable results
- (void)enumerateContentsOfURL:(NSURL *)url
    includingPropertiesForKeys:(NSArray *)keys
                       options:(NSDirectoryEnumerationOptions)mask
                    usingBlock:(void (^)(NSURL *url))block
             completionHandler:(void (^)(NSError *error))completionBlock;


#pragma mark Creating and Deleting Items

- (void)createDirectoryAtURL:(NSURL *)url withIntermediateDirectories:(BOOL)createIntermediates completionHandler:(void (^)(NSError *error))handler;

// 0 bytesWritten indicates writing has ended. This might be because of a failure; if so, error will be filled in
- (void)createFileAtURL:(NSURL *)url contents:(NSData *)data withIntermediateDirectories:(BOOL)createIntermediates progressBlock:(void (^)(NSUInteger bytesWritten, NSError *error))progressBlock;

- (void)createFileAtURL:(NSURL *)destinationURL withContentsOfURL:(NSURL *)sourceURL withIntermediateDirectories:(BOOL)createIntermediates progressBlock:(void (^)(NSUInteger bytesWritten, NSError *error))progressBlock;

- (void)removeFileAtURL:(NSURL *)url completionHandler:(void (^)(NSError *error))handler;


#pragma mark Getting and Setting Attributes
// Only NSFilePosixPermissions is recognised at present. Note that some servers don't support this so will return an error (code 500)
// All other attributes are ignored
- (void)setResourceValues:(NSDictionary *)keyedValues ofItemAtURL:(NSURL *)url completionHandler:(void (^)(NSError *error))handler;


#pragma mark Delegate
// Delegate messages are received on arbitrary queues. So changing delegate might mean you still receive message shortly after the change. Not ideal I know!
@property(assign) id <CK2FileTransferSessionDelegate> delegate;


#pragma mark URLs
// These two methods take into account the specifics of different URL schemes. e.g. for the same relative path, but different base schemes:
//  http://example.com/relative/path
//  ftp://example.com/relative/path
//  ssh://example.com/~/relative/path
+ (NSURL *)URLWithPath:(NSString *)path relativeToURL:(NSURL *)baseURL;
+ (NSString *)pathOfURLRelativeToHomeDirectory:(NSURL *)URL;


@end


@protocol CK2FileTransferSessionDelegate <NSObject>
- (void)fileTransferSession:(CK2FileTransferSession *)session didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge;
- (void)fileTransferSession:(CK2FileTransferSession *)session appendString:(NSString *)info toTranscript:(CKTranscriptType)transcript;
@end


#pragma mark -


@interface NSURL (ConnectionKit)
- (BOOL)ck2_isFTPURL;   // YES if the scheme is ftp or ftps
@end