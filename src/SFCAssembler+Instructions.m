#import "SFCAssembler.h"
#import "NSString+SFC.h"

#define ExpectArgumentCount(directive, _count) \
if (arguments.count != _count) {\
[_errors addErrorWithType:SFCError string:@"Instruction %s expects %u argument(s), got %u", directive, _count, (unsigned)arguments.count];\
return;\
}

#define ExpectAddress(directive) \
if (!arguments.count) {\
[_errors addErrorWithType:SFCError string:@"Instruction %s expects an argument", directive];\
return;\
}\
if (arguments.count > 1) arguments = @[[arguments componentsJoinedByString:@","]];

@interface SFCAssembler()
{
    @public
    SFCErrorSet *_errors;
    uint32_t _org;
}

- (NSString *)translatePlusMinusLabel:(NSString *)label isNew:(bool)isNew;
@end


#define AddressingModeLengthMask 3
#define AddressingModeLengthDirectPage 1
#define AddressingModeLengthAbsolute 2
#define AddressingModeLengthLong 3
#define AddressingModeIndexedByX 8
#define AddressingModeIndexedByY 0x10
#define AddressingModeIndirect 0x80
#define AddressingModeIndexedByXIndirect 0x100
#define AddressingModeIndexedByYIndirect 0x200
#define AddressingModeDirectPageIndirectBit 0x400
#define AddressingModeStackRelativeIndirect 0x800

typedef enum {
    AddressingModeAccumulator = 0,
    AddressingModeDirectPage = AddressingModeLengthDirectPage,
    AddressingModeAbsolute = AddressingModeLengthAbsolute,
    AddressingModeAbsoluteLong = AddressingModeLengthLong,
    
    /* No explicit sizes allowed */
    AddressingModeImmediate = 4,
    AddressingModeDirectPageIndexedByX = AddressingModeDirectPage | AddressingModeIndexedByX,
    AddressingModeDirectPageIndexedByY = AddressingModeDirectPage | AddressingModeIndexedByY,
    AddressingModeStackRelative = 0x40,
    AddressingModeStackRelativeIndirectIndexeByY = AddressingModeStackRelativeIndirect | AddressingModeIndexedByYIndirect | AddressingModeIndirect,
    
    /* Implicitly long */
    AddressingModeAbsoluteIndexedByXIndirectLong = AddressingModeIndirect | AddressingModeIndexedByXIndirect | AddressingModeAbsoluteLong,
    
    // 16-bit addresses
    AddressingModeAbsoluteIndexedByX = AddressingModeAbsolute | AddressingModeIndexedByX,
    AddressingModeAbsoluteIndexedByY = AddressingModeAbsolute | AddressingModeIndexedByY,
    AddressingModeAbsoluteIndirect = AddressingModeAbsolute | AddressingModeIndirect,
    AddressingModeDirectPageIndirect = AddressingModeLengthAbsolute | AddressingModeIndirect | AddressingModeDirectPageIndirectBit,
    AddressingModeDirectPageIndexedIndirectByX = AddressingModeDirectPageIndirect | AddressingModeIndexedByXIndirect,
    AddressingModeDirectPageIndirectIndexedByY = AddressingModeDirectPageIndirect | AddressingModeIndexedByY,
    
    /* 24-bit addresses */
    AddressingModeAbsoluteLongIndexedByX = AddressingModeAbsoluteLong | AddressingModeIndexedByX,
    AddressingModeAbsoluteIndirectLong = AddressingModeAbsoluteLong | AddressingModeIndirect,
    AddressingModeDirectPageIndirectLong = AddressingModeLengthLong | AddressingModeIndirect | AddressingModeDirectPageIndirectBit,
    AddressingModeDirectPageIndirectIndexedByYLong = AddressingModeDirectPageIndirectLong | AddressingModeIndexedByY,
} AddressingMode;

@implementation SFCAssembler (Instructions)

