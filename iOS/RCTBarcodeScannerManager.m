//
//  RCTBarcodeScannerManager.m
//  ReactNativeBarcodeScanner
//
//  Created by Richard Lee on 4/18/15.
//  Copyright (c) 2015 Facebook. All rights reserved.
//

#import "RCTBarcodeScannerManager.h"
#import "RCTBarcodeScanner.h"
#import "RCTEventDispatcher.h"
#import "RCTBridge.h"
#import "RCTUtils.h"
#import "RCTLog.h"
#import "UIView+React.h"
#import "UIImage+Resize.h"
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>

CGFloat const kFocalPointOfInterestX = 0.5;
CGFloat const kFocalPointOfInterestY = 0.5;

@implementation RCTBarcodeScannerManager

RCT_EXPORT_MODULE();

@synthesize bridge = _bridge;

- (UIView *)view
{
  return [[RCTBarcodeScanner alloc] initWithManager:self];
}

RCT_EXPORT_VIEW_PROPERTY(aspect, NSString);
RCT_EXPORT_VIEW_PROPERTY(type, NSInteger);
RCT_EXPORT_VIEW_PROPERTY(orientation, NSInteger);

- (NSDictionary *)constantsToExport
{
  return @{
           @"aspects": @{
               @"Stretch": AVLayerVideoGravityResize,
               @"Fit": AVLayerVideoGravityResizeAspect,
               @"Fill": AVLayerVideoGravityResizeAspectFill
               },
           @"cameras": @{
               @"Front": @(AVCaptureDevicePositionFront),
               @"Back": @(AVCaptureDevicePositionBack)
               },
           @"orientations": @{
               @"LandscapeLeft": @(AVCaptureVideoOrientationLandscapeLeft),
               @"LandscapeRight": @(AVCaptureVideoOrientationLandscapeRight),
               @"Portrait": @(AVCaptureVideoOrientationPortrait),
               @"PortraitUpsideDown": @(AVCaptureVideoOrientationPortraitUpsideDown)
               }
           };
}

- (NSDictionary *)customDirectEventTypes
{
  return @{
           @"scanned": @{
               @"registrationName": @"onScanned"
               }
           };
}

- (id)init {
  
  if ((self = [super init])) {
    
    self.session = [AVCaptureSession new];
    self.session.sessionPreset = AVCaptureSessionPresetHigh;
    
    self.previewLayer = [AVCaptureVideoPreviewLayer layerWithSession:self.session];
    self.previewLayer.needsDisplayOnBoundsChange = YES;
    
    self.sessionQueue = dispatch_queue_create("cameraManagerQueue", DISPATCH_QUEUE_SERIAL);
    
    dispatch_async(self.sessionQueue, ^{
      NSError *error = nil;
      
      if (self.presetCamera == AVCaptureDevicePositionUnspecified) {
        self.presetCamera = AVCaptureDevicePositionBack;
      }
      
      AVCaptureDevice *captureDevice = [self deviceWithMediaType:AVMediaTypeVideo preferringPosition:self.presetCamera];
      AVCaptureDeviceInput *captureDeviceInput = [AVCaptureDeviceInput deviceInputWithDevice:captureDevice error:&error];
      
      if (error)
      {
        NSLog(@"%@", error);
      }
      
      if ([self.session canAddInput:captureDeviceInput])
      {
        [self.session addInput:captureDeviceInput];
        self.captureDeviceInput = captureDeviceInput;
      }
      
      AVCaptureMetadataOutput *captureOutput = [[AVCaptureMetadataOutput alloc] init];
      if ([self.session canAddOutput:captureOutput])
      {
        [captureOutput setMetadataObjectsDelegate:self queue:dispatch_get_main_queue()];
        [self.session addOutput:captureOutput];
//        captureOutput.metadataObjectTypes = [self defaultMetaDataObjectTypes];
        captureOutput.metadataObjectTypes = [captureOutput availableMetadataObjectTypes];
      }

//      AVCaptureStillImageOutput *stillImageOutput = [[AVCaptureStillImageOutput alloc] init];
//      if ([self.session canAddOutput:stillImageOutput])
//      {
//        stillImageOutput.outputSettings = @{AVVideoCodecKey : AVVideoCodecJPEG};
//        [self.session addOutput:stillImageOutput];
//        self.stillImageOutput = stillImageOutput;
//      }
      
      __weak RCTBarcodeScannerManager *weakSelf = self;
      [self setRuntimeErrorHandlingObserver:[NSNotificationCenter.defaultCenter addObserverForName:AVCaptureSessionRuntimeErrorNotification object:self.session queue:nil usingBlock:^(NSNotification *note) {
        RCTBarcodeScannerManager *strongSelf = weakSelf;
        dispatch_async(strongSelf.sessionQueue, ^{
          // Manually restarting the session since it must have been stopped due to an error.
          [strongSelf.session startRunning];
        });
      }]];
      
      [self.session startRunning];
    });
  }
  return self;
}

