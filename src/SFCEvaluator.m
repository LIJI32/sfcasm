#import "SFCEvaluator.h"
#import "NSString+SFC.h"
#import <ctype.h>

#define SafeOp(operator) \
if (first.isString || second.isString) {\
*error = @"Invalid operation on a string argument";\
return nil;\
}\
if (first.isDouble || second.isDouble) {\
return [SFCValue valueWithDouble:first.doubleValue operator second.doubleValue];\
}\
return [SFCValue valueWithInt:first.intValue operator second.intValue];

#define SafeBoolOp(operator) \
if (first.isString || second.isString) {\
*error = @"Invalid operation on a string argument";\
return nil;\
}\
if (first.isDouble || second.isDouble) {\
return [SFCValue valueWithInt:first.doubleValue operator second.doubleValue];\
}\
return [SFCValue valueWithInt:first.intValue operator second.intValue];


@implementation SFCEvaluator
{
    NSMutableDictionary<NSString *, SFCValue *> *_variables;
    NSMutableSet<SFCUnaryOperator *> *_leftUnaryOperators;
    NSMutableSet<SFCUnaryOperator *> *_rightUnaryOperators;
    NSMutableSet<SFCBinaryOperator *> *_binaryOperators;

}

- (bool)verifyAlphaTokenInString:(NSString *)string andRange:(NSRange)range
{
    static NSMutableCharacterSet *alpha = nil;
    if (!alpha) {
        alpha = [NSMutableCharacterSet letterCharacterSet];
        [alpha addCharactersInString:@"._"];
    }
    if (range.location != 0) {
        if ([alpha characterIsMember:[string characterAtIndex:range.location]] &&
            [alpha characterIsMember:[string characterAtIndex:range.location - 1]]) {
            return false;
        }
    }
    
    if (range.location + range.length != string.length) {
        if ([alpha characterIsMember:[string characterAtIndex:range.location + range.length - 1]] &&
            [alpha characterIsMember:[string characterAtIndex:range.location + range.length]]) {
            return false;
        }
    }
    return true;
}

- (bool)verifyOperatorIsNotUnaryInExpression:(NSString *)expression range:(NSRange)range operatorRange:(NSRange)operatorRange
{
    NSString *operatorString = [expression substringWithRange:operatorRange];
    for (SFCUnaryOperator *op in _leftUnaryOperators) {
        if ([op.symbol isEqualToString:operatorString]) {
            NSRange leftRange = {range.location, operatorRange.location - range.location};
            while (leftRange.length && [[NSCharacterSet whitespaceCharacterSet] characterIsMember:[expression characterAtIndex:leftRange.location + leftRange.length - 1]]) {
                leftRange.length--;
            }
            if (leftRange.length == 0) {
                // Not left side at all
                return false;
            }
            NSString *left = [expression substringWithRange:leftRange];
            // Make sure the left side does not end with a binary operator or another left-unary operator
            for (SFCBinaryOperator *op in _binaryOperators) {
                if ([left hasSuffix:op.symbol] &&
                    [self verifyAlphaTokenInString:expression andRange:(NSRange){leftRange.location + leftRange.length - op.symbol.length, op.symbol.length}]) {
                    return false;
                }
            }
            
            for (SFCUnaryOperator *op in _leftUnaryOperators) {
                if ([left hasSuffix:op.symbol] &&
                    [self verifyAlphaTokenInString:expression andRange:(NSRange){leftRange.location + leftRange.length - op.symbol.length, op.symbol.length}]) {
                    return false;
                }
            }
            
            break;
        }
    }
    
    for (SFCUnaryOperator *op in _rightUnaryOperators) {
        if ([op.symbol isEqualToString:operatorString]) {
            NSRange rightRange = {operatorRange.location + operatorRange.length, range.location + range.length - operatorRange.location - operatorRange.length};
            while (rightRange.length && [[NSCharacterSet whitespaceCharacterSet] characterIsMember:[expression characterAtIndex:0]]) {
                rightRange.length--;
                rightRange.location++;
            }
            if (rightRange.length == 0) {
                // Not right side at all
                return false;
            }
            NSString *right = [expression substringWithRange:rightRange];
            // Make sure the right side does not start with a binary operator or another right-unary operator
            for (SFCBinaryOperator *op in _binaryOperators) {
                if ([right hasPrefix:op.symbol] &&
                    [self verifyAlphaTokenInString:expression andRange:(NSRange){rightRange.location, op.symbol.length}]) {
                    return false;
                }
            }
            
            for (SFCUnaryOperator *op in _rightUnaryOperators) {
                if ([right hasPrefix:op.symbol] &&
                    [self verifyAlphaTokenInString:expression andRange:(NSRange){rightRange.location, op.symbol.length}]) {
                    return false;
                }
            }
            
            break;
        }
    }
    return true;
}

- (void)setVariable:(NSString *)variable withValue:(SFCValue *)value
{
    if (!_variables) {
        _variables = [NSMutableDictionary dictionary];
    }
    _variables[variable] = value;
}