- (AddressingMode)addressingModeForArgument:(NSString **)argument useDataBank:(bool)useDataBank isJump:(bool)isJump
{
#define argument (*argument)
    if ([argument.lowercaseString isEqualToString:@"a"]) return AddressingModeAccumulator;
    AddressingMode ret = 0;
    bool explicitAddressSize = false;
    NSArray<NSString *> *tokens = [argument tokenizeByString:@":" maximumTokens:2];
    if (tokens.count == 2) {
        NSString *exlicitSize = tokens[0].lowercaseString;
        explicitAddressSize = true;
        if ([exlicitSize isEqual:@"z"]) {
            ret = AddressingModeLengthDirectPage;
        }
        else if ([exlicitSize isEqual:@"a"]) {
            ret = AddressingModeLengthAbsolute;
        }
        else if ([exlicitSize isEqual:@"f"]) {
            ret = AddressingModeLengthLong;
        }
        else {
            [_errors addErrorWithType:SFCWarning string:@"Ignoring invalid address size hint '%@'", tokens[0]];
            explicitAddressSize = false;
        }
        argument = tokens[1];
    }
    
    tokens = [argument tokenizeByString:@"," maximumTokens:3];
    if (tokens.count > 1) {
        NSString *indexRegister = tokens.lastObject.lowercaseString;
        if ([indexRegister isEqual:@"x"]) {
            ret |= AddressingModeIndexedByX;
            tokens = [tokens subarrayWithRange:NSMakeRange(0, tokens.count - 1)];
        }
        else if ([indexRegister isEqual:@"y"]) {
            ret |= AddressingModeIndexedByY;
            tokens = [tokens subarrayWithRange:NSMakeRange(0, tokens.count - 1)];
        }
        else if (tokens.count == 3) {
            [_errors addErrorWithType:SFCError string:@"Invalid indexing register '%@'", tokens[2]];
            tokens = [tokens subarrayWithRange:NSMakeRange(0, tokens.count - 1)];
        }
        
    }
    
    if (tokens.count == 2) {
        NSString *baseRegister = tokens[0].lowercaseString;
        if ([baseRegister isEqual:@"d"]) {
            ret |= AddressingModeDirectPage;
            explicitAddressSize = true;
        }
        else if ([baseRegister isEqual:@"s"]) {
            ret |= AddressingModeStackRelative;
        }
        else {
            [_errors addErrorWithType:SFCError string:@"Invalid base register '%@'", tokens.lastObject];
            return -1;
        }
        tokens = @[tokens[1]];
    }
    argument = tokens[0];
    
    if ([argument hasPrefix:@"["] && [argument hasSuffix:@"]"]) {
        argument = [argument substringWithRange:NSMakeRange(1, argument.length - 2)];
        ret |= AddressingModeIndirect;
        
        tokens = [argument tokenizeByString:@"," maximumTokens:3];
        if (tokens.count > 1) {
            NSString *indexRegister = tokens.lastObject.lowercaseString;
            if ([indexRegister isEqual:@"x"]) {
                ret |= AddressingModeIndexedByXIndirect;
                tokens = [tokens subarrayWithRange:NSMakeRange(0, tokens.count - 1)];
            }
            else if ([indexRegister isEqual:@"y"]) {
                ret |= AddressingModeIndexedByYIndirect;
                tokens = [tokens subarrayWithRange:NSMakeRange(0, tokens.count - 1)];
            }
            else if (tokens.count == 3) {
                [_errors addErrorWithType:SFCError string:@"Invalid indexing register '%@'", tokens[2]];
                tokens = [tokens subarrayWithRange:NSMakeRange(0, tokens.count - 1)];
            }
        }
        
        if (tokens.count == 2) {
            NSString *baseRegister = tokens[0].lowercaseString;
            if ([baseRegister isEqual:@"d"]) {
                ret |= AddressingModeDirectPageIndirectBit;
            }
            else if ([baseRegister isEqual:@"s"]) {
                ret |= AddressingModeStackRelativeIndirect;
            }
            else {
                [_errors addErrorWithType:SFCError string:@"Invalid base register '%@'", tokens.lastObject];
                return -1;
            }
            tokens = @[tokens[1]];
        }
        argument = tokens[0];
        
        NSArray<NSString *> *tokens = [argument tokenizeByString:@":" maximumTokens:2];
        if (tokens.count == 2) {
            NSString *exlicitSize = tokens[0].lowercaseString;
            if ([exlicitSize isEqual:@"z"]) {
                ret |= AddressingModeDirectPageIndirectBit;
            }
            else {
                [_errors addErrorWithType:SFCWarning string:@"Ignoring invalid address size hint '%@'", tokens[0]];
            }
            argument = tokens[1];
        }
    }
    
    if ([argument hasPrefix:@"#"]) {
        argument = [argument substringFromIndex:1];
        ret |= AddressingModeImmediate;
    }
    
    if (!isJump && !(ret & AddressingModeDirectPageIndirectBit) && (ret & AddressingModeIndirect) && !(ret & AddressingModeStackRelativeIndirect)) {
        [_errors addErrorWithType:SFCWarning string:@"Implicit direct page addressing mode"];
        ret |= AddressingModeDirectPageIndirectBit;
    }
    
    if (explicitAddressSize) return ret;
    // Implicitly long
    if (((ret & ~AddressingModeLengthMask) | AddressingModeLengthLong) == AddressingModeAbsoluteIndexedByXIndirectLong) {
        return AddressingModeAbsoluteIndexedByXIndirectLong;
    }
    
    // No explicit sizes allowed
    if (ret == AddressingModeImmediate) return ret;
    if (ret == AddressingModeDirectPage) return ret;
    if (ret == AddressingModeDirectPageIndexedByX) return ret;
    if (ret == AddressingModeDirectPageIndexedByY) return ret;
    if (ret == AddressingModeStackRelative) return ret;
    if (ret == AddressingModeStackRelativeIndirectIndexeByY) return ret;
    
    // Default is 16-bit
    ret |= AddressingModeLengthAbsolute;
    // Except for these two, where the default is far, unless the argument is resolved to the current bank
    if (ret == AddressingModeAbsolute || ret == AddressingModeAbsoluteIndexedByX) {
        ret &= ~AddressingModeLengthMask;
        SFCValue *value = [self evaluate:argument allowUndefined:true];
        if (value.isInt && (value.intValue >> 16) == (useDataBank? (self.assemblerFlags >> 8) : (_org >> 16))) {
            ret |= AddressingModeLengthAbsolute;
        }
        else {
            ret |= AddressingModeLengthLong;
        }
    }
    return ret;
#undef argument
}

- (void)handleA8:(NSArray<NSString *> *)arguments
{
    ExpectArgumentCount("a8", 0);
    self.assemblerFlags |= 0x20;
}

- (void)handleA16:(NSArray<NSString *> *)arguments
{
    ExpectArgumentCount("a16", 0);
    self.assemblerFlags &= ~0x20;
}

- (void)handleI8:(NSArray<NSString *> *)arguments
{
    ExpectArgumentCount("i8", 0);
    self.assemblerFlags |= 0x10;
}

- (void)handleI16:(NSArray<NSString *> *)arguments
{
    ExpectArgumentCount("i16", 0);
    self.assemblerFlags &= ~0x10;
}

