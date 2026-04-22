#import "SFCStackedLineReader.h"
#import "SFCFileLineReader.h"

@implementation SFCStackedLineReader
{
    NSMutableArray<id<SFCLineReader>> *_readers;
    NSMutableArray<NSString *> *_prefixes;
}

- (void)pushReader:(id<SFCLineReader>)reader withPrefix:(NSString *)prefix
{
    if (!_readers) _readers = [NSMutableArray array];
    if (!_prefixes) _prefixes = [NSMutableArray array];
    [_readers addObject:reader];
    [_prefixes addObject:prefix];
}

- (bool)eof
{
    while (_readers.count) {
        if (!_readers.lastObject.eof) {
            return false;
        }
        [_readers removeLastObject];
        [_prefixes removeLastObject];
    }
    return true;
}

- (NSString *)lastLineDescription
{
    if (_readers.count == 1) return _readers[0].lastLineDescription;
    NSMutableString *ret = [@"" mutableCopy];
    for (unsigned i = 0; i < _readers.count; i++) {
        if (i == _readers.count - 1) {
            [ret appendString:_readers[i].lastLineDescription];
            break;
        }
        [ret appendFormat:@"%@ %@:\n", _prefixes[i + 1], _readers[i].lastLineDescription];
    }
    return ret;
}

- (NSString *)readLineWithErrorSet:(SFCErrorSet *)errors
{
    [self eof]; // Clear eof readers
    return [_readers.lastObject readLineWithErrorSet:errors];
}

- (NSString *)directory
{
    return _readers.lastObject.directory;
}

- (NSString *)filename
{
    return _readers.lastObject.filename;
}

- (unsigned)currentLine
{
    return _readers.lastObject.currentLine;
}
@end