- (SFCValue *)getVariable:(NSString *)variable
{
    if (_currentScope && [variable hasPrefix:@"."] && variable.length != 1) {
        variable = [_currentScope stringByAppendingString:variable];
    }
    return _variables[variable];
}

- (void)registerLeftUnaryOperator:(SFCUnaryOperator *)operator
{
    if (!_leftUnaryOperators) {
        _leftUnaryOperators = [NSMutableSet set];
    }
    [_leftUnaryOperators addObject:operator];
}

- (void)registerRightUnaryOperator:(SFCUnaryOperator *)operator
{
    if (!_rightUnaryOperators) {
        _rightUnaryOperators = [NSMutableSet set];
    }
    [_rightUnaryOperators addObject:operator];
}

- (void)registerBinaryOperator:(SFCBinaryOperator *)operator
{
    if (!_binaryOperators) {
        _binaryOperators = [NSMutableSet set];
    }
    [_binaryOperators addObject:operator];
}

- (SFCValue *)evaluate:(NSString *)expression errorString:(NSString __strong **)errorString errorRange:(NSRange *)errorRange
{
    NSString *dummyString;
    if (!errorString) {
        errorString = &dummyString;
    }
    NSRange dummyRange;
    if (!errorRange) {
        errorRange = &dummyRange;
    }
    
    *errorString = nil;
    errorRange->location = NSNotFound;
    
    SFCValue *ret = [self evaluate:expression range:NSMakeRange(0, expression.length) errorString:errorString errorRange:errorRange];
    if (ret.isSymbol) {
        return [SFCValue valueWithInt:ret.intValue];
    }
    
    return ret;
}

