#import "YCCursorVisibility.h"
#import <CoreGraphics/CoreGraphics.h>

BOOL YCCursorIsVisible(void) {
    // ScreenCaptureKit 只能选择是否录入光标，没有提供隐藏状态的读取接口。
    // 此旧系统接口须由实机隐藏/显示回归验证；不调用私有符号。
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return CGCursorIsVisible();
#pragma clang diagnostic pop
}
