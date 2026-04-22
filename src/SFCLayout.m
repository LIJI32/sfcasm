#import "SFCLayout.h"
#import "NSString+SFC.h"

@implementation SFCSegment
{
    @public
    NSString *_name;
    uint32_t _address;
    uint32_t _size;
    uint32_t _sizeAlignment;
    uint8_t _fillByte;
    bool _flexibleSize;
    uint32_t _lastLocation;
    uint32_t _fileOffset;
    bool _fileMapped;
    uint32_t _maxSize;
}

- (NSString *)description
{
    if (_fileMapped) {
        return [NSString stringWithFormat:@"<%@ (%p) %@: address: 0x%06x-0x%06x%s (org: 0x%06x), file: 0x%06x-0x%06x%s, fill: 0x%02x>",
                self.className,
                self,
                _name,
                _address,
                _address + _size,
                _flexibleSize? "..." : "",
                _lastLocation,
                _fileOffset,
                _fileOffset + _size,
                _flexibleSize? "..." : "",
                _fillByte
        ];
    }
    return [NSString stringWithFormat:@"<%@ (%p) %@: address: 0x%06x-0x%06x%s (org: 0x%06x)>",
            self.className,
            self,
            _name,
            _address,
            _address + _size,
            _flexibleSize? "..." : "",
            _lastLocation
    ];
}

- (void)setSize:(uint32_t)size
{
    assert(size < _maxSize);
    _size = size;
}

- (uint32_t)size
{
    return _size;
}

@end

@implementation SFCLayout
{
    NSMutableArray<SFCSegment *> *_segments;
}

