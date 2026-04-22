#import "SFCFileLineReader.h"
#import <unistd.h>

@implementation SFCFileLineReader
{
    FILE *_file;
    unsigned _line;
    NSString *_path;
}

+ (instancetype)lineReaderWithPath:(NSString *)path errorSet:(SFCErrorSet *)errors
{
    SFCFileLineReader *ret = [[self alloc] init];
    if ([path isEqualToString:@"-"]) {
        ret->_file = fdopen(dup(STDIN_FILENO), "r");
    }
    else {
        ret->_file = fopen(path.UTF8String, "r");
    }
    if (!ret->_file) {
        [errors addErrorWithType:SFCFatal string:@"Could not open file '%@': %s", path, strerror(errno)];
        return nil;
    }
    ret->_path = path;
    return ret;
}

- (bool)eof
{
    return feof(_file);
}

- (NSString *)lastLineDescription
{
    return [NSString stringWithFormat:@"%@:%u", _path, _line];
}


- (NSString *)filename
{
    return _path;
}

- (unsigned)currentLine
{
    return _line;
}

- (NSString *)readLineWithErrorSet:(SFCErrorSet *)errors
{
    _line++;
    char *line = NULL;
    size_t size = 0;
    errno = 0;
    if (getline(&line, &size, _file) < 0) {
        if (line) free(line);
        if (errno == 0) return @"";
        [errors addErrorWithType:SFCFatal string:@"Failed to read file %@: %s", _path, strerror(errno)];
        return nil;
    }
    
    NSString *nsline = @(line);
    free(line);
    if (!nsline) {
        [errors addErrorWithType:SFCError string:@"%@: Invalid UTF-8", self.lastLineDescription];
        return nil;
    }
    return nsline;
}

- (NSString *)directory
{
    return [_path stringByDeletingLastPathComponent];
}

- (void)dealloc
{
    if (_file) fclose(_file);
}
@end
