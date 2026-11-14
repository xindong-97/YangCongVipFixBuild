#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static void yc_diagLog(NSString *msg);
static NSUInteger yc_tableCount(void);

static void yc_void_noop(id self, SEL _cmd) {}
static BOOL yc_bool_yes(id self, SEL _cmd) { return YES; }
static BOOL yc_bool_no(id self, SEL _cmd) { return NO; }
static BOOL yc_fireAuthYes(id self, SEL _cmd, double t, BOOL isPlayEnd) { return YES; }
static double yc_double_long(id self, SEL _cmd) { return 1e9; }
static NSString *yc_expire_2028(id self, SEL _cmd, id courseId) { return @"2028-12-31"; }
static void yc_offsetNoop(id self, SEL _cmd, double t) { (void)self; (void)_cmd; (void)t; }

static void yc_replace(Class cls, SEL sel, IMP imp) {
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (m) method_setImplementation(m, imp);
}

static void yc_replaceBool(Class cls, SEL sel, BOOL v) {
    yc_replace(cls, sel, (IMP)(v ? yc_bool_yes : yc_bool_no));
}

static void yc_replaceDouble(Class cls, SEL sel) {
    yc_replace(cls, sel, (IMP)yc_double_long);
}

static void yc_replaceClass(Class cls, SEL sel, IMP imp, IMP *origOut) {
    if (!cls) return;
    Class meta = object_getClass((id)cls);
    if (!meta) return;
    Method m = class_getInstanceMethod(meta, sel);
    if (!m) return;
    if (origOut) *origOut = method_getImplementation(m);
    method_setImplementation(m, imp);
}

static NSMutableDictionary *yc_videoAddrs;
static NSMutableSet *yc_notFoundIds;
static BOOL yc_warmDone;
static NSArray *yc_themeIds;
static BOOL yc_warmStarted;
static IMP yc_orig_getURL;
static IMP yc_orig_getHLSURLs;
static IMP yc_orig_getVideoUrlsBySuffix;
static IMP yc_orig_getVideoAddresssBySuffix;
static IMP yc_orig_handleVideoModel;
static int yc_warmRetryCount;
static NSString *yc_capturedToken;
static BOOL yc_specialRan;
static NSUInteger yc_specialRawVids;
static BOOL yc_specialRetried;

static NSString *yc_getToken(void) {
    if (yc_capturedToken.length > 0) return yc_capturedToken;
    Class mgr = objc_getClass("YCUserManager");
    if (!mgr) return nil;
    id inst = ((id (*)(id, SEL))objc_msgSend)((id)mgr, @selector(alloc));
    if (!inst) return nil;
    inst = ((id (*)(id, SEL))objc_msgSend)(inst, @selector(init));
    if (!inst) return nil;
    NSString *tok = ((NSString *(*)(id, SEL))objc_msgSend)(inst, @selector(returnUserToken));
    if (tok.length == 0) tok = ((NSString *(*)(id, SEL))objc_msgSend)(inst, @selector(userToken));
    if (tok.length == 0) {
        [inst release];
        return nil;
    }
    if ([tok hasPrefix:@"Bearer "]) {
        tok = [tok substringFromIndex:7];
        yc_diagLog(@"stripped Bearer prefix from token");
    }
    tok = [tok stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (tok.length == 0) {
        [inst release];
        return nil;
    }
    tok = [[tok copy] autorelease];
    [inst release];
    return tok;
}

static NSData *yc_fetchSync(NSString *urlStr, NSString *token, NSTimeInterval timeout) {
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url || token.length == 0) return nil;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    [req setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    [NSURLProtocol setProperty:[NSNumber numberWithBool:YES] forKey:@"YCIntercepted" inRequest:req];
    req.timeoutInterval = timeout;
    __block NSData *out = nil;
    __block BOOL done = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        if (d) out = [d retain];
        NSInteger st = 0;
        if ([r isKindOfClass:[NSHTTPURLResponse class]]) st = [(NSHTTPURLResponse *)r statusCode];
        if (e || st != 200) yc_diagLog([NSString stringWithFormat:@"fetch %@ status=%ld err=%@ bytes=%lu", urlStr, (long)st, e ? [e localizedDescription] : @"-", (unsigned long)(d ? d.length : 0)]);
        done = YES;
        dispatch_semaphore_signal(sem);
    }];
    [task resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)));
    if (!done || !out) return nil;
    return [out autorelease];
}

static id yc_fetchJSON(NSString *urlStr, NSString *token, NSTimeInterval timeout) {
    NSData *d = yc_fetchSync(urlStr, token, timeout);
    if (!d) return nil;
    return [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
}

static id yc_postJSONSync(NSString *urlStr, NSDictionary *body, NSString *token, NSTimeInterval timeout) {
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url || token.length == 0) return nil;
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    if (!bodyData) return nil;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    [req setHTTPMethod:@"POST"];
    [req setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setHTTPBody:bodyData];
    [NSURLProtocol setProperty:[NSNumber numberWithBool:YES] forKey:@"YCIntercepted" inRequest:req];
    req.timeoutInterval = timeout;
    __block NSData *out = nil;
    __block BOOL done = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        if (d) out = [d retain];
        NSInteger st = 0;
        if ([r isKindOfClass:[NSHTTPURLResponse class]]) st = [(NSHTTPURLResponse *)r statusCode];
        if (e || st != 200) yc_diagLog([NSString stringWithFormat:@"post %@ status=%ld err=%@ bytes=%lu", urlStr, (long)st, e ? [e localizedDescription] : @"-", (unsigned long)(d ? d.length : 0)]);
        done = YES;
        dispatch_semaphore_signal(sem);
    }];
    [task resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)));
    if (!done || !out) return nil;
    NSData *d = [out autorelease];
    return [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
}

static void yc_collectThemeIds(id node, NSMutableArray *out) {
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSArray *themes = node[@"themes"];
        if ([themes isKindOfClass:[NSArray class]]) {
            for (id t in themes) {
                NSString *tid = t[@"id"];
                if ([tid isKindOfClass:[NSString class]] && tid.length > 0) [out addObject:tid];
            }
        }
        for (id v in [node allValues]) yc_collectThemeIds(v, out);
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id v in node) yc_collectThemeIds(v, out);
    }
}

static void yc_storeTheme(id theme) {
    if (![theme isKindOfClass:[NSDictionary class]]) return;
    NSArray *topics = theme[@"topics"];
    if (![topics isKindOfClass:[NSArray class]]) return;
    @synchronized (yc_videoAddrs) {
        for (id tp in topics) {
            id video = tp[@"video"];
            if (![video isKindOfClass:[NSDictionary class]]) continue;
            NSArray *addrs = video[@"addresses"];
            if (![addrs isKindOfClass:[NSArray class]] || addrs.count == 0) continue;
            NSString *vid = video[@"id"];
            if ([vid isKindOfClass:[NSString class]] && vid.length > 0) yc_videoAddrs[vid] = addrs;
            NSString *vid2 = video[@"_id"];
            if ([vid2 isKindOfClass:[NSString class]] && vid2.length > 0) yc_videoAddrs[vid2] = addrs;
        }
    }
}

static NSString *yc_cachePath(void) {
    NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    if (dirs.count == 0) return nil;
    return [dirs[0] stringByAppendingPathComponent:@"yc_video_addrs.json"];
}

static void yc_loadCache(void) {
    NSString *path = yc_cachePath();
    if (!path) return;
    NSData *d = [NSData dataWithContentsOfFile:path];
    if (!d) return;
    id obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    if ([obj isKindOfClass:[NSDictionary class]]) {
        @synchronized (yc_videoAddrs) {
            [yc_videoAddrs addEntriesFromDictionary:obj];
        }
    }
}

static void yc_saveCache(void) {
    NSString *path = yc_cachePath();
    if (!path) return;
    NSDictionary *snap = nil;
    @synchronized (yc_videoAddrs) {
        if (yc_videoAddrs.count == 0) return;
        snap = [yc_videoAddrs copy];
    }
    NSData *d = [NSJSONSerialization dataWithJSONObject:snap options:0 error:nil];
    [snap release];
    if (d) [d writeToFile:path atomically:YES];
}

