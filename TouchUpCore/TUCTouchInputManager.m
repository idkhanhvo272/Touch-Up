//
//  TUCTouchInputManager.m
//  Touch Up Core
//
//  Created by Sebastian Hueber on 03.02.23.
//

#import "TUCTouchInputManager.h"

#import "HIDInterpreter.h"
#import "TUCCursorUtilities.h"

typedef NS_ENUM(NSInteger, TUCMultiFingerMode) {
    TUCMultiFingerModeUndecided,
    TUCMultiFingerModeScroll,
    TUCMultiFingerModeTransform,   // pinch and rotate
    TUCMultiFingerModeDockSwipe,
    TUCMultiFingerModeDone,        // the gesture ended or fired: ignore the fingers until all of them lifted
};

@interface TUCTouchInputManager ()

@property NSMutableDictionary<NSNumber *, NSNumber *> *frameIDsByLocationID;

@property (weak, nullable) TUCTouch *cursorTouch;

@property BOOL cursorTouchQualifiedForTap; // if the cursor entered moving state once it can no longer be interpreted as tap
@property BOOL cursorTouchDidHold; //
@property (strong) NSDate *cursorTouchStationarySinceDate;

// An interaction lasts from the first finger landing until every finger has lifted.
@property (strong) NSDate *interactionStartDate;
@property NSUInteger interactionMaxTouches;
@property BOOL interactionMoved;
@property (strong) NSMutableDictionary<NSUUID *, NSValue *> *interactionStartLocations;

@property TUCMultiFingerMode multiFingerMode;
@property BOOL multiFingerStarted;
@property NSUInteger anchorTouchCount;
@property CGPoint anchorCentroid;
@property CGFloat anchorSpread;
@property CGFloat anchorAngle;
@property BOOL anchorAtRightEdge;
@property CGPoint previousCentroid;
@property CGFloat previousSpread;
@property CGFloat previousAngle;
@property (strong) NSMutableDictionary<NSUUID *, NSValue *> *previousTouchLocations;
@property CGFloat recentScrollStep;                            // typical finger movement per report during this scroll
@property CGPoint heldScrollJump;
@property BOOL holdingScrollJump;
@property CGFloat accumulatedRotation;
@property BOOL rotationLocked;
@property TUCDockSwipeMotion dockSwipeMotion;

@property (strong, nullable) NSTimer *pendingSecondaryClickTimer;
@property CGPoint pendingTwoFingerTapLocation;
@property BOOL awaitingSecondTwoFingerTap;

@end


// Distances are fractions of the touch screen width rather than millimetres: panels often
// report a bogus physical size in their EDID, which skews pixelsPerMM.
static const CGFloat kTapSlop = 0.02;
static const CGFloat kTwoFingerGestureThreshold = 0.015;
static const CGFloat kMultiFingerSwipeThreshold = 0.03;
static const CGFloat kFourFingerPinchThreshold = 0.03;
static const CGFloat kRightEdgeZone = 0.03;
static const CGFloat kEdgeSwipeThreshold = 0.05;

static const CGFloat kRotationLockDegrees = 12;

static const CGFloat kScrollJumpFactor = 2.5;
static const CGFloat kScrollJumpMinimum = 0.02;

// Dock swipe progress per point of finger travel. A full screen width moves one Space, with the
// gap the switching animation draws between Spaces; the Dock expects about 1.5 per Space.
static const CGFloat kDockSwipeProgressPerSpace = 1.5;
static const CGFloat kSpaceSeparatorWidth = 63;
static const CGFloat kDockPinchTravel = 0.25;   // spread change, as a fraction of the screen width, for a full pinch

static const NSTimeInterval kMultiFingerTapMaxDuration = 0.35;
static const NSTimeInterval kTwoFingerDoubleTapInterval = 0.3;

@implementation TUCTouchInputManager

#pragma mark   Start & Stop

- (void)start {
    
    __weak id weakSelf = self;
    
    // needs to run on main anyway
//    [NSThread detachNewThreadWithBlock:^{
//        [NSThread setThreadPriority:1];
    OpenHIDManager((__bridge void *)(weakSelf));
//    }];

    // without these, the system silently drops every event we post
    TUCDebugLog("permissions: postEvent=%d accessibility=%d", CGPreflightPostEventAccess(), AXIsProcessTrusted());
}

- (void)stop {
    CloseHIDManager();
}

- (void)setTouchscreensSeized:(BOOL)seized {
    SetTouchDevicesSeized(seized);
}


- (void)didConnectTouchscreenWithLocationID:(uint32_t)locationID {
    self.frameIDsByLocationID[@(locationID)] = @0;
    [self.delegate touchscreenDidConnectWithLocationID:locationID];
}

- (void)didDisconnectTouchscreenWithLocationID:(uint32_t)locationID {
    [self.frameIDsByLocationID removeObjectForKey:@(locationID)];
    [self.delegate touchscreenDidDisconnectWithLocationID:locationID];
}



#pragma mark - Reacting to HID Events

- (NSInteger)currentFrameIDForLocationID:(uint32_t)locationID {
    return self.frameIDsByLocationID[@(locationID)].integerValue;
}

- (void)didProcessReportForLocationID:(uint32_t)locationID {
    // go through all touches: if the frame is not the latest one, the touch might be old and should be removed.
    NSInteger currentFrameID = [self currentFrameIDForLocationID:locationID];

    for (TUCTouch *touch in self.touchSet) {
        if (touch.locationID != locationID) continue;

        if (touch.lastUpdated + self.errorResistance < currentFrameID) {
            [touch setPhase:NSTouchPhaseCancelled];
            [self removeTouch:touch now:NO];
        }
    }

    if ([[self activeTouches] count] == 0) {
        [self stopCurrentGesture];
    }

    self.frameIDsByLocationID[@(locationID)] = @(currentFrameID + 1);

    [self processTouchesForCursorInput];

}


