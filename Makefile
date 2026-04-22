BIN := build/bin
OBJ := build/obj

SOURCES := $(shell echo src/*.m)
OBJECTS := $(patsubst %,$(OBJ)/%.o,$(SOURCES))
CFLAGS += -fobjc-arc -O3
LDFLAGS = -framework Foundation

ifneq ($(shell uname -s),Darwin)
export CC=clang # Force Clang on non-Darwin

CFLAGS += -fobjc-runtime=gnustep-2.2 -fblocks -IGNUstepHeaders
LDFLAGS = -fobjc-runtime=gnustep-2.2 -fblocks -lm -Wl,-rpath,/usr/local/lib -L/usr/local/lib -lgnustep-base -lobjc
# GNU defines (u)int64_t as long rather than long long, making formats complain for literally no reason because both are 64-bits long
CFLAGS += -Wno-format

endif

all: $(BIN)/sfcasm

ifneq ($(MAKECMDGOALS),clean)
-include $(OBJECTS:.o=.dep)
endif
$(BIN)/sfcasm: $(OBJECTS)
	-@mkdir -p $(dir $@)
	clang $(LDFLAGS) $^ -o $@

$(OBJ)/%.o: %
	-@mkdir -p $(dir $@)
	clang -c $(CFLAGS) $< -o $@
	
$(OBJ)/%.dep: %
	-@mkdir -p $(dir $@)
	clang $(CFLAGS) -MT $(OBJ)/$^.o -M $^ -o $@
	
clean:
	rm -rf build
	
install: $(BIN)/sfcasm
	install $^ /usr/local/bin