static NSArray *yc_themeIdsForToken(NSString *token) {
    @synchronized (yc_videoAddrs) {
        if (yc_themeIds) return yc_themeIds;
    }
    NSMutableArray *ids = [NSMutableArray array];
    for (NSNumber *sem in @[@15, @16]) {
        NSString *url = [NSString stringWithFormat:@"https://school-api.yangcong345.com/course/chapters-with-section/publisher/1/semester/%@/subject/1/stage/2", sem];
        id tree = yc_fetchJSON(url, token, 8);
        if (tree) yc_collectThemeIds(tree, ids);
    }
    @synchronized (yc_videoAddrs) {
        yc_themeIds = [ids copy];
        return yc_themeIds;
    }
}

static void yc_fetchThemeSync(NSString *tid, NSString *token, NSString *videoId) {
    @synchronized (yc_videoAddrs) {
        if (videoId && yc_videoAddrs[videoId]) return;
    }
    NSString *url = [NSString stringWithFormat:@"https://school-api.yangcong345.com/course/course-tree/themes/%@", tid];
    id theme = yc_fetchJSON(url, token, 4);
    if (theme) yc_storeTheme(theme);
}

static void yc_collectVideoIds(id node, NSMutableArray *out) {
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSString *vid = node[@"videoId"];
        if ([vid isKindOfClass:[NSString class]] && vid.length > 20) [out addObject:vid];
        for (id v in [node allValues]) yc_collectVideoIds(v, out);
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id v in node) yc_collectVideoIds(v, out);
    }
}

static void yc_storeAddressList(id resp) {
    if (![resp isKindOfClass:[NSDictionary class]]) return;
    NSArray *vl = resp[@"videoList"];
    if (![vl isKindOfClass:[NSArray class]]) return;
    @synchronized (yc_videoAddrs) {
        for (id item in vl) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            NSString *vid = item[@"videoId"];
            NSArray *addrs = item[@"address"];
            if ([vid isKindOfClass:[NSString class]] && vid.length > 0 && [addrs isKindOfClass:[NSArray class]] && addrs.count > 0) {
                yc_videoAddrs[vid] = addrs;
            }
        }
    }
}

static void yc_prefetchVideoIds(NSArray *vids, NSString *token) {
    if (!vids || vids.count == 0 || token.length == 0) return;
    NSMutableArray *todo = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    @synchronized (yc_videoAddrs) {
        for (NSString *vid in vids) {
            if (![vid isKindOfClass:[NSString class]] || vid.length == 0) continue;
            if ([seen containsObject:vid]) continue;
            [seen addObject:vid];
            if (!yc_videoAddrs[vid]) [todo addObject:vid];
        }
    }
    if (todo.count == 0) return;
    yc_diagLog([NSString stringWithFormat:@"dynamic prefetch %lu vids", (unsigned long)todo.count]);
    NSUInteger chunk = 500;
    for (NSUInteger start = 0; start < todo.count; start += chunk) {
        NSRange range = NSMakeRange(start, MIN(chunk, todo.count - start));
        NSArray *part = [todo subarrayWithRange:range];
        NSMutableArray *list = [NSMutableArray array];
        for (NSString *vid in part) [list addObject:@{@"videoId": vid}];
        NSDictionary *body = @{@"videoList": list};
        id resp = yc_postJSONSync(@"https://school-api.yangcong345.com/videos/addresses", body, token, 20);
        yc_storeAddressList(resp);
        yc_saveCache();
    }
    yc_diagLog([NSString stringWithFormat:@"dynamic prefetch done table=%lu", (unsigned long)yc_tableCount()]);
}

static NSComparisonResult yc_hlsAddrCompare(id a, id b, void *context) {
    NSDictionary *da = [a isKindOfClass:[NSDictionary class]] ? a : nil;
    NSDictionary *db = [b isKindOfClass:[NSDictionary class]] ? b : nil;
    NSString *ca = [[da[@"clarity"] description] lowercaseString];
    NSString *cb = [[db[@"clarity"] description] lowercaseString];
    NSUInteger ra = 4, rb = 4;
    if ([ca isEqualToString:@"low"]) ra = 0;
    else if ([ca isEqualToString:@"middle"]) ra = 1;
    else if ([ca isEqualToString:@"high"]) ra = 2;
    else if ([ca isEqualToString:@"fullhigh"]) ra = 3;
    if ([cb isEqualToString:@"low"]) rb = 0;
    else if ([cb isEqualToString:@"middle"]) rb = 1;
    else if ([cb isEqualToString:@"high"]) rb = 2;
    else if ([cb isEqualToString:@"fullhigh"]) rb = 3;
    if (ra != rb) return ra < rb ? NSOrderedAscending : NSOrderedDescending;
    NSString *pa = [[da[@"platform"] description] lowercaseString];
    NSString *pb = [[db[@"platform"] description] lowercaseString];
    BOOL ma = [pa isEqualToString:@"mobile"];
    BOOL mb = [pb isEqualToString:@"mobile"];
    if (ma != mb) return ma ? NSOrderedAscending : NSOrderedDescending;
    return NSOrderedSame;
}

static NSArray *yc_sortedHLSAddrs(NSArray *addrs) {
    NSMutableArray *hls = [NSMutableArray array];
    for (id a in addrs) {
        if (![a isKindOfClass:[NSDictionary class]]) continue;
        if (![[a[@"format"] description] isEqualToString:@"hls"]) continue;
        if (![[a[@"platform"] description] isEqualToString:@"mobile"]) continue;
        [hls addObject:a];
    }
    if (hls.count == 0) {
        for (id a in addrs) {
            if (![a isKindOfClass:[NSDictionary class]]) continue;
            if (![[a[@"format"] description] isEqualToString:@"hls"]) continue;
            [hls addObject:a];
        }
    }
    if (hls.count == 0) return addrs;
    NSMutableSet *have = [NSMutableSet set];
    for (id a in hls) [have addObject:[[a[@"clarity"] description] lowercaseString]];
    for (id a in addrs) {
        if (![a isKindOfClass:[NSDictionary class]]) continue;
        if (![[a[@"format"] description] isEqualToString:@"hls"]) continue;
        NSString *c = [[a[@"clarity"] description] lowercaseString];
        if (![have containsObject:c]) {
            [hls addObject:a];
            [have addObject:c];
        }
    }
    [hls sortUsingFunction:yc_hlsAddrCompare context:NULL];
    return hls;
}

