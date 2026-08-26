// RatioBar.x — like/dislike ratio bar on feed thumbnails, via the Return YouTube Dislike API.
//
// How it finds a video: ELMImageNode.URL holds the thumbnail URL, which contains /vi/<videoID>/.
// Grid thumbnails land on container nodes, so the image node is found by walking down through
// yogaChildren. Bars are parented to the enclosing _ASCollectionViewCell's contentView, which
// survives node relayout, and tracked per-thumbnail so a carousel cell can hold several.

#import "Headers.h"
#import <objc/runtime.h>

static const CGFloat kBarHeight = 5.0;
static const NSTimeInterval kCacheTTL = 600;      // 10 minutes
static const NSUInteger kMaxConcurrentFetches = 4;
static const NSUInteger kMaxCacheEntries = 600;
static const NSTimeInterval kRevalidateInterval = 2.0;  // seconds between ID re-derivations

// Validated pair: ΔE 21.1 under simulated CVD, passes light and dark.
// Softer alternative: like #2A9D8F, dislike #D9704B.
#define YM_LIKE_COLOR    [UIColor colorWithRed:0.243 green:0.561 blue:0.851 alpha:1.0]  // #3E8FD9
#define YM_DISLIKE_COLOR [UIColor colorWithRed:0.898 green:0.329 blue:0.294 alpha:1.0]  // #E5544B

static NSMutableDictionary *gVotes;    // videoID -> @{@"l", @"d", @"t"}
static NSMutableSet *gInFlight;
static NSMutableArray *gPending;       // videoIDs waiting for a fetch slot
static NSMutableDictionary *gWaiters;  // videoID -> NSHashTable of thumb views (weak)
static NSMutableSet *gDirtyIDs;        // videoIDs whose waiters need repainting
static NSUInteger gActiveFetches;
static BOOL gPumpScheduled;
static BOOL gFlushScheduled;