- (SFCValue *)evaluate:(NSString *)expression range:(NSRange)range errorString:(NSString __strong **)errorString errorRange:(NSRange *)errorRange
{
    while (range.length && [[NSCharacterSet whitespaceCharacterSet] characterIsMember:[expression characterAtIndex:range.location]]) {
        range.location += 1;
        range.length -= 1;
    }
    
    while (range.length && [[NSCharacterSet whitespaceCharacterSet] characterIsMember:[expression characterAtIndex:range.location + range.length - 1]]) {
        range.length -= 1;
    }
    
    if (range.length == 0) {
        *errorString = @"Expected expression";
        *errorRange = range;
        return nil;
    }
    NSString *subExpression = [expression substringWithRange:range];
    
    unsigned leftCount = subExpression.length - [subExpression stringByReplacingOccurrencesOfString:@"(" withString:@""].length;
    unsigned rightCount = subExpression.length - [subExpression stringByReplacingOccurrencesOfString:@")" withString:@""].length;
    
    unsigned depth = 0;
    unichar quote = 0;
    SFCBinaryOperator *bestOp = nil;
    unsigned opLocation = -1;
    bool canStripParen = true;
    for (unsigned i = range.location; i < range.location + range.length; i++) {
        unichar c = [expression characterAtIndex:i];
        if (quote) {
            if (c == quote) {
                quote = 0;
            }
            else if (c == '\\') {
                i++;
            }
            continue;
        }
        if (c == '"' || c == '\'') {
            quote = c;
            continue;
        }
        if (c == '(') {
            depth++;
            if (leftCount > rightCount) {
                if (depth == leftCount - rightCount) {
                    *errorString =  @"Unmatched '('";
                    *errorRange = NSMakeRange(i, 1);
                }
            }
            continue;
        }
        if (c == ')') {
            if (depth) {
                depth--;
                if (depth == 0 && i != range.location + range.length - 1) {
                    canStripParen = false;
                }
                continue;
            }
            *errorString =  @"Unmatched ')'";
            *errorRange = (NSRange){i, 1};
            return nil;
        }
        if (depth == 0 && leftCount == rightCount) {
            for (SFCBinaryOperator *op in _binaryOperators) {
                if (bestOp && i <= opLocation && i + op.symbol.length >= opLocation + bestOp.symbol.length) {
                    // The best op is completely overlapping this opcode, ignore priority checks
                    goto skipChecks;
                }
                if (bestOp && op.priority > bestOp.priority) {
                    continue;
                }
                if (bestOp && i >= opLocation && i + op.symbol.length <= opLocation + bestOp.symbol.length) {
                    continue;
                }
                skipChecks:
                // Avoid parsing + and - inside scientific notation as operators
                if ([op.symbol isEqualToString:@"+"] || [op.symbol isEqualToString:@"-"]) {
                    if (i >= 2 && expression.length >= i + 2) {
                        if ([[NSCharacterSet decimalDigitCharacterSet] characterIsMember:[expression characterAtIndex:i - 2]] &&
                            [expression characterAtIndex:i - 1] == 'e' &&
                            [[NSCharacterSet decimalDigitCharacterSet] characterIsMember:[expression characterAtIndex:i + 1]] &&
                            ![subExpression hasPrefix:@"0x"]) {
                            continue;
                        }
                    }
                }
                if ([[expression substringFromIndex:i] hasPrefix:op.symbol] &&
                    [self verifyAlphaTokenInString:expression andRange:(NSRange){i, op.symbol.length}] &&
                    [self verifyOperatorIsNotUnaryInExpression:expression range:range operatorRange:(NSRange){i, op.symbol.length}]) {
                    bestOp = op;
                    opLocation = i;
                }
            }
        }
    }
    
    if (quote) {
        *errorRange = range;
        *errorString = quote == '"'? @"Unterminated string literal" : @"Unterminated character literal";
        return nil;
    }
    
    if (leftCount > rightCount) {
        return nil;
    }
    
    if (canStripParen && [subExpression hasPrefix:@"("] && [subExpression hasSuffix:@")"]) {
        return [self evaluate:expression range:NSMakeRange(range.location + 1, range.length - 2) errorString:errorString errorRange:errorRange];
    }
    
    if (bestOp) {
        NSRange leftRange = NSMakeRange(range.location, opLocation - range.location);
        NSRange rightRange = NSMakeRange(opLocation + bestOp.symbol.length,
                                         range.location + range.length - (opLocation + bestOp.symbol.length));

        SFCValue *first = [self evaluate:expression
                                   range:leftRange
                             errorString:errorString
                              errorRange:errorRange];
        if (!first) {
            return nil;
        }
        
        SFCValue *second = [self evaluate:expression
                                    range:rightRange
                              errorString:errorString
                               errorRange:errorRange];
        if (!second) {
            return nil;
        }
        
        *errorString = nil;
        errorRange->location = NSNotFound;
        
        SFCValue *ret = [bestOp performWith:first and:second error:errorString];
        if (!ret) {
            *errorRange = range;
        }
        return ret;
    }
    
    
    
    for (SFCUnaryOperator *op in _leftUnaryOperators) {
        if ([subExpression hasPrefix:op.symbol] &&
            [self verifyAlphaTokenInString:expression andRange:(NSRange){range.location, op.symbol.length}]) {
            SFCValue *input = [self evaluate:expression
                                       range:(NSRange){range.location + op.symbol.length, range.length - op.symbol.length}
                                 errorString:errorString
                                  errorRange:errorRange];
            if (!input) return nil;
            *errorString = nil;
            errorRange->location = NSNotFound;
            SFCValue *ret = [op performWith:input isRight:false error:errorString];
            if (!ret) {
                *errorRange = range;
            }
            return ret;
        }
    }
    
    for (SFCUnaryOperator *op in _rightUnaryOperators) {
        if ([subExpression hasSuffix:op.symbol] &&
            [self verifyAlphaTokenInString:expression andRange:(NSRange){range.location + range.length - op.symbol.length, op.symbol.length}]) {
            SFCValue *input = [self evaluate:expression
                                       range:(NSRange){range.location, range.length - op.symbol.length}
                                 errorString:errorString
                                  errorRange:errorRange];
            if (!input) return nil;
            *errorString = nil;
            errorRange->location = NSNotFound;
            SFCValue *ret = [op performWith:input isRight:true error:errorString];
            if (!ret) {
                *errorRange = range;
            }
            return ret;
        }
    }
    
    SFCValue *ret = [self parseLiteral:subExpression errorString:errorString];
    if (!ret) {
        *errorRange = range;
        return nil;
    }
    if (ret.isDouble) {
        if (ret.doubleValue == INFINITY) {
            *errorRange = range;
            *errorString = @"Number too large";
            return nil;
        }
        if (ret.doubleValue == -INFINITY) {
            *errorString = @"Number too small";
            return nil;
        }
        if (ret.doubleValue == NAN) {
            *errorRange = range;
            *errorString = @"Not a number";
            return nil;
        }
    }
    return ret;
}

- (SFCValue *)parseNumber:(NSString *)string withBase:(unsigned)base
{
    string = string.lowercaseString;
    if (string.length == 0 || [string isEqualToString:@"."]) {
        return nil;
    }
    unsigned length = string.length;
    uint64_t integerPart = 0;
    unsigned i = 0;
    for (; i < length; i++) {
        unichar digit = [string characterAtIndex:i];
        if (digit == '.'){
            i++;
            break;
        }
        
        unsigned digitValue = -1;
        if (digit >= 'a') {
            digitValue = digit - 'a' + 10;
        }
        else if (digit >= '0') {
            digitValue = digit - '0';
        }
        if (digitValue >= base) {
            return nil;
        }
        uint64_t previousIntegerPart = integerPart;
        integerPart *= base;
        integerPart += digitValue;
        if (integerPart / base != previousIntegerPart) {
            return [SFCValue valueWithDouble:INFINITY];
        }
    }
    
    if (i == length) {
        return [SFCValue valueWithInt:integerPart];
    }
    
    uint64_t fractionalPart = 0;
    uint64_t power = 1;
    for (; i < length; i++) {
        unichar digit = [string characterAtIndex:i];
        
        unsigned digitValue = -1;
        if (digit >= 'a') {
            digitValue = digit - 'a' + 10;
        }
        else if (digit >= '0') {
            digitValue = digit - '0';
        }
        if (digitValue >= base) {
            return nil;
        }
        if (power * base > power) {
            fractionalPart *= base;
            fractionalPart += digitValue;
            power *= base;
        }
    }
        
    return [SFCValue valueWithDouble:integerPart + (double)fractionalPart / power];
}