- (instancetype)initWithLineReader:(id<SFCLineReader>)reader evaluator:(SFCEvaluator *)evaluator errorSet:(SFCErrorSet *)errors
{
    self = [super init];
    __block SFCSegment *currentSegment = nil;
    _segments = [NSMutableArray array];
    NSMutableDictionary<NSString *, SFCValue *> *properties = [NSMutableDictionary dictionary];
    
    void (^segmentDone)(void) = ^(void) {
        if (!properties[@"address"]) {
            if ((uint64_t)properties[@"address"].intValue > 0xffffff) {
                [errors addErrorWithType:SFCError string:@"Segment %@'s mapped address is too big", currentSegment.name];
            }
            [errors addErrorWithType:SFCFatal string:@"Segment %@ has no defined address", currentSegment.name];
        }
        else {
            currentSegment->_address = properties[@"address"].intValue;
            [properties removeObjectForKey:@"address"];
        }
        
        if (properties[@"size"]) {
            currentSegment->_size = properties[@"size"].intValue;
            currentSegment->_maxSize = currentSegment->_size;
            [properties removeObjectForKey:@"size"];
        }
        else {
            currentSegment->_flexibleSize = true;
            currentSegment->_maxSize = 0x1000000 - currentSegment->_address;
        }
        
        if (properties[@"size_alignment"]) {
            if (!currentSegment->_flexibleSize) {
                [errors addErrorWithType:SFCFatal string:@"Segment %@ has both the size and size_alignment properties", currentSegment.name];
            }
            currentSegment->_sizeAlignment = properties[@"size_alignment"].intValue;
            if (currentSegment->_sizeAlignment & (currentSegment->_sizeAlignment - 1)) {
                [errors addErrorWithType:SFCFatal string:@"The size alignment of segment %@ is not a power of 2", currentSegment.name];
            }
            
            if (currentSegment->_address & (currentSegment->_sizeAlignment - 1)) {
                [errors addErrorWithType:SFCFatal string:@"The address of segment %@ is not aligned to its size_alignment", currentSegment.name];
            }
            
            if (currentSegment->_fileMapped && currentSegment->_fileOffset & (currentSegment->_sizeAlignment - 1)) {
                [errors addErrorWithType:SFCFatal string:@"The offset of segment %@ is not aligned to its size_alignment", currentSegment.name];
            }
            [properties removeObjectForKey:@"size_alignment"];
        }
        
        if (properties[@"offset"]) {
            if ((uint64_t)properties[@"offset"].intValue > 0xFFFFFF) {
                [errors addErrorWithType:SFCError string:@"Segment %@'s file offset is over 16MB", currentSegment.name];
            }
            currentSegment->_fileOffset = properties[@"offset"].intValue;
            currentSegment->_fileMapped = true;
            [properties removeObjectForKey:@"offset"];
        }
        
        if ((uint64_t)currentSegment->_address + MAX(currentSegment->_size, currentSegment.sizeAlignment) > 0xFFFFFF) {
            [errors addErrorWithType:SFCFatal string:@"Segment %@'s end address is too big", currentSegment.name];
        }
        
        for (SFCSegment *segment in self->_segments) {
            if (NSIntersectionRange(NSMakeRange(segment.address, segment.size), NSMakeRange(currentSegment.address, currentSegment.size)).length) {
                [errors addErrorWithType:SFCFatal string:@"Segment %@ is overlapping with segment %@'s addresses", currentSegment.name, segment.name];
            }
            
            if (segment.fileMapped && currentSegment.fileMapped &&
                NSIntersectionRange(NSMakeRange(segment.fileOffset, segment.size), NSMakeRange(currentSegment.fileOffset, currentSegment.size)).length) {
                [errors addErrorWithType:SFCFatal string:@"Segment %@ is overlapping with segment %@'s file offsets", currentSegment.name, segment.name];
            }
        }
        
        if (properties[@"fill"]) {
            if ((uint64_t)properties[@"fill"].intValue > 0xff) {
                [errors addErrorWithType:SFCWarning string:@"Segment %@'s fill byte is greater than 0xFF", currentSegment.name];
            }
            if (!currentSegment.fileMapped) {
                [errors addErrorWithType:SFCWarning string:@"Ignoring segment %@'s fill byte because it's not a ROM segment", currentSegment.name];
            }
            currentSegment->_fillByte = properties[@"fill"].intValue;
            [properties removeObjectForKey:@"fill"];
        }
        else {
            currentSegment->_fillByte = 0xff;
        }
        
        [self->_segments addObject:currentSegment];
        if (properties.count) {
            [errors addErrorWithType:SFCWarning string:@"Ignoring unrecognized properties in segment %@: %@", currentSegment.name, [properties.allKeys componentsJoinedByString:@", "]];
        }
        [properties removeAllObjects];
    };
    
    errors.activeReader = reader;
    while (!reader.eof) {
        NSString *line = [reader readLineWithErrorSet:errors];
        if (errors.status == SFCFatal) return nil;
        if (!line) continue;
        line = [line tokenizeByString:@";" maximumTokens:2][0];
        line = [line componentsSeparatedByString:@";"][0];
        if (line.length == 0) continue; // Empty line
        
        if ([line hasSuffix:@":"]) {
            if (currentSegment) {
                errors.activeReader = nil;
                segmentDone();
                errors.activeReader = reader;
                currentSegment = nil;
            }
            NSString *symbol = [line substringWithRange:NSMakeRange(0, line.length - 1)];
            symbol = [symbol stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (!symbol.isValidSFCSegment) {
                [errors addErrorWithType:SFCError string:@"Invalid segment name '%@'", symbol];
                currentSegment = nil;
                continue;
            }
            for (SFCSegment *segment in _segments) {
                if ([segment.name isEqual:symbol]) {
                    [errors addErrorWithType:SFCError string:@"Duplicate segment name '%@'", symbol];
                    currentSegment = nil;
                    continue;
                }
            }
            currentSegment = [[SFCSegment alloc] init];
            currentSegment->_name = symbol;
        }
        else {
            if (!currentSegment) {
                [errors addErrorWithType:SFCError string:@"Expected segment name"];
                continue;
            }
            NSArray<NSString *> *tokens = [line tokenizeByString:@"=" maximumTokens:2];
            if (tokens.count == 1) {
                [errors addErrorWithType:SFCError string:@"Expected segment property assignment"];
                continue;
            }
            if (!tokens[0].isValidSFCSegment) {
                [errors addErrorWithType:SFCError string:@"Illegal segment property '%@'", tokens[0]];
                continue;
            }
            if (properties[tokens[0]]) {
                [errors addErrorWithType:SFCError string:@"Duplicated segment property '%@'", tokens[0]];
                continue;
            }
            
            NSRange errorRange;
            NSString *error;
            SFCValue *value = [evaluator evaluate:tokens[1] errorString:&error errorRange:&errorRange];
            if (!value) {
                [errors addErrorWithType:SFCError string:@"%@ ('%@')", error, [tokens[1] substringWithRange:errorRange]];
                continue;
            }
            
            if (value.isMissingSymbolsSet) {
                [errors addErrorWithType:SFCError string:@"Unresolved symbol(s): %@", [value.missingSymbolsSet.allObjects componentsJoinedByString:@", "]];
                continue;
            }
            
            if (!value.isInt) {
                [errors addErrorWithType:SFCError string:@"Expression is not an integer"];
                continue;
            }
            
            properties[tokens[0]] = value;
            [evaluator setVariable:[NSString stringWithFormat:@"%@.%@", currentSegment.name, tokens[0]] withValue:value];
        }
    }
    
    errors.activeReader = nil;
    if (currentSegment) {
        segmentDone();
    }
    
    /* Calculate maxSize for flex segments */
    for (SFCSegment *flexSegment in _segments) {
        if (!flexSegment->_flexibleSize) continue;
        for (SFCSegment *segment in _segments) {
            if (segment->_address > flexSegment->_address) {
                flexSegment->_maxSize = MIN(flexSegment->_maxSize, segment->_address - flexSegment->_address);
            }
            
            if (segment->_fileMapped && flexSegment->_fileMapped && segment->_fileOffset > flexSegment->_fileOffset) {
                flexSegment->_maxSize = MIN(flexSegment->_maxSize, segment->_fileOffset - flexSegment->_fileOffset);
            }
        }
    }
    
    return self;
}

- (SFCSegment *)segmentForAddress:(uint32_t)address
{
    for (SFCSegment *segment in _segments) {
        if (segment->_address <= address && address < segment->_address + segment->_maxSize) {
            return segment;
        }
    }
    return nil;
}

- (SFCSegment *)segmentWithName:(NSString *)name
{
    for (SFCSegment *segment in _segments) {
        if ([segment->_name isEqual:name]) {
            return segment;
        }
    }
    return nil;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@ (%p):\n    %@\n>", self.className, self, [_segments componentsJoinedByString:@"\n    "]];
}
@end
