#include "backend.h"
#include "config.h"
#include "local_gemma.h"

std::string Backend::execute(const Config& /*config*/,
                             std::string_view prompt,
                             std::string_view image_path) {
    if (!local_gemma_is_loaded()) {
        return "[Error: No model loaded. Set the model path and restart.]";
    }
    return local_gemma_generate(std::string(prompt),
                                std::string(image_path),
                                /*max_tokens=*/8192);
}
