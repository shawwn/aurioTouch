/*
 
 Copyright (C) 2016 Apple Inc. All Rights Reserved.
 See LICENSE.txt for this sample’s licensing information
 
 Abstract:
 This class wraps the CAEAGLLayer from CoreAnimation into a convenient UIView subclass
 
 */

#import <QuartzCore/QuartzCore.h>
#if !TARGET_OS_UIKITFORMAC
#import <OpenGLES/EAGLDrawable.h>
#endif

#import "EAGLView.h"
#import "BufferManager.h"


#define USE_DEPTH_BUFFER 1
#define SPECTRUM_BAR_WIDTH 4


#ifndef CLAMP
#define CLAMP(min,x,max) (x < min ? min : (x > max ? max : x))
#endif


// value, a, r, g, b
GLfloat colorLevels[] = {
    0., 1., 0., 0., 0.,
    .333, 1., .7, 0., 0.,
    .667, 1., 0., 0., 1.,
    1., 1., 0., 1., 1.,
};

#define kMinDrawSamples 64
#define kMaxDrawSamples 4096


typedef struct SpectrumLinkedTexture {
	GLuint							texName;
	struct SpectrumLinkedTexture	*nextTex;
} SpectrumLinkedTexture;


typedef enum aurioTouchDisplayMode {
	aurioTouchDisplayModeOscilloscopeWaveform,
	aurioTouchDisplayModeOscilloscopeFFT,
	aurioTouchDisplayModeSpectrum
} aurioTouchDisplayMode;

#if TARGET_OS_UIKITFORMAC
typedef id<MTLDevice> SystemContext;
#else
typedef EAGLContext* SystemContext;
#endif


@interface EAGLView () {
    
    /* The pixel dimensions of the backbuffer */
	GLint backingWidth;
	GLint backingHeight;
	
	SystemContext context;
	
	/* OpenGL names for the renderbuffer and framebuffers used to render to this view */
	GLuint viewRenderbuffer, viewFramebuffer;
	
	/* OpenGL name for the depth buffer that is attached to viewFramebuffer, if it exists (0 if it does not exist) */
	GLuint depthRenderbuffer;
    
	NSTimer                     *animationTimer;
	NSTimeInterval              animationInterval;
	NSTimeInterval              animationStarted;
    
    BOOL                        applicationResignedActive;
    
    UIImageView*				sampleSizeOverlay;
	UILabel*					sampleSizeText;
    
	BOOL						initted_oscilloscope, initted_spectrum;
	UInt32*						texBitBuffer;
	CGRect						spectrumRect;
	
	GLuint						bgTexture;
	GLuint						muteOffTexture, muteOnTexture;
	GLuint						fftOffTexture, fftOnTexture;
	GLuint						sonoTexture;
	
	aurioTouchDisplayMode		displayMode;
    
	SpectrumLinkedTexture*		firstTex;
    
	UIEvent*					pinchEvent;
	CGFloat						lastPinchDist;
	Float32*					l_fftData;
	GLfloat*					oscilLine;
    
    AudioController*            audioController;
    
}

- (BOOL)createFramebuffer;
- (void)destroyFramebuffer;
- (void)setupView;
- (void)drawView;
- (void)setAnimationInterval:(NSTimeInterval)interval;

@end

#if TARGET_OS_UIKITFORMAC
#define SystemLayer CAMetalLayer
#else
#define SystemLayer CAEAGLLayer
#endif
@implementation EAGLView

@synthesize applicationResignedActive;

// You must implement this
+ (Class) layerClass
{
  return [SystemLayer class];
}

