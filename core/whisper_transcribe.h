#pragma once

#include <string>

bool whisper_transcribe_init(const std::string& model_path);
std::string whisper_transcribe_audio(const std::string& audio_path);
void whisper_transcribe_shutdown();
bool whisper_transcribe_is_loaded();