- (void)handleDatabank:(NSArray<NSString *> *)arguments
{
    ExpectArgumentCount("databank", 1);
    
    SFCValue *value = [self evaluate:arguments[0] allowUndefined:false];
    if (!value) return;
    if (!value.isInt) {
        [_errors addErrorWithType:SFCError string:@"Argument is not an integer"];
        return;
    }
    if (value.intValue < 0 || value.intValue > 255) {
        [_errors addErrorWithType:SFCWarning string:@"Value (0x%06llx) is out of range (0x00 - 0xff) and will be truncated", value.intValue];
    }
    self.assemblerFlags &= ~0xff00;
    self.assemblerFlags |= value.intValue << 8;
}

#define SimpleOpcode(selector, instruction, opcode) \
- (void)selector:(NSArray<NSString *> *)arguments\
{\
ExpectArgumentCount(instruction, 0);\
uint8_t _opcode = opcode;\
[self writeBytes:&_opcode length:sizeof(_opcode)];\
}

SimpleOpcode(handleClc, "clc", 0x18)
SimpleOpcode(handleCld, "cld", 0xd8)
SimpleOpcode(handleCli, "cli", 0x58)
SimpleOpcode(handleClv, "clv", 0xb8)
SimpleOpcode(handleDex, "dex", 0xca)
SimpleOpcode(handleDey, "dey", 0x88)
SimpleOpcode(handleInx, "inx", 0xe8)
SimpleOpcode(handleIny, "iny", 0xc8)
SimpleOpcode(handleNop, "nop", 0xea)
SimpleOpcode(handlePha, "pha", 0x48)
SimpleOpcode(handlePhb, "phb", 0x8b)
SimpleOpcode(handlePhd, "phd", 0x0b)
SimpleOpcode(handlePhk, "phk", 0x4b)
SimpleOpcode(handlePhp, "php", 0x08)
SimpleOpcode(handlePhx, "phx", 0xda)
SimpleOpcode(handlePhy, "phy", 0x5a)
SimpleOpcode(handlePla, "pla", 0x68)
SimpleOpcode(handlePlb, "plb", 0xab)
SimpleOpcode(handlePld, "pld", 0x2b)
SimpleOpcode(handlePlp, "plp", 0x28)
SimpleOpcode(handlePlx, "plx", 0xfa)
SimpleOpcode(handlePly, "ply", 0x7a)
SimpleOpcode(handleRti, "rti", 0x40)
SimpleOpcode(handleRtl, "rtl", 0x6b)
SimpleOpcode(handleRts, "rts", 0x60)
SimpleOpcode(handleSec, "sec", 0x38)
SimpleOpcode(handleSed, "sed", 0xf8)
SimpleOpcode(handleSei, "sei", 0x78)
SimpleOpcode(handleStp, "stp", 0xdb)
SimpleOpcode(handleTax, "tax", 0xaa)
SimpleOpcode(handleTay, "tay", 0xa8)
SimpleOpcode(handleTcd, "tcd", 0x5b)
SimpleOpcode(handleTcs, "tcs", 0x1b)
SimpleOpcode(handleTdc, "tdc", 0x7b)
SimpleOpcode(handleTsc, "tsc", 0x3b)
SimpleOpcode(handleTsx, "tsx", 0xba)
SimpleOpcode(handleTxa, "txa", 0x8a)
SimpleOpcode(handleTxs, "txs", 0x9a)
SimpleOpcode(handleTxy, "txy", 0x9b)
SimpleOpcode(handleTya, "tya", 0x98)
SimpleOpcode(handleTyx, "tyx", 0xbb)
SimpleOpcode(handleWai, "wai", 0xcb)
SimpleOpcode(handleXba, "xba", 0xeb)
SimpleOpcode(handleXce, "xce", 0xfb)

- (void)handleBrk:(NSArray<NSString *> *)arguments
{
    if (arguments.count == 0) {
        arguments = @[@"#0"];
    }
    ExpectArgumentCount("brk", 1);
    NSString *arg = arguments[0];
    if ([arg hasPrefix:@"#"]) {
        arg = [arg substringFromIndex:1];
    }
    else {
        [_errors addErrorWithType:SFCWarning string:@"Missing # prefix from immediate value"];
    }
    SFCValue *value = [self evaluate:arg allowUndefined:true];
    if (!value) return;
    uint8_t byte = 0;
    [self writeBytes:&byte length:sizeof(byte)];
    [self addRelocation:value size:1 validation:SFCRelValidationRange expectedHigh:0];
}

- (void)handleCop:(NSArray<NSString *> *)arguments
{
    ExpectArgumentCount("cop", 1);
    NSString *arg = arguments[0];
    if ([arg hasPrefix:@"#"]) {
        arg = [arg substringFromIndex:1];
    }
    else {
        [_errors addErrorWithType:SFCWarning string:@"Missing # prefix from immediate value"];
    }
    SFCValue *value = [self evaluate:arg allowUndefined:true];
    if (!value) return;
    uint8_t byte = 0x02;
    [self writeBytes:&byte length:sizeof(byte)];
    [self addRelocation:value size:1 validation:SFCRelValidationRange expectedHigh:0];
}

