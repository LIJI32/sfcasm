#import "SFCAssembler.h"
#import "NSString+SFC.h"
#import "SFCStackedLineReader.h"
#import "SFCFileLineReader.h"
#import "SFCStringLineReader.h"
#import <objc/message.h>
#import <unistd.h>

#ifndef PAGE_SIZE
#define PAGE_SIZE 0x1000
#endif

@interface SFCMacro : NSObject
@property NSString *name;
@property NSArray<NSString *> *arguments;
@property NSString *definingFile;
@property uint32_t definingLine;
@property NSMutableString *contents;
@property bool isVAArgs;
@end

@implementation SFCMacro
@end

@interface SFCRelocation : NSObject
@property NSString *expression;
@property NSString *lineDescription;
@property size_t fileOffset;
@property uint8_t size;
@property uint32_t expectedHigh;
@property SFCRelValidation validation;
@end

@implementation SFCRelocation
@end

typedef enum : uint8_t {
    IfStateIfFalse, // Inside if, value is false
    IfStateElseFalse, // Inside else, value is false
    IfStateNestedFalse, // A nested if instide a false if
    IfStateElifFinalFalse, // Inside elif, forbid switching to true
    IfStateIfTrue, // Inside if, value is true
    IfStateElseTrue, // Inside else, value is true
} IfState;

@implementation SFCAssembler
{
    SFCLayout *_layout;
    SFCEvaluator *_evaluator;
    FILE *_file;
    SFCStackedLineReader *_reader;
    SFCErrorSet *_errors;
    
    NSMutableDictionary<NSString *, NSString *> *_definitions;
    NSRegularExpression *_definitionsRegex;
    
    uint32_t _org;
    NSString *_lastGlobalLabel;
    SFCSegment *_currentSegment;

    SFCMacro *_definingMacro;
    NSMutableDictionary<NSString *, SFCMacro *> *_macros;
    
    IfState _ifStack[128];
    uint8_t _ifDepth;
    
    NSMutableArray<SFCRelocation *> *_relocations;
    NSMutableSet<NSString *> *_unresolvedSymbols;
    
    NSMutableString *_reptString;
    unsigned _reptDepth;
    unsigned _reptCount;
    unsigned _reptLine;
    
    NSMutableDictionary<NSNumber *,NSNumber *> *_plusLabelCount;
    
    NSString *_definingStruct;
    unsigned _structOffset;
    
    NSMutableDictionary<NSString *, NSMutableDictionary<NSNumber *,NSNumber *> *> *_encodings;
    NSString *_currentEncoding;
    
    NSString *_trailedCommaLine;
    
    uint16_t _checksum;
    
    NSMutableSet<NSString *> *_sourceDeps;
    NSMutableSet<NSString *> *_binDeps;
}

+ (instancetype)assemblerWithLayout:(SFCLayout *)layout evaluator:(SFCEvaluator *)evaluator
{
    SFCAssembler *assembler = [[self alloc] init];
    assembler->_layout = layout;
    assembler->_evaluator = evaluator;
    assembler->_org = -1;
    return assembler;
}

#define ExpectArgumentCount(directive, _count) \
if (arguments.count != _count) {\
[_errors addErrorWithType:SFCError string:@"Directive %s expects %u argument(s), got %u", directive, _count, (unsigned)arguments.count];\
return;\
}

- (SFCValue *)evaluate:(NSString *)expression allowUndefined:(bool)allowUndefined
{
    if (allowUndefined && _depsMode) return [SFCValue valueWithMissingSymbolsSet:[NSSet set] expression:@"0"];

    if (expression.isPlusMinusLabel) {
        expression = [self translatePlusMinusLabel:expression isNew:false];
    }
    NSRange errorRange;
    NSString *error;
    SFCValue *value = [_evaluator evaluate:expression errorString:&error errorRange:&errorRange];

    if (!value) {
        [_errors addErrorWithType:SFCError string:@"%@ ('%@')", error, [expression substringWithRange:errorRange]];
        return nil;
    }
    
    if (value.isMissingSymbolsSet && !allowUndefined) {
        [_errors addErrorWithType:SFCError string:@"Unresolved symbol(s): %@", [value.missingSymbolsSet.allObjects componentsJoinedByString:@", "]];
        return nil;
    }
    return value;
}

- (NSString *)evaluateString:(NSString *)expression
{
    SFCValue *value = [self evaluate:expression allowUndefined:false];
    if (!value.isString) {
        [_errors addErrorWithType:SFCError string:@"Expected string value"];
        return nil;
    }
    return value.stringValue;
}

- (bool)evaluateBool:(NSString *)expression
{
    SFCValue *value = [self evaluate:expression allowUndefined:false];
    if (!value) return false;;
    if (value.isString) return true;
    if (value.isInt) return value.intValue;
    return value.doubleValue;
}

- (void)handleInclude:(NSArray<NSString *> *)arguments
{
    ExpectArgumentCount("include", 1)
    NSString *path = [self evaluateString:arguments[0]];
    if (!path) return;
    
    if (![path hasPrefix:@"/"]) {
        if (!_reader.directory) {
            [_errors addErrorWithType:SFCError string:@"Relative includes are not supported from this context"];
            return;
        }
        path = [_reader.directory stringByAppendingPathComponent:path];
    }
    
    [_sourceDeps addObject:path];
    
    SFCFileLineReader *reader;
    if (_depsMode) {
        reader = [SFCFileLineReader lineReaderWithPath:path errorSet:nil];
        if (!reader) return;
    }
    else {
        reader = [SFCFileLineReader lineReaderWithPath:path errorSet:_errors];
    }
    [_reader pushReader:reader withPrefix:@"In file included from"];
}

- (void)handleIncbin:(NSArray<NSString *> *)arguments
{
    if (arguments.count < 1 || arguments.count > 3) {
        [_errors addErrorWithType:SFCError string:@"Directive incbin expects 1, 2 or 3 arguments"];
        return;
    }
    NSString *path = [self evaluateString:arguments[0]];
    if (!path) return;
    
    if (![path hasPrefix:@"/"]) {
        if (!_reader.directory) {
            [_errors addErrorWithType:SFCError string:@"Relative includes are not supported from this context"];
            return;
        }
        path = [_reader.directory stringByAppendingPathComponent:path];
    }
    
    size_t offset = 0;
    size_t size = 0;
    
    if (arguments.count > 1) {
        SFCValue *offsetValue = [self evaluate:arguments[1] allowUndefined:false];
        if (!offsetValue) return;
        if (!offsetValue.isInt) {
            [_errors addErrorWithType:SFCError string:@"Offset argument is not an integer"];
            return;
        }
        offset = offsetValue.intValue;
        
        if (arguments.count > 2) {
            SFCValue *sizeValue = [self evaluate:arguments[2] allowUndefined:false];
            if (!sizeValue) return;
            if (!sizeValue.isInt) {
                [_errors addErrorWithType:SFCError string:@"Size argument is not an integer"];
                return;
            }
            size = sizeValue.intValue;
        }
    }
    
    [_binDeps addObject:path];
    
    FILE *data = fopen(path.UTF8String, "rb");
    if (!data) {
        if (!_depsMode) {
            [_errors addErrorWithType:SFCError string:@"Could not open file %@: %s", path, strerror(errno)];
        }
        return;
    }
    
 
    fseek(data, 0, SEEK_END);
    size_t fileSize = ftell(data);
    if (arguments.count == 1)  {
        size = fileSize;
    }
    else {
        if (arguments.count == 2)  {
            size = fileSize - offset;
        }
        if (offset + size > fileSize || offset + size < offset) {
            [_errors addErrorWithType:SFCError string:@"Requested offset and size exceed the included file's size"];
            fclose(data);
            return;
        }
    }
    
    fseek(data, offset, SEEK_SET);
    uint8_t *temp = malloc(PAGE_SIZE);
    while (size) {
        ssize_t read = fread(temp, 1, MIN(PAGE_SIZE, size), data);
        if (read < 0) {
            [_errors addErrorWithType:SFCFatal string:@"Error reading file: %s", strerror(errno)];
            break;
        }
        size -= read;
        [self writeBytes:temp length:read];
        if (_errors.status == SFCFatal) break;
    }
    
    free(temp);
    fclose(data);
}