static void yc_diagLog(NSString *msg) {
    static NSString *path = nil;
    static NSObject *lock = nil;
    static dispatch_once_t once = 0;
    dispatch_once(&once, ^{
        NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *doc = [dirs firstObject];
        path = [[doc stringByAppendingPathComponent:@"YangCongVipFix_diag.txt"] retain];
        lock = [[NSObject alloc] init];
    });
    @synchronized (lock) {
        NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) {
            [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        } else {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    }
}

static NSUInteger yc_tableCount(void) {
    NSUInteger n = 0;
    @synchronized (yc_videoAddrs) {
        n = yc_videoAddrs.count;
    }
    return n;
}

static void yc_prefetchSpecialCourses(NSString *token) {
    NSMutableArray *courses = [NSMutableArray array];
    NSArray *known = @[
        @{@"id": @"a820e7f0-4774-11ec-99c2-7367123a3632", @"courseType": @"total_review_package"},
        @{@"id": @"1c055db0-478c-11ec-8692-833186e50566", @"courseType": @"total_review_package"},
        @{@"id": @"fbcac940-478b-11ec-a589-e52a584942a3", @"courseType": @"total_review_package"},
        @{@"id": @"3927c350-45e4-11ec-8692-833186e50566", @"courseType": @"total_review_package"},
        @{@"id": @"03591030-481e-11ec-8229-df3407f9a8df", @"courseType": @"total_review_package"},
        @{@"id": @"62b45180-45e3-11ec-8692-833186e50566", @"courseType": @"total_review_package"},
        @{@"id": @"777c4f0e-5c16-11ed-ba0c-ba0ab9872e3a", @"courseType": @"total_review_package"},
        @{@"id": @"9b9a46b0-478e-11ec-8692-833186e50566", @"courseType": @"total_review_package"},
        @{@"id": @"11f3faf6-75fd-11ed-a6cc-ea3c33132486", @"courseType": @"total_review_package"},
        @{@"id": @"b7be155c-45a4-11f0-b491-dae869946e39", @"courseType": @"total_review_package"},
        @{@"id": @"4dc1e91e-f4d0-11ef-9fd7-9a1daf04f3fb", @"courseType": @"new_problem_type"},
        @{@"id": @"1caa6bab-0146-11ef-9272-1ad70eaae358", @"courseType": @"new_problem_type"},
        @{@"id": @"0c650748-02bd-11ef-84d1-aea51e33dbea", @"courseType": @"new_problem_type"},
        @{@"id": @"260674bf-3456-11ef-9e4a-8e9d59d085aa", @"courseType": @"new_problem_type"},
        @{@"id": @"65a12f78-0159-11ef-8577-9e782df4fecc", @"courseType": @"new_problem_type"},
        @{@"id": @"b0400f23-a222-11ef-88f9-16aad193f435", @"courseType": @"new_problem_type"},
        @{@"id": @"91d9b5a5-a222-11ef-a527-c6630ade03df", @"courseType": @"new_problem_type"},
        @{@"id": @"597e750f-893e-11f0-8d5d-e69bcf52e7b7", @"courseType": @"new_problem_type"},
        @{@"id": @"8c52c86a-893c-11f0-8d5d-e69bcf52e7b7", @"courseType": @"new_problem_type"},
        @{@"id": @"cc519e90-88b1-11f0-a820-e62dc3581e44", @"courseType": @"new_problem_type"},
        @{@"id": @"103b8d79-88aa-11f0-a820-e62dc3581e44", @"courseType": @"new_problem_type"},
    ];
    [courses addObjectsFromArray:known];
    for (NSNumber *stage in @[@1, @2, @3]) {
        NSString *url = [NSString stringWithFormat:@"https://7to12.yangcong345.com/backend/study-course/totalReview/courseList/v2?stageId=%@&courseType=total_review_package", stage];
        id resp = yc_fetchJSON(url, token, 8);
        if ([resp isKindOfClass:[NSDictionary class]]) {
            NSArray *data = resp[@"data"];
            if ([data isKindOfClass:[NSArray class]]) [courses addObjectsFromArray:data];
        }
        NSDictionary *body = @{@"stageId": stage, @"subjectId": @1, @"publisherId": @1, @"selected": @[]};
        id resp2 = yc_postJSONSync(@"https://7to12.yangcong345.com/backend/study-course/newProblemType/courseList", body, token, 8);
        if ([resp2 isKindOfClass:[NSDictionary class]]) {
            NSArray *data = resp2[@"data"];
            if ([data isKindOfClass:[NSArray class]]) [courses addObjectsFromArray:data];
        }
    }
    NSMutableArray *allVids = [NSMutableArray array];
    NSMutableSet *seenCourse = [NSMutableSet set];
    for (id c in courses) {
        if (![c isKindOfClass:[NSDictionary class]]) continue;
        NSString *cid = c[@"id"];
        NSString *ctype = c[@"courseType"];
        if (![cid isKindOfClass:[NSString class]] || cid.length == 0) continue;
        if ([seenCourse containsObject:cid]) continue;
        [seenCourse addObject:cid];
        NSString *url = nil;
        if ([ctype isEqualToString:@"new_problem_type"]) {
            url = [NSString stringWithFormat:@"https://7to12.yangcong345.com/backend/study-course/newProblemType/packageChapter?specialCourseId=%@", cid];
        } else {
            url = [NSString stringWithFormat:@"https://7to12.yangcong345.com/backend/study-course/totalReview/%@/packageChapter", cid];
        }
        id chapter = yc_fetchJSON(url, token, 8);
        if (chapter) yc_collectVideoIds(chapter, allVids);
    }
    yc_diagLog([NSString stringWithFormat:@"special chapters done rawVids=%lu", (unsigned long)allVids.count]);
    yc_specialRan = YES;
    yc_specialRawVids = allVids.count;
    if (allVids.count == 0 && yc_capturedToken.length > 0 && ![yc_capturedToken isEqualToString:token] && !yc_specialRetried) {
        yc_specialRetried = YES;
        yc_diagLog(@"special empty with captured token, retrying prefetch");
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
            @autoreleasepool {
                NSString *t = yc_getToken();
                if (t.length > 0) yc_prefetchSpecialCourses(t);
            }
        });
    }
    NSMutableArray *uniq = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (NSString *vid in allVids) {
        if (![seen containsObject:vid]) {
            [seen addObject:vid];
            [uniq addObject:vid];
        }
    }
    NSUInteger total = uniq.count;
    yc_diagLog([NSString stringWithFormat:@"special uniqVids=%lu", (unsigned long)total]);
    NSUInteger chunk = 500;
    for (NSUInteger start = 0; start < total; start += chunk) {
        NSRange range = NSMakeRange(start, MIN(chunk, total - start));
        NSArray *part = [uniq subarrayWithRange:range];
        NSMutableArray *list = [NSMutableArray array];
        for (NSString *vid in part) [list addObject:@{@"videoId": vid}];
        NSDictionary *body = @{@"videoList": list};
        id resp = yc_postJSONSync(@"https://school-api.yangcong345.com/videos/addresses", body, token, 20);
        yc_storeAddressList(resp);
        yc_saveCache();
        yc_diagLog([NSString stringWithFormat:@"special batch %lu table=%lu", (unsigned long)start, (unsigned long)yc_tableCount()]);
    }
    yc_saveCache();
}

static void yc_warmUp(void) {
    @synchronized (yc_videoAddrs) {
        if (yc_warmStarted) return;
        yc_warmStarted = YES;
    }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        @autoreleasepool {
            NSString *token = yc_getToken();
            if (token.length == 0) {
                yc_diagLog([NSString stringWithFormat:@"warmUp tokenEmpty retry=%d", yc_warmRetryCount]);
                @synchronized (yc_videoAddrs) {
                    yc_warmStarted = NO;
                }
                if (yc_warmRetryCount < 8) {
                    yc_warmRetryCount++;
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
                        yc_warmUp();
                    });
                }
                return;
            }
            yc_diagLog([NSString stringWithFormat:@"warmUp tokenLen=%lu", (unsigned long)token.length]);
            dispatch_group_t g = dispatch_group_create();
            dispatch_group_enter(g);
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
                @autoreleasepool {
                    yc_prefetchSpecialCourses(token);
                }
                dispatch_group_leave(g);
            });
            NSArray *ids = yc_themeIdsForToken(token);
            NSOperationQueue *q = [[NSOperationQueue alloc] init];
            q.maxConcurrentOperationCount = 16;
            for (NSString *tid in ids) {
                [q addOperationWithBlock:^{
                    @autoreleasepool {
                        yc_fetchThemeSync(tid, token, nil);
                    }
                }];
            }
            [q waitUntilAllOperationsAreFinished];
            [q release];
            dispatch_group_wait(g, DISPATCH_TIME_FOREVER);
            @synchronized (yc_videoAddrs) {
                yc_warmDone = YES;
                [yc_notFoundIds removeAllObjects];
            }
            yc_diagLog([NSString stringWithFormat:@"warmUp done table=%lu", (unsigned long)yc_tableCount()]);
            yc_saveCache();
        }
    });
}

static NSArray *yc_resolveViaAddresses(NSString *videoId, NSString *token, NSTimeInterval timeout, int maxAttempts) {
    NSDictionary *body = @{@"videoList": @[@{@"videoId": videoId}]};
    id resp = nil;
    for (int attempt = 0; attempt < maxAttempts && !resp; attempt++) {
        resp = yc_postJSONSync(@"https://school-api.yangcong345.com/videos/addresses", body, token, timeout);
        if (!resp) yc_diagLog([NSString stringWithFormat:@"sync %@ attempt %d respNil", videoId, attempt]);
    }
    if (![resp isKindOfClass:[NSDictionary class]]) {
        yc_diagLog([NSString stringWithFormat:@"sync %@ respNil", videoId]);
        return nil;
    }
    NSArray *list = resp[@"videoList"];
    if (![list isKindOfClass:[NSArray class]] || list.count == 0) {
        yc_diagLog([NSString stringWithFormat:@"sync %@ listEmpty", videoId]);
        return [NSArray array];
    }
    id first = list[0];
    if (![first isKindOfClass:[NSDictionary class]]) {
        yc_diagLog([NSString stringWithFormat:@"sync %@ itemBad", videoId]);
        return [NSArray array];
    }
    NSArray *addrs = first[@"address"];
    if (![addrs isKindOfClass:[NSArray class]] || addrs.count == 0) {
        yc_diagLog([NSString stringWithFormat:@"sync %@ addrEmpty", videoId]);
        return [NSArray array];
    }
    yc_diagLog([NSString stringWithFormat:@"sync %@ OK addrs=%lu", videoId, (unsigned long)addrs.count]);
    @synchronized (yc_videoAddrs) {
        yc_videoAddrs[videoId] = addrs;
    }
    yc_saveCache();
    return addrs;
}

