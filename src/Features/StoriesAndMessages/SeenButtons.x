#import "../../InstagramHeaders.h"
#import "../../Tweak.h"
#import "../../Utils.h"
#import <objc/runtime.h>

static const void *kSCISeenButtonThreadIDKey = &kSCISeenButtonThreadIDKey;
static const void *kSCISeenButtonBarItemKey = &kSCISeenButtonBarItemKey;

static NSString *SCIStringValueForObject(id obj) {
    if (!obj || obj == [NSNull null]) return nil;

    if ([obj isKindOfClass:[NSString class]]) {
        NSString *value = (NSString *)obj;
        return value.length ? value : nil;
    }

    if ([obj respondsToSelector:@selector(stringValue)]) {
        NSString *value = [obj stringValue];
        return value.length ? value : nil;
    }

    return nil;
}

static id SCIValueForKeySafely(id obj, NSString *key) {
    if (!obj || !key.length) return nil;

    @try {
        return [obj valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSString *SCIExtractThreadIDFromContext(id context) {
    if (!context) return nil;

    NSArray<NSString *> *directKeys = @[
        @"threadId", @"threadID", @"threadIdentifier", @"threadPk", @"threadPK",
        @"directThreadID", @"directThreadId", @"conversationID", @"conversationId",
        @"recipientID", @"recipientId", @"uniqueIdentifier", @"pk", @"id"
    ];

    for (NSString *key in directKeys) {
        NSString *value = SCIStringValueForObject(SCIValueForKeySafely(context, key));
        if (value.length) return value;
    }

    NSArray<NSString *> *nestedKeys = @[@"thread", @"threadModel", @"conversation", @"recipient", @"directThread", @"viewModel"];
    for (NSString *nestedKey in nestedKeys) {
        id nestedObj = SCIValueForKeySafely(context, nestedKey);
        if (!nestedObj || nestedObj == context) continue;

        for (NSString *key in directKeys) {
            NSString *value = SCIStringValueForObject(SCIValueForKeySafely(nestedObj, key));
            if (value.length) return value;
        }
    }

    return nil;
}

static NSString *SCICurrentThreadIDFromNavBarView(IGTallNavigationBarView *view) {
    NSString *threadID = SCIExtractThreadIDFromContext(view);
    if (threadID.length) return threadID;

    UIViewController *controller = [SCIUtils nearestViewControllerForView:view];
    threadID = SCIExtractThreadIDFromContext(controller);
    if (threadID.length) return threadID;

    return SCIExtractThreadIDFromContext(topMostController());
}

static void SCIApplySeenButtonAppearance(UIBarButtonItem *button, NSString *threadID) {
    if (!button) return;

    BOOL isWhitelisted = SCIIsThreadWhitelisted(threadID);
    UIImage *icon = [UIImage systemImageNamed:(isWhitelisted ? @"checkmark.message.fill" : @"checkmark.message")];
    if (icon) {
        [button setImage:icon];
    }

    if (isWhitelisted) {
        [button setTintColor:[UIColor systemGreenColor]];
    } else {
        [button setTintColor:UIColor.labelColor];
    }

    objc_setAssociatedObject(button, kSCISeenButtonThreadIDKey, threadID ?: @"", OBJC_ASSOCIATION_COPY_NONATOMIC);
}

// Seen buttons (in DMs)
// - Enables no seen for messages
// - Enables unlimited views of DM visual messages
%hook IGTallNavigationBarView
- (void)setRightBarButtonItems:(NSArray <UIBarButtonItem *> *)items {
    NSMutableArray *new_items = [[items filteredArrayUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(UIView *value, NSDictionary *_) {
            if ([SCIUtils getBoolPref:@"hide_reels_blend"]) {
                return ![value.accessibilityIdentifier isEqualToString:@"blend-button"];
            }

            return true;
        }]
    ] mutableCopy];

    // Messages seen
    if ([SCIUtils getBoolPref:@"remove_lastseen"]) {
        UIBarButtonItem *seenButton = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"checkmark.message"] style:UIBarButtonItemStylePlain target:self action:@selector(seenButtonHandler:)];
        NSString *threadID = SCICurrentThreadIDFromNavBarView(self);
        SCIApplySeenButtonAppearance(seenButton, threadID);
        [new_items addObject:seenButton];

        dispatch_async(dispatch_get_main_queue(), ^{
            UIView *buttonView = [seenButton valueForKey:@"view"];
            if (!buttonView) return;

            objc_setAssociatedObject(buttonView, kSCISeenButtonThreadIDKey, threadID ?: @"", OBJC_ASSOCIATION_COPY_NONATOMIC);
            objc_setAssociatedObject(buttonView, kSCISeenButtonBarItemKey, seenButton, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

            if (![SCIUtils existingLongPressGestureRecognizerForView:buttonView]) {
                UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(seenButtonLongPressHandler:)];
                longPress.minimumPressDuration = 0.5;
                [buttonView addGestureRecognizer:longPress];
            }
        });
    }

    // DM visual messages viewed
    if ([SCIUtils getBoolPref:@"unlimited_replay"]) {
        UIBarButtonItem *dmVisualMsgsViewedButton = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"photo.badge.checkmark"] style:UIBarButtonItemStylePlain target:self action:@selector(dmVisualMsgsViewedButtonHandler:)];
        [new_items addObject:dmVisualMsgsViewedButton];

        if (dmVisualMsgsViewedButtonEnabled) {
            [dmVisualMsgsViewedButton setTintColor:SCIUtils.SCIColor_Primary];
        } else {
            [dmVisualMsgsViewedButton setTintColor:UIColor.labelColor];
        }
    }

    %orig([new_items copy]);
}