- (void)handleDefine:(NSArray<NSString *> *)arguments
{
    if (arguments.count == 0) {
        [_errors addErrorWithType:SFCError string:@"Directive define expects an argument"];
        return;
    }
    
    NSString *combined = [arguments componentsJoinedByString:@","];
    NSArray<NSString *> *tokens = [combined tokenizeByString:@" " maximumTokens:2];
    
    
    if (!tokens[0].isValidSFCSegment) {
        [_errors addErrorWithType:SFCError string:@"%@ is not a valid definition name", tokens[0]];
        return;
    }
    
    if (_definitions[tokens[0]]) {
        [_errors addErrorWithType:SFCWarning string:@"Redefining %@", tokens[0]];
    }
    
    if (!_definitions) _definitions = [NSMutableDictionary dictionary];
    
    _definitions[tokens[0]] = tokens.count == 2? tokens[1] : @"1";
    _definitionsRegex = [NSRegularExpression regularExpressionWithPattern:[NSString stringWithFormat:@"\\$(%@)(?![a-zA-Z0-9_])", [_definitions.allKeys componentsJoinedByString:@"|"]]
                                                                  options:0
                                                                    error:nil];
}

- (void)handleMacro:(NSArray<NSString *> *)arguments
{
    if (_definingMacro) {
        [_errors addErrorWithType:SFCError string:@"Nested macro definitions are not supported"];
        return;
    }
    
    if (arguments.count == 0) {
        [_errors addErrorWithType:SFCError string:@"Directive define expects at least 1 argument"];
        return;
    }
    NSString *combined = [arguments componentsJoinedByString:@","];
    NSArray<NSString *> *tokens = [combined tokenizeByString:@" " maximumTokens:2];
    arguments = tokens.count == 2? [tokens[1] tokenizeByString:@","] : @[];
    
    if (!tokens[0].isValidSFCSegment) {
        [_errors addErrorWithType:SFCError string:@"%@ is not a valid macro name", tokens[0]];
        return;
    }
    
    SEL selector = NSSelectorFromString([NSString stringWithFormat:@"handle%@:", tokens[0].lowercaseString.capitalizedString]);

    if ([self respondsToSelector:selector]) {
        [_errors addErrorWithType:SFCError string:@"%@ is reserved to a built-in instruction/directive", tokens[0]];
        return;
    }
    
    bool vaArgs = false;
    
    if (arguments.count && [arguments.lastObject hasSuffix:@"..."]) {
        vaArgs = true;
        arguments = [arguments mutableCopy];
        ((NSMutableArray *)arguments)[arguments.count - 1] = [arguments.lastObject substringToIndex:arguments.lastObject.length - 3];
    }
    
    for (NSString *argument in arguments) {
        if (!argument.isValidSFCSegment) {
            [_errors addErrorWithType:SFCError string:@"%@ is not a valid macro argument name", argument];
            return;
        }
    }
    
    if (_macros[tokens[0]]) {
        [_errors addErrorWithType:SFCWarning string:@"Redefining macro %@", tokens[0]];
    }

    if (!_macros) _macros = [NSMutableDictionary dictionary];
    _macros[tokens[0]] = _definingMacro = [[SFCMacro alloc] init];
    _definingMacro.name = tokens[0];
    _definingMacro.arguments = arguments;
    _definingMacro.definingFile = _reader.filename;
    _definingMacro.definingLine = _reader.currentLine;
    _definingMacro.contents = [NSMutableString string];
    _definingMacro.isVAArgs = vaArgs;
}

- (void)handleRept:(NSArray<NSString *> *)arguments
{
    ExpectArgumentCount("rept", 1);
    if (_reptDepth) {
        _reptDepth++;
        [_reptString appendFormat:@"rept %@\n", [arguments componentsJoinedByString:@", "]];
        return;
    }
    
    SFCValue *value = [self evaluate:arguments[0] allowUndefined:false];
    if (!value) return;
    if (!value.isInt) {
        [_errors addErrorWithType:SFCError string:@"Argument is not an integer"];
        return;
    }
    
    if ((unsigned)value.intValue > 0x10000) {
        [_errors addErrorWithType:SFCError string:@"Repeat count too high"];
        return;
    }
    
    _reptDepth++;
    _reptString = [NSMutableString string];
    _reptCount = value.intValue;
    _reptLine = _reader.currentLine;
}

- (void)handleEndr:(NSArray<NSString *> *)arguments
{
    ExpectArgumentCount("endr", 0);
    if (!_reptDepth) {
        [_errors addErrorWithType:SFCError string:@"endr without a matching rept"];
        return;
    }
    if (--_reptDepth == 0) {
        [_reader pushReader:[SFCStringLineReader readerWithString:_reptString
                                                         fileName:_reader.filename
                                                       lineOffset:_reader.currentLine
                                                          repeats:_reptCount]
                 withPrefix:@"Repeated from a REPT directive ending at"];
        _reptString = nil;
    }
    else {
        [_reptString appendString:@"endr\n"];
    }
}

- (void)handleEndmacro:(NSArray<NSString *> *)arguments
{
    ExpectArgumentCount("endmacro", 0)
    if (_definingStruct || !_definingMacro) {
        [_errors addErrorWithType:SFCError string:@"endmacro used outside of macro definition"];
    }
    _definingMacro = nil;
}

