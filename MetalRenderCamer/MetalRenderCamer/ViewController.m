//
//  ViewController.m
//  Metal -视频渲染
//
//  Created by a on 2020/8/27.
//  Copyright © 2020 lkm. All rights reserved.
//
@import MetalKit;
@import AVFoundation;
@import CoreMedia;
#import "ViewController.h"
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>
@interface ViewController ()<MTKViewDelegate,AVCaptureVideoDataOutputSampleBufferDelegate>
//获得MTKView
@property(nonatomic,strong)MTKView *mtkView;

//负责输入和输出设备之间的数据传递
@property(nonatomic,strong)AVCaptureSession *mCaptureSession;
//负责从AVCaptureDevice获得输入数据
@property(nonatomic,strong)AVCaptureDeviceInput *mDeviceInput;
//输出设备
@property(nonatomic,strong)AVCaptureVideoDataOutput *mVideoDataOutput;
//处理队列
@property(nonatomic,strong)dispatch_queue_t mProcessQueue;
//纹理缓存区
@property(nonatomic,assign)CVMetalTextureCacheRef textureCache;
//纹理
@property(nonatomic,strong) id<MTLTexture> texture;
// 命令队列
@property(nonatomic,strong) id<MTLCommandQueue> commandQueue;

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
   //1. setupMetal
       [self setupMetal];
       //2. setupAVFoundation
       [self setupCaptureSession];
    
}

-(void)setupMetal
{
    self.mtkView = [[MTKView alloc]initWithFrame:self.view.bounds];
    self.mtkView.device = MTLCreateSystemDefaultDevice();
    [self.view insertSubview:self.mtkView atIndex:0];
    self.mtkView.delegate = self;
    //创建d命令队列
    self.commandQueue = [self.mtkView.device newCommandQueue];
    //注意: 在初始化MTKView 的基本操作以外. 还需要多下面2行代码.
       /*
        1. 设置MTKView 的drawable 纹理是可读写的(默认是只读);
        2. 创建CVMetalTextureCacheRef _textureCache; 这是Core Video的Metal纹理缓存
        */
    //允许读写操作
    self.mtkView.framebufferOnly = NO;
    /*
    CVMetalTextureCacheCreate(CFAllocatorRef  allocator,
    CFDictionaryRef cacheAttributes,
    id <MTLDevice>  metalDevice,
    CFDictionaryRef  textureAttributes,
    CVMetalTextureCacheRef * CV_NONNULL cacheOut )
    
    功能: 创建纹理缓存区
    参数1: allocator 内存分配器.默认即可.NULL
    参数2: cacheAttributes 缓存区行为字典.默认为NULL
    参数3: metalDevice
    参数4: textureAttributes 缓存创建纹理选项的字典. 使用默认选项NULL
    参数5: cacheOut 返回时，包含新创建的纹理缓存。
    
    */
    CVMetalTextureCacheCreate(NULL, NULL, self.mtkView.device, NULL, &_textureCache);
    
}

-(void)setupCaptureSession
{
    //创建mCaptureSession
    self.mCaptureSession = [[AVCaptureSession alloc]init];
    //设置视频采集分辨率
    self.mCaptureSession.sessionPreset = AVCaptureSessionPreset1920x1080;
    //创建队列
    self.mProcessQueue = dispatch_queue_create("mProcessQueue", DISPATCH_QUEUE_SERIAL);
    //获取摄像头设备（前置/后置摄像头设备）
    NSArray *devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
    AVCaptureDevice *mCaptureDevice = nil;
    for (AVCaptureDevice *device in devices) {
        if ([device position] == AVCaptureDevicePositionBack) {
            mCaptureDevice = device;
        }
    }
    
    //将设备AVCaptureDevice 转化成AVCaptureDeviceInput (没有办法直接使用AVCaptureDevice设备)
    self.mDeviceInput = [[AVCaptureDeviceInput alloc]initWithDevice:mCaptureDevice error:nil];
    //添加设备 (和应用建立联系)
    if ([self.mCaptureSession canAddInput:self.mDeviceInput]) {
        [self.mCaptureSession addInput:self.mDeviceInput];
    }
    
    //输出设备
    self.mVideoDataOutput = [[AVCaptureVideoDataOutput alloc]init];
    /*设置视频帧延迟到底时是否丢弃数据.
        YES: 处理现有帧的调度队列在captureOutput:didOutputSampleBuffer:FromConnection:Delegate方法中被阻止时，对象会立即丢弃捕获的帧。
        NO: 在丢弃新帧之前，允许委托有更多的时间处理旧帧，但这样可能会内存增加.
        */
    [self.mVideoDataOutput setAlwaysDiscardsLateVideoFrames:NO];
    
    //这里设置格式为BGRA，而不用YUV的颜色空间，避免使用Shader转换（每一个像素点颜色保持的格式）
    //注意:这里必须和后面CVMetalTextureCacheCreateTextureFromImage 保存图像像素存储格式保持一致.否则视频会出现异常现象.
   [self.mVideoDataOutput setVideoSettings:[NSDictionary dictionaryWithObject:[NSNumber numberWithInt:kCVPixelFormatType_32BGRA] forKey:(id)kCVPixelBufferPixelFormatTypeKey]];
    // 设置视频捕捉输出的代理方法
    [self.mVideoDataOutput setSampleBufferDelegate:self queue:self.mProcessQueue];
    //添加输出
    if ([self.mCaptureSession canAddOutput:self.mVideoDataOutput] ) {
        [self.mCaptureSession addOutput:self.mVideoDataOutput];
    }
    
    //输入与输出连接
    AVCaptureConnection *connection = [self.mVideoDataOutput connectionWithMediaType:AVMediaTypeVideo];
    //设置视频方向
    [connection setVideoOrientation:(AVCaptureVideoOrientationPortrait)];
    
    //开始捕捉
    [self.mCaptureSession startRunning];
    
}