//The GL view is stored in the nib file. When it's unarchived it's sent -initWithCoder:
- (id)initWithCoder:(NSCoder*)coder
{
	if((self = [super initWithCoder:coder])) {
    
        self.frame = [[UIScreen mainScreen] bounds];

#if !TARGET_OS_UIKITFORMAC
		// Get the layer
		CAEAGLLayer *eaglLayer = (CAEAGLLayer*) self.layer;
		
		eaglLayer.opaque = YES;
		
		eaglLayer.drawableProperties = [NSDictionary dictionaryWithObjectsAndKeys:
                                       [NSNumber numberWithBool:FALSE],
                                       kEAGLDrawablePropertyRetainedBacking,
                                       kEAGLColorFormatRGBA8,
                                       kEAGLDrawablePropertyColorFormat,
                                       nil];
		
        context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES1];
		
		if(!context || ![EAGLContext setCurrentContext:context] || ![self createFramebuffer]) {
			[self release];
			return nil;
		}
#endif
        
        // Enable multi touch so we can handle pinch and zoom in the oscilloscope
        self.multipleTouchEnabled = YES;
        
        audioController = [[AudioController alloc] init];
        l_fftData = (Float32*) calloc([audioController getBufferManagerInstance]->GetFFTOutputBufferLength(), sizeof(Float32));
		
        oscilLine = (GLfloat*)malloc(kDefaultDrawSamples * 2 * sizeof(GLfloat));

		animationInterval = 1.0 / 60.0;
		      
		[self setupView];
		[self drawView];
        
        #if TARGET_OS_UIKITFORMAC
        displayMode = aurioTouchDisplayModeOscilloscopeFFT;
        BufferManager* bufferManager = [audioController getBufferManagerInstance];
        bufferManager->SetDisplayMode(displayMode);
        #else
        displayMode = aurioTouchDisplayModeOscilloscopeWaveform;
        #endif
        
        // Set up our overlay view that pops up when we are pinching/zooming the oscilloscope
        UIImage *img_ui = nil;
        {
            // Draw the rounded rect for the bg path using this convenience function
            CGPathRef bgPath = CreateRoundedRectPath(CGRectMake(0, 0, 110, 234), 15.);
            
            CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
            // Create the bitmap context into which we will draw
            CGContextRef cxt = CGBitmapContextCreate(NULL, 110, 234, 8, 4*110, cs, kCGImageAlphaPremultipliedFirst);
            CGContextSetFillColorSpace(cxt, cs);
            CGFloat fillClr[] = {0., 0., 0., 0.7};
            CGContextSetFillColor(cxt, fillClr);
            // Add the rounded rect to the context...
            CGContextAddPath(cxt, bgPath);
            // ... and fill it.
            CGContextFillPath(cxt);
            
            // Make a CGImage out of the context
            CGImageRef img_cg = CGBitmapContextCreateImage(cxt);
            // Make a UIImage out of the CGImage
            img_ui = [UIImage imageWithCGImage:img_cg];
            
            // Clean up
            CGImageRelease(img_cg);
            CGColorSpaceRelease(cs);
            CGContextRelease(cxt);
            CGPathRelease(bgPath);
        }
        
        // Create the image view to hold the background rounded rect which we just drew
        sampleSizeOverlay = [[UIImageView alloc] initWithImage:img_ui];
        sampleSizeOverlay.frame = CGRectMake(190, 124, 110, 234);
        
        // Create the text view which shows the size of our oscilloscope window as we pinch/zoom
        sampleSizeText = [[UILabel alloc] initWithFrame:CGRectMake(-62, 0, 234, 234)];
        sampleSizeText.textAlignment = NSTextAlignmentCenter;
        sampleSizeText.textColor = [UIColor whiteColor];
        sampleSizeText.text = NSLocalizedString(@"0000 ms", nil);
        sampleSizeText.font = [UIFont boldSystemFontOfSize:36.];
        // Rotate the text view since we want the text to draw top to bottom (when the device is oriented vertically)
        sampleSizeText.transform = CGAffineTransformMakeRotation(M_PI_2);
        sampleSizeText.backgroundColor = [UIColor clearColor];
        
        // Add the text view as a subview of the overlay BG
        [sampleSizeOverlay addSubview:sampleSizeText];
        // Text view was retained by the above line, so we can release it now
        [sampleSizeText release];
        
        // We don't add sampleSizeOverlay to our main view yet. We just hang on to it for now, and add it when we
        // need to display it, i.e. when a user starts a pinch/zoom.
        
        // Set up the view to refresh at 20 hz
        [self setAnimationInterval:1./20.];
        [self startAnimation];
	}
	
	return self;
}

- (void)layoutSubviews
{
#if !TARGET_OS_UIKITFORMAC
	[EAGLContext setCurrentContext:context];
#endif
	[self destroyFramebuffer];
	[self createFramebuffer];
	[self drawView];
}

- (BOOL)createFramebuffer
{
#if !TARGET_OS_UIKITFORMAC
	glGenFramebuffersOES(1, &viewFramebuffer);
	glGenRenderbuffersOES(1, &viewRenderbuffer);
	
	glBindFramebufferOES(GL_FRAMEBUFFER_OES, viewFramebuffer);
	glBindRenderbufferOES(GL_RENDERBUFFER_OES, viewRenderbuffer);
	[context renderbufferStorage:GL_RENDERBUFFER_OES fromDrawable:(id<EAGLDrawable>)self.layer];
	glFramebufferRenderbufferOES(GL_FRAMEBUFFER_OES, GL_COLOR_ATTACHMENT0_OES, GL_RENDERBUFFER_OES, viewRenderbuffer);
	
	glGetRenderbufferParameterivOES(GL_RENDERBUFFER_OES, GL_RENDERBUFFER_WIDTH_OES, &backingWidth);
	glGetRenderbufferParameterivOES(GL_RENDERBUFFER_OES, GL_RENDERBUFFER_HEIGHT_OES, &backingHeight);
	
	if(USE_DEPTH_BUFFER) {
		glGenRenderbuffersOES(1, &depthRenderbuffer);
		glBindRenderbufferOES(GL_RENDERBUFFER_OES, depthRenderbuffer);
		glRenderbufferStorageOES(GL_RENDERBUFFER_OES, GL_DEPTH_COMPONENT16_OES, backingWidth, backingHeight);
		glFramebufferRenderbufferOES(GL_FRAMEBUFFER_OES, GL_DEPTH_ATTACHMENT_OES, GL_RENDERBUFFER_OES, depthRenderbuffer);
	}
	
	if(glCheckFramebufferStatusOES(GL_FRAMEBUFFER_OES) != GL_FRAMEBUFFER_COMPLETE_OES) {
		NSLog(@"failed to make complete framebuffer object %x", glCheckFramebufferStatusOES(GL_FRAMEBUFFER_OES));
		return NO;
	}
	
#endif
	return YES;
}