- (void)handleOrg:(NSArray<NSString *> *)arguments
{
    assert(_file || _depsMode);
    ExpectArgumentCount("org", 1)
    SFCValue *value = [self evaluate:arguments[0] allowUndefined:false];
    if (!value) return;
    if (!value.isInt) {
        [_errors addErrorWithType:SFCError string:@"Argument is not an integer"];
        return;
    }

    
    uint32_t org = value.intValue;
    if (_definingStruct) {
        [_definingMacro.contents appendFormat:@"org . + %d\n", org - _structOffset];
        _structOffset = org;
        return;
    }
    
    SFCSegment *newSegment = [_layout segmentForAddress:org];
    if (!newSegment) {
        [_errors addErrorWithType:SFCFatal string:@"Address %06x does not belong to any segment", org];
        return;
    }
    
    _org = org;
    _currentSegment = newSegment;
    
    uint32_t offsetInSegment = org - _currentSegment.address;
    
    if (_currentSegment.fileMapped) {
        if (_currentSegment.lastLocation > offsetInSegment) {
            [_errors addErrorWithType:SFCFatal string:@"Cannot rewind ROM segment %@ (from %06x to %06x)",
             _currentSegment.name, _currentSegment.lastLocation + _currentSegment.address, org];
            return;
        }
        if (_file) {
            fseek(_file, _currentSegment.lastLocation + _currentSegment.fileOffset, SEEK_SET);
            while (_currentSegment.lastLocation != offsetInSegment) {
                /* TODO: Optimize */
                uint8_t fill = _currentSegment.fillByte;
                _checksum += fill;
                if (fwrite(&fill, 1, 1, _file) != 1) {
                    [_errors addErrorWithType:SFCFatal string:@"Failed to write to ROM: %s", strerror(errno)];
                    return;
                }
                _currentSegment.lastLocation++;
            }
        }
        else {
            _currentSegment.lastLocation = offsetInSegment;
        }
        if (_currentSegment.flexibleSize) {
            _currentSegment.size = _currentSegment.lastLocation;
        }
    }
    else {
        _currentSegment.lastLocation = offsetInSegment;
        if (_currentSegment.flexibleSize && _currentSegment.lastLocation > _currentSegment.size) {
            _currentSegment.size = _currentSegment.lastLocation;
        }
    }
}

- (void)handleDs:(NSArray<NSString *> *)arguments
{
    assert(_file || _depsMode);
    ExpectArgumentCount("ds", 1)
    SFCValue *value = [self evaluate:arguments[0] allowUndefined:false];
    if (!value) return;
    if (!value.isInt) {
        [_errors addErrorWithType:SFCError string:@"Argument is not an integer"];
        return;
    }
    
    if (value.intValue < 0) {
        [_errors addErrorWithType:SFCError string:@"Expected non-negative argument, got %lld", value.intValue];
        return;
    }
    
    if (_definingStruct) {
        [_definingMacro.contents appendFormat:@"ds %lld\n", value.intValue];
        _structOffset += value.intValue;
        return;
    }
    
    if (!_currentSegment) {
        [_errors addErrorWithType:SFCError string:@"Data defined before before org being set"];
        return;
    }
    
    uint32_t org = _org + value.intValue;
    if (_org > org) {
        [_errors addErrorWithType:SFCError string:@"Integer overflow"];
        return;
    }
    
    if ([_layout segmentForAddress:org] != _currentSegment) {
        [_errors addErrorWithType:SFCFatal string:@"Segment %@ overflowed (0x%06x, max address is 0x%06x)",
                                                 _currentSegment.name, org, _currentSegment.address + _currentSegment.maxSize];
        return;
    }
    
    _org = org;
    uint32_t offsetInSegment = org - _currentSegment.address;
    
    if (_currentSegment.fileMapped) {
        if (_currentSegment.lastLocation > offsetInSegment) {
            [_errors addErrorWithType:SFCFatal string:@"Cannot rewind ROM segment %@ (from %06x to %06x)",
             _currentSegment.name, _currentSegment.lastLocation + _currentSegment.address, org];
            return;
        }
        if (_file) {
            fseek(_file, _currentSegment.lastLocation + _currentSegment.fileOffset, SEEK_SET);
            while (_currentSegment.lastLocation != offsetInSegment) {
                /* TODO: Optimize */
                uint8_t fill = _currentSegment.fillByte;
                _checksum += fill;
                if (fwrite(&fill, 1, 1, _file) != 1) {
                    [_errors addErrorWithType:SFCFatal string:@"Failed to write to ROM: %s", strerror(errno)];
                    return;
                }
                _currentSegment.lastLocation++;
            }
        }
        else {
            _currentSegment.lastLocation = offsetInSegment;
        }
        if (_currentSegment.flexibleSize) {
            _currentSegment.size = _currentSegment.lastLocation;
        }
    }
    else {
        _currentSegment.lastLocation = offsetInSegment;
        if (_currentSegment.flexibleSize && _currentSegment.lastLocation > _currentSegment.size) {
            _currentSegment.size = _currentSegment.lastLocation;
        }
    }
}

- (void)handleDb:(NSArray<NSString *> *)arguments
{
    if (_definingStruct) {
        [_definingMacro.contents appendFormat:@"db %@\n", [arguments componentsJoinedByString:@", "]];
        _structOffset += arguments.count;
        return;
    }
    
    for (NSString *arg in arguments) {
        SFCValue *value = [self evaluate:arg allowUndefined:true];
        if (!value) continue;
        if (value.isString) {
            if (!_currentEncoding) {
                [self writeBytes:value.dataValue.bytes length:value.dataValue.length];
            }
            else {
                NSMutableDictionary<NSNumber *,NSNumber *> *encoding = _encodings[_currentEncoding];
                for (unsigned i = 0; i < value.stringValue.length; i++) {
                    NSNumber *encoded = encoding[@([value.stringValue characterAtIndex:i])];
                    if (!encoded) {
                        [_errors addErrorWithType:SFCError string:@"Character \"%@\" cannot be encoded with %@", [value.stringValue substringWithRange:NSMakeRange(i, 1)], _currentEncoding];
                        // Don't stop, generate other errors for this string
                    }
                    uint8_t byte = encoded.intValue;
                    [self writeBytes:&byte length:1];
                }
            }
        }
        else if (value.isDouble) {
            [_errors addErrorWithType:SFCError string:@"Expression \"%@\" must be an integer or a string", arg];
        }
        else {
            [self addRelocation:value size:1 validation:SFCRelValidationRange expectedHigh:0];
        }
        if (_errors.status == SFCFatal) return;
    }
}

- (void)handleDw:(NSArray<NSString *> *)arguments
{
    if (_definingStruct) {
        [_definingMacro.contents appendFormat:@"dw %@\n", [arguments componentsJoinedByString:@", "]];
        _structOffset += arguments.count * 2;
        return;
    }
    
    for (NSString *arg in arguments) {
        SFCValue *value = [self evaluate:arg allowUndefined:true];
        if (!value) continue;
        [self addRelocation:value size:2 validation:SFCRelValidationRange expectedHigh:0];
        if (_errors.status == SFCFatal) return;
    }
}

- (void)handleDf:(NSArray<NSString *> *)arguments
{
    if (_definingStruct) {
        [_definingMacro.contents appendFormat:@"df %@\n", [arguments componentsJoinedByString:@", "]];
        _structOffset += arguments.count * 3;
        return;
    }
    
    for (NSString *arg in arguments) {
        SFCValue *value = [self evaluate:arg allowUndefined:true];
        if (!value) continue;
        [self addRelocation:value size:3 validation:SFCRelValidationRange expectedHigh:0];
        if (_errors.status == SFCFatal) return;
    }
}

- (void)handleDl:(NSArray<NSString *> *)arguments
{
    if (_definingStruct) {
        [_definingMacro.contents appendFormat:@"dl %@\n", [arguments componentsJoinedByString:@", "]];
        _structOffset += arguments.count * 4;
        return;
    }
    
    for (NSString *arg in arguments) {
        SFCValue *value = [self evaluate:arg allowUndefined:true];
        if (!value) continue;
        [self addRelocation:value size:4 validation:SFCRelValidationRange expectedHigh:0];
        if (_errors.status == SFCFatal) return;
    }
}

