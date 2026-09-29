//
//  TUCCursorUtilities.m
//  Touch Up Core
//
//  Created by Sebastian Hueber on 11.02.23.
//

#import "TUCCursorUtilities.h"

#import <dlfcn.h>

@interface TUCCursorUtilities ()

@property NSInteger cursorClickCount;
@property NSDate *timeOfLastClick;
@property CGPoint locationOfLastClick;

@property BOOL isLeftMouseDown;

@property BOOL isGestureScrolling;
@property CGPoint scrollRemainder;
@property (strong) NSMutableArray<NSValue *> *scrollSamples;   // CGVector (dx, dy) per sample
@property (strong) NSMutableArray<NSNumber *> *scrollSampleTimes;

@property (strong) NSTimer *momentumScrollTimer;
@property CGPoint momentumVelocity;                            // points per second
@property CFAbsoluteTime momentumLastTime;
@property BOOL momentumStarted;

@property BOOL isMagnifying;
@property BOOL isRotating;

@property TUCDockSwipeMotion dockSwipeMotion;
@property BOOL dockSwiping;
@property double dockSwipeOffset;
@property double dockSwipeLastDelta;
@property (strong) NSArray<NSTimer *> *dockSwipeEndResendTimers;

@end


// Field numbers of undocumented CGEvent fields, as observed in real trackpad events.
// Mac Mouse Fix (github.com/noah-nuebling/mac-mouse-fix) documents most of them.
static const CGEventField kTUCEventTypeField        = 55;
static const CGEventField kTUCGestureSubtypeField   = 110;
static const CGEventField kTUCGesturePhaseField     = 132;
static const CGEventField kTUCMagnificationField    = 113;
static const CGEventField kTUCRotationField         = 114;
static const CGEventField kTUCGestureScrollXField   = 116;
static const CGEventField kTUCGestureScrollYField   = 119;
static const CGEventField kTUCScrollInvertedField   = 137;

static const int64_t kTUCEventTypeGesture   = 29;
static const int64_t kTUCEventTypeDockSwipe = 30;

static const int64_t kTUCGestureSubtypeRotation    = 5;
static const int64_t kTUCGestureSubtypeScroll      = 6;
static const int64_t kTUCGestureSubtypeZoom        = 8;
static const int64_t kTUCGestureSubtypeZoomToggle  = 22;
static const int64_t kTUCGestureSubtypeDockSwipe   = 23;

// Trackpads report larger gesture deltas than point deltas; this makes swiping between pages as easy as on a trackpad.
static const CGFloat kGestureScrollScale = 1.67;

static const NSTimeInterval kMomentumTickInterval = 1.0 / 120;
static const CGFloat kMomentumDecayPerMS = 0.998;             // same feel as UIScrollView's normal deceleration
static const CGFloat kMomentumStopSpeed = 20;                 // points per second
static const CGFloat kMomentumMaxSpeed = 8000;
static const NSTimeInterval kVelocityWindow = 0.1;
static const NSTimeInterval kVelocityMaxPause = 0.05;          // a finger that rested before lifting does not fling

@implementation TUCCursorUtilities

+ (TUCCursorUtilities *)sharedInstance {
    static TUCCursorUtilities *sharedInstance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (!sharedInstance) {
            sharedInstance = [[TUCCursorUtilities alloc] init];
            sharedInstance.isLeftMouseDown = NO;
            sharedInstance.cursorClickCount = 0;
            sharedInstance.timeOfLastClick = [NSDate dateWithTimeIntervalSince1970:0];
            sharedInstance.locationOfLastClick = CGPointZero;
            sharedInstance.scrollSamples = [NSMutableArray array];
            sharedInstance.scrollSampleTimes = [NSMutableArray array];
        }
    });
    return sharedInstance;
}





- (CGPoint)currentCursorLocation {
    CGEventRef dummy = CGEventCreate(NULL);
    CGPoint location = CGEventGetLocation(dummy);
    CFRelease(dummy);
    return location;
}



- (void)moveCursorTo:(CGPoint)aLocation {
    [self cancelMomentumScroll];
    [self stopDraggingCursor];
    
    CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, aLocation, kCGMouseButtonLeft);
    CGEventSetIntegerValueField(event, kCGMouseEventClickState, 0);
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}



