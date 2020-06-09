// TEST_CRASHES
/*
TEST_RUN_OUTPUT
Associated object is 0x[0-9a-fA-F]+
objc\[\d+\]: objc_setAssociatedObject called on instance \(0x[0-9a-fA-F]+\) of class ForbiddenSubclass which does not allow associated objects
objc\[\d+\]: HALTED
END
*/

#include "associationForbidden.h"

void test(void)
{
    ShouldSucceed([Normal alloc]);
    Class ForbiddenSubclass = objc_allocateClassPair([Forbidden class],
                                                     "ForbiddenSubclass", 0);
    objc_registerClassPair(ForbiddenSubclass);
    ShouldFail([ForbiddenSubclass alloc]);
}
