#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static void yc_diagLog(NSString *msg);
static void yc_showDiagMenu(UIButton *btn);
static NSUInteger yc_tableCount(void);

static void yc_void_noop(id self, SEL _cmd) {}
static BOOL yc_bool_yes(id self, SEL _cmd) { return YES; }
static BOOL yc_bool_no(id self, SEL _cmd) { return NO; }
static BOOL yc_fireAuthYes(id self, SEL _cmd, double t, BOOL isPlayEnd) { return YES; }
static double yc_double_long(id self, SEL _cmd) { return 1e9; }
static NSString *yc_expire_2028(id self, SEL _cmd, id courseId) { return @"2028-12-31"; }
static void yc_offsetNoop(id self, SEL _cmd, double t) { (void)self; (void)_cmd; (void)t; }

static BOOL yc_replace(Class cls, SEL sel, IMP imp) {
    if (!cls) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    method_setImplementation(m, imp);
    return YES;
}

static BOOL yc_replaceBool(Class cls, SEL sel, BOOL v) {
    return yc_replace(cls, sel, (IMP)(v ? yc_bool_yes : yc_bool_no));
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
static IMP yc_orig_getCacheVideoByTag;
static IMP yc_orig_initDownloadTask;
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

static void yc_waitSemaphore(dispatch_semaphore_t sem, NSTimeInterval timeout) {
    if (![NSThread isMainThread]) {
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)));
        return;
    }
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (dispatch_semaphore_wait(sem, DISPATCH_TIME_NOW) != 0) {
        if ([deadline timeIntervalSinceNow] <= 0) break;
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
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
    yc_waitSemaphore(sem, timeout);
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
    yc_waitSemaphore(sem, timeout);
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

static NSString *yc_diagFilePath(void) {
    static NSString *p = nil;
    static dispatch_once_t once = 0;
    dispatch_once(&once, ^{
        NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *doc = [dirs firstObject];
        p = [[doc stringByAppendingPathComponent:@"YangCongVipFix_diag.txt"] retain];
    });
    return p;
}

static void yc_diagLog(NSString *msg) {
    static NSObject *lock = nil;
    static dispatch_once_t once = 0;
    dispatch_once(&once, ^{
        lock = [[NSObject alloc] init];
    });
    @synchronized (lock) {
        NSString *path = yc_diagFilePath();
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

static UIWindow *yc_diagWindow = nil;

static void yc_copyDiagOnly(UIButton *btn) {
    NSString *content = [NSString stringWithContentsOfFile:yc_diagFilePath() encoding:NSUTF8StringEncoding error:NULL];
    NSUInteger n = content ? content.length : 0;
    if (n > 0) {
        [[UIPasteboard generalPasteboard] setString:content];
    }
    yc_diagLog([NSString stringWithFormat:@"diag copied %lu bytes", (unsigned long)n]);
    [btn setTitle:@"已复制✓" forState:UIControlStateNormal];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1500 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        [btn setTitle:@"📋日志" forState:UIControlStateNormal];
    });
}

static void yc_clearDiagOnly(UIButton *btn) {
    [@"" writeToFile:yc_diagFilePath() atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    yc_diagLog(@"diag cleared");
    [btn setTitle:@"已清空✓" forState:UIControlStateNormal];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1500 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        [btn setTitle:@"📋日志" forState:UIControlStateNormal];
    });
}

@interface YCDiagButtonTarget : NSObject
+ (instancetype)shared;
- (void)buttonTapped:(id)sender;
- (void)buttonDragged:(UIPanGestureRecognizer *)g;
@end

@implementation YCDiagButtonTarget
+ (instancetype)shared {
    static YCDiagButtonTarget *s = nil;
    static dispatch_once_t once = 0;
    dispatch_once(&once, ^{ s = [[self alloc] init]; });
    return s;
}
- (void)buttonTapped:(id)sender {
    yc_diagLog(@"diag button tapped");
    yc_showDiagMenu((UIButton *)sender);
}
- (void)buttonDragged:(UIPanGestureRecognizer *)g {
    if (!yc_diagWindow) return;
    CGPoint t = [g translationInView:yc_diagWindow];
    if (g.state == UIGestureRecognizerStateChanged) {
        CGRect f = yc_diagWindow.frame;
        f.origin.x += t.x;
        f.origin.y += t.y;
        yc_diagWindow.frame = f;
        [g setTranslation:CGPointMake(0, 0) inView:yc_diagWindow];
    }
}
@end

static void yc_showDiagMenu(UIButton *btn) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"诊断日志" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    UIAlertAction *copyAction = [UIAlertAction actionWithTitle:@"复制日志" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        yc_copyDiagOnly(btn);
    }];
    UIAlertAction *clearAction = [UIAlertAction actionWithTitle:@"清空日志" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        yc_clearDiagOnly(btn);
    }];
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];
    [alert addAction:copyAction];
    [alert addAction:clearAction];
    [alert addAction:cancelAction];
    UIViewController *vc = nil;
    for (UIWindow *win in [UIApplication sharedApplication].windows) {
        if (win == yc_diagWindow) continue;
        if (win.isKeyWindow) { vc = win.rootViewController; break; }
    }
    if (!vc) {
        for (UIWindow *win in [UIApplication sharedApplication].windows) {
            if (win == yc_diagWindow) continue;
            if (win.rootViewController) { vc = win.rootViewController; break; }
        }
    }
    if (!vc) vc = yc_diagWindow.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if (!vc) return;
    UIPopoverPresentationController *pop = alert.popoverPresentationController;
    if (pop) {
        pop.sourceView = vc.view;
        CGRect r = vc.view.bounds;
        pop.sourceRect = CGRectMake(r.size.width / 2, r.size.height - 1, 1, 1);
        pop.permittedArrowDirections = 0;
    }
    [vc presentViewController:alert animated:YES completion:nil];
}

static void yc_setupDiagButton(void) {
    if (yc_diagWindow) return;
    UIScreen *scr = [UIScreen mainScreen];
    CGRect sb = scr.bounds;
    CGFloat w = 84, h = 32;
    CGRect fr = CGRectMake(sb.size.width - w - 16, sb.size.height - h - 120, w, h);
    yc_diagWindow = [[UIWindow alloc] initWithFrame:fr];
    yc_diagWindow.windowLevel = UIWindowLevelStatusBar + 1;
    yc_diagWindow.backgroundColor = [UIColor clearColor];
    for (UIWindow *win in [UIApplication sharedApplication].windows) {
        if (win.isKeyWindow && win.windowScene) {
            yc_diagWindow.windowScene = win.windowScene;
            break;
        }
    }
    yc_diagWindow.hidden = NO;
    yc_diagWindow.rootViewController = [[[UIViewController alloc] init] autorelease];
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = yc_diagWindow.bounds;
    btn.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];
    btn.layer.cornerRadius = 16;
    btn.clipsToBounds = YES;
    [btn setTitle:@"📋日志" forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont systemFontOfSize:13];
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [btn addTarget:[YCDiagButtonTarget shared] action:@selector(buttonTapped:) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:[YCDiagButtonTarget shared] action:@selector(buttonDragged:)];
    pan.cancelsTouchesInView = NO;
    [btn addGestureRecognizer:pan];
    [pan release];
    [yc_diagWindow addSubview:btn];
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
    NSArray *via = yc_resolveViaAddresses(videoId, token, 8, 2);
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

static NSArray *yc_tableAddrs(NSString *vid) {
    if (![vid isKindOfClass:[NSString class]] || vid.length == 0) return nil;
    @synchronized (yc_videoAddrs) {
        return yc_videoAddrs[vid];
    }
}

static id yc_modelFromAddrDict(id dict) {
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;
    Class addrCls = objc_getClass("YCAddressesM");
    if (!addrCls) return nil;
    SEL sel = @selector(mj_objectWithKeyValues:);
    if (![addrCls respondsToSelector:sel]) return nil;
    id m = ((id (*)(id, SEL, id))objc_msgSend)((id)addrCls, sel, dict);
    if (!m) return nil;
    return m;
}