- (void)bringWindowToFrontAt:(CGPoint)aLocation {
    CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, aLocation, kCGMouseButtonLeft);
    CGEventSetIntegerValueField(event, kCGMouseEventClickState, 1);
    CGEventTimestamp time = CGEventGetTimestamp(event);
    CGEventSetTimestamp(event, time-1);
    
    CGEventPost(kCGHIDEventTap, event);
    CGEventSetType(event, kCGEventLeftMouseDragged);
    CGEventPost(kCGHIDEventTap, event);
    CGEventSetLocation(event, aLocation);
    CGEventSetType(event, kCGEventLeftMouseUp);
    CGEventPost(kCGHIDEventTap, event);
    
    CFRelease(event);
    //    self.isLeftMouseDown = YES;
}

/**
 integrated double click support: needs checks time between clicks and spatial distance
 */
- (void)performClickAt:(CGPoint)aLocation {
    [self updateCursorClickCountWithLocation:aLocation];
    
    CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, aLocation, kCGMouseButtonLeft);
    CGEventSetIntegerValueField(event, kCGMouseEventClickState, self.cursorClickCount);
    CGEventPost(kCGHIDEventTap, event);
    CGEventSetType(event, kCGEventLeftMouseUp);
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
    
    self.timeOfLastClick = [NSDate date];
    self.locationOfLastClick = aLocation;
}


- (void)updateCursorClickCountWithLocation:(CGPoint)aLocation {
    ++self.cursorClickCount;
    
    NSTimeInterval durationSinceLastClick = [[NSDate date] timeIntervalSinceDate:self.timeOfLastClick];
    
    if (durationSinceLastClick > [NSEvent doubleClickInterval] || self.cursorClickCount == 4) {
        self.cursorClickCount = 1;
    }
    
    else if ((aLocation.x - self.locationOfLastClick.x) > self.doubleClickTolerance
             && (aLocation.y - self.locationOfLastClick.y) > self.doubleClickTolerance) {
        // touch is too far away
        self.cursorClickCount = 1;
    }
}


- (void)performSecondaryClickAt:(CGPoint)aLocation {
    CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventRightMouseDown, aLocation, kCGMouseButtonRight);
    CGEventSetIntegerValueField(event, kCGMouseEventClickState, 1);
    CGEventPost(kCGHIDEventTap, event);
    CGEventSetType(event, kCGEventRightMouseUp);
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}



- (void)dragCursorTo:(CGPoint)aLocation phase:(NSTouchPhase)phase  {
    if (phase == NSTouchPhaseEnded || phase == NSTouchPhaseCancelled) {
        [self stopDraggingCursor];
        return;
    }
    
    
    if (self.isLeftMouseDown) {
        CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDragged, aLocation, kCGMouseButtonLeft);
        CGEventSetIntegerValueField(event, kCGMouseEventClickState, self.cursorClickCount);
        CGEventPost(kCGHIDEventTap, event);
        CFRelease(event);
        
    } else {
        [self moveCursorTo:aLocation];
        [self updateCursorClickCountWithLocation:aLocation];
        CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, aLocation, kCGMouseButtonLeft);
        CGEventSetIntegerValueField(event, kCGMouseEventClickState, self.cursorClickCount);
        CGEventPost(kCGHIDEventTap, event);
        CFRelease(event);
        
        self.isLeftMouseDown = YES;
    }
}


- (void)stopDraggingCursor {
    if (self.isLeftMouseDown) {
        CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp, [self currentCursorLocation], kCGMouseButtonLeft);
        CGEventSetIntegerValueField(event, kCGMouseEventClickState, self.cursorClickCount);
        CGEventPost(kCGHIDEventTap, event);
        CFRelease(event);
        
        self.isLeftMouseDown = NO;
    }
}



- (void)scroll:(CGPoint)translation phase:(NSTouchPhase)phase {
    if (phase == NSTouchPhaseEnded || phase == NSTouchPhaseCancelled) {
        [self endScroll];
    } else {
        [self scrollBy:translation];
    }
}


#pragma mark - Trackpad-style Scrolling

- (void)scrollBy:(CGPoint)delta {
    [self stopDraggingCursor];
    [self cancelMomentumScroll];
    
    if (!self.isGestureScrolling) {
        [self.scrollSamples removeAllObjects];
        [self.scrollSampleTimes removeAllObjects];
        self.scrollRemainder = CGPointZero;
    }
    [self recordScrollSample:delta];
    
    CGScrollPhase phase = self.isGestureScrolling ? kCGScrollPhaseChanged : kCGScrollPhaseBegan;
    if ([self postScroll:delta scrollPhase:phase momentumPhase:kCGMomentumScrollPhaseNone]) {
        self.isGestureScrolling = YES;
    }
}