static void yc_rescueVideo(NSString *videoId) {
    if (![videoId isKindOfClass:[NSString class]] || videoId.length == 0) return;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        @autoreleasepool {
            for (int attempt = 0; attempt < 3; attempt++) {
                @synchronized (yc_videoAddrs) {
                    if (yc_videoAddrs[videoId]) return;
                }
                NSString *t = yc_getToken();
                if (t.length == 0) return;
                NSArray *via = yc_resolveViaAddresses(videoId, t, 20, 3);
                if (via && via.count > 0) {
                    yc_diagLog([NSString stringWithFormat:@"rescue %@ OK", videoId]);
                    return;
                }
                [NSThread sleepForTimeInterval:2];
            }
            yc_diagLog([NSString stringWithFormat:@"rescue %@ FAIL", videoId]);
        }
    });
}

static NSArray *yc_resolveSync(NSString *videoId) {
    @synchronized (yc_videoAddrs) {
        NSArray *hit = yc_videoAddrs[videoId];
        if (hit) return hit;
        if ([yc_notFoundIds containsObject:videoId]) return nil;
    }
    NSString *token = yc_getToken();
    if (token.length == 0) {
        yc_diagLog([NSString stringWithFormat:@"resolve %@ noToken", videoId]);
        return nil;
    }
    NSArray *via = yc_resolveViaAddresses(videoId, token, 8, 1);
    if (via && via.count > 0) return via;
    if (via) {
        @synchronized (yc_videoAddrs) {
            [yc_notFoundIds addObject:videoId];
        }
        return nil;
    }
    yc_rescueVideo(videoId);
    @synchronized (yc_videoAddrs) {
        return yc_videoAddrs[videoId];
    }
}

static NSString *yc_pickURL(NSArray *addrs, BOOL isMiddle, BOOL isHLS) {
    NSString *wantFormat = isHLS ? @"hls" : @"mp4";
    NSString *wantClarity = isMiddle ? @"middle" : @"high";
    NSArray *order = @[
        @[@"mobile", wantFormat, wantClarity],
        @[@"mobile", @"hls", @"fullHigh"],
        @[@"mobile", @"hls", @"high"],
        @[@"mobile", @"hls", @"middle"],
        @[@"mobile", @"hls", @"low"],
        @[@"pc", @"hls", @"fullHigh"],
        @[@"pc", @"hls", @"high"],
        @[@"mobile", @"mp4", @"fullHigh"],
        @[@"mobile", @"mp4", @"high"],
        @[@"mobile", @"mp4", @"middle"]
    ];
    for (NSArray *want in order) {
        for (id a in addrs) {
            if (![a isKindOfClass:[NSDictionary class]]) continue;
            if ([a[@"platform"] isEqualToString:want[0]] && [a[@"format"] isEqualToString:want[1]] && [a[@"clarity"] isEqualToString:want[2]]) {
                NSString *u = a[@"url"];
                if ([u isKindOfClass:[NSString class]] && u.length > 0) {
                    yc_diagLog([NSString stringWithFormat:@"pickURL middle=%d hls=%d got %@/%@", isMiddle, isHLS, [a[@"clarity"] description], [a[@"platform"] description]]);
                    return u;
                }
            }
        }
    }
    for (id a in addrs) {
        if (![a isKindOfClass:[NSDictionary class]]) continue;
        if ([a[@"format"] isEqualToString:@"hls"]) {
            NSString *u = a[@"url"];
            if ([u isKindOfClass:[NSString class]] && u.length > 0) return u;
        }
    }
    for (id a in addrs) {
        if (![a isKindOfClass:[NSDictionary class]]) continue;
        NSString *u = a[@"url"];
        if ([u isKindOfClass:[NSString class]] && u.length > 0) return u;
    }
    return nil;
}

static NSString *yc_getURL(id self, SEL _cmd, BOOL isMiddle, BOOL isHLS) {
    NSString *vid = ((NSString *(*)(id, SEL))objc_msgSend)(self, @selector(Id));
    NSArray *addrs = nil;
    if ([vid isKindOfClass:[NSString class]] && vid.length > 0) {
        @synchronized (yc_videoAddrs) {
            addrs = yc_videoAddrs[vid];
        }
        if (!addrs) addrs = yc_resolveSync(vid);
    }
    if (addrs) {
        NSString *u = yc_pickURL(addrs, isMiddle, isHLS);
        if (u) return u;
    }
    return ((NSString *(*)(id, SEL, BOOL, BOOL))yc_orig_getURL)(self, _cmd, isMiddle, isHLS);
}

static NSArray *yc_getHLSURLs(id self, SEL _cmd) {
    NSString *vid = ((NSString *(*)(id, SEL))objc_msgSend)(self, @selector(Id));
    NSArray *addrs = nil;
    if ([vid isKindOfClass:[NSString class]] && vid.length > 0) {
        @synchronized (yc_videoAddrs) {
            addrs = yc_videoAddrs[vid];
        }
        if (!addrs) addrs = yc_resolveSync(vid);
    }
    if (addrs) {
        NSArray *sorted = yc_sortedHLSAddrs(addrs);
        NSMutableArray *out = [NSMutableArray array];
        NSMutableArray *cl = [NSMutableArray array];
        for (id a in sorted) {
            if (![a isKindOfClass:[NSDictionary class]]) continue;
            if (![a[@"format"] isEqualToString:@"hls"]) continue;
            NSString *u = a[@"url"];
            if ([u isKindOfClass:[NSString class]] && u.length > 0) {
                [out addObject:u];
                [cl addObject:[NSString stringWithFormat:@"%@/%@", [a[@"clarity"] description], [a[@"platform"] description]]];
            }
        }
        if (out.count > 0) {
            yc_diagLog([NSString stringWithFormat:@"hlsOrder %@ %@", vid, [cl componentsJoinedByString:@","]]);
            return out;
        }
    }
    return ((NSArray *(*)(id, SEL))yc_orig_getHLSURLs)(self, _cmd);
}

static NSArray *yc_lookupAddrs(NSString *vid) {
    NSArray *addrs = nil;
    if ([vid isKindOfClass:[NSString class]] && vid.length > 0) {
        @synchronized (yc_videoAddrs) {
            addrs = yc_videoAddrs[vid];
        }
        if (addrs) {
            yc_diagLog([NSString stringWithFormat:@"lookup %@ tableHit addrs=%lu", vid, (unsigned long)addrs.count]);
        } else {
            addrs = yc_resolveSync(vid);
            yc_diagLog([NSString stringWithFormat:@"lookup %@ syncResult=%@", vid, addrs ? [NSString stringWithFormat:@"OK addrs=%lu", (unsigned long)addrs.count] : @"FAIL"]);
        }
    }
    return addrs;
}

static NSArray *yc_addrsWithVideoId(NSArray *addrs, NSString *vid) {
    NSMutableArray *out = [NSMutableArray array];
    for (id a in addrs) {
        if (![a isKindOfClass:[NSDictionary class]]) continue;
        NSMutableDictionary *m = [a mutableCopy];
        if (vid.length > 0 && ![m objectForKey:@"videoId"]) [m setObject:vid forKey:@"videoId"];
        [out addObject:m];
        [m release];
    }
    return out;
}

