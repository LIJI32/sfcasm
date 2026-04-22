#import <Foundation/Foundation.h>
#import "SFCValue.h"

@interface SFCBinaryOperator : NSObject
+ (instancetype)operatorWithBlock:(SFCValue *(^)(SFCValue *first, SFCValue *second, NSString __strong **error))block symbol:(NSString *)symbol priority:(signed)priority;
@property (readonly) NSString *symbol;
@property (readonly) signed priority;
- (SFCValue *)performWith:(SFCValue *)first and:(SFCValue *)second error:(NSString __strong **)error;
- (instancetype) aliasedOperatorWithSymbol:(NSString *)symbol;
@end