- (void)stopCurrentGesture {
    [[TUCCursorUtilities sharedInstance] stopDraggingCursor];
    [[TUCCursorUtilities sharedInstance] stopMagnifying];
}



/**
 Most important event handling callback: it posts the events to the system where the touches need to go
 */
- (void)updateTouch:(NSInteger)contactID locationID:(uint32_t)locationID withLocation:(CGPoint)digitizerPoint onSurface:(BOOL)isOnSurface tooLargeForFinger:(BOOL)confidenceFlag {
    
    // assume that this is an erroneous message!!!
    if (self.ignoreOriginTouches && CGPointEqualToPoint(digitizerPoint, CGPointZero)) {
        return;
    }
    
    CGPoint point = [self convertDigitizerPointToRelativeScreenPoint:digitizerPoint locationID:locationID];
    
    BOOL isNewTouch = NO;
    TUCTouch *touch = [self obtainTouchWithID:contactID locationID:locationID isNew:&isNewTouch];
    
    if (isNewTouch && (self.cursorTouch == nil || !self.cursorTouch.isActive)) {
        self.cursorTouch = touch;
        self.cursorTouchQualifiedForTap = YES;
        self.cursorTouchDidHold = NO;
        self.cursorTouchStationarySinceDate = nil;
        [self beginInteraction];
    }
    
    [touch setLocation: point];
    [touch setIsOnSurface:isOnSurface];
    [touch setConfidenceFlag:confidenceFlag];
    [touch setLastUpdated:[self currentFrameIDForLocationID:locationID]];
    
    if (!isOnSurface) {
        [touch setPhase: NSTouchPhaseEnded];
        [self removeTouch:touch now:NO];
        [self.delegate touchesDidChange];
        return;
        
    }
    
    if(touch.previousPhase != NSTouchPhaseEnded && !isNewTouch) {
        // update to an existing touch... check if stationary or not
        CGFloat digitizerRelDistance = sqrt(pow(touch.location.x - touch.previousLocation.x, 2) + pow(touch.location.y - touch.previousLocation.y, 2));
        CGFloat screenSize = [self touchscreenForLocationID:locationID].nativePhysicalSize.width;
        //TODO: - Make customizable in settings?
        BOOL isStationary = (digitizerRelDistance * screenSize) < 0.1;
//        BOOL isStationary = CGPointEqualToPoint(touch.location, touch.previousLocation);
        
        if (touch.uuid == self.cursorTouch.uuid) {
            if (!isStationary) {
                self.cursorTouchQualifiedForTap = NO;
                self.cursorTouchStationarySinceDate = nil;
                
            } else if (touch.phase !=  NSTouchPhaseStationary) {
                self.cursorTouchStationarySinceDate = [NSDate date];
            }
        }
        
        [touch setPhase:isStationary ? NSTouchPhaseStationary : NSTouchPhaseMoved];
    }
    
    
    [self.delegate touchesDidChange];
    
    return;
}


- (void)updateTouch:(NSInteger)contactID locationID:(uint32_t)locationID withSize:(CGSize)size azimuth:(CGFloat)azimuth {
    BOOL isNewTouch = NO;
    TUCTouch *touch = [self obtainTouchWithID:contactID locationID:locationID isNew:&isNewTouch];
    [touch setLastUpdated:[self currentFrameIDForLocationID:locationID]];
    
    [touch setSize:size];
    [touch setAzimuth:azimuth];
}



#pragma mark - Mouse Cursor Management



- (void)processTouchesForCursorInput {
    
    if(!self.cursorTouch || !self.postMouseEvents) {
        return;
    }
    
    NSSet<TUCTouch *> *touches = [self activeTouches];
    [self updateInteractionWithTouches:touches];
    
    if (self.interactionMaxTouches >= 2) {
        [self processMultiFingerTouches:touches];
        return;
    }
    
    TUCTouch *cursorTouch = self.cursorTouch;
    NSTouchPhase phase = cursorTouch.phase;
    
    
    if (phase == NSTouchPhaseBegan) {
        [self performMouseEventForGesture:TUCCursorGestureTouchDown];
        return;
    }
    
    
    else if (phase == NSTouchPhaseStationary) {
        NSTimeInterval holdDuration = 0;
        if (self.cursorTouchStationarySinceDate != nil) {
            holdDuration = [[NSDate date] timeIntervalSinceDate:self.cursorTouchStationarySinceDate];
        }
        if (self.cursorTouchQualifiedForTap && holdDuration > self.holdDuration) {
            // the user left the finger on the screen for the min duration required to produce a hold
            self.cursorTouchDidHold = YES;
        }
        
        return;
    }
    
    
    else if (phase == NSTouchPhaseEnded) {
        if (self.cursorTouchDidHold) {
            [self performMouseEventForGesture:TUCCursorGestureHoldAndDrag];
        } else if (!self.cursorTouchQualifiedForTap) {
            [self performMouseEventForGesture:TUCCursorGestureDrag];
        }
        
        [self stopCurrentGesture];
        
        if (self.cursorTouchQualifiedForTap) {
            [self performMouseEventForGesture:TUCCursorGestureTap];
        }
        
        return;
    }
    
    
    else if (phase == NSTouchPhaseCancelled) {
        [self stopCurrentGesture];
        return;
    }
    
    
    if (self.cursorTouchDidHold) {
        [self performMouseEventForGesture:TUCCursorGestureHoldAndDrag];
    } else {
        [self performMouseEventForGesture:TUCCursorGestureDrag];
    }
}


#pragma mark - Multi-Finger Gestures