static NSArray *yc_filterAddrsForSuffix(NSArray *addrs, NSString *suffix, NSString *vid) {
    NSArray *full = yc_addrsWithVideoId(addrs, vid);
    if (!suffix || suffix.length == 0) return full;
    NSString *s = [suffix lowercaseString];
    NSMutableArray *out = [NSMutableArray array];
    for (id a in full) {
        NSString *fmt = [[a[@"format"] description] lowercaseString];
        NSString *url = [[a[@"url"] description] lowercaseString];
        NSString *clar = [[a[@"clarity"] description] lowercaseString];
        BOOL hit = NO;
        if (fmt.length > 0 && ([fmt containsString:s] || [s containsString:fmt])) hit = YES;
        if (url.length > 0 && [url containsString:s]) hit = YES;
        if (clar.length > 0 && [clar containsString:s]) hit = YES;
        if (hit) [out addObject:a];
    }
    return out.count > 0 ? out : full;
}

static NSArray *yc_urlsFromAddrs(NSArray *addrs, NSString *suffix, NSString *vid) {
    NSArray *f = yc_filterAddrsForSuffix(addrs, suffix, vid);
    NSMutableArray *out = [NSMutableArray array];
    for (id a in f) {
        NSString *u = a[@"url"];
        if ([u isKindOfClass:[NSString class]] && u.length > 0) [out addObject:u];
    }
    return out;
}

static id yc_getVideoUrlsBySuffix(id self, SEL _cmd, NSString *suffix) {
    NSString *vid = ((NSString *(*)(id, SEL))objc_msgSend)(self, @selector(Id));
    NSArray *addrs = yc_lookupAddrs(vid);
    id orig = ((id (*)(id, SEL, id))yc_orig_getVideoUrlsBySuffix)(self, _cmd, suffix);
    if (addrs) {
        if ([orig isKindOfClass:[NSArray class]] && [(NSArray *)orig count] > 0) {
            id first = [(NSArray *)orig objectAtIndex:0];
            if ([first isKindOfClass:[NSDictionary class]]) {
                NSArray *f = yc_filterAddrsForSuffix(addrs, suffix, vid);
                if (f.count > 0) return f;
            }
        }
        NSArray *urls = yc_urlsFromAddrs(addrs, suffix, vid);
        if (urls.count > 0) return urls;
    }
    return orig;
}

static id yc_getVideoAddresssBySuffix(id self, SEL _cmd, NSString *suffix) {
    NSString *vid = ((NSString *(*)(id, SEL))objc_msgSend)(self, @selector(Id));
    NSArray *addrs = yc_lookupAddrs(vid);
    id orig = ((id (*)(id, SEL, id))yc_orig_getVideoAddresssBySuffix)(self, _cmd, suffix);
    if (addrs) {
        if ([orig isKindOfClass:[NSArray class]] && [(NSArray *)orig count] > 0) {
            id first = [(NSArray *)orig objectAtIndex:0];
            if ([first isKindOfClass:[NSString class]]) {
                NSArray *urls = yc_urlsFromAddrs(addrs, suffix, vid);
                if (urls.count > 0) return urls;
            }
        }
        NSArray *f = yc_filterAddrsForSuffix(addrs, suffix, vid);
        if (f.count > 0) return f;
    }
    return orig;
}

static NSArray *yc_hlsURLStrings(NSArray *addrs) {
    NSArray *sorted = yc_sortedHLSAddrs(addrs);
    NSMutableArray *out = [NSMutableArray array];
    for (id a in sorted) {
        if (![a isKindOfClass:[NSDictionary class]]) continue;
        if (![[a[@"format"] description] isEqualToString:@"hls"]) continue;
        NSString *u = a[@"url"];
        if ([u isKindOfClass:[NSString class]] && u.length > 0) [out addObject:u];
    }
    if (out.count > 0) return out;
    for (id a in addrs) {
        if (![a isKindOfClass:[NSDictionary class]]) continue;
        NSString *u = a[@"url"];
        if ([u isKindOfClass:[NSString class]] && u.length > 0) [out addObject:u];
    }
    return out;
}

static BOOL yc_urlsAreTrial(NSArray *urls) {
    if (!urls || urls.count == 0) return YES;
    for (id u in urls) {
        if (![u isKindOfClass:[NSString class]]) continue;
        if ([u containsString:@"video-demo"]) return YES;
    }
    return NO;
}

static id yc_handleVideoModel(id self, SEL _cmd, id model, id replaceURLs) {
    id item = ((id (*)(id, SEL, id, id))yc_orig_handleVideoModel)(self, _cmd, model, replaceURLs);
    if (!item) return item;
    NSArray *urls = nil;
    if ([item respondsToSelector:@selector(videoURLs)]) urls = [item videoURLs];
    if (!yc_urlsAreTrial(urls)) return item;
    NSString *vid = nil;
    if ([item respondsToSelector:@selector(videoId)]) vid = [item videoId];
    if (![vid isKindOfClass:[NSString class]] || vid.length == 0) {
        if (model && [model respondsToSelector:@selector(Id)]) vid = [model Id];
    }
    NSArray *addrs = yc_lookupAddrs(vid);
    if (!addrs) return item;
    NSArray *full = yc_hlsURLStrings(addrs);
    if (full.count == 0) return item;
    if ([item respondsToSelector:@selector(setVideoURLs:)]) {
        [item setVideoURLs:full];
    } else {
        @try { [item setValue:full forKey:@"videoURLs"]; } @catch (id e) {}
    }
    return item;
}

static NSMutableArray *yc_examIds;

static NSData *yc_rewriteCourseList(NSData *data) {
    if (!data) return data;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:NULL];
    if (![obj isKindOfClass:[NSDictionary class]]) return data;
    NSMutableDictionary *d = (NSMutableDictionary *)obj;
    NSArray *arr = d[@"data"];
    if (![arr isKindOfClass:[NSArray class]]) return data;
    for (id it in arr) {
        if (![it isKindOfClass:[NSDictionary class]]) continue;
        NSMutableDictionary *m = (NSMutableDictionary *)it;
        if ([m objectForKey:@"hasAuth"] != nil) m[@"hasAuth"] = [NSNumber numberWithBool:YES];
    }
    NSData *out = [NSJSONSerialization dataWithJSONObject:d options:0 error:NULL];
    return out ? out : data;
}

static void yc_unlockNode(id node) {
    if ([node isKindOfClass:[NSMutableDictionary class]]) {
        NSMutableDictionary *d = (NSMutableDictionary *)node;
        id unlock = d[@"unlock"];
        if ([unlock isKindOfClass:[NSNumber class]]) d[@"unlock"] = [NSNumber numberWithBool:YES];
        id pay = d[@"pay"];
        if ([pay isKindOfClass:[NSNumber class]]) d[@"pay"] = [NSNumber numberWithBool:NO];
        for (id v in [d allValues]) yc_unlockNode(v);
    } else if ([node isKindOfClass:[NSMutableArray class]]) {
        for (id v in (NSMutableArray *)node) yc_unlockNode(v);
    }
}

static NSData *yc_rewritePackageChapter(NSData *data) {
    if (!data) return data;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:NULL];
    if (!obj) return data;
    yc_unlockNode(obj);
    NSMutableArray *vids = [NSMutableArray array];
    yc_collectVideoIds(obj, vids);
    if (vids.count > 0) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
            @autoreleasepool {
                NSString *t = yc_getToken();
                if (t.length > 0) yc_prefetchVideoIds(vids, t);
            }
        });
    }
    NSData *out = [NSJSONSerialization dataWithJSONObject:obj options:0 error:NULL];
    return out ? out : data;
}

static void yc_suppressNewUserGift(void) {
    Class cls = objc_getClass("YCLoginNewUserGiftPlugin");
    if (!cls) return;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    if (!methods) return;
    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(methods[i]);
        const char *name = sel_getName(sel);
        if (!name) continue;
        NSString *lower = [[NSString stringWithUTF8String:name] lowercaseString];
        if ([lower containsString:@"show"] || [lower containsString:@"display"] || [lower containsString:@"present"] || [lower containsString:@"gift"]) {
            const char *types = method_getTypeEncoding(methods[i]);
            if (types && types[0] == 'v') {
                method_setImplementation(methods[i], (IMP)yc_void_noop);
            }
        }
    }
    free(methods);
}