// built-in macro
- (void)handleDa:(NSArray<NSString *> *)arguments
{
    NSMutableArray *newArgs = [NSMutableArray arrayWithCapacity:arguments.count];
    for (NSString *arg in arguments) {
        [newArgs addObject:[NSString stringWithFormat:@"addr(%@)", arg]];
    }
    [self handleDw:newArgs];
}


- (void)handleSegment:(NSArray<NSString *> *)arguments
{
    assert(_file || _depsMode);
    ExpectArgumentCount("segment", 1)
    NSString *name = [self evaluateString:arguments[0]];
    if (!name) return;
    
    if (_definingStruct) {
        [_errors addErrorWithType:SFCFatal string:@"Cannot change segment while defining a struct"];
        return;
    }
    
    SFCSegment *newSegment = [_layout segmentWithName:name];
    if (!newSegment) {
        [_errors addErrorWithType:SFCFatal string:@"No segment named '%@'", name];
        return;
    }
    _lastGlobalLabel = nil;
    _evaluator.currentScope = nil;
    _currentSegment = newSegment;
    _org = newSegment.lastLocation + newSegment.address;
    if (_file) {
        fseek(_file, _currentSegment.lastLocation + _currentSegment.fileOffset, SEEK_SET);
    }
}

- (void)handleIf:(NSArray<NSString *> *)arguments
{
    ExpectArgumentCount("if", 1)
    if (_ifDepth == sizeof(_ifStack)) {
        [_errors addErrorWithType:SFCFatal string:@"If nesting too deep"];
        return;
    }
    if (_ifDepth && _ifStack[_ifDepth - 1] < IfStateIfTrue) {
        _ifStack[_ifDepth++] = IfStateNestedFalse;
        return;
    }
    bool truth = [self evaluateBool:arguments[0]];
    _ifStack[_ifDepth++] = truth? IfStateIfTrue : IfStateIfFalse;
}

- (bool)isDefined:(NSString *)string
{
    if (!string.isValidSFCSymbol) {
        [_errors addErrorWithType:SFCError string:@"Invalid symbol name '%@'", string];
        return false;
    }
    if (_macros[string]) return true;
    if (_definitions[string]) return true;
    return [_evaluator getVariable:string];
}

- (void)handleIfdef:(NSArray<NSString *> *)arguments
{
    ExpectArgumentCount("ifdef", 1)
    if (_ifDepth == sizeof(_ifStack)) {
        [_errors addErrorWithType:SFCFatal string:@"If nesting too deep"];
        return;
    }
    
    if (_ifDepth && _ifStack[_ifDepth - 1] < IfStateIfTrue) {
        _ifStack[_ifDepth++] = IfStateNestedFalse;
        return;
    }
    
    _ifStack[_ifDepth++] = [self isDefined:arguments[0]]? IfStateIfTrue : IfStateIfFalse;
}

- (void)handleIfndef:(NSArray<NSString *> *)arguments
{
    ExpectArgumentCount("ifndef", 1)
    if (_ifDepth == sizeof(_ifStack)) {
        [_errors addErrorWithType:SFCFatal string:@"If nesting too deep"];
        return;
    }
    
    if (_ifDepth && _ifStack[_ifDepth - 1] < IfStateIfTrue) {
        _ifStack[_ifDepth++] = IfStateNestedFalse;
        return;
    }
    
    _ifStack[_ifDepth++] = [self isDefined:arguments[0]]? IfStateIfFalse : IfStateIfTrue;
}

- (void)handleElse:(NSArray<NSString *> *)arguments
{
    ExpectArgumentCount("else", 0)
    if (_ifDepth == 0) {
        [_errors addErrorWithType:SFCError string:@"else without a matching if"];
        return;
    }
    
    switch (_ifStack[_ifDepth - 1]) {
        case IfStateIfFalse:
            _ifStack[_ifDepth - 1] = IfStateElseTrue;
            return;;
        case IfStateElseFalse:
        case IfStateElseTrue:
            [_errors addErrorWithType:SFCError string:@"Two else directiving inside a single if"];
            return;
        case IfStateNestedFalse:
            return;
        case IfStateIfTrue:
        case IfStateElifFinalFalse:
            _ifStack[_ifDepth - 1] = IfStateElseFalse;
            return;
    }
}

- (void)handleEndif:(NSArray<NSString *> *)arguments
{
    ExpectArgumentCount("endif", 0)
    if (_ifDepth == 0) {
        [_errors addErrorWithType:SFCError string:@"Endif without a matching if"];
        return;
    }
    
    _ifDepth--;
}

- (void)handleElif:(NSArray<NSString *> *)arguments
{
    ExpectArgumentCount("elif", 1)
    if (_ifDepth == 0) {
        [_errors addErrorWithType:SFCError string:@"elif without a matching if"];
        return;
    }
    
    switch (_ifStack[_ifDepth - 1]) {
        case IfStateIfFalse:
            _ifStack[_ifDepth - 1] = [self evaluateBool:arguments[0]]? IfStateIfTrue : IfStateIfFalse;
            return;
        case IfStateElseFalse:
        case IfStateElseTrue:
            [_errors addErrorWithType:SFCError string:@"elif directiving inside an else clause"];
            return;
        case IfStateNestedFalse:
            return;
        case IfStateElifFinalFalse:
            return;
        case IfStateIfTrue:
            _ifStack[_ifDepth - 1] = IfStateElifFinalFalse;
            break;
    }
}

- (void)handleElifdef:(NSArray<NSString *> *)arguments
{
    ExpectArgumentCount("elifdef", 1)
    if (_ifDepth == 0) {
        [_errors addErrorWithType:SFCError string:@"elifdef without a matching if"];
        return;
    }
    
    switch (_ifStack[_ifDepth - 1]) {
        case IfStateIfFalse:
            _ifStack[_ifDepth - 1] = [self isDefined:arguments[0]]? IfStateIfTrue : IfStateIfFalse;
            return;
        case IfStateElseFalse:
        case IfStateElseTrue:
            [_errors addErrorWithType:SFCError string:@"elif directiving inside an else clause"];
            return;
        case IfStateNestedFalse:
            return;
        case IfStateElifFinalFalse:
            return;
        case IfStateIfTrue:
            _ifStack[_ifDepth - 1] = IfStateElifFinalFalse;
            break;
    }
}

- (void)handleElifndef:(NSArray<NSString *> *)arguments
{
    ExpectArgumentCount("elifndef", 1)
    if (_ifDepth == 0) {
        [_errors addErrorWithType:SFCError string:@"elifdef without a matching if"];
        return;
    }
    
    switch (_ifStack[_ifDepth - 1]) {
        case IfStateIfFalse:
            _ifStack[_ifDepth - 1] = [self isDefined:arguments[0]]? IfStateIfFalse : IfStateIfTrue;
            return;
        case IfStateElseFalse:
        case IfStateElseTrue:
            [_errors addErrorWithType:SFCError string:@"elif directiving inside an else clause"];
            return;
        case IfStateNestedFalse:
            return;
        case IfStateElifFinalFalse:
            return;
        case IfStateIfTrue:
            _ifStack[_ifDepth - 1] = IfStateElifFinalFalse;
            break;
    }
}

