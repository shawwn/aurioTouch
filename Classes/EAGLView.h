/*
 
 Copyright (C) 2016 Apple Inc. All Rights Reserved.
 See LICENSE.txt for this sample’s licensing information
 
 Abstract:
 This class wraps the CAEAGLLayer from CoreAnimation into a convenient UIView subclass
 
 */

// Framework includes
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#if !TARGET_OS_UIKITFORMAC
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES1/gl.h>
#import <OpenGLES/ES1/glext.h>
#else
#import <MetalKit/MetalKit.h>
#import <Metal/Metal.h>
#endif

// Local includes
#import "AudioController.h"

#if TARGET_OS_UIKITFORMAC
@interface EAGLView : MTKView
#else
@interface EAGLView : UIView
#endif

@property (assign)  BOOL applicationResignedActive;

- (void)startAnimation;
- (void)stopAnimation;

@end