- (void)destroyFramebuffer
{
#if !TARGET_OS_UIKITFORMAC
	glDeleteFramebuffersOES(1, &viewFramebuffer);
#endif
	viewFramebuffer = 0;
#if !TARGET_OS_UIKITFORMAC
	glDeleteRenderbuffersOES(1, &viewRenderbuffer);
#endif
	viewRenderbuffer = 0;
	
	if(depthRenderbuffer) {
#if !TARGET_OS_UIKITFORMAC
		glDeleteRenderbuffersOES(1, &depthRenderbuffer);
#endif
		depthRenderbuffer = 0;
	}
}


- (void)startAnimation
{
	animationTimer = [NSTimer scheduledTimerWithTimeInterval:animationInterval target:self selector:@selector(drawView) userInfo:nil repeats:YES];
	animationStarted = [NSDate timeIntervalSinceReferenceDate];
    [audioController startIOUnit];
}


- (void)stopAnimation
{
	[animationTimer invalidate];
	animationTimer = nil;
    [audioController stopIOUnit];
}


- (void)setAnimationInterval:(NSTimeInterval)interval
{
	animationInterval = interval;
	
	if(animationTimer) {
		[self stopAnimation];
		[self startAnimation];
	}
}


- (void)setupView
{
#if !TARGET_OS_UIKITFORMAC
	// Sets up matrices and transforms for OpenGL ES
	glViewport(0, 0, backingWidth, backingHeight);
	glMatrixMode(GL_PROJECTION);
	glLoadIdentity();
	glOrthof(0, backingWidth, 0, backingHeight, -1.0f, 1.0f);
	glMatrixMode(GL_MODELVIEW);
	
	// Clears the view with black
	glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
	
	glEnableClientState(GL_VERTEX_ARRAY);
#endif
}


// Updates the OpenGL view when the timer fires
- (void)drawView
{
    // the NSTimer seems to fire one final time even though it's been invalidated
    // so just make sure and not draw if we're resigning active
    if (self.applicationResignedActive) return;
    
#if !TARGET_OS_UIKITFORMAC
	// Make sure that you are drawing to the current context
	[EAGLContext setCurrentContext:context];
	
	glBindFramebufferOES(GL_FRAMEBUFFER_OES, viewFramebuffer);
#endif

	[self drawView:self forTime:([NSDate timeIntervalSinceReferenceDate] - animationStarted)];
	
#if !TARGET_OS_UIKITFORMAC
	glBindRenderbufferOES(GL_RENDERBUFFER_OES, viewRenderbuffer);
	[context presentRenderbuffer:GL_RENDERBUFFER_OES];
#endif
}


- (void)setupViewForOscilloscope
{
	CGImageRef img;
	
	// Load our GL textures
	
	img = [UIImage imageNamed:@"oscilloscope.png"].CGImage;
    
	[self createGLTexture:&bgTexture fromCGImage:img];
	
	img = [UIImage imageNamed:@"fft_off.png"].CGImage;
	[self createGLTexture:&fftOffTexture fromCGImage:img];
	
	img = [UIImage imageNamed:@"fft_on.png"].CGImage;
	[self createGLTexture:&fftOnTexture fromCGImage:img];
	
	img = [UIImage imageNamed:@"mute_off.png"].CGImage;
	[self createGLTexture:&muteOffTexture fromCGImage:img];
	
	img = [UIImage imageNamed:@"mute_on.png"].CGImage;
	[self createGLTexture:&muteOnTexture fromCGImage:img];
    
	img = [UIImage imageNamed:@"sonogram.png"].CGImage;
	[self createGLTexture:&sonoTexture fromCGImage:img];
    
	initted_oscilloscope = YES;
}


- (void)clearTextures
{
	bzero(texBitBuffer, sizeof(UInt32) * 512);
	SpectrumLinkedTexture *curTex;
	
#if !TARGET_OS_UIKITFORMAC
	for (curTex = firstTex; curTex; curTex = curTex->nextTex)
	{
		glBindTexture(GL_TEXTURE_2D, curTex->texName);
		glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 1, 512, 0, GL_RGBA, GL_UNSIGNED_BYTE, texBitBuffer);
	}