- (void)beginInteraction {
    if (self.pendingSecondaryClickTimer.isValid) {
        // this might be the second tap of a two finger double tap, which zooms instead of right clicking
        [self.pendingSecondaryClickTimer invalidate];
        self.awaitingSecondTwoFingerTap = YES;
    } else {
        self.awaitingSecondTwoFingerTap = NO;
    }
    self.pendingSecondaryClickTimer = nil;
    
    self.interactionStartDate = [NSDate date];
    self.interactionMaxTouches = 0;
    self.interactionMoved = NO;
    self.interactionStartLocations = [NSMutableDictionary dictionary];
    
    self.multiFingerMode = TUCMultiFingerModeUndecided;
    self.multiFingerStarted = NO;
}


- (void)updateInteractionWithTouches:(NSSet<TUCTouch *> *)touches {
    self.interactionMaxTouches = MAX(self.interactionMaxTouches, touches.count);
    
    CGFloat slop = kTapSlop * [self touchscreenWidth];
    for (TUCTouch *touch in touches) {
        CGPoint p = [self screenPointOfTouch:touch];
        NSValue *start = self.interactionStartLocations[touch.uuid];
        if (start == nil) {
            self.interactionStartLocations[touch.uuid] = [NSValue valueWithPoint:NSPointFromCGPoint(p)];
        } else if ([self distanceBetweenPoint:p and:NSPointToCGPoint(start.pointValue)] > slop) {
            self.interactionMoved = YES;
        }
    }
}


- (void)processMultiFingerTouches:(NSSet<TUCTouch *> *)touches {
    if (!self.multiFingerStarted) {
        // a second finger joined: whatever the first finger started is over, and it is no longer a tap
        self.multiFingerStarted = YES;
        [self stopCurrentGesture];
        self.cursorTouchQualifiedForTap = NO;
        self.cursorTouchDidHold = NO;
        [self anchorWithTouches:touches];
    }
    
    TUCDebugLog("frame n=%lu mode=%ld centroid=(%.1f,%.1f)", (unsigned long)touches.count, (long)self.multiFingerMode,
                [self centroidOfTouches:touches].x, [self centroidOfTouches:touches].y);
    
    if (touches.count == 0) {
        if (self.multiFingerMode != TUCMultiFingerModeDone) {
            TUCMultiFingerMode endedMode = self.multiFingerMode;
            [self finishMultiFingerGesture];
            if (endedMode == TUCMultiFingerModeUndecided) {
                [self handleMultiFingerTap];
            }
        }
        return;
    }
    
    if (touches.count != self.anchorTouchCount) {
        // a finger landed or lifted: a running gesture ends, an undecided one starts over from here
        if (self.multiFingerMode != TUCMultiFingerModeUndecided) {
            [self finishMultiFingerGesture];
        }
        [self anchorWithTouches:touches];
        return;
    }
    
    switch (self.multiFingerMode) {
        case TUCMultiFingerModeUndecided:
            [self identifyMultiFingerGestureWithTouches:touches];
            break;
        case TUCMultiFingerModeScroll:
            [self continueScrollWithTouches:touches];
            break;
        case TUCMultiFingerModeTransform:
            [self continueTransformWithTouches:touches];
            break;
        case TUCMultiFingerModeDockSwipe:
            [self continueDockSwipeWithTouches:touches];
            break;
        case TUCMultiFingerModeDone:
            break;
    }
    
    [self rememberFrameOfTouches:touches];
}


- (void)identifyMultiFingerGestureWithTouches:(NSSet<TUCTouch *> *)touches {
    if (touches.count < 2) {
        // the other fingers lifted before anything was recognized; the last one must not start a gesture alone
        return;
    }

    CGFloat width = [self touchscreenWidth];
    CGPoint centroid = [self centroidOfTouches:touches];
    CGFloat travel = [self distanceBetweenPoint:centroid and:self.anchorCentroid];
    CGFloat spreadChange = [self spreadOfTouches:touches centroid:centroid] - self.anchorSpread;
    TUCCursorUtilities *utils = [TUCCursorUtilities sharedInstance];
    
    if (touches.count == 2) {
        CGFloat dx = centroid.x - self.anchorCentroid.x;
        CGFloat dy = centroid.y - self.anchorCentroid.y;
        if (self.anchorAtRightEdge && -dx > kEdgeSwipeThreshold * width && -dx > 2 * fabs(dy)) {
            // like swiping in from the right edge of a trackpad
            [utils triggerSymbolicHotKey:kTUCSymbolicHotKeyNotificationCenter];
            self.multiFingerMode = TUCMultiFingerModeDone;
            return;
        }
        
        // the arc the fingers travel while turning, comparable with the distance they travel together
        CGFloat rotation = [self angleFrom:self.anchorAngle to:[self angleOfTouches:touches]];
        CGFloat transform = MAX(fabs(spreadChange) * 2, fabs(rotation) * self.anchorSpread);
        CGFloat threshold = kTwoFingerGestureThreshold * width;
        
        if (travel > threshold && travel > transform) {
            if ([self actionForGesture:TUCCursorGestureTwoFingerDrag] != TUCCursorActionScroll) {
                self.multiFingerMode = TUCMultiFingerModeDone;
                return;
            }
            self.multiFingerMode = TUCMultiFingerModeScroll;
            self.recentScrollStep = 0;
            self.holdingScrollJump = NO;
            [utils moveCursorTo:centroid];
            [utils scrollBy:CGPointMake(dx, dy)];
            
        } else if (transform > threshold && transform > travel) {
            if ([self actionForGesture:TUCCursorGesturePinch] != TUCCursorActionMagnify) {
                self.multiFingerMode = TUCMultiFingerModeDone;
                return;
            }
            self.multiFingerMode = TUCMultiFingerModeTransform;
            self.accumulatedRotation = rotation;
            self.rotationLocked = NO;
            [utils moveCursorTo:centroid];
            [utils magnifyBy:[self spreadOfTouches:touches centroid:centroid] / self.anchorSpread - 1];
        }
        return;
    }
    
    if (touches.count >= 4 && fabs(spreadChange) > kFourFingerPinchThreshold * width && fabs(spreadChange) > travel) {
        self.multiFingerMode = TUCMultiFingerModeDockSwipe;
        self.dockSwipeMotion = TUCDockSwipeMotionPinch;
        [utils moveCursorTo:centroid];
        [utils dockSwipe:TUCDockSwipeMotionPinch by:[self dockSwipeDeltaForSpreadChange:spreadChange]];
        
    } else if (travel > kMultiFingerSwipeThreshold * width) {
        CGFloat dx = centroid.x - self.anchorCentroid.x;
        CGFloat dy = centroid.y - self.anchorCentroid.y;
        TUCDockSwipeMotion motion = fabs(dx) > fabs(dy) ? TUCDockSwipeMotionHorizontal : TUCDockSwipeMotionVertical;
        self.multiFingerMode = TUCMultiFingerModeDockSwipe;
        self.dockSwipeMotion = motion;
        // the cursor decides which display's Spaces or Mission Control react
        [utils moveCursorTo:centroid];
        [utils dockSwipe:motion by:[self dockSwipeDeltaForMotion:motion translation:CGPointMake(dx, dy)]];
    }
}