RCT_EXPORT_METHOD(checkDeviceAuthorizationStatus:(RCTResponseSenderBlock) callback)
{
  NSString *mediaType = AVMediaTypeVideo;
  
  [AVCaptureDevice requestAccessForMediaType:mediaType completionHandler:^(BOOL granted) {
    callback(@[[NSNull null], @(granted)]);
  }];
}


RCT_EXPORT_METHOD(changeCamera:(NSInteger)camera) {
  AVCaptureDevice *currentCaptureDevice = [self.captureDeviceInput device];
  AVCaptureDevicePosition position = (AVCaptureDevicePosition)camera;
  AVCaptureDevice *captureDevice = [self deviceWithMediaType:AVMediaTypeVideo preferringPosition:(AVCaptureDevicePosition)position];
  
  NSError *error = nil;
  AVCaptureDeviceInput *captureDeviceInput = [AVCaptureDeviceInput deviceInputWithDevice:captureDevice error:&error];
  
  if (error)
  {
    NSLog(@"%@", error);
  }
  
  [self.session beginConfiguration];
  
  [self.session removeInput:self.captureDeviceInput];
  
  if ([self.session canAddInput:captureDeviceInput])
  {
    [NSNotificationCenter.defaultCenter removeObserver:self name:AVCaptureDeviceSubjectAreaDidChangeNotification object:currentCaptureDevice];
    
    //            [self setFlashMode:AVCaptureFlashModeAuto forDevice:captureDevice];
    
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(subjectAreaDidChange:) name:AVCaptureDeviceSubjectAreaDidChangeNotification object:captureDevice];
    [self.session addInput:captureDeviceInput];
    self.captureDeviceInput = captureDeviceInput;
  }
  else
  {
    [self.session addInput:self.captureDeviceInput];
  }
  
  [self.session commitConfiguration];
}

RCT_EXPORT_METHOD(changeAspect:(NSString *)aspect) {
  self.previewLayer.videoGravity = aspect;
}

RCT_EXPORT_METHOD(changeOrientation:(NSInteger)orientation) {
  self.previewLayer.connection.videoOrientation = orientation;
}

RCT_EXPORT_METHOD(takePicture:(RCTResponseSenderBlock)callback) {
  [[self.stillImageOutput connectionWithMediaType:AVMediaTypeVideo] setVideoOrientation:self.previewLayer.connection.videoOrientation];
  [self.stillImageOutput captureStillImageAsynchronouslyFromConnection:[self.stillImageOutput connectionWithMediaType:AVMediaTypeVideo] completionHandler:^(CMSampleBufferRef imageDataSampleBuffer, NSError *error) {
    
    if (imageDataSampleBuffer)
    {
      NSData *imageData = [AVCaptureStillImageOutput jpegStillImageNSDataRepresentation:imageDataSampleBuffer];
      UIImage *image = [UIImage imageWithData:imageData];
      UIImage *rotatedImage = [image resizedImage:CGSizeMake(image.size.width, image.size.height) interpolationQuality:kCGInterpolationDefault];
      NSString *imageBase64 = [UIImageJPEGRepresentation(rotatedImage, 1.0) base64EncodedStringWithOptions:0];
      callback(@[[NSNull null], imageBase64]);
    }
    else {
      callback(@[RCTMakeError(error.description, nil, nil)]);
    }
  }];
}

RCT_EXPORT_METHOD(startScanning:(RCTResponseSenderBlock)callback) {
  self.callback = callback;
}

RCT_EXPORT_METHOD(stopScanning) {
  return;
}

- (AVCaptureDevice *)deviceWithMediaType:(NSString *)mediaType preferringPosition:(AVCaptureDevicePosition)position
{
  NSArray *devices = [AVCaptureDevice devicesWithMediaType:mediaType];
  AVCaptureDevice *captureDevice = [devices firstObject];
  
  for (AVCaptureDevice *device in devices)
  {
    if ([device position] == position)
    {
      captureDevice = device;
      break;
    }
  }
  
  return captureDevice;
}


