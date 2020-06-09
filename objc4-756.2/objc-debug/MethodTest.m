//
//  MethodTest.m
//  objc-debug
//
//  Created by 刘光辉(健康互联网) on 2020/6/8.
//

#import "MethodTest.h"

@implementation MethodTest

- (void)method1
{
    NSLog(@"class: %@ method: %@", self.className, NSStringFromSelector(_cmd));
}

+ (void)method11
{
    NSLog(@"class: %@ method: %@", self.className, NSStringFromSelector(_cmd));
}

@end