#endif
}

- (void)setupViewForSpectrum
{
#if !TARGET_OS_UIKITFORMAC
	glClearColor(0., 0., 0., 0.);
	
	spectrumRect = CGRectMake(10., 10., 460., 300.);
	
	// The bit buffer for the texture needs to be 512 pixels, because OpenGL textures are powers of
	// two in either dimensions. Our texture is drawing a strip of 300 vertical pixels on the screen,
	// so we need to step up to 512 (the nearest power of 2 greater than 300).
	texBitBuffer = (UInt32 *)(malloc(sizeof(UInt32) * 512));
	
	// Clears the view with black
	glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
	
	glEnableClientState(GL_VERTEX_ARRAY);
	glEnableClientState(GL_TEXTURE_COORD_ARRAY);
	
	NSUInteger texCount = ceil(CGRectGetWidth(spectrumRect) / (CGFloat)SPECTRUM_BAR_WIDTH);
	GLuint *texNames;
	
	texNames = (GLuint *)(malloc(sizeof(GLuint) * texCount));
	glGenTextures((int)texCount, texNames);
	
	unsigned int i;
	SpectrumLinkedTexture *curTex = NULL;
	firstTex = (SpectrumLinkedTexture *)(calloc(1, sizeof(SpectrumLinkedTexture)));
	firstTex->texName = texNames[0];
	curTex = firstTex;
	
	bzero(texBitBuffer, sizeof(UInt32) * 512);
	
	glBindTexture(GL_TEXTURE_2D, curTex->texName);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
	
	for (i=1; i<texCount; i++)
	{
		curTex->nextTex = (SpectrumLinkedTexture *)(calloc(1, sizeof(SpectrumLinkedTexture)));
		curTex = curTex->nextTex;
		curTex->texName = texNames[i];
		
		glBindTexture(GL_TEXTURE_2D, curTex->texName);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
	}
	
	// Enable use of the texture
	glEnable(GL_TEXTURE_2D);
	// Set a blending function to use
	glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
	// Enable blending
	glEnable(GL_BLEND);
	
	initted_spectrum = YES;
	
	free(texNames);
#endif 
}

