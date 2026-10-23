#import <Foundation/Foundation.h>

// 集中封装系统光标可见性查询，避免把旧接口散布到 Swift 业务代码。
FOUNDATION_EXPORT BOOL YCCursorIsVisible(void);
