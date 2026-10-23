#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface YCVirtualDisplayBridge : NSObject

@property(class, nonatomic, readonly) BOOL isSupported;
@property(nonatomic, readonly) CGDirectDisplayID displayID;

- (nullable instancetype)initWithPixelWidth:(NSUInteger)pixelWidth
                                pixelHeight:(NSUInteger)pixelHeight
                                refreshRate:(double)refreshRate
                                      error:(NSError **)error NS_DESIGNATED_INITIALIZER;

- (BOOL)mirrorPhysicalDisplay:(CGDirectDisplayID)physicalDisplayID
                        error:(NSError **)error;

- (void)invalidate;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
