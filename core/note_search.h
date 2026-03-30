#pragma once

#include <string>
#include <vector>
#include <map>
#include <memory>

// Forward declare to avoid pulling in HNSWLIB in every translation unit
namespace hnswlib {
    template<typename dist_t> class HierarchicalNSW;
    class L2Space;
    typedef size_t labeltype;
}

class NoteSearch {
public:
    NoteSearch();
    ~NoteSearch();

    // Initialize. index_dir is where the index files are stored (working root).
    void initialize(const std::string& index_dir, int dimension = 0, int max_elements = 10000);

    // Add or update a note's embedding in the index
    void add(const std::string& note_id, const std::vector<float>& embedding);

    // Remove a note from the index (marks as deleted)
    void remove(const std::string& note_id);

    // Search for the top-k most similar notes to the query embedding
    std::vector<std::string> search(const std::vector<float>& query, int top_k = 5);

    // Persist index to disk
    void save();

    bool is_initialized() const { return initialized_; }
    int dimension() const { return dimension_; }

private:
    std::unique_ptr<hnswlib::L2Space> space_;
    std::unique_ptr<hnswlib::HierarchicalNSW<float>> index_;
    std::map<hnswlib::labeltype, std::string> label_to_note_;
    std::map<std::string, hnswlib::labeltype> note_to_label_;
    hnswlib::labeltype next_label_ = 0;
    int dimension_ = 0;
    std::string index_path_;
    std::string map_path_;
    bool initialized_ = false;

    void load_map();
    void save_map();
    void create_index(int dim);
};