- (void)endScroll {
    if (!self.isGestureScrolling) {
        return;
    }
    self.isGestureScrolling = NO;
    [self postScroll:CGPointZero scrollPhase:kCGScrollPhaseEnded momentumPhase:kCGMomentumScrollPhaseNone];
    
    CGPoint velocity = [self releaseVelocity];
    CGFloat speed = hypot(velocity.x, velocity.y);
    if (speed < kMomentumStopSpeed) {
        return;
    }
    if (speed > kMomentumMaxSpeed) {
        velocity = CGPointMake(velocity.x * kMomentumMaxSpeed / speed, velocity.y * kMomentumMaxSpeed / speed);
    }
    
    self.momentumVelocity = velocity;
    self.momentumLastTime = CFAbsoluteTimeGetCurrent();
    self.momentumStarted = NO;
    self.momentumScrollTimer = [NSTimer scheduledTimerWithTimeInterval:kMomentumTickInterval target:self selector:@selector(updateMomentumScroll) userInfo:nil repeats:YES];
}


- (void)updateMomentumScroll {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    CFTimeInterval dt = now - self.momentumLastTime;
    self.momentumLastTime = now;
    
    CGFloat decay = pow(kMomentumDecayPerMS, dt * 1000);
    CGPoint velocity = CGPointMake(self.momentumVelocity.x * decay, self.momentumVelocity.y * decay);
    self.momentumVelocity = velocity;
    
    if (hypot(velocity.x, velocity.y) < kMomentumStopSpeed) {
        [self cancelMomentumScroll];
        return;
    }
    
    CGPoint delta = CGPointMake(velocity.x * dt, velocity.y * dt);
    CGMomentumScrollPhase phase = self.momentumStarted ? kCGMomentumScrollPhaseContinue : kCGMomentumScrollPhaseBegin;
    if ([self postScroll:delta scrollPhase:0 momentumPhase:phase]) {
        self.momentumStarted = YES;
    }
}


- (void)cancelMomentumScroll {
    if (self.momentumScrollTimer == nil) {
        return;
    }
    [self.momentumScrollTimer invalidate];
    self.momentumScrollTimer = nil;
    
    if (self.momentumStarted) {
        [self postScroll:CGPointZero scrollPhase:0 momentumPhase:kCGMomentumScrollPhaseEnd];
        self.momentumStarted = NO;
    }
}


- (void)recordScrollSample:(CGPoint)delta {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    [self.scrollSamples addObject:[NSValue valueWithPoint:NSPointFromCGPoint(delta)]];
    [self.scrollSampleTimes addObject:@(now)];
    
    while (self.scrollSampleTimes.count > 0 && now - self.scrollSampleTimes.firstObject.doubleValue > kVelocityWindow) {
        [self.scrollSamples removeObjectAtIndex:0];
        [self.scrollSampleTimes removeObjectAtIndex:0];
    }
}


- (CGPoint)releaseVelocity {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (self.scrollSampleTimes.count < 2 || now - self.scrollSampleTimes.lastObject.doubleValue > kVelocityMaxPause) {
        return CGPointZero;
    }
    
    // the first sample only marks when the window starts, its movement happened before
    CGPoint sum = CGPointZero;
    for (NSUInteger i = 1; i < self.scrollSamples.count; i++) {
        NSPoint d = self.scrollSamples[i].pointValue;
        sum.x += d.x;
        sum.y += d.y;
    }
    CFTimeInterval span = MAX(now - self.scrollSampleTimes.firstObject.doubleValue, kMomentumTickInterval);
    return CGPointMake(sum.x / span, sum.y / span);
}


/**
 Returns NO when the delta was too small to post and was carried over to the next call.
 */
