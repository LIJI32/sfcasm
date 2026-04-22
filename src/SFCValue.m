#import "SFCValue.h"

@implementation SFCValue
{
    enum {
        TypeString,
        TypeInt,
        TypeDouble,
        TypeMissingSymbolsSet,
    } _type;
}

- (bool)isString
{
    return _type == TypeString;
}

- (bool)isInt
{
    return _type == TypeInt;
}

- (bool)isDouble
{
    return _type == TypeDouble;
}

- (bool)isMissingSymbolsSet
{
    return _type == TypeMissingSymbolsSet;
}

+ (instancetype)valueWithString:(NSString *)string
{
    assert(string);
    SFCValue *ret = [[self alloc] init];
    ret->_type = TypeString;
    ret->_stringValue = string.copy;
    ret->_dataValue = [string dataUsingEncoding:NSUTF8StringEncoding];
    NSString *escaped = [[string stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""] stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    ret->_expressionValue = [NSString stringWithFormat:@"\"%@\"", escaped];
    return ret;
}

+ (instancetype)valueWithData:(NSData *)data
{
    assert(data);
    SFCValue *ret = [[self alloc] init];
    ret->_type = TypeString;
    ret->_stringValue = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"<Invalid UTF-8 String>";
    ret->_dataValue = data.copy;
    NSMutableString *expression = [@"\"" mutableCopy];
    const uint8_t *bytes = data.bytes;
    size_t length = data.length;
    while (length) {
        [expression appendFormat:@"\\x%02x", *bytes];
        bytes++;
        length--;
    }
    [expression appendString:@"\""];
    ret->_expressionValue = expression;
    return ret;
}

+ (instancetype)valueWithInt:(int64_t)number
{
    SFCValue *ret = [[self alloc] init];
    ret->_type = TypeInt;
    ret->_intValue = number;
    ret->_doubleValue = number;
    ret->_expressionValue = [NSString stringWithFormat:@"0x%llx", number];
    return ret;
}

+ (instancetype)valueWithDouble:(double)number
{
    SFCValue *ret = [[self alloc] init];
    ret->_type = TypeDouble;
    ret->_intValue = number;
    ret->_doubleValue = number;
    // TODO: introduces dataloss
    ret->_expressionValue = [NSString stringWithFormat:@"%f", number];
    return ret;
}

+ (instancetype)valueWithMissingSymbolsSet:(NSSet<NSString *> *)missingSymbolsSet expression:(NSString *)expression
{
    assert(missingSymbolsSet);
    SFCValue *ret = [[self alloc] init];
    ret->_type = TypeMissingSymbolsSet;
    ret->_missingSymbolsSet = missingSymbolsSet.copy;
    ret->_expressionValue = expression;
    return ret;
}

- (NSString *)description
{
    if (_stringValue) {
        if (![_stringValue containsString:@"\""] && ![_stringValue containsString:@"\\"] && ![_stringValue isEqual: @"<Invalid UTF-8 String>"]) {
            return [NSString stringWithFormat:@"\"%@\"", _stringValue];
        }
    }
    return _expressionValue;
}

@end