- (void)handleWdm:(NSArray<NSString *> *)arguments
{
    if (arguments.count == 0) {
        arguments = @[@"#0"];
    }
    ExpectArgumentCount("wdm", 1);
    NSString *arg = arguments[0];
    if ([arg hasPrefix:@"#"]) {
        arg = [arg substringFromIndex:1];
    }
    else {
        [_errors addErrorWithType:SFCWarning string:@"Missing # prefix from immediate value"];
    }
    SFCValue *value = [self evaluate:arg allowUndefined:true];
    if (!value) return;
    uint8_t byte = 0x42;
    [self writeBytes:&byte length:sizeof(byte)];
    [self addRelocation:value size:1 validation:SFCRelValidationRange expectedHigh:0];
}

- (void)handleRep:(NSArray<NSString *> *)arguments
{
    ExpectArgumentCount("rep", 1);
    NSString *arg = arguments[0];
    if ([arg hasPrefix:@"#"]) {
        arg = [arg substringFromIndex:1];
    }
    else {
        [_errors addErrorWithType:SFCWarning string:@"Missing # prefix from immediate value"];
    }
    SFCValue *value = [self evaluate:arg allowUndefined:false];
    if (!value) return;
    if (!value.isInt) {
        [_errors addErrorWithType:SFCError string:@"Argument is not an integer"];
        return;
    }
    if (value.intValue < 0 || value.intValue > 255) {
        [_errors addErrorWithType:SFCWarning string:@"Value (0x%06llx) is out of range (0 - 255) and will be truncated", value.intValue];
    }
    uint8_t byte = 0xc2;
    [self writeBytes:&byte length:sizeof(byte)];
    byte = value.intValue;
    [self writeBytes:&byte length:sizeof(byte)];
    self.assemblerFlags &= ~byte;
}

- (void)handleSep:(NSArray<NSString *> *)arguments
{
    ExpectArgumentCount("sep", 1);
    NSString *arg = arguments[0];
    if ([arg hasPrefix:@"#"]) {
        arg = [arg substringFromIndex:1];
    }
    else {
        [_errors addErrorWithType:SFCWarning string:@"Missing # prefix from immediate value"];
    }
    SFCValue *value = [self evaluate:arg allowUndefined:false];
    if (!value) return;
    if (!value.isInt) {
        [_errors addErrorWithType:SFCError string:@"Argument is not an integer"];
        return;
    }
    if (value.intValue < 0 || value.intValue > 255) {
        [_errors addErrorWithType:SFCWarning string:@"Value (0x%06llx) is out of range (0 - 255) and will be truncated", value.intValue];
    }
    uint8_t byte = 0xe2;
    [self writeBytes:&byte length:sizeof(byte)];
    byte = value.intValue;
    [self writeBytes:&byte length:sizeof(byte)];
    self.assemblerFlags |= byte;
}

- (void)handleBlockOpcode:(NSArray<NSString *> *)arguments opcode:(uint8_t)opcode
{
    NSString *arg1 = arguments[0];
    NSString *arg2 = arguments[1];
    if ([arg1 hasPrefix:@"#"]) {
        arg1 = [arg1 substringFromIndex:1];
    }
    else {
        [_errors addErrorWithType:SFCWarning string:@"Missing # prefix from immediate value"];
    }
    
    if ([arg2 hasPrefix:@"#"]) {
        arg2 = [arg2 substringFromIndex:1];
    }
    else {
        [_errors addErrorWithType:SFCWarning string:@"Missing # prefix from immediate value"];
    }
    
    SFCValue *value1 = [self evaluate:arg1 allowUndefined:true];
    if (!value1) return;
    
    SFCValue *value2 = [self evaluate:arg2 allowUndefined:true];
    if (!value2) return;
    
    [self writeBytes:&opcode length:1];
    [self addRelocation:value1 size:1 validation:SFCRelValidationUnsigned expectedHigh:0];
    [self addRelocation:value2 size:1 validation:SFCRelValidationUnsigned expectedHigh:0];

}

- (void)handleMvp:(NSArray<NSString *> *)arguments
{
    ExpectArgumentCount("mvp", 2);
    [self handleBlockOpcode:arguments opcode:0x44];
}

- (void)handleMvn:(NSArray<NSString *> *)arguments
{
    ExpectArgumentCount("mvn", 2);
    [self handleBlockOpcode:arguments opcode:0x54];
}

- (void)handleJmp:(NSArray<NSString *> *)arguments
{
    ExpectAddress("jmp");
    NSString *target = arguments[0];
    AddressingMode mode = [self addressingModeForArgument:&target useDataBank:false isJump:true];
    uint8_t opcode;
    uint8_t addressSize = 2;
    uint8_t targetBank = _org >> 16;
    switch (mode) {
        case AddressingModeAbsolute:
            opcode = 0x4c;
            break;
        case AddressingModeAbsoluteIndirect:
            targetBank = 0;
            opcode = 0x6c;
            break;
        case AddressingModeAbsoluteIndexedByXIndirectLong:
            targetBank = 0;
            opcode = 0x7c;
            break;
        case AddressingModeAbsoluteIndirectLong:
            targetBank = 0;
            opcode = 0xdc;
            break;
        case AddressingModeAbsoluteLong:
            opcode = 0x5c;
            addressSize = 3;
            break;
        default:
            [_errors addErrorWithType:SFCError string:@"Invalid addressing mode"];
            return;
    }
    [self writeBytes:&opcode length:sizeof(opcode)];
    SFCValue *value = [self evaluate:target allowUndefined:true];
    if (!value) return;
    [self addRelocation:value size:addressSize validation:SFCRelValidationHigh expectedHigh:targetBank << 16];
}

// Built-in macro
- (void)handleJml:(NSArray<NSString *> *)arguments
{
    ExpectAddress("jml");
    [self handleJmp:@[[@"f:" stringByAppendingString:arguments[0]]]];
}

