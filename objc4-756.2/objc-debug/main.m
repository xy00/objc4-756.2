//
//  main.m
//  objc-debug
//
//  Created by Cooci on 2019/10/9.
//

#import <Foundation/Foundation.h>
#import "MethodTest.h"
#import "SubMethodTest.h"
#import <objc/runtime.h>

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        // insert code here...
        NSObject *object = [NSObject alloc];
        NSLog(@"Hello, World! %@",object);
        
        MethodTest *test = [[MethodTest alloc] init];
        IMP imp1 = [test methodForSelector:@selector(method1)];
        SubMethodTest *test2 = [[SubMethodTest alloc] init];
        IMP imp2 = [test2 methodForSelector:@selector(method1)];
        
        NSLog(@"%p", imp1);
        NSLog(@"%p", imp2);
        
        [test2 method1];
        
        IMP function = imp_implementationWithBlock(^(id self, NSString *text) {
            NSLog(@"callback block : %@", text);
        });
        
        [test2 hi:@"iOSer"];
        const char *types = sel_getName(@selector(hi:));
        class_replaceMethod(SubMethodTest.class, @selector(hi:), function, types);
        
        unsigned int count = 0;
        Method *methods = class_copyMethodList(SubMethodTest.class, &count);
        for (NSInteger i=0; i<count; i++) {
            Method m = methods[i];
            const char *methoName = sel_getName(method_getName(m));
            
            char dst;
            method_getReturnType(m, &dst, sizeof(dst));
            NSString *returnType = [NSString stringWithFormat:@"%c", dst];
            unsigned int mNumber = method_getNumberOfArguments(m);
            NSString *name = [[NSString alloc] initWithCString:methoName encoding:NSUTF8StringEncoding];
            const char *encoding = method_getTypeEncoding(m);
            NSString *encodingStr = [[NSString alloc] initWithCString:encoding encoding:NSUTF8StringEncoding];
            NSLog(@"name: %@, returnType: %@, argumentsNumber: %@, encoding: %@", name, returnType, @(mNumber).stringValue, encodingStr);
            for (unsigned int index=0; index<mNumber; index++) {
                char aDst;
                method_getArgumentType(m, index, &aDst, sizeof(char));
                NSString *aType = [NSString stringWithFormat:@"%c", aDst];
                NSLog(@"Argument Type: %@", aType);
            }
        }
        SubMethodTest *test3 = [[SubMethodTest alloc] init];
        [test3 performSelector:@selector(hi:) withObject:@"iOSer"];
        
        unsigned int pCount = 0;
        objc_property_t *propertys = class_copyPropertyList(SubMethodTest.class, &pCount);
        for (NSInteger i=0; i<pCount; i++) {
            objc_property_t property = propertys[i];
            const char *pName = property_getName(property);
            NSString *name = [[NSString alloc] initWithCString:pName encoding:NSUTF8StringEncoding];
            NSLog(@"name : %@", name);
            unsigned int aCount = 0;
            objc_property_attribute_t *attributes = property_copyAttributeList(property, &aCount);
            for (unsigned int index = 0; index < aCount; index ++)
            {
                objc_property_attribute_t attribute = attributes[index];
                const char * aName = attribute.name;
                const char * aValue = attribute.value;
                NSString *aNameStr = [[NSString alloc] initWithCString:aName encoding:NSUTF8StringEncoding];
                NSString *aValueStr = [[NSString alloc] initWithCString:aValue encoding:NSUTF8StringEncoding];
                NSLog(@"name : %@, value : %@", aNameStr, aValueStr);
            }
        }
        
        unsigned int protocolCount = 0;
        Protocol * __unsafe_unretained *protocols = class_copyProtocolList(SubMethodTest.class, &protocolCount);
        for (unsigned int i=0; i<protocolCount; i++) {
            Protocol *protocol = protocols[i];
            const char *pName = protocol_getName(protocol);
            NSString *pNameSte = [[NSString alloc] initWithCString:pName encoding:NSUTF8StringEncoding];
            NSLog(@"name: %@", pNameSte);
        }
        
        unsigned int iCount = 0;
        Ivar *vars = class_copyIvarList(SubMethodTest.class, &iCount);
        for (unsigned int i=0; i<iCount; i++) {
            Ivar var = vars[i];
            NSString *name = [[NSString alloc] initWithCString:ivar_getName(var) encoding:NSUTF8StringEncoding];
            NSString *type = [[NSString alloc] initWithCString:ivar_getTypeEncoding(var) encoding:NSUTF8StringEncoding];
//            ptrdiff_t offset = ivar_getOffset(var);
            NSLog(@"name: %@, type: %@", name, type);
            
        }
        
        Class testClass = objc_allocateClassPair(SubMethodTest.class, "TestClass", 0);
        BOOL isAdded = class_addIvar(testClass, "pwd", sizeof(NSString *), log2(sizeof(NSString *)), @encode(NSString *));
        objc_registerClassPair(testClass);
        if (isAdded)
        {
            id obj = [[testClass alloc] init];
            [obj setValue:@"TEST" forKey:@"pwd"];
            NSString *value = [obj valueForKey:@"pwd"];
            NSLog(@"value: %@", value);
        }
    }
    return 0;
}