- (SFCValue *)parseScientificNotation:(NSString *)literal
{
    NSArray <NSString *> *components = [literal componentsSeparatedByString:@"e"];
    if (components.count != 2) {
        return nil;
    }
    NSString *first = components[0];
    NSString *second = components[1];
    NSString *temp = [first stringByTrimmingCharactersInSet:[NSCharacterSet decimalDigitCharacterSet]];
    
    if (temp.length != 0 && ![temp isEqualToString:@"."]) {
        return nil;
    }
    
    double sign = 1;
    if ([second hasPrefix:@"+"]) {
        second = [second substringFromIndex:1];
    }
    else if ([second hasPrefix:@"-"]) {
        second = [second substringFromIndex:1];
        sign = -1;
    }
    
    if (second.length == 0 ) {
        return nil;
    }
    
    if ([second stringByTrimmingCharactersInSet:[NSCharacterSet decimalDigitCharacterSet]].length != 0) {
        return nil;
    }
    
    return [SFCValue valueWithDouble:(double)first.doubleValue * pow(10, (double)second.doubleValue * sign)];
}

- (NSData *)parseStringLiteral:(NSString *)literal errorString:(NSString __strong **)errorString
{
    const char *s = literal.UTF8String;
    NSMutableData *ret = [NSMutableData dataWithLength:strlen(s)];
    char *bytes = ret.mutableBytes;
    unsigned i = 0;
    char end = *s;
    s++;
    while (true) {
        if (*s == 0) {
            unterminated:
            if (end == '"') {
                *errorString = @"Unterminated string literal";
            }
            else {
                *errorString = @"Unterminated character literal";
            }
            return nil;
        }
        if (*s == end) {
            if (s[1] != 0) {
                if (end == '"') {
                    *errorString = @"Excess characters string literal";
                }
                else {
                    *errorString = @"Excess characters character literal";
                }
                return nil;
            }
            ret.length = i;
            return ret;
        }
        if (*s == '\\') {
            s++;
            if (*s == 0) goto unterminated;
            if (!isalnum(*s)) {
                bytes[i++] = *(s++);
            }
            else {
                switch (*s) {
                    case '0': bytes[i++] = '\0'; break;
                    case 'a': bytes[i++] = '\a'; break;
                    case 'b': bytes[i++] = '\b'; break;
                    case 'f': bytes[i++] = '\f'; break;
                    case 'n': bytes[i++] = '\n'; break;
                    case 'r': bytes[i++] = '\r'; break;
                    case 't': bytes[i++] = '\t'; break;
                    case 'v': bytes[i++] = '\v'; break;
                    case 'x': {
                        s++;
                        if (!s[0] || !s[1]) goto unterminated;
                        if (!isxdigit(s[0]) || !isxdigit(s[1])) {
                            *errorString = @"Invalidate hexadecimal escape sequence";
                            return nil;
                        }
                        char temp[3] = {s[0], s[1], 0};
                        bytes[i++] = strtol(temp, NULL, 16);
                    }
                }
            }
        }
        else {
            bytes[i++] = *(s++);
        }
    }
}

- (NSMutableDictionary<NSString *,SFCValue *> *)allVariables
{
    return _variables;
}

