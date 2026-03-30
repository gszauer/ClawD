CXX      := clang++
CC       := clang
CXXFLAGS := -std=c++17 -Wall -Wextra -O2 -Icore
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
            core.cpp \
            main.cpp

# C sources
C_SRCS   := cJSON.c

CXX_OBJS := $(addprefix $(TMPDIR)/,$(CXX_SRCS:.cpp=.o))
C_OBJS   := $(addprefix $(TMPDIR)/,$(C_SRCS:.c=.o))
OBJS     := $(CXX_OBJS) $(C_OBJS)

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CXX) $(CXXFLAGS) -o $@ $^

# Suppress warnings from third-party HNSWLIB headers
$(TMPDIR)/note_search.o: $(SRCDIR)/note_search.cpp | $(TMPDIR)
	$(CXX) $(CXXFLAGS) -Wno-unused-parameter -c -o $@ $<

$(TMPDIR)/%.o: $(SRCDIR)/%.cpp | $(TMPDIR)
	$(CXX) $(CXXFLAGS) -c -o $@ $<

$(TMPDIR)/%.o: $(SRCDIR)/%.c | $(TMPDIR)
	$(CC) $(CFLAGS) -c -o $@ $<

$(TMPDIR):
	mkdir -p $(TMPDIR)

clean:
	rm -rf $(TMPDIR) $(TARGET)

.PHONY: all clean
