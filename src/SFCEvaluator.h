#import <Foundation/Foundation.h>
#import "SFCValue.h"
#import "SFCUnaryOperator.h"
#import "SFCBinaryOperator.h"


@interface SFCEvaluator : NSObject
- (void)setVariable:(NSString *)variable withValue:(SFCValue *)value;
- (SFCValue *)getVariable:(NSString *)variable;
- (void)registerLeftUnaryOperator:(SFCUnaryOperator *)operator;
- (void)registerRightUnaryOperator:(SFCUnaryOperator *)operator;
- (void)registerBinaryOperator:(SFCBinaryOperator *)operator;
- (SFCValue *)evaluate:(NSString *)expression errorString:(NSString __strong **)errorString errorRange:(NSRange *)errorRange;
+ (instancetype)emptyEvaluator;
+ (instancetype)standardEvaluator;

@property NSString *currentScope;
@property (readonly) NSMutableDictionary<NSString *, SFCValue *> *allVariables;
@property NSMutableDictionary<NSNumber *, NSNumber *> *encoding;
@end