//AVFoundation 视频采集回调方法
-(void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection
{
    //从sampleBuffer  获取视频像素缓存区对象
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
      
    size_t width =CVPixelBufferGetWidth(pixelBuffer);
    size_t height = CVPixelBufferGetHeight(pixelBuffer);
    /*3. 根据视频像素缓存区 创建 Metal 纹理缓存区
        CVReturn CVMetalTextureCacheCreateTextureFromImage(CFAllocatorRef allocator,  CVMetalTextureCacheRef textureCache,
        CVImageBufferRef sourceImage,
        CFDictionaryRef textureAttributes,
        MTLPixelFormat pixelFormat,
        size_t width,
        size_t height,
        size_t planeIndex,
        CVMetalTextureRef  *textureOut);
        
        功能: 从现有图像缓冲区创建核心视频Metal纹理缓冲区。
        参数1: allocator 内存分配器,默认kCFAllocatorDefault
        参数2: textureCache 纹理缓存区对象
        参数3: sourceImage 视频图像缓冲区
        参数4: textureAttributes 纹理参数字典.默认为NULL
        参数5: pixelFormat 图像缓存区数据的Metal 像素格式常量.注意如果MTLPixelFormatBGRA8Unorm和摄像头采集时设置的颜色格式不一致，则会出现图像异常的情况；
        参数6: width,纹理图像的宽度（像素）
        参数7: height,纹理图像的高度（像素）
        参数8: planeIndex.如果图像缓冲区是平面的，则为映射纹理数据的平面索引。对于非平面图像缓冲区忽略。
        参数9: textureOut,返回时，返回创建的Metal纹理缓冲区。
        
        // Mapping a BGRA buffer:
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, pixelBuffer, NULL, MTLPixelFormatBGRA8Unorm, width, height, 0, &outTexture);
        
        // Mapping the luma plane of a 420v buffer:
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, pixelBuffer, NULL, MTLPixelFormatR8Unorm, width, height, 0, &outTexture);
        
        // Mapping the chroma plane of a 420v buffer as a source texture:
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, pixelBuffer, NULL, MTLPixelFormatRG8Unorm width/2, height/2, 1, &outTexture);
        
        // Mapping a yuvs buffer as a source texture (note: yuvs/f and 2vuy are unpacked and resampled -- not colorspace converted)
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, pixelBuffer, NULL, MTLPixelFormatGBGR422, width, height, 1, &outTexture);
        
        */
    CVMetalTextureRef tmTexture = nil;
    CVReturn status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, self.textureCache, pixelBuffer, NULL, MTLPixelFormatBGRA8Unorm, width, height, 0, &tmTexture);
    
    //判断tmTexture是否创建成功
    if (status == kCVReturnSuccess) {
        //设置绘制纹理的当前大小
        self.mtkView.drawableSize = CGSizeMake(width, height);
        //返回纹理缓存区的metal纹理对象
        self.texture = CVMetalTextureGetTexture(tmTexture);
        
        CFRelease(tmTexture);
    }
}

-(void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size
{
     
}

-(void)drawInMTKView:(MTKView *)view
{
    //判断是否获取AVFoundation采集的纹理数据
    if (self.texture) {
        //创建缓存区
        id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
        commandBuffer.label = @"mCommandBuffer";
        
        //3.将MTKView 作为目标渲染纹理
        id<MTLTexture> drawingTexture = view.currentDrawable.texture;
        /*
         MetalPerformanceShaders是Metal的一个集成库，有一些滤镜处理的Metal实现;
         MPSImageGaussianBlur 高斯模糊处理;
         */
        
        //创建高斯滤镜处理filter
        //注意:sigma值可以修改，sigma值越高图像越模糊;
        MPSImageGaussianBlur *filter = [[MPSImageGaussianBlur alloc]initWithDevice:self.mtkView.device sigma:1];
        
        //5.MPSImageGaussianBlur以一个Metal纹理作为输入，以一个Metal纹理作为输出；
               //输入:摄像头采集的图像 self.texture
               //输出:创建的纹理 drawingTexture(其实就是view.currentDrawable.texture)
        [filter encodeToCommandBuffer:commandBuffer sourceTexture:self.texture destinationTexture:drawingTexture];
        
        [commandBuffer presentDrawable:view.currentDrawable];
        [commandBuffer commit];
        self.texture = NULL;
        
    }
}
@end