- (void)handleJsr:(NSArray<NSString *> *)arguments
{
    ExpectAddress("jsr");
    NSString *target = arguments[0];
    AddressingMode mode = [self addressingModeForArgument:&target useDataBank:false isJump:true];
    uint8_t opcode;
    uint8_t addressSize = 2;
    uint8_t targetBank = _org >> 16;
    switch (mode) {
        case AddressingModeAbsolute:
            opcode = 0x20;
            break;
        case AddressingModeAbsoluteIndexedByXIndirectLong:
            targetBank = 0;
            opcode = 0xfc;
            break;
        case AddressingModeAbsoluteLong:
            opcode = 0x22;
            addressSize = 3;
            break;
        default:
            [_errors addErrorWithType:SFCError string:@"Invalid addressing mode"];
            return;
    }
    [self writeBytes:&opcode length:sizeof(opcode)];
    SFCValue *value = [self evaluate:target allowUndefined:true];
    if (!value) return;
    [self addRelocation:value size:addressSize validation:SFCRelValidationHigh expectedHigh:targetBank << 16];
}

// Built-in macro
- (void)handleJsl:(NSArray<NSString *> *)arguments
{
    ExpectAddress("jsl");
    [self handleJsr:@[[@"f:" stringByAppendingString:arguments[0]]]];
}

- (void)handleLdaSta:(NSString *)target isSta:(bool)sta base:(int8_t)offset
{
    AddressingMode mode = [self addressingModeForArgument:&target useDataBank:true isJump:false];
    uint8_t opcode;
    uint8_t addressSize = 2;
    uint8_t targetBank = (self.assemblerFlags) >> 8;
    switch (mode) {
        case AddressingModeAbsolute:
            opcode = 0x0d;
            break;
        case AddressingModeAbsoluteLong:
            opcode = 0x0f;
            addressSize = 3;
            break;
        case AddressingModeDirectPage:
            opcode = 0x05;
            addressSize = 1;
            break;
        case AddressingModeDirectPageIndirect:
            opcode = 0x12;
            addressSize = 1;
            break;
        case AddressingModeDirectPageIndirectLong:
            opcode = 0x07;
            addressSize = 1;
            break;
        case AddressingModeAbsoluteIndexedByX:
            opcode = 0x1d;
            break;
        case AddressingModeAbsoluteLongIndexedByX:
            opcode = 0x1f;
            addressSize = 3;
            break;
        case AddressingModeAbsoluteIndexedByY:
            opcode = 0x19;
            break;
        case AddressingModeDirectPageIndexedByX:
            opcode = 0x15;
            addressSize = 1;
            break;
        case AddressingModeDirectPageIndexedIndirectByX:
            opcode = 0x01;
            addressSize = 1;
            break;
        case AddressingModeDirectPageIndirectIndexedByY:
            opcode = 0x11;
            addressSize = 1;
            break;
        case AddressingModeDirectPageIndirectIndexedByYLong:
            opcode = 0x17;
            addressSize = 1;
            break;
        case AddressingModeStackRelative:
            opcode = 0x03;
            addressSize = 1;
            break;
        case AddressingModeStackRelativeIndirectIndexeByY:
            opcode = 0x13;
            addressSize = 1;
            break;
        case AddressingModeImmediate:
            if (!sta) {
                opcode = 0x09;
                if (self.assemblerFlags & 0x20) {
                    addressSize = 1;
                }
                break;
            }
            // fallthrough
        default:
            [_errors addErrorWithType:SFCError string:@"Invalid addressing mode"];
            return;
    }
    opcode += offset;
    [self writeBytes:&opcode length:sizeof(opcode)];
    SFCValue *value = [self evaluate:target allowUndefined:true];
    if (!value) return;
    SFCRelValidation validation = SFCRelValidationHigh;
    if (mode == AddressingModeImmediate) {
        validation = SFCRelValidationRange;
    }
    else if (addressSize) {
        validation = SFCRelValidationUnsigned;
    }
    [self addRelocation:value size:addressSize validation:validation expectedHigh:targetBank << 16];
}

- (void)handleOra:(NSArray<NSString *> *)arguments
{
    ExpectAddress("ora");
    NSString *target = arguments[0];
    [self handleLdaSta:target isSta:false base:0x00];
}

- (void)handleAnd:(NSArray<NSString *> *)arguments
{
    ExpectAddress("and");
    NSString *target = arguments[0];
    [self handleLdaSta:target isSta:false base:0x20];
}

- (void)handleEor:(NSArray<NSString *> *)arguments
{
    ExpectAddress("eor");
    NSString *target = arguments[0];
    [self handleLdaSta:target isSta:false base:0x40];
}

- (void)handleAdc:(NSArray<NSString *> *)arguments
{
    ExpectAddress("adc");
    NSString *target = arguments[0];
    [self handleLdaSta:target isSta:false base:0x60];
}

- (void)handleSta:(NSArray<NSString *> *)arguments
{
    ExpectAddress("sta");
    NSString *target = arguments[0];
    [self handleLdaSta:target isSta:true base:0x80];
}

- (void)handleLda:(NSArray<NSString *> *)arguments
{
    ExpectAddress("lda");
    NSString *target = arguments[0];
    [self handleLdaSta:target isSta:false base:0xa0];
}

- (void)handleCmp:(NSArray<NSString *> *)arguments
{
    ExpectAddress("cmp");
    NSString *target = arguments[0];
    [self handleLdaSta:target isSta:false base:0xc0];
}