- (void)drawOscilloscope
{
#if !TARGET_OS_UIKITFORMAC
	// Clear the view
	glClear(GL_COLOR_BUFFER_BIT);
	
	glBlendFunc(GL_SRC_ALPHA, GL_ONE);
	
	glColor4f(1., 1., 1., 1.);
	
	glPushMatrix();
    
    // xy coord. offset for various devices
    float offsetY = (self.bounds.size.height - 480) / 2;
    float offsetX = (self.bounds.size.width - 320) / 2;
	
	glTranslatef(offsetX, 480 + offsetY, 0.);
	glRotatef(-90., 0., 0., 1.);
	
	glEnable(GL_TEXTURE_2D);
	glEnableClientState(GL_VERTEX_ARRAY);
	glEnableClientState(GL_TEXTURE_COORD_ARRAY);
	
	{
		// Draw our background oscilloscope screen
		const GLfloat vertices[] = {
			0., 0.,
			512., 0.,
			0.,  512.,
			512.,  512.,
		};
		const GLshort texCoords[] = {
			0, 0,
			1, 0,
			0, 1,
			1, 1,
		};
		
		
		glBindTexture(GL_TEXTURE_2D, bgTexture);
		
		glVertexPointer(2, GL_FLOAT, 0, vertices);
		glTexCoordPointer(2, GL_SHORT, 0, texCoords);
		
		glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
	}
	
	{
		// Draw our buttons
		const GLfloat vertices[] = {
			0., 0.,
			112, 0.,
			0.,  64,
			112,  64,
		};
		const GLshort texCoords[] = {
			0, 0,
			1, 0,
			0, 1,
			1, 1,
		};
		
		glPushMatrix();
		
		glVertexPointer(2, GL_FLOAT, 0, vertices);
		glTexCoordPointer(2, GL_SHORT, 0, texCoords);
        
        // button coords
		glTranslatef(15 + offsetX, 0, 0);
		glBindTexture(GL_TEXTURE_2D, sonoTexture);
		glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
		glTranslatef(90 + offsetX, 0, 0);
		glBindTexture(GL_TEXTURE_2D, audioController.muteAudio ? muteOnTexture : muteOffTexture);
		glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
		glTranslatef(105 + offsetX, 0, 0);
		glBindTexture(GL_TEXTURE_2D, (displayMode == aurioTouchDisplayModeOscilloscopeFFT) ? fftOnTexture : fftOffTexture);
		glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
		
		glPopMatrix();
		
	}
#endif
	
    BufferManager* bufferManager = [audioController getBufferManagerInstance];
    Float32** drawBuffers = bufferManager->GetDrawBuffers();
	if (displayMode == aurioTouchDisplayModeOscilloscopeFFT)
	{
		if (bufferManager->HasNewFFTData())
		{
			bufferManager->GetFFTOutput(l_fftData);
        
			int y, maxY;
			maxY = bufferManager->GetCurrentDrawBufferLength();
            int fftLength = bufferManager->GetFFTOutputBufferLength();
      printf("\n\n");
      printf("-----------------------------------------------\n");
      fflush(stdout);
			for (y=0; y<maxY; y++)
			{
        if (y % (16*16) == 0) {
          printf("\n");
          fflush(stdout);
        }
				CGFloat yFract = (CGFloat)y / (CGFloat)(maxY - 1);
				CGFloat fftIdx = yFract * ((CGFloat)fftLength - 1);
				
				double fftIdx_i, fftIdx_f;
				fftIdx_f = modf(fftIdx, &fftIdx_i);
				
				CGFloat fft_l_fl, fft_r_fl;
				CGFloat interpVal;
				
                int lowerIndex = (int) fftIdx_i;
                int upperIndex = (int) fftIdx_i + 1;
                upperIndex = (upperIndex == fftLength) ? fftLength - 1 : upperIndex;
                
				fft_l_fl = (CGFloat)(l_fftData[lowerIndex] + 80) / 64.;
				fft_r_fl = (CGFloat)(l_fftData[upperIndex] + 80) / 64.;
				interpVal = fft_l_fl * (1. - fftIdx_f) + fft_r_fl * fftIdx_f;
				
				drawBuffers[0][y] = CLAMP(0., interpVal, 1.);
        if (y % 16 == 0) {
          printf("%0.04f ", (float)drawBuffers[0][y]);    
        }
			}
      fflush(stdout);
			[self cycleOscilloscopeLines];
		}
	}
	
#if !TARGET_OS_UIKITFORMAC
	GLfloat *oscilLine_ptr;
	GLfloat max = kDefaultDrawSamples; //bufferManager->GetCurrentDrawBufferLength();
	Float32 *drawBuffer_ptr;
		
	glPushMatrix();
	
	// Translate to the left side and vertical center of the screen, and scale so that the screen coordinates
	// go from 0 to 1 along the X, and -1 to 1 along the Y
	glTranslatef(17., 182., 0.);
	glScalef(448., 116., 1.);
	
	// Set up some GL state for our oscilloscope lines
	glDisable(GL_TEXTURE_2D);
	glDisableClientState(GL_TEXTURE_COORD_ARRAY);
	glDisableClientState(GL_COLOR_ARRAY);
	glDisable(GL_LINE_SMOOTH);
	glLineWidth(2.);
	
	UInt32 drawBuffer_i;
	// Draw a line for each stored line in our buffer (the lines are stored and fade over time)
	for (drawBuffer_i=0; drawBuffer_i<kNumDrawBuffers; drawBuffer_i++)
	{
		if (!drawBuffers[drawBuffer_i]) continue;
		
		oscilLine_ptr = oscilLine;
		drawBuffer_ptr = drawBuffers[drawBuffer_i];
		
		GLfloat i;
		// Fill our vertex array with points
		for (i=0.; i<max; i=i+1.)
		{
			*oscilLine_ptr++ = i/max;
			*oscilLine_ptr++ = (Float32)(*drawBuffer_ptr++);
		}
		
		// If we're drawing the newest line, draw it in solid green. Otherwise, draw it in a faded green.
		if (drawBuffer_i == 0)
			glColor4f(0., 1., 0., 1.);
		else
			glColor4f(0., 1., 0., (.24 * (1. - ((GLfloat)drawBuffer_i / (GLfloat)kNumDrawBuffers))));
		
		// Set up vertex pointer,
		glVertexPointer(2, GL_FLOAT, 0, oscilLine);
		
		// and draw the line.
		glDrawArrays(GL_LINE_STRIP, 0, bufferManager->GetCurrentDrawBufferLength());
		
	}
	glPopMatrix();
	glPopMatrix();
#endif
}

- (void)cycleSpectrum
{
	SpectrumLinkedTexture *newFirst;
	newFirst = (SpectrumLinkedTexture *)calloc(1, sizeof(SpectrumLinkedTexture));
	newFirst->nextTex = firstTex;
	firstTex = newFirst;
	
	SpectrumLinkedTexture *thisTex = firstTex;
	do {
		if (!(thisTex->nextTex->nextTex))
		{
			firstTex->texName = thisTex->nextTex->texName;
			free(thisTex->nextTex);
			thisTex->nextTex = NULL;
		}
		thisTex = thisTex->nextTex;
	} while (thisTex);
}

double linearInterp(double valA, double valB, double fract)
{
	return valA + ((valB - valA) * fract);
}


