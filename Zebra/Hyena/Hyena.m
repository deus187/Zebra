//
//  Hyena.m
//  Zebra
//
//  Created by Wilson Styres on 3/20/19.
//  Copyright © 2019 Wilson Styres. All rights reserved.
//

#import "Hyena.h"
#import <UIKit/UIDevice.h>
#import <sys/sysctl.h>
#import <bzlib.h>
#import <ZBAppDelegate.h>

@implementation Hyena

- (id)init {
    self = [super init];
    
    if (self) {
        repos = [self reposFromSourcePath:[ZBAppDelegate sourceListLocation]];
    }
    
    return self;
}

- (id)initWithSourceListPath:(NSString *)trail {
    self = [super init];
    
    if (self) {
        repos = [self reposFromSourcePath:trail];
    }
    
    return self;
}

- (void)postStatusUpdate:(NSString *)update atLevel:(int)level {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"databaseStatusUpdate" object:self userInfo:@{@"level": @(level), @"message": update}];
}

- (NSArray *)reposFromSourcePath:(NSString *)path {
    NSMutableArray *repos = [NSMutableArray new];
    
    NSError *sourceListReadError;
    NSString *sourceList = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&sourceListReadError];
    NSArray *debLines = [sourceList componentsSeparatedByString:@"\n"];
    
    for (NSString *line in debLines) {
        if (![line isEqual:@""]) {
            NSArray *baseURL = [self baseURLFromDebLine:line];
            [repos addObject:baseURL];
        }
    }
    
    return (NSArray *)repos;
}

- (NSArray *)baseURLFromDebLine:(NSString *)debLine {
    NSArray *urlComponents;
    
    NSArray *components = [debLine componentsSeparatedByString:@" "];
    if ([components count] > 3) { //Distribution repo, we get it, you're cool
        NSString *baseURL = components[1];
        NSString *suite = components[2];
        NSString *component = components[3];
        
        urlComponents = @[baseURL, suite, component];
    }
    else { //Normal, non-weird repo
        NSString *baseURL = components[1];
        
        urlComponents = @[baseURL];
    }
    
    return urlComponents;
}

- (void)downloadReposWithCompletion:(void (^)(NSDictionary *fileUpdates, BOOL success))completion ignoreCache:(BOOL)ignore {
    NSMutableDictionary *fnms = [NSMutableDictionary new];
    [fnms setObject:[NSMutableArray new] forKey:@"release"];
    [fnms setObject:[NSMutableArray new] forKey:@"packages"];
    dispatch_group_t downloadGroup = dispatch_group_create();
    for (int i = 0; i < repos.count; i++) {
        
        NSArray *repo = repos[i];
        
        [self postStatusUpdate:[NSString stringWithFormat:@"Downloading %@\n", repo[0]] atLevel:0];
        if ([repo count] == 3) { //dist
            [[NSNotificationCenter defaultCenter] postNotificationName:@"repoStatusUpdate" object:self userInfo:@{@"busy": @TRUE, @"row": @(i)}];
            dispatch_group_enter(downloadGroup);
            [self downloadFromURL:[NSString stringWithFormat:@"%@dists/%@/", repo[0], repo[1]] ignoreCache:ignore file:@"Release" completion:^(NSString *releaseFilename, BOOL success) {
                if (releaseFilename != NULL) {
                    [fnms[@"release"] addObject:releaseFilename];
                }
                [self downloadFromURL:[NSString stringWithFormat:@"%@dists/%@/main/binary-iphoneos-arm/", repo[0], repo[1]] ignoreCache:ignore file:@"Packages.bz2" completion:^(NSString *packageFilename, BOOL success) {
                    if (packageFilename != NULL) {
                        [fnms[@"packages"] addObject:[packageFilename stringByDeletingPathExtension]];
                    }
                    [self postStatusUpdate:[NSString stringWithFormat:@"Done %@\n", repo[0]] atLevel:0];
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"repoStatusUpdate" object:self userInfo:@{@"busy": @FALSE, @"row": @(i)}];
                    dispatch_group_leave(downloadGroup);
                }];
            }];
        }
        else { //reg
            [[NSNotificationCenter defaultCenter] postNotificationName:@"repoStatusUpdate" object:self userInfo:@{@"busy": @TRUE, @"row": @(i)}];
            dispatch_group_enter(downloadGroup);
            [self downloadFromURL:repo[0] ignoreCache:ignore file:@"Release" completion:^(NSString *releaseFilename, BOOL success) {
                if (releaseFilename != NULL) {
                    [fnms[@"release"] addObject:releaseFilename];
                }
                [self downloadFromURL:repo[0] ignoreCache:ignore file:@"Packages.bz2" completion:^(NSString *packageFilename, BOOL success) {
                    if (packageFilename != NULL) {
                        [fnms[@"packages"] addObject:[packageFilename stringByDeletingPathExtension]];
                    }
                    [self postStatusUpdate:[NSString stringWithFormat:@"Done %@\n", repo[0]] atLevel:0];
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"repoStatusUpdate" object:self userInfo:@{@"busy": @FALSE, @"row": @(i)}];
                    dispatch_group_leave(downloadGroup);
                }];
            }];
        }
    }
    
    dispatch_group_notify(downloadGroup, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^ {
        NSLog(@"[Hyena] Done");
        [[NSNotificationCenter defaultCenter] postNotificationName:@"repoStatusUpdate" object:self userInfo:@{@"finished": @TRUE}];
        completion((NSDictionary *)fnms, true);
    });
}

