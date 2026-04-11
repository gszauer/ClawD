#include "local_gemma.h"
#include "llama.h"
#include "mtmd.h"
#include "mtmd-helper.h"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <sstream>
#include <string>
#include <vector>

#ifdef __APPLE__
#include <TargetConditionals.h>
#if TARGET_OS_MAC
// Query Metal's max threadgroup memory to decide if Q8_0 KV cache is safe.
// Defined as a C function — implemented in a .m file or via the ObjC runtime.
// Returns 0 if Metal is unavailable.
extern "C" unsigned long metal_max_threadgroup_memory(void);
#endif
#endif

// -----------------------------------------------------------------------------
// Global state (single loaded model serving both generation and embeddings)
// -----------------------------------------------------------------------------

static llama_model*        g_model    = nullptr;
static const llama_vocab*  g_vocab    = nullptr;
static llama_context*      g_ctx_gen  = nullptr; // Chat / multimodal generation
static llama_context*      g_ctx_embed = nullptr; // Note-search embeddings
static llama_sampler*      g_sampler  = nullptr;
static mtmd_context*       g_mtmd     = nullptr; // Vision projector (optional)
static int                 g_n_embd   = 0;
static bool                g_backend_inited = false;

// Chat template configuration — selected at init time based on GGUF metadata.
struct ChatTemplate {
    const char* user_open;    // e.g. "<start_of_turn>user\n"
    const char* user_close;   // e.g. "<end_of_turn>\n"
    const char* assist_open;  // e.g. "<start_of_turn>model\n"
    const char* assist_close; // e.g. "<end_of_turn>" — used as stop string
    size_t      stop_len;     // strlen(assist_close)
    const char* prefill;      // appended after assist_open (e.g. "<think>\n" for Qwen)
    bool        strip_think;  // strip leading <think>...</think> block from output
};

// Gemma family: standard turn tokens, no thinking.
static const ChatTemplate TMPL_GEMMA = {
    "<start_of_turn>user\n", "<end_of_turn>\n", "<start_of_turn>model\n", "<end_of_turn>", 12,
    "", false
};

// Qwen family (ChatML + think prefill): pre-opens <think> to trigger CoT,
// strips the reasoning block before returning.
static const ChatTemplate TMPL_QWEN = {
    "<|im_start|>user\n", "<|im_end|>\n", "<|im_start|>assistant\n", "<|im_end|>", 10,
    "<think>\n", true
};

static const ChatTemplate* g_template = &TMPL_GEMMA;
static bool g_show_thinking = false;  // if true, leave <think>...</think> in output

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------

static void free_all() {
    if (g_sampler)    { llama_sampler_free(g_sampler); g_sampler = nullptr; }
    if (g_mtmd)       { mtmd_free(g_mtmd); g_mtmd = nullptr; }
    if (g_ctx_gen)    { llama_free(g_ctx_gen); g_ctx_gen = nullptr; }
    if (g_ctx_embed)  { llama_free(g_ctx_embed); g_ctx_embed = nullptr; }
    if (g_model)      { llama_model_free(g_model); g_model = nullptr; }
    g_vocab = nullptr;
    g_n_embd = 0;
}

// L2-normalize a vector in place
static void normalize_l2(float* v, int n) {
    float sum = 0.0f;
    for (int i = 0; i < n; i++) sum += v[i] * v[i];
    float inv = 1.0f / (std::sqrt(sum) + 1e-12f);
    for (int i = 0; i < n; i++) v[i] *= inv;
}

// Piece (partial detokenization) of a single token appended to a string.
static bool append_token_piece(std::string& out, llama_token tok) {
    char buf[256];
    int n = llama_token_to_piece(g_vocab, tok, buf, sizeof(buf), 0, /*special=*/false);
    if (n < 0) return false;
    out.append(buf, static_cast<size_t>(n));
    return true;
}