- (BOOL)postScroll:(CGPoint)delta scrollPhase:(CGScrollPhase)scrollPhase momentumPhase:(CGMomentumScrollPhase)momentumPhase {
    CGPoint total = CGPointMake(delta.x + self.scrollRemainder.x, delta.y + self.scrollRemainder.y);
    int32_t dx = (int32_t)trunc(total.x);
    int32_t dy = (int32_t)trunc(total.y);
    
    BOOL carriesMovement = scrollPhase == kCGScrollPhaseBegan || scrollPhase == kCGScrollPhaseChanged
                        || momentumPhase == kCGMomentumScrollPhaseBegin || momentumPhase == kCGMomentumScrollPhaseContinue;
    if (carriesMovement && dx == 0 && dy == 0) {
        // real trackpads never send moving phases without movement; apps treat that as a stop
        self.scrollRemainder = total;
        return NO;
    }
    self.scrollRemainder = carriesMovement ? CGPointMake(total.x - dx, total.y - dy) : CGPointZero;
    
    CGEventRef scroll = CGEventCreateScrollWheelEvent2(NULL, kCGScrollEventUnitPixel, 2, dy, dx, 0);
    CGEventSetIntegerValueField(scroll, kCGScrollWheelEventIsContinuous, 1);
    CGEventSetIntegerValueField(scroll, kCGScrollWheelEventScrollPhase, scrollPhase);
    CGEventSetIntegerValueField(scroll, kCGScrollWheelEventMomentumPhase, momentumPhase);
    // content follows the fingers, which is what natural scrolling means for a trackpad
    CGEventSetIntegerValueField(scroll, kTUCScrollInvertedField, 1);
    CGEventPost(kCGHIDEventTap, scroll);
    CFRelease(scroll);
    
    if (scrollPhase != 0) {
        // the accompanying gesture event is what apps track to swipe between pages
        CGEventRef gesture = CGEventCreate(NULL);
        CGEventSetIntegerValueField(gesture, kTUCEventTypeField, kTUCEventTypeGesture);
        CGEventSetIntegerValueField(gesture, kTUCGestureSubtypeField, kTUCGestureSubtypeScroll);
        CGEventSetDoubleValueField(gesture, kTUCGestureScrollXField, dx * kGestureScrollScale);
        CGEventSetDoubleValueField(gesture, kTUCGestureScrollYField, dy * kGestureScrollScale);
        CGEventSetIntegerValueField(gesture, kTUCGesturePhaseField, scrollPhase);
        CGEventPost(kCGHIDEventTap, gesture);
        CFRelease(gesture);
    }
    
    return YES;
}


#pragma mark - Magnify, Rotate, Smart Zoom

- (CGEventRef)newGestureEventWithSubtype:(int64_t)subtype phase:(CGGesturePhase)phase CF_RETURNS_RETAINED {
    // start with a mouse event, as it carries a valid timestamp and the cursor location the gesture targets
    CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, [self currentCursorLocation], kCGMouseButtonLeft);
    CGEventSetType(event, (CGEventType)kTUCEventTypeGesture);
    CGEventSetFlags(event, 0);
    CGEventSetIntegerValueField(event, 50, 248);
    CGEventSetIntegerValueField(event, 101, 4);
    CGEventSetIntegerValueField(event, kTUCGestureSubtypeField, subtype);
    CGEventSetIntegerValueField(event, kTUCGesturePhaseField, phase);
    return event;
}


- (void)postGestureWithSubtype:(int64_t)subtype field:(CGEventField)field value:(double)value phase:(CGGesturePhase)phase {
    CGEventRef event = [self newGestureEventWithSubtype:subtype phase:phase];
    CGEventSetDoubleValueField(event, field, value);
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}


- (void)magnifyBy:(CGFloat)magnification {
    [self stopDraggingCursor];
    
    if (!self.isMagnifying) {
        self.isMagnifying = YES;
        [self postGestureWithSubtype:kTUCGestureSubtypeZoom field:kTUCMagnificationField value:0 phase:kCGGesturePhaseBegan];
    }
    if (magnification != 0) {
        [self postGestureWithSubtype:kTUCGestureSubtypeZoom field:kTUCMagnificationField value:magnification phase:kCGGesturePhaseChanged];
    }
}


- (void)rotateBy:(CGFloat)degrees {
    [self stopDraggingCursor];
    
    if (!self.isRotating) {
        self.isRotating = YES;
        [self postGestureWithSubtype:kTUCGestureSubtypeRotation field:kTUCRotationField value:0 phase:kCGGesturePhaseBegan];
    }
    if (degrees != 0) {
        [self postGestureWithSubtype:kTUCGestureSubtypeRotation field:kTUCRotationField value:degrees phase:kCGGesturePhaseChanged];
    }
}


