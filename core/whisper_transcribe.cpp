#include "whisper_transcribe.h"
#include "whisper.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <string>

static whisper_context* g_wctx = nullptr;

bool whisper_transcribe_init(const std::string& model_path) {
    if (g_wctx) whisper_transcribe_shutdown();

    whisper_context_params cparams = whisper_context_default_params();
    g_wctx = whisper_init_from_file_with_params(model_path.c_str(), cparams);
    if (!g_wctx) {
        fprintf(stderr, "[Whisper] Failed to load model: %s\n", model_path.c_str());
        return false;
    }
    fprintf(stderr, "[Whisper] Loaded model: %s\n", model_path.c_str());
    return true;
}

// Read a WAV file and return PCM float32 samples at the file's native sample rate.
// Handles 16-bit PCM WAV only.
static bool read_wav(const std::string& path, std::vector<float>& out, int& sample_rate) {
    FILE* f = fopen(path.c_str(), "rb");
    if (!f) return false;

    // Read RIFF header
    char riff[4];
    fread(riff, 1, 4, f);
    if (memcmp(riff, "RIFF", 4) != 0) { fclose(f); return false; }

    fseek(f, 4, SEEK_CUR); // skip file size
    char wave[4];
    fread(wave, 1, 4, f);
    if (memcmp(wave, "WAVE", 4) != 0) { fclose(f); return false; }

    int channels = 0;
    sample_rate = 0;
    int bits_per_sample = 0;

    // Find fmt and data chunks
    while (!feof(f)) {
        char chunk_id[4];
        uint32_t chunk_size;
        if (fread(chunk_id, 1, 4, f) != 4) break;
        if (fread(&chunk_size, 4, 1, f) != 1) break;

        if (memcmp(chunk_id, "fmt ", 4) == 0) {
            uint16_t audio_format;
            fread(&audio_format, 2, 1, f);
            uint16_t num_channels;
            fread(&num_channels, 2, 1, f);
            channels = num_channels;
            uint32_t sr;
            fread(&sr, 4, 1, f);
            sample_rate = static_cast<int>(sr);
            fseek(f, 4, SEEK_CUR); // byte rate
            fseek(f, 2, SEEK_CUR); // block align
            uint16_t bps;
            fread(&bps, 2, 1, f);
            bits_per_sample = bps;
            // Skip rest of fmt chunk
            if (chunk_size > 16) fseek(f, chunk_size - 16, SEEK_CUR);
        } else if (memcmp(chunk_id, "data", 4) == 0) {
            if (bits_per_sample != 16 || channels < 1) { fclose(f); return false; }
            int n_samples = static_cast<int>(chunk_size / (channels * 2));
            std::vector<int16_t> pcm16(n_samples * channels);
            fread(pcm16.data(), 2, n_samples * channels, f);

            // Convert to mono float32
            out.resize(n_samples);
            for (int i = 0; i < n_samples; i++) {
                float sum = 0;
                for (int c = 0; c < channels; c++) {
                    sum += pcm16[i * channels + c];
                }
                out[i] = (sum / channels) / 32768.0f;
            }
            fclose(f);
            return true;
        } else {
            fseek(f, chunk_size, SEEK_CUR);
        }
    }

    fclose(f);
    return false;
}

// Simple linear resampler
static std::vector<float> resample(const std::vector<float>& in, int from_rate, int to_rate) {
    if (from_rate == to_rate) return in;
    double ratio = static_cast<double>(to_rate) / from_rate;
    size_t out_len = static_cast<size_t>(in.size() * ratio);
    std::vector<float> out(out_len);
    for (size_t i = 0; i < out_len; i++) {
        double src = i / ratio;
        size_t idx = static_cast<size_t>(src);
        double frac = src - idx;
        if (idx + 1 < in.size()) {
            out[i] = static_cast<float>(in[idx] * (1.0 - frac) + in[idx + 1] * frac);
        } else if (idx < in.size()) {
            out[i] = in[idx];
        }
    }
    return out;
}

std::string whisper_transcribe_audio(const std::string& audio_path) {
    if (!g_wctx) return {};

    // Convert ogg/opus to wav using macOS afconvert
    std::string wav_path = audio_path;
    bool needs_convert = false;
    auto ext_pos = audio_path.rfind('.');
    if (ext_pos != std::string::npos) {
        std::string ext = audio_path.substr(ext_pos);
        if (ext == ".ogg" || ext == ".opus" || ext == ".mp3" || ext == ".aac" || ext == ".m4a") {
            needs_convert = true;
            wav_path = audio_path.substr(0, ext_pos) + ".wav";
            std::string cmd = "afconvert '" + audio_path + "' '" + wav_path + "' -d LEI16 -f WAVE 2>/dev/null";
            if (system(cmd.c_str()) != 0) {
                fprintf(stderr, "[Whisper] afconvert failed for: %s\n", audio_path.c_str());
                return {};
            }
        }
    }

    // Read WAV
    std::vector<float> pcm;
    int sample_rate = 0;
    if (!read_wav(wav_path, pcm, sample_rate)) {
        fprintf(stderr, "[Whisper] Failed to read WAV: %s\n", wav_path.c_str());
        if (needs_convert) remove(wav_path.c_str());
        return {};
    }

    if (needs_convert) remove(wav_path.c_str());

    // Resample to 16kHz if needed (whisper requires 16000 Hz)
    if (sample_rate != 16000) {
        fprintf(stderr, "[Whisper] Resampling from %d Hz to 16000 Hz\n", sample_rate);
        pcm = resample(pcm, sample_rate, 16000);
    }

    fprintf(stderr, "[Whisper] Transcribing %zu samples (%.1f seconds)\n",
            pcm.size(), pcm.size() / 16000.0f);

    // Run whisper
    whisper_full_params wparams = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    wparams.print_progress   = false;
    wparams.print_special    = false;
    wparams.print_realtime   = false;
    wparams.print_timestamps = false;
    wparams.single_segment   = false;
    wparams.language         = "en";

    if (whisper_full(g_wctx, wparams, pcm.data(), static_cast<int>(pcm.size())) != 0) {
        fprintf(stderr, "[Whisper] Transcription failed\n");
        return {};
    }

    // Collect segments
    std::string result;
    int n_segments = whisper_full_n_segments(g_wctx);
    for (int i = 0; i < n_segments; i++) {
        const char* text = whisper_full_get_segment_text(g_wctx, i);
        if (text) result += text;
    }

    // Trim
    while (!result.empty() && (result.front() == ' ' || result.front() == '\n'))
        result.erase(result.begin());
    while (!result.empty() && (result.back() == ' ' || result.back() == '\n'))
        result.pop_back();

    fprintf(stderr, "[Whisper] Transcript: %s\n", result.c_str());
    return result;
}

void whisper_transcribe_shutdown() {
    if (g_wctx) {
        whisper_free(g_wctx);
        g_wctx = nullptr;
        fprintf(stderr, "[Whisper] Model unloaded.\n");
    }
}

bool whisper_transcribe_is_loaded() {
    return g_wctx != nullptr;
}
