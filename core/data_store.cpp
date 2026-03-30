#include "data_store.h"
#include "frontmatter.h"

#include <dirent.h>
#include <sys/stat.h>
#include <cstdio>
#include <cstdlib>
#include <algorithm>
#include <cctype>
#include <fstream>
#include <random>

DataStore::DataStore(const std::string& directory) : dir_(directory) {}

static std::string read_file_contents(const std::string& path) {
    FILE* f = fopen(path.c_str(), "rb");
    if (!f) return {};
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    std::string buf(static_cast<size_t>(len), '\0');
    fread(buf.data(), 1, static_cast<size_t>(len), f);
    fclose(f);
    return buf;
}

void DataStore::load() {
    items_.clear();

    // Ensure directory exists
    mkdir(dir_.c_str(), 0755);

    DIR* d = opendir(dir_.c_str());
    if (!d) return;

    struct dirent* entry;
    while ((entry = readdir(d)) != nullptr) {
        std::string name = entry->d_name;
        if (name.size() < 4 || name.substr(name.size() - 3) != ".md") continue;
        if (name[0] == '.') continue;

        std::string path = dir_ + "/" + name;
        std::string content = read_file_contents(path);
        if (content.empty()) continue;

        Document doc = parse_document(content);

        DataItem item;
        item.id = name.substr(0, name.size() - 3); // strip .md
        item.filename = path;
        item.meta = std::move(doc.meta);
        item.body = std::move(doc.body);
        item.title = extract_title(item.body);

        items_.push_back(std::move(item));
    }
    closedir(d);

    // Sort by title for consistent ordering
    std::sort(items_.begin(), items_.end(),
              [](const DataItem& a, const DataItem& b) { return a.title < b.title; });
}

const DataItem* DataStore::find(std::string_view id) const {
    for (const auto& item : items_) {
        if (item.id == id) return &item;
    }
    return nullptr;
}

std::string DataStore::make_slug(std::string_view title) const {
    std::string slug;
    slug.reserve(title.size());
    for (char c : title) {
        if (std::isalnum(static_cast<unsigned char>(c))) {
            slug += static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
        } else if (c == ' ' || c == '-' || c == '_') {
            if (!slug.empty() && slug.back() != '_') slug += '_';
        }
    }
    // Remove trailing underscore
    while (!slug.empty() && slug.back() == '_') slug.pop_back();

    // Append random 6-digit hex for uniqueness
    static std::mt19937 rng(std::random_device{}());
    std::uniform_int_distribution<uint32_t> dist(0, 0xFFFFFF);
    char hex[8];
    snprintf(hex, sizeof(hex), "%06x", dist(rng));
    slug += "_";
    slug += hex;

    return slug;
}

std::string DataStore::make_path(std::string_view slug) const {
    return dir_ + "/" + std::string(slug) + ".md";
}

void DataStore::write_item(const DataItem& item) {
    std::string content = serialize_document(item.meta, item.body);
    std::ofstream out(item.filename, std::ios::trunc);
    out << content;
}

DataItem& DataStore::add(std::string_view title,
                         const std::map<std::string, std::string>& meta,
                         std::string_view content) {
    mkdir(dir_.c_str(), 0755);

    DataItem item;
    item.id = make_slug(title);
    item.filename = make_path(item.id);
    item.meta = meta;
    item.title = std::string(title);

    // Build body with heading if content doesn't already have one
    std::string body_str(content);
    if (body_str.find("# ") == std::string::npos) {
        body_str = "# " + std::string(title) + "\n\n" + body_str;
    }
    item.body = std::move(body_str);

    write_item(item);
    items_.push_back(std::move(item));
    return items_.back();
}

void DataStore::update(std::string_view id,
                       const std::map<std::string, std::string>& meta,
                       std::string_view body) {
    for (auto& item : items_) {
        if (item.id == id) {
            item.meta = meta;
            item.body = std::string(body);
            item.title = extract_title(item.body);
            write_item(item);
            return;
        }
    }
}

void DataStore::remove(std::string_view id) {
    for (auto it = items_.begin(); it != items_.end(); ++it) {
        if (it->id == id) {
            std::remove(it->filename.c_str());
            items_.erase(it);
            return;
        }
    }
}

std::vector<const DataItem*> DataStore::filter(
    std::function<bool(const DataItem&)> predicate) const {
    std::vector<const DataItem*> result;
    for (const auto& item : items_) {
        if (predicate(item)) result.push_back(&item);
    }
    return result;
}