- (void)handleWarning:(NSArray<NSString *> *)arguments
{
    NSMutableString *string = [NSMutableString string];
    for (NSString *arg in arguments) {
        SFCValue *value = [self evaluate:arg allowUndefined:false];
        if (!value) return;
        if (value.isString) {
            [string appendString:value.stringValue];
            [string appendString:@" "];
        }
        else {
            [string appendString:value.expressionValue];
            [string appendString:@" "];
        }
    }
    [_errors addErrorWithType:SFCWarning string:@"User warning: %@", string];
}

- (void)handleError:(NSArray<NSString *> *)arguments
{
    NSMutableString *string = [NSMutableString string];
    for (NSString *arg in arguments) {
        SFCValue *value = [self evaluate:arg allowUndefined:false];
        if (!value) return;;
        if (value.isString) {
            [string appendString:value.stringValue];
            [string appendString:@" "];
        }
        else {
            [string appendString:value.expressionValue];
            [string appendString:@" "];
        }
    }
    [_errors addErrorWithType:SFCError string:@"User error: %@", string];
}

- (void)handleFatal:(NSArray<NSString *> *)arguments
{
    NSMutableString *string = [NSMutableString string];
    for (NSString *arg in arguments) {
        SFCValue *value = [self evaluate:arg allowUndefined:false];
        if (!value) return;;
        if (value.isString) {
            [string appendString:value.stringValue];
            [string appendString:@" "];
        }
        else {
            [string appendString:value.expressionValue];
            [string appendString:@" "];
        }
    }
    [_errors addErrorWithType:SFCFatal string:@"User fatal error: %@", string];
}

- (void)handleStruct:(NSArray<NSString *> *)arguments
{
    if (_definingStruct) {
        [_errors addErrorWithType:SFCError string:@"Already inside a struct definition"];
        return;
    }
    
    NSString *combined = [arguments componentsJoinedByString:@","];
    NSArray<NSString *> *tokens = [combined tokenizeByString:@" " maximumTokens:2];
    arguments = tokens.count == 2? [tokens[1] tokenizeByString:@","] : @[];

    
    if (!tokens[0].isValidSFCSegment) {
        [_errors addErrorWithType:SFCError string:@"'%@' is not a valid struct name", tokens[0]];
        return;
    }
    if ([_evaluator getVariable:[NSString stringWithFormat:@"%@.sizeof", tokens[0]]]) {
        [_errors addErrorWithType:SFCError string:@"Struct '%@' already exists (%@.sizeof is already defined)", tokens[0], tokens[0]];
        return;
    }
    
    SEL selector = NSSelectorFromString([NSString stringWithFormat:@"handle%@:", tokens[0].lowercaseString.capitalizedString]);
    
    if ([self respondsToSelector:selector]) {
        [_errors addErrorWithType:SFCError string:@"%@ is reserved to a built-in instruction/directive", tokens[0]];
        return;
    }
    
    for (NSString *argument in arguments) {
        if (!argument.isValidSFCSegment) {
            [_errors addErrorWithType:SFCError string:@"%@ is not a valid struct argument name", argument];
            return;
        }
    }
    _definingStruct = tokens[0];
    if (!_macros) _macros = [NSMutableDictionary dictionary];
    _macros[_definingStruct] = _definingMacro = [[SFCMacro alloc] init];
    _definingMacro.name = _definingStruct;
    _definingMacro.arguments = arguments;
    _definingMacro.definingFile = [NSString stringWithFormat:@"<struct %@>", _definingStruct];
    _definingMacro.definingLine = 1;
    _definingMacro.contents = [NSMutableString string];
    _structOffset = 0;

}

- (void)handleEndstruct:(NSArray<NSString *> *)arguments
{
    ExpectArgumentCount("endstruct", 0)

    if (!_definingStruct) {
        [_errors addErrorWithType:SFCError string:@"Not in a struct definition"];
        return;
    }

    [_definingMacro.contents appendFormat:@".sizeof = 0x%x\n", _structOffset];
    [_evaluator setVariable:[NSString stringWithFormat:@"%@.sizeof", _definingStruct] withValue:[SFCValue valueWithInt:_structOffset]];
    _definingStruct = nil;
    _definingMacro = nil;
}

- (void)handleUnset:(NSArray<NSString *> *)arguments
{
    ExpectArgumentCount("unset", 1)
    
    SFCValue *value = [_evaluator getVariable:arguments[0]];
    if (!value) {
        [_errors addErrorWithType:SFCWarning string:@"Variable '%@' is not set", arguments[0]];
        return;
    }
    
    if (value.isSymbol) {
        [_errors addErrorWithType:SFCWarning string:@"Cannot unset symbol '%@'", arguments[0]];
        return;
    }
    
    if ([_unresolvedSymbols containsObject:arguments[0]]) {
        [_errors addErrorWithType:SFCError string:@"'%@' was referenced before its initial assignment, so it must remain constant", arguments[0]];
        return;
    }
    
    [_evaluator setVariable:arguments[0] withValue:nil];
}

- (void)handleUndef:(NSArray<NSString *> *)arguments
{
    ExpectArgumentCount("undef", 1)
    
    if (!_definitions[arguments[0]]) {
        [_errors addErrorWithType:SFCWarning string:@"Definition '%@' is not defined", arguments[0]];
        return;
    }

    _definitions[arguments[0]] = nil;
    _definitionsRegex = [NSRegularExpression regularExpressionWithPattern:[NSString stringWithFormat:@"\\$(%@)(?![a-zA-Z0-9_])", [_definitions.allKeys componentsJoinedByString:@"|"]]
                                                                  options:0
                                                                    error:nil];
}

- (void)handleUnmacro:(NSArray<NSString *> *)arguments
{
    ExpectArgumentCount("unmacro", 1)
    
    if (!_macros[arguments[0]]) {
        [_errors addErrorWithType:SFCWarning string:@"Macro '%@' is not defined", arguments[0]];
        return;
    }
    
    _macros[arguments[0]] = nil;
}

- (void)handleEncoding:(NSArray<NSString *> *)arguments
{
    ExpectArgumentCount("encoding", 1)
    if ([arguments[0] isEqualToString:@"raw"]) {
        _currentEncoding = nil;
        _evaluator.encoding = nil;
    }
    else if (_encodings[arguments[0]]) {
        _currentEncoding = arguments[0];
        _evaluator.encoding = _encodings[arguments[0]];
    }
    else {
        [_errors addErrorWithType:SFCError string:@"Encoding '%@' is not defined", arguments[0]];
    }
}

- (void)handleEncode:(NSArray<NSString *> *)arguments
{
    ExpectArgumentCount("encode", 3)
    NSString *encoding = arguments[0];
    
    NSString *string = [self evaluateString:arguments[1]];
    if (!string) return;
    SFCValue *value = [self evaluate:arguments[2] allowUndefined:false];
    if (!value) return;
    if (!value.isInt) {
        [_errors addErrorWithType:SFCError string:@"Encoding byte is not an integer"];
        return;
    }
    
    if ([arguments[0] isEqualToString:@"raw"]) {
        [_errors addErrorWithType:SFCError string:@"The raw encoding cannot be modified"];
        return;
    }
    
    if (!encoding.isValidSFCSegment) {
        [_errors addErrorWithType:SFCError string:@"Invalid encoding name '%@'", encoding];
        return;
    }
    
    if (!_encodings) {
        _encodings = [NSMutableDictionary dictionary];
    }
    if (!_encodings[encoding]) {
        _encodings[encoding] = [NSMutableDictionary dictionary];
    }
    
    unsigned encoded = value.intValue;
    if ((uint64_t)(encoded + string.length) > 255) {
        [_errors addErrorWithType:SFCError string:@"Encoding overflows a byte's range"];
        return;
    }
    for (unsigned i = 0; i < string.length; i++) {
        _encodings[encoding][@([string characterAtIndex:i])] = @(i + encoded);
    }
}