- (void)handleSbc:(NSArray<NSString *> *)arguments
{
    ExpectAddress("sbc");
    NSString *target = arguments[0];
    [self handleLdaSta:target isSta:false base:0xe0];
}

- (void)handleBitOp:(NSString *)target base:(int8_t)offset
{
    AddressingMode mode = [self addressingModeForArgument:&target useDataBank:true isJump:false];
    uint8_t opcode;
    uint8_t addressSize = 2;
    uint8_t targetBank = (self.assemblerFlags) >> 8;
    switch (mode) {
        case AddressingModeAccumulator:
            addressSize = 0;
            opcode = 0x0a;
            break;
        case AddressingModeAbsolute:
            opcode = 0x0e;
            break;
        case AddressingModeDirectPage:
            opcode = 0x06;
            addressSize = 1;
            break;
        case AddressingModeAbsoluteIndexedByX:
            opcode = 0x1e;
            break;
        case AddressingModeDirectPageIndexedByX:
            opcode = 0x16;
            addressSize = 1;
            break;
        default:
            [_errors addErrorWithType:SFCError string:@"Invalid addressing mode"];
            return;
    }
    opcode += offset;
    // INC A and DEC A break the pattern
    if (opcode == 0xea) opcode = 0x1a;
    if (opcode == 0xca) opcode = 0x3a;
    [self writeBytes:&opcode length:sizeof(opcode)];
    if (addressSize == 0) return;
    
    SFCValue *value = [self evaluate:target allowUndefined:true];
    if (!value) return;
    [self addRelocation:value size:addressSize validation:addressSize == 1? SFCRelValidationUnsigned : SFCRelValidationHigh expectedHigh:targetBank << 16];
}

- (void)handleAsl:(NSArray<NSString *> *)arguments
{
    ExpectAddress("asl");
    NSString *target = arguments[0];
    [self handleBitOp:target base:0x00];
}

- (void)handleRol:(NSArray<NSString *> *)arguments
{
    ExpectAddress("rol");
    NSString *target = arguments[0];
    [self handleBitOp:target base:0x20];
}

- (void)handleLsr:(NSArray<NSString *> *)arguments
{
    ExpectAddress("lsr");
    NSString *target = arguments[0];
    [self handleBitOp:target base:0x40];
}

- (void)handleRor:(NSArray<NSString *> *)arguments
{
    ExpectAddress("ror");
    NSString *target = arguments[0];
    [self handleBitOp:target base:0x60];
}

- (void)handleDec:(NSArray<NSString *> *)arguments
{
    ExpectAddress("dec");
    NSString *target = arguments[0];
    [self handleBitOp:target base:0xc0];
}

- (void)handleInc:(NSArray<NSString *> *)arguments
{
    ExpectAddress("inc");
    NSString *target = arguments[0];
    [self handleBitOp:target base:0xe0];
}

- (void)handleXY:(NSString *)target isStore:(bool)store isY:(bool)isY
{
    AddressingMode mode = [self addressingModeForArgument:&target useDataBank:true isJump:false];
    uint8_t opcode;
    uint8_t addressSize = 2;
    uint8_t targetBank = (self.assemblerFlags) >> 8;
    switch (mode) {
        case AddressingModeAbsolute:
            opcode = 0xae;
            break;
        case AddressingModeDirectPage:
            opcode = 0xa6;
            addressSize = 1;
            break;
        case AddressingModeAbsoluteIndexedByX:
            if (!isY) goto invalid;
            if (store) goto invalid;
            opcode = 0xbe; // Will be changed to BC
            break;
        case AddressingModeAbsoluteIndexedByY:
            if (isY) goto invalid;
            if (store) goto invalid;
            opcode = 0xbe;
            break;
        case AddressingModeDirectPageIndexedByY:
            if (isY) goto invalid;
            opcode = 0xb6;
            addressSize = 1;
            break;
        case AddressingModeDirectPageIndexedByX:
            if (!isY) goto invalid;
            opcode = 0xb6; // Will be modified to 0x94 or B4
            addressSize = 1;
            break;
        case AddressingModeImmediate:
            if (!store) {
                opcode = 0xa2;
                if (self.assemblerFlags & 0x10) {
                    addressSize = 1;
                }
                break;
            }
            // fallthrough
        default:
        invalid:
            [_errors addErrorWithType:SFCError string:@"Invalid addressing mode"];
            return;
    }
    if (store) opcode -= 0x20;
    if (isY) opcode -= 2;
    [self writeBytes:&opcode length:sizeof(opcode)];
    SFCValue *value = [self evaluate:target allowUndefined:true];
    if (!value) return;
    SFCRelValidation validation = SFCRelValidationHigh;
    if (mode == AddressingModeImmediate) {
        validation = SFCRelValidationRange;
    }
    else if (addressSize) {
        validation = SFCRelValidationUnsigned;
    }
    [self addRelocation:value size:addressSize validation:validation expectedHigh:targetBank << 16];
}

- (void)handleLdx:(NSArray<NSString *> *)arguments
{
    ExpectAddress("ldx");
    NSString *target = arguments[0];
    [self handleXY:target isStore:false isY:false];
}

- (void)handleLdy:(NSArray<NSString *> *)arguments
{
    ExpectAddress("ldy");
    NSString *target = arguments[0];
    [self handleXY:target isStore:false isY:true];
}

- (void)handleStx:(NSArray<NSString *> *)arguments
{
    ExpectAddress("stx");
    NSString *target = arguments[0];
    [self handleXY:target isStore:true isY:false];
}

- (void)handleSty:(NSArray<NSString *> *)arguments
{
    ExpectAddress("sty");
    NSString *target = arguments[0];
    [self handleXY:target isStore:true isY:true];
}

