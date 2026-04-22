#import <Foundation/Foundation.h>

@interface NSString (SFC)
@property (readonly, getter=isPlusMinusLabel) bool plusMinusLabel;
@property (readonly, getter=isValidSFCSymbol) bool validSFCSymbol;
@property (readonly, getter=isValidSFCSegment) bool validSFCSegment;
- (NSArray<NSString *> *)tokenizeByString:(NSString *)string maximumTokens:(unsigned)limit;
- (NSArray<NSString *> *)tokenizeByString:(NSString *)string;
@end

