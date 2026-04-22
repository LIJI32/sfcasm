#import <Foundation/Foundation.h>
#import "SFCValue.h"

@interface SFCUnaryOperator : NSObject
+ (instancetype)operatorWithBlock:(SFCValue *(^)(SFCValue *input, NSString __strong **error))block symbol:(NSString *)symbol;
@property (readonly) NSString *symbol;
- (SFCValue *)performWith:(SFCValue *)input isRight:(bool)right error:(NSString __strong **)error;
- (instancetype) aliasedOperatorWithSymbol:(NSString *)symbol;
@end
