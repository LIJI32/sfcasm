#import <Foundation/Foundation.h>
#import "SFCErrorSet.h"

@protocol SFCLineReader <NSObject>

@required
- (NSString *)readLineWithErrorSet:(SFCErrorSet *)errors;
- (NSString *)lastLineDescription;
- (bool)eof;
- (NSString *)filename;
- (unsigned)currentLine;
- (NSString *)directory;
@end
