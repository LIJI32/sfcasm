#import "SFCErrorSet.h"
#import "SFCLineReader.h"
#import <unistd.h>

@implementation SFCErrorSet
{
    unsigned _count[SFCFatal + 1];
    SFCErrorType _status;
}

- (void)addErrorWithType:(SFCErrorType)type string:(NSString *)format, ...
{
    assert(type >= SFCWarning && type <= SFCFatal);
    _status = MAX(_status, type);
    _count[type]++;
    
    bool tty = isatty(STDERR_FILENO);
    
    if (_activeReader) {
        NSString *lineDescription = _activeReader.lastLineDescription;
        if (tty) {
            if ([lineDescription containsString:@"\n"]) {
                NSMutableArray<NSString *> *array = [lineDescription componentsSeparatedByString:@"\n"].mutableCopy;
                array[array.count - 1] = [NSString stringWithFormat:@"\033[1m\033[37m%@", array.lastObject];
                fprintf(stderr, "%s: ", [array componentsJoinedByString:@"\n"].UTF8String);
            }
            else {
                fprintf(stderr, "\033[1m\033[37m%s: ", lineDescription.UTF8String);
            }
        }
        else {
            fprintf(stderr, "%s: ", lineDescription.UTF8String);
        }
    }
    
    if (tty) {
        fprintf(stderr, "\033[1m\033[%dm", type == SFCWarning? 33 : 31);
    }
    switch (type) {
        case SFCWarning: fwrite("Warning: ", strlen("Warning: "), 1, stderr); break;
        case SFCError: fwrite("Error: ", strlen("Error: "), 1, stderr); break;
        case SFCFatal: fwrite("Fatal: ", strlen("Fatal: "), 1, stderr); break;
        default: break;
    }
    
    if (tty) {
        fwrite("\033[0m", strlen("\033[0m"), 1, stderr);
    }
    
    va_list args;
    va_start(args, format);
    fputs([[NSString alloc] initWithFormat:format arguments:args].UTF8String, stderr);
    va_end(args);
    
    fputc('\n', stderr);
}

- (unsigned)countForType:(SFCErrorType)type
{
    assert(type >= SFCWarning && type <= SFCFatal);
    return _count[type];
}

- (SFCErrorType)status
{
    return _status;
}

@end