- (void)setFlashMode:(AVCaptureFlashMode)flashMode forDevice:(AVCaptureDevice *)device
{
  if (device.hasFlash && [device isFlashModeSupported:flashMode])
  {
    NSError *error = nil;
    if ([device lockForConfiguration:&error])
    {
      [device setFlashMode:flashMode];
      [device unlockForConfiguration];
    }
    else
    {
      NSLog(@"%@", error);
    }
  }
}

- (void)subjectAreaDidChange:(NSNotification *)notification
{
  CGPoint devicePoint = CGPointMake(.5, .5);
  [self focusWithMode:AVCaptureFocusModeContinuousAutoFocus exposeWithMode:AVCaptureExposureModeContinuousAutoExposure atDevicePoint:devicePoint monitorSubjectAreaChange:NO];
}

- (void)focusWithMode:(AVCaptureFocusMode)focusMode exposeWithMode:(AVCaptureExposureMode)exposureMode atDevicePoint:(CGPoint)point monitorSubjectAreaChange:(BOOL)monitorSubjectAreaChange
{
  dispatch_async([self sessionQueue], ^{
    AVCaptureDevice *device = [[self captureDeviceInput] device];
    NSError *error = nil;
    if ([device lockForConfiguration:&error])
    {
      // prioritize the focus on objects near to the device
      if ([device respondsToSelector:@selector(isAutoFocusRangeRestrictionSupported)] &&
          device.isAutoFocusRangeRestrictionSupported) {
        device.autoFocusRangeRestriction = AVCaptureAutoFocusRangeRestrictionNear;
      }
      // focus on the center of the image
      if ([device isFocusPointOfInterestSupported] && [device isFocusModeSupported:focusMode])
      {
        [device setFocusMode:focusMode];
        [device setFocusPointOfInterest:point];
      }
      if ([device isExposurePointOfInterestSupported] && [device isExposureModeSupported:exposureMode])
      {
        [device setExposureMode:exposureMode];
        [device setExposurePointOfInterest:point];
      }
      [device setSubjectAreaChangeMonitoringEnabled:monitorSubjectAreaChange];
      [device unlockForConfiguration];
    }
    else
    {
      NSLog(@"%@", error);
    }
  });
}

#pragma mark - Default Values

- (NSArray *)defaultMetaDataObjectTypes {
  NSMutableArray *types = [@[AVMetadataObjectTypeQRCode,
                             AVMetadataObjectTypeUPCECode,
                             AVMetadataObjectTypeCode39Code,
                             AVMetadataObjectTypeCode39Mod43Code,
                             AVMetadataObjectTypeEAN13Code,
                             AVMetadataObjectTypeEAN8Code,
                             AVMetadataObjectTypeCode93Code,
                             AVMetadataObjectTypeCode128Code,
                             AVMetadataObjectTypePDF417Code,
                             AVMetadataObjectTypeAztecCode] mutableCopy];

  if (floor(NSFoundationVersionNumber) > NSFoundationVersionNumber_iOS_7_1) {
    [types addObjectsFromArray:@[
                                 AVMetadataObjectTypeInterleaved2of5Code,
                                 AVMetadataObjectTypeITF14Code,
                                 AVMetadataObjectTypeDataMatrixCode
                                 ]];
  }

  return types;
}

#pragma mark - AVCaptureMetadataOutputObjects Delegate

- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputMetadataObjects:(NSArray *)metadataObjects fromConnection:(AVCaptureConnection *)connection {

  NSMutableArray *codes = [[NSMutableArray alloc] init];

  for (AVMetadataObject *metaData in metadataObjects) {
    AVMetadataMachineReadableCodeObject *barCodeObject = (AVMetadataMachineReadableCodeObject *)[self.previewLayer transformedMetadataObjectForMetadataObject:(AVMetadataMachineReadableCodeObject *)metaData];
    if (barCodeObject) {
      [codes addObject:barCodeObject];
      NSLog(@"%@", barCodeObject.description);
      [self.bridge.eventDispatcher sendDeviceEventWithName:@"scanned" body: barCodeObject.stringValue];
      break;
    }
  }

//  if (self.callback) {
//    self.callback(codes);
//  }
}

@end
