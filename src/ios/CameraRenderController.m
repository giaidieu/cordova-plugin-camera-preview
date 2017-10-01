#import "CameraRenderController.h"
#import <CoreVideo/CVOpenGLESTextureCache.h>
#import <GLKit/GLKit.h>
#import <OpenGLES/ES2/glext.h>
#import <ImageIO/ImageIO.h>
#import <AssetsLibrary/AssetsLibrary.h>
#import <ImageIO/CGImageProperties.h>

@implementation CameraRenderController
@synthesize context = _context;
@synthesize delegate;


- (CameraRenderController *)init {
  if (self = [super init]) {
    self.renderLock = [[NSLock alloc] init];
  }
  return self;
}

- (void)loadView {
  GLKView *glkView = [[GLKView alloc] init];
  [glkView setBackgroundColor:[UIColor blackColor]];
  [self setView:glkView];
}

- (void)viewDidLoad {
  [super viewDidLoad];

  self.context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];

  if (!self.context) {
    NSLog(@"Failed to create ES context");
  }

  CVReturn err = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL, self.context, NULL, &_videoTextureCache);
  if (err) {
    NSLog(@"Error at CVOpenGLESTextureCacheCreate %d", err);
    return;
  }

  GLKView *view = (GLKView *)self.view;
  view.context = self.context;
  view.drawableDepthFormat = GLKViewDrawableDepthFormat24;
  view.contentMode = UIViewContentModeScaleToFill;

  glGenRenderbuffers(1, &_renderBuffer);
  glBindRenderbuffer(GL_RENDERBUFFER, _renderBuffer);

  self.ciContext = [CIContext contextWithEAGLContext:self.context];

  if (self.dragEnabled) {
    //add drag action listener
    NSLog(@"Enabling view dragging");
    UIPanGestureRecognizer *drag = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self.view addGestureRecognizer:drag];
  }

  if (self.tapToFocus && self.tapToTakePicture){
    //tap to focus and take picture
    UITapGestureRecognizer *tapToFocusAndTakePicture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector (handleFocusAndTakePictureTap:)];
    [self.view addGestureRecognizer:tapToFocusAndTakePicture];

  } else if (self.tapToFocus){
    // tap to focus
    UITapGestureRecognizer *tapToFocusGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector (handleFocusTap:)];
    [self.view addGestureRecognizer:tapToFocusGesture];

  } else if (self.tapToTakePicture) {
    //tap to take picture
    UITapGestureRecognizer *takePictureTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTakePictureTap:)];
    [self.view addGestureRecognizer:takePictureTap];
  }

  self.view.userInteractionEnabled = self.dragEnabled || self.tapToTakePicture || self.tapToFocus;
}

- (void) viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];

  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(appplicationIsActive:)
                                               name:UIApplicationDidBecomeActiveNotification
                                             object:nil];

  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(applicationEnteredForeground:)
                                               name:UIApplicationWillEnterForegroundNotification
                                             object:nil];

  dispatch_async(self.sessionManager.sessionQueue, ^{
      NSLog(@"Starting session");
      [self.sessionManager.session startRunning];
      });
}

- (void) viewWillDisappear:(BOOL)animated {
  [super viewWillDisappear:animated];

  [[NSNotificationCenter defaultCenter] removeObserver:self
                                                  name:UIApplicationDidBecomeActiveNotification
                                                object:nil];

  [[NSNotificationCenter defaultCenter] removeObserver:self
                                                  name:UIApplicationWillEnterForegroundNotification
                                                object:nil];

  dispatch_async(self.sessionManager.sessionQueue, ^{
      NSLog(@"Stopping session");
      [self.sessionManager.session stopRunning];
      });
}

- (void) handleFocusAndTakePictureTap:(UITapGestureRecognizer*)recognizer {
  NSLog(@"handleFocusAndTakePictureTap");

  // let the delegate take an image, the next time the image is in focus.
  [self.delegate invokeTakePictureOnFocus];

  // let the delegate focus on the tapped point.
  [self handleFocusTap:recognizer];
}

- (void) handleTakePictureTap:(UITapGestureRecognizer*)recognizer {
  NSLog(@"handleTakePictureTap");
  [self.delegate invokeTakePicture];
}

