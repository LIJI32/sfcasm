#import "NSString+SFC.h"
#import <ctype.h>
#import <string.h>

static bool IsValidSymbolName(NSString *symbol, bool label)
{
    const char *string = symbol.UTF8String;
    
    if (!isalpha(*string) && (*string != '.' || !label) && *string != '_') {
        return false;
    }
    string++;
    while (*string) {
        if (!isalnum(*string) && (*string != '.' || !label) && *string != '_') {
            return false;
        }
        string++;
    }
    
    return true;
}

@implementation NSString (SFC)

- (bool)isPlusMinusLabel
{
    const char *string = self.UTF8String;

    // Allow +... and -... labels
    if (*string == '+' || *string == '-') {
        while (true) {
            string++;
            if (!*string) return true;
            if (string[0] != string[-1]) return false;
        }
    }
    return false;;
}

- (bool)isValidSFCSymbol
{
    return IsValidSymbolName(self, true);
}

- (bool)isValidSFCSegment
{
    return IsValidSymbolName(self, false);
}

- (NSArray<NSString *> *)tokenizeByString:(NSString *)string maximumTokens:(unsigned)limit
{
    if (limit == 1) return @[self];
    NSMutableArray<NSString *> *ret = [NSMutableArray array];
    
    const char *token = string.UTF8String;
    const char *expression = [[self stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] stringByReplacingOccurrencesOfString:@"\t" withString:@" "].UTF8String;
    
    size_t length = 0;
    char quote = 0;
    unsigned depth = 0;
    /* Hack: Only support one [ */
    unsigned squaredDepth = -1;
    while (true) {
        char c = expression[length];
        if (!c) break;
        
        if (quote) {
            if (c == quote) {
                quote = 0;
                length++;
                continue;
            }
            if (c == '\\') {
                length++;
                if (expression[length]) {
                    length++;
                }
            }
        }
        else if (c == '"' || c == '\'') {
            quote = c;
            length++;
        }
        else if (c =='(') {
            depth++;
        }
        else if (c =='[') {
            depth++;
            squaredDepth = depth;
        }
        else if (depth > 0) {
            if (c == ')' && depth != squaredDepth) depth--;
            if (c == ']' && depth == squaredDepth) depth--;
        }
        else if (memcmp(expression + length, token, strlen(token)) == 0) {
            NSString *item = [[NSString alloc] initWithBytes:expression length:length encoding:NSUTF8StringEncoding];
            item = [item stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            [ret addObject:item];
            expression += length + strlen(token);
            length = 0;
            if (ret.count == limit - 1) {
                [ret addObject:[@(expression) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];
                return ret;
            }
        }
        length++;
    }
    
    NSString *item = [[NSString alloc] initWithBytes:expression length:length encoding:NSUTF8StringEncoding];
    item = [item stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    [ret addObject:item];

    return ret;
}

- (NSArray<NSString *> *)tokenizeByString:(NSString *)string
{
    return [self tokenizeByString:string maximumTokens:-1];
}

@end