static NSArray *yc_modelsFromAddrs(NSArray *dicts) {
    if (!dicts) return nil;
    NSMutableArray *out = [NSMutableArray array];
    for (id d in dicts) {
        id m = yc_modelFromAddrDict(d);
        if (!m) return nil;
        [out addObject:m];
    }
    return out;
}

static NSString *yc_bestDownloadTag(NSArray *addrs) {
    if (!addrs) return nil;
    NSArray *order = @[@"fullhigh", @"high", @"middle", @"low"];
    NSArray *tags = @[@"fullHigh", @"high", @"middle", @"low"];
    for (int i = 0; i < 4; i++) {
        for (id a in addrs) {
            if (![a isKindOfClass:[NSDictionary class]]) continue;
            if (![[[a[@"platform"] description] lowercaseString] isEqualToString:@"mobile"]) continue;
            if (![[[a[@"format"] description] lowercaseString] isEqualToString:@"mp4"]) continue;
            if (![[[a[@"clarity"] description] lowercaseString] isEqualToString:order[i]]) continue;
            NSString *u = a[@"url"];
            if ([u isKindOfClass:[NSString class]] && u.length > 0 && ![u containsString:@"video-demo"]) return tags[i];
        }
    }
    for (int i = 0; i < 4; i++) {
        for (id a in addrs) {
            if (![a isKindOfClass:[NSDictionary class]]) continue;
            if (![[[a[@"clarity"] description] lowercaseString] isEqualToString:order[i]]) continue;
            NSString *u = a[@"url"];
            if ([u isKindOfClass:[NSString class]] && u.length > 0 && ![u containsString:@"video-demo"]) return tags[i];
        }
    }
    return nil;
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
            } else {
                NSArray *f = yc_filterAddrsForSuffix(addrs, suffix, vid);
                if (f.count > 0) {
                    NSArray *models = yc_modelsFromAddrs(f);
                    if (models) return models;
                }
            }
        }
    }
    return orig;
}

static id yc_getCacheVideoByTag(id self, SEL _cmd, NSString *tag, NSString *suffix) {
    NSString *vid = ((NSString *(*)(id, SEL))objc_msgSend)(self, @selector(Id));
    NSArray *addrs = yc_lookupAddrs(vid);
    if (addrs) {
        NSString *wantTag = [[tag description] lowercaseString];
        NSString *wantSuffix = [[suffix description] lowercaseString];
        for (id a in addrs) {
            if (![a isKindOfClass:[NSDictionary class]]) continue;
            NSString *plat = [[a[@"platform"] description] lowercaseString];
            NSString *fmt = [[a[@"format"] description] lowercaseString];
            NSString *clar = [[a[@"clarity"] description] lowercaseString];
            if ([plat isEqualToString:@"mobile"] && [fmt isEqualToString:wantSuffix] && [clar isEqualToString:wantTag]) {
                NSString *u = a[@"url"];
                if ([u isKindOfClass:[NSString class]] && u.length > 0 && ![u containsString:@"video-demo"]) {
                    yc_diagLog([NSString stringWithFormat:@"cacheVideoByTag %@ %@/%@ tableHit", vid, tag, suffix]);
                    Class addrCls = objc_getClass("YCAddressesM");
                    return ((id (*)(id, SEL, id))objc_msgSend)((id)addrCls, @selector(mj_objectWithKeyValues:), a);
                }
            }
        }
    }
    id orig = ((id (*)(id, SEL, id, id))yc_orig_getCacheVideoByTag)(self, _cmd, tag, suffix);
    if ([orig isKindOfClass:[NSArray class]]) return orig;
    if (orig) {
        NSString *u = nil;
        if ([orig respondsToSelector:@selector(url)]) u = [orig url];
        else {
            @try { u = [orig valueForKey:@"url"]; } @catch (id e) {}
        }
        if ([u isKindOfClass:[NSString class]] && u.length > 0) {
            if ([u containsString:@"video-demo"]) {
                yc_diagLog([NSString stringWithFormat:@"cacheVideoByTag %@ %@/%@ origTrial", vid, tag, suffix]);
                return nil;
            }
            return orig;
        }
        yc_diagLog([NSString stringWithFormat:@"cacheVideoByTag %@ %@/%@ origEmpty", vid, tag, suffix]);
        return nil;
    }
    return nil;
}

static id yc_initDownloadTask(id self, SEL _cmd, id videoInfo, id topicInfo, id subsectionId, long long subjectId, long long stageId, long long publisherId, long long semesterId, id courseId, BOOL isVideoClip, id extraData) {
    id useExtra = extraData;
    NSString *tag = nil;
    if ([extraData isKindOfClass:[NSDictionary class]]) tag = extraData[@"targetDownloadQuality"];
    if ((!tag || [tag isEqualToString:@"middle"]) && videoInfo) {
        NSArray *addrs = nil;
        @try { addrs = [videoInfo addresses]; } @catch (id e) { addrs = nil; }
        if (!addrs || [addrs count] == 0) {
            NSString *vid = nil;
            @try { vid = [videoInfo Id]; } @catch (id e) { vid = nil; }
            if ([vid isKindOfClass:[NSString class]] && vid.length > 0) {
                NSArray *table = yc_tableAddrs(vid);
                NSString *best = yc_bestDownloadTag(table);
                if (best && ![best isEqualToString:tag]) {
                    NSMutableDictionary *m = nil;
                    if ([extraData isKindOfClass:[NSDictionary class]]) m = [[extraData mutableCopy] autorelease];
                    if (!m) m = [NSMutableDictionary dictionary];
                    [m setObject:best forKey:@"targetDownloadQuality"];
                    useExtra = m;
                    yc_diagLog([NSString stringWithFormat:@"dlTag %@ %@->%@", vid, tag ? tag : @"nil", best]);
                }
            }
        }
    }
    return ((id (*)(id, SEL, id, id, id, long long, long long, long long, long long, id, BOOL, id))yc_orig_initDownloadTask)(self, _cmd, videoInfo, topicInfo, subsectionId, subjectId, stageId, publisherId, semesterId, courseId, isVideoClip, useExtra);
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
        @"a820e7f0-4774-11ec-99c2-7367123a3632",
        @"1c055db0-478c-11ec-8692-833186e50566",
        @"3927c350-45e4-11ec-8692-833186e50566",
        @"03591030-481e-11ec-8229-df3407f9a8df",
        @"62b45180-45e3-11ec-8692-833186e50566",
        @"777c4f0e-5c16-11ed-ba0c-ba0ab9872e3a",
        @"9b9a46b0-478e-11ec-8692-833186e50566",
        @"11f3faf6-75fd-11ed-a6cc-ea3c33132486",
        @"b7be155c-45a4-11f0-b491-dae869946e39",
        @"fbcac940-478b-11ec-a589-e52a584942a3",
        @"4dc1e91e-f4d0-11ef-9fd7-9a1daf04f3fb",
        @"1caa6bab-0146-11ef-9272-1ad70eaae358",
        @"0c650748-02bd-11ef-84d1-aea51e33dbea",
        @"260674bf-3456-11ef-9e4a-8e9d59d085aa",
        @"65a12f78-0159-11ef-8577-9e782df4fecc",
        @"b0400f23-a222-11ef-88f9-16aad193f435",
        @"91d9b5a5-a222-11ef-a527-c6630ade03df",
        @"597e750f-893e-11f0-8d5d-e69bcf52e7b7",
        @"8c52c86a-893c-11f0-8d5d-e69bcf52e7b7",
        @"cc519e90-88b1-11f0-a820-e62dc3581e44",
        @"103b8d79-88aa-11f0-a820-e62dc3581e44", nil];
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
                    if ([e[@"id"] isEqualToString:vid] || [e[@"vipId"] isEqualToString:vid]) { found = YES; break; }
                }
            }
            if (!found) {
                [vipList addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                    vid, @"id",
                    vid, @"vipId",
                    @"2028-12-31T23:59:59.999Z", @"expireTime", [NSNumber numberWithBool:NO], @"expired", nil]];
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
                    @"2028-12-31T23:59:59.999Z", @"expireTime", [NSNumber numberWithBool:NO], @"expired", nil]];
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
                    @"2028-12-31T23:59:59.999Z", @"expireTime", [NSNumber numberWithBool:NO], @"expired", nil]];
            }
            sec[arrKey] = al;
            [al release];
        }
    }
    NSData *out = [NSJSONSerialization dataWithJSONObject:d options:0 error:NULL];
    return out ? out : data;
}