// Tokenize a text string using the generation vocab.
static std::vector<llama_token> tokenize(const std::string& text,
                                         bool add_special,
                                         bool parse_special) {
    std::vector<llama_token> tokens;
    if (!g_vocab) return tokens;
    int n_est = static_cast<int>(text.size()) + 16;
    tokens.resize(n_est);
    int n = llama_tokenize(g_vocab, text.c_str(), static_cast<int32_t>(text.size()),
                           tokens.data(), n_est, add_special, parse_special);
    if (n < 0) {
        tokens.resize(-n);
        n = llama_tokenize(g_vocab, text.c_str(), static_cast<int32_t>(text.size()),
                           tokens.data(), -n, add_special, parse_special);
        if (n < 0) {
            tokens.clear();
            return tokens;
        }
    }
    tokens.resize(static_cast<size_t>(n));
    return tokens;
}

// -----------------------------------------------------------------------------
// Init / shutdown
// -----------------------------------------------------------------------------

bool local_gemma_init(const std::string& model_path,
                      const std::string& mmproj_path,
                      int n_ctx_req) {
    if (g_model) local_gemma_shutdown();

    if (model_path.empty()) {
        fprintf(stderr, "[Gemma] No model path configured.\n");
        return false;
    }

    if (!g_backend_inited) {
        llama_backend_init();
        g_backend_inited = true;
    }

    // Load the model
    llama_model_params mparams = llama_model_default_params();
    mparams.n_gpu_layers = 999; // offload everything we can to Metal
    g_model = llama_model_load_from_file(model_path.c_str(), mparams);
    if (!g_model) {
        fprintf(stderr, "[Gemma] Failed to load model: %s\n", model_path.c_str());
        return false;
    }
    g_vocab  = llama_model_get_vocab(g_model);
    g_n_embd = llama_model_n_embd(g_model);

    // Detect model family and select chat template
    {
        char arch[64] = {};
        llama_model_meta_val_str(g_model, "general.architecture", arch, sizeof(arch));
        if (strncmp(arch, "qwen", 4) == 0) {
            g_template = &TMPL_QWEN;
        } else {
            g_template = &TMPL_GEMMA;
        }
        fprintf(stderr, "[LLM] Architecture: %s  template: %s\n",
                arch, (g_template == &TMPL_QWEN) ? "Qwen (thinking)" : "Gemma");
    }

    // Resolve the requested context length, clamped to the model's trained max
    const int n_ctx_train = llama_model_n_ctx_train(g_model);
    int n_ctx = (n_ctx_req <= 0) ? n_ctx_train : n_ctx_req;
    if (n_ctx > n_ctx_train) n_ctx = n_ctx_train;
    if (n_ctx < 512) n_ctx = 512;

    // Create the generation context. Retries at half n_ctx on failure.
    auto try_make_gen_ctx = [&](int ctx_tokens) -> llama_context* {
        llama_context_params cp = llama_context_default_params();
        cp.n_ctx           = static_cast<uint32_t>(ctx_tokens);
        cp.n_batch         = 512;
        cp.n_ubatch        = 512;
        // Q8_0 KV cache halves memory but requires >32KB threadgroup memory
        // for Gemma 4's dk=512 heads. Only enable on devices that support it.
#ifdef __APPLE__
        {
            unsigned long tg_mem = metal_max_threadgroup_memory();
            if (tg_mem >= 65536) { // 64KB — M1 and later
                cp.type_k = GGML_TYPE_Q8_0;
                cp.type_v = GGML_TYPE_Q8_0;
            }
        }
#endif
        cp.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO;
        cp.offload_kqv     = true;
        cp.embeddings      = false;
        return llama_init_from_model(g_model, cp);
    };

    g_ctx_gen = try_make_gen_ctx(n_ctx);
    if (!g_ctx_gen && n_ctx > 1024) {
        int retry_ctx = n_ctx / 2;
        fprintf(stderr, "[Gemma] Gen context create failed at n_ctx=%d, retrying at %d\n",
                n_ctx, retry_ctx);
        g_ctx_gen = try_make_gen_ctx(retry_ctx);
        if (g_ctx_gen) n_ctx = retry_ctx;
    }
    if (!g_ctx_gen) {
        fprintf(stderr, "[Gemma] Failed to create generation context.\n");
        free_all();
        return false;
    }

    // Create the embedding context (small, mean-pool, text-only)
    {
        llama_context_params cp = llama_context_default_params();
        cp.n_ctx       = 512;
        cp.n_batch     = 512;
        cp.n_ubatch    = 512;
        cp.embeddings  = true;
        cp.pooling_type = LLAMA_POOLING_TYPE_MEAN;
        cp.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO;
        g_ctx_embed = llama_init_from_model(g_model, cp);
    }
    if (!g_ctx_embed) {
        fprintf(stderr, "[Gemma] Failed to create embedding context.\n");
        free_all();
        return false;
    }

    // Build the sampling chain (top-k -> top-p -> temp -> dist)
    {
        llama_sampler_chain_params sp = llama_sampler_chain_default_params();
        g_sampler = llama_sampler_chain_init(sp);
        llama_sampler_chain_add(g_sampler, llama_sampler_init_top_k(40));
        llama_sampler_chain_add(g_sampler, llama_sampler_init_top_p(0.95f, 1));
        llama_sampler_chain_add(g_sampler, llama_sampler_init_temp(0.7f));
        llama_sampler_chain_add(g_sampler, llama_sampler_init_dist(LLAMA_DEFAULT_SEED));
    }

    // Optional: load the vision projector
    if (!mmproj_path.empty()) {
        mtmd_context_params mp = mtmd_context_params_default();
        mp.use_gpu       = true;
        mp.print_timings = false;
        mp.n_threads     = 4;
        mp.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO;
        g_mtmd = mtmd_init_from_file(mmproj_path.c_str(), g_model, mp);
        if (!g_mtmd) {
            fprintf(stderr, "[Gemma] Failed to load vision projector: %s  (continuing text-only)\n",
                    mmproj_path.c_str());
        } else if (!mtmd_support_vision(g_mtmd)) {
            fprintf(stderr, "[Gemma] Loaded mmproj does not support vision, unloading.\n");
            mtmd_free(g_mtmd);
            g_mtmd = nullptr;
        }
    }

    fprintf(stderr, "[Gemma] Ready. model=%s  n_ctx=%d  embd=%d  vision=%s\n",
            model_path.c_str(), n_ctx, g_n_embd, (g_mtmd ? "yes" : "no"));
    return true;
}

