/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software
 * Foundation, version 2. OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details. You should have received a copy of the GNU General
 * Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.
 */

/** @file ios_application.mm UIKit scene shell and Metal framebuffer presentation. */

#import <UIKit/UIKit.h>
#import <MetalKit/MetalKit.h>
#include "ios_bridge.h"
#include <atomic>
#include <algorithm>
#include <deque>
#include <mutex>
#include <thread>
#include <vector>
namespace
{
std::mutex event_mutex, frame_mutex, surface_mutex, construction_mutex;
struct ConstructionTouch
{
	bool active = false;
	int x = 0;
	int y = 0;
};
ConstructionTouch construction_touch;
std::deque<IOSEvent> events;
std::vector<uint32_t> frame;
int frame_width = 0, frame_height = 0;
uint64_t generation = 0;
int surface_width = 640, surface_height = 480;
std::atomic<bool> active{false};
std::atomic<uint64_t> background_save_request{0};
// These two lifecycle fields are confined to the UIKit main thread.
UIBackgroundTaskIdentifier background_task = UIBackgroundTaskInvalid;
uint64_t background_generation = 0;
std::once_flag engine_once;
CGPoint MapPoint(CGPoint point, CGSize bounds)
{
	int w, h;
	{
		std::lock_guard<std::mutex> lock(frame_mutex);
		w = frame_width;
		h = frame_height;
	}
	if (w <= 0 || h <= 0)
		IOSGetSurfaceSize(w, h);
	double scale = std::min(bounds.width / w, bounds.height / h);
	if (scale <= 0)
		return CGPointZero;
	return CGPointMake(std::clamp(int((point.x - (bounds.width - w * scale) / 2) / scale), 0, w - 1),
					   std::clamp(int((point.y - (bounds.height - h * scale) / 2) / scale), 0, h - 1));
}
void Queue(IOSEvent event)
{
	std::lock_guard<std::mutex> lock(event_mutex);
	if ((event.type == IOSEventType::PointerMove || event.type == IOSEventType::HardwarePointerMove) && !events.empty() && events.back().type == event.type)
		events.back() = std::move(event);
	else
		events.push_back(std::move(event));
}
} // namespace
bool IOSPollEvent(IOSEvent &event)
{
	std::lock_guard<std::mutex> lock(event_mutex);
	if (events.empty())
		return false;
	event = std::move(events.front());
	events.pop_front();
	return true;
}
void IOSPublishFrame(const uint32_t *pixels, int width, int height, int pitchPixels)
{
	if (!pixels || width <= 0 || height <= 0 || pitchPixels < width)
		return;
	std::lock_guard<std::mutex> lock(frame_mutex);
	frame.resize(size_t(width) * height);
	for (int y = 0; y < height; ++y)
		std::copy_n(pixels + size_t(y) * pitchPixels, width, frame.data() + size_t(y) * width);
	frame_width = width;
	frame_height = height;
	++generation;
}
void IOSGetSurfaceSize(int &width, int &height)
{
	std::lock_guard<std::mutex> lock(surface_mutex);
	width = surface_width;
	height = surface_height;
}
bool IOSIsActive()
{
	return active.load(std::memory_order_relaxed);
}
uint64_t IOSConsumeBackgroundSaveRequest()
{
	return background_save_request.exchange(0);
}
void IOSCompleteBackgroundSave(uint64_t ticket, bool saved)
{
	dispatch_async(dispatch_get_main_queue(), ^{
	  NSLog(@"OpenTTD background save %@ (request %llu)", saved ? @"completed" : @"skipped or failed", static_cast<unsigned long long>(ticket));
	  if (ticket == background_generation && background_task != UIBackgroundTaskInvalid)
	  {
		  [UIApplication.sharedApplication endBackgroundTask:background_task];
		  background_task = UIBackgroundTaskInvalid;
	  }
	});
}
void IOSSetConstructionTouch(bool enabled, int x, int y)
{
	std::lock_guard<std::mutex> lock(construction_mutex);
	construction_touch = {enabled, x, y};
}
static ConstructionTouch ConstructionSnapshot()
{
	std::lock_guard<std::mutex> lock(construction_mutex);
	return construction_touch;
}
@interface IOSPrecisionLoupe : UIView
@property(nonatomic, strong) UIImage *image;
@end
@implementation IOSPrecisionLoupe
- (void)drawRect:(CGRect)rect
{
	CGContextRef context = UIGraphicsGetCurrentContext();
	UIBezierPath *outline = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(self.bounds, 1, 1) cornerRadius:12];
	CGContextSaveGState(context);
	[outline addClip];
	CGContextSetInterpolationQuality(context, kCGInterpolationNone);
	[self.image drawInRect:self.bounds];
	CGFloat x = CGRectGetMidX(self.bounds), y = CGRectGetMidY(self.bounds);
	UIBezierPath *crosshair = [UIBezierPath bezierPath];
	[crosshair moveToPoint:CGPointMake(x - 12, y)];
	[crosshair addLineToPoint:CGPointMake(x - 4, y)];
	[crosshair moveToPoint:CGPointMake(x + 4, y)];
	[crosshair addLineToPoint:CGPointMake(x + 12, y)];
	[crosshair moveToPoint:CGPointMake(x, y - 12)];
	[crosshair addLineToPoint:CGPointMake(x, y - 4)];
	[crosshair moveToPoint:CGPointMake(x, y + 4)];
	[crosshair addLineToPoint:CGPointMake(x, y + 12)];
	[[UIColor colorWithWhite:0 alpha:0.8] setStroke];
	crosshair.lineWidth = 3;
	[crosshair stroke];
	[[UIColor colorWithWhite:1 alpha:0.9] setStroke];
	crosshair.lineWidth = 1;
	[crosshair stroke];
	CGContextRestoreGState(context);
	[[UIColor colorWithWhite:1 alpha:0.85] setStroke];
	outline.lineWidth = 1.5;
	[outline stroke];
}
@end
static uint32_t HardwareModifiers(UIKeyModifierFlags flags)
{
	return ((flags & UIKeyModifierShift) ? IOSShift : 0) | ((flags & UIKeyModifierControl) ? IOSControl : 0) |
		   ((flags & UIKeyModifierAlternate) ? IOSAlternate : 0) | ((flags & UIKeyModifierCommand) ? IOSCommand : 0);
}
// Return only presses UIKit must still process as committed text. Intercepting
// printable text in both this adapter and UITextField would insert it twice.
static NSSet<UIPress *> *QueueHardwarePresses(NSSet<UIPress *> *presses, UIPressesEvent *event, bool down, bool textEditing)
{
	NSMutableSet<UIPress *> *nativeText = [NSMutableSet set];
	IOSEvent modifiers{IOSEventType::HardwareModifiers};
	modifiers.modifiers = HardwareModifiers(event.modifierFlags);
	Queue(modifiers);
	for (UIPress *press in presses)
	{
		UIKey *key = press.key;
		if (!key)
		{
			[nativeText addObject:press];
			continue;
		}
		bool printable = key.characters.length != 0 && key.keyCode != UIKeyboardHIDUsageKeyboardReturnOrEnter &&
						 key.keyCode != UIKeyboardHIDUsageKeyboardDeleteOrBackspace && key.keyCode != UIKeyboardHIDUsageKeyboardEscape &&
						 key.keyCode != UIKeyboardHIDUsageKeyboardTab &&
						 !(key.keyCode >= UIKeyboardHIDUsageKeyboardF1 && key.keyCode <= UIKeyboardHIDUsageKeyboardUpArrow);
		if (textEditing && printable && !(key.modifierFlags & (UIKeyModifierControl | UIKeyModifierCommand)))
		{
			[nativeText addObject:press];
			continue;
		}
		IOSEvent input{down ? IOSEventType::HardwareKeyDown : IOSEventType::HardwareKeyUp, 0, 0, int(key.keyCode)};
		input.modifiers = HardwareModifiers(event.modifierFlags);
		input.text = std::string(key.charactersIgnoringModifiers.UTF8String ?: "");
		Queue(std::move(input));
	}
	return nativeText;
}
@interface IOSInputField : UITextField
@end
@implementation IOSInputField
- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event
{
	NSSet *remaining = QueueHardwarePresses(presses, event, true, true);
	if (remaining.count)
		[super pressesBegan:remaining withEvent:event];
}
- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event
{
	NSSet *remaining = QueueHardwarePresses(presses, event, false, true);
	if (remaining.count)
		[super pressesEnded:remaining withEvent:event];
}
- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event
{
	Queue({IOSEventType::HardwareReset});
	[super pressesCancelled:presses withEvent:event];
}
@end
@interface IOSGameView : MTKView <UIPointerInteractionDelegate>
@property(nonatomic) BOOL leftPressed;
@property(nonatomic) BOOL multiTouch;
@property(nonatomic) NSUInteger pointerButtons;
@property(nonatomic, strong) NSMutableSet<UITouch *> *trackedTouches;
@property(nonatomic) CGPoint previousCenter;
@property(nonatomic) CGFloat pinchReference;
- (void)cancelTouches;
@end
@implementation IOSGameView
- (BOOL)canBecomeFirstResponder
{
	return YES;
}
- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event
{
	NSSet *remaining = QueueHardwarePresses(presses, event, true, false);
	if (remaining.count)
		[super pressesBegan:remaining withEvent:event];
}
- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event
{
	NSSet *remaining = QueueHardwarePresses(presses, event, false, false);
	if (remaining.count)
		[super pressesEnded:remaining withEvent:event];
}
- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event
{
	Queue({IOSEventType::HardwareReset});
	[super pressesCancelled:presses withEvent:event];
}
- (UIPointerRegion *)pointerInteraction:(UIPointerInteraction *)interaction
					   regionForRequest:(UIPointerRegionRequest *)request
						  defaultRegion:(UIPointerRegion *)defaultRegion
{
	return defaultRegion;
}
- (void)pointerHover:(UIHoverGestureRecognizer *)gesture
{
	CGPoint p = MapPoint([gesture locationInView:self], self.bounds.size);
	IOSEvent input{gesture.state == UIGestureRecognizerStateEnded ? IOSEventType::HardwarePointerLeave : IOSEventType::HardwarePointerMove, int(p.x), int(p.y)};
	input.modifiers = HardwareModifiers(gesture.modifierFlags);
	Queue(std::move(input));
}
- (void)pointerScroll:(UIPanGestureRecognizer *)gesture
{
	CGPoint p = MapPoint([gesture locationInView:self], self.bounds.size);
	CGPoint delta = [gesture translationInView:self];
	[gesture setTranslation:CGPointZero inView:self];
	IOSEvent input{IOSEventType::HardwareScroll, int(p.x), int(p.y)};
	input.dx = int(delta.x);
	input.dy = int(delta.y);
	input.modifiers = HardwareModifiers(gesture.modifierFlags);
	Queue(std::move(input));
}
- (BOOL)sendPointerTouches:(NSSet<UITouch *> *)touches event:(UIEvent *)event ending:(BOOL)ending
{
	UITouch *pointer = nil;
	for (UITouch *touch in touches)
		if (touch.type == UITouchTypeIndirectPointer)
		{
			pointer = touch;
			break;
		}
	if (!pointer)
		return NO;
	CGPoint p = MapPoint([pointer locationInView:self], self.bounds.size);
	NSUInteger buttons = event.buttonMask & (UIEventButtonMaskPrimary | UIEventButtonMaskSecondary);
	IOSEvent input{buttons != self.pointerButtons || ending ? IOSEventType::HardwarePointerButtons : IOSEventType::HardwarePointerMove, int(p.x), int(p.y),
				   int(buttons)};
	input.modifiers = HardwareModifiers(event.modifierFlags);
	Queue(std::move(input));
	self.pointerButtons = buttons;
	return YES;
}
- (void)sendTouch:(UITouch *)touch type:(IOSEventType)type
{
	CGPoint p = MapPoint([touch locationInView:self], self.bounds.size);
	Queue({type, int(p.x), int(p.y)});
}
- (void)cancelTouches
{
	Queue({IOSEventType::TouchCancel});
	Queue({IOSEventType::HardwareReset});
	self.pointerButtons = 0;
	[self.trackedTouches removeAllObjects];
	self.leftPressed = NO;
	self.multiTouch = NO;
}
- (void)updateMultipleTouches:(BOOL)begin
{
	NSArray<UITouch *> *touches = self.trackedTouches.allObjects;
	if (touches.count < 2)
		return;
	CGPoint a = [touches[0] locationInView:self], b = [touches[1] locationInView:self];
	CGPoint center = MapPoint(CGPointMake((a.x + b.x) / 2, (a.y + b.y) / 2), self.bounds.size);
	CGFloat distance = hypot(a.x - b.x, a.y - b.y);
	if (begin)
	{
		Queue({IOSEventType::MultiBegin, int(center.x), int(center.y)});
		self.pinchReference = MAX(distance, 1);
	}
	else
	{
		IOSEvent move{IOSEventType::MultiMove, int(center.x), int(center.y)};
		move.dx = int(self.previousCenter.x - center.x);
		move.dy = int(self.previousCenter.y - center.y);
		Queue(std::move(move));
		if (distance / self.pinchReference > 1.3 || distance / self.pinchReference < 1 / 1.3)
		{
			Queue({IOSEventType::Zoom, int(center.x), int(center.y), distance > self.pinchReference ? 1 : -1});
			self.pinchReference = MAX(distance, 1);
		}
	}
	self.previousCenter = center;
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
	if ([self sendPointerTouches:touches event:event ending:NO])
		return;
	if (!self.trackedTouches)
		self.trackedTouches = [NSMutableSet set];
	[self.trackedTouches unionSet:touches];
	if (self.trackedTouches.count >= 2)
	{
		self.multiTouch = YES;
		self.leftPressed = NO;
		[self updateMultipleTouches:YES];
	}
	else if (!self.multiTouch)
	{
		self.leftPressed = YES;
		[self sendTouch:touches.anyObject type:IOSEventType::TouchBegin];
	}
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
	if ([self sendPointerTouches:touches event:event ending:NO])
		return;
	if (self.multiTouch)
		[self updateMultipleTouches:NO];
	else if (self.leftPressed)
		[self sendTouch:touches.anyObject type:IOSEventType::TouchMove];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
	if ([self sendPointerTouches:touches event:event ending:YES])
		return;
	if (!self.multiTouch && self.leftPressed)
		[self sendTouch:touches.anyObject type:IOSEventType::TouchEnd];
	[self.trackedTouches minusSet:touches];
	self.leftPressed = NO;
	if (self.trackedTouches.count == 0)
	{
		if (self.multiTouch)
			Queue({IOSEventType::MultiEnd});
		self.multiTouch = NO;
	}
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
	[self cancelTouches];
}
@end
@interface IOSGameController : UIViewController <MTKViewDelegate, UITextFieldDelegate, UIGestureRecognizerDelegate>
@property(nonatomic, strong) IOSGameView *gameView;
@property(nonatomic, strong) IOSPrecisionLoupe *loupe;
@property(nonatomic, strong) UIButton *keyboardButton;
@property(nonatomic, strong) NSLayoutConstraint *gameBottomConstraint;
@property(nonatomic) BOOL textInputRequested;
@property(nonatomic, strong) UITextField *inputField;
@property(nonatomic, strong) id<MTLCommandQueue> commands;
@property(nonatomic, strong) id<MTLRenderPipelineState> pipeline;
@property(nonatomic, strong) id<MTLTexture> texture;
@property(nonatomic) uint64_t displayedGeneration;
@end
static __weak IOSGameController *game_controller;
void IOSRequestTextInput(bool enabled)
{
	dispatch_async(dispatch_get_main_queue(), ^{
	  game_controller.textInputRequested = enabled;
	  [game_controller.view setNeedsLayout];
	  if (enabled)
		  [game_controller.inputField becomeFirstResponder];
	  else
	  {
		  [game_controller.inputField resignFirstResponder];
		  [game_controller.gameView becomeFirstResponder];
	  }
	});
}
@implementation IOSGameController
- (void)loadView
{
	self.view = [[UIView alloc] init];
	self.view.backgroundColor = UIColor.blackColor;
	id<MTLDevice> device = MTLCreateSystemDefaultDevice();
	NSAssert(device, @"Metal is required");
	self.gameView = [[IOSGameView alloc] initWithFrame:CGRectZero device:device];
	self.gameView.translatesAutoresizingMaskIntoConstraints = NO;
	self.gameView.multipleTouchEnabled = YES;
	self.gameView.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
	self.gameView.clearColor = MTLClearColorMake(0, 0, 0, 1);
	self.gameView.preferredFramesPerSecond = 60;
	self.gameView.delegate = self;
	[self.view addSubview:self.gameView];
	UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
	if (@available(iOS 26.0, *))
	{
		if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad)
		{
			safe =
				[self.view layoutGuideForLayoutRegion:[UIViewLayoutRegion safeAreaLayoutRegionWithCornerAdaptation:UIViewLayoutRegionAdaptivityAxisVertical]];
		}
	}
	[NSLayoutConstraint activateConstraints:@[
		[self.gameView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor], [self.gameView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
		[self.gameView.topAnchor constraintEqualToAnchor:safe.topAnchor constant:UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad ? 44 : 0],
		(self.gameBottomConstraint = [self.gameView.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor])
	]];
	self.keyboardButton = [UIButton buttonWithType:UIButtonTypeSystem];
	self.keyboardButton.translatesAutoresizingMaskIntoConstraints = NO;
	[self.keyboardButton setImage:[UIImage systemImageNamed:@"keyboard"] forState:UIControlStateNormal];
	self.keyboardButton.tintColor = UIColor.whiteColor;
	self.keyboardButton.accessibilityLabel = @"Show keyboard";
	self.keyboardButton.hidden = YES;
	[self.keyboardButton addTarget:self action:@selector(showKeyboard) forControlEvents:UIControlEventTouchUpInside];
	[self.view addSubview:self.keyboardButton];
	[NSLayoutConstraint activateConstraints:@[
		[self.keyboardButton.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
		[self.keyboardButton.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
		[self.keyboardButton.widthAnchor constraintEqualToConstant:44], [self.keyboardButton.heightAnchor constraintEqualToConstant:44]
	]];
	self.commands = [device newCommandQueue];
	NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
						"struct V { float4 p [[position]]; float2 uv; };\n"
						"vertex V vertex_main(uint i [[vertex_id]]) { const float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)}; V o; o.p=float4(p[i],0,1); "
						"o.uv=float2((p[i].x+1)*0.5,(1-p[i].y)*0.5); return o; }\n"
						"fragment float4 fragment_main(V v [[stage_in]], texture2d<float> t [[texture(0)]]) { constexpr sampler "
						"s(coord::normalized,address::clamp_to_edge,filter::nearest); return float4(t.sample(s,v.uv).rgb,1); }\n";
	NSError *error = nil;
	id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
	if (!library)
		NSLog(@"OpenTTD Metal shader error: %@", error);
	MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
	desc.vertexFunction = [library newFunctionWithName:@"vertex_main"];
	desc.fragmentFunction = [library newFunctionWithName:@"fragment_main"];
	desc.colorAttachments[0].pixelFormat = self.gameView.colorPixelFormat;
	self.pipeline = [device newRenderPipelineStateWithDescriptor:desc error:&error];
	if (!self.pipeline)
		NSLog(@"OpenTTD Metal pipeline error: %@", error);
	self.inputField = [[IOSInputField alloc] initWithFrame:CGRectMake(-10, -10, 1, 1)];
	self.inputField.delegate = self;
	self.inputField.autocorrectionType = UITextAutocorrectionTypeNo;
	self.inputField.autocapitalizationType = UITextAutocapitalizationTypeNone;
	self.inputField.text = @" ";
	[self.view addSubview:self.inputField];
	UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(rightPress:)];
	longPress.allowedTouchTypes = @[ @(UITouchTypeDirect) ];
	[self.gameView addGestureRecognizer:longPress];
	UIHoverGestureRecognizer *hover = [[UIHoverGestureRecognizer alloc] initWithTarget:self.gameView action:@selector(pointerHover:)];
	hover.allowedTouchTypes = @[ @(UITouchTypeIndirectPointer) ];
	hover.cancelsTouchesInView = NO;
	[self.gameView addGestureRecognizer:hover];
	UIPanGestureRecognizer *scroll = [[UIPanGestureRecognizer alloc] initWithTarget:self.gameView action:@selector(pointerScroll:)];
	scroll.allowedScrollTypesMask = UIScrollTypeMaskAll;
	scroll.allowedTouchTypes = @[];
	scroll.cancelsTouchesInView = NO;
	[self.gameView addGestureRecognizer:scroll];
	[self.gameView addInteraction:[[UIPointerInteraction alloc] initWithDelegate:self.gameView]];
	self.loupe = [[IOSPrecisionLoupe alloc] initWithFrame:CGRectMake(0, 0, 147, 99)];
	self.loupe.opaque = NO;
	self.loupe.userInteractionEnabled = NO;
	self.loupe.hidden = YES;
	self.loupe.layer.shadowColor = UIColor.blackColor.CGColor;
	self.loupe.layer.shadowOpacity = 0.4;
	self.loupe.layer.shadowRadius = 5;
	self.loupe.layer.shadowOffset = CGSizeMake(0, 3);
	[self.gameView addSubview:self.loupe];
	game_controller = self;
	NSLog(@"OpenTTD UIKit scene and Metal framebuffer initialized");
}
- (void)showKeyboard
{
	if (!self.textInputRequested)
		return;
	[self.inputField resignFirstResponder];
	dispatch_async(dispatch_get_main_queue(), ^{
	  if (self.textInputRequested)
	  {
		  [self.inputField becomeFirstResponder];
		  [self.inputField reloadInputViews];
	  }
	});
}
- (void)updateKeyboardAffordance
{
	CGRect safe = self.view.safeAreaLayoutGuide.layoutFrame;
	BOOL keyboardVisible = self.view.keyboardLayoutGuide.layoutFrame.origin.y < CGRectGetMaxY(safe) - 40;
	BOOL show = self.textInputRequested && !keyboardVisible;
	self.keyboardButton.hidden = !show;
	// Reserve the button's own strip only while the keyboard is hidden, so its
	// 44-point target never covers an engine widget or wastes keyboard-open space.
	CGFloat inset = show ? -44 : 0;
	if (self.gameBottomConstraint.constant != inset)
	{
		self.gameBottomConstraint.constant = inset;
		[self.view layoutIfNeeded];
	}
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture
{
	// The long press must not turn an active precision placement into right-click.
	return !ConstructionSnapshot().active;
}
- (void)didReceiveMemoryWarning
{
	[super didReceiveMemoryWarning];
	self.texture = nil;
	self.loupe.image = nil;
	self.loupe.hidden = YES;
	std::lock_guard<std::mutex> lock(frame_mutex);
	std::vector<uint32_t>().swap(frame);
	++generation;
	// Preserve dimensions for coordinate mapping. Engine framebuffer/state survives.
}
- (void)updatePrecisionLoupe
{
	ConstructionTouch target = ConstructionSnapshot();
	if (UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPhone || !target.active)
	{
		self.loupe.hidden = YES;
		return;
	}
	constexpr int crop_width = 49, crop_height = 33;
	std::vector<uint32_t> crop(crop_width * crop_height);
	int width, height;
	{
		std::lock_guard<std::mutex> lock(frame_mutex);
		if (frame.empty())
		{
			self.loupe.hidden = YES;
			return;
		}
		width = frame_width;
		height = frame_height;
		for (int y = 0; y < crop_height; ++y)
			for (int x = 0; x < crop_width; ++x)
			{
				int sx = std::clamp(target.x + x - crop_width / 2, 0, width - 1);
				int sy = std::clamp(target.y + y - crop_height / 2, 0, height - 1);
				crop[y * crop_width + x] = frame[size_t(sy) * width + sx];
			}
	}
	NSData *data = [NSData dataWithBytes:crop.data() length:crop.size() * sizeof(uint32_t)];
	CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
	CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
	CGImageRef image =
		CGImageCreate(crop_width, crop_height, 8, 32, crop_width * 4, color,
					  CGBitmapInfo(kCGBitmapByteOrder32Little) | CGBitmapInfo(kCGImageAlphaNoneSkipFirst), provider, nullptr, false, kCGRenderingIntentDefault);
	self.loupe.image = [UIImage imageWithCGImage:image];
	CGImageRelease(image);
	CGColorSpaceRelease(color);
	CGDataProviderRelease(provider);
	CGSize bounds = self.gameView.bounds.size;
	CGFloat scale = MIN(bounds.width / width, bounds.height / height);
	CGPoint point = CGPointMake((bounds.width - width * scale) / 2 + target.x * scale, (bounds.height - height * scale) / 2 + target.y * scale);
	CGFloat loupeWidth = MIN(147, MAX(1, bounds.width - 12)), loupeHeight = MIN(99, MAX(1, bounds.height - 12));
	CGFloat top = point.y - loupeHeight - 28;
	if (top < 6)
		top = point.y + 28;
	top = MAX(6, MIN(top, bounds.height - loupeHeight - 6));
	CGFloat left = MAX(6, MIN(point.x - loupeWidth / 2, bounds.width - loupeWidth - 6));
	self.loupe.frame = CGRectMake(left, top, loupeWidth, loupeHeight);
	self.loupe.hidden = NO;
	[self.loupe setNeedsDisplay];
}
- (void)viewDidAppear:(BOOL)animated
{
	[super viewDidAppear:animated];
	if (!self.inputField.isFirstResponder)
		[self.gameView becomeFirstResponder];
}
- (void)viewDidLayoutSubviews
{
	[super viewDidLayoutSubviews];
	[self updateKeyboardAffordance];
	int w = std::max(1, int(self.gameView.bounds.size.width)), h = std::max(1, int(self.gameView.bounds.size.height));
	if (w <= 1 || h <= 1)
		return;
	{
		std::lock_guard<std::mutex> lock(surface_mutex);
		if (surface_width != w || surface_height != h)
		{
			[self.gameView cancelTouches];
			surface_width = w;
			surface_height = h;
			Queue({IOSEventType::Resize, w, h});
		}
	}
	std::call_once(engine_once,
				   []
				   {
					   std::string resources(NSBundle.mainBundle.resourcePath.UTF8String);
					   std::string documents(
						   [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject.path.UTF8String);
					   std::thread(
						   [resources, documents]
						   {
							   @autoreleasepool
							   {
								   NSLog(@"OpenTTD engine thread starting");
								   IOSRunEngine(resources.c_str(), documents.c_str());
							   }
						   })
						   .detach();
				   });
}
- (void)rightPress:(UILongPressGestureRecognizer *)gesture
{
	CGPoint p = MapPoint([gesture locationInView:self.gameView], self.gameView.bounds.size);
	if (gesture.state == UIGestureRecognizerStateBegan)
	{
		if (self.gameView.leftPressed)
		{
			Queue({IOSEventType::TouchCancel});
			self.gameView.leftPressed = NO;
		}
		Queue({IOSEventType::RightDown, int(p.x), int(p.y)});
	}
	else if (gesture.state == UIGestureRecognizerStateEnded || gesture.state == UIGestureRecognizerStateCancelled)
		Queue({IOSEventType::RightUp, int(p.x), int(p.y)});
}
- (BOOL)textField:(UITextField *)textField shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)string
{
	if (string.length)
		Queue({IOSEventType::Text, 0, 0, 0, std::string(string.UTF8String)});
	else
		Queue({IOSEventType::Key, 0, 0, 8});
	return NO;
}
- (BOOL)textFieldShouldReturn:(UITextField *)textField
{
	Queue({IOSEventType::Key, 0, 0, 13});
	[textField resignFirstResponder];
	[self.gameView becomeFirstResponder];
	return NO;
}
- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size
{
}
- (void)drawInMTKView:(MTKView *)view
{
	if (!IOSIsActive() || !self.pipeline)
		return;
	{
		std::lock_guard<std::mutex> lock(frame_mutex);
		if (generation != self.displayedGeneration && !frame.empty())
		{
			if (!self.texture || self.texture.width != NSUInteger(frame_width) || self.texture.height != NSUInteger(frame_height))
			{
				MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
																								width:frame_width
																							   height:frame_height
																							mipmapped:NO];
				desc.usage = MTLTextureUsageShaderRead;
				desc.storageMode = MTLStorageModeShared;
				self.texture = [view.device newTextureWithDescriptor:desc];
			}
			[self.texture replaceRegion:MTLRegionMake2D(0, 0, frame_width, frame_height)
							mipmapLevel:0
							  withBytes:frame.data()
							bytesPerRow:frame_width * sizeof(uint32_t)];
			if (!self.displayedGeneration)
				NSLog(@"OpenTTD first framebuffer: %d x %d", frame_width, frame_height);
			self.displayedGeneration = generation;
		}
	}
	MTLRenderPassDescriptor *pass = view.currentRenderPassDescriptor;
	id<CAMetalDrawable> drawable = view.currentDrawable;
	if (!self.texture || !pass || !drawable)
		return;
	id<MTLCommandBuffer> buffer = [self.commands commandBuffer];
	id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
	double scale = std::min(view.drawableSize.width / self.texture.width, view.drawableSize.height / self.texture.height);
	double width = self.texture.width * scale, height = self.texture.height * scale;
	[encoder setViewport:MTLViewport{(view.drawableSize.width - width) / 2, (view.drawableSize.height - height) / 2, width, height, 0, 1}];
	[encoder setRenderPipelineState:self.pipeline];
	[encoder setFragmentTexture:self.texture atIndex:0];
	[encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
	[encoder endEncoding];
	[buffer presentDrawable:drawable];
	[buffer commit];
	// Serialize texture reuse against the GPU reader.
	[buffer waitUntilCompleted];
	[self updatePrecisionLoupe];
}
@end
@interface IOSSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation IOSSceneDelegate
- (UISceneWindowingControlStyle *)preferredWindowingControlStyleForScene:(UIWindowScene *)scene API_AVAILABLE(ios(26.0))
{
	return UISceneWindowingControlStyle.minimalStyle;
}
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options
{
	self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
	self.window.rootViewController = [[IOSGameController alloc] init];
	[self.window makeKeyAndVisible];
}
- (void)sceneDidBecomeActive:(UIScene *)scene
{
	active.store(true);
}
- (void)sceneDidEnterBackground:(UIScene *)scene
{
	if (background_task != UIBackgroundTaskInvalid)
		[UIApplication.sharedApplication endBackgroundTask:background_task];
	uint64_t ticket = ++background_generation;
	background_task = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"Save OpenTTD resume"
																 expirationHandler:^{
																   // Expiration releases the lease, never deletes or promotes a save file.
																   if (ticket == background_generation && background_task != UIBackgroundTaskInvalid)
																   {
																	   [UIApplication.sharedApplication endBackgroundTask:background_task];
																	   background_task = UIBackgroundTaskInvalid;
																   }
																 }];
	background_save_request.store(ticket);
}
- (void)sceneWillResignActive:(UIScene *)scene
{
	active.store(false);
	game_controller.loupe.hidden = YES;
	[game_controller.gameView cancelTouches];
}
@end
@interface IOSAppDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation IOSAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options
{
	return YES;
}
@end
int main(int argc, char **argv)
{
	@autoreleasepool
	{
		return UIApplicationMain(argc, argv, nil, NSStringFromClass(IOSAppDelegate.class));
	}
}
