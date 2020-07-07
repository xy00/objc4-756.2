//
//  MethodTest.h
//  objc-debug
//
//  Created by xy00 on 2020/6/8.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MethodTest : NSObject
{
    NSInteger _test1;
}

- (void)method1;
+ (void)method11;

@end

NS_ASSUME_NONNULL_END