- (NSString *)expandDefinitions:(NSString *)line
{
    if (!_definitionsRegex) return line;
    NSArray *results = [_definitionsRegex matchesInString:line
                                                  options:0
                                                    range:NSMakeRange(0, line.length)];
    
    if (!results.count) return line;
    NSMutableString *ret = [line mutableCopy];
    for (NSTextCheckingResult *result in [results reverseObjectEnumerator]) {
        NSString *defName = [ret substringWithRange:NSMakeRange(result.range.location + 1, result.range.length - 1)];
        [ret replaceCharactersInRange:result.range withString:_definitions[defName]];
    }
    return ret;
}

- (void)handleMacro:(SFCMacro *)macro arguments:(NSArray *)arguments
{
    if (macro.arguments.count != arguments.count) {
        [_errors addErrorWithType:SFCError string:@"Expected %s%u macro argument(s), got %u", macro.isVAArgs? "at least " : "",
                                                                                              (unsigned)macro.arguments.count,
                                                                                              (unsigned)arguments.count];
        return;
    }
    
    if (arguments.count) {
        NSMutableString *contents = macro.contents.mutableCopy;
        
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:[NSString stringWithFormat:@"\\$(%@)(?![a-zA-Z0-9_])", [macro.arguments componentsJoinedByString:@"|"]]
                                                                               options:0
                                                                                 error:nil];
        
        NSArray *results = [regex matchesInString:contents
                                          options:0
                                            range:NSMakeRange(0, contents.length)];
        
        for (NSTextCheckingResult *result in [results reverseObjectEnumerator]) {
            NSString *argumentName = [contents substringWithRange:NSMakeRange(result.range.location + 1, result.range.length - 1)];
            [contents replaceCharactersInRange:result.range withString:arguments[[macro.arguments indexOfObject:argumentName]]];
        }
        
        [_reader pushReader:[SFCStringLineReader readerWithString:contents
                                                         fileName:macro.definingFile
                                                       lineOffset:macro.definingLine]
            withPrefix:[NSString stringWithFormat:@"Expanded from macro %@ at", macro.name]];
    }
    else {
        [_reader pushReader:[SFCStringLineReader readerWithString:macro.contents
                                                         fileName:macro.definingFile
                                                       lineOffset:macro.definingLine]
                 withPrefix:[NSString stringWithFormat:@"Expanded from macro %@ at", macro.name]];
    }
}


- (void)writeBytes:(const uint8_t *)bytes length:(size_t)length
{
    assert(_file || _depsMode);
    if (_definingStruct) {
        [_errors addErrorWithType:SFCError string:@"Cannot write data inside a struct definition"];
        return;
    }
    if (!_currentSegment) {
        [_errors addErrorWithType:SFCError string:@"Data defined before before org being set"];
        return;
    }
    if (!_currentSegment.fileMapped) {
        [_errors addErrorWithType:SFCError string:@"Cannot write data to RAM segment %@", _currentSegment.name];
        return;
    }
    if (_currentSegment.lastLocation + length > _currentSegment.maxSize) {
        [_errors addErrorWithType:SFCFatal string:@"Segment %@ overflowed (0x%06x, max address is 0x%06x)",
         _currentSegment.name, _org + (uint32_t)length, _currentSegment.address + _currentSegment.maxSize];
        return;
    }
    
    if (!_file) {
        _currentSegment.lastLocation += length;
        _org += length;
        if (_currentSegment.flexibleSize) {
            _currentSegment.size = _currentSegment.lastLocation;
        }
        return;
    }
    
    for (unsigned i = 0; i < length; i++) {
        _checksum += bytes[i];
    }
    
    while (length) {
        ssize_t written = fwrite(bytes, 1, length, _file);
        if (written < 0) {
            [_errors addErrorWithType:SFCFatal string:@"Could not write to output file: %s", strerror(errno)];
            return;
        }
        length -= written;
        bytes += written;
        _currentSegment.lastLocation += written;
        _org += written;
        if (_currentSegment.flexibleSize) {
            _currentSegment.size = _currentSegment.lastLocation;
        }
    }
}

- (void)writeRelocation:(SFCRelocation *)relocation
{
    NSRange errorRange;
    NSString *error;
    SFCValue *value = [_evaluator evaluate:relocation.expression errorString:&error errorRange:&errorRange];
    
    if (!value) {
        [_errors addErrorWithType:SFCError string:@"%@:%@ ('%@')", relocation.lineDescription, error, [relocation.expression substringWithRange:errorRange]];
        return;
    }
    
    if (value.isMissingSymbolsSet) {
        [_errors addErrorWithType:SFCError string:@"%@: Unresolved symbol(s): %@", relocation.lineDescription, [value.missingSymbolsSet.allObjects componentsJoinedByString:@", "]];
        return;
    }
    
    if (!value.isInt) {
        [_errors addErrorWithType:SFCError string:@"%@: Expected integer value", relocation.lineDescription];
        return;
    }
    
    int64_t resolved = value.intValue;
    int64_t min, max;
    switch (relocation.validation) {
        case SFCRelValidationRange:
            max = ((uint64_t)0x100 << (relocation.size * 8 - 8)) - 1;
            min = ~max;
            break;
        case SFCRelValidationSigned:
            min = -(0x80 << (relocation.size * 8 - 8));
            max = (0x80 << (relocation.size * 8 - 8)) - 1;
            break;
        case SFCRelValidationUnsigned:
            min = 0;
            max = ((uint64_t)0x100 << (relocation.size * 8 - 8)) - 1;
            break;
        case SFCRelValidationHigh:
            min = relocation.expectedHigh;
            max = min + (0x100 << (relocation.size * 8 - 8)) - 1;
            break;
    }
    
    id oldErrorsReader = _errors.activeReader;
    _errors.activeReader = nil;
    if (relocation.validation == SFCRelValidationHigh && (resolved >> (relocation.size * 8)) == 0) {
        // SFCRelValidationHigh allows out-of-range 0 values
    }
    else if (resolved < min || resolved > max) {
        if (min < 0) {
            [_errors addErrorWithType:SFCWarning string:@"%@: Relocation value (0x%06llx) out of range (%lld - %lld) and will be truncated", relocation.lineDescription, resolved, min, max];
        }
        else {
            [_errors addErrorWithType:SFCWarning string:@"%@: Relocation value (0x%06llx) out of range (0x%06llx - 0x%06llx) and will be truncated", relocation.lineDescription, resolved, min, max];
        }
    }
    fseek(_file, relocation.fileOffset, SEEK_SET);
    uint8_t bytes[4];
    bytes[0] = resolved;
    bytes[1] = resolved >> 8;
    bytes[2] = resolved >> 16;
    bytes[3] = resolved >> 24;
    _errors.activeReader = oldErrorsReader;
    for (unsigned i = 0; i < relocation.size; i++) {
        _checksum += bytes[i];
    }
    if (fwrite(bytes, 1, relocation.size, _file) != relocation.size) {
        [_errors addErrorWithType:SFCFatal string:@"Failed to write relocation to file: %s", strerror(errno)];
        return;
    }
}