static NSData *yc_rewriteTelesaleQR(NSData *data) {
    if (!data) return data;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:NULL];
    if (![obj isKindOfClass:[NSDictionary class]]) return data;
    NSMutableDictionary *d = (NSMutableDictionary *)obj;
    if (d[@"show"] != nil) d[@"show"] = [NSNumber numberWithBool:NO];
    if ([d[@"data"] isKindOfClass:[NSDictionary class]] && d[@"data"][@"show"] != nil) d[@"data"][@"show"] = [NSNumber numberWithBool:NO];
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
    if ([path hasPrefix:@"/backend/go-revenue/telesale/qrcode"]) return YES;
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
        } else if ([path hasPrefix:@"/backend/go-revenue/telesale/qrcode"]) {
            outData = yc_rewriteTelesaleQR(data);
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
    if (!js) js = @"(function () {\n  if (window.__yc_exam_fix) return;\n  window.__yc_exam_fix = true;\n  function yc_patchOnionUtils() { try { var ou = window.onionUtils; if (!ou || ou.__yc_ou_patched) return; ou.__yc_ou_patched = true; ou.isVip = function() { return Promise.resolve({isVip: true}); }; ou.isPublicTextBookVip = function() { return Promise.resolve({isPublicTextBookVip: true}); }; } catch (e) {} }\n  yc_patchOnionUtils();\n  var yc_ouCount = 0;\n  var yc_ouTimer = setInterval(function() { yc_patchOnionUtils(); yc_ouCount++; if (yc_ouCount > 50) clearInterval(yc_ouTimer); }, 200);\n  document.addEventListener('DOMContentLoaded', yc_patchOnionUtils);\n  function walk(o) {\n    if (!o || typeof o !== \"object\") return;\n    if (o instanceof Array) { for (var i = 0; i < o.length; i++) walk(o[i]); return; }\n    if (\"payType\" in o) { o.payType = \"free\"; o.pay = false; o.bigVip = false; o.payPage = \"\"; }\n    for (var k in o) walk(o[k]);\n  }\n  function fixAuth(j) {\n    if (!j) return j;\n    if (j.ids && j.ids instanceof Array && j.ids.length === 0) j.ids = [\"__yc_all__\"];\n    if (j.data && j.data.ids && j.data.ids instanceof Array && j.data.ids.length === 0) j.data.ids = [\"__yc_all__\"];\n    return j;\n  }\n  function fixDown(j) {\n    if (!j) return j;\n    if (typeof j.auth !== \"undefined\") j.auth = true;\n    if (j.data && typeof j.data.auth !== \"undefined\") j.data.auth = true;\n    return j;\n  }\n  function fixUserAuth(j) {\n    if (!j) return j;\n    var ids = [\"a820e7f0-4774-11ec-99c2-7367123a3632\", \"1c055db0-478c-11ec-8692-833186e50566\", \"3927c350-45e4-11ec-8692-833186e50566\", \"03591030-481e-11ec-8229-df3407f9a8df\", \"62b45180-45e3-11ec-8692-833186e50566\", \"777c4f0e-5c16-11ed-ba0c-ba0ab9872e3a\", \"9b9a46b0-478e-11ec-8692-833186e50566\", \"11f3faf6-75fd-11ed-a6cc-ea3c33132486\", \"b7be155c-45a4-11f0-b491-dae869946e39\", \"fbcac940-478b-11ec-a589-e52a584942a3\", \"4dc1e91e-f4d0-11ef-9fd7-9a1daf04f3fb\", \"1caa6bab-0146-11ef-9272-1ad70eaae358\", \"0c650748-02bd-11ef-84d1-aea51e33dbea\", \"260674bf-3456-11ef-9e4a-8e9d59d085aa\", \"65a12f78-0159-11ef-8577-9e782df4fecc\", \"b0400f23-a222-11ef-88f9-16aad193f435\", \"91d9b5a5-a222-11ef-a527-c6630ade03df\", \"597e750f-893e-11f0-8d5d-e69bcf52e7b7\", \"8c52c86a-893c-11f0-8d5d-e69bcf52e7b7\", \"cc519e90-88b1-11f0-a820-e62dc3581e44\", \"103b8d79-88aa-11f0-a820-e62dc3581e44\"];\n    var secs = [];\n    if (j.auth && typeof j.auth === \"object\") secs.push(j.auth);\n    if (j.data && typeof j.data === \"object\") secs.push(j.data);\n    for (var s = 0; s < secs.length; s++) {\n      var sc = secs[s].specialCourse;\n      if (!(sc instanceof Array)) sc = secs[s].specialCourse = [];\n      for (var i = 0; i < ids.length; i++) {\n        var found = false;\n        for (var k = 0; k < sc.length; k++) { if (sc[k] && sc[k].id === ids[i]) { found = true; break; } }\n        if (!found) sc.push({id: ids[i], expired: false, expireTime: \"2028-12-31T23:59:59.999Z\"});\n      }\n    }\n    return j;\n  }\n  function fixStudyPlan(j, url) {\n    if (!j) return j;\n    if (url.indexOf(\"userSupplementContentList\") >= 0) {\n      if (j.userClassInfo && j.userClassInfo.authScope) {\n        j.userClassInfo.authScope.hasSystem = true;\n        j.userClassInfo.authScope.hasPackage = true;\n      }\n      return j;\n    }\n    if (url.indexOf(\"getClassUserAuth\") >= 0) {\n      if (j.authScope) { j.authScope.hasSystem = true; j.authScope.hasPackage = true; }\n      return j;\n    }\n    if (url.indexOf(\"userDailyCourseContent\") >= 0) {\n      if (j.classInfos instanceof Array)\n        for (var i = 0; i < j.classInfos.length; i++)\n          if (j.classInfos[i].authScope) {\n            j.classInfos[i].authScope.hasSystem = true;\n            j.classInfos[i].authScope.hasPackage = true;\n          }\n      return j;\n    }\n    return j;\n  }\n  function fixConfig(j, url) {\n    if (!j) return j;\n    if (url.indexOf(\"topicKey=aIClassAppFetch\") >= 0 && j.content) {\n      j.content.isAppFetch = false;\n    }\n    return j;\n  }\n\n  var yc_cat = [[\"d23977f6-96a8-11ef-a581-322be264e7a0\",\"specialCourse\"],[\"f22d4be1-96a8-11ef-a581-322be264e7a0\",\"specialCourse\"],[\"0b07c057-96a9-11ef-a581-322be264e7a0\",\"specialCourse\"],[\"aef06544-96a8-11ef-bff4-0658ebb04ccd\",\"specialCourse\"],[\"3e760f1b-92af-11ef-878c-4a6756bc614b\",\"specialCourse\"],[\"1-1\",\"vip\"],[\"1-3\",\"vip\"],[\"1-5\",\"vip\"],[\"bd772bfe-11c0-11ef-9f45-46decbf5b1ce\",\"specialCourse\"],[\"a820e7f0-4774-11ec-99c2-7367123a3632\",\"specialCourse\"],[\"b1e632fc-be7a-11ef-82f4-fad1a46e625b\",\"specialCourse\"],[\"2-1\",\"vip\"],[\"2-2\",\"vip\"],[\"2-3\",\"vip\"],[\"2-4\",\"vip\"],[\"2-5\",\"vip\"],[\"2-6\",\"vip\"],[\"2-7\",\"vip\"],[\"2-12\",\"vip\"],[\"2-11\",\"vip\"],[\"73f2d910-ecd4-11ee-8f65-4a156de36ad3\",\"specialCourse\"],[\"d903b400-477f-11ec-99c2-7367123a3632\",\"specialCourse\"],[\"1caa6bab-0146-11ef-9272-1ad70eaae358\",\"specialCourse\"],[\"3927c350-45e4-11ec-8692-833186e50566\",\"specialCourse\"],[\"0c650748-02bd-11ef-84d1-aea51e33dbea\",\"specialCourse\"],[\"03591030-481e-11ec-8229-df3407f9a8df\",\"specialCourse\"],[\"260674bf-3456-11ef-9e4a-8e9d59d085aa\",\"specialCourse\"],[\"62b45180-45e3-11ec-8692-833186e50566\",\"specialCourse\"],[\"65a12f78-0159-11ef-8577-9e782df4fecc\",\"specialCourse\"],[\"777c4f0e-5c16-11ed-ba0c-ba0ab9872e3a\",\"specialCourse\"],[\"b0400f23-a222-11ef-88f9-16aad193f435\",\"specialCourse\"],[\"9b9a46b0-478e-11ec-8692-833186e50566\",\"specialCourse\"],[\"91d9b5a5-a222-11ef-a527-c6630ade03df\",\"specialCourse\"],[\"11f3faf6-75fd-11ed-a6cc-ea3c33132486\",\"specialCourse\"],[\"3-1\",\"vip\"],[\"3-2\",\"vip\"],[\"3-3\",\"vip\"],[\"3-4\",\"vip\"],[\"3-5\",\"vip\"],[\"3-6\",\"vip\"],[\"3-7\",\"vip\"],[\"3-12\",\"vip\"],[\"3-20\",\"vip\"],[\"8c52c86a-893c-11f0-8d5d-e69bcf52e7b7\",\"specialCourse\"],[\"2bd05600-f598-11eb-a031-33dd886fa8a3\",\"specialCourse\"],[\"00a1717d-5c16-11ed-9a60-5a71264b3cb2\",\"specialCourse\"],[\"632ae5fd-df8e-11ee-a0f2-0a3aac206c7f\",\"specialCourse\"],[\"cc519e90-88b1-11f0-a820-e62dc3581e44\",\"specialCourse\"],[\"afdcca5f-f86e-11ed-9740-56a786333721\",\"specialCourse\"],[\"b9a9bb04-9e49-11ee-93bf-92f08eae0850\",\"specialCourse\"],[\"e0635359-39af-11ef-b4a4-a21b41052db6\",\"specialCourse\"],[\"b7be155c-45a4-11f0-b491-dae869946e39\",\"specialCourse\"],[\"597e750f-893e-11f0-8d5d-e69bcf52e7b7\",\"specialCourse\"],[\"1988e4fd-f86c-11ed-9740-56a786333721\",\"specialCourse\"],[\"027f5cc9-9e48-11ee-b12b-62fca951e227\",\"specialCourse\"],[\"66e68b08-3517-11ef-9728-466cfef96f89\",\"specialCourse\"],[\"0d6e797b-23da-11ef-a12a-e698fa38aecc\",\"specialCourse\"],[\"5ba0a16b-c68a-11ef-a2a3-b21f167755fc\",\"specialCourse\"],[\"103b8d79-88aa-11f0-a820-e62dc3581e44\",\"specialCourse\"],[\"1150e31b-7c49-11ed-b2b0-567debafa38e\",\"specialCourse\"],[\"83be3944-7076-11ed-9007-5af931e9b70a\",\"specialCourse\"],[\"647e443a-39b8-11ef-b4a4-a21b41052db6\",\"specialCourse\"],[\"4-1\",\"vip\"],[\"4-5\",\"vip\"],[\"134b1d69-70e1-11ef-8021-ee09e4051482\",\"specialCourse\"],[\"d8106390-7013-11ef-bd4e-52f137073ff5\",\"specialCourse\"],[\"abde60b0-7a41-11ef-a160-62d0dec790e9\",\"specialCourse\"],[\"ac7eba4c-7974-11ef-96e2-a63db9483fa9\",\"specialCourse\"],[\"examPaper-1\",\"examPaper\"],[\"examPaper-2\",\"examPaper\"],[\"examPaper-3\",\"examPaper\"],[\"fdb3599a-015f-11ef-8577-9e782df4fecc\",\"specialCourse\"],[\"dd10ab86-2c82-11ef-8964-aefe5499df7e\",\"specialCourse\"],[\"2fcf4aac-982d-11f0-8af5-9a153f0e117f\",\"specialCourse\"],[\"4dfb53e3-840c-11f1-80b8-9a889e6330d5\",\"specialCourse\"],[\"c2e4c984-2d7b-11f1-abb5-9680e772c5df\",\"specialCourse\"],[\"aec80fe0-2d7b-11f1-abb5-9680e772c5df\",\"specialCourse\"],[\"5df22d25-ccb7-11ef-8a55-bad6399d39d5\",\"specialCourse\"],[\"40ad0330-ccb8-11ef-8a55-bad6399d39d5\",\"specialCourse\"],[\"b50db118-ccb7-11ef-8a55-bad6399d39d5\",\"specialCourse\"],[\"ff551613-3aab-11f0-a6e5-06aa6bcb409c\",\"specialCourse\"]];\n  var yc_learn = {};\n  var yc_learn_fallback = {\n    \"初中化学同步课\": \"https://7to12.yangcong345.com/study-app/courses/system?subjectId=4&stageId=2&publisherId=&semesterId=\",\n    \"初中化学培优课\": \"https://7to12.yangcong345.com/study-app/totalReviewLandscape/newTotalReview?stageId=2&courseType=total_review_package&subjectId=4&specialCourseId=62b45180-45e3-11ec-8692-833186e50566\",\n    \"初中历史同步课\": \"https://7to12.yangcong345.com/study-app/courses/system?subjectId=12&stageId=2&publisherId=&semesterId=\",\n    \"初中地理同步课\": \"https://7to12.yangcong345.com/study-app/courses/system?subjectId=7&stageId=2&publisherId=&semesterId=\",\n    \"初中地理培优课\": \"https://7to12.yangcong345.com/study-app/totalReviewLandscape/newTotalReview?stageId=2&courseType=total_review_package&subjectId=7&specialCourseId=11f3faf6-75fd-11ed-a6cc-ea3c33132486\",\n    \"初中数学同步课\": \"https://7to12.yangcong345.com/study-app/courses/system?subjectId=1&stageId=2&publisherId=&semesterId=\",\n    \"初中数学培优课\": \"https://7to12.yangcong345.com/study-app/totalReviewLandscape/newTotalReview?stageId=2&courseType=total_review_package&subjectId=1&packageId=&specialCourseId=fbcac940-478b-11ec-a589-e52a584942a3\",\n    \"初中物理同步课\": \"https://7to12.yangcong345.com/study-app/courses/system?subjectId=2&stageId=2&publisherId=&semesterId=\",\n    \"初中物理培优课\": \"https://7to12.yangcong345.com/study-app/totalReviewLandscape/newTotalReview?stageId=2&courseType=total_review_package&subjectId=2&specialCourseId=3927c350-45e4-11ec-8692-833186e50566\",\n    \"初中生物同步课\": \"https://7to12.yangcong345.com/study-app/courses/system?subjectId=6&stageId=2&publisherId=&semesterId=\",\n    \"初中生物培优课\": \"https://7to12.yangcong345.com/study-app/totalReviewLandscape/newTotalReview?stageId=2&courseType=total_review_package&subjectId=6&specialCourseId=9b9a46b0-478e-11ec-8692-833186e50566\",\n    \"初中英语同步课\": \"https://7to12.yangcong345.com/study-app/courses/system?subjectId=5&stageId=2&publisherId=&semesterId=\",\n    \"初中英语培优课\": \"https://7to12.yangcong345.com/study-app/totalReviewLandscape/newTotalReview?&stageId=2&courseType=total_review_package&subjectId=5&packageId=&specialCourseId=777c4f0e-5c16-11ed-ba0c-ba0ab9872e3a\",\n    \"初中语文同步课\": \"https://7to12.yangcong345.com/study-app/courses/system?subjectId=3&stageId=2&publisherId=&semesterId=\",\n    \"初中语文培优课\": \"https://7to12.yangcong345.com/study-app/totalReviewLandscape/newTotalReview?stageId=2&courseType=total_review_package&subjectId=3&packageId=&specialCourseId=03591030-481e-11ec-8229-df3407f9a8df\",\n    \"初中道德与法治同步课\": \"https://7to12.yangcong345.com/study-app/courses/system?subjectId=11&stageId=2&publisherId=&semesterId=\",\n    \"初升高衔接课\": \"https://7to12.yangcong345.com/study-app/courses/special?courseId=dd10ab86-2c82-11ef-8964-aefe5499df7e\",\n    \"小初高甄选试卷库\": \"https://7to12.yangcong345.com/study-app/testPreparationTools/chapterList?defaultTab=examPaper&isHideTab=true&stageId=2\",\n};\n  var yc_shopNameMap = {\n    \"初中化学培优课\": \"初中化学新中考培优课\",\n    \"初中地理培优课\": \"初中地理新中考培优课\",\n    \"初中数学培优课\": \"初中数学新中考培优课\",\n    \"初中物理培优课\": \"初中物理新中考培优课\",\n    \"初中生物培优课\": \"初中生物新中考培优课\",\n    \"初中英语培优课\": \"初中英语新中考培优课\",\n    \"初中语文培优课\": \"初中语文新中考培优课\",\n    \"小初高甄选试卷库\": \"初中试卷库\",\n};\n  function fixIdentityResource(j) {\n    if (!j) return j;\n    var cr = j.courseRights;\n    if (!(cr instanceof Array) && j.data && j.data.courseRights instanceof Array) cr = j.data.courseRights;\n    if (cr instanceof Array && cr.length > 0) {\n      var live = [];\n      var learn = {};\n      for (var i = 0; i < cr.length; i++) {\n        var g = cr[i];\n        if (!g) continue;\n        if (g.courses instanceof Array) {\n          for (var k = 0; k < g.courses.length; k++) {\n            var c = g.courses[k];\n            if (c && c.id) live.push([c.id, c.targetType || \"specialCourse\"]);\n            if (c && c.name && c.learnPage) learn[c.name] = c.learnPage;\n          }\n        } else if (g.id) {\n          live.push([g.id, g.targetType || \"specialCourse\"]);\n          if (g.name && g.learnPage) learn[g.name] = g.learnPage;\n        }\n      }\n      if (live.length > 0) yc_cat = live;\n      for (var n in learn) yc_learn[n] = learn[n];\n    }\n    return j;\n  }\n  var yc_keptTagIds = {};\n  function fixShop(j) {\n    if (!j) return j;\n    var list = null;\n    var holder = null;\n    if (j.result && j.result.list instanceof Array) { list = j.result.list; holder = j.result; }\n    else if (j.data && j.data.result && j.data.result.list instanceof Array) { list = j.data.result.list; holder = j.data.result; }\n    if (!list) return j;\n    for (var i = 0; i < list.length; i++) {\n      var it = list[i];\n      if (!it || typeof it.name !== \"string\" || typeof it.page !== \"string\") continue;\n      var catName = yc_shopNameMap[it.name] || it.name;\n      var lp = yc_learn[catName] || yc_learn_fallback[it.name];\n      if (lp) it.page = lp;\n    }\n    var kept = [];\n    for (var k = 0; k < list.length; k++) {\n      var it2 = list[k];\n      if (!it2) continue;\n      if (it2.goodsType === \"周边\" || it2.goodsType === \"pad\") continue;\n      if (typeof it2.name === \"string\" && it2.name.indexOf(\"研学\") >= 0) continue;\n      if (typeof it2.name === \"string\" && it2.name.indexOf(\"重难点题型\") >= 0) continue;\n      kept.push(it2);\n      if (it2.courseTypeId) yc_keptTagIds[it2.courseTypeId] = true;\n    }\n    holder.list = kept;\n    return j;\n  }\n  var yc_bypassNames = [\"初中语文同步课\", \"初中物理同步课\", \"初中数学同步课\", \"初中地理同步课\", \"初中生物同步课\", \"初中化学同步课\", \"初中英语同步课\", \"初中道德与法治同步课\", \"初中历史同步课\", \"初中语文培优课\", \"初中地理培优课\", \"初中生物培优课\", \"初中数学培优课\", \"初中物理培优课\", \"初中化学培优课\", \"初中英语培优课\", \"初升高衔接课\", \"小初高甄选试卷库\"];\n  function yc_fixBuyNode(tn) {\n    if (!tn || tn.nodeValue !== \"去购买\") return;\n    var el = tn.parentNode;\n    for (var d = 0; d < 10 && el; d++) {\n      var txt = \"\";\n      try { txt = el.textContent || \"\"; } catch (e) {}\n      var hit = null;\n      var hits = 0;\n      for (var i = 0; i < yc_bypassNames.length; i++) {\n        if (txt.indexOf(yc_bypassNames[i]) >= 0) { hit = yc_bypassNames[i]; hits++; }\n      }\n      if (hits === 1) { tn.nodeValue = \"已开通\"; return; }\n      if (hits > 1) return;\n      el = el.parentNode;\n    }\n  }\n  function yc_scanBuyText(root) {\n    if (!root) return;\n    try {\n      var w = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null, false);\n      var n;\n      var list = [];\n      while ((n = w.nextNode())) { if (n.nodeValue === \"去购买\") list.push(n); }\n      for (var i = 0; i < list.length; i++) yc_fixBuyNode(list[i]);\n    } catch (e) {}\n  }\n  function yc_buyTextStart() {\n    try {\n      if (location.href.indexOf(\"discover2026\") < 0) return;\n      if (!document.body) return;\n      yc_scanBuyText(document.body);\n      if (window.MutationObserver) {\n        var ob = new MutationObserver(function (muts) {\n          if (location.href.indexOf(\"discover2026\") < 0) return;\n          for (var i = 0; i < muts.length; i++) {\n            var mu = muts[i];\n            if (mu.type === \"characterData\" && mu.target && mu.target.nodeValue === \"去购买\") yc_fixBuyNode(mu.target);\n            if (mu.type === \"childList\") {\n              for (var k = 0; k < mu.addedNodes.length; k++) {\n                var nd = mu.addedNodes[k];\n                if (!nd) continue;\n                if (nd.nodeType === 3) { if (nd.nodeValue === \"去购买\") yc_fixBuyNode(nd); }\n                else if (nd.nodeType === 1) yc_scanBuyText(nd);\n              }\n            }\n          }\n        });\n        ob.observe(document.body, { childList: true, subtree: true, characterData: true });\n      }\n    } catch (e) {}\n  }\n  function yc_fixExpBadge() {\n    try {\n      if (!document.body) return;\n      function sweepText(root) {\n        if (!root) return;\n        try {\n          var w = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null, false);\n          var nn;\n          var list = [];\n          while ((nn = w.nextNode())) { if (nn.nodeValue && nn.nodeValue.trim() === \"特价体验\") list.push(nn); }\n          for (var i = 0; i < list.length; i++) list[i].nodeValue = \"首席研究员\";\n        } catch (e) {}\n      }\n      sweepText(document.body);\n      if (window.MutationObserver) {\n        var ob = new MutationObserver(function (muts) {\n          for (var i = 0; i < muts.length; i++) {\n            var mu = muts[i];\n            if (mu.type === \"characterData\" && mu.target && mu.target.nodeValue && mu.target.nodeValue.trim() === \"特价体验\") mu.target.nodeValue = \"首席研究员\";\n            if (mu.type === \"childList\") {\n              for (var k = 0; k < mu.addedNodes.length; k++) {\n                var nd = mu.addedNodes[k];\n                if (!nd) continue;\n                if (nd.nodeType === 3) { if (nd.nodeValue && nd.nodeValue.trim() === \"特价体验\") nd.nodeValue = \"首席研究员\"; }\n                else if (nd.nodeType === 1) sweepText(nd);\n              }\n            }\n          }\n        });\n        ob.observe(document.body, { childList: true, subtree: true, characterData: true });\n      }\n    } catch (e) {}\n  }\n  function fixIdentityStatus(j) {\n    if (!j) return j;\n    var ids = [\"exclusiveIdentityLabel\", \"exclusiveAchievement\", \"exclusiveDeskOrnament\", \"pkRewardsDoubled\", \"exclusiveEmojiPack\"];\n    function inj(t) {\n      if (!t || typeof t !== \"object\") return;\n      if (typeof t.identity !== \"undefined\") t.identity = \"lead\";\n      if (typeof t.identityExpiredTime !== \"undefined\") t.identityExpiredTime = \"2028-12-31T23:59:59.999Z\";\n      var ir = t.identityRights;\n      if (!(ir instanceof Array)) ir = t.identityRights = [];\n      for (var n = 0; n < ids.length; n++) {\n        var f2 = false;\n        for (var m = 0; m < ir.length; m++) { if (ir[m] && ir[m].id === ids[n]) { f2 = true; break; } }\n        if (!f2) ir.push({id: ids[n]});\n      }\n      var cr = t.courseRights;\n      if (!(cr instanceof Array)) cr = t.courseRights = [];\n      for (var i = 0; i < yc_cat.length; i++) {\n        var found = false;\n        for (var k = 0; k < cr.length; k++) { if (cr[k] && cr[k].id === yc_cat[i][0]) { found = true; break; } }\n        if (!found) cr.push({id: yc_cat[i][0], expireTime: \"2028-12-31T23:59:59.999Z\", targetType: yc_cat[i][1]});\n      }\n    }\n    inj(j);\n    if (j.data && typeof j.data === \"object\") inj(j.data);\n    return j;\n  }\n  function fixBanner(j, url) {\n    if (!j) return j;\n    var holders = [];\n    if (j.banners instanceof Array) holders.push(j);\n    if (j.data && j.data.banners instanceof Array) holders.push(j.data);\n    if (holders.length === 0) return j;\n    if (url.indexOf(\"bannerPosition=responsiveMyTabMarketingCard\") >= 0) {\n      for (var h = 0; h < holders.length; h++) holders[h].banners = [];\n      return j;\n    }\n    for (var h = 0; h < holders.length; h++) {\n      var kept = [];\n      var arr = holders[h].banners;\n      for (var i = 0; i < arr.length; i++) {\n        var it = arr[i];\n        var tgt = (it && it.navigateTarget) || \"\";\n        var act = (it && it.activityType) || \"\";\n        var nm = (it && it.name) || \"\";\n        if (tgt.indexOf(\"miniprogram/qrcode/continue\") >= 0) continue;\n        if (act === \"DRAINAGE\") continue;\n        if (nm.indexOf(\"双十一\") >= 0) continue;\n        if (nm.indexOf(\"双11\") >= 0) continue;\n        if (tgt.indexOf(\"sell-998\") >= 0) continue;\n        if (act === \"FISSION\") continue;\n        if (nm.indexOf(\"研学\") >= 0) continue;\n        if (nm.indexOf(\"青春开播\") >= 0) continue;\n        kept.push(it);\n      }\n      holders[h].banners = kept;\n    }\n    return j;\n  }\n  function fixTreasure(j) {\n    if (!j) return j;\n    var arr = null;\n    if (j.data instanceof Array) arr = j.data;\n    if (!arr) return j;\n    var kept = [];\n    for (var i = 0; i < arr.length; i++) {\n      var it = arr[i];\n      var href = (it && it.hrefUrl) || \"\";\n      if (href.indexOf(\"sell-998\") >= 0) continue;\n      kept.push(it);\n    }\n    j.data = kept;\n    return j;\n  }\n  function fixTreasureTags(j) {\n    if (!j) return j;\n    var arr = null;\n    var holder = null;\n    if (j.result instanceof Array) { arr = j.result; holder = j; }\n    else if (j.data && j.data.result instanceof Array) { arr = j.data.result; holder = j.data; }\n    if (!arr || !holder) return j;\n    var n = 0;\n    for (var k in yc_keptTagIds) n++;\n    if (n === 0) return j;\n    var kept = [];\n    for (var i = 0; i < arr.length; i++) {\n      var it = arr[i];\n      if (it && it.id && yc_keptTagIds[it.id]) kept.push(it);\n    }\n    if (kept.length === 0) return j;\n    holder.result = kept;\n    return j;\n  }\n  function fixPackageChapter(j) {\n    if (!j) return j;\n    function unlockTopics(o) {\n      if (!o || typeof o !== \"object\") return;\n      if (o instanceof Array) { for (var i = 0; i < o.length; i++) unlockTopics(o[i]); return; }\n      if (o.levelType === \"topic\" && typeof o.unlock !== \"undefined\") o.unlock = true;\n      for (var k in o) unlockTopics(o[k]);\n    }\n    unlockTopics(j);\n    return j;\n  }\n  function fixTabExperiment(j) {\n    if (!j) return j;\n    if (typeof j.isStart !== \"undefined\") j.isStart = false;\n    if (\"cardTypeA\" in j) j.cardTypeA = null;\n    if (j.data && typeof j.data === \"object\") {\n      if (typeof j.data.isStart !== \"undefined\") j.data.isStart = false;\n      if (\"cardTypeA\" in j.data) j.data.cardTypeA = null;\n    }\n    return j;\n  }\n  function fixNpcConfig(j) {\n    if (!j) return j;\n    if (j.configMap instanceof Array) j.configMap = [];\n    if (j.data && j.data.configMap instanceof Array) j.data.configMap = [];\n    return j;\n  }\n  function fixNpcDialogue(j) {\n    if (!j) return j;\n    if (\"npcDialogue\" in j) j.npcDialogue = [];\n    if (j.data && \"npcDialogue\" in j.data) j.data.npcDialogue = [];\n    return j;\n  }\n  function fixRookie(j) {\n    if (!j) return j;\n    if (typeof j.checkInEntryDisplay !== \"undefined\") j.checkInEntryDisplay = false;\n    if (typeof j.hasClaimableTask !== \"undefined\") j.hasClaimableTask = false;\n    if (j.data && typeof j.data === \"object\") {\n      if (typeof j.data.checkInEntryDisplay !== \"undefined\") j.data.checkInEntryDisplay = false;\n      if (typeof j.data.hasClaimableTask !== \"undefined\") j.data.hasClaimableTask = false;\n    }\n    return j;\n  }\n  function fixPopUpInfo(j) {\n    if (!j) return j;\n    if (typeof j.isPopUp !== \"undefined\") j.isPopUp = false;\n    if (j.data && typeof j.data.isPopUp !== \"undefined\") j.data.isPopUp = false;\n    return j;\n  }\n  function fixGroup(j) {\n    if (!j) return j;\n    if (typeof j.isShowWechat !== \"undefined\") j.isShowWechat = false;\n    if (j.data && typeof j.data.isShowWechat !== \"undefined\") j.data.isShowWechat = false;\n    return j;\n  }\n  function fixTelesaleQR(j) {\n    if (!j) return j;\n    if (typeof j.show !== \"undefined\") j.show = false;\n    if (j.data && typeof j.data.show !== \"undefined\") j.data.show = false;\n    return j;\n  }\n  function fixPlayAddr(j) {\n    if (!j) return j;\n    var vl = j.videoList;\n    if (!(vl instanceof Array)) return j;\n    for (var i = 0; i < vl.length; i++) {\n      var it = vl[i];\n      if (!it || !(it.address instanceof Array)) continue;\n      var has = false;\n      for (var k = 0; k < it.address.length; k++) {\n        var a = it.address[k];\n        if (a && a.platform === \"mobile\" && a.format === \"mp4\" && a.clarity === \"fullHigh\") { has = true; break; }\n      }\n      if (!has) it.address.push({index: 0, clarity: \"fullHigh\", name: \"超高清\", url: \"\", format: \"mp4\", platform: \"mobile\", md5: \"\"});\n    }\n    return j;\n  }\n  function fixResp(j, url) {\n    if (url.indexOf(\"userSupplementContentList\") >= 0 || url.indexOf(\"getClassUserAuth\") >= 0 || url.indexOf(\"userDailyCourseContent\") >= 0) return fixStudyPlan(j, url);\n    if (url.indexOf(\"course-mall/position/identity/status\") >= 0) return fixIdentityStatus(j);\n    if (url.indexOf(\"course-mall/position/identity/resource\") >= 0) return fixIdentityResource(j);\n    if (url.indexOf(\"configByKey\") >= 0) return fixConfig(j, url);\n    if (url.indexOf(\"/banner?\") >= 0) return fixBanner(j, url);\n    if (url.indexOf(\"tab_ab_experiment\") >= 0) return fixTabExperiment(j);\n    if (url.indexOf(\"getAllSceneNpcConfig\") >= 0) return fixNpcConfig(j);\n    if (url.indexOf(\"getSceneNpcDialogue\") >= 0) return fixNpcDialogue(j);\n    if (url.indexOf(\"rookie/ab\") >= 0) return fixRookie(j);\n    if (url.indexOf(\"getPopUpInfo\") >= 0) return fixPopUpInfo(j);\n    if (url.indexOf(\"study-task/homepage/group\") >= 0) return fixGroup(j);\n    if (url.indexOf(\"/revenue/telesale/qrcode\") >= 0) return fixTelesaleQR(j);\n    if (url.indexOf(\"shop-course-good/batch\") >= 0) return fixShop(j);\n    if (url.indexOf(\"treasure/card/h5/list\") >= 0) return fixTreasure(j);\n    if (url.indexOf(\"treasure-tags\") >= 0) return fixTreasureTags(j);\n    if (url.indexOf(\"newProblemType/packageChapter\") >= 0) return fixPackageChapter(j);\n    if (url.indexOf(\"userAuth\") >= 0) return fixUserAuth(j);\n    if (url.indexOf(\"/study-practice/examination/auth\") >= 0) return fixAuth(j);\n    if (url.indexOf(\"/study-practice/examination/down/auth\") >= 0) return fixDown(j);\n    if (url.indexOf(\"/study-practice/examination\") >= 0) { walk(j); return j; }\n    if (url.indexOf(\"/study-course/v2/video/play/addr\") >= 0) return fixPlayAddr(j);\n    if (url.indexOf(\"/comment/review/show?\") >= 0) { if (j && typeof j.show !== \"undefined\") j.show = true; return j; }\n    return j;\n  }\n  function want(u) { return u.indexOf(\"study-practice/examination\") >= 0 || u.indexOf(\"userAuth\") >= 0 || u.indexOf(\"userSupplementContentList\") >= 0 || u.indexOf(\"getClassUserAuth\") >= 0 || u.indexOf(\"userDailyCourseContent\") >= 0 || u.indexOf(\"configByKey\") >= 0 || u.indexOf(\"course-mall/position/identity/status\") >= 0 || u.indexOf(\"course-mall/position/identity/resource\") >= 0 || u.indexOf(\"/banner?\") >= 0 || u.indexOf(\"tab_ab_experiment\") >= 0 || u.indexOf(\"getAllSceneNpcConfig\") >= 0 || u.indexOf(\"getSceneNpcDialogue\") >= 0 || u.indexOf(\"rookie/ab\") >= 0 || u.indexOf(\"getPopUpInfo\") >= 0 || u.indexOf(\"study-task/homepage/group\") >= 0 || u.indexOf(\"/revenue/telesale/qrcode\") >= 0 || u.indexOf(\"shop-course-good/batch\") >= 0 || u.indexOf(\"treasure/card/h5/list\") >= 0 || u.indexOf(\"treasure-tags\") >= 0 || u.indexOf(\"newProblemType/packageChapter\") >= 0 || u.indexOf(\"/study-course/v2/video/play/addr\") >= 0 || u.indexOf(\"/comment/review/show?\") >= 0; }\n  if (window.fetch) {\n    var _f = window.fetch;\n    window.fetch = function () {\n      var u = \"\";\n      try { u = typeof arguments[0] === \"string\" ? arguments[0] : (arguments[0] && arguments[0].url) || \"\"; } catch (e) {}\n      return _f.apply(this, arguments).then(function (r) {\n        if (!want(u)) return r;\n        var ct = r.headers.get(\"content-type\") || \"\";\n        if (ct.indexOf(\"application/json\") < 0) return r;\n        return r.clone().json().then(function (j) {\n          var d = fixResp(j, u);\n          return new Response(JSON.stringify(d), { status: r.status, statusText: r.statusText, headers: r.headers });\n        }).catch(function () { return r; });\n      });\n    };\n  }\n  var _open = XMLHttpRequest.prototype.open;\n  var _send = XMLHttpRequest.prototype.send;\n  XMLHttpRequest.prototype.open = function (m, u) { this.__yc_u = u; return _open.apply(this, arguments); };\n  XMLHttpRequest.prototype.send = function () {\n    var x = this;\n    var u = x.__yc_u || \"\";\n    if (!want(u)) return _send.apply(this, arguments);\n    var _o = x.onreadystatechange;\n    x.onreadystatechange = function () {\n      if (x.readyState === 4 && x.status === 200) {\n        try {\n          var j = JSON.parse(x.responseText);\n          var d = fixResp(j, u);\n          var s = JSON.stringify(d);\n          try { Object.defineProperty(x, \"responseText\", { value: s }); } catch (e) {}\n          try { Object.defineProperty(x, \"response\", { value: s }); } catch (e) {}\n        } catch (e) {}\n      }\n      if (_o) _o.apply(x, arguments);\n    };\n    return _send.apply(this, arguments);\n  };\n  if (document.readyState === \"loading\") {\n    document.addEventListener(\"DOMContentLoaded\", yc_buyTextStart);\n    document.addEventListener(\"DOMContentLoaded\", yc_fixExpBadge);\n  } else {\n    yc_buyTextStart();\n    yc_fixExpBadge();\n  }\n})();\n";;;;;
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
            if ([e isKindOfClass:[NSDictionary class]] && ([e[@"id"] isEqualToString:vid] || [e[@"vipId"] isEqualToString:vid])) { found = YES; break; }
        }
        if (!found) {
            [vipList addObject:[NSDictionary dictionaryWithObjectsAndKeys:vid, @"id", vid, @"vipId", @"2028-12-31T23:59:59.999Z", @"expireTime", [NSNumber numberWithBool:NO], @"expired", nil]];
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
    if (!vm) {
        yc_diagLog(@"hookVipManager class NIL");
        return;
    }
    BOOL a = yc_replace(vm, @selector(hadAuthWithWithPay:topicId:courseId:stageId:subjectId:semesterId:publisherId:), (IMP)yc_hadAuthYes);
    BOOL b = yc_replaceBool(vm, @selector(hadAuthTrialWithTopicId:courseId:stageId:subjectId:semesterId:publisherId:), YES);
    BOOL c = yc_replaceBool(vm, @selector(hadAuthTrialWithTopicId:), YES);
    BOOL d = yc_replaceBool(vm, @selector(hadAuthTrialWithCourseId:), YES);
    BOOL e = yc_replaceBool(vm, @selector(hadAuthTrialWithStageId:subjectId:semesterId:publisherId:), YES);
    BOOL f = yc_replaceBool(vm, @selector(isShowPaymentPostWithTopicId:isPay:stageId:subjectId:semesterId:publisherId:), NO);
    BOOL g = yc_replaceBool(vm, @selector(isAuthSuccessWithCourseId:), YES);
    BOOL h = yc_replaceBool(vm, @selector(returnUserIsVip), YES);
    Method rm = class_getInstanceMethod(vm, @selector(recordVipInfoWithResponseObject:));
    BOOL i = NO;
    if (rm) {
        yc_orig_recordVipInfo = (void *)method_getImplementation(rm);
        method_setImplementation(rm, (IMP)yc_recordVipInfo);
        i = YES;
    }
    yc_diagLog([NSString stringWithFormat:@"hookVipManager hadAuth=%d trial=%d/%d/%d/%d payPost=%d authOK=%d isVip=%d recordVip=%d", a, b, c, d, e, f, g, h, i]);
}
static id (*yc_orig_getEncryptBody)(id, SEL, id);
static id yc_getEncryptBody(id self, SEL _cmd, id response) {
    id result = yc_orig_getEncryptBody(self, _cmd, response);
    NSString *cls = NSStringFromClass([self class]);
    if ([cls isEqualToString:@"YCQueryOperationPopupCMD"] || [cls isEqualToString:@"YCWelcomeConfigCMD"] || [cls isEqualToString:@"YCWelcomeConfigTimeoutCMD"]) {
        if ([result isKindOfClass:[NSArray class]]) {
            yc_diagLog(@"decrypt cleared popup/welcome");
            return [NSArray array];
        }
        return result;
    }
    if ([result isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = (NSDictionary *)result;
        NSMutableDictionary *m = nil;
        if (d[@"showPoint"] != nil) {
            m = [d mutableCopy];
            m[@"showPoint"] = [NSNumber numberWithBool:NO];
            yc_diagLog(@"decrypt cleared trialVouchers showPoint");
        }
        if (d[@"red_point"] != nil) {
            if (!m) m = [d mutableCopy];
            m[@"red_point"] = @"close";
            yc_diagLog(@"decrypt cleared red_point");
        }
        id dataSec = d[@"data"];
        id authSec = d[@"auth"];
        if ([dataSec isKindOfClass:[NSDictionary class]] && [authSec isKindOfClass:[NSDictionary class]]) {
            if (!m) m = [d mutableCopy];
            NSMutableDictionary *dataCopy = [dataSec mutableCopy];
            yc_injectVipIntoDict(dataCopy);
            m[@"data"] = dataCopy;
            [dataCopy release];
            NSMutableDictionary *authCopy = [authSec mutableCopy];
            yc_injectVipIntoDict(authCopy);
            m[@"auth"] = authCopy;
            [authCopy release];
            yc_diagLog(@"decrypt injected vip#2-1/vip#3-1");
        }
        if ([dataSec isKindOfClass:[NSDictionary class]] && (dataSec[@"opAd"] != nil || dataSec[@"edAd"] != nil || dataSec[@"pauseAd"] != nil)) {
            if (!m) m = [d mutableCopy];
            NSMutableDictionary *dataCopy = [dataSec mutableCopy];
            if (dataCopy[@"opAd"] != nil) dataCopy[@"opAd"] = [NSArray array];
            if (dataCopy[@"edAd"] != nil) dataCopy[@"edAd"] = [NSArray array];
            if (dataCopy[@"pauseAd"] != nil) dataCopy[@"pauseAd"] = [NSArray array];
            m[@"data"] = dataCopy;
            [dataCopy release];
            yc_diagLog(@"decrypt cleared patchAdvertising");
        }
        if (m) return [m autorelease];
        return result;
    }
    if ([result isKindOfClass:[NSArray class]]) {
        NSArray *arr = (NSArray *)result;
        BOOL hasHot = NO;
        BOOL hasPreload = NO;
        for (id item in arr) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            if (item[@"hotAreaList"] != nil || item[@"hotAreaListV"] != nil) hasHot = YES;
            if (item[@"type"] != nil && item[@"md5"] != nil) hasPreload = YES;
        }
        if (hasHot) {
            NSMutableArray *out = [NSMutableArray arrayWithCapacity:[arr count]];
            for (id item in arr) {
                if ([item isKindOfClass:[NSDictionary class]] && (item[@"hotAreaList"] != nil || item[@"hotAreaListV"] != nil)) {
                    NSMutableDictionary *mi = [[item mutableCopy] autorelease];
                    mi[@"hotAreaList"] = [NSArray array];
                    mi[@"hotAreaListV"] = [NSArray array];
                    [out addObject:mi];
                } else {
                    [out addObject:item];
                }
            }
            yc_diagLog(@"decrypt cleared player_block hotArea");
            return out;
        }
        if (hasPreload) {
            NSMutableArray *out = [NSMutableArray array];
            for (id item in arr) {
                if ([item isKindOfClass:[NSDictionary class]]) {
                    NSString *t = item[@"type"];
                    if ([t isEqualToString:@"coopen"] || [t isEqualToString:@"popup"]) continue;
                }
                [out addObject:item];
            }
            yc_diagLog(@"decrypt filtered preloadResources");
            return out;
        }
        return result;
    }
    return result;
}
static void yc_hookDecrypt(void) {
    Class c = objc_getClass("YCMathRequest");
    if (!c) {
        yc_diagLog(@"hookDecrypt class NIL");
        return;
    }
    Method m = class_getInstanceMethod(c, @selector(getEncryptBodyWithResponse:));
    if (!m) {
        yc_diagLog(@"hookDecrypt method NIL");
        return;
    }
    yc_orig_getEncryptBody = (id (*)(id, SEL, id))method_getImplementation(m);
    method_setImplementation(m, (IMP)yc_getEncryptBody);
    yc_diagLog(@"hookDecrypt getEncryptBody=1");
}

__attribute__((constructor))
static void yc_init(void) {
    NSLog(@"[YangCongVipFix] v54 loaded");
    [NSURLProtocol registerClass:[YCInterceptProtocol class]];
    yc_suppressNewUserGift();
    yc_videoAddrs = [[NSMutableDictionary alloc] init];
    yc_notFoundIds = [[NSMutableSet alloc] init];
    yc_loadCache();
    yc_diagLog([NSString stringWithFormat:@"loaded v54 cacheTable=%lu", (unsigned long)yc_tableCount()]);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        yc_setupDiagButton();
    });
    yc_hookWKWebView();
    yc_hookVipManager();
    yc_hookDecrypt();
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
        Method m5 = class_getInstanceMethod(hv, @selector(getCacheVideoByTag:suffix:));
        if (m5) {
            yc_orig_getCacheVideoByTag = method_getImplementation(m5);
            method_setImplementation(m5, (IMP)yc_getCacheVideoByTag);
        }
    }
    Class dt = objc_getClass("YCVideoDownloadTask");
    if (dt) {
        Method dm = class_getInstanceMethod(dt, @selector(initWithVideoInfo:topicInfo:subsectionId:subjectId:stageId:publisherId:semesterId:courseId:isVideoClip:extraData:));
        if (dm) {
            yc_orig_initDownloadTask = method_getImplementation(dm);
            method_setImplementation(dm, (IMP)yc_initDownloadTask);
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
