#import <Foundation/Foundation.h>
#import "SFCLayout.h"
#import "SFCLineReader.h"
#import "SFCErrorSet.h"
#import "SFCEvaluator.h"

@interface SFCAssembler : NSObject
+ (instancetype)assemblerWithLayout:(SFCLayout *)layout evaluator:(SFCEvaluator *)evaluator;
- (void)assemble:(id<SFCLineReader>)reader toFile:(NSString *)path errorSet:(SFCErrorSet *)errors;
@property bool updateChecksumWhenDone;
@property bool depsMode;
@property (readonly) NSSet<NSString *> *sourceDeps;
@property (readonly) NSSet<NSString *> *binDeps;

// Internal
- (void)writeBytes:(const uint8_t *)bytes length:(size_t)length;
- (SFCValue *)evaluate:(NSString *)expression allowUndefined:(bool)allowUndefined;
- (NSString *)evaluateString:(NSString *)expression;
- (bool)evaluateBool:(NSString *)expression;

typedef enum {
    SFCRelValidationRange, // Signed or unsigned in range
    SFCRelValidationSigned,
    SFCRelValidationUnsigned,
    SFCRelValidationHigh, // Validate high part matches, or 0
} SFCRelValidation;

- (void)addRelocation:(SFCValue *)expression size:(uint8_t)size validation:(SFCRelValidation)validation expectedHigh:(uint32_t)high;

@property uint64_t assemblerFlags;
@end
