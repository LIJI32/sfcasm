#import <unistd.h>
#import <Foundation/Foundation.h>
#import "SFCLayout.h"
#import "SFCFileLineReader.h"
#import "SFCStringLineReader.h"
#import "SFCAssembler.h"
#import "NSString+SFC.h"

static const char *GetFlagOperand(SFCErrorSet *errors, int argc, const char *argv[], unsigned *i)
{
    if (argv[*i][2] == 0) {
        if (*i + 1 == argc) {
            [errors addErrorWithType:SFCFatal string:@"Flag -%c requires and argument", argv[*i][1]];
            return NULL;
        }
        return argv[++*i];
    }
    return argv[*i] + 2;
}

int main(int argc, const char *argv[])
{
    SFCErrorSet *errors = [[SFCErrorSet alloc] init];

    NSString *source = nil;
    NSMutableString *builtinSource = [NSMutableString string];
    NSString *output = nil;
    NSString *layoutFile = nil;
    NSString *symFile = nil;
    NSString *vardumpFile = nil;
    NSString *depOutput = nil;
    bool depOnly = false;
    
    bool updateChecksum = false;
    
    for (unsigned i = 1; i < argc; i++) {
        const char *arg = argv[i];
        if (arg[0] == '-' && argv[1]) {
            switch (arg[1]) {
                case 'h':
                    goto printUsage;
                case 'D': {
                    const char *operand = GetFlagOperand(errors, argc, argv, &i);
                    if (!operand) goto argsDone;
                    NSArray<NSString *> *tokens = [@(operand) tokenizeByString:@"=" maximumTokens:2];
                    if (tokens.count == 1) {
                        [builtinSource appendFormat:@"define %@ 1\n", tokens[0]];
                    }
                    else {
                        [builtinSource appendFormat:@"define %@ %@\n", tokens[0], tokens[1]];
                    }
                    break;
                }
                    
                case 'V': {
                    const char *operand = GetFlagOperand(errors, argc, argv, &i);
                    if (!operand) goto argsDone;
                    NSArray<NSString *> *tokens = [@(operand) tokenizeByString:@"=" maximumTokens:2];
                    if (tokens.count == 1) {
                        [builtinSource appendFormat:@"%@ = 1\n", tokens[0]];
                    }
                    else {
                        [builtinSource appendFormat:@"%@ = %@\n", tokens[0], tokens[1]];
                    }
                    break;
                }
                    
                case 'o': {
                    const char *operand = GetFlagOperand(errors, argc, argv, &i);
                    if (!operand) goto argsDone;
                    if (output) {
                        [errors addErrorWithType:SFCFatal string:@"Multiple -o/O flags"];
                        goto argsDone;
                    }
                    output = @(operand);
                    break;
                }
                    
                case 'O': {
                    const char *operand = GetFlagOperand(errors, argc, argv, &i);
                    if (!operand) goto argsDone;
                    if (output) {
                        [errors addErrorWithType:SFCFatal string:@"Multiple -o/O flags"];
                        goto argsDone;
                    }
                    depOnly = true;
                    output = @(operand);
                    break;
                }

                case 'l': {
                    const char *operand = GetFlagOperand(errors, argc, argv, &i);
                    if (!operand) goto argsDone;
                    if (layoutFile) {
                        [errors addErrorWithType:SFCFatal string:@"Multiple -l flags"];
                        goto argsDone;

                    }
                    layoutFile = @(operand);
                    break;
                }
                case 'v': {
                    const char *operand = GetFlagOperand(errors, argc, argv, &i);
                    if (!operand) goto argsDone;
                    if (vardumpFile) {
                        [errors addErrorWithType:SFCFatal string:@"Multiple -v flags"];
                        goto argsDone;
                        
                    }
                    vardumpFile = @(operand);
                    break;
                }
                case 's': {
                    const char *operand = GetFlagOperand(errors, argc, argv, &i);
                    if (!operand) goto argsDone;
                    if (symFile) {
                        [errors addErrorWithType:SFCFatal string:@"Multiple -s flags"];
                        goto argsDone;
                        
                    }
                    symFile = @(operand);
                    break;
                }
                    
                case 'M': {
                    const char *operand = GetFlagOperand(errors, argc, argv, &i);
                    if (!operand) goto argsDone;
                    if (depOutput) {
                        [errors addErrorWithType:SFCFatal string:@"Multiple -M flags"];
                        goto argsDone;
                        
                    }
                    depOutput = @(operand);
                    break;
                }
                    
                case 'c': {
                    updateChecksum = true;
                    break;
                }
                    
                default:
                    [errors addErrorWithType:SFCError string:@"Unrecognized argument %s", arg];
                    break;
            }
        }
        else {
            if (source) {
                [errors addErrorWithType:SFCFatal string:@"Multiple input files"];
            }
            source = @(arg);
        }
    }
argsDone:;
    if (!source) {
        [errors addErrorWithType:SFCFatal string:@"No input file"];
    }
    if (!depOutput && depOnly) {
        [errors addErrorWithType:SFCFatal string:@"Using -O without a -M"];
    }
    if (errors.status == SFCFatal) {
    printUsage:
        fprintf(stderr,
                "Usage: %s <input.asm>\n"
                "Options:\n"
                "\t-o output: Sets the ROM output path (default: rom.sfc).\n"
                "\t-l layout-file: Sets a memory layout file to use instead of the default built-in one.\n"
                "\t-v var-file: The assembler will dump all global and local variables and their values to the file `var-file` after assembly.\n"
                "\t-s sym-file: The assembler will dump all global and local symbols file `sym-file` after assembly.\n"
                "\t-D define, -D define=replacement: Defines a macro $define with `replacement` (or 1, if unspecified) as its substitution.\n"
                "\t-V variable, -variable define=expression: Defines a variable `variable` with `expression` (or 1, if unspecified) as its value.\n"
                "\t-M dep-file: Output a Makefile compatiable dependency file to `depfile`.\n"
                "\t-O target: For use with -M. The file `target` will be used as the dependency file's target. The assembler will not attempt to assembler and link an output file; missing included files will not issue errors and will be added as dependencies.\n"
                "\t-h: Prints this message.\n",
                argv[0]);
        return 1;
    }
    
    id<SFCLineReader> layoutReader = nil;
    if (layoutFile) {
        layoutReader = [SFCFileLineReader lineReaderWithPath:layoutFile errorSet:errors];
    }
    else {
        layoutReader = [SFCStringLineReader readerWithString:
                        @""
                        "RAM:\n"
                        "    address = 0x0\n"
                        "    size = 0x400000\n"
                        "ROM:\n"
                        "    address = 0x400000\n"
                        "    offset = 0x0\n"
                        "HIRAM:\n"
                        "    address = 0x7E0000\n"
                                                    fileName:@"<built-in layout>"];
    }
    
    if (!layoutReader) return 1;
    SFCEvaluator *evaluator = [SFCEvaluator standardEvaluator];
    SFCLayout *layout = [[SFCLayout alloc] initWithLineReader:layoutReader evaluator:evaluator errorSet:errors];
    if (!layout) return 1;
    
    SFCAssembler *assembler = [SFCAssembler assemblerWithLayout:layout evaluator:evaluator];
    if (builtinSource.length) {
        [assembler assemble:[SFCStringLineReader readerWithString:builtinSource] toFile:nil errorSet:errors];
        if (errors.status == SFCFatal) return 1;
    }
    
    NSString *outputPath = output ?: @"rom.sfc";
    assembler.updateChecksumWhenDone = updateChecksum;
    assembler.depsMode = depOnly;
    [assembler assemble:[SFCFileLineReader lineReaderWithPath:source
                                                     errorSet:errors]
                 toFile:depOnly? nil :  outputPath // TODO: handle - output
               errorSet:errors];
    
    if (depOutput) {
        if (![[NSString stringWithFormat:@"%@ %@: %@\n %@: %@\n",
               outputPath, depOutput, [assembler.sourceDeps.allObjects componentsJoinedByString:@" "],
               outputPath, [assembler.binDeps.allObjects componentsJoinedByString:@" "]] writeToFile:depOutput atomically:false encoding:NSUTF8StringEncoding error:nil]) {
            [errors addErrorWithType:SFCError string:@"Failed to write dep file %@", depOutput];
            unlink(depOutput.UTF8String);
        }
    }
    
    if (errors.status > SFCWarning) return 1;
    
    if (symFile) {
        FILE *f = fopen(symFile.UTF8String, "w");
        if (!f) {
            [errors addErrorWithType:SFCError string:@"Failed to open %@ for writing: %s", symFile, strerror(errno)];
        }
        else {
            NSDictionary<NSString *, SFCValue *> *variables = evaluator.allVariables;
            for (NSString *symbol in [variables.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *obj1, NSString *obj2) {
                signed a = variables[obj1].intValue;
                signed b = variables[obj2].intValue;
                return (a > b) - (b > a);
            }]) {
                SFCValue *value = variables[symbol];
                if (!value.isSymbol) continue;
                fprintf(f, "%06x %s\n", (unsigned)value.intValue, symbol.UTF8String);
            }
        }
        fclose(f);
    }
    
    if (vardumpFile) {
        FILE *f = fopen(vardumpFile.UTF8String, "w");
        if (!f) {
            [errors addErrorWithType:SFCError string:@"Failed to open %@ for writing: %s", vardumpFile, strerror(errno)];
        }
        else {
            NSDictionary<NSString *, SFCValue *> *variables = evaluator.allVariables;
            for (NSString *symbol in [variables.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
                SFCValue *value = variables[symbol];
                if (value.isSymbol) continue;
                fprintf(f, "%s = %s\n", symbol.UTF8String, value.description.UTF8String);
            }
        }
        fclose(f);
    }
    
    switch (errors.status) {
        case SFCClear:
        default:
            return 0;
        case SFCWarning:
            fprintf(stderr, "%u warning(s) generated.\n", [errors countForType:SFCWarning]);
            return 0;
        case SFCError:
            fprintf(stderr, "%u errors(s) and %u warning(s) generated.\n", [errors countForType:SFCError], [errors countForType:SFCWarning]);
            return 1;
        case SFCFatal:
            fprintf(stderr, "A fatal error was generated. %u other errors(s) and %u warning(s) generated.\n", [errors countForType:SFCError], [errors countForType:SFCWarning]);
            return 1;
    }
}
