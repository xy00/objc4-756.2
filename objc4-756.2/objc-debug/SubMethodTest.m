//
//  SubMethodTest.m
//  objc-debug
//
//  Created by 刘光辉(健康互联网) on 2020/6/8.
//

#import "SubMethodTest.h"

@implementation SubMethodTest

- (void)method1
{
    NSLog(@"class: %@ method: %@", self.className, NSStringFromSelector(_cmd));
    [super method1];
}

- (void)method2
{
    NSLog(@"class: %@ method: %@", self.className, NSStringFromSelector(_cmd));
}

- (void)hi:(NSString *)name
{
    NSLog(@"hi : %@", name);
}

@end
