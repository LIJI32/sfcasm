#import "SFCBinaryOperator.h"

@implementation SFCBinaryOperator
{
    SFCValue *(^_block)(SFCValue *first, SFCValue *second, NSString __strong **error);
}

+ (instancetype)operatorWithBlock:(SFCValue *(^)(SFCValue *, SFCValue *, NSString __strong  **))block
                           symbol:(NSString *)symbol
                         priority:(int)priority
{
    SFCBinaryOperator *ret = [[self alloc] init];
    ret->_block = block;
    ret->_symbol = symbol;
    ret->_priority = priority;
    return ret;
}

- (SFCValue *)performWith:(SFCValue *)first and:(SFCValue *)second error:(NSString *__strong *)error
{
    if (first.isMissingSymbolsSet || second.isMissingSymbolsSet) {
        NSMutableSet *set = nil;
        if (!second.isMissingSymbolsSet) {
            set = (id)first.missingSymbolsSet;
        }
        else if (!first.isMissingSymbolsSet) {
            set = (id)second.missingSymbolsSet;
        }
        else {
            set = first.missingSymbolsSet.mutableCopy;
            [set unionSet:second.missingSymbolsSet];
        }
        
        return [SFCValue valueWithMissingSymbolsSet:set expression:[NSString stringWithFormat:@"(%@)%@(%@)", first.expressionValue, self.symbol, second.expressionValue]];
    }
    
    NSString *dummy;
    if (!error) {
        error = &dummy;
    }
    *error = nil;
    assert(_block);
    SFCValue *ret = _block(first, second, error);
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
    return [self.class operatorWithBlock:_block
                                  symbol:symbol
                                priority:_priority];
}
@end