static NSData *yc_rewriteExamList(NSData *data) {
    if (!data) return data;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:NULL];
    if (![obj isKindOfClass:[NSDictionary class]]) return data;
    NSMutableDictionary *d = (NSMutableDictionary *)obj;
    NSArray *arr = d[@"data"];
    if (![arr isKindOfClass:[NSArray class]]) return data;
    if (!yc_examIds) yc_examIds = [[NSMutableArray alloc] init];
    for (id it in arr) {
        if (![it isKindOfClass:[NSDictionary class]]) continue;
        NSMutableDictionary *m = (NSMutableDictionary *)it;
        NSString *pid = m[@"id"];
        if ([pid isKindOfClass:[NSString class]] && pid.length > 0 && ![yc_examIds containsObject:pid]) {
            [yc_examIds addObject:pid];
        }
        m[@"payType"] = @"free";
        m[@"pay"] = [NSNumber numberWithBool:NO];
        m[@"bigVip"] = [NSNumber numberWithBool:NO];
        m[@"payPage"] = @"";
    }
    NSData *out = [NSJSONSerialization dataWithJSONObject:d options:0 error:NULL];
    return out ? out : data;
}

static NSData *yc_rewriteExamAuth(NSData *data) {
    if (!data) return data;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:NULL];
    if (![obj isKindOfClass:[NSDictionary class]]) return data;
    NSMutableDictionary *d = (NSMutableDictionary *)obj;
    NSArray *ids = d[@"ids"];
    if ([ids isKindOfClass:[NSArray class]] && ids.count > 0) return data;
    if (yc_examIds && yc_examIds.count > 0) {
        d[@"ids"] = [[yc_examIds copy] autorelease];
        NSData *out = [NSJSONSerialization dataWithJSONObject:d options:0 error:NULL];
        return out ? out : data;
    }
    d[@"ids"] = [NSArray arrayWithObject:@"__yc_all__"];
    NSData *out = [NSJSONSerialization dataWithJSONObject:d options:0 error:NULL];
    return out ? out : data;
}

static NSData *yc_rewriteUserAuth(NSData *data) {
    if (!data) return data;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:NULL];
    if (![obj isKindOfClass:[NSDictionary class]]) return data;
    NSMutableDictionary *d = (NSMutableDictionary *)obj;
    NSArray *courseIds = [NSArray arrayWithObjects:
        @"85d020b0-9279-11ef-a259-1a169c87f377",
        @"ae08dbb2-d8bd-11f1-99a4-ca9314582017",
        @"c435655a-fd98-11ef-bb8f-42b9b0b798fb",
        @"1c055db0-478c-11ec-8692-833186e50566",
        @"4dc1e91e-f4d0-11ef-9fd7-9a1daf04f3fb", nil];
    for (NSString *key in [NSArray arrayWithObjects:@"data", @"auth", nil]) {
        id section = d[key];
        if (![section isKindOfClass:[NSDictionary class]]) continue;
        NSMutableDictionary *sec = (NSMutableDictionary *)section;
        id vipArr = sec[@"vip"];
        NSMutableArray *vipList = nil;
        if ([vipArr isKindOfClass:[NSArray class]]) {
            vipList = [vipArr mutableCopy];
        } else {
            vipList = [[NSMutableArray alloc] init];
        }
        for (NSString *vid in [NSArray arrayWithObjects:@"vip#2-1", @"vip#3-1", nil]) {
            BOOL found = NO;
            for (id e in vipList) {
                if ([e isKindOfClass:[NSDictionary class]]) {
                    if ([e[@"vipId"] isEqualToString:vid]) { found = YES; break; }
                }
            }
            if (!found) {
                [vipList addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                    vid, @"vipId",
                    @"2028-12-31", @"expireTime", [NSNumber numberWithBool:NO], @"expired", nil]];
            }
        }
        sec[@"vip"] = vipList;
        [vipList release];
        id sc = sec[@"specialCourse"];
        NSMutableArray *list = nil;
        if ([sc isKindOfClass:[NSArray class]]) {
            list = [sc mutableCopy];
        } else {
            list = [[NSMutableArray alloc] init];
        }
        for (NSString *cid in courseIds) {
            BOOL found = NO;
            for (id e in list) {
                if ([e isKindOfClass:[NSDictionary class]]) {
                    if ([e[@"courseId"] isEqualToString:cid] || [e[@"packageId"] isEqualToString:cid] || [e[@"id"] isEqualToString:cid]) { found = YES; break; }
                }
            }
            if (!found) {
                [list addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                    cid, @"courseId", cid, @"packageId", cid, @"id",
                    @"2028-12-31", @"expireTime", [NSNumber numberWithBool:NO], @"expired", nil]];
            }
        }
        sec[@"specialCourse"] = list;
        [list release];
        for (NSString *arrKey in [NSArray arrayWithObjects:@"examPaper", @"topic", @"publicTextbook", @"tenant", nil]) {
            id arr = sec[arrKey];
            NSMutableArray *al = nil;
            if ([arr isKindOfClass:[NSArray class]]) {
                al = [arr mutableCopy];
            } else {
                al = [[NSMutableArray alloc] init];
            }
            BOOL found = NO;
            for (id e in al) {
                if ([e isKindOfClass:[NSDictionary class]] && [e[@"id"] isEqualToString:@"yc_all"]) { found = YES; break; }
            }
            if (!found) {
                [al addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                    @"yc_all", @"id",
                    @"2028-12-31", @"expireTime", [NSNumber numberWithBool:NO], @"expired", nil]];
            }
            sec[arrKey] = al;
            [al release];
        }
    }
    NSData *out = [NSJSONSerialization dataWithJSONObject:d options:0 error:NULL];
    return out ? out : data;
}

@interface YCInterceptProtocol : NSURLProtocol {
    NSURLSessionDataTask *_task;
}
@end

@implementation YCInterceptProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if ([NSURLProtocol propertyForKey:@"YCIntercepted" inRequest:request]) return NO;
    NSString *host = request.URL.host;
    if ([host isEqualToString:@"7to12.yangcong345.com"]) {
        NSString *auth = [request valueForHTTPHeaderField:@"Authorization"];
        if ([auth hasPrefix:@"Bearer "]) {
            NSString *tok = [auth substringFromIndex:7];
            if (tok.length > 0) {
                BOOL isNew = NO;
                @synchronized (yc_videoAddrs) {
                    if (![tok isEqualToString:yc_capturedToken]) {
                        [yc_capturedToken release];
                        yc_capturedToken = [tok copy];
                        isNew = YES;
                    }
                }
                if (isNew) {
                    yc_diagLog([NSString stringWithFormat:@"captured token from 7to12 len=%lu", (unsigned long)tok.length]);
                    if (yc_specialRan && yc_specialRawVids == 0 && !yc_specialRetried) {
                        yc_specialRetried = YES;
                        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
                            @autoreleasepool {
                                NSString *t = yc_getToken();
                                if (t.length > 0) yc_prefetchSpecialCourses(t);
                            }
                        });
                    }
                }
            }
        }
    }
    if (![host isEqualToString:@"7to12.yangcong345.com"]) return NO;
    NSString *path = request.URL.path;
    if ([path hasPrefix:@"/backend/study-practice/examination"]) return YES;
    if ([path isEqualToString:@"/backend/api/client/userAuth"]) return YES;
    if ([path hasSuffix:@"/packageChapter"]) return YES;
    if ([path hasSuffix:@"/courseList/v2"]) return YES;
    if ([path hasSuffix:@"/newProblemType/courseList"]) return YES;
    return NO;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    NSMutableURLRequest *req = [[self.request mutableCopy] autorelease];
    [NSURLProtocol setProperty:[NSNumber numberWithBool:YES] forKey:@"YCIntercepted" inRequest:req];
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.protocolClasses = [NSArray array];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    __block YCInterceptProtocol *blockSelf = self;
    _task = [session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            [[blockSelf client] URLProtocol:blockSelf didFailWithError:error];
            return;
        }
        NSData *outData = data;
        NSString *path = blockSelf.request.URL.path;
        if ([path hasPrefix:@"/backend/study-practice/examination/auth"]) {
            outData = yc_rewriteExamAuth(data);
        } else if ([path hasPrefix:@"/backend/study-practice/examination"]) {
            outData = yc_rewriteExamList(data);
        } else if ([path isEqualToString:@"/backend/api/client/userAuth"]) {
            outData = yc_rewriteUserAuth(data);
        } else if ([path hasSuffix:@"/packageChapter"]) {
            outData = yc_rewritePackageChapter(data);
        } else if ([path hasSuffix:@"/courseList/v2"] || [path hasSuffix:@"/newProblemType/courseList"]) {
            outData = yc_rewriteCourseList(data);
        }
        NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
        NSMutableDictionary *headers = [[httpResp.allHeaderFields mutableCopy] autorelease];
        [headers setObject:[NSString stringWithFormat:@"%lu", (unsigned long)outData.length] forKey:@"Content-Length"];
        NSHTTPURLResponse *newResp = [[[NSHTTPURLResponse alloc] initWithURL:httpResp.URL statusCode:httpResp.statusCode HTTPVersion:@"HTTP/1.1" headerFields:headers] autorelease];
        [[blockSelf client] URLProtocol:blockSelf didReceiveResponse:newResp cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        [[blockSelf client] URLProtocol:blockSelf didLoadData:outData];
        [[blockSelf client] URLProtocolDidFinishLoading:blockSelf];
    }];
    [_task resume];
}