- (void)stopMagnifying {
    if (self.isMagnifying) {
        self.isMagnifying = NO;
        [self postGestureWithSubtype:kTUCGestureSubtypeZoom field:kTUCMagnificationField value:0 phase:kCGGesturePhaseEnded];
    }
    if (self.isRotating) {
        self.isRotating = NO;
        [self postGestureWithSubtype:kTUCGestureSubtypeRotation field:kTUCRotationField value:0 phase:kCGGesturePhaseEnded];
    }
}


- (void)smartMagnify {
    CGEventRef event = [self newGestureEventWithSubtype:kTUCGestureSubtypeZoomToggle phase:kCGGesturePhaseNone];
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}


#pragma mark - Dock Swipes

- (BOOL)isDockSwiping {
    return self.dockSwiping;
}


- (void)dockSwipe:(TUCDockSwipeMotion)motion by:(double)delta {
    [self stopDraggingCursor];
    
    if (!self.dockSwiping) {
        [self cancelDockSwipeEndResends];
        self.dockSwiping = YES;
        self.dockSwipeMotion = motion;
        self.dockSwipeOffset = delta;
        self.dockSwipeLastDelta = delta;
        [self postDockSwipePhase:kCGGesturePhaseBegan exitSpeed:0];
        return;
    }
    
    if (delta == 0) {
        return;
    }
    self.dockSwipeOffset += delta;
    self.dockSwipeLastDelta = delta;
    [self postDockSwipePhase:kCGGesturePhaseChanged exitSpeed:0];
}


- (void)endDockSwipe {
    if (!self.dockSwiping) {
        return;
    }
    self.dockSwiping = NO;
    
    // like a trackpad: the transition completes if the fingers were still moving towards it when they lifted
    BOOL completes = (self.dockSwipeLastDelta > 0) == (self.dockSwipeOffset > 0);
    NSArray *events = [self postDockSwipePhase:completes ? kCGGesturePhaseEnded : kCGGesturePhaseCancelled
                                     exitSpeed:self.dockSwipeLastDelta * 100];
    
    // under load the Dock sometimes drops the end event and the transition gets stuck halfway, so repeat it
    NSMutableArray<NSTimer *> *timers = [NSMutableArray array];
    for (NSNumber *delay in @[@0.2, @0.5]) {
        [timers addObject:[NSTimer scheduledTimerWithTimeInterval:delay.doubleValue repeats:NO block:^(NSTimer *timer) {
            for (id event in events) {
                CGEventPost(kCGSessionEventTap, (__bridge CGEventRef)event);
            }
        }]];
    }
    self.dockSwipeEndResendTimers = timers;
}


- (void)cancelDockSwipeEndResends {
    for (NSTimer *timer in self.dockSwipeEndResendTimers) {
        [timer invalidate];
    }
    self.dockSwipeEndResendTimers = nil;
}


/**
 A dock swipe is a pair of events: a type 30 event carrying the swipe and an accompanying type 29 gesture event.
 This is the pre-macOS 27 format; macOS 27 reads the swipe from an attached IOHIDEvent instead.
 Returns the posted events so they can be sent again.
 */
- (NSArray *)postDockSwipePhase:(CGGesturePhase)phase exitSpeed:(double)exitSpeed {
    const double unknownField41 = 33231;   // present in real dock swipes
    
    CGEventRef swipe = CGEventCreate(NULL);
    CGEventSetDoubleValueField(swipe, kTUCEventTypeField, kTUCEventTypeDockSwipe);
    CGEventSetDoubleValueField(swipe, kTUCGestureSubtypeField, kTUCGestureSubtypeDockSwipe);
    CGEventSetDoubleValueField(swipe, kTUCGesturePhaseField, phase);
    CGEventSetDoubleValueField(swipe, 134, phase);
    CGEventSetDoubleValueField(swipe, 41, unknownField41);
    
    // the progress is stored twice: as a double, and as the raw bits of a 32 bit float
    CGEventSetDoubleValueField(swipe, 124, self.dockSwipeOffset);
    Float32 offset32 = (Float32)self.dockSwipeOffset;
    uint32_t offsetBits;
    memcpy(&offsetBits, &offset32, sizeof(offsetBits));
    CGEventSetIntegerValueField(swipe, 135, (int64_t)offsetBits);
    
    // the motion is stored as a plain number and as the raw bits of an integer read as a float
    uint32_t motionInt = (uint32_t)self.dockSwipeMotion;
    Float32 motionBits;
    memcpy(&motionBits, &motionInt, sizeof(motionBits));
    CGEventSetDoubleValueField(swipe, 119, motionBits);
    CGEventSetDoubleValueField(swipe, 139, motionBits);
    CGEventSetDoubleValueField(swipe, 123, self.dockSwipeMotion);
    CGEventSetDoubleValueField(swipe, 165, self.dockSwipeMotion);
    
    // natural direction: the Spaces follow the fingers
    CGEventSetIntegerValueField(swipe, 136, 1);
    
    if (phase == kCGGesturePhaseEnded || phase == kCGGesturePhaseCancelled) {
        CGEventSetDoubleValueField(swipe, 129, exitSpeed);
        CGEventSetDoubleValueField(swipe, 130, exitSpeed);
    }
    
    CGEventRef gesture = CGEventCreate(NULL);
    CGEventSetDoubleValueField(gesture, kTUCEventTypeField, kTUCEventTypeGesture);
    CGEventSetDoubleValueField(gesture, 41, unknownField41);
    
    CGEventPost(kCGSessionEventTap, swipe);
    CGEventPost(kCGSessionEventTap, gesture);
    
    NSArray *events = @[(__bridge id)swipe, (__bridge id)gesture];
    CFRelease(swipe);
    CFRelease(gesture);
    return events;
}