- (void)continueScrollWithTouches:(NSSet<TUCTouch *> *)touches {
    TUCCursorUtilities *utils = [TUCCursorUtilities sharedInstance];
    CGPoint delta = [self steadyDeltaOfTouches:touches];
    CGFloat step = hypot(delta.x, delta.y);
    
    if (self.holdingScrollJump) {
        self.holdingScrollJump = NO;
        if (step < 1) {
            // Digitizers report the contacts leaping ahead, then frozen, right before they lift.
            // Fingers cannot accelerate like that, so the leap is dropped.
            TUCDebugLog("dropped lift jump (%.1f,%.1f)", self.heldScrollJump.x, self.heldScrollJump.y);
        } else {
            [utils scrollBy:self.heldScrollJump];
        }
    }
    
    if (self.recentScrollStep > 0 && step > kScrollJumpFactor * self.recentScrollStep && step > kScrollJumpMinimum * [self touchscreenWidth]) {
        self.heldScrollJump = delta;
        self.holdingScrollJump = YES;
        return;
    }
    
    if (step > 0) {
        self.recentScrollStep = self.recentScrollStep > 0 ? 0.5 * self.recentScrollStep + 0.5 * step : step;
    }
    [utils scrollBy:delta];
}


/**
 How far the fingers moved together since the last frame. A finger that starts lifting or landing jumps
 for a frame or two; when the fingers disagree, the one that moved less is the one to trust.
 */
- (CGPoint)steadyDeltaOfTouches:(NSSet<TUCTouch *> *)touches {
    NSMutableArray<NSValue *> *deltas = [NSMutableArray array];
    for (TUCTouch *touch in touches) {
        NSValue *previous = self.previousTouchLocations[touch.uuid];
        if (previous == nil) {
            continue;
        }
        CGPoint p = [self screenPointOfTouch:touch];
        [deltas addObject:[NSValue valueWithPoint:NSMakePoint(p.x - previous.pointValue.x, p.y - previous.pointValue.y)]];
    }
    if (deltas.count == 0) {
        return CGPointZero;
    }
    
    CGPoint average = [self centroidOfPoints:deltas];
    NSPoint smallest = deltas.firstObject.pointValue;
    NSPoint largest = smallest;
    for (NSValue *value in deltas) {
        NSPoint d = value.pointValue;
        if (hypot(d.x, d.y) < hypot(smallest.x, smallest.y)) smallest = d;
        if (hypot(d.x, d.y) > hypot(largest.x, largest.y)) largest = d;
    }
    
    CGFloat disagreement = hypot(largest.x - smallest.x, largest.y - smallest.y);
    if (disagreement > MAX(6, hypot(smallest.x, smallest.y))) {
        return NSPointToCGPoint(smallest);
    }
    return average;
}


- (void)continueTransformWithTouches:(NSSet<TUCTouch *> *)touches {
    TUCCursorUtilities *utils = [TUCCursorUtilities sharedInstance];
    CGPoint centroid = [self centroidOfTouches:touches];
    
    CGFloat spread = [self spreadOfTouches:touches centroid:centroid];
    if (self.previousSpread > 0) {
        [utils magnifyBy:spread / self.previousSpread - 1];
    }
    
    // small turns happen in every pinch; only rotate once the fingers clearly turn
    CGFloat rotation = [self angleFrom:self.previousAngle to:[self angleOfTouches:touches]];
    self.accumulatedRotation += rotation;
    if (!self.rotationLocked && fabs(self.accumulatedRotation) * 180 / M_PI > kRotationLockDegrees) {
        self.rotationLocked = YES;
    }
    if (self.rotationLocked) {
        // screen coordinates grow downwards, so a positive angle turns clockwise; gestures count counterclockwise
        [utils rotateBy:-rotation * 180 / M_PI];
    }
}


- (void)continueDockSwipeWithTouches:(NSSet<TUCTouch *> *)touches {
    TUCCursorUtilities *utils = [TUCCursorUtilities sharedInstance];
    CGPoint centroid = [self centroidOfTouches:touches];
    
    if (self.dockSwipeMotion == TUCDockSwipeMotionPinch) {
        CGFloat spreadChange = [self spreadOfTouches:touches centroid:centroid] - self.previousSpread;
        [utils dockSwipe:TUCDockSwipeMotionPinch by:[self dockSwipeDeltaForSpreadChange:spreadChange]];
    } else {
        CGPoint translation = CGPointMake(centroid.x - self.previousCentroid.x, centroid.y - self.previousCentroid.y);
        [utils dockSwipe:self.dockSwipeMotion by:[self dockSwipeDeltaForMotion:self.dockSwipeMotion translation:translation]];
    }
}


