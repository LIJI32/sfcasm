#import <Foundation/Foundation.h>
#import "SFCErrorSet.h"
#import "SFCLineReader.h"
#import "SFCEvaluator.h"

@interface SFCSegment : NSObject
@property (readonly) NSString *name;
@property (readonly) uint32_t address;
@property uint32_t size;
@property (readonly) uint32_t maxSize;
@property (readonly) uint32_t sizeAlignment;
@property (readonly) uint8_t fillByte;
@property (readonly) bool flexibleSize;
@property uint32_t lastLocation;
@property (readonly) uint32_t fileOffset;
@property (readonly) bool fileMapped;
@end

@interface SFCLayout : NSObject
- (instancetype)initWithLineReader:(id<SFCLineReader>)reader evaluator:(SFCEvaluator *)evaluator errorSet:(SFCErrorSet *)errors;
@property (readonly) NSArray<SFCSegment *> *segments;
- (SFCSegment *)segmentForAddress:(uint32_t)address;
- (SFCSegment *)segmentWithName:(NSString *)name;
@end