void local_gemma_shutdown() {
    free_all();
    if (g_backend_inited) {
        llama_backend_free();
        g_backend_inited = false;
    }
    fprintf(stderr, "[Gemma] Unloaded.\n");
}

bool local_gemma_is_loaded()  { return g_model != nullptr && g_ctx_gen != nullptr; }
bool local_gemma_has_vision() { return g_mtmd != nullptr; }
int  local_gemma_embed_dim()  { return g_n_embd; }

// -----------------------------------------------------------------------------
// Generation
// -----------------------------------------------------------------------------

// Wrap an assembled prompt block in Gemma's chat turn tokens.
// The PromptAssembler hands us one big text block encoding system + context +
// history + final user message. We treat the whole thing as a single user turn
// and ask the model to start the assistant turn.
static std::string wrap_in_template(const std::string& prompt) {
    std::string out;
    out.reserve(prompt.size() + 128);
    out += g_template->user_open;
    out += prompt;
    out += g_template->user_close;
    out += g_template->assist_open;
    out += g_template->prefill;
    return out;
}

// Produce tokens for the generated assistant reply by sampling until we hit
// EOS / <end_of_turn> / max_tokens.
static std::string sample_loop(llama_pos n_past, int max_tokens) {
    std::string response;
    response.reserve(512);
    const int ctx_size = static_cast<int>(llama_n_ctx(g_ctx_gen));
    int generated = 0;

    while (generated < max_tokens) {
        if (n_past >= ctx_size) {
            response += "\n[Error: context window exhausted]";
            break;
        }

        llama_token tok = llama_sampler_sample(g_sampler, g_ctx_gen, -1);
        llama_sampler_accept(g_sampler, tok);

        if (llama_vocab_is_eog(g_vocab, tok)) break;

        if (!append_token_piece(response, tok)) break;

        // The EOG check above usually catches the model's stop token, but
        // keep a textual safety net in case it renders as readable text.
        if (response.size() >= g_template->stop_len) {
            const char* tail = response.c_str() + (response.size() - g_template->stop_len);
            if (std::strcmp(tail, g_template->assist_close) == 0) {
                response.resize(response.size() - g_template->stop_len);
                break;
            }
        }

        // Feed the sampled token back as the next input
        llama_batch next = llama_batch_get_one(&tok, 1);
        if (llama_decode(g_ctx_gen, next) != 0) {
            response += "\n[Error: decode failed during sampling]";
            break;
        }
        n_past += 1;
        generated += 1;
    }

    return response;
}

