#pragma once

#include <string>
#include <vector>

// Local LLM backend built on top of llama.cpp + libmtmd.
// Supports multiple model families (Gemma, Qwen/ChatML, etc.) via automatic
// chat template detection from GGUF metadata.
//
// One loaded model serves both chat generation and embeddings:
//   - g_ctx_gen   : generation context (Q8_0 KV cache, user-configurable n_ctx)
//   - g_ctx_embed : embedding context (small, pooling_type=MEAN, text only)
//
// Multimodal input is optional: if a valid mmproj GGUF is supplied at init,
// local_gemma_generate can accept an image path and decode it alongside the
// text prompt. If mmproj loading fails, text-only mode is retained and
// local_gemma_has_vision() returns false.

// Initialize Gemma from on-disk GGUFs.
//   model_path:  required, path to the LM GGUF
//   mmproj_path: optional, path to the vision projector GGUF ("" = text only)
//   n_ctx:       context length for generation. 0 = use model's trained max.
// Returns true on success.
bool local_gemma_init(const std::string& model_path,
                      const std::string& mmproj_path,
                      int n_ctx);

// Shut down all contexts and free the model. Idempotent.
void local_gemma_shutdown();

// Is a model currently loaded?
bool local_gemma_is_loaded();

// Is a vision projector loaded and usable?
bool local_gemma_has_vision();

// Generate a response from the given prompt.
// If image_path is non-empty and has_vision() is true, the image is loaded,
// tokenized via mtmd, and prepended to the text in the same KV cache.
// Returns the detokenized assistant response (no role markers).
// On failure returns a string beginning with "[Error: ...]".
std::string local_gemma_generate(const std::string& prompt,
                                 const std::string& image_path,
                                 int max_tokens = 8192);

// Compute an embedding vector for the given text using the shared embedding
// context. Returns a normalized (L2) vector, or empty on failure.
std::vector<float> local_gemma_embed(const std::string& text);

// Return the dimension of embeddings produced by local_gemma_embed.
// Returns 0 if no model is loaded.
int local_gemma_embed_dim();

// Toggle whether reasoning blocks (e.g. Qwen's <think>...</think>) are kept
// in the generated response. Default is to strip them. Safe to call at any
// time — takes effect on the next generation.
void local_gemma_set_show_thinking(bool show);
