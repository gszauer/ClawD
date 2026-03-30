#pragma once

#include <string>
#include <string_view>

struct HttpResponse {
    int status = 0;
    std::string body;
    bool ok() const { return status >= 200 && status < 300; }
};

// Simple POSIX-socket HTTP/1.1 client for Phase 1.
// Supports plain HTTP only (no TLS). Sufficient for localhost endpoints.
HttpResponse http_post(std::string_view url, std::string_view body,
                       std::string_view content_type = "application/json",
                       std::string_view auth_header = "");

HttpResponse http_get(std::string_view url);
