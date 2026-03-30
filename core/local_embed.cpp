#include "local_embed.h"
#include "llama.h"
#include <cstdio>
#include <cmath>
#include <cstring>

static llama_model* g_model = nullptr;
static llama_context* g_ctx = nullptr;
static const llama_vocab* g_vocab = nullptr;
static int g_n_embd = 0;

bool local_embed_init(const std::string& model_path) {
    if (g_model) local_embed_shutdown();

    llama_backend_init();

    llama_model_params mparams = llama_model_default_params();
    g_model = llama_model_load_from_file(model_path.c_str(), mparams);
    if (!g_model) {
        fprintf(stderr, "[Embedding] Failed to load GGUF model: %s\n",
                model_path.c_str());
        llama_backend_free();
        return false;
    }

    g_vocab = llama_model_get_vocab(g_model);
    g_n_embd = llama_model_n_embd(g_model);

    llama_context_params cparams = llama_context_default_params();
    cparams.n_ctx = 512;
    cparams.n_batch = 512;
    cparams.embeddings = true;
    cparams.pooling_type = LLAMA_POOLING_TYPE_MEAN;

    g_ctx = llama_init_from_model(g_model, cparams);
    if (!g_ctx) {
        fprintf(stderr, "[Embedding] Failed to create context\n");
        llama_model_free(g_model);
        g_model = nullptr;
        llama_backend_free();
        return false;
    }

    fprintf(stderr, "[Embedding] Loaded local model: %s  (dim=%d)\n",
            model_path.c_str(), g_n_embd);
    return true;
}

// L2-normalize a vector in place
static void normalize(float* vec, int n) {
    float sum = 0.0f;
    for (int i = 0; i < n; i++) sum += vec[i] * vec[i];
    float inv = 1.0f / (sqrtf(sum) + 1e-12f);
    for (int i = 0; i < n; i++) vec[i] *= inv;
}

std::vector<float> local_embed_compute(const std::string& text) {
    if (!g_ctx || !g_model) return {};

    // Tokenize
    int max_tokens = 512;
    std::vector<llama_token> tokens(max_tokens);
    int n_tokens = llama_tokenize(g_vocab, text.c_str(),
                                  static_cast<int32_t>(text.size()),
                                  tokens.data(), max_tokens,
                                  true,   // add_special (BOS/CLS)
                                  false); // parse_special
    if (n_tokens < 0) {
        fprintf(stderr, "[Embedding] Tokenization failed for text (%zu chars)\n",
                text.size());
        return {};
    }
    tokens.resize(static_cast<size_t>(n_tokens));

    // Clear previous state
    llama_memory_clear(llama_get_memory(g_ctx), true);

    // Encode
    llama_batch batch = llama_batch_get_one(tokens.data(), n_tokens);
    if (llama_encode(g_ctx, batch) != 0) {
        fprintf(stderr, "[Embedding] llama_encode failed\n");
        return {};
    }

    // Get pooled embedding (sequence 0)
    float* emb = llama_get_embeddings_seq(g_ctx, 0);
    if (!emb) {
        // Fallback to first token embedding
        emb = llama_get_embeddings_ith(g_ctx, 0);
    }
    if (!emb) {
        fprintf(stderr, "[Embedding] No embeddings returned\n");
        return {};
    }

    std::vector<float> result(emb, emb + g_n_embd);
    normalize(result.data(), g_n_embd);
    return result;
}

void local_embed_shutdown() {
    if (g_ctx) { llama_free(g_ctx); g_ctx = nullptr; }
    if (g_model) { llama_model_free(g_model); g_model = nullptr; }
    g_vocab = nullptr;
    g_n_embd = 0;
    llama_backend_free();
    fprintf(stderr, "[Embedding] Local model unloaded.\n");
}

bool local_embed_is_loaded() {
    return g_model != nullptr && g_ctx != nullptr;
}