- (double)dockSwipeDeltaForMotion:(TUCDockSwipeMotion)motion translation:(CGPoint)translation {
    CGSize size = [self touchscreenSize];
    if (motion == TUCDockSwipeMotionHorizontal) {
        // natural direction: fingers moving right reveal the Space on the left
        return -translation.x * kDockSwipeProgressPerSpace / (size.width + kSpaceSeparatorWidth);
    }
    // fingers moving up (negative y) open Mission Control
    return translation.y / size.height;
}


- (double)dockSwipeDeltaForSpreadChange:(CGFloat)spreadChange {
    return spreadChange / (kDockPinchTravel * [self touchscreenWidth]);
}


- (void)finishMultiFingerGesture {
    TUCDebugLog("finish mode=%ld", (long)self.multiFingerMode);
    TUCCursorUtilities *utils = [TUCCursorUtilities sharedInstance];
    switch (self.multiFingerMode) {
        case TUCMultiFingerModeScroll:
            [utils endScroll];
            break;
        case TUCMultiFingerModeTransform:
            [utils stopMagnifying];
            break;
        case TUCMultiFingerModeDockSwipe:
            [utils endDockSwipe];
            break;
        case TUCMultiFingerModeUndecided:
        case TUCMultiFingerModeDone:
            break;
    }
    self.multiFingerMode = TUCMultiFingerModeDone;
}


- (void)handleMultiFingerTap {
    BOOL isTap = !self.interactionMoved
              && [[NSDate date] timeIntervalSinceDate:self.interactionStartDate] < kMultiFingerTapMaxDuration;
    if (!isTap) {
        return;
    }
    
    CGPoint location = [self centroidOfPoints:self.interactionStartLocations.allValues];
    TUCCursorUtilities *utils = [TUCCursorUtilities sharedInstance];
    
    if (self.interactionMaxTouches == 2) {
        if (self.awaitingSecondTwoFingerTap
            && [self distanceBetweenPoint:location and:self.pendingTwoFingerTapLocation] < kTapSlop * 3 * [self touchscreenWidth]) {
            self.awaitingSecondTwoFingerTap = NO;
            [utils moveCursorTo:location];
            [utils smartMagnify];
            return;
        }
        
        // wait whether a second tap turns this into a smart zoom
        self.pendingTwoFingerTapLocation = location;
        if ([self actionForGesture:TUCCursorGestureTapSecondFinger] == TUCCursorActionSecondaryClick) {
            __weak typeof(self) weakSelf = self;
            self.pendingSecondaryClickTimer = [NSTimer scheduledTimerWithTimeInterval:kTwoFingerDoubleTapInterval repeats:NO block:^(NSTimer *timer) {
                [utils performSecondaryClickAt:location];
                weakSelf.pendingSecondaryClickTimer = nil;
            }];
        }
        
    } else if (self.interactionMaxTouches == 3) {
        // a trackpad looks up with a force click or a three finger tap
        [utils moveCursorTo:location];
        [utils triggerSymbolicHotKey:kTUCSymbolicHotKeyLookUp];
    }
}


#pragma mark - Multi-Finger Geometry

- (void)anchorWithTouches:(NSSet<TUCTouch *> *)touches {
    self.anchorTouchCount = touches.count;
    if (touches.count == 0) {
        return;
    }
    CGPoint centroid = [self centroidOfTouches:touches];
    self.anchorCentroid = centroid;
    self.anchorSpread = [self spreadOfTouches:touches centroid:centroid];
    self.anchorAngle = [self angleOfTouches:touches];
    
    CGFloat rightmost = 0;
    for (TUCTouch *touch in touches) {
        rightmost = MAX(rightmost, touch.location.x);
    }
    self.anchorAtRightEdge = rightmost > 1 - kRightEdgeZone;
    
    [self rememberFrameOfTouches:touches];
}


- (void)rememberFrameOfTouches:(NSSet<TUCTouch *> *)touches {
    CGPoint centroid = [self centroidOfTouches:touches];
    self.previousCentroid = centroid;
    self.previousSpread = [self spreadOfTouches:touches centroid:centroid];
    self.previousAngle = [self angleOfTouches:touches];
    
    self.previousTouchLocations = [NSMutableDictionary dictionaryWithCapacity:touches.count];
    for (TUCTouch *touch in touches) {
        self.previousTouchLocations[touch.uuid] = [NSValue valueWithPoint:NSPointFromCGPoint([self screenPointOfTouch:touch])];
    }
}


- (CGPoint)screenPointOfTouch:(TUCTouch *)touch {
    return [self convertScreenPointRelativeToAbsolute:touch.location locationID:touch.locationID];
}


- (CGPoint)centroidOfTouches:(NSSet<TUCTouch *> *)touches {
    NSMutableArray<NSValue *> *points = [NSMutableArray arrayWithCapacity:touches.count];
    for (TUCTouch *touch in touches) {
        [points addObject:[NSValue valueWithPoint:NSPointFromCGPoint([self screenPointOfTouch:touch])]];
    }
    return [self centroidOfPoints:points];
}


- (CGPoint)centroidOfPoints:(NSArray<NSValue *> *)points {
    if (points.count == 0) {
        return CGPointZero;
    }
    CGPoint sum = CGPointZero;
    for (NSValue *value in points) {
        sum.x += value.pointValue.x;
        sum.y += value.pointValue.y;
    }
    return CGPointMake(sum.x / points.count, sum.y / points.count);
}


/// Mean distance of the fingers from their centroid, in screen points.
- (CGFloat)spreadOfTouches:(NSSet<TUCTouch *> *)touches centroid:(CGPoint)centroid {
    if (touches.count == 0) {
        return 0;
    }
    CGFloat sum = 0;
    for (TUCTouch *touch in touches) {
        sum += [self distanceBetweenPoint:[self screenPointOfTouch:touch] and:centroid];
    }
    return sum / touches.count;
}


