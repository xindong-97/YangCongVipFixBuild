#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

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

static NSString *yc_getToken(void) {
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
    tok = [[tok copy] autorelease];
    [inst release];
    return tok;
}

static NSData *yc_fetchSync(NSString *urlStr, NSString *token, NSTimeInterval timeout) {
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url || token.length == 0) return nil;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    [req setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    req.timeoutInterval = timeout;
    __block NSData *out = nil;
    __block BOOL done = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        if (d) out = [d retain];
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
    req.timeoutInterval = timeout;
    __block NSData *out = nil;
    __block BOOL done = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        if (d) out = [d retain];
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

static void yc_prefetchSpecialCourses(NSString *token) {
    NSMutableArray *courses = [NSMutableArray array];
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
    NSMutableArray *uniq = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (NSString *vid in allVids) {
        if (![seen containsObject:vid]) {
            [seen addObject:vid];
            [uniq addObject:vid];
        }
    }
    NSUInteger total = uniq.count;
    NSUInteger chunk = 500;
    for (NSUInteger start = 0; start < total; start += chunk) {
        NSRange range = NSMakeRange(start, MIN(chunk, total - start));
        NSArray *part = [uniq subarrayWithRange:range];
        NSMutableArray *list = [NSMutableArray array];
        for (NSString *vid in part) [list addObject:@{@"videoId": vid}];
        NSDictionary *body = @{@"videoList": list};
        id resp = yc_postJSONSync(@"https://school-api.yangcong345.com/videos/addresses", body, token, 20);
        yc_storeAddressList(resp);
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
            yc_prefetchSpecialCourses(token);
            @synchronized (yc_videoAddrs) {
                yc_warmDone = YES;
            }
            yc_saveCache();
        }
    });
}

static NSArray *yc_resolveViaAddresses(NSString *videoId, NSString *token) {
    NSDictionary *body = @{@"videoList": @[@{@"videoId": videoId}]};
    id resp = yc_postJSONSync(@"https://school-api.yangcong345.com/videos/addresses", body, token, 3);
    if (![resp isKindOfClass:[NSDictionary class]]) return nil;
    NSArray *list = resp[@"videoList"];
    if (![list isKindOfClass:[NSArray class]] || list.count == 0) return nil;
    id first = list[0];
    if (![first isKindOfClass:[NSDictionary class]]) return nil;
    NSArray *addrs = first[@"address"];
    if (![addrs isKindOfClass:[NSArray class]] || addrs.count == 0) return nil;
    @synchronized (yc_videoAddrs) {
        yc_videoAddrs[videoId] = addrs;
    }
    yc_saveCache();
    return addrs;
}

static NSArray *yc_resolveSync(NSString *videoId) {
    @synchronized (yc_videoAddrs) {
        NSArray *hit = yc_videoAddrs[videoId];
        if (hit) return hit;
        if ([yc_notFoundIds containsObject:videoId]) return nil;
    }
    NSString *token = yc_getToken();
    if (token.length == 0) return nil;
    BOOL warmDone = NO;
    @synchronized (yc_videoAddrs) {
        warmDone = yc_warmDone;
    }
    if (warmDone) {
        NSArray *via = yc_resolveViaAddresses(videoId, token);
        if (via) return via;
        @synchronized (yc_videoAddrs) {
            [yc_notFoundIds addObject:videoId];
        }
        return nil;
    }
    NSArray *ids = yc_themeIdsForToken(token);
    NSOperationQueue *q = [[NSOperationQueue alloc] init];
    q.maxConcurrentOperationCount = 8;
    for (NSString *tid in ids) {
        [q addOperationWithBlock:^{
            @autoreleasepool {
                yc_fetchThemeSync(tid, token, videoId);
            }
        }];
    }
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
    NSArray *hit = nil;
    while ([deadline timeIntervalSinceNow] > 0) {
        @synchronized (yc_videoAddrs) {
            hit = yc_videoAddrs[videoId];
            if (hit) break;
        }
        if (q.operationCount == 0) break;
        [NSThread sleepForTimeInterval:0.05];
    }
    [q cancelAllOperations];
    [q release];
    if (hit) return hit;
    NSArray *via = yc_resolveViaAddresses(videoId, token);
    if (via) return via;
    @synchronized (yc_videoAddrs) {
        [yc_notFoundIds addObject:videoId];
        return yc_videoAddrs[videoId];
    }
}

static NSString *yc_pickURL(NSArray *addrs, BOOL isMiddle, BOOL isHLS) {
    NSString *wantFormat = isHLS ? @"hls" : @"mp4";
    NSString *wantClarity = isMiddle ? @"middle" : @"high";
    NSArray *order = @[
        @[@"mobile", wantFormat, wantClarity],
        @[@"mobile", @"hls", @"high"],
        @[@"mobile", @"hls", @"middle"],
        @[@"mobile", @"hls", @"low"],
        @[@"pc", @"hls", @"high"],
        @[@"mobile", @"mp4", @"high"],
        @[@"mobile", @"mp4", @"middle"]
    ];
    for (NSArray *want in order) {
        for (id a in addrs) {
            if (![a isKindOfClass:[NSDictionary class]]) continue;
            if ([a[@"platform"] isEqualToString:want[0]] && [a[@"format"] isEqualToString:want[1]] && [a[@"clarity"] isEqualToString:want[2]]) {
                NSString *u = a[@"url"];
                if ([u isKindOfClass:[NSString class]] && u.length > 0) return u;
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
        NSMutableArray *out = [NSMutableArray array];
        for (id a in addrs) {
            if (![a isKindOfClass:[NSDictionary class]]) continue;
            if (![a[@"format"] isEqualToString:@"hls"]) continue;
            NSString *u = a[@"url"];
            if ([u isKindOfClass:[NSString class]] && u.length > 0) [out addObject:u];
        }
        if (out.count > 0) return out;
    }
    return ((NSArray *(*)(id, SEL))yc_orig_getHLSURLs)(self, _cmd);
}

static NSArray *yc_lookupAddrs(NSString *vid) {
    NSArray *addrs = nil;
    if ([vid isKindOfClass:[NSString class]] && vid.length > 0) {
        @synchronized (yc_videoAddrs) {
            addrs = yc_videoAddrs[vid];
        }
        if (!addrs) addrs = yc_resolveSync(vid);
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
    NSMutableArray *out = [NSMutableArray array];
    for (id a in addrs) {
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

__attribute__((constructor))
static void yc_init(void) {
    NSLog(@"[YangCongVipFix] v23 loaded");
    [NSURLProtocol registerClass:[YCInterceptProtocol class]];
    yc_suppressNewUserGift();
    yc_videoAddrs = [[NSMutableDictionary alloc] init];
    yc_notFoundIds = [[NSMutableSet alloc] init];
    yc_loadCache();
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
