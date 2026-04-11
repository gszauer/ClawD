CXX      := clang++
CC       := clang
CXXFLAGS := -std=c++17 -Wall -Wextra -O2 -Icore -Ideps/include
CFLAGS   := -Wall -Wextra -O2 -Icore

# Disable SIMD vectorization in HNSWLIB for portability (works on both x86 and ARM)
CXXFLAGS += -DNO_MANUAL_VECTORIZATION

SRCDIR   := core
TMPDIR   := tmp
TARGET   := assistant

# C++ sources
CXX_SRCS := config.cpp \
            frontmatter.cpp \
            data_store.cpp \
            http_client.cpp \
            tool_parser.cpp \
            tool_handler.cpp \
            tool_handlers.cpp \
            chat_history.cpp \
            note_search.cpp \
            prompt_assembler.cpp \
            backend.cpp \
            task_queue.cpp \
            calendar.cpp \
            local_gemma.cpp \
            whisper_transcribe.cpp \
            core.cpp \
            main.cpp

# C sources
C_SRCS   := cJSON.c

# Objective-C sources (Metal runtime queries)
OBJC_SRCS := metal_query.m

CXX_OBJS  := $(addprefix $(TMPDIR)/,$(CXX_SRCS:.cpp=.o))
C_OBJS    := $(addprefix $(TMPDIR)/,$(C_SRCS:.c=.o))
OBJC_OBJS := $(addprefix $(TMPDIR)/,$(OBJC_SRCS:.m=.o))
OBJS      := $(CXX_OBJS) $(C_OBJS) $(OBJC_OBJS)

# llama.cpp / whisper.cpp static libraries.
# Link order matters: mtmd must come before llama/ggml (static lib dep ordering).
# Rebuild with: ./deps/build_llama.sh
LLAMA_LIBS := deps/lib/libmtmd.a \
              deps/lib/libllama.a \
              deps/lib/libwhisper.a \
              deps/lib/libggml.a \
              deps/lib/libggml-base.a \
              deps/lib/libggml-cpu.a \
              deps/lib/libggml-blas.a \
              deps/lib/libggml-metal.a
LDFLAGS    := -framework Accelerate -framework Foundation \
              -framework Metal -framework MetalKit \
              -lstdc++

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CXX) $(CXXFLAGS) -o $@ $^ $(LLAMA_LIBS) $(LDFLAGS)

# Suppress warnings from third-party HNSWLIB headers
$(TMPDIR)/note_search.o: $(SRCDIR)/note_search.cpp | $(TMPDIR)
	$(CXX) $(CXXFLAGS) -Wno-unused-parameter -c -o $@ $<

$(TMPDIR)/%.o: $(SRCDIR)/%.cpp | $(TMPDIR)
	$(CXX) $(CXXFLAGS) -c -o $@ $<

$(TMPDIR)/%.o: $(SRCDIR)/%.c | $(TMPDIR)
	$(CC) $(CFLAGS) -c -o $@ $<

$(TMPDIR)/%.o: $(SRCDIR)/%.m | $(TMPDIR)
	$(CC) -O2 -c -o $@ $<

$(TMPDIR):
	mkdir -p $(TMPDIR)

clean:
	rm -rf $(TMPDIR) $(TARGET)

.PHONY: all clean
