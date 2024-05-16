//
//  SBYZipArchive.m
//  SBYZipArchive
//
//  Created by shoby on 2013/12/30.
//  Copyright (c) 2013 shoby. All rights reserved.
//

#import "SBYZipArchive.h"
#import "unzip.h"

NSString* const SBYZipArchiveErrorDomain = @"SBYZipArchiveErrorDomain";

static const NSUInteger SBYZipArchiveBufferSize = 4096;

@interface SBYZipArchive ()
@property (nonatomic, readwrite) NSURL *url;
@property (nonatomic) unzFile unzFile;
@property (nonatomic) NSMutableArray<SBYZipEntry *> *cachedEntries;

@property (nonatomic) dispatch_semaphore_t semaphore;

@property (nonatomic) NSOutputStream *outputStream;
@property (nonatomic) NSURL *unzipDestinationURL;

@property (nonatomic) NSUInteger bytesUnzipped;
@property (nonatomic) NSUInteger totalBytes;

@property (copy, nonatomic) void (^successBlock)(NSURL *);
@property (copy, nonatomic) void (^failureBlock)(NSError *);
@property (copy, nonatomic) void (^progressBlock)(NSUInteger, NSUInteger);
@end

@implementation SBYZipArchive

- (instancetype)initWithContentsOfURL:(NSURL *)url error:(NSError *__autoreleasing *)error
{
    self = [super init];
    if (self) {
        self.url = url;
        self.unzFile = unzOpen([url.path UTF8String]);
        if (!self.unzFile) {
            if (error) {
                NSDictionary *userInfo = @{NSLocalizedDescriptionKey: @"Cannot open the archive file."};
                *error = [NSError errorWithDomain:SBYZipArchiveErrorDomain code:SBYZipArchiveErrorCannotOpenFile userInfo:userInfo];
            }
            return nil;
        }
        
        self.semaphore = dispatch_semaphore_create(1);
    }
    return self;
}

- (void)dealloc
{
    unzClose(self.unzFile);
}

- (NSArray *)entries
{
    if (!self.cachedEntries) {
        [self loadEntriesWithError:nil];
    }
    return self.cachedEntries;
}

- (NSData *)dataForEntry:(SBYZipEntry *)entry error:(NSError *__autoreleasing *)error
{
    if (!entry) {
        return nil;
    }
    
    // start lock
    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC);
    dispatch_semaphore_wait(self.semaphore, timeout);
    
    unzSetOffset(self.unzFile, entry.offset);
    
    unzOpenCurrentFile(self.unzFile);
    
    NSMutableData *data = [[NSMutableData alloc] initWithLength:entry.fileSize];
    int unz_err = unzReadCurrentFile(self.unzFile, [data mutableBytes], (unsigned int)data.length);
    
    unzCloseCurrentFile(self.unzFile);
    
    // end lock
    dispatch_semaphore_signal(self.semaphore);
    
    if (error && unz_err < 0) {
        NSString *localizedDescription = [self localizedDescriptionForUnzError:unz_err];
        *error = [NSError errorWithDomain:SBYZipArchiveErrorDomain code:SBYZipArchiveErrorCannotGetFileInfo userInfo:@{NSLocalizedDescriptionKey: localizedDescription}];
        
        return nil;
    }
    
    return data;
}

NSString *convertEncodedString(const char *encodedString) {
    NSData *data = [NSData dataWithBytes:encodedString length:strlen(encodedString)];
    NSString *decodedString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    
    if (decodedString == nil) {
        decodedString = [[NSString alloc] initWithData:data encoding:0x80000400];
        NSLog(@"[Warning] fileName Zip (%s) is not UTF-8 encoding compliant", encodedString);
    }
    if (decodedString == nil) {
        decodedString = [[NSString alloc] initWithData:data encoding:[NSString defaultCStringEncoding]];
        NSLog(@"[Warning] fileName Zip (%s) is not Latin (DOS) encoding compliant", encodedString);
    }
    return decodedString;
}

- (BOOL)loadEntriesWithError:(NSError *__autoreleasing *)error
{
    self.cachedEntries = [NSMutableArray array];
    
    unzGoToFirstFile(self.unzFile);
    while (true) {
        unz_file_info file_info;
        char file_name[256];
        
        int unz_err = unzGetCurrentFileInfo(self.unzFile, &file_info, file_name, sizeof(file_name), NULL, 0, NULL, 0);
        if (unz_err != UNZ_OK) {
            if (error) {
                NSString *localizedDescription = [self localizedDescriptionForUnzError:unz_err];
                *error = [NSError errorWithDomain:SBYZipArchiveErrorDomain code:SBYZipArchiveErrorCannotGetFileInfo userInfo:@{NSLocalizedDescriptionKey: localizedDescription}];
            }
            return NO;
        }
        
        NSUInteger offset = unzGetOffset(self.unzFile);
        
        NSString *fileName = convertEncodedString(file_name);
        SBYZipEntry *entry = [[SBYZipEntry alloc] initWithArchive:self
                                                               fileName:fileName
                                                               fileSize:file_info.uncompressed_size
                                                                 offset:offset];
        
        [self.cachedEntries addObject:entry];
        
        if (unzGoToNextFile(self.unzFile) != UNZ_OK) {
            break;
        }
    }
    
    return YES;
}