- (SFCValue *)parseLiteral:(NSString *)literal errorString:(NSString __strong **)errorString
{
    SFCValue *ret = [self getVariable:literal];
    if (ret) return ret;
    
    if (literal.isValidSFCSymbol) {
        if (_currentScope && [literal hasPrefix:@"."] && literal.length != 1) {
            literal = [_currentScope stringByAppendingString:literal];
        }
        return [SFCValue valueWithMissingSymbolsSet:[NSSet setWithObject:literal] expression:literal];
    }
    
    if ([literal hasPrefix:@"\""] || [literal hasPrefix:@"\'"]) {
        NSData *stringValue = [self parseStringLiteral:literal errorString:(NSString __strong **)errorString];
        if (!stringValue) return nil;
        if ([literal hasPrefix:@"\""]) {
            return [SFCValue valueWithData:stringValue];
        }
        
        unsigned ret = 0;
        if (_encoding) {
            NSString *asUTF8 = [[NSString alloc] initWithData:stringValue encoding:NSUTF8StringEncoding];
            if (!asUTF8) {
                *errorString = @"Invalid UTF-8";
                return nil;
            }
            if (asUTF8.length != 1 && asUTF8.length != 2 && asUTF8.length != 4) {
                *errorString = @"A character literal's length must be 1, 2 or 4";
                return nil;
            }
            for (unsigned i = 0; i < asUTF8.length; i++) {
                ret *= 0x100;
                NSNumber *encoded = _encoding[@([asUTF8 characterAtIndex:i])];
                if (!encoded) {
                    *errorString = [NSString stringWithFormat:@"Character \"%@\" cannot be encoded with the current encoding", [asUTF8 substringWithRange:NSMakeRange(i, 1)]];
                    return nil;
                }
                ret += encoded.unsignedIntValue;
            }
        }
        else {
            if (stringValue.length != 1 && stringValue.length != 2 && stringValue.length != 4) {
                *errorString = @"A character literal's length must be 1, 2 or 4";
                return nil;
            }
            const uint8_t *bytes = stringValue.bytes;
            for (unsigned i = stringValue.length; i--;) {
                ret *= 0x100;
                if (_encoding) {
                    NSNumber *encoded = _encoding[@(*bytes)];
                    ret += encoded.unsignedIntValue;
                }
                else {
                    ret += *bytes;
                }
                bytes++;
            }
        }
        
        return [SFCValue valueWithInt:ret];
    }
    
    if ([literal hasPrefix:@"0x"]) {
        ret = [self parseNumber:[literal substringFromIndex:2] withBase:0x10];
        if (!ret) {
            *errorString = @"Invalid hexadecimal number";
        }
        return ret;
    }
    
    if ([literal hasPrefix:@"0b"]) {
        ret = [self parseNumber:[literal substringFromIndex:2] withBase:0b10];
        if (!ret) {
            *errorString = @"Invalid binary number";
        }
        return ret;
    }
    
    if ([literal hasPrefix:@"0o"]) {
        ret = [self parseNumber:[literal substringFromIndex:2] withBase:010];
        if (!ret) {
            *errorString = @"Invalid octal number";
        }
        return ret;
    }
    if ([literal hasPrefix:@"."] ||
        [[NSCharacterSet decimalDigitCharacterSet] characterIsMember:[literal characterAtIndex:0]]) {
        if ([literal containsString:@"e"]) {
            ret = [self parseScientificNotation:literal];
            if (!ret) {
                *errorString = @"Invalid scientific notation";
            }
            return ret;
        }
        ret = [self parseNumber:literal withBase:10];
        if (!ret) {
            *errorString = @"Invalid decimal number";
        }
        return ret;
    }
    
    *errorString = @"Unrecognized operation";
    return nil;
}

+ (instancetype)emptyEvaluator
{
    return [[self alloc] init];
}

