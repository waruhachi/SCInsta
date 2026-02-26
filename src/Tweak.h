#import <Foundation/Foundation.h>

// * Tweak version *
extern NSString *SCIVersionString;

// Variables that work across features
extern BOOL dmVisualMsgsViewedButtonEnabled; // Whether story dm unlimited views button is enabled
extern NSMutableSet<NSString *> *dmReadWhitelistThreadIDs; // Thread IDs that auto-mark as read

BOOL SCIIsThreadWhitelisted(NSString *threadID);
BOOL SCIToggleThreadWhitelist(NSString *threadID);
void SCILoadThreadWhitelist(void);

// Biometric/passcode authentication
extern BOOL isAuthenticationBeingShown;