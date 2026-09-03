#import "Headers.h"

@class YMSettingsItem;
extern YMSettingsItem *YMAction(NSString *title, NSString *subtitle, void (^action)(UIViewController *vc));
extern YMSettingsItem *YMHeader(NSString *title);
extern void YMPushSubSettings(NSString *title, NSArray<YMSettingsItem *> *items, id settingsVC, id parentResponder);

#pragma mark - List storage

static NSArray<NSString *> *blockedChannels(void) {
    NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:BlockedChannels];
    NSMutableArray<NSString *> *list = [NSMutableArray array];
    for (id entry in saved) {
        if ([entry isKindOfClass:[NSString class]] && [entry length]) [list addObject:entry];
    }
    return list;
}

static void saveBlockedChannels(NSArray<NSString *> *list) {
    [[NSUserDefaults standardUserDefaults] setObject:list forKey:BlockedChannels];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

#pragma mark - Matching

// -description on a renderer is protobuf text format. String fields come through as
// UTF-8, but the element payload is a bytes field, and those print every byte outside
// printable ASCII as a three-digit octal escape — so a non-ASCII name has to be looked
// for in that spelling too.
static NSString *octalEscaped(NSString *text) {
    NSData *bytes = [text dataUsingEncoding:NSUTF8StringEncoding];
    const unsigned char *p = bytes.bytes;
    NSMutableString *out = [NSMutableString stringWithCapacity:bytes.length * 4];
    for (NSUInteger i = 0; i < bytes.length; i++) {
        unsigned char c = p[i];
        if (c == '"' || c == '\'' || c == '\\') {
            [out appendFormat:@"\\%c", c];
        } else if (c < 0x20 || c >= 0x7f) {
            [out appendFormat:@"\\%03o", c];
        } else {
            [out appendFormat:@"%c", c];
        }
    }
    return out;
}

static NSArray<NSString *> *blockedNeedles(void) {
    NSMutableArray<NSString *> *needles = [NSMutableArray array];
    for (NSString *entry in blockedChannels()) {
        NSString *trimmed = [entry stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!trimmed.length) continue;
        [needles addObject:trimmed];
        NSString *escaped = octalEscaped(trimmed);
        if (![escaped isEqualToString:trimmed]) [needles addObject:escaped];
    }
    return needles;
}

static BOOL mentionsBlockedChannel(id renderer, NSArray<NSString *> *needles) {
    NSString *description = [renderer description];
    for (NSString *needle in needles) {
        if ([description rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    }
    return NO;
}

// Drops matching results out of each section in place. The section objects are the
// ones the controller keeps, so the caller has nothing to write back.
static void stripBlockedChannels(NSArray *sections) {
    NSArray<NSString *> *needles = blockedNeedles();
    if (!needles.count) return;
    for (id section in sections) {
        if (![section isKindOfClass:%c(YTIItemSectionRenderer)]) continue;
        NSMutableArray *contents = ((YTIItemSectionRenderer *)section).contentsArray;
        NSIndexSet *remove = [contents indexesOfObjectsPassingTest:^BOOL(id item, NSUInteger idx, BOOL *stop) {
            return mentionsBlockedChannel(item, needles);
        }];
        if (remove.count) [contents removeObjectsAtIndexes:remove];
    }
}

// Search results only. The same collection controller backs every feed, so the
// page is told apart by the search controllers it sits under, by name rather than
// class so a missing header cannot take the whole hook down.
static BOOL isSearchResults(UIViewController *controller) {
    for (UIViewController *current = controller; current; current = current.parentViewController) {
        NSString *name = NSStringFromClass(current.class);
        if ([name isEqualToString:@"YTSearchViewController"] || [name containsString:@"SearchResults"]) return YES;
    }
    return NO;
}

%hook YTInnerTubeCollectionViewController
- (void)displaySectionsWithReloadingSectionControllerByRenderer:(id)renderer {
    if (IS_ENABLED(BlockChannelsInSearch) && isSearchResults(self)) {
        stripBlockedChannels([self valueForKey:@"_sectionRenderers"]);
    }
    %orig;
}
- (void)addSectionsFromArray:(NSArray *)array {
    if (IS_ENABLED(BlockChannelsInSearch) && isSearchResults(self)) {
        stripBlockedChannels(array);
    }
    %orig;
}
%end

#pragma mark - Settings screen

static NSArray<YMSettingsItem *> *blockedChannelItems(void);

static void reloadBlockedChannels(UIViewController *vc) {
    [vc setValue:blockedChannelItems() forKey:@"items"];
    SEL update = NSSelectorFromString(@"updateDisplayedItemsAnimated:");
    if ([vc respondsToSelector:update]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(vc, update, NO);
    }
}

static void promptForChannel(UIViewController *vc) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:LOC(@"BLOCKED_CHANNELS_ADD")
                                                                   message:LOC(@"BLOCKED_CHANNELS_ADD_DESC")
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = LOC(@"BLOCKED_CHANNELS_PLACEHOLDER");
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.returnKeyType = UIReturnKeyDone;
    }];
    __weak UIViewController *weakVC = vc;
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:LOC(@"CANCEL") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:LOC(@"ADD") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *text = [weakAlert.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!text.length) return;
        NSMutableArray<NSString *> *list = [blockedChannels() mutableCopy];
        for (NSString *existing in list) {
            if ([existing caseInsensitiveCompare:text] == NSOrderedSame) return;
        }
        [list addObject:text];
        saveBlockedChannels(list);
        if (weakVC) reloadBlockedChannels(weakVC);
    }]];
    [vc presentViewController:alert animated:YES completion:nil];
}

static void confirmRemoval(UIViewController *vc, NSString *channel) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:channel
                                                                   message:LOC(@"BLOCKED_CHANNELS_REMOVE_DESC")
                                                            preferredStyle:UIAlertControllerStyleAlert];
    __weak UIViewController *weakVC = vc;
    [alert addAction:[UIAlertAction actionWithTitle:LOC(@"CANCEL") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:LOC(@"REMOVE") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        NSMutableArray<NSString *> *list = [blockedChannels() mutableCopy];
        [list removeObject:channel];
        saveBlockedChannels(list);
        if (weakVC) reloadBlockedChannels(weakVC);
    }]];
    [vc presentViewController:alert animated:YES completion:nil];
}

static NSArray<YMSettingsItem *> *blockedChannelItems(void) {
    NSMutableArray<YMSettingsItem *> *items = [NSMutableArray array];
    [items addObject:YMAction(LOC(@"BLOCKED_CHANNELS_ADD"), LOC(@"BLOCKED_CHANNELS_ADD_DESC"), ^(UIViewController *vc) {
        promptForChannel(vc);
    })];
    NSArray<NSString *> *list = blockedChannels();
    [items addObject:YMHeader(list.count ? LOC(@"BLOCKED_CHANNELS") : LOC(@"BLOCKED_CHANNELS_EMPTY"))];
    for (NSString *channel in list) {
        [items addObject:YMAction(channel, LOC(@"BLOCKED_CHANNELS_TAP_TO_REMOVE"), ^(UIViewController *vc) {
            confirmRemoval(vc, channel);
        })];
    }
    return items;
}

void YMPushBlockedChannels(id settingsVC, id parentResponder) {
    YMPushSubSettings(LOC(@"BLOCKED_CHANNELS"), blockedChannelItems(), settingsVC, parentResponder);
}