/// Angle of the line between the first two fingers, in radians. Fingers are ordered by contact ID so the angle does not flip.
- (CGFloat)angleOfTouches:(NSSet<TUCTouch *> *)touches {
    if (touches.count < 2) {
        return 0;
    }
    NSArray<TUCTouch *> *sorted = [touches.allObjects sortedArrayUsingSelector:@selector(compareWithAnotherTouch:)];
    CGPoint a = [self screenPointOfTouch:sorted[0]];
    CGPoint b = [self screenPointOfTouch:sorted[1]];
    return atan2(b.y - a.y, b.x - a.x);
}


/// Shortest signed turn from one angle to another, in radians.
- (CGFloat)angleFrom:(CGFloat)from to:(CGFloat)to {
    CGFloat difference = to - from;
    while (difference > M_PI) difference -= 2 * M_PI;
    while (difference < -M_PI) difference += 2 * M_PI;
    return difference;
}


- (CGSize)touchscreenSize {
    return [self touchscreenForLocationID:self.cursorTouch.locationID].frame.size;
}


- (CGFloat)touchscreenWidth {
    return [self touchscreenSize].width;
}


- (void)performMouseEventForGesture:(TUCCursorGesture)gesture {
    TUCTouch *touch = self.cursorTouch;
    
    CGPoint screenLocation = [self convertScreenPointRelativeToAbsolute:touch.location locationID:touch.locationID];
    
    TUCCursorUtilities *utils = [TUCCursorUtilities sharedInstance];
    
    TUCCursorAction action = [self actionForGesture:gesture];
    
    CGFloat doubleClickSpan = self.doubleClickTolerance * [[self touchscreenForLocationID:touch.locationID] pixelsPerMM];
    [[TUCCursorUtilities sharedInstance] setDoubleClickTolerance:doubleClickSpan];
    
    switch (action) {
        case TUCCursorActionNone:
            break;
            
        case TUCCursorActionMove:
            [utils moveCursorTo:screenLocation];
            break;
            
        case TUCCursorActionMoveClickIfNeeded:
            [utils moveCursorTo:screenLocation];
            if ([self isLocationOutsideFrontmostWindow:screenLocation locationID:touch.locationID]) {
                [utils performClickAt:screenLocation];
            }
            
            break;
            
        case TUCCursorActionPointAndClick:
            [utils moveCursorTo:screenLocation];
            if (touch.phase == NSTouchPhaseEnded) {
                [utils performClickAt:screenLocation];
            }
            break;
            
        case TUCCursorActionDrag:
            [utils dragCursorTo:screenLocation phase:touch.phase];
            break;
            
        case TUCCursorActionClick:
            [utils performClickAt:screenLocation];
            break;
            
        case TUCCursorActionSecondaryClick:
            [utils performSecondaryClickAt: screenLocation];
            break;
            
        case TUCCursorActionScroll: {
            CGPoint prevLocation = [self convertScreenPointRelativeToAbsolute:touch.previousLocation locationID:touch.locationID];
            CGPoint translation = CGPointMake(screenLocation.x - prevLocation.x,
                                              screenLocation.y - prevLocation.y);
            [utils scroll:translation phase:touch.phase];
            
            break; }
            
        case TUCCursorActionMagnify:
            // needs two fingers, so the multi-finger recognizer drives it
            break;
    }
}


- (TUCCursorAction)actionForGesture:(TUCCursorGesture)gesture {
    
    if (self.delegate != nil) {
        return [self.delegate actionForGesture:gesture];
    }
    
    switch(gesture) {
        case TUCCursorGestureTouchDown:         return TUCCursorActionMoveClickIfNeeded;
        case TUCCursorGestureTap:               return TUCCursorActionClick;
        case TUCCursorGestureLongPress:         return TUCCursorActionClick;
        case TUCCursorGestureDrag:              return TUCCursorActionScroll;
        case TUCCursorGestureHoldAndDrag:       return TUCCursorActionDrag;
        case TUCCursorGestureTapSecondFinger:   return TUCCursorActionSecondaryClick;
        case TUCCursorGestureTwoFingerDrag:     return TUCCursorActionDrag;
            
        case TUCCursorGesturePinch:             return TUCCursorActionMagnify;
        case _TUCCursorGestureNone:             return TUCCursorActionNone;
    }
}


#pragma mark - Touch Set

/**
 The `touchSet` can contain touches whose phase is ended or cancelled. activeTouches. filteres those out
 */
- (NSSet<TUCTouch *> *)activeTouches {
    NSPredicate *p1 = [NSPredicate predicateWithFormat:@"phase != %d", NSTouchPhaseEnded];
    NSPredicate *p2 = [NSPredicate predicateWithFormat:@"phase != %d", NSTouchPhaseCancelled];
    
    NSPredicate *predicate = [NSCompoundPredicate andPredicateWithSubpredicates:@[p1, p2]];
    
    return [self.touchSet filteredSetUsingPredicate:predicate];
}



- (CGFloat)distanceBetweenPoint:(CGPoint)p1 and:(CGPoint)p2 {
    CGFloat dx = p1.x - p2.x;
    CGFloat dy = p1.y - p2.y;
    
    return sqrt( pow(dx, 2) + pow(dy, 2) );
}


/**
 maxDistance in mm
 */