- (void)renderFFTToTex
{
	[self cycleSpectrum];
	
	UInt32 *texBitBuffer_ptr = texBitBuffer;
	
	static int numLevels = sizeof(colorLevels) / sizeof(GLfloat) / 5;
	
	int y, maxY;
	maxY = CGRectGetHeight(spectrumRect);
    BufferManager* bufferManager = [audioController getBufferManagerInstance];
    int fftLength = bufferManager->GetFFTOutputBufferLength();
	for (y=0; y<maxY; y++)
	{
		CGFloat yFract = (CGFloat)y / (CGFloat)(maxY - 1);
		CGFloat fftIdx = yFract * ((CGFloat)fftLength-1);
        
		double fftIdx_i, fftIdx_f;
		fftIdx_f = modf(fftIdx, &fftIdx_i);
		
		CGFloat fft_l_fl, fft_r_fl;
		CGFloat interpVal;
		
		int lowerIndex = (int)(fftIdx_i);
        int upperIndex = (int)(fftIdx_i + 1);
        upperIndex = (upperIndex == fftLength) ? fftLength - 1 : upperIndex;
        
		fft_l_fl = (CGFloat)(l_fftData[lowerIndex] + 80) / 64.;
		fft_r_fl = (CGFloat)(l_fftData[upperIndex] + 80) / 64.;
		interpVal = fft_l_fl * (1. - fftIdx_f) + fft_r_fl * fftIdx_f;
		
		interpVal = sqrt(CLAMP(0., interpVal, 1.));
        
		UInt32 newPx = 0xFF000000;
		
		int level_i;
		const GLfloat *thisLevel = colorLevels;
		const GLfloat *nextLevel = colorLevels + 5;
		for (level_i=0; level_i<(numLevels-1); level_i++)
		{
			if ( (*thisLevel <= interpVal) && (*nextLevel >= interpVal) )
			{
				double fract = (interpVal - *thisLevel) / (*nextLevel - *thisLevel);
				newPx =
				((UInt8)(255. * linearInterp(thisLevel[1], nextLevel[1], fract)) << 24)
				|
				((UInt8)(255. * linearInterp(thisLevel[2], nextLevel[2], fract)) << 16)
				|
				((UInt8)(255. * linearInterp(thisLevel[3], nextLevel[3], fract)) << 8)
				|
				(UInt8)(255. * linearInterp(thisLevel[4], nextLevel[4], fract))
				;
				break;
			}
			
			thisLevel+=5;
			nextLevel+=5;
		}
		
		*texBitBuffer_ptr++ = newPx;
	}
	
#if !TARGET_OS_UIKITFORMAC
	glBindTexture(GL_TEXTURE_2D, firstTex->texName);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 1, 512, 0, GL_RGBA, GL_UNSIGNED_BYTE, texBitBuffer);
#endif 
}

- (void)drawSpectrum
{
#if !TARGET_OS_UIKITFORMAC
	// Clear the view
	glClear(GL_COLOR_BUFFER_BIT);
	   
    BufferManager* bufferManager = [audioController getBufferManagerInstance];
    if (bufferManager->HasNewFFTData())
    {
        bufferManager->GetFFTOutput(l_fftData);
        [self renderFFTToTex];
    }
    
	glClear(GL_COLOR_BUFFER_BIT);
	
	glEnable(GL_TEXTURE);
	glEnable(GL_TEXTURE_2D);
	
	glPushMatrix();
	glTranslatef(0., 480., 0.);
	glRotatef(-90., 0., 0., 1.);
	glTranslatef(spectrumRect.origin.x + spectrumRect.size.width, spectrumRect.origin.y, 0.);
	
	GLfloat quadCoords[] = {
		0., 0.,
		SPECTRUM_BAR_WIDTH, 0.,
		0., 512.,
		SPECTRUM_BAR_WIDTH, 512.,
	};
	
	GLshort texCoords[] = {
		0, 0,
		1, 0,
		0, 1,
		1, 1,
	};
	
	glVertexPointer(2, GL_FLOAT, 0, quadCoords);
	glEnableClientState(GL_VERTEX_ARRAY);
	glTexCoordPointer(2, GL_SHORT, 0, texCoords);
	glEnableClientState(GL_TEXTURE_COORD_ARRAY);
	
	glColor4f(1., 1., 1., 1.);
	
	SpectrumLinkedTexture *thisTex;
	glPushMatrix();
	for (thisTex = firstTex; thisTex; thisTex = thisTex->nextTex)
	{
		glTranslatef(-(SPECTRUM_BAR_WIDTH), 0., 0.);
		glBindTexture(GL_TEXTURE_2D, thisTex->texName);
		glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
	}
	glPopMatrix();
	glPopMatrix();
	
	glFlush();
#endif
}


