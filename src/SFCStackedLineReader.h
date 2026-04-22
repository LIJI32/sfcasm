#import <Foundation/Foundation.h>
#import "SFCLineReader.h"

@interface SFCStackedLineReader : NSObject<SFCLineReader>
- (void)pushReader:(id<SFCLineReader>)reader withPrefix:(NSString *)prefix;
@end