- (void)unzipEntry:(SBYZipEntry *)entry toURL:(NSURL *)url success:(nullable void (^)(NSURL *))success failure:(nullable void (^)(NSError *))failure progress:(nullable void (^)(NSUInteger, NSUInteger))progress
{
    if (!entry) {
        return;
    }
    
    NSURL *fullPath = url;
    
    NSFileManager *fileManger = [[NSFileManager alloc] init];
    
    if ([fileManger fileExistsAtPath:fullPath.path]) {
        NSDictionary *userInfo = @{NSLocalizedDescriptionKey: @"Cannot unzip the entry file. File already exits."};
        NSError *error = [NSError errorWithDomain:SBYZipArchiveErrorDomain code:SBYZipArchiveErrorCannotUnzipEntryFile userInfo:userInfo];
        
        if (failure) {
            failure(error);
        }
        return;
    }
    
    if (![fileManger fileExistsAtPath:[fullPath.path stringByDeletingLastPathComponent]]) {
        NSError *error = nil;
        [fileManger createDirectoryAtPath:[fullPath.path stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:&error];
        
        if (error) {
            NSDictionary *userInfo = @{NSLocalizedDescriptionKey: @"Failed to create directory."};
            NSError *error = [NSError errorWithDomain:SBYZipArchiveErrorDomain code:SBYZipArchiveErrorCannotUnzipEntryFile userInfo:userInfo];
            
            if (failure) {
                failure(error);
            }
            
            return;
        }
    }

    dispatch_semaphore_wait(self.semaphore, DISPATCH_TIME_FOREVER);
    
    self.unzipDestinationURL = fullPath;
    self.bytesUnzipped = 0;
    self.totalBytes = entry.fileSize;
    
    self.successBlock = success;
    self.failureBlock = failure;
    self.progressBlock = progress;
    
    unzSetOffset(self.unzFile, entry.offset);
    unzOpenCurrentFile(self.unzFile);
    
    self.outputStream = [[NSOutputStream alloc] initWithURL:fullPath append:YES];
    [self.outputStream open];

    NSMutableData *buffer = [[NSMutableData alloc] initWithLength:SBYZipArchiveBufferSize];

    while (1) {
        int readBytes = unzReadCurrentFile(self.unzFile, [buffer mutableBytes], (unsigned int)buffer.length);
        
        if (readBytes == 0) { // completed
            [self closeStream:self.outputStream];
            [self callSuccessBlock];
            break;
        } else if (readBytes < 0) { // error
            int unz_err = readBytes;
            NSString *localizedDescription = [self localizedDescriptionForUnzError:unz_err];
            NSError *error = [NSError errorWithDomain:SBYZipArchiveErrorDomain code:SBYZipArchiveErrorCannotUnzipEntryFile userInfo:@{NSLocalizedDescriptionKey: localizedDescription}];
            
            [self closeStream:self.outputStream];
            [self callFailureBlockWithError:error];
            break;
        } else {
            [self.outputStream write:[buffer bytes] maxLength:readBytes];
            
            self.bytesUnzipped += readBytes;
            [self callProgressBlock];
        }
    }
}

- (void)closeStream:(NSStream *)stream
{
    [stream close];
    self.outputStream = nil;
    
    // end lock
    dispatch_semaphore_signal(self.semaphore);
}

- (void)releaseBlocks
{
    self.progressBlock = nil;
    self.successBlock = nil;
    self.failureBlock = nil;
}

#pragma mark - Privete Methods

- (NSString *)localizedDescriptionForUnzError:(int)unzError
{
    NSString * localizedDescription = nil;
    
    switch (unzError) {
        case UNZ_BADZIPFILE:
            localizedDescription = @"The archive file seems to be incorrect format.";
            break;
        case UNZ_ERRNO:
            localizedDescription = [NSString stringWithFormat:@"Failed to read file: %s", strerror(errno)];
            break;
        default:
            localizedDescription = @"Failed to read file";
            break;
    }
    
    return localizedDescription;
}

- (void)callSuccessBlock
{
    if (self.successBlock) {
        typeof(self.successBlock) successBlock = self.successBlock;
        typeof(self.unzipDestinationURL) unzipDestinationURL = self.unzipDestinationURL;
        [self releaseBlocks];
        successBlock(unzipDestinationURL);
    }
}

- (void)callFailureBlockWithError:(NSError *)error
{
    if (self.failureBlock) {
        typeof(self.failureBlock) failureBlock = self.failureBlock;
        [self releaseBlocks];
        failureBlock(error);
    }
}

- (void)callProgressBlock
{
    if (self.progressBlock) {
        typeof(self.progressBlock) progressBlock = self.progressBlock;
        NSUInteger bytesUnzipped = self.bytesUnzipped;
        NSUInteger totalBytes = self.totalBytes;
        progressBlock(bytesUnzipped, totalBytes);
    }
}

@end