- (void)drawView:(id)sender forTime:(NSTimeInterval)time
{
    if (![audioController audioChainIsBeingReconstructed])  //hold off on drawing until the audio chain has been reconstructed
    {
        if ((displayMode == aurioTouchDisplayModeOscilloscopeWaveform) || (displayMode == aurioTouchDisplayModeOscilloscopeFFT))
        {
            if (!initted_oscilloscope) [self setupViewForOscilloscope];
            [self drawOscilloscope];
        } else if (displayMode == aurioTouchDisplayModeSpectrum) {
            if (!initted_spectrum) [self setupViewForSpectrum];
            [self drawSpectrum];
        }
    }
}


- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event
{
	// If we're if waveform mode and not currently in a pinch event, and we've got two touches, start a pinch event
	if ((!pinchEvent) && ([[event allTouches] count] == 2) && (displayMode == aurioTouchDisplayModeOscilloscopeWaveform))
	{
		pinchEvent = event;
		NSArray *t = [[event allTouches] allObjects];
		lastPinchDist = fabs([[t objectAtIndex:0] locationInView:self].x - [[t objectAtIndex:1] locationInView:self].x);
		
        double hwSampleRate = [audioController sessionSampleRate];
        BufferManager* bufferManager = [audioController getBufferManagerInstance];
		sampleSizeText.text = [NSString stringWithFormat:@"%lu ms", bufferManager->GetCurrentDrawBufferLength() / (unsigned long)(hwSampleRate / 1000.)];
		[self addSubview:sampleSizeOverlay];
	}
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event
{
	// If we are in a pinch event...
	if ((event == pinchEvent) && ([[event allTouches] count] == 2))
	{
		CGFloat thisPinchDist, pinchDiff;
		NSArray *t = [[event allTouches] allObjects];
		thisPinchDist = fabs([[t objectAtIndex:0] locationInView:self].x - [[t objectAtIndex:1] locationInView:self].x);
		
		// Find out how far we traveled since the last event
		pinchDiff = thisPinchDist - lastPinchDist;
		// Adjust our draw buffer length accordingly,
        BufferManager* bufferManager = [audioController getBufferManagerInstance];
        UInt32 drawBufferLen = bufferManager->GetCurrentDrawBufferLength();
		drawBufferLen -= 12 * (int)pinchDiff;
		drawBufferLen = CLAMP(kMinDrawSamples, drawBufferLen, kMaxDrawSamples);
        bufferManager->SetCurrentDrawBufferLength(drawBufferLen);
		
		// and display the size of our oscilloscope window in our overlay view
        double hwSampleRate = [audioController sessionSampleRate];
		sampleSizeText.text = [NSString stringWithFormat:@"%lu ms", drawBufferLen / (unsigned long)(hwSampleRate / 1000.)];
		
		lastPinchDist = thisPinchDist;
	}
}


CGPathRef CreateRoundedRectPath(CGRect RECT, CGFloat cornerRadius)
{
	CGMutablePathRef		path;
	path = CGPathCreateMutable();
	
	double		maxRad = MAX(CGRectGetHeight(RECT) / 2., CGRectGetWidth(RECT) / 2.);
	
	if (cornerRadius > maxRad) cornerRadius = maxRad;
	
	CGPoint		bl, tl, tr, br;
	
	bl = tl = tr = br = RECT.origin;
	tl.y += RECT.size.height;
	tr.y += RECT.size.height;
	tr.x += RECT.size.width;
	br.x += RECT.size.width;
	
	CGPathMoveToPoint(path, NULL, bl.x + cornerRadius, bl.y);
	CGPathAddArcToPoint(path, NULL, bl.x, bl.y, bl.x, bl.y + cornerRadius, cornerRadius);
	CGPathAddLineToPoint(path, NULL, tl.x, tl.y - cornerRadius);
	CGPathAddArcToPoint(path, NULL, tl.x, tl.y, tl.x + cornerRadius, tl.y, cornerRadius);
	CGPathAddLineToPoint(path, NULL, tr.x - cornerRadius, tr.y);
	CGPathAddArcToPoint(path, NULL, tr.x, tr.y, tr.x, tr.y - cornerRadius, cornerRadius);
	CGPathAddLineToPoint(path, NULL, br.x, br.y + cornerRadius);
	CGPathAddArcToPoint(path, NULL, br.x, br.y, br.x - cornerRadius, br.y, cornerRadius);
	
	CGPathCloseSubpath(path);
	
	CGPathRef				ret;
	ret = CGPathCreateCopy(path);
	CGPathRelease(path);
	return ret;
}


- (void)cycleOscilloscopeLines
{
    BufferManager* bufferManager = [audioController getBufferManagerInstance];
    
	// Cycle the lines in our draw buffer so that they age and fade. The oldest line is discarded.
    Float32** drawBuffers = bufferManager->GetDrawBuffers();
	for (int drawBuffer_i=(kNumDrawBuffers - 2); drawBuffer_i>=0; drawBuffer_i--)
		memmove(drawBuffers[drawBuffer_i + 1], drawBuffers[drawBuffer_i], bufferManager->GetCurrentDrawBufferLength());
}


- (void)createGLTexture:(GLuint *)texName fromCGImage:(CGImageRef)img
{
#if !TARGET_OS_UIKITFORMAC
	GLubyte *spriteData = NULL;
	CGContextRef spriteContext;
	size_t imgW, imgH, texW, texH;
	
	imgW = CGImageGetWidth(img);
	imgH = CGImageGetHeight(img);
	
	// Find smallest possible powers of 2 for our texture dimensions
	for (texW = 1; texW < imgW; texW *= 2) ;
	for (texH = 1; texH < imgH; texH *= 2) ;
	
	// Allocated memory needed for the bitmap context
	spriteData = (GLubyte *) calloc(texH, texW * 4);
	// Uses the bitmatp creation function provided by the Core Graphics framework.
	spriteContext = CGBitmapContextCreate(spriteData, texW, texH, 8, texW * 4, CGImageGetColorSpace(img), kCGImageAlphaPremultipliedLast);
	
	// Translate and scale the context to draw the image upside-down (conflict in flipped-ness between GL textures and CG contexts)
	CGContextTranslateCTM(spriteContext, 0., texH);
	CGContextScaleCTM(spriteContext, 1., -1.);
	
	// After you create the context, you can draw the sprite image to the context.
	CGContextDrawImage(spriteContext, CGRectMake(0.0, 0.0, imgW, imgH), img);
	// You don't need the context at this point, so you need to release it to avoid memory leaks.
	CGContextRelease(spriteContext);
	
	// Use OpenGL ES to generate a name for the texture.
	glGenTextures(1, texName);
	// Bind the texture name.
	glBindTexture(GL_TEXTURE_2D, *texName);
	// Speidfy a 2D texture image, provideing the a pointer to the image data in memory
	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, (GLuint)texW, (GLuint)texH, 0, GL_RGBA, GL_UNSIGNED_BYTE, spriteData);
	// Set the texture parameters to use a minifying filter and a linear filer (weighted average)
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
	
	// Enable use of the texture
	glEnable(GL_TEXTURE_2D);
	// Set a blending function to use
	glBlendFunc(GL_SRC_ALPHA,GL_ONE);
	//glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
	// Enable blending
	glEnable(GL_BLEND);
	
	free(spriteData);
#endif
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event
{
    BufferManager* bufferManager = [audioController getBufferManagerInstance];
	if (event == pinchEvent)
	{
		// If our pinch/zoom has ended, nil out the pinchEvent and remove the overlay view
		[sampleSizeOverlay removeFromSuperview];
		pinchEvent = nil;
		return;
	}
    
	// any tap in sonogram view will exit back to the waveform
	if (displayMode == aurioTouchDisplayModeSpectrum)
	{
		[audioController playButtonPressedSound];
		displayMode = aurioTouchDisplayModeOscilloscopeWaveform;
        bufferManager->SetDisplayMode(displayMode);
		return;
	}
    
    // xy coord. offset for various devices
    float offsetY = (self.bounds.size.height - 480) / 2;
    float offsetX = (self.bounds.size.width - 320) / 2;
	
	UITouch *touch = [touches anyObject];
    if (CGRectContainsPoint(CGRectMake(offsetX, 15., 52., 99.), [touch locationInView:self])) // The Sonogram button was touched
    {
        [audioController playButtonPressedSound];
        if ((displayMode == aurioTouchDisplayModeOscilloscopeWaveform) || (displayMode == aurioTouchDisplayModeOscilloscopeFFT))
        {
            if (!initted_spectrum) [self setupViewForSpectrum];
            [self clearTextures];
            displayMode = aurioTouchDisplayModeSpectrum;
            bufferManager->SetDisplayMode(displayMode);
        }
    }
    else if (CGRectContainsPoint(CGRectMake(offsetX, offsetY + 105., 52., 99.), [touch locationInView:self])) // The Mute button was touched
    {
        [audioController playButtonPressedSound];
        audioController.muteAudio = !(audioController.muteAudio);
        return;
    }
    else if (CGRectContainsPoint(CGRectMake(offsetX, offsetY + 210, 52., 99.), [touch locationInView:self])) // The FFT button was touched
    {
        [audioController playButtonPressedSound];
        displayMode = (displayMode == aurioTouchDisplayModeOscilloscopeWaveform) ?  aurioTouchDisplayModeOscilloscopeFFT :
        aurioTouchDisplayModeOscilloscopeWaveform;
        bufferManager->SetDisplayMode(displayMode);
        return;
    }
}

// Stop animating and release resources when they are no longer needed.
- (void)dealloc
{
	[self stopAnimation];
	
#if !TARGET_OS_UIKITFORMAC
	if([EAGLContext currentContext] == context) {
		[EAGLContext setCurrentContext:nil];
	}
	
	[context release];
#endif
	context = nil;
    
    free(oscilLine);
	
	[super dealloc];
}


@end