- (void)handlePer:(NSArray<NSString *> *)arguments
{
    ExpectArgumentCount("per", 1);
    NSString *target = arguments[0];
    if (target.isPlusMinusLabel) {
        target = [self translatePlusMinusLabel:target isNew:false];
    }
    uint8_t opcode = 0x62;
    [self writeBytes:&opcode length:sizeof(opcode)];
    SFCValue *value = [self evaluate:[NSString stringWithFormat:@"(%@) - 0x%x", target, _org + 2] allowUndefined:true];
    if (!value) return;
    // Needs a new validation type since wrap arounds are fine as long as it's in the same bank
    [self addRelocation:value size:2 validation:SFCRelValidationRange expectedHigh:0];
}

- (void)handlePea:(NSArray<NSString *> *)arguments
{
    ExpectArgumentCount("pea", 1);
    NSString *target = arguments[0];
    if ([target hasPrefix:@"#"]) {
        target = [target substringFromIndex:1];
    }
    uint8_t opcode = 0xf4;
    [self writeBytes:&opcode length:sizeof(opcode)];
    SFCValue *value = [self evaluate:target allowUndefined:true];
    if (!value) return;
    // Needs a new validation type since wrap arounds are fine as long as it's in the same bank
    [self addRelocation:value size:2 validation:SFCRelValidationUnsigned expectedHigh:0];
}

- (void)handleBrl:(NSArray<NSString *> *)arguments
{
    ExpectArgumentCount("brl", 1);
    NSString *target = arguments[0];
    if (target.isPlusMinusLabel) {
        target = [self translatePlusMinusLabel:target isNew:false];
    }
    uint8_t opcode = 0x82;
    [self writeBytes:&opcode length:sizeof(opcode)];
    SFCValue *value = [self evaluate:[NSString stringWithFormat:@"(%@) - 0x%x", target, _org + 2] allowUndefined:true];
    if (!value) return;
    // Needs a new validation type since wrap arounds are fine as long as it's in the same bank
    [self addRelocation:value size:2 validation:SFCRelValidationRange expectedHigh:0];
}

- (void)handleBranch:(NSString *)target opcode:(uint8_t)opcode
{
    if (target.isPlusMinusLabel) {
        target = [self translatePlusMinusLabel:target isNew:false];
    }
    [self writeBytes:&opcode length:sizeof(opcode)];
    // TODO: This will handle errors poorly
    SFCValue *value = [self evaluate:[NSString stringWithFormat:@"(%@) - 0x%x", target, _org + 1] allowUndefined:true];
    if (!value) return;
    // TODO: Relocation failure here should error instead of issue a warning
    [self addRelocation:value size:1 validation:SFCRelValidationSigned expectedHigh:0];
}

- (void)handleBpl:(NSArray<NSString *> *)arguments
{
    ExpectArgumentCount("bpl", 1);
    NSString *arg = arguments[0];
    [self handleBranch:arg opcode:0x10];
}

- (void)handleBmi:(NSArray<NSString *> *)arguments
{
    ExpectArgumentCount("bmi", 1);
    NSString *arg = arguments[0];
    [self handleBranch:arg opcode:0x30];
}

- (void)handleBvc:(NSArray<NSString *> *)arguments
{
    ExpectArgumentCount("bvc", 1);
    NSString *arg = arguments[0];
    [self handleBranch:arg opcode:0x50];
}

- (void)handleBvs:(NSArray<NSString *> *)arguments
{
    ExpectArgumentCount("bvs", 1);
    NSString *arg = arguments[0];
    [self handleBranch:arg opcode:0x70];
}

- (void)handleBra:(NSArray<NSString *> *)arguments
{
    ExpectArgumentCount("bra", 1);
    NSString *arg = arguments[0];
    [self handleBranch:arg opcode:0x80];
}

- (void)handleBcc:(NSArray<NSString *> *)arguments
{
    ExpectArgumentCount("bcc", 1);
    NSString *arg = arguments[0];
    [self handleBranch:arg opcode:0x90];
}

- (void)handleBcs:(NSArray<NSString *> *)arguments
{
    ExpectArgumentCount("bcs", 1);
    NSString *arg = arguments[0];
    [self handleBranch:arg opcode:0xb0];
}

- (void)handleBne:(NSArray<NSString *> *)arguments
{
    ExpectArgumentCount("bne", 1);
    NSString *arg = arguments[0];
    [self handleBranch:arg opcode:0xd0];
}

- (void)handleBeq:(NSArray<NSString *> *)arguments
{
    ExpectArgumentCount("beq", 1);
    NSString *arg = arguments[0];
    [self handleBranch:arg opcode:0xf0];
}

- (void)handleBit:(NSArray *)arguments
{
    ExpectAddress("adc");
    NSString *target = arguments[0];
    AddressingMode mode = [self addressingModeForArgument:&target useDataBank:true isJump:false];
    uint8_t opcode;
    uint8_t addressSize = 2;
    uint8_t targetBank = (self.assemblerFlags) >> 8;
    switch (mode) {
        case AddressingModeImmediate:
            opcode = 0x89;
            if (self.assemblerFlags & 0x20) {
                addressSize = 1;
            }
            break;
        case AddressingModeAbsolute:
            opcode = 0x2c;
            break;
        case AddressingModeDirectPage:
            opcode = 0x24;
            addressSize = 1;
            break;
        case AddressingModeAbsoluteIndexedByX:
            opcode = 0x3c;
            break;
        case AddressingModeDirectPageIndexedByX:
            opcode = 0x34;
            addressSize = 1;
            break;
        default:
            [_errors addErrorWithType:SFCError string:@"Invalid addressing mode"];
            return;
    }
    [self writeBytes:&opcode length:sizeof(opcode)];
    SFCValue *value = [self evaluate:target allowUndefined:true];
    if (!value) return;
    SFCRelValidation validation = SFCRelValidationHigh;
    if (mode == AddressingModeImmediate) {
        validation = SFCRelValidationRange;
    }
    else if (addressSize) {
        validation = SFCRelValidationUnsigned;
    }
    [self addRelocation:value size:addressSize validation:validation expectedHigh:targetBank << 16];
}