- (NSDictionary *)generateHeadersForFile:(NSString *)path {
    NSString *version = [[UIDevice currentDevice] systemVersion];
    NSString *udid = [[UIDevice currentDevice] identifierForVendor].UUIDString;
    
    size_t size;
    sysctlbyname("hw.machine", NULL, &size, NULL, 0);
    
    char *answer = malloc(size);
    sysctlbyname("hw.machine", answer, &size, NULL, 0);
    
    NSString *machineIdentifier = [NSString stringWithCString:answer encoding: NSUTF8StringEncoding];
    
    if (path == NULL) {
        return @{@"X-Cydia-ID" : udid, @"User-Agent" : @"Telesphoreo APT-HTTP/1.0.592", @"X-Firmware": version, @"X-Unique-ID" : udid, @"X-Machine" : machineIdentifier};
    }
    else {
        NSError *fileError;
        NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:&fileError];
        NSDate *date = fileError != nil ? [NSDate date] : [attributes fileModificationDate];
        
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        NSTimeZone *gmt = [NSTimeZone timeZoneWithAbbreviation:@"GMT"];
        [formatter setTimeZone:gmt];
        [formatter setDateFormat:@"E, d MMM yyyy HH:mm:ss"];
        
        NSString *modificationDate = [NSString stringWithFormat:@"%@ GMT", [formatter stringFromDate:date]];
        
        return @{@"If-Modified-Since": modificationDate, @"X-Cydia-ID" : udid, @"User-Agent" : @"Telesphoreo APT-HTTP/1.0.592", @"X-Firmware": version, @"X-Unique-ID" : udid, @"X-Machine" : machineIdentifier};
    }
}

- (void)downloadFromURL:(NSString *)baseURL ignoreCache:(BOOL)ignore file:(NSString *)filename completion:(void (^)(NSString *filename, BOOL success))completion {
    NSURL *base = [NSURL URLWithString:baseURL];
    NSURL *url = [base URLByAppendingPathComponent:filename];
    
    NSString *listsPath = [ZBAppDelegate listsLocation];
    NSString *schemeless = [[base absoluteString]stringByReplacingOccurrencesOfString:[url scheme] withString:@""];
    NSString *safe = [[schemeless substringFromIndex:3] stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    NSString *saveName = [NSString stringWithFormat:[baseURL rangeOfString:@"dists"].location == NSNotFound ? @"%@._%@" : @"%@%@", safe, filename];
    NSString *finalPath = [listsPath stringByAppendingPathComponent:saveName];
    
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
    configuration.HTTPAdditionalHeaders = [self generateHeadersForFile:ignore ? NULL : finalPath];
    
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    
    NSURLSessionTask *downloadTask = [session downloadTaskWithURL:url completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        if ([httpResponse statusCode] == 304) {
            NSLog(@"%@ hasn't been modified", url);
            [self postStatusUpdate:@"%@ hasn't been modified" atLevel:1];
            completion(NULL, true);
        }
        else {
            BOOL success;
            NSError *fileManagerError;
            if ([fileManager fileExistsAtPath:finalPath]) {
                success = [fileManager removeItemAtPath:finalPath error:&fileManagerError];
                NSAssert(success, @"removeItemAtPath error: %@", fileManagerError);
            }
            
            success = [fileManager moveItemAtURL:location toURL:[NSURL fileURLWithPath:finalPath] error:&fileManagerError];
            NSAssert(success, @"moveItemAtURL error: %@", fileManagerError);
            
            if ([[filename pathExtension] isEqual:@"bz2"]) {
                FILE *f = fopen([finalPath UTF8String], "r");
                FILE *output = fopen([[finalPath stringByDeletingPathExtension] UTF8String], "w");
                
                int bzError;
                BZFILE *bzf;
                char buf[4096];
                
                bzf = BZ2_bzReadOpen(&bzError, f, 0, 0, NULL, 0);
                if (bzError != BZ_OK) {
                    fprintf(stderr, "[Hyena] E: BZ2_bzReadOpen: %d\n", bzError);
                }
                
                while (bzError == BZ_OK) {
                    int nread = BZ2_bzRead(&bzError, bzf, buf, sizeof buf);
                    if (bzError == BZ_OK || bzError == BZ_STREAM_END) {
                        size_t nwritten = fwrite(buf, 1, nread, output);
                        if (nwritten != (size_t) nread) {
                            fprintf(stderr, "[Hyena] E: short write\n");
                        }
                    }
                }
                
                if (bzError != BZ_STREAM_END) {
                    fprintf(stderr, "[Hyena] E: bzip error after read: %d\n", bzError);
                }
                
                BZ2_bzReadClose(&bzError, bzf);
                fclose(f);
                fclose(output);
                
            }
            
            completion(finalPath, success);
        }
    }];
    
    [downloadTask resume];
}

@end
