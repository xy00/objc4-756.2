//
//  SubMethodTest.h
//  objc-debug
//
//  Created by xy00 on 2020/6/8.
//

#import "MethodTest.h"

NS_ASSUME_NONNULL_BEGIN

@interface SubMethodTest : MethodTest <NSObject>
{
    NSInteger _test2;
}

@property (nonatomic, assign) NSInteger index;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong) SubMethodTest *methodTest;

- (void)method1;
- (void)method2;

- (void)hi:(NSString *)name;

@end

NS_ASSUME_NONNULL_END
