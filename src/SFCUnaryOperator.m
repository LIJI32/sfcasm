#import "SFCUnaryOperator.h"

@implementation SFCUnaryOperator
{
    SFCValue *(^_block)(SFCValue *, NSString __strong **error);
}

+ (instancetype)operatorWithBlock:(SFCValue *(^)(SFCValue *input, NSString __strong **error))block symbol:(NSString *)symbol
{
    SFCUnaryOperator *ret = [[self alloc] init];
    ret->_block = block;
    ret->_symbol = symbol;
    return ret;
    
}

- (SFCValue *)performWith:(SFCValue *)input isRight:(bool)right error:(NSString __strong **)error
{
    if (input.isMissingSymbolsSet) {
        if (right) {
            return [SFCValue valueWithMissingSymbolsSet:input.missingSymbolsSet
                                             expression:[NSString stringWithFormat:@"(%@)%@", input.expressionValue, self.symbol]];
        }
        return [SFCValue valueWithMissingSymbolsSet:input.missingSymbolsSet
                                         expression:[NSString stringWithFormat:@"%@(%@)", self.symbol, input.expressionValue]];
    }
    NSString *dummy;
    if (!error) {
        error = &dummy;
    }
    *error = nil;
    SFCValue *ret = _block(input, error);
    if (ret && ret.isDouble) {
        if (ret.doubleValue == INFINITY) {
            *error = @"Number too large";
            return nil;
        }
        if (ret.doubleValue == -INFINITY) {
            *error = @"Number too small";
            return nil;
        }
        if (ret.doubleValue == NAN) {
            *error = @"Not a number";
            return nil;
        }
    }
    return ret;
}

- (instancetype) aliasedOperatorWithSymbol:(NSString *)symbol
{
    return [self.class operatorWithBlock:_block symbol:symbol];
}

@end
