#pragma once

#include <string>
#include <string_view>
#include <vector>
#include <map>
#include <functional>

struct DataItem {
    std::string id;           // slug from filename (without .md)
    std::string filename;     // full filesystem path
    std::map<std::string, std::string> meta;
    std::string title;        // extracted from # heading
    std::string body;         // full body including heading
};

class DataStore {
public:
    explicit DataStore(const std::string& directory);

    void load();
    const std::vector<DataItem>& items() const { return items_; }
    const DataItem* find(std::string_view id) const;
    DataItem& add(std::string_view title,
                  const std::map<std::string, std::string>& meta,
                  std::string_view content);
    void update(std::string_view id,
                const std::map<std::string, std::string>& meta,
                std::string_view body);
    void remove(std::string_view id);

    std::vector<const DataItem*> filter(
        std::function<bool(const DataItem&)> predicate) const;

    const std::string& directory() const { return dir_; }

private:
    std::string dir_;
    std::vector<DataItem> items_;

    std::string make_slug(std::string_view title) const;
    std::string make_path(std::string_view slug) const;
    void write_item(const DataItem& item);
};