- (void)handleStz:(NSArray<NSString *> *)arguments
{
    ExpectAddress("stz");
    NSString *target = arguments[0];
    AddressingMode mode = [self addressingModeForArgument:&target useDataBank:true isJump:false];
    uint8_t opcode;
    uint8_t addressSize = 2;
    uint8_t targetBank = (self.assemblerFlags) >> 8;
    switch (mode) {
        case AddressingModeAbsolute:
            opcode = 0x9c;
            break;
        case AddressingModeDirectPage:
            addressSize = 1;
            opcode = 0x64;
            break;
        case AddressingModeAbsoluteIndexedByX:
            opcode = 0x9e;
            break;
        case AddressingModeDirectPageIndexedByX:
            addressSize = 1;
            opcode = 0x74;
            break;
        default:
            [_errors addErrorWithType:SFCError string:@"Invalid addressing mode"];
            return;
    }
    [self writeBytes:&opcode length:sizeof(opcode)];
    SFCValue *value = [self evaluate:target allowUndefined:true];
    if (!value) return;
    [self addRelocation:value size:addressSize validation:addressSize == 1? SFCRelValidationUnsigned : SFCRelValidationHigh expectedHigh:targetBank << 16];
}

- (void)handleCpXY:(NSString *)target isY:(bool)isY
{
    AddressingMode mode = [self addressingModeForArgument:&target useDataBank:true isJump:false];
    uint8_t opcode;
    uint8_t addressSize = 2;
    uint8_t targetBank = (self.assemblerFlags) >> 8;
    switch (mode) {
        case AddressingModeImmediate:
            opcode = 0xe0;
            if (self.assemblerFlags & 0x10) {
                addressSize = 1;
            }
            break;
        case AddressingModeAbsolute:
            opcode = 0xec;
            break;
        case AddressingModeDirectPage:
            addressSize = 1;
            opcode = 0xe4;
            break;
        default:
            [_errors addErrorWithType:SFCError string:@"Invalid addressing mode"];
            return;
    }
    if (isY) opcode -= 0x20;
    [self writeBytes:&opcode length:sizeof(opcode)];
    SFCValue *value = [self evaluate:target allowUndefined:true];
    if (!value) return;
    SFCRelValidation validation = SFCRelValidationHigh;
    if (mode == AddressingModeImmediate) {
        validation = SFCRelValidationRange;
    }
    else if (addressSize) {
        validation = SFCRelValidationUnsigned;
    }
    [self addRelocation:value size:addressSize validation:validation expectedHigh:targetBank << 16];
}

- (void)handleCpx:(NSArray<NSString *> *)arguments
{
    ExpectAddress("cpx");
    [self handleCpXY:arguments[0] isY:false];
}

- (void)handleCpy:(NSArray<NSString *> *)arguments
{
    ExpectAddress("cpy");
    [self handleCpXY:arguments[0] isY:true];
}

- (void)handleTrsb:(NSString *)target base:(uint8_t)base
{
    AddressingMode mode = [self addressingModeForArgument:&target useDataBank:true isJump:false];
    uint8_t opcode;
    uint8_t addressSize = 2;
    uint8_t targetBank = (self.assemblerFlags) >> 8;
    switch (mode) {
        case AddressingModeAbsolute:
            opcode = 0x0c;
            break;
        case AddressingModeDirectPage:
            addressSize = 1;
            opcode = 0x04;
            break;
        default:
            [_errors addErrorWithType:SFCError string:@"Invalid addressing mode"];
            return;
    }
    opcode += base;
    [self writeBytes:&opcode length:sizeof(opcode)];
    SFCValue *value = [self evaluate:target allowUndefined:true];
    if (!value) return;
    [self addRelocation:value size:addressSize validation:addressSize == 1? SFCRelValidationUnsigned : SFCRelValidationHigh expectedHigh:targetBank << 16];
}

- (void)handleTsb:(NSArray<NSString *> *)arguments
{
    ExpectAddress("tsb");
    [self handleTrsb:arguments[0] base:0];
}

- (void)handleTrb:(NSArray<NSString *> *)arguments
{
    ExpectAddress("trb");
    [self handleTrsb:arguments[0] base:0x10];
}

- (void)handlePei:(NSArray<NSString *> *)arguments
{
    ExpectAddress("Pei");
    NSString *target = arguments[0];
    AddressingMode mode = [self addressingModeForArgument:&target useDataBank:true isJump:false];
    if (mode != AddressingModeDirectPageIndirect) {
        [_errors addErrorWithType:SFCError string:@"Invalid addressing mode"];
        return;
    }
    uint8_t opcode = 0xd4;
    uint8_t addressSize = 1;
    [self writeBytes:&opcode length:sizeof(opcode)];
    SFCValue *value = [self evaluate:target allowUndefined:true];
    if (!value) return;
    [self addRelocation:value size:addressSize validation:SFCRelValidationUnsigned expectedHigh:0];
}

@end