- (void)addRelocation:(SFCValue *)expression size:(uint8_t)size validation:(SFCRelValidation)validation expectedHigh:(uint32_t)high
{
    static const uint8_t placeholder[4] = {0,};
    if (_depsMode) {
        [self writeBytes:placeholder length:size];
        return;
    }
    
    assert(_file);
    assert(expression);
    SFCRelocation *relocation = [[SFCRelocation alloc] init];
    if (!_relocations) _relocations = [NSMutableArray array];
    
    relocation.expression = expression.expressionValue;
    if (relocation.expression.isPlusMinusLabel) {
        relocation.expression = [self translatePlusMinusLabel:relocation.expression isNew:false];
    }
    relocation.fileOffset = ftell(_file);
    relocation.lineDescription = _reader.lastLineDescription;
    relocation.size = size;
    relocation.expectedHigh = high;
    relocation.validation = validation;
    
    [self writeBytes:placeholder length:size];
    
    if (!expression.isMissingSymbolsSet) {
        [self writeRelocation:relocation];
        return;
    }
    
    if (!_unresolvedSymbols) _unresolvedSymbols = [NSMutableSet set];
    [_unresolvedSymbols unionSet:expression.missingSymbolsSet];
    [_relocations addObject:relocation];
}

- (void)link
{
    for (SFCRelocation *relocation in _relocations) {
        [self writeRelocation:relocation];
        if (_errors.status == SFCFatal) return;
    }
}

- (void)applyPadding
{
    for (SFCSegment *segment in _layout.segments) {
        if (!segment.fileMapped) continue;
        if (segment.flexibleSize) {
            if (!segment.sizeAlignment) continue;
            segment.size += segment.sizeAlignment - 1;
            segment.size &= ~(segment.sizeAlignment - 1);
        }
        if (segment.lastLocation == segment.size) continue;
        
        fseek(_file, segment.lastLocation + segment.fileOffset, SEEK_SET);
        uint8_t fill = _currentSegment.fillByte;
        while (segment.lastLocation != segment.size) {
            /* TODO: Optimize */
            _checksum += fill;
            if (fwrite(&fill, 1, 1, _file) != 1) {
                [_errors addErrorWithType:SFCFatal string:@"Failed to write to ROM: %s", strerror(errno)];
                return;
            }
            
            segment.lastLocation++;
        }
    }
}

- (NSString *)translatePlusMinusLabel:(NSString *)label isNew:(bool)isNew;
{
    if ([label hasPrefix:@"-"]) {
        return [NSString stringWithFormat:@"__Minus_Label_%u", (unsigned)label.length];
    }
    if (!_plusLabelCount) {
        _plusLabelCount = [NSMutableDictionary dictionary];
    }
    
    unsigned count = _plusLabelCount[@(label.length)].unsignedIntValue;
    NSString *ret = [NSString stringWithFormat:@"__Plus_Label_%u_%u", (unsigned)label.length, count];
    if (isNew) {
        _plusLabelCount[@(label.length)] = @(count + 1);
    }
    return ret;
}

