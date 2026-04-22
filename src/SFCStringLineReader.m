#import "SFCStringLineReader.h"

@implementation SFCStringLineReader
{
    NSArray<NSString *> *_lines;
    unsigned _line;
    unsigned _lineOffset;
    NSString *_fileName;
    NSString *_directory;
    unsigned _repeats;
}
+ (instancetype)readerWithString:(NSString *)string fileName:(NSString *)fileName lineOffset:(unsigned)offset repeats:(unsigned)repeats
{
    SFCStringLineReader *ret = [[SFCStringLineReader alloc] init];
    ret->_lines = repeats == 0? @[]:[string componentsSeparatedByString:@"\n"];
    ret->_lineOffset = offset;
    ret->_fileName = fileName;
    ret->_directory = [fileName stringByDeletingLastPathComponent];
    ret->_repeats = repeats - 1;
    return ret;
}

+ (instancetype)readerWithString:(NSString *)string fileName:(NSString *)fileName lineOffset:(unsigned)offset
{
    return [self readerWithString:string fileName:fileName lineOffset:offset repeats:1];
}

+ (instancetype)readerWithString:(NSString *)string fileName:(NSString *)fileName
{
    return [self readerWithString:string fileName:fileName lineOffset:0];
}

+ (instancetype)readerWithString:(NSString *)string
{
    SFCStringLineReader *ret = [self readerWithString:string fileName:@"<builtin>" lineOffset:0];
    ret->_directory = nil;
    return ret;
}

- (bool)eof
{
    return _line == _lines.count && _repeats == 0;
}

- (NSString *)lastLineDescription
{
    return [NSString stringWithFormat:@"%@:%u", _fileName, _line + _lineOffset];
}

- (NSString *)readLineWithErrorSet:(SFCErrorSet *)errors
{
    if (_line == _lines.count && _repeats) {
        _line = 0;
        _repeats--;
    }
    return _lines[_line++];
}

- (NSString *)directory
{
    return _directory;
}

- (NSString *)filename
{
    return _fileName;
}

- (unsigned)currentLine
{
    return _line + _lineOffset;
}
@end