- (NSSet<TUCTouch *> *)touchesInProximityTo:(CGPoint)point maxDistance:(CGFloat)mmDistance locationID:(uint32_t)locationID {
    
    TUCScreen *screen = [self touchscreenForLocationID:locationID];
    CGFloat screenDistance = mmDistance * [screen pixelsPerMM];
    CGPoint distance = CGPointMake(screenDistance / screen.frame.size.width,
                                   screenDistance / screen.frame.size.height);
    
    NSPredicate * predicate = [NSPredicate predicateWithBlock: ^BOOL(TUCTouch *t, NSDictionary *bind) {
        if (t.locationID != locationID) return NO;

        CGFloat dx = [t location].x - point.x;
        CGFloat dy = [t location].y - point.y;

        return sqrt( pow(dx, 2) + pow(dy, 2) ) < distance.x;
    }];
    
    return [self.touchSet filteredSetUsingPredicate:predicate];
}


/**
 Removes a touch from the touch set. As a previous touch might be important for gesture evaluation, it is removed after half a second
 */
- (void)removeTouch:(TUCTouch *)touch now:(BOOL)instantDeletion{
    //    if (touch.uuid == self.touchUsedForCursor.uuid) {
    //        [self processTouchesForCursorInput];
    //        self.touchUsedForCursor = nil;
    //    }
    
    if (instantDeletion) {
        [[self touchSet] removeObject:touch];
        [[self delegate] touchesDidChange];
        return;
    }
    
    __weak id weakSelf = self;
    NSUUID *uuid = touch.uuid;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
        for(TUCTouch *touch in [weakSelf touchSet]) {
            if (touch.uuid == uuid && [[weakSelf touchSet] containsObject:touch]) {
                [[weakSelf touchSet] removeObject:touch];
                [[weakSelf delegate] touchesDidChange];
                return;
            }
        }
    });
}


/**
 Checks the touch set if a touch exists
 */
- (TUCTouch *)findTouchWithID:(NSInteger)contactID locationID:(uint32_t)locationID includingPastTouches:(BOOL)includePastTouches {
    NSSet *set = includePastTouches ? self.touchSet : [self activeTouches];
    
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"contactID == %d AND locationID == %u", contactID, locationID];
    TUCTouch *touch = [[set filteredSetUsingPredicate:predicate] anyObject];
    return touch;
}

/**
 Returns the existing touch object or a new one if this ID does not exist in the set yet.
 */
- (TUCTouch *)obtainTouchWithID:(NSInteger)contactID locationID:(uint32_t)locationID isNew:(BOOL*)isNew {
    TUCTouch *touch = [self findTouchWithID:contactID locationID:locationID includingPastTouches:NO];
    *isNew = NO;
    if(!touch) {
        touch = [[TUCTouch alloc] initWithContactID:contactID locationID:locationID];
        [self.touchSet addObject:touch];
        *isNew = YES;
    }
    return touch;
}





#pragma mark - Screen Characteristics

/**
 the relative hardware points are always in the direction the digitizer is built in.
 If the display is rotated, we need to rotate these points
 */
- (CGPoint)convertDigitizerPointToRelativeScreenPoint:(CGPoint)devicePoint locationID:(uint32_t)locationID {
    TUCScreen *screen = [self touchscreenForLocationID:locationID];

    CGFloat rotation = screen.rotation;

    CGFloat extra = [[self delegate] digitizerRotationForLocationID:locationID];

    rotation += extra;
    rotation = fmod(rotation, 360);
    if (rotation < 0) {
        rotation += 360;
    }

    // Rotate the glass-relative point into the screen's content orientation.
    CGPoint rotated;
    if (rotation == 180) {
        rotated = CGPointMake(1 - devicePoint.x, 1 - devicePoint.y);
    } else if (rotation == 90) {
        rotated = CGPointMake(1 - devicePoint.y, devicePoint.x);
    } else if (rotation == 270) {
        rotated = CGPointMake(devicePoint.y, 1 - devicePoint.x);
    } else {
        rotated = devicePoint;
    }

    // Then account for any letterboxing when the content doesn't fill the panel (mirroring
    // a differently-shaped display). A no-op when the aspect ratios already match.
    return [screen convertGlassPointToContentPoint:rotated];
}



- (CGPoint)convertScreenPointRelativeToAbsolute:(CGPoint)relativePoint locationID:(uint32_t)locationID {
    return [[self touchscreenForLocationID:locationID] convertPointRelativeToAbsolute:relativePoint];
}



- (TUCScreen *)touchscreenForLocationID:(uint32_t)locationID {
    if (self.delegate != nil) {
        return [self.delegate touchscreenForLocationID:locationID];
    }
    
    return [[TUCScreen allScreens] firstObject];
}



- (BOOL)isPointInMenuBar:(CGPoint)point locationID:(uint32_t)locationID {
    CGFloat menuBarHeight = [[[NSApplication sharedApplication] mainMenu] menuBarHeight];
    
    CGRect screenFrame = [self touchscreenForLocationID:locationID].frame;
    CGRect menuBarFrame = CGRectMake(screenFrame.origin.x,
                                     screenFrame.origin.y * -1,
                                     screenFrame.size.width,
                                     menuBarHeight);
    
    if (CGRectContainsPoint(menuBarFrame, point)) {
        return YES;
    }
    return NO;
}


- (BOOL)isSystemChromeOwner:(pid_t)pid name:(NSString *)ownerName {
    static NSSet<NSString *> *chromeBundleIDs;
    static NSSet<NSString *> *chromeOwnerNames;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        chromeBundleIDs = [NSSet setWithArray:@[
            @"com.apple.dock",
            @"com.apple.controlcenter",
            @"com.apple.notificationcenterui",
        ]];
        // The Window Server has no NSRunningApplication, so match it by owner name.
        chromeOwnerNames = [NSSet setWithArray:@[ @"Window Server", @"WindowServer" ]];
    });

    if (ownerName && [chromeOwnerNames containsObject:ownerName]) {
        return YES;
    }

    NSString *bundleID = [NSRunningApplication runningApplicationWithProcessIdentifier:pid].bundleIdentifier;
    return bundleID != nil && [chromeBundleIDs containsObject:bundleID];
}