// Messages seen button
%new - (void)seenButtonHandler:(UIBarButtonItem *)sender {
    NSString *threadID = objc_getAssociatedObject(sender, kSCISeenButtonThreadIDKey);
    if (!threadID.length) {
        threadID = SCICurrentThreadIDFromNavBarView(self);
    }

    SCIApplySeenButtonAppearance(sender, threadID);

    UIViewController *nearestVC = [SCIUtils nearestViewControllerForView:self];
    if ([nearestVC isKindOfClass:%c(IGDirectThreadViewController)]) {
        [(IGDirectThreadViewController *)nearestVC markLastMessageAsSeen];

        [SCIUtils showToastForDuration:2.5 title:@"Marked messages as seen"];
    }
}
%new - (void)seenButtonLongPressHandler:(UILongPressGestureRecognizer *)sender {
    if (sender.state != UIGestureRecognizerStateBegan) return;

    UIView *buttonView = sender.view;
    NSString *threadID = objc_getAssociatedObject(buttonView, kSCISeenButtonThreadIDKey);
    UIBarButtonItem *barItem = objc_getAssociatedObject(buttonView, kSCISeenButtonBarItemKey);

    if (!threadID.length) {
        threadID = SCICurrentThreadIDFromNavBarView(self);
    }

    if (!threadID.length) {
        [SCIUtils showToastForDuration:2.5 title:@"Could not resolve thread" subtitle:@"Try reopening this conversation"];
        return;
    }

    BOOL nowWhitelisted = SCIToggleThreadWhitelist(threadID);
    SCIApplySeenButtonAppearance(barItem, threadID);

    if (nowWhitelisted) {
        [SCIUtils showToastForDuration:2.5 title:@"Added to whitelist" subtitle:@"Messages in this thread will auto-mark as read"];
    } else {
        [SCIUtils showToastForDuration:2.5 title:@"Removed from whitelist" subtitle:@"Messages in this thread now require manual marking"];
    }
}
%new - (void)seenButtonLongPressHandler:(UILongPressGestureRecognizer *)sender {
    if (sender.state != UIGestureRecognizerStateBegan) return;

    UIView *buttonView = sender.view;
    NSString *threadID = objc_getAssociatedObject(buttonView, kSCISeenButtonThreadIDKey);
    UIBarButtonItem *barItem = objc_getAssociatedObject(buttonView, kSCISeenButtonBarItemKey);

    if (!threadID.length) {
        threadID = SCICurrentThreadIDFromNavBarView(self);
    }

    if (!threadID.length) {
        [SCIUtils showToastForDuration:2.5 title:@"Could not resolve thread" subtitle:@"Try reopening this conversation"];
        return;
    }

    BOOL nowWhitelisted = SCIToggleThreadWhitelist(threadID);
    SCIApplySeenButtonAppearance(barItem, threadID);

    if (nowWhitelisted) {
        [SCIUtils showToastForDuration:2.5 title:@"Added to whitelist" subtitle:@"Messages in this thread will auto-mark as read"];
    } else {
        [SCIUtils showToastForDuration:2.5 title:@"Removed from whitelist" subtitle:@"Messages in this thread now require manual marking"];
    }
}
// DM visual messages viewed button
%new - (void)dmVisualMsgsViewedButtonHandler:(UIBarButtonItem *)sender {
    if (dmVisualMsgsViewedButtonEnabled) {
        dmVisualMsgsViewedButtonEnabled = false;
        [sender setTintColor:UIColor.labelColor];

        [SCIUtils showToastForDuration:4.5 title:@"Visual messages can be replayed without expiring"];
    }
    else {
        dmVisualMsgsViewedButtonEnabled = true;
        [sender setTintColor:SCIUtils.SCIColor_Primary];

        [SCIUtils showToastForDuration:4.5 title:@"Visual messages will now expire after viewing"];
    }
}
%end

// Messages seen logic
%hook IGDirectThreadViewListAdapterDataSource
- (BOOL)shouldUpdateLastSeenMessage {
    if ([SCIUtils getBoolPref:@"remove_lastseen"]) {
        NSString *threadID = SCIExtractThreadIDFromContext(self);
        if (SCIIsThreadWhitelisted(threadID)) {
            return %orig;
        }

        return false;
    }
    
    return %orig;
}
%end

// DM stories viewed logic
%hook IGDirectVisualMessageViewerEventHandler
- (void)visualMessageViewerController:(id)arg1 didBeginPlaybackForVisualMessage:(id)arg2 atIndex:(NSInteger)arg3 {
    if ([SCIUtils getBoolPref:@"unlimited_replay"]) {
        // Check if dm stories should be marked as viewed
        if (dmVisualMsgsViewedButtonEnabled) {
            %orig;
        }
    }
}
- (void)visualMessageViewerController:(id)arg1 didEndPlaybackForVisualMessage:(id)arg2 atIndex:(NSInteger)arg3 mediaCurrentTime:(CGFloat)arg4 forNavType:(NSInteger)arg5 {
    if ([SCIUtils getBoolPref:@"unlimited_replay"]) {
        // Check if dm stories should be marked as viewed
        if (dmVisualMsgsViewedButtonEnabled) {
            %orig;
        }
    }
}
%end