#pragma mark - Keys

- (void)postKey:(CGKeyCode)key flags:(CGEventFlags)flags {
    for (int isKeyDown = 1; isKeyDown >= 0; isKeyDown--) {
        CGEventRef event = CGEventCreateKeyboardEvent(NULL, key, isKeyDown);
        CGEventSetFlags(event, flags);
        CGEventPost(kCGHIDEventTap, event);
        CFRelease(event);
    }
}


// Private WindowServer functions that read and write the symbolic hot key table.
typedef CGError (*TUCGetSymbolicHotKeyValueFn)(int hotKey, unichar *keyEquivalent, unichar *virtualKeyCode, uint32_t *modifiers);
typedef bool    (*TUCIsSymbolicHotKeyEnabledFn)(int hotKey);
typedef CGError (*TUCSetSymbolicHotKeyEnabledFn)(int hotKey, bool enabled);
typedef CGError (*TUCSetSymbolicHotKeyValueFn)(int hotKey, unichar keyEquivalent, unichar virtualKeyCode, uint32_t modifiers);

- (void)triggerSymbolicHotKey:(TUCSymbolicHotKey)hotKey {
    TUCGetSymbolicHotKeyValueFn getValue = dlsym(RTLD_DEFAULT, "CGSGetSymbolicHotKeyValue");
    TUCIsSymbolicHotKeyEnabledFn isEnabled = dlsym(RTLD_DEFAULT, "CGSIsSymbolicHotKeyEnabled");
    TUCSetSymbolicHotKeyEnabledFn setEnabled = dlsym(RTLD_DEFAULT, "CGSSetSymbolicHotKeyEnabled");
    TUCSetSymbolicHotKeyValueFn setValue = dlsym(RTLD_DEFAULT, "CGSSetSymbolicHotKeyValue");
    if (!getValue || !isEnabled || !setEnabled || !setValue) {
        return;
    }

    const unichar noKey = 0xFFFF;
    unichar keyEquivalent = noKey;
    unichar keyCode = noKey;
    uint32_t modifiers = 0;
    getValue(hotKey, &keyEquivalent, &keyCode, &modifiers);

    if (!isEnabled(hotKey) || keyCode == noKey) {
        // A key code no keyboard produces, so the binding never collides with the user's shortcuts.
        // It stays in place: restoring it right after posting races with the WindowServer.
        keyCode = (unichar)(400 + hotKey);
        modifiers = kCGEventFlagMaskNumericPad | kCGEventFlagMaskSecondaryFn;
        setEnabled(hotKey, true);
        setValue(hotKey, noKey, keyCode, modifiers);
    }

    CGEventRef keyDown = CGEventCreateKeyboardEvent(NULL, keyCode, true);
    CGEventRef keyUp = CGEventCreateKeyboardEvent(NULL, keyCode, false);
    CGEventSetFlags(keyDown, (CGEventFlags)modifiers);
    CGEventSetFlags(keyUp, 0);
    CGEventPost(kCGSessionEventTap, keyDown);
    CGEventPost(kCGSessionEventTap, keyUp);
    CFRelease(keyDown);
    CFRelease(keyUp);
}

@end