- (void)stopLoading {
    [_task cancel];
    _task = nil;
}

@end


static NSString *yc_examJS(void) {
    static NSString *js = nil;
    if (!js) js = @"(function () {\n  if (window.__yc_exam_fix) return;\n  window.__yc_exam_fix = true;\n  function walk(o) {\n    if (!o || typeof o !== \"object\") return;\n    if (o instanceof Array) { for (var i = 0; i < o.length; i++) walk(o[i]); return; }\n    if (\"payType\" in o) { o.payType = \"free\"; o.pay = false; o.bigVip = false; o.payPage = \"\"; }\n    for (var k in o) walk(o[k]);\n  }\n  function fixAuth(j) {\n    if (!j) return j;\n    if (j.ids && j.ids instanceof Array && j.ids.length === 0) j.ids = [\"__yc_all__\"];\n    if (j.data && j.data.ids && j.data.ids instanceof Array && j.data.ids.length === 0) j.data.ids = [\"__yc_all__\"];\n    return j;\n  }\n  function fixDown(j) {\n    if (!j) return j;\n    if (typeof j.auth !== \"undefined\") j.auth = true;\n    if (j.data && typeof j.data.auth !== \"undefined\") j.data.auth = true;\n    return j;\n  }\n  function fixResp(j, url) {\n    if (url.indexOf(\"/study-practice/examination/auth\") >= 0) return fixAuth(j);\n    if (url.indexOf(\"/study-practice/examination/down/auth\") >= 0) return fixDown(j);\n    if (url.indexOf(\"/study-practice/examination\") >= 0) { walk(j); return j; }\n    return j;\n  }\n  if (window.fetch) {\n    var _f = window.fetch;\n    window.fetch = function () {\n      var u = \"\";\n      try { u = typeof arguments[0] === \"string\" ? arguments[0] : (arguments[0] && arguments[0].url) || \"\"; } catch (e) {}\n      return _f.apply(this, arguments).then(function (r) {\n        if (u.indexOf(\"study-practice/examination\") < 0) return r;\n        var ct = r.headers.get(\"content-type\") || \"\";\n        if (ct.indexOf(\"application/json\") < 0) return r;\n        return r.clone().json().then(function (j) {\n          var d = fixResp(j, u);\n          return new Response(JSON.stringify(d), { status: r.status, statusText: r.statusText, headers: r.headers });\n        }).catch(function () { return r; });\n      });\n    };\n  }\n  var _open = XMLHttpRequest.prototype.open;\n  var _send = XMLHttpRequest.prototype.send;\n  XMLHttpRequest.prototype.open = function (m, u) { this.__yc_u = u; return _open.apply(this, arguments); };\n  XMLHttpRequest.prototype.send = function () {\n    var x = this;\n    var u = x.__yc_u || \"\";\n    if (u.indexOf(\"study-practice/examination\") < 0) return _send.apply(this, arguments);\n    var _o = x.onreadystatechange;\n    x.onreadystatechange = function () {\n      if (x.readyState === 4 && x.status === 200) {\n        try {\n          var j = JSON.parse(x.responseText);\n          var d = fixResp(j, u);\n          var s = JSON.stringify(d);\n          try { Object.defineProperty(x, \"responseText\", { value: s }); } catch (e) {}\n          try { Object.defineProperty(x, \"response\", { value: s }); } catch (e) {}\n        } catch (e) {}\n      }\n      if (_o) _o.apply(x, arguments);\n    };\n    return _send.apply(this, arguments);\n  };\n})();\n";
    return js;
}
static void yc_addExamScript(id ucc) {
    if (!ucc) return;
    Class usCls = objc_getClass("WKUserScript");
    if (!usCls) return;
    id script = [usCls alloc];
    script = [script initWithSource:yc_examJS() injectionTime:0 forMainFrameOnly:NO];
    [ucc addUserScript:script];
    [script release];
}
static id (*yc_orig_WKWebView_initFrame)(id, SEL, CGRect, id);
static id yc_WKWebView_initFrame(id self, SEL _cmd, CGRect frame, id config) {
    if (config) {
        id ucc = [config userContentController];
        yc_addExamScript(ucc);
    }
    return yc_orig_WKWebView_initFrame(self, _cmd, frame, config);
}
static id (*yc_orig_WKWebView_initCoder)(id, SEL, id);
static id yc_WKWebView_initCoder(id self, SEL _cmd, id coder) {
    id ret = yc_orig_WKWebView_initCoder(self, _cmd, coder);
    if (ret) {
        id config = [ret configuration];
        if (config) yc_addExamScript([config userContentController]);
    }
    return ret;
}
static void yc_hookWKWebView(void) {
    Class wk = objc_getClass("WKWebView");
    if (!wk) return;
    Method m1 = class_getInstanceMethod(wk, @selector(initWithFrame:configuration:));
    if (m1) {
        yc_orig_WKWebView_initFrame = (void *)method_getImplementation(m1);
        method_setImplementation(m1, (IMP)yc_WKWebView_initFrame);
    }
    Method m2 = class_getInstanceMethod(wk, @selector(initWithCoder:));
    if (m2) {
        yc_orig_WKWebView_initCoder = (void *)method_getImplementation(m2);
        method_setImplementation(m2, (IMP)yc_WKWebView_initCoder);
    }
}