- (BOOL)isLocationOutsideFrontmostWindow:(CGPoint)point locationID:(uint32_t)locationID {

    if ([self isPointInMenuBar:point locationID:locationID]) {
        return NO;
    }

    pid_t frontmostPID = [[[NSWorkspace sharedWorkspace] frontmostApplication] processIdentifier];

    CFArrayRef array = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly|kCGWindowListExcludeDesktopElements, kCGNullWindowID);

    // The window list is ordered front-to-back by window *level* (not grouped by app), so
    // high-level overlays — including our own screenSaver-level panels — come before the
    // active app's normal windows. `behindFrontmostWindow` flips once we pass the active
    // app's topmost window: windows seen before it are stacked above it, windows after are
    // behind it.
    BOOL behindFrontmostWindow = NO;
    BOOL res = NO;

    for (CFIndex i=0; i<CFArrayGetCount(array); i++) {
        CFDictionaryRef dic = CFArrayGetValueAtIndex(array, i);

        CFNumberRef numPid = CFDictionaryGetValue(dic, kCGWindowOwnerPID);
        pid_t currPID;
        CFNumberGetValue(numPid, kCFNumberIntType,  &currPID);
        BOOL isFrontmostApp = currPID == frontmostPID;

        CFDictionaryRef bounds = CFDictionaryGetValue(dic, kCGWindowBounds);
        CGRect nextFrame;
        CGRectMakeWithDictionaryRepresentation(bounds, &nextFrame);
        BOOL isInside = CGRectContainsPoint(nextFrame, point);

        if (isFrontmostApp && !behindFrontmostWindow) {
            behindFrontmostWindow = YES;
        }

        if (!isInside) continue;

        NSString *ownerName = (__bridge NSString *)CFDictionaryGetValue(dic, kCGWindowOwnerName);
        if ([self isSystemChromeOwner:currPID name:ownerName]) {
            continue;
        }

        // First real window under the point = the one the finger actually hits.
        if (isFrontmostApp) {
            res = NO;   // already the active window — the tap actuates it directly
        } else if (!behindFrontmostWindow) {
            res = NO;   // stacked above the active app (an overlay or our own panel) — takes the tap directly
        } else {
            // A background window of another app — normally inject a click to raise it.
            // Exception: the title bar. A background title bar accepts clicks directly, so
            // our injected raise-click plus the tap's own click would register as a
            // title-bar double-click (→ zoom/fullscreen). A single tap already raises the
            // window, so skip the extra click within the title-bar strip.
            //
            // CGWindowList can't tell us the actual title-bar/toolbar height, so this is a
            // heuristic constant. Erring high (toolbars on Tahoe are tall) costs at most a
            // missed raise-click near the top of a background window; erring low brings the
            // destructive double-click-zoom back.
            CGFloat titleBarHeight = 44;
            BOOL inTitleBar = (point.y - nextFrame.origin.y) <= titleBarHeight;
            res = inTitleBar ? NO : YES;
        }
        break;
    }

    CFRelease(array);
    return res;
}




#pragma mark -

- (instancetype)init {
    if(self = [super init]) {
        self.touchSet = [NSMutableSet new];
        self.postMouseEvents = YES;
        
        self.cursorTouchQualifiedForTap = NO;
        self.cursorTouchStationarySinceDate = nil;
        
        self.frameIDsByLocationID = [NSMutableDictionary new];
        
        self.doubleClickTolerance = 5;
        self.holdDuration = 0.08;
        self.errorResistance = 0;
        
        self.ignoreOriginTouches = NO;
    }
    return self;
}


- (NSString *)debugDescription {
    NSMutableString *str = [[NSString stringWithFormat:@"Touch Set contains %ld touches:{\n", [self.touchSet count]] mutableCopy];
    
    for (TUCTouch *touch in [[self.touchSet allObjects] sortedArrayUsingSelector:@selector(compareWithAnotherTouch:)] ) {
        [str appendString: [NSString stringWithFormat:@"  %@", [touch debugDescription]] ];
        if (touch.contactID == self.cursorTouch.contactID) {
            [str appendString: @" <<<CURSOR>>>\n" ];
        } else {
            [str appendString: @"\n" ];
        }
    }
    
    [str appendString:@"}"];
    return str;
}

- (void)triggerSystemAccessibilityAccessAlert {
    CGPoint loc = [[TUCCursorUtilities sharedInstance] currentCursorLocation];
    [[TUCCursorUtilities sharedInstance] moveCursorTo:loc];
}



#pragma mark - Bridge calls of C Header to Objective-C

void TouchInputManagerUpdateTouchPosition(void *self, uint32_t locationID, CFIndex contactID, CGFloat x, CGFloat y, Boolean onSurface, Boolean isValid) {
    CGPoint point = CGPointMake(x, y);
    [(__bridge id)self updateTouch:(NSInteger)contactID locationID:locationID withLocation:point onSurface:onSurface tooLargeForFinger:isValid];
}

void TouchInputManagerUpdateTouchSize(void *self, uint32_t locationID, CFIndex contactID, CGFloat width, CGFloat height, CGFloat azimuth) {
    CGSize size = CGSizeMake(width, height);
    [(__bridge id)self updateTouch:(NSInteger)contactID locationID:locationID withSize:size azimuth:azimuth];
}

void TouchInputManagerDidProcessReport(void *self, uint32_t locationID) {
    [(__bridge id)self didProcessReportForLocationID:locationID];
}

void TouchInputManagerDidConnectTouchscreen(void *self, uint32_t locationID) {
    [(__bridge id)self didConnectTouchscreenWithLocationID:locationID];
}

void TouchInputManagerDidDisconnectTouchscreen(void *self, uint32_t locationID) {
    [(__bridge id)self didDisconnectTouchscreenWithLocationID:locationID];
}


@end