// Building an NSURLRequest and creating a session task takes locks and allocations.
// Doing that inside a layout pass is what made fresh content stutter, so the actual
// task construction happens here instead; only the small bookkeeping stays on main.
static dispatch_queue_t YMNetQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("ratiobar.net", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

static char kViewNodePtrKey;
static char kViewVideoIDKey;
static char kViewCounterKey;
static char kViewBarKey;

#pragma mark - Video ID

static NSString *YMVideoIDFromURL(NSString *s) {
    if (!s.length) return nil;
    NSRange vi = [s rangeOfString:@"/vi/"];
    if (vi.location == NSNotFound) return nil;
    NSUInteger start = vi.location + vi.length;
    if (start + 11 > s.length) return nil;
    NSString *candidate = [s substringWithRange:NSMakeRange(start, 11)];
    NSCharacterSet *illegal = [[NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"] invertedSet];
    if ([candidate rangeOfCharacterFromSet:illegal].location != NSNotFound) return nil;
    return candidate;
}

static id YMFindImageNode(id node, int depth) {
    if (!node || depth > 4) return nil;
    if ([NSStringFromClass([node class]) isEqualToString:@"ELMImageNode"]) return node;
    NSArray *children = nil;
    @try { children = [node yogaChildren]; } @catch (__unused NSException *e) { return nil; }
    for (id child in children) {
        id found = YMFindImageNode(child, depth + 1);
        if (found) return found;
    }
    return nil;
}

static NSString *YMDeriveVideoID(id node) {
    id imageNode = YMFindImageNode(node, 0);
    if (!imageNode) return nil;
    id url = nil;
    @try { url = [imageNode valueForKey:@"URL"]; } @catch (__unused NSException *e) { return nil; }
    if (!url) return nil;
    NSString *s = [url isKindOfClass:[NSURL class]] ? [(NSURL *)url absoluteString] : [url description];
    return YMVideoIDFromURL(s);
}

// The tree walk is the expensive part and layoutSubviews fires constantly while scrolling.
// Cache against the node's identity: a recycled view gets a different node, so the cache
// invalidates itself. Re-derive periodically in case a node is reused with a new URL.
// The node pointer is stored non-retained and only ever compared, never messaged.
static NSString *YMVideoIDForView(UIView *view, id node) {
    if (!node) return nil;

    NSValue *lastPtr = objc_getAssociatedObject(view, &kViewNodePtrKey);
    NSString *cached = objc_getAssociatedObject(view, &kViewVideoIDKey);
    NSTimeInterval lastDerive = [objc_getAssociatedObject(view, &kViewCounterKey) doubleValue];
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];

    // Revalidate on a clock, not a layout counter. During a fast scroll a view can get
    // many layout passes per second, and the old every-8th-pass rule turned that into a
    // burst of tree walks exactly when the frame budget is tightest.
    BOOL sameNode = lastPtr && [lastPtr pointerValue] == (__bridge void *)node;
    if (sameNode && cached && (now - lastDerive) < kRevalidateInterval) return cached;

    NSString *videoID = YMDeriveVideoID(node);
    objc_setAssociatedObject(view, &kViewNodePtrKey, [NSValue valueWithPointer:(__bridge void *)node],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, &kViewVideoIDKey, videoID, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(view, &kViewCounterKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return videoID;
}

#pragma mark - Vote data

static NSDictionary *YMCachedVotes(NSString *videoID) {
    NSDictionary *entry = gVotes[videoID];
    if (!entry) return nil;
    if ([NSDate timeIntervalSinceReferenceDate] - [entry[@"t"] doubleValue] > kCacheTTL) {
        [gVotes removeObjectForKey:videoID];
        return nil;
    }
    return entry;
}

// Bound the cache: without this it grows for the life of the process, since the TTL
// above only evicts entries that happen to be looked up again.
static void YMTrimCache(void) {
    if (gVotes.count <= kMaxCacheEntries) return;
    NSArray *byAge = [gVotes keysSortedByValueUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"t"] compare:b[@"t"]];
    }];
    NSUInteger drop = gVotes.count - (kMaxCacheEntries * 3 / 4);
    for (NSUInteger i = 0; i < drop && i < byAge.count; i++) [gVotes removeObjectForKey:byAge[i]];
}

static void YMPumpQueue(void);
static void YMApplyBar(UIView *thumbView, NSString *videoID);

// Views waiting on an in-flight fetch. Held weakly, so a dealloced cell drops out on its
// own; each survivor's cached ID is re-checked before painting, so a recycled view never
// gets the previous video's ratio.
static void YMAddWaiter(NSString *videoID, UIView *thumbView) {
    if (!gWaiters) gWaiters = [NSMutableDictionary new];
    NSHashTable *table = gWaiters[videoID];
    if (!table) {
        table = [NSHashTable weakObjectsHashTable];
        gWaiters[videoID] = table;
    }
    [table addObject:thumbView];
}

static void YMFlushWaiters(NSString *videoID) {
    NSHashTable *table = gWaiters[videoID];
    if (!table) return;
    [gWaiters removeObjectForKey:videoID];
    for (UIView *view in table.allObjects) {
        NSString *current = objc_getAssociatedObject(view, &kViewVideoIDKey);
        if ([current isEqualToString:videoID]) YMApplyBar(view, videoID);
    }
}

// RYD returns JSON null for videos it has no data on. NSNull is not nil, so a plain
// `?: @0` would let it through and doubleValue would throw.
static NSNumber *YMNumber(id value) {
    return [value isKindOfClass:[NSNumber class]] ? (NSNumber *)value : nil;
}

// Repaint every video that arrived in this runloop turn in a single batch, instead of
// mutating the view hierarchy once per response.
static void YMScheduleFlush(void) {
    if (gFlushScheduled) return;
    gFlushScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        gFlushScheduled = NO;
        NSArray *ids = [gDirtyIDs allObjects];
        [gDirtyIDs removeAllObjects];
        for (NSString *vid in ids) YMFlushWaiters(vid);
        YMPumpQueue();
    });
}