- (void)assemble:(id<SFCLineReader>)topReader toFile:(NSString *)path errorSet:(SFCErrorSet *)errors
{
    if (!_sourceDeps) _sourceDeps = [NSMutableSet set];
    if (!_binDeps) _binDeps = [NSMutableSet set];
    
    _errors = errors;
    if (path) {
        _file = fopen(path.UTF8String, "wb+");
        
        if (!_file) {
            [_errors addErrorWithType:SFCFatal string:@"Could not open output file %@: %s", path, strerror(errno)];
            return;
        }
    }
    
    _reader = [[SFCStackedLineReader alloc] init];
    [_reader pushReader:topReader withPrefix:@""];
    _errors.activeReader = _reader;
    
    NSSet *macroWhitelist = [NSSet setWithArray:@[@"endmacro", @"macro"]];
    NSSet *reptWhitelist = [NSSet setWithArray:@[@"rept", @"endr"]];
    NSSet *conditionalWhitelist = [NSSet setWithArray:@[@"if", @"elif", @"else", @"endif", @"ifdef", @"elifdef", @"ifnindef", @"elifndef"]];
    
    while (!_reader.eof) {
        @autoreleasepool {
            NSSet *whitelist = nil;
            if (_definingMacro && !_definingStruct) whitelist = macroWhitelist;
            if (_ifDepth && _ifStack[_ifDepth - 1] < IfStateIfTrue) whitelist = conditionalWhitelist;
            if (_reptDepth) whitelist = reptWhitelist;

            // Labels
            NSString *line = [_reader readLineWithErrorSet:_errors];
            if (_errors.status == SFCFatal) break;
            if (!line) continue;
            
            NSString *rawLine = line;
            
            line = [line tokenizeByString:@";" maximumTokens:2][0];
            if (line.length == 0) {
                if (_definingMacro && !_definingStruct) {
                    [_definingMacro.contents appendFormat:@"%@\n", rawLine];
                }
                else if (_reptDepth) {
                    [_reptString appendFormat:@"%@\n", rawLine];
                }
                continue;
            }
            
            if (_trailedCommaLine) {
                line = [_trailedCommaLine stringByAppendingFormat:@" %@", line];
                _trailedCommaLine = nil;
            }
            
            if ([line hasSuffix:@","]) {
                _trailedCommaLine = line;
                continue;
            }
            
            if (_definingStruct) {
                [_evaluator setVariable:@"." withValue:[SFCValue valueWithInt:_structOffset]];
            }
            else if (_org != -1) {
                [_evaluator setVariable:@"." withValue:[SFCValue valueWithInt:_org]];
            }
            else {
                [_evaluator setVariable:@"." withValue:nil];
            }
            
            line = [self expandDefinitions:line];
            bool isWeak = false;
            if ([line hasSuffix:@":?"] || ([line hasSuffix:@"?"] && [line hasPrefix:@"."])) {
                isWeak = true;
                line = [line substringToIndex:line.length - 1];
            }
            if (!whitelist && ([line hasPrefix:@"."] || [line isPlusMinusLabel] || [line hasSuffix:@":"]) && ![line containsString:@" "] && ![line containsString:@"\t"]) {
                if (_org == -1 && !_definingStruct) {
                    [_errors addErrorWithType:SFCError string:@"Label defined before before org being set"];
                    continue;
                }
                
                NSString *symbol = line;
                if ([symbol hasSuffix:@":"]) {
                    symbol = [symbol substringToIndex:symbol.length - 1];
                }
                
                if (!(symbol.validSFCSymbol || symbol.isPlusMinusLabel) || [symbol isEqual:@"."]) {
                    [_errors addErrorWithType:SFCError string:@"'%@' is not a valid symbol name", symbol];
                    continue;
                }
                
                bool isPlusMinus = false;
                if (symbol.isPlusMinusLabel) {
                    symbol = [self translatePlusMinusLabel:symbol isNew:true];
                    isPlusMinus = true;
                }
                else {
                    SFCValue *value = [_evaluator getVariable:symbol];
                    if (value) {
                        if (!isWeak) {
                            [_errors addErrorWithType:SFCError string:@"'%@' is already a defined %@", symbol, value.isSymbol? @"symbol" : @"variable"];
                        }
                        continue;
                    }
                }
                
                SFCValue *value = [SFCValue valueWithInt:_definingStruct? _structOffset : _org];
                value.isSymbol = !_definingStruct;
                if ([symbol hasPrefix:@"."]) {
                    if (_definingStruct) {
                        [_definingMacro.contents appendFormat:@"%@:?\n", symbol];
                        [_evaluator setVariable:[NSString stringWithFormat:@"%@%@", _definingStruct, symbol] withValue:value];
                        continue;
                    }
                    if (!_lastGlobalLabel) {
                        [_errors addErrorWithType:SFCError string:@"Cannot define local label '%@' because no global label has been set yet", symbol];
                        continue;
                    }
                    [_evaluator setVariable:[NSString stringWithFormat:@"%@%@", _lastGlobalLabel, symbol] withValue:value];
                }
                else {
                    if (_definingStruct) {
                        [_errors addErrorWithType:SFCError string:@"Cannot define global label '%@' inside a struct definition", symbol];
                        continue;
                    }
                    if (!isPlusMinus) {
                        _lastGlobalLabel = symbol;
                        _evaluator.currentScope = symbol;
                    }
                    [_evaluator setVariable:symbol withValue:value];
                }
                continue;
            }
            
            // Variables
            NSArray<NSString *> *tokens = [line tokenizeByString:@"=" maximumTokens:2];
            if (!whitelist && tokens.count == 2 && tokens[0].validSFCSymbol) {
                NSString *symbol = tokens[0];
                
                if ([symbol isEqual:@"."]) {
                    [_errors addErrorWithType:SFCError string:@"'%@' is not a valid symbol name", symbol];
                    continue;
                }
                
                SFCValue *value = [_evaluator getVariable:symbol];
                if (value.isSymbol) {
                    [_errors addErrorWithType:SFCError string:@"'%@' is already a defined symbol", symbol];
                    continue;
                }
                
                if (value && [_unresolvedSymbols containsObject:symbol]) {
                    [_errors addErrorWithType:SFCError string:@"'%@' was referenced before its initial assignment, so it must remain constant", symbol];
                    continue;
                }
                
                value = [self evaluate:tokens[1] allowUndefined:false];
                if (!value) {
                    if (_errors.status == SFCFatal) return;
                    continue;
                }
                if ([symbol hasPrefix:@"."]) {
                    if (!_lastGlobalLabel) {
                        [_errors addErrorWithType:SFCError string:@"Cannot define local label '%@' because no global label has been set yet", symbol];
                        continue;
                    }
                    [_evaluator setVariable:[NSString stringWithFormat:@"%@%@", _lastGlobalLabel, symbol] withValue:value];
                }
                else {
                    _lastGlobalLabel = symbol;
                    _evaluator.currentScope = symbol;
                    [_evaluator setVariable:symbol withValue:value];
                }
                continue;
            }
            
            tokens = [line tokenizeByString:@" " maximumTokens:2];
            NSString *directive = tokens[0];
            if (whitelist && ![whitelist containsObject:directive.lowercaseString]) {
                if (_definingMacro) {
                    [_definingMacro.contents appendFormat:@"%@", rawLine];
                }
                else if (_reptDepth) {
                    [_reptString appendFormat:@"%@\n", rawLine];
                }
                continue;
            }
            if (!directive.isValidSFCSegment) {
                [_errors addErrorWithType:SFCError string:@"Invalid instruction/macro name '%@'", directive];
                continue;
            }
            
            NSString *argumentsString = tokens.count == 2? tokens[1] : @"";
            SEL selector = NSSelectorFromString([NSString stringWithFormat:@"handle%@:", directive.lowercaseString.capitalizedString]);
            if (![self respondsToSelector:selector]) {
                SFCMacro *macro = _macros[directive];
                if (!macro) {
                    [_errors addErrorWithType:SFCError string:@"Unrecognized instruction/macro '%@'", directive];
                    continue;
                }
                NSArray<NSString *> *arguments = macro.isVAArgs? [argumentsString tokenizeByString:@"," maximumTokens:macro.arguments.count] :
                                                                 [argumentsString tokenizeByString:@","];
                if (arguments.count == 1 && arguments[0].length == 0) {
                    arguments = @[];
                }
                [self handleMacro:macro arguments:arguments];
                continue;
            }
            
            NSArray<NSString *> *arguments = [argumentsString tokenizeByString:@","];
            if (arguments[0].length == 0) {
                arguments = @[];
            }
            
            if (_currentSegment.fileMapped && !_depsMode) {
                assert(((_org ^ ftell(_file)) & 0xFFFF) == 0);
            }
            
            ((void (*)(id, SEL, id))objc_msgSend)(self, selector, arguments);
            if (_errors.status == SFCFatal) break;
        }
    }
    _errors.activeReader = nil;
        
    if (_definingStruct) {
        [_errors addErrorWithType:SFCError string:@"Unterminated struct directive for struct %@", _definingStruct];
    }
    else if (_definingMacro) {
        [_errors addErrorWithType:SFCError string:@"Unterminated macro directive for macro %@", _definingMacro];
    }
    else if (_ifDepth) {
        [_errors addErrorWithType:SFCError string:@"%u unterminated if/ifdef directive(s)", _ifDepth];
    }
    else if (_reptDepth) {
        [_errors addErrorWithType:SFCError string:@"%u unterminated rept directive(s)", _reptDepth];
    }
    
    
    if (_file) {
        if (_errors.status < SFCError) {
            [self link];
        }
        
        if (_errors.status < SFCError) {
            [self applyPadding];
        }

        if (_updateChecksumWhenDone) {
            [self updateChecksum];
        }
        fclose(_file);
        _file = NULL;
        if (_errors.status >= SFCError) {
            unlink(path.UTF8String);
        }
    }
    _errors = nil;
    _evaluator.encoding = nil;
}

- (void)updateChecksum
{
    fseek(_file, 0xFFDC, SEEK_SET);
    
    uint8_t byte = 0;
    
    // Ignore 4 bytes at the checksum
    for (unsigned i = 4; i--;) {
        fread(&byte, 1, 1, _file);
        _checksum -= byte;
    }
    
    // Pretend the last 2 were 0xff
    _checksum += 0xff * 2;
    
    // Write the actual checksum
    
    uint8_t checksum[4] = {
        ~_checksum,
        ~_checksum >> 8,
        _checksum,
        _checksum >> 8,
    };
    
    fseek(_file, 0xFFDC, SEEK_SET);

    ssize_t written = fwrite(checksum, 1, sizeof(checksum), _file);
    if (written != sizeof(checksum)) {
        [_errors addErrorWithType:SFCFatal string:@"Could not checksum write to output file: %s", strerror(errno)];
        return;
    }
}

- (void)dealloc
{
    if (_file) fclose(_file);
}

@end
