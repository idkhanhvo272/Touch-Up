//
//  TUCCursorUtilities.h
//  Touch Up Core
//
//  Created by Sebastian Hueber on 11.02.23.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// Launch with TOUCHUP_DEBUG_GESTURES=1 in the environment to log gesture recognition and synthesized events to stderr.
extern BOOL TUCDebugGestures;
#define TUCDebugLog(...) do { if (TUCDebugGestures) { fprintf(stderr, "%.3f ", CFAbsoluteTimeGetCurrent()); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } } while (0)

typedef NS_ENUM(NSInteger, TUCDockSwipeMotion) {
    TUCDockSwipeMotionHorizontal = 1, // switch Spaces
    TUCDockSwipeMotionVertical   = 2, // Mission Control, App Exposé
    TUCDockSwipeMotionPinch      = 3, // Launchpad, Show Desktop
};

/// IDs of the system's symbolic hot keys (System Settings › Keyboard › Keyboard Shortcuts).
typedef NS_ENUM(int, TUCSymbolicHotKey) {
    kTUCSymbolicHotKeyLookUp             = 70,
    kTUCSymbolicHotKeyNotificationCenter = 163,
};

@interface TUCCursorUtilities : NSObject

+ (instancetype)sharedInstance;


@property CGFloat doubleClickTolerance;

- (CGPoint)currentCursorLocation;

- (void)bringWindowToFrontAt:(CGPoint)aLocation;

- (void)moveCursorTo:(CGPoint)aLocation;

- (void)performClickAt:(CGPoint)aLocation;

- (void)performSecondaryClickAt:(CGPoint)aLocation;

- (void)dragCursorTo:(CGPoint)aLocation phase:(NSTouchPhase)phase;
- (void)stopDraggingCursor;

- (void)scroll:(CGPoint)translation phase:(NSTouchPhase)phase;

/// Trackpad-style scrolling: phased events let apps rubber-band, coast and swipe between pages.
- (void)scrollBy:(CGPoint)delta;
- (void)endScroll;
- (void)cancelMomentumScroll;

/// `magnification` is the relative change of the finger distance, `degrees` is counterclockwise.
- (void)magnifyBy:(CGFloat)magnification;
- (void)rotateBy:(CGFloat)degrees;
- (void)stopMagnifying;
- (void)smartMagnify;

/// `delta` is in the Dock's progress units; the sign follows natural (content follows fingers) direction.
- (void)dockSwipe:(TUCDockSwipeMotion)motion by:(double)delta;
- (void)endDockSwipe;
- (BOOL)isDockSwiping;

- (void)postKey:(CGKeyCode)key flags:(CGEventFlags)flags;

/// Triggers a system shortcut, binding an unreachable key to it first if the user left it without one.
- (void)triggerSymbolicHotKey:(TUCSymbolicHotKey)hotKey;


@end

NS_ASSUME_NONNULL_END
