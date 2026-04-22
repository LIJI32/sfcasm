#import <Foundation/Foundation.h>

@protocol SFCLineReader;

@interface SFCErrorSet : NSObject
typedef enum {
    SFCClear,
    SFCWarning,
    SFCError,
    SFCFatal,
} SFCErrorType;

- (SFCErrorType)status;
- (void)addErrorWithType:(SFCErrorType)type string:(NSString *)format, ... NS_FORMAT_FUNCTION(2,3);
- (unsigned)countForType:(SFCErrorType)type;
@property id<SFCLineReader> activeReader;
@end