// Text-only generation path
static std::string generate_text(const std::string& prompt, int max_tokens) {
    std::string wrapped = wrap_in_template(prompt);
    auto tokens = tokenize(wrapped, /*add_special=*/true, /*parse_special=*/true);
    if (tokens.empty()) return "[Error: tokenization produced no tokens]";

    const int ctx_size = static_cast<int>(llama_n_ctx(g_ctx_gen));
    if (static_cast<int>(tokens.size()) + max_tokens > ctx_size) {
        fprintf(stderr, "[Gemma] Warning: prompt %zu tokens + max %d exceeds ctx %d\n",
                tokens.size(), max_tokens, ctx_size);
        // Hard-truncate from the front to leave room for generation
        int drop = static_cast<int>(tokens.size()) + max_tokens - ctx_size;
        if (drop >= static_cast<int>(tokens.size())) {
            return "[Error: prompt too long for context window]";
        }
        tokens.erase(tokens.begin(), tokens.begin() + drop);
    }

    llama_memory_clear(llama_get_memory(g_ctx_gen), true);
    llama_sampler_reset(g_sampler);

    // Prefill in n_batch-sized chunks (llama_decode can only handle n_batch
    // tokens per call, even though the context window is much larger).
    const int n_batch = 512;
    for (size_t i = 0; i < tokens.size(); i += n_batch) {
        int chunk = static_cast<int>(std::min(tokens.size() - i, static_cast<size_t>(n_batch)));
        llama_batch batch = llama_batch_get_one(tokens.data() + i, chunk);
        if (llama_decode(g_ctx_gen, batch) != 0) {
            return "[Error: decode failed during prefill]";
        }
    }

    return sample_loop(static_cast<llama_pos>(tokens.size()), max_tokens);
}

// Multimodal generation path: load the image, tokenize text+image together
// via mtmd, feed chunks into the shared generation context, then sample.
static std::string generate_with_image(const std::string& prompt,
                                       const std::string& image_path,
                                       int max_tokens) {
    if (!g_mtmd) return "[Error: vision projector not loaded]";

    mtmd_bitmap* bmp = mtmd_helper_bitmap_init_from_file(g_mtmd, image_path.c_str());
    if (!bmp) return "[Error: failed to load image: " + image_path + "]";

    // Build prompt text with Gemma turn markers and the mtmd media marker.
    const char* marker = mtmd_default_marker();
    std::string body;
    body.reserve(prompt.size() + 128);
    body += g_template->user_open;
    body += marker;
    body += "\n";
    body += prompt;
    body += g_template->user_close;
    body += g_template->assist_open;
    body += g_template->prefill;

    mtmd_input_text text_in{};
    text_in.text          = body.c_str();
    text_in.add_special   = true;
    text_in.parse_special = true;

    mtmd_input_chunks* chunks = mtmd_input_chunks_init();
    const mtmd_bitmap* bitmaps[1] = { bmp };
    int32_t tok_rc = mtmd_tokenize(g_mtmd, chunks, &text_in, bitmaps, 1);
    mtmd_bitmap_free(bmp);
    if (tok_rc != 0) {
        mtmd_input_chunks_free(chunks);
        return "[Error: mtmd_tokenize failed]";
    }

    llama_memory_clear(llama_get_memory(g_ctx_gen), true);
    llama_sampler_reset(g_sampler);

    llama_pos new_n_past = 0;
    int32_t ev_rc = mtmd_helper_eval_chunks(
        g_mtmd, g_ctx_gen, chunks,
        /*n_past=*/0, /*seq_id=*/0,
        /*n_batch=*/512, /*logits_last=*/true,
        &new_n_past);
    mtmd_input_chunks_free(chunks);

    if (ev_rc != 0) {
        return "[Error: mtmd_helper_eval_chunks failed]";
    }

    return sample_loop(new_n_past, max_tokens);
}

