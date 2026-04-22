#import <Foundation/Foundation.h>

@interface SFCValue : NSObject

@property (readonly) bool isString;
@property (readonly) bool isInt;
@property (readonly) bool isDouble;
@property (readonly) bool isMissingSymbolsSet;

@property (readonly) NSString *stringValue;
@property (readonly) NSData *dataValue;
@property (readonly) int64_t intValue;
@property (readonly) double doubleValue;
@property (readonly, copy) NSSet<NSString *> *missingSymbolsSet;
@property (readonly) NSString *expressionValue;

@property bool isSymbol;

+ (instancetype)valueWithString:(NSString *)string;
+ (instancetype)valueWithData:(NSData *)data;
+ (instancetype)valueWithInt:(int64_t)number;
+ (instancetype)valueWithDouble:(double)number;
+ (instancetype)valueWithMissingSymbolsSet:(NSSet<NSString *> *)missingSymbolsSet expression:(NSString *)expression;

@end
