//
//  TUCCursorUtilities.h
//  Touch Up Core
//
//  Created by Sebastian Hueber on 11.02.23.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(CGKeyCode, TUCArrowKey) {
    TUCArrowKeyLeft  = 123,
    TUCArrowKeyRight = 124,
    TUCArrowKeyDown  = 125,
    TUCArrowKeyUp    = 126,
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

- (void)magnifyLocationA:(CGPoint)p1 locationB:(CGPoint)p2 relativeP1:(CGPoint)r1 relP2:(CGPoint)r2;
- (void)stopMagnifying;

/// Posts Control + arrow, the default shortcuts for switching Spaces, Mission Control and App Exposé.
- (void)postControlArrowKey:(TUCArrowKey)key;


@end

NS_ASSUME_NONNULL_END