- (void) handleFocusTap:(UITapGestureRecognizer*)recognizer {
  NSLog(@"handleTapFocusTap");

  if (recognizer.state == UIGestureRecognizerStateEnded)    {
    CGPoint point = [recognizer locationInView:self.view];
    [self.delegate invokeTapToFocus:point];
  }
}

- (void) onFocus{
  [self.delegate invokeTakePicture];
}

- (IBAction)handlePan:(UIPanGestureRecognizer *)recognizer {
        CGPoint translation = [recognizer translationInView:self.view];
        recognizer.view.center = CGPointMake(recognizer.view.center.x + translation.x,
                                             recognizer.view.center.y + translation.y);
        [recognizer setTranslation:CGPointMake(0, 0) inView:self.view];
}

- (void) appplicationIsActive:(NSNotification *)notification {
  dispatch_async(self.sessionManager.sessionQueue, ^{
      NSLog(@"Starting session");
      [self.sessionManager.session startRunning];
      });
}

- (void) applicationEnteredForeground:(NSNotification *)notification {
  dispatch_async(self.sessionManager.sessionQueue, ^{
      NSLog(@"Stopping session");
      [self.sessionManager.session stopRunning];
      });
}

-(void)captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
  if ([self.renderLock tryLock]) {
    CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)CMSampleBufferGetImageBuffer(sampleBuffer);
    CIImage *image = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    
    NSDictionary* dict = (NSDictionary*)CMGetAttachment(sampleBuffer, kCGImagePropertyExifDictionary, NULL);

    float rawShutterSpeed = [[dict objectForKey:(NSString *)kCGImagePropertyExifShutterSpeedValue] floatValue];
    float rawApentureValue = [[dict objectForKey:(NSString *)kCGImagePropertyExifApertureValue] floatValue];
    float rawFNumber = [[dict objectForKey:(NSString *)kCGImagePropertyExifFNumber] floatValue];
    float rawExposureTime = [[dict objectForKey:(NSString *)kCGImagePropertyExifExposureTime] floatValue];
    NSNumber *rawISOspeedrating  = [[dict objectForKey:(NSString *)kCGImagePropertyExifISOSpeedRatings] objectAtIndex:0];
    float brightness = [[dict objectForKey:(NSString *)kCGImagePropertyExifBrightnessValue] floatValue];
    
    //NSLog(@"Dic: %@", dict);
    //NSLog(@"Shutter: %f", rawShutterSpeed);
    //NSLog(@"Apenture: %f", rawApentureValue);
    //NSLog(@"FNumber: %f", rawFNumber);
    //NSLog(@"ExposureTime: %f", rawExposureTime);
    //NSLog(@"rawISOspeed: %d", rawISOspeed);
    //NSLog(@"Brightness: %f", brightness);

    // Store to local for send back later.
    NSNumber *shutterspeed_store = [NSNumber numberWithFloat:rawShutterSpeed];
    NSNumber *apenture_store = [NSNumber numberWithFloat:rawApentureValue];
    NSNumber *fnumber_store = [NSNumber numberWithFloat:rawFNumber];
    NSNumber *exposuretime_store = [NSNumber numberWithFloat:rawExposureTime];
    NSNumber *isospeed_store = rawISOspeedrating;
    NSNumber *brightness_store = [NSNumber numberWithFloat:brightness];

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject: [shutterspeed_store stringValue] forKey:@"shutterspeed_store"];
    [defaults setObject: [apenture_store stringValue] forKey:@"apenture_store"];
    [defaults setObject: [fnumber_store stringValue] forKey:@"fnumber_store"];
    [defaults setObject: [exposuretime_store stringValue] forKey:@"exposuretime_store"];
    [defaults setObject: [isospeed_store stringValue] forKey:@"isospeed_store"];
    [defaults setObject: [brightness_store stringValue] forKey:@"brightness_store"];
    [defaults synchronize];

      
    // Get lux.
    /*
    CVPixelBufferLockBaseAddress(pixelBuffer,0);

    unsigned char *pixels = (unsigned char *)CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t image_width = CVPixelBufferGetWidth(pixelBuffer);
    size_t image_height = CVPixelBufferGetHeight(pixelBuffer);

    double totalLuminance = 0.0;
    for(int p=0;p<image_width*image_height;p+=4) {
      totalLuminance += pixels[p]*0.299 + pixels[p+1]*0.587 + pixels[p+2]*0.114;
    }
      
    totalLuminance /= (image_width*image_height);
    totalLuminance /= 255.0;
      
    //totalLuminance = totalLuminance * (2 * 3.141592653589793);
    
    // Store to local for send back later.
    NSNumber *luminance_store = [NSNumber numberWithDouble:totalLuminance];

    //NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    //[defaults setObject: [totalLuminance_store stringValue] forKey:@"totalLuminance"];
    //[defaults synchronize];

    //NSLog(@"Lux:%f",totalLuminance);

    CVPixelBufferUnlockBaseAddress(pixelBuffer,0);
    */


    CGFloat scaleHeight = self.view.frame.size.height/image.extent.size.height;
    CGFloat scaleWidth = self.view.frame.size.width/image.extent.size.width;

    CGFloat scale, x, y;
    if (scaleHeight < scaleWidth) {
      scale = scaleWidth;
      x = 0;
      y = ((scale * image.extent.size.height) - self.view.frame.size.height ) / 2;
    } else {
      scale = scaleHeight;
      x = ((scale * image.extent.size.width) - self.view.frame.size.width )/ 2;
      y = 0;
    }

    // scale - translate
    CGAffineTransform xscale = CGAffineTransformMakeScale(scale, scale);
    CGAffineTransform xlate = CGAffineTransformMakeTranslation(-x, -y);
    CGAffineTransform xform =  CGAffineTransformConcat(xscale, xlate);

    CIFilter *centerFilter = [CIFilter filterWithName:@"CIAffineTransform"  keysAndValues:
      kCIInputImageKey, image,
      kCIInputTransformKey, [NSValue valueWithBytes:&xform objCType:@encode(CGAffineTransform)],
      nil];

    CIImage *transformedImage = [centerFilter outputImage];

    // crop
    CIFilter *cropFilter = [CIFilter filterWithName:@"CICrop"];
    CIVector *cropRect = [CIVector vectorWithX:0 Y:0 Z:self.view.frame.size.width W:self.view.frame.size.height];
    [cropFilter setValue:transformedImage forKey:kCIInputImageKey];
    [cropFilter setValue:cropRect forKey:@"inputRectangle"];
    CIImage *croppedImage = [cropFilter outputImage];

    //fix front mirroring
    if (self.sessionManager.defaultCamera == AVCaptureDevicePositionFront) {
      CGAffineTransform matrix = CGAffineTransformTranslate(CGAffineTransformMakeScale(-1, 1), 0, croppedImage.extent.size.height);
      croppedImage = [croppedImage imageByApplyingTransform:matrix];
    }

    self.latestFrame = croppedImage;

    CGFloat pointScale;
    if ([[UIScreen mainScreen] respondsToSelector:@selector(nativeScale)]) {
      pointScale = [[UIScreen mainScreen] nativeScale];
    } else {
      pointScale = [[UIScreen mainScreen] scale];
    }
    CGRect dest = CGRectMake(0, 0, self.view.frame.size.width*pointScale, self.view.frame.size.height*pointScale);

    [self.ciContext drawImage:croppedImage inRect:dest fromRect:[croppedImage extent]];
    [self.context presentRenderbuffer:GL_RENDERBUFFER];
    [(GLKView *)(self.view)display];
    [self.renderLock unlock];
  }
}

- (void)viewDidUnload {
  [super viewDidUnload];

  if ([EAGLContext currentContext] == self.context) {
    [EAGLContext setCurrentContext:nil];
  }
  self.context = nil;
}

- (void)didReceiveMemoryWarning {
  [super didReceiveMemoryWarning];
  // Release any cached data, images, etc. that aren't in use.
}

- (BOOL)shouldAutorotate {
  return YES;
}

-(void) willRotateToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation duration:(NSTimeInterval)duration {
  [self.sessionManager updateOrientation:[self.sessionManager getCurrentOrientation:toInterfaceOrientation]];
}

@end
