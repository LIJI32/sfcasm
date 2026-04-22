#import <Foundation/Foundation.h>
#import "SFCLineReader.h"

@interface SFCFileLineReader : NSObject<SFCLineReader>
+ (instancetype)lineReaderWithPath:(NSString *)path errorSet:(SFCErrorSet *)errors;
@end