static BOOL yc_hadAuthYes(id self, SEL _cmd, BOOL pay, id topicId, id courseId, NSInteger stageId, NSInteger subjectId, NSInteger semesterId, NSInteger publisherId) {
    yc_diagLog([NSString stringWithFormat:@"hadAuth pay=%d topic=%@ -> YES", pay, topicId]);
    return YES;
}
static void yc_injectVipIntoDict(NSMutableDictionary *d) {
    id vipArr = d[@"vip"];
    NSMutableArray *vipList = nil;
    if ([vipArr isKindOfClass:[NSArray class]]) {
        vipList = [vipArr mutableCopy];
    } else {
        vipList = [[NSMutableArray alloc] init];
    }
    for (NSString *vid in [NSArray arrayWithObjects:@"vip#2-1", @"vip#3-1", nil]) {
        BOOL found = NO;
        for (id e in vipList) {
            if ([e isKindOfClass:[NSDictionary class]] && [e[@"vipId"] isEqualToString:vid]) { found = YES; break; }
        }
        if (!found) {
            [vipList addObject:[NSDictionary dictionaryWithObjectsAndKeys:vid, @"vipId", @"2028-12-31", @"expireTime", [NSNumber numberWithBool:NO], @"expired", nil]];
        }
    }
    d[@"vip"] = vipList;
    [vipList release];
}
static void (*yc_orig_recordVipInfo)(id, SEL, id);
static void yc_recordVipInfo(id self, SEL _cmd, id response) {
    if ([response isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *m = [response mutableCopy];
        yc_injectVipIntoDict(m);
        for (NSString *key in [NSArray arrayWithObjects:@"data", @"auth", nil]) {
            id section = m[key];
            if ([section isKindOfClass:[NSDictionary class]]) {
                NSMutableDictionary *sec = [section mutableCopy];
                yc_injectVipIntoDict(sec);
                m[key] = sec;
                [sec release];
            }
        }
        yc_diagLog(@"recordVipInfo injected vip#2-1/vip#3-1");
        response = [m autorelease];
    }
    yc_orig_recordVipInfo(self, _cmd, response);
}
static void yc_hookVipManager(void) {
    Class vm = objc_getClass("YCVipManager");
    if (!vm) return;
    yc_replace(vm, @selector(hadAuthWithWithPay:topicId:courseId:stageId:subjectId:semesterId:publisherId:), (IMP)yc_hadAuthYes);
    yc_replaceBool(vm, @selector(hadAuthTrialWithTopicId:courseId:stageId:subjectId:semesterId:publisherId:), YES);
    yc_replaceBool(vm, @selector(hadAuthTrialWithTopicId:), YES);
    yc_replaceBool(vm, @selector(hadAuthTrialWithCourseId:), YES);
    yc_replaceBool(vm, @selector(hadAuthTrialWithStageId:subjectId:semesterId:publisherId:), YES);
    yc_replaceBool(vm, @selector(isShowPaymentPostWithTopicId:isPay:stageId:subjectId:semesterId:publisherId:), NO);
    yc_replaceBool(vm, @selector(isAuthSuccessWithCourseId:), YES);
    yc_replaceBool(vm, @selector(returnUserIsVip), YES);
    Method rm = class_getInstanceMethod(vm, @selector(recordVipInfoWithResponseObject:));
    if (rm) {
        yc_orig_recordVipInfo = (void *)method_getImplementation(rm);
        method_setImplementation(rm, (IMP)yc_recordVipInfo);
    }
}

__attribute__((constructor))
static void yc_init(void) {
    NSLog(@"[YangCongVipFix] v36 loaded");
    [NSURLProtocol registerClass:[YCInterceptProtocol class]];
    yc_suppressNewUserGift();
    yc_videoAddrs = [[NSMutableDictionary alloc] init];
    yc_notFoundIds = [[NSMutableSet alloc] init];
    yc_loadCache();
    yc_diagLog([NSString stringWithFormat:@"loaded v36 cacheTable=%lu", (unsigned long)yc_tableCount()]);
    yc_hookWKWebView();
    yc_hookVipManager();
    Class vip = objc_getClass("YCPlayerBusinessVipManagerPlugin");
    if (vip) {
        yc_replace(vip, @selector(fireAuthCheck:isPlayEnd:), (IMP)yc_fireAuthYes);
        yc_replace(vip, @selector(checkAuthInfo), (IMP)yc_bool_yes);
        yc_replace(vip, @selector(showBecomeAuthView), (IMP)yc_void_noop);
        yc_replace(vip, @selector(showBuyVipTips), (IMP)yc_void_noop);
        yc_replace(vip, @selector(showBuyVipHudTips), (IMP)yc_void_noop);
        yc_replace(vip, @selector(hasAuth), (IMP)yc_bool_yes);
        yc_replace(vip, @selector(isVip), (IMP)yc_bool_yes);
        yc_replace(vip, @selector(skipAuth), (IMP)yc_bool_yes);
        yc_replaceDouble(vip, @selector(tryToWatchTime));
        yc_replaceDouble(vip, @selector(realTryToWatchTime));
    }
    Class hv = objc_getClass("YCHypervideoM");
    if (hv) {
        Method m1 = class_getInstanceMethod(hv, @selector(getURLWithIsMiddle:isHLS:));
        if (m1) {
            yc_orig_getURL = method_getImplementation(m1);
            method_setImplementation(m1, (IMP)yc_getURL);
        }
        Method m2 = class_getInstanceMethod(hv, @selector(getHLSVideoURLs));
        if (m2) {
            yc_orig_getHLSURLs = method_getImplementation(m2);
            method_setImplementation(m2, (IMP)yc_getHLSURLs);
        }
        Method m3 = class_getInstanceMethod(hv, @selector(getVideoUrlsBySuffix:));
        if (m3) {
            yc_orig_getVideoUrlsBySuffix = method_getImplementation(m3);
            method_setImplementation(m3, (IMP)yc_getVideoUrlsBySuffix);
        }
        Method m4 = class_getInstanceMethod(hv, @selector(getVideoAddresssBySuffix:));
        if (m4) {
            yc_orig_getVideoAddresssBySuffix = method_getImplementation(m4);
            method_setImplementation(m4, (IMP)yc_getVideoAddresssBySuffix);
        }
    }
    Class off = objc_getClass("YCPlayerBusinessOffsetPlugin");
    if (off) {
        Method om = class_getInstanceMethod(off, @selector(onPlayerSwitchPlayTimeOffset:));
        if (om) method_setImplementation(om, (IMP)yc_offsetNoop);
    }
    yc_replaceClass(objc_getClass("YCPlayerItemTools"), @selector(handleVideoModel:replaceVideoURLs:), (IMP)yc_handleVideoModel, &yc_orig_handleVideoModel);
    Class vipInfo = objc_getClass("YCVipInfoModel");
    yc_replaceBool(vipInfo, @selector(isVipWithStageId:subjectId:), YES);
    yc_replaceBool(vipInfo, @selector(isVipWithVipType:), YES);
    yc_replaceBool(vipInfo, @selector(isVipTimeOutWithStageId:subjectId:), NO);
    yc_replaceBool(vipInfo, @selector(isPacketExpiredWithPacketId:), NO);
    yc_replaceBool(vipInfo, @selector(isPublicTextbookWithStageId:subjectId:semesterId:publisherId:), YES);
    yc_replaceBool(vipInfo, @selector(isTenantWithStageId:subjectId:), YES);
    yc_replaceBool(objc_getClass("YCUserAuthPackageModel"), @selector(checkExpired), NO);
    yc_replaceBool(objc_getClass("YCUserAuthPackageModel"), @selector(expired), NO);
    yc_replaceBool(objc_getClass("YCUserAuthNewCoursePackageModel"), @selector(checkExpired), NO);
    yc_replaceBool(objc_getClass("YCUserAuthNewCoursePackageModel"), @selector(expired), NO);
    yc_replaceBool(objc_getClass("YCSpecialCourseBookModel"), @selector(bought), YES);
    yc_replaceBool(vipInfo, @selector(isSpecialPackageIdArrayWithCourseId:), YES);
    yc_replace(vipInfo, @selector(specialCoursePackageExpireTimeWithCourseId:), (IMP)yc_expire_2028);
    yc_replaceBool(objc_getClass("YCPlayerFunctionalSwitchQualityPlugin"), @selector(isVip), YES);
    yc_replaceBool(objc_getClass("YCPlayerFunctionalSwitchQualityPlugin"), @selector(hasAuth), YES);
    yc_replaceBool(objc_getClass("YCPlayerFunctionalCachePlugin"), @selector(hasAuth), YES);
    yc_replaceBool(objc_getClass("YCPlayerFunctionalCachePlugin"), @selector(isVip), YES);
    yc_replaceBool(objc_getClass("YCPlayerAirPlayPlugin"), @selector(hasAuth), YES);
    yc_replaceBool(objc_getClass("YCPlayerAirPlayPlugin"), @selector(isVip), YES);
    yc_replaceBool(objc_getClass("YCPlayerNoteBookPlugin"), @selector(hasAuth), YES);
    yc_replaceBool(objc_getClass("YCPlayerNetworkControlPlugin"), @selector(hasAuth), YES);
    yc_replaceBool(objc_getClass("YCPlayerSecurityVideoUrlPlugin"), @selector(hasAuth), YES);
    yc_replaceBool(objc_getClass("YCPlayerBusinessPopupAdvertPlugin"), @selector(hasAuth), YES);
    yc_replaceBool(objc_getClass("YCPlayerBusinessMainStudyTimelineTipsPlugin"), @selector(timelineHasAuth), YES);
    yc_replaceBool(objc_getClass("YCPlayerBusinessMainStudyVideoEndVM"), @selector(hasAuth), YES);
    yc_replaceBool(objc_getClass("YCPlayerAIQAPlugin"), @selector(isLockMode), NO);
    yc_replaceBool(objc_getClass("YCCourceIntroductionOBPlugin"), @selector(isVip), YES);
    yc_replaceBool(objc_getClass("_TtC13YCMath_Online20YCOfflineAuthManager"), @selector(allowPlayWithTopicId:courseId:stageId:subjectId:semesterId:publisherId:), YES);
    yc_replaceBool(objc_getClass("YCLanuchADView"), @selector(showLaunch), NO);
    yc_replace(objc_getClass("UMPLaunchMessage"), @selector(displayLaunchAD), (IMP)yc_void_noop);
    yc_warmUp();
}
