#import "YCVirtualDisplayBridge.h"

static NSString *const YCVirtualDisplayErrorDomain = @"com.yingchui.interconnect.virtual-display";

typedef id _Nullable (*YCObjectInitializer)(id, SEL, id);
typedef id _Nullable (*YCModeInitializer)(id, SEL, NSUInteger, NSUInteger, double);
typedef BOOL (*YCSettingsApplicator)(id, SEL, id);

static NSError *YCDisplayError(NSInteger code, NSString *description) {
    return [NSError errorWithDomain:YCVirtualDisplayErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

@interface YCVirtualDisplayBridge ()

@property(nonatomic, strong) id descriptor;
@property(nonatomic, strong) id settings;
@property(nonatomic, strong) id display;
@property(nonatomic) CGDirectDisplayID mirroredPhysicalDisplayID;
@property(nonatomic, readwrite) CGDirectDisplayID displayID;

@end

@implementation YCVirtualDisplayBridge

+ (BOOL)isSupported {
    NSDictionary<NSString *, NSArray<NSString *> *> *requirements = @{
        @"CGVirtualDisplayDescriptor": @[@"setVendorID:", @"setProductID:", @"setSerialNum:",
            @"setName:", @"setMaxPixelsWide:", @"setMaxPixelsHigh:", @"setSizeInMillimeters:",
            @"setRedPrimary:", @"setGreenPrimary:", @"setBluePrimary:", @"setWhitePoint:", @"setQueue:"],
        @"CGVirtualDisplay": @[@"initWithDescriptor:", @"applySettings:", @"displayID"],
        @"CGVirtualDisplayMode": @[@"initWithWidth:height:refreshRate:"],
        @"CGVirtualDisplaySettings": @[@"setHiDPI:", @"setModes:"]
    };
    for (NSString *name in requirements) {
        Class cls = NSClassFromString(name);
        if (cls == Nil) { return NO; }
        for (NSString *selector in requirements[name]) {
            if (![cls instancesRespondToSelector:NSSelectorFromString(selector)]) { return NO; }
        }
    }
    return YES;
}

- (nullable instancetype)initWithPixelWidth:(NSUInteger)pixelWidth
                                pixelHeight:(NSUInteger)pixelHeight
                                refreshRate:(double)refreshRate
                                      error:(NSError **)error {
    self = [super init];
    if (self == nil) {
        return nil;
    }

    @try {
    if (pixelWidth < 2 || pixelHeight < 2 || pixelWidth % 2 != 0 || pixelHeight % 2 != 0) {
        if (error != NULL) {
            *error = YCDisplayError(1, @"虚拟显示器像素尺寸必须为正偶数");
        }
        return nil;
    }

    Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class displayClass = NSClassFromString(@"CGVirtualDisplay");
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
    if (![self.class isSupported]) {
        if (error != NULL) {
            *error = YCDisplayError(2, @"当前 macOS 不支持虚拟显示器接口");
        }
        return nil;
    }

    id descriptor = [descriptorClass new];
    [descriptor setValue:@(0x5943) forKey:@"vendorID"];
    [descriptor setValue:@(0x4950) forKey:@"productID"];
    uint32_t serialNumber = ((uint32_t)(pixelWidth & 0xFFFF) << 16)
        ^ (uint32_t)(pixelHeight & 0xFFFF);
    if (serialNumber == 0) {
        serialNumber = 1;
    }
    [descriptor setValue:@(serialNumber) forKey:@"serialNum"];
    [descriptor setValue:@"鹰锤互联 iPad Retina" forKey:@"name"];
    [descriptor setValue:@(pixelWidth) forKey:@"maxPixelsWide"];
    [descriptor setValue:@(pixelHeight) forKey:@"maxPixelsHigh"];

    const double millimetersPerPixel = 25.4 / 220.0;
    const CGSize physicalSize = CGSizeMake(
        (double)pixelWidth * millimetersPerPixel,
        (double)pixelHeight * millimetersPerPixel
    );
    [descriptor setValue:[NSValue valueWithSize:physicalSize] forKey:@"sizeInMillimeters"];
    [descriptor setValue:[NSValue valueWithPoint:NSMakePoint(0.6797, 0.3203)] forKey:@"redPrimary"];
    [descriptor setValue:[NSValue valueWithPoint:NSMakePoint(0.2559, 0.6983)] forKey:@"greenPrimary"];
    [descriptor setValue:[NSValue valueWithPoint:NSMakePoint(0.1494, 0.0557)] forKey:@"bluePrimary"];
    [descriptor setValue:[NSValue valueWithPoint:NSMakePoint(0.3125, 0.3291)] forKey:@"whitePoint"];
    [descriptor setValue:dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0) forKey:@"queue"];

    const SEL displayInitializerSelector = NSSelectorFromString(@"initWithDescriptor:");
    id allocatedDisplay = [displayClass alloc];
    YCObjectInitializer displayInitializer =
        (YCObjectInitializer)[allocatedDisplay methodForSelector:displayInitializerSelector];
    id display = displayInitializer(allocatedDisplay, displayInitializerSelector, descriptor);
    if (display == nil) {
        if (error != NULL) {
            *error = YCDisplayError(3, @"虚拟显示器实例创建失败");
        }
        return nil;
    }

    // 首个模式必须与描述符的最大像素尺寸一致，系统才会把它作为首选
    // Retina 帧缓冲区，并呈现为一半宽高的逻辑点。
    const NSUInteger logicalWidth = pixelWidth / 2;
    const NSUInteger logicalHeight = pixelHeight / 2;
    const SEL modeInitializerSelector = NSSelectorFromString(@"initWithWidth:height:refreshRate:");
    NSMutableArray *modes = [NSMutableArray arrayWithCapacity:2];
    for (NSValue *sizeValue in @[
        [NSValue valueWithSize:NSMakeSize(pixelWidth, pixelHeight)],
        [NSValue valueWithSize:NSMakeSize(logicalWidth, logicalHeight)]
    ]) {
        const NSSize size = sizeValue.sizeValue;
        id allocatedMode = [modeClass alloc];
        YCModeInitializer modeInitializer =
            (YCModeInitializer)[allocatedMode methodForSelector:modeInitializerSelector];
        id mode = modeInitializer(
            allocatedMode,
            modeInitializerSelector,
            (NSUInteger)size.width,
            (NSUInteger)size.height,
            refreshRate
        );
        if (mode == nil) {
            if (error != NULL) {
                *error = YCDisplayError(
                    4,
                    [NSString stringWithFormat:
                        @"虚拟显示器 Retina 模式创建失败：%lu×%lu",
                        (unsigned long)size.width,
                        (unsigned long)size.height]
                );
            }
            return nil;
        }
        [modes addObject:mode];
    }

    id settings = [settingsClass new];
    [settings setValue:@(1) forKey:@"hiDPI"];
    [settings setValue:modes forKey:@"modes"];
    const SEL applySelector = NSSelectorFromString(@"applySettings:");
    YCSettingsApplicator applySettings =
        (YCSettingsApplicator)[display methodForSelector:applySelector];
    if (!applySettings(display, applySelector, settings)) {
        if (error != NULL) {
            *error = YCDisplayError(
                5,
                [NSString stringWithFormat:
                    @"虚拟显示器 Retina 配置应用失败：目标 %lu×%lu 像素",
                    (unsigned long)pixelWidth,
                    (unsigned long)pixelHeight]
            );
        }
        return nil;
    }

    NSNumber *displayIDValue = [display valueForKey:@"displayID"];
    const CGDirectDisplayID displayID = displayIDValue.unsignedIntValue;
    if (displayID == kCGNullDirectDisplay) {
        if (error != NULL) {
            *error = YCDisplayError(6, @"虚拟显示器没有有效的显示编号");
        }
        return nil;
    }

    self.descriptor = descriptor;
    self.settings = settings;
    self.display = display;
    self.displayID = displayID;
    return self;
    } @catch (NSException *exception) {
        if (error != NULL) {
            *error = YCDisplayError(9, [NSString stringWithFormat:@"虚拟显示器接口不兼容：%@", exception.reason]);
        }
        return nil;
    }
}

- (BOOL)mirrorPhysicalDisplay:(CGDirectDisplayID)physicalDisplayID
                        error:(NSError **)error {
    if (physicalDisplayID == kCGNullDirectDisplay || self.displayID == kCGNullDirectDisplay) {
        if (error != NULL) {
            *error = YCDisplayError(7, @"镜像显示器编号无效");
        }
        return NO;
    }

    CGDisplayConfigRef configuration = NULL;
    CGError status = CGBeginDisplayConfiguration(&configuration);
    if (status == kCGErrorSuccess) {
        status = CGConfigureDisplayMirrorOfDisplay(
            configuration,
            physicalDisplayID,
            self.displayID
        );
    }
    if (status == kCGErrorSuccess) {
        status = CGCompleteDisplayConfiguration(configuration, kCGConfigureForSession);
        configuration = NULL;
    }
    if (configuration != NULL) {
        CGCancelDisplayConfiguration(configuration);
    }
    if (status != kCGErrorSuccess) {
        if (error != NULL) {
            *error = YCDisplayError(8, [NSString stringWithFormat:@"显示器镜像配置失败（%d）", status]);
        }
        return NO;
    }

    self.mirroredPhysicalDisplayID = physicalDisplayID;
    return YES;
}

- (void)invalidate {
    // 原始显示模式和镜像拓扑由 MacVirtualDisplayManager 在释放之前事务式恢复。
    self.mirroredPhysicalDisplayID = kCGNullDirectDisplay;
    self.displayID = kCGNullDirectDisplay;
    self.display = nil;
    self.settings = nil;
    self.descriptor = nil;
}

- (void)dealloc {
    [self invalidate];
}

@end