static void YMStartFetch(NSString *videoID) {
    gActiveFetches++;
    dispatch_async(YMNetQueue(), ^{
        NSString *urlStr = [NSString stringWithFormat:
            @"https://returnyoutubedislikeapi.com/Votes?videoId=%@", videoID];
        NSURL *url = [NSURL URLWithString:urlStr];
        if (!url) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (gActiveFetches > 0) gActiveFetches--;
                [gInFlight removeObject:videoID];
                [gWaiters removeObjectForKey:videoID];
                YMPumpQueue();
            });
            return;
        }
        NSURLRequest *req = [NSURLRequest requestWithURL:url
                                             cachePolicy:NSURLRequestUseProtocolCachePolicy
                                         timeoutInterval:10];

        [[[NSURLSession sharedSession] dataTaskWithRequest:req
            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSDictionary *parsed = nil;
            if (!error && [response isKindOfClass:[NSHTTPURLResponse class]] &&
                [(NSHTTPURLResponse *)response statusCode] == 200 && data.length) {
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if ([json isKindOfClass:[NSDictionary class]]) {
                    NSNumber *likes = YMNumber(json[@"likes"]);
                    NSNumber *dislikes = YMNumber(json[@"dislikes"]);
                    if (likes && dislikes) {
                        parsed = @{ @"l": likes, @"d": dislikes,
                                    @"t": @([NSDate timeIntervalSinceReferenceDate]) };
                    }
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (gActiveFetches > 0) gActiveFetches--;
                [gInFlight removeObject:videoID];
                if (parsed) {
                    if (!gVotes) gVotes = [NSMutableDictionary new];
                    gVotes[videoID] = parsed;
                    YMTrimCache();
                    if (!gDirtyIDs) gDirtyIDs = [NSMutableSet new];
                    [gDirtyIDs addObject:videoID];
                    YMScheduleFlush();
                } else {
                    [gWaiters removeObjectForKey:videoID];   // no data; stop holding the views
                    YMPumpQueue();
                }
            });
        }] resume];
    });
}

static void YMPumpQueue(void) {
    while (gActiveFetches < kMaxConcurrentFetches && gPending.count > 0) {
        NSString *next = gPending.firstObject;
        [gPending removeObjectAtIndex:0];
        if (YMCachedVotes(next)) {
            // Arrived via another request while queued — paint the waiters instead of refetching.
            [gInFlight removeObject:next];
            YMFlushWaiters(next);
            continue;
        }
        YMStartFetch(next);
    }
}

static void YMRequestVotes(NSString *videoID) {
    if (!videoID.length) return;
    if (!gInFlight) gInFlight = [NSMutableSet new];
    if (!gPending) gPending = [NSMutableArray new];
    if ([gInFlight containsObject:videoID]) return;   // de-dupe across shelves
    [gInFlight addObject:videoID];
    [gPending addObject:videoID];
    // Deferred, not immediate: this is called from inside a layout pass, and starting
    // network work there is what the stutter was.
    if (!gPumpScheduled) {
        gPumpScheduled = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            gPumpScheduled = NO;
            YMPumpQueue();
        });
    }
}

#pragma mark - Drawing

// objc_lookUpClass takes a runtime lock and hashes the string; resolving it once
// matters when this runs on every layout pass of every thumbnail.
static Class YMCellClass(void) {
    static Class cls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cls = objc_lookUpClass("_ASCollectionViewCell"); });
    return cls;
}

static UIView *YMAnchorForThumb(UIView *thumbView) {
    Class cellClass = YMCellClass();
    UIView *walk = thumbView.superview;
    for (int i = 0; i < 6 && walk; i++) {
        if (cellClass && [walk isKindOfClass:cellClass])
            return [(UICollectionViewCell *)walk contentView];
        walk = walk.superview;
    }
    return thumbView;
}

