#pragma once

#include <string>
#include <vector>

// Initialize the local embedding model from a GGUF file.
// Returns true on success.
bool local_embed_init(const std::string& model_path);

// Compute an embedding vector for the given text.
// Returns an empty vector on failure or if no model is loaded.
std::vector<float> local_embed_compute(const std::string& text);

// Unload the model and free resources.
void local_embed_shutdown();

// Returns true if a model is currently loaded.
bool local_embed_is_loaded();
