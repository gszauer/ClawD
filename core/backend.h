#pragma once

#include <string>
#include <string_view>

struct Config;

// Thin wrapper that forwards assembled prompts to the self-hosted Gemma
// backend. Kept as a seam so future extensions (streaming, tool use, etc.)
// have a single hook point instead of threading through every call site.
class Backend {
public:
    // Execute a prompt, optionally with an attached image.
    // image_path is interpreted by local_gemma: when non-empty and the vision
    // projector is loaded, the image is encoded and prepended to the text.
    static std::string execute(const Config& config,
                               std::string_view prompt,
                               std::string_view image_path = {});
};
