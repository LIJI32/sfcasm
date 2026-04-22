#import <Foundation/Foundation.h>
#import "SFCLineReader.h"

@interface SFCStringLineReader : NSObject<SFCLineReader>

+ (instancetype)readerWithString:(NSString *)string fileName:(NSString *)fileName lineOffset:(unsigned)offset repeats:(unsigned)repeats;
+ (instancetype)readerWithString:(NSString *)string fileName:(NSString *)fileName lineOffset:(unsigned)offset;
+ (instancetype)readerWithString:(NSString *)string fileName:(NSString *)fileName;
+ (instancetype)readerWithString:(NSString *)string;

@end