+ (instancetype)standardEvaluator;
{
    SFCEvaluator *eval = [[self alloc] init];
    
    [eval registerLeftUnaryOperator:[SFCUnaryOperator operatorWithBlock:^SFCValue *(SFCValue *input, NSString __strong **error) {
        if (input.isString) {
            *error = @"Invalid operation on a string argument";
            return nil;
        }
        return input;
    } symbol:@"+"]];
    
    SFCUnaryOperator *unaryMinus = [SFCUnaryOperator operatorWithBlock:^SFCValue *(SFCValue *input, NSString __strong **error) {
        if (input.isString) {
            *error = @"Invalid operation on a string argument";
            return nil;
        }
        if (input.isDouble) {
            return [SFCValue valueWithDouble:-input.doubleValue];
        }
        return [SFCValue valueWithInt:-input.intValue];
    } symbol:@"-"];
    
    [eval registerLeftUnaryOperator:unaryMinus];
    
    
    SFCUnaryOperator *bitwiseNot = [SFCUnaryOperator operatorWithBlock:^SFCValue *(SFCValue *input, NSString __strong **error) {
        if (!input.isInt) {
            *error = @"Bitwise operation on a non-integer";
            return nil;
        }
        return [SFCValue valueWithInt:~input.intValue];
    } symbol:@"~"];
    
    [eval registerLeftUnaryOperator:bitwiseNot];
        
    [eval registerLeftUnaryOperator:[SFCUnaryOperator operatorWithBlock:^SFCValue *(SFCValue *input, NSString __strong **error) {
        if (input.isString) {
            *error = @"Invalid operation on a string argument";
            return nil;
        }
        if (input.doubleValue >= 0) {
            return input;
        }
        if (input.isDouble) {
            return [SFCValue valueWithDouble:-input.doubleValue];
        }
        return [SFCValue valueWithInt:-input.intValue];
    } symbol:@"abs"]];
    
    [eval registerLeftUnaryOperator:[SFCUnaryOperator operatorWithBlock:^SFCValue *(SFCValue *input, NSString __strong **error) {
        if (input.isString) {
            *error = @"Invalid operation on a string argument";
            return nil;
        }
        if (input.isDouble) {
            return [SFCValue valueWithInt:floor(input.doubleValue)];
        }
        return input;
    } symbol:@"floor"]];
    
    [eval registerLeftUnaryOperator:[SFCUnaryOperator operatorWithBlock:^SFCValue *(SFCValue *input, NSString __strong **error) {
        if (input.isString) {
            *error = @"Invalid operation on a string argument";
            return nil;
        }
        if (input.isDouble) {
            return [SFCValue valueWithInt:ceil(input.doubleValue)];
        }
        return input;
    } symbol:@"ceil"]];
    
    [eval registerLeftUnaryOperator:[SFCUnaryOperator operatorWithBlock:^SFCValue *(SFCValue *input, NSString __strong **error) {
        if (input.isString) {
            *error = @"Invalid operation on a string argument";
            return nil;
        }
        if (input.isDouble) {
            return [SFCValue valueWithInt:trunc(input.doubleValue)];
        }
        return input;
    } symbol:@"trunc"]];
    
    [eval registerLeftUnaryOperator:[SFCUnaryOperator operatorWithBlock:^SFCValue *(SFCValue *input, NSString __strong **error) {
        if (input.isString) {
            *error = @"Invalid operation on a string argument";
            return nil;
        }
        if (input.isDouble) {
            return [SFCValue valueWithInt:round(input.doubleValue)];
        }
        return input;
    } symbol:@"round"]];
    
    [eval registerLeftUnaryOperator:[SFCUnaryOperator operatorWithBlock:^SFCValue *(SFCValue *input, NSString __strong **error) {
        if (input.isString) {
            *error = @"Invalid operation on a string argument";
            return nil;
        }
        return [SFCValue valueWithDouble:input.doubleValue - trunc(input.doubleValue)];
    } symbol:@"fract"]];
    
    [eval registerLeftUnaryOperator:[SFCUnaryOperator operatorWithBlock:^SFCValue *(SFCValue *input, NSString __strong **error) {
        if (input.isString) {
            *error = @"Invalid operation on a string argument";
            return nil;
        }
        double ret = sin(fmod(input.doubleValue, M_PI));
        if (fabs(ret) <= cos(M_PI_2)) {
            return [SFCValue valueWithDouble:0];
        }
        return [SFCValue valueWithDouble:ret];
    } symbol:@"sin"]];
    
    [eval registerLeftUnaryOperator:[SFCUnaryOperator operatorWithBlock:^SFCValue *(SFCValue *input, NSString __strong **error) {
        if (input.isString) {
            *error = @"Invalid operation on a string argument";
            return nil;
        }
        double ret = cos(fmod(input.doubleValue, M_PI));
        if (fabs(ret) <= cos(M_PI_2)) {
            return [SFCValue valueWithDouble:0];
        }
        return [SFCValue valueWithDouble:ret];
    } symbol:@"cos"]];
    
    [eval registerLeftUnaryOperator:[SFCUnaryOperator operatorWithBlock:^SFCValue *(SFCValue *input, NSString __strong **error) {
        if (input.isString) {
            *error = @"Invalid operation on a string argument";
            return nil;
        }
        double ret = tan(fmod(input.doubleValue, M_PI));
        if (fabs(ret) >= fabs(tan(M_PI_2))) {
            *error = @"Division by zero";
            return nil;
        }
        return [SFCValue valueWithDouble:ret];
    } symbol:@"tan"]];
    
    [eval registerLeftUnaryOperator:[SFCUnaryOperator operatorWithBlock:^SFCValue *(SFCValue *input, NSString __strong **error) {
        if (input.isString) {
            *error = @"Invalid operation on a string argument";
            return nil;
        }
        if (fabs(input.doubleValue) > 1) {
            *error = @"Out of range";
            return nil;
        }
        return [SFCValue valueWithDouble:asin(input.doubleValue)];
    } symbol:@"asin"]];
    
    [eval registerLeftUnaryOperator:[SFCUnaryOperator operatorWithBlock:^SFCValue *(SFCValue *input, NSString __strong **error) {
        if (input.isString) {
            *error = @"Invalid operation on a string argument";
            return nil;
        }
        if (fabs(input.doubleValue) > 1) {
            *error = @"Out of range";
            return nil;
        }
        return [SFCValue valueWithDouble:acos(input.doubleValue)];
    } symbol:@"acos"]];
    
    [eval registerLeftUnaryOperator:[SFCUnaryOperator operatorWithBlock:^SFCValue *(SFCValue *input, NSString __strong **error) {
        if (input.isString) {
            *error = @"Invalid operation on a string argument";
            return nil;
        }
        return [SFCValue valueWithDouble:atan(input.doubleValue)];
    } symbol:@"atan"]];
    
    [eval registerLeftUnaryOperator:[SFCUnaryOperator operatorWithBlock:^SFCValue *(SFCValue *input, NSString __strong **error) {
        if (input.isString) {
            *error = @"Invalid operation on a string argument";
            return nil;
        }
        if (input.doubleValue <= 0) {
            *error = @"Logarithm of a non-positive number";
            return nil;
        }
        return [SFCValue valueWithDouble:log(input.doubleValue)];
    } symbol:@"ln"]];
    
    
    [eval registerLeftUnaryOperator:[SFCUnaryOperator operatorWithBlock:^SFCValue *(SFCValue *input, NSString __strong **error) {
        if (input.isString) {
            *error = @"Invalid operation on a string argument";
            return nil;
        }
        if (input.doubleValue < 0) {
            *error = @"Root of a negative number";
            return nil;
        }
        return [SFCValue valueWithDouble:sqrt(input.doubleValue)];
    } symbol:@"sqrt"]];

    [eval registerLeftUnaryOperator:[SFCUnaryOperator operatorWithBlock:^SFCValue *(SFCValue *input, NSString __strong **error) {
        if (input.isString) {
            return [SFCValue valueWithInt:0];
        }
        if (input.doubleValue) {
            return [SFCValue valueWithInt:!input.doubleValue];
        }
        return [SFCValue valueWithInt:!input.intValue];
    } symbol:@"!"]];
    
    [eval registerBinaryOperator:[SFCBinaryOperator operatorWithBlock:^SFCValue *(SFCValue *first, SFCValue *second, NSString __strong **error) {
        if (first.isString && second.isString) {
            NSMutableData *ret = [first.dataValue mutableCopy];
            [ret appendData:second.dataValue];
            return [SFCValue valueWithData:ret];
        }
        SafeOp(+)
    } symbol:@"+" priority:0]];
    
    [eval registerBinaryOperator:[SFCBinaryOperator operatorWithBlock:^SFCValue *(SFCValue *first, SFCValue *second, NSString __strong **error) {
        SafeOp(-)
    } symbol:@"-" priority:0]];
    
    [eval registerBinaryOperator:[SFCBinaryOperator operatorWithBlock:^SFCValue *(SFCValue *first, SFCValue *second, NSString __strong **error) {
        SafeOp(*)
    } symbol:@"*" priority:1]];

    [eval registerBinaryOperator:[SFCBinaryOperator operatorWithBlock:^SFCValue *(SFCValue *first, SFCValue *second, NSString __strong **error) {
        if (first.isString || second.isString) {
            *error = @"Invalid operation on a string argument";
            return nil;
        }
        if (second.doubleValue == 0) {
            *error = @"Division by zero";
            return nil;
        }
        if (first.isDouble || second.isDouble) {
            return [SFCValue valueWithDouble:first.doubleValue / second.doubleValue];
        }
        return [SFCValue valueWithInt:first.intValue / second.intValue];
    } symbol:@"/" priority:1]];

    
    [eval registerBinaryOperator:[SFCBinaryOperator operatorWithBlock:^SFCValue *(SFCValue *first, SFCValue *second, NSString __strong **error) {
        if (first.isString || second.isString) {
            *error = @"Invalid operation on a string argument";
            return nil;
        }
        if (second.doubleValue == 0) {
            *error = @"Division by zero";
            return nil;
        }
        if (first.isDouble || second.isDouble) {
            return [SFCValue valueWithDouble:fmod(first.doubleValue, second.doubleValue)];
        }
        return [SFCValue valueWithInt:first.intValue % second.intValue];
    } symbol:@"%" priority:1]];
    
    [eval registerBinaryOperator: [SFCBinaryOperator operatorWithBlock:^SFCValue *(SFCValue *first, SFCValue *second, NSString __strong **error) {
        if (first.isString || second.isString) {
            *error = @"Invalid operation on a string argument";
            return nil;
        }
        if (second.doubleValue == 1) {
            return first;
        }
        if (first.doubleValue < 0 && fmod(second.doubleValue, 1.0) != 0) {
            *error = @"Root of a negative number";
            return nil;
        }
        if (first.isInt && second.isInt) {
            return [SFCValue valueWithInt:pow(first.doubleValue, second.doubleValue)];
        }
        return [SFCValue valueWithDouble:pow(first.doubleValue, second.doubleValue)];
    } symbol:@"**" priority:2]];
    
    [eval registerBinaryOperator:[SFCBinaryOperator operatorWithBlock:^SFCValue *(SFCValue *first, SFCValue *second, NSString __strong **error) {
        if (!first.isInt || !second.isInt) {
            *error = @"Bitwise operation on a non-integer";
            return nil;
        }
        return [SFCValue valueWithInt:first.intValue << second.intValue];
    } symbol:@"<<" priority:-1]];
    
    [eval registerBinaryOperator:[SFCBinaryOperator operatorWithBlock:^SFCValue *(SFCValue *first, SFCValue *second, NSString __strong **error) {
        if (!first.isInt || !second.isInt) {
            *error = @"Bitwise operation on a non-integer";
            return nil;
        }
        if (second.intValue >= 64) {
            if (first.intValue >= 0) {
                return [SFCValue valueWithInt:0];
            }
            return [SFCValue valueWithInt:-1];
        }
        return [SFCValue valueWithInt:first.intValue >> second.intValue];
    } symbol:@">>" priority:-1]];
    
    [eval registerBinaryOperator:[SFCBinaryOperator operatorWithBlock:^SFCValue *(SFCValue *first, SFCValue *second, NSString __strong **error) {
        SafeBoolOp(==)
    } symbol:@"==" priority:-2]];
    
    [eval registerBinaryOperator:[SFCBinaryOperator operatorWithBlock:^SFCValue *(SFCValue *first, SFCValue *second, NSString __strong **error) {
        SafeBoolOp(!=)
    } symbol:@"!=" priority:-2]];
    
    [eval registerBinaryOperator:[SFCBinaryOperator operatorWithBlock:^SFCValue *(SFCValue *first, SFCValue *second, NSString __strong **error) {
        SafeBoolOp(<=)
    } symbol:@"<=" priority:-2]];
    
    [eval registerBinaryOperator:[SFCBinaryOperator operatorWithBlock:^SFCValue *(SFCValue *first, SFCValue *second, NSString __strong **error) {
        SafeBoolOp(<)
    } symbol:@"<" priority:-2]];
    
    [eval registerBinaryOperator:[SFCBinaryOperator operatorWithBlock:^SFCValue *(SFCValue *first, SFCValue *second, NSString __strong **error) {
        SafeBoolOp(>=)
    } symbol:@">=" priority:-2]];
    
    [eval registerBinaryOperator:[SFCBinaryOperator operatorWithBlock:^SFCValue *(SFCValue *first, SFCValue *second, NSString __strong **error) {
        SafeBoolOp(>)
    } symbol:@">" priority:-2]];
    
    
    [eval registerBinaryOperator:[SFCBinaryOperator operatorWithBlock:^SFCValue *(SFCValue *first, SFCValue *second, NSString __strong **error) {
        if (!first.isInt || !second.isInt) {
            *error = @"Bitwise operation on a non-integer";
            return nil;
        }
        return [SFCValue valueWithInt:first.intValue & second.intValue];
    } symbol:@"&" priority:-3]];
    
    [eval registerBinaryOperator:[SFCBinaryOperator operatorWithBlock:^SFCValue *(SFCValue *first, SFCValue *second, NSString __strong **error) {
        if (!first.isInt || !second.isInt) {
            *error = @"Bitwise operation on a non-integer";
            return nil;
        }
        return [SFCValue valueWithInt:first.intValue ^ second.intValue];
    } symbol:@"^" priority:-4]];

    [eval registerBinaryOperator:[SFCBinaryOperator operatorWithBlock:^SFCValue *(SFCValue *first, SFCValue *second, NSString __strong **error) {
        if (!first.isInt || !second.isInt) {
            *error = @"Bitwise operation on a non-integer";
            return nil;
        }
        return [SFCValue valueWithInt:first.intValue | second.intValue];
    } symbol:@"|" priority:-5]];
    
    [eval registerBinaryOperator:[SFCBinaryOperator operatorWithBlock:^SFCValue *(SFCValue *first, SFCValue *second, NSString __strong **error) {
        if (first.isDouble && !first.doubleValue) return [SFCValue valueWithInt:0];
        if (second.isDouble && !second.doubleValue) return [SFCValue valueWithInt:0];
        if (first.isInt && !first.intValue) return [SFCValue valueWithInt:0];
        if (second.isInt && !second.intValue) return [SFCValue valueWithInt:0];
        
        return [SFCValue valueWithInt:1];
    } symbol:@"&&" priority:-6]];
    
    [eval registerBinaryOperator:[SFCBinaryOperator operatorWithBlock:^SFCValue *(SFCValue *first, SFCValue *second, NSString __strong **error) {
        if (first.isString || second.isString) return [SFCValue valueWithInt:1];;
        if (first.isDouble && first.doubleValue) return [SFCValue valueWithInt:1];
        if (second.isDouble && second.doubleValue) return [SFCValue valueWithInt:1];
        if (first.isInt && first.intValue) return [SFCValue valueWithInt:1];
        if (second.isInt && second.intValue) return [SFCValue valueWithInt:1];
        
        return [SFCValue valueWithInt:1];
    } symbol:@"||" priority:-6]];
    
    [eval registerLeftUnaryOperator:[SFCUnaryOperator operatorWithBlock:^SFCValue *(SFCValue *input, NSString __strong **error) {
        if (!input.isInt) {
            *error = @"Bitwise operation on a non-integer";
            return nil;
        }
        return [SFCValue valueWithInt:input.intValue & 0xFF];
    } symbol:@"low"]];
    
    [eval registerLeftUnaryOperator:[SFCUnaryOperator operatorWithBlock:^SFCValue *(SFCValue *input, NSString __strong **error) {
        if (!input.isInt) {
            *error = @"Bitwise operation on a non-integer";
            return nil;
        }
        return [SFCValue valueWithInt:(input.intValue >> 8) & 0xFF];
    } symbol:@"high"]];
    
    [eval registerLeftUnaryOperator:[SFCUnaryOperator operatorWithBlock:^SFCValue *(SFCValue *input, NSString __strong **error) {
        if (!input.isInt) {
            *error = @"Bitwise operation on a non-integer";
            return nil;
        }
        return [SFCValue valueWithInt:input.intValue & 0xFFFF];
    } symbol:@"addr"]];
    
    [eval registerLeftUnaryOperator:[SFCUnaryOperator operatorWithBlock:^SFCValue *(SFCValue *input, NSString __strong **error) {
        if (!input.isInt) {
            *error = @"Bitwise operation on a non-integer";
            return nil;
        }
        return [SFCValue valueWithInt:input.intValue >> 16];
    } symbol:@"bank"]];
        
    return eval;
}

@end