// Strip a leading reasoning block from Qwen-style thinking output.
// We pre-injected "<think>\n" into the prompt, so the model's response begins
// with thinking content followed by "</think>" and then the real answer.
// If the close tag is missing (e.g. truncated mid-thought), return as-is.
static std::string strip_thinking_block(std::string response) {
    size_t end = response.find("</think>");
    if (end == std::string::npos) return response;
    response.erase(0, end + 8); // 8 = strlen("</think>")
    size_t first = response.find_first_not_of(" \n\r\t");
    if (first != std::string::npos) response.erase(0, first);
    else response.clear();
    return response;
}

std::string local_gemma_generate(const std::string& prompt,
                                 const std::string& image_path,
                                 int max_tokens) {
    if (!local_gemma_is_loaded()) return "[Error: No model loaded]";
    if (max_tokens <= 0) max_tokens = 8192;

    std::string response = (!image_path.empty() && g_mtmd)
        ? generate_with_image(prompt, image_path, max_tokens)
        : generate_text(prompt, max_tokens);

    if (g_template->strip_think && response.rfind("[Error:", 0) != 0) {
        if (g_show_thinking) {
            // The opening <think>\n was injected into the prompt (not the
            // response), so prepend it to make the block self-contained.
            response.insert(0, g_template->prefill);
        } else {
            response = strip_thinking_block(std::move(response));
        }
    }
    return response;
}

void local_gemma_set_show_thinking(bool show) {
    g_show_thinking = show;
}

// -----------------------------------------------------------------------------
// Embeddings
// -----------------------------------------------------------------------------

std::vector<float> local_gemma_embed(const std::string& text) {
    std::vector<float> out;
    if (!g_ctx_embed || !g_vocab) return out;

    const int max_tokens = 512;
    std::vector<llama_token> tokens(max_tokens);
    int n = llama_tokenize(g_vocab, text.c_str(), static_cast<int32_t>(text.size()),
                           tokens.data(), max_tokens,
                           /*add_special=*/true, /*parse_special=*/false);
    if (n < 0) {
        // Truncate to fit — decoder-only embedding from first 512 tokens is fine
        n = -n;
        if (n > max_tokens) n = max_tokens;
        n = llama_tokenize(g_vocab, text.c_str(), static_cast<int32_t>(text.size()),
                           tokens.data(), n,
                           /*add_special=*/true, /*parse_special=*/false);
        if (n < 0) return out;
    }
    tokens.resize(static_cast<size_t>(n));

    llama_memory_clear(llama_get_memory(g_ctx_embed), true);

    llama_batch batch = llama_batch_get_one(tokens.data(), static_cast<int32_t>(tokens.size()));
    if (llama_decode(g_ctx_embed, batch) != 0) {
        fprintf(stderr, "[Gemma] llama_decode failed in embed path\n");
        return out;
    }

    float* emb = llama_get_embeddings_seq(g_ctx_embed, 0);
    if (!emb) emb = llama_get_embeddings_ith(g_ctx_embed, 0);
    if (!emb) {
        fprintf(stderr, "[Gemma] No embeddings returned\n");
        return out;
    }

    out.assign(emb, emb + g_n_embd);
    normalize_l2(out.data(), g_n_embd);
    return out;
}
