#include "note_search.h"
#include "cJSON.h"

#include "hnswlib/hnswlib.h"

#include <fstream>
#include <cstdio>
#include <algorithm>

static int g_max_elements = 10000;
static const int M = 16;
static const int EF_CONSTRUCTION = 200;

NoteSearch::NoteSearch() = default;
NoteSearch::~NoteSearch() = default;

void NoteSearch::load_map() {
    label_to_note_.clear();
    note_to_label_.clear();
    next_label_ = 0;

    FILE* f = fopen(map_path_.c_str(), "rb");
    if (!f) return;

    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    std::string data(static_cast<size_t>(len), '\0');
    fread(data.data(), 1, static_cast<size_t>(len), f);
    fclose(f);

    cJSON* root = cJSON_Parse(data.c_str());
    if (!root) return;

    const cJSON* item = nullptr;
    cJSON_ArrayForEach(item, root) {
        if (!item->string || !cJSON_IsNumber(item)) continue;
        std::string note_id = item->string;
        auto label = static_cast<hnswlib::labeltype>(item->valueint);

        label_to_note_[label] = note_id;
        note_to_label_[note_id] = label;

        if (label >= next_label_) next_label_ = label + 1;
    }

    cJSON_Delete(root);
}

void NoteSearch::save_map() {
    cJSON* root = cJSON_CreateObject();
    for (const auto& [label, note_id] : label_to_note_) {
        cJSON_AddNumberToObject(root, note_id.c_str(), static_cast<double>(label));
    }

    char* json = cJSON_PrintUnformatted(root);
    std::ofstream out(map_path_, std::ios::trunc);
    out << json;
    free(json);
    cJSON_Delete(root);
}

void NoteSearch::create_index(int dim) {
    dimension_ = dim;
    space_ = std::make_unique<hnswlib::L2Space>(static_cast<size_t>(dim));
    index_ = std::make_unique<hnswlib::HierarchicalNSW<float>>(
        space_.get(), g_max_elements, M, EF_CONSTRUCTION);
    index_->setEf(50); // search time ef parameter
}

void NoteSearch::initialize(const std::string& index_dir, int dimension, int max_elements) {
    g_max_elements = max_elements;
    index_path_ = index_dir + "/notes.index";
    map_path_ = index_dir + "/index_map.json";

    load_map();

    // Try to load existing index
    if (dimension > 0) {
        create_index(dimension);

        // Try loading persisted index
        FILE* test = fopen(index_path_.c_str(), "rb");
        if (test) {
            fclose(test);
            try {
                index_ = std::make_unique<hnswlib::HierarchicalNSW<float>>(
                    space_.get(), index_path_, false, g_max_elements);
                index_->setEf(50);
            } catch (...) {
                // Index file corrupted — start fresh
                create_index(dimension);
                label_to_note_.clear();
                note_to_label_.clear();
                next_label_ = 0;
            }
        }

        initialized_ = true;
    }
    // If dimension == 0, we'll initialize lazily on first add()
}

void NoteSearch::add(const std::string& note_id, const std::vector<float>& embedding) {
    if (!initialized_) {
        create_index(static_cast<int>(embedding.size()));
        initialized_ = true;
    }

    if (static_cast<int>(embedding.size()) != dimension_) return;

    // If note already exists, mark old label as deleted and add new
    auto existing = note_to_label_.find(note_id);
    if (existing != note_to_label_.end()) {
        try {
            index_->markDelete(existing->second);
        } catch (...) {}
        label_to_note_.erase(existing->second);
        note_to_label_.erase(existing);
    }

    hnswlib::labeltype label = next_label_++;
    try {
        index_->addPoint(embedding.data(), label);
    } catch (...) {
        // Index might be full — resize
        try {
            index_->resizeIndex(index_->getMaxElements() + g_max_elements);
            index_->addPoint(embedding.data(), label);
        } catch (...) {
            return;
        }
    }

    label_to_note_[label] = note_id;
    note_to_label_[note_id] = label;
}

void NoteSearch::remove(const std::string& note_id) {
    if (!initialized_) return;

    auto it = note_to_label_.find(note_id);
    if (it == note_to_label_.end()) return;

    try {
        index_->markDelete(it->second);
    } catch (...) {}

    label_to_note_.erase(it->second);
    note_to_label_.erase(it);
}

std::vector<std::string> NoteSearch::search(const std::vector<float>& query, int top_k) {
    std::vector<std::string> results;
    if (!initialized_ || static_cast<int>(query.size()) != dimension_) return results;
    if (note_to_label_.empty()) return results;

    // Clamp top_k to actual number of elements
    int actual_k = std::min(top_k, static_cast<int>(note_to_label_.size()));
    if (actual_k <= 0) return results;

    try {
        auto result_queue = index_->searchKnn(query.data(), static_cast<size_t>(actual_k));

        // Extract results (priority queue gives farthest first)
        std::vector<std::pair<float, hnswlib::labeltype>> pairs;
        while (!result_queue.empty()) {
            pairs.push_back(result_queue.top());
            result_queue.pop();
        }

        // Reverse to get closest first
        for (auto it = pairs.rbegin(); it != pairs.rend(); ++it) {
            auto note_it = label_to_note_.find(it->second);
            if (note_it != label_to_note_.end()) {
                results.push_back(note_it->second);
            }
        }
    } catch (...) {
        // Search failed — return empty
    }

    return results;
}

void NoteSearch::save() {
    if (!initialized_) return;

    try {
        index_->saveIndex(index_path_);
    } catch (...) {}

    save_map();
}
