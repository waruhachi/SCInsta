#import "../../InstagramHeaders.h"
#import "../../Tweak.h"
#import "../../Utils.h"

static CFTimeInterval sciSeenOnSendLastScheduleAt = 0;

static BOOL SCIObjectCanMarkSeen(id obj) {
    return obj && [obj respondsToSelector:@selector(markLastMessageAsSeen)];
}

static id SCIValueForKeySafely(id obj, NSString *key) {
    if (!obj || !key.length) return nil;

    @try {
        return [obj valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static id SCIResolveThreadController(id source) {
    if (SCIObjectCanMarkSeen(source)) {
        return source;
    }

    id threadVC = nil;

    if ([source isKindOfClass:[UIView class]]) {
        threadVC = [SCIUtils nearestViewControllerForView:(UIView *)source];

        if (!SCIObjectCanMarkSeen(threadVC)) {
            UIResponder *responder = (UIResponder *)source;
            while (responder) {
                responder = [responder nextResponder];
                if (SCIObjectCanMarkSeen(responder)) {
                    threadVC = responder;
                    break;
                }
            }
        }
    }

    if (!threadVC && [source respondsToSelector:@selector(view)]) {
        @try {
            id sourceView = [source valueForKey:@"view"];
            if ([sourceView isKindOfClass:[UIView class]]) {
                threadVC = [SCIUtils nearestViewControllerForView:(UIView *)sourceView];
            }
        } @catch (__unused NSException *exception) {}
    }

    if (!SCIObjectCanMarkSeen(threadVC)) {
        UIViewController *topVC = topMostController();
        if (SCIObjectCanMarkSeen(topVC)) {
            threadVC = topVC;
        }
    }

    return threadVC;
}

static id SCIFindMarkSeenCapableControllerInTree(UIViewController *root) {
    if (!root) return nil;
    if (SCIObjectCanMarkSeen(root)) return root;

    if ([root isKindOfClass:[UINavigationController class]]) {
        UINavigationController *nav = (UINavigationController *)root;
        id found = SCIFindMarkSeenCapableControllerInTree(nav.visibleViewController ?: nav.topViewController);
        if (found) return found;
    }

    if ([root isKindOfClass:[UITabBarController class]]) {
        UITabBarController *tab = (UITabBarController *)root;
        id found = SCIFindMarkSeenCapableControllerInTree(tab.selectedViewController);
        if (found) return found;
    }

    for (UIViewController *child in root.childViewControllers) {
        id found = SCIFindMarkSeenCapableControllerInTree(child);
        if (found) return found;
    }

    if (root.presentedViewController) {
        id found = SCIFindMarkSeenCapableControllerInTree(root.presentedViewController);
        if (found) return found;
    }

    return nil;
}

static id SCIResolveThreadControllerFromCandidates(id first, id second) {
    id threadVC = SCIResolveThreadController(first);
    if (SCIObjectCanMarkSeen(threadVC)) return threadVC;

    threadVC = SCIResolveThreadController(second);
    if (SCIObjectCanMarkSeen(threadVC)) return threadVC;

    NSArray<NSString *> *relayKeys = @[
        @"viewController", @"delegate", @"presentingViewController", @"parentViewController", @"navigationController"
    ];

    for (NSString *key in relayKeys) {
        id relayed = SCIValueForKeySafely(first, key);
        threadVC = SCIResolveThreadController(relayed);
        if (SCIObjectCanMarkSeen(threadVC)) return threadVC;

        relayed = SCIValueForKeySafely(second, key);
        threadVC = SCIResolveThreadController(relayed);
        if (SCIObjectCanMarkSeen(threadVC)) return threadVC;
    }

    threadVC = SCIResolveThreadController(topMostController());
    if (SCIObjectCanMarkSeen(threadVC)) return threadVC;

    UIViewController *rootVC = [UIApplication sharedApplication].keyWindow.rootViewController;
    threadVC = SCIFindMarkSeenCapableControllerInTree(rootVC);
    if (SCIObjectCanMarkSeen(threadVC)) return threadVC;

    return nil;
}

static void SCIAttemptMarkSeen(id source, NSString *reason, NSInteger attempt) {
    id threadVC = SCIResolveThreadController(source);
    if (SCIObjectCanMarkSeen(threadVC)) {
        SCIMarkThreadAsSeenIfNeeded(threadVC);
    }
}

static void SCIScheduleMarkSeen(id source, NSString *reason) {
    if (!SCIShouldMarkSeenOnSend()) return;

    CFTimeInterval now = CACurrentMediaTime();
    if ((now - sciSeenOnSendLastScheduleAt) < 0.12) return;
    sciSeenOnSendLastScheduleAt = now;

    SCIAttemptMarkSeen(source, reason, 1);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.30 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SCIAttemptMarkSeen(source, reason, 2);
    });
}

static BOOL SCIStringContainsCaseInsensitive(NSString *value, NSString *needle) {
    if (!value.length || !needle.length) return NO;

    return [value rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static BOOL SCIIsLikelyDMSendAction(SEL action, id target, id sender) {
    NSString *selectorName = NSStringFromSelector(action) ?: @"";
    NSString *targetClassName = target ? NSStringFromClass([target class]) : @"";
    NSString *senderClassName = sender ? NSStringFromClass([sender class]) : @"";

    BOOL selectorLooksLikeSend = SCIStringContainsCaseInsensitive(selectorName, @"send");
    BOOL selectorLooksLikePost = SCIStringContainsCaseInsensitive(selectorName, @"post") && SCIStringContainsCaseInsensitive(selectorName, @"button");
    if (!selectorLooksLikeSend && !selectorLooksLikePost) return NO;

    BOOL classLooksDirect =
        SCIStringContainsCaseInsensitive(targetClassName, @"Direct")
        || SCIStringContainsCaseInsensitive(senderClassName, @"Direct")
        || SCIStringContainsCaseInsensitive(targetClassName, @"Composer")
        || SCIStringContainsCaseInsensitive(senderClassName, @"Composer");

    return classLooksDirect;
}

%hook IGDirectComposer
- (void)didTapSend {
    %orig;

    SCIScheduleMarkSeen(self, @"IGDirectComposer.didTapSend");
}

- (void)_didTapSend:(id)arg1 {
    %orig;

    SCIScheduleMarkSeen(self, @"IGDirectComposer._didTapSend:");
    SCIScheduleMarkSeen(arg1, @"IGDirectComposer._didTapSend:(arg1)");
}

- (void)_didTapSendButton:(id)arg1 {
    %orig;

    SCIScheduleMarkSeen(self, @"IGDirectComposer._didTapSendButton:");
}

- (void)_didPressSendButton:(id)arg1 {
    %orig;

    SCIScheduleMarkSeen(self, @"IGDirectComposer._didPressSendButton:");
}

- (void)onSendButtonTap {
    %orig;

    SCIScheduleMarkSeen(self, @"IGDirectComposer.onSendButtonTap");
}

- (void)sendButtonTapped:(id)arg1 {
    %orig;

    SCIScheduleMarkSeen(self, @"IGDirectComposer.sendButtonTapped:");
}
%end

%hook IGDirectThreadViewController
- (void)didTapSend {
    %orig;

    SCIScheduleMarkSeen(self, @"IGDirectThreadViewController.didTapSend");
}

- (void)_didTapSend:(id)arg1 {
    %orig;

    SCIScheduleMarkSeen(self, @"IGDirectThreadViewController._didTapSend:");
    SCIScheduleMarkSeen(arg1, @"IGDirectThreadViewController._didTapSend:(arg1)");
}

- (void)_didTapSendButton:(id)arg1 {
    %orig;

    SCIScheduleMarkSeen(self, @"IGDirectThreadViewController._didTapSendButton:");
}

- (void)_didPressSendButton:(id)arg1 {
    %orig;

    SCIScheduleMarkSeen(self, @"IGDirectThreadViewController._didPressSendButton:");
}

- (void)onSendButtonTap {
    %orig;

    SCIScheduleMarkSeen(self, @"IGDirectThreadViewController.onSendButtonTap");
}

- (void)sendButtonTapped:(id)arg1 {
    %orig;

    SCIScheduleMarkSeen(self, @"IGDirectThreadViewController.sendButtonTapped:");
}
%end

%hook UIApplication
- (BOOL)sendAction:(SEL)action to:(id)target from:(id)sender forEvent:(UIEvent *)event {
    BOOL didSend = %orig(action, target, sender, event);

    BOOL enabled = SCIShouldMarkSeenOnSend();
    BOOL likelyDMSend = SCIIsLikelyDMSendAction(action, target, sender);

    if (!enabled) return didSend;
    if (!likelyDMSend) return didSend;

    UIViewController *threadVC = SCIResolveThreadControllerFromCandidates(target, sender);
    if (!SCIObjectCanMarkSeen(threadVC)) return didSend;

    SCIScheduleMarkSeen(threadVC, @"UIApplication.sendAction");
    return didSend;
}
%end

%hook UIControl
- (void)sendAction:(SEL)action to:(id)target forEvent:(UIEvent *)event {
    %orig(action, target, event);

    BOOL enabled = SCIShouldMarkSeenOnSend();
    BOOL likelyDMSend = SCIIsLikelyDMSendAction(action, target, self);

    if (!enabled) return;
    if (!likelyDMSend) return;

    // Try multiple candidates because in current IG builds the active controller can be indirect.
    SCIScheduleMarkSeen(target, @"UIControl.sendAction(target)");
    SCIScheduleMarkSeen(self, @"UIControl.sendAction(sender)");
    SCIScheduleMarkSeen(topMostController(), @"UIControl.sendAction(topMost)");
}
%end