static void YMHideBar(UIView *thumbView) {
    UIView *bar = objc_getAssociatedObject(thumbView, &kViewBarKey);
    bar.hidden = YES;
}

static void YMApplyBar(UIView *thumbView, NSString *videoID) {
    UIView *bar = objc_getAssociatedObject(thumbView, &kViewBarKey);

    // Resolve data before touching the view hierarchy: a thumbnail with no data yet
    // should cost a dictionary lookup, not a layout.
    NSDictionary *votes = YMCachedVotes(videoID);
    if (!votes) {
        bar.hidden = YES;
        YMAddWaiter(videoID, thumbView);
        YMRequestVotes(videoID);
        return;
    }

    double likes = MAX(0.0, [votes[@"l"] doubleValue]);
    double dislikes = MAX(0.0, [votes[@"d"] doubleValue]);
    double total = likes + dislikes;
    double ratio = total > 0 ? likes / total : 1.0;
    ratio = MIN(1.0, MAX(0.0, ratio));

    UIView *anchor = YMAnchorForThumb(thumbView);
    CGRect inAnchor = (anchor == thumbView)
        ? thumbView.bounds
        : [thumbView convertRect:thumbView.bounds toView:anchor];
    CGRect barFrame = CGRectMake(inAnchor.origin.x, inAnchor.origin.y,
                                 inAnchor.size.width, kBarHeight);
    CGFloat w = barFrame.size.width, h = barFrame.size.height;
    CGFloat likeWidth = w * ratio;

    // Nothing changed since the last pass — the common case while scrolling a settled
    // feed. Bail before writing any frame, which would trigger layout and compositing.
    if (bar && !bar.hidden && bar.superview == anchor &&
        CGRectEqualToRect(bar.frame, barFrame) && bar.subviews.count == 2 &&
        fabs(((UIView *)bar.subviews[0]).frame.size.width - likeWidth) < 0.5) {
        return;
    }

    // The bar belongs to this thumbnail, not to the cell: a carousel cell holds several
    // thumbnails, and a tag lookup on the cell would make them share one bar.
    UIView *likeView, *dislikeView;
    if (!bar) {
        bar = [[UIView alloc] initWithFrame:barFrame];
        bar.userInteractionEnabled = NO;
        bar.clipsToBounds = YES;
        likeView = [[UIView alloc] init];
        likeView.backgroundColor = YM_LIKE_COLOR;
        dislikeView = [[UIView alloc] init];
        dislikeView.backgroundColor = YM_DISLIKE_COLOR;
        [bar addSubview:likeView];
        [bar addSubview:dislikeView];
        objc_setAssociatedObject(thumbView, &kViewBarKey, bar, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        if (bar.subviews.count < 2) return;
        likeView = bar.subviews[0];
        dislikeView = bar.subviews[1];
        if (!CGRectEqualToRect(bar.frame, barFrame)) bar.frame = barFrame;
    }

    if (bar.superview != anchor) [anchor addSubview:bar];
    // Reordering subviews is not free; only do it when the bar isn't already on top.
    if (anchor.subviews.lastObject != bar) [anchor bringSubviewToFront:bar];

    likeView.frame = CGRectMake(0, 0, likeWidth, h);
    dislikeView.frame = CGRectMake(likeWidth, 0, w - likeWidth, h);
    bar.hidden = NO;
}

#pragma mark - Hook

%hook _ASDisplayView

- (void)layoutSubviews {
    %orig;

    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    if (w < 120 || h < 60) return;
    CGFloat aspect = w / h;
    if (aspect < 1.6 || aspect > 2.0) return;

    NSString *videoID = YMVideoIDForView(self, self.keepalive_node);
    if (!videoID) {
        YMHideBar(self);   // recycled into non-video content; don't leave a stale bar
        return;
    }

    YMApplyBar(self, videoID);
}

%end
