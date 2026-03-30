#include "http_client.h"

#include <sys/socket.h>
#include <netinet/in.h>
#include <netdb.h>
#include <unistd.h>
#include <cerrno>
#include <cstring>
#include <sstream>
#include <string>

struct ParsedUrl {
    std::string host;
    std::string port;
    std::string path;
};

static ParsedUrl parse_url(std::string_view url) {
    ParsedUrl u;
    // Skip "http://"
    if (url.substr(0, 7) == "http://") url.remove_prefix(7);
    else if (url.substr(0, 8) == "https://") url.remove_prefix(8);

    size_t path_start = url.find('/');
    std::string_view authority = (path_start != std::string_view::npos)
                                     ? url.substr(0, path_start)
                                     : url;

    size_t colon = authority.find(':');
    if (colon != std::string_view::npos) {
        u.host = std::string(authority.substr(0, colon));
        u.port = std::string(authority.substr(colon + 1));
    } else {
        u.host = std::string(authority);
        u.port = "80";
    }

    u.path = (path_start != std::string_view::npos)
                 ? std::string(url.substr(path_start))
                 : "/";
    return u;
}

static int connect_to(const std::string& host, const std::string& port) {
    struct addrinfo hints{}, *res = nullptr;
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;

    if (getaddrinfo(host.c_str(), port.c_str(), &hints, &res) != 0) return -1;

    int fd = -1;
    for (auto* rp = res; rp; rp = rp->ai_next) {
        fd = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
        if (fd < 0) continue;
        if (connect(fd, rp->ai_addr, rp->ai_addrlen) == 0) break;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    return fd;
}

static std::string read_all(int fd) {
    std::string result;
    char buf[4096];
    for (;;) {
        ssize_t n = recv(fd, buf, sizeof(buf), 0);
        if (n <= 0) break;
        result.append(buf, static_cast<size_t>(n));
    }
    return result;
}

static HttpResponse parse_response(const std::string& raw) {
    HttpResponse resp;

    // Find status line
    size_t line_end = raw.find("\r\n");
    if (line_end == std::string::npos) { resp.status = -1; return resp; }

    // Parse "HTTP/1.x STATUS ..."
    std::string_view status_line(raw.data(), line_end);
    size_t sp1 = status_line.find(' ');
    if (sp1 != std::string_view::npos) {
        size_t sp2 = status_line.find(' ', sp1 + 1);
        std::string_view code_str = status_line.substr(sp1 + 1,
            (sp2 != std::string_view::npos ? sp2 : status_line.size()) - sp1 - 1);
        resp.status = std::atoi(std::string(code_str).c_str());
    }

    // Find header/body boundary
    size_t body_start = raw.find("\r\n\r\n");
    if (body_start == std::string::npos) return resp;
    body_start += 4;

    // Check for chunked transfer encoding
    std::string lower_headers = raw.substr(0, body_start);
    for (auto& c : lower_headers) c = static_cast<char>(tolower(c));

    if (lower_headers.find("transfer-encoding: chunked") != std::string::npos) {
        // Decode chunked body
        std::string decoded;
        size_t pos = body_start;
        while (pos < raw.size()) {
            size_t chunk_end = raw.find("\r\n", pos);
            if (chunk_end == std::string::npos) break;

            std::string hex_str = raw.substr(pos, chunk_end - pos);
            unsigned long chunk_size = strtoul(hex_str.c_str(), nullptr, 16);
            if (chunk_size == 0) break;

            pos = chunk_end + 2;
            if (pos + chunk_size <= raw.size()) {
                decoded.append(raw, pos, chunk_size);
            }
            pos += chunk_size + 2; // skip chunk data + \r\n
        }
        resp.body = std::move(decoded);
    } else {
        resp.body = raw.substr(body_start);
    }

    return resp;
}

static HttpResponse do_request(std::string_view method, std::string_view url,
                               std::string_view body, std::string_view content_type,
                               std::string_view auth_header = "") {
    ParsedUrl u = parse_url(url);

    int fd = connect_to(u.host, u.port);
    if (fd < 0) return {-1, "Connection failed"};

    // Build HTTP request
    std::ostringstream req;
    req << method << " " << u.path << " HTTP/1.1\r\n";
    req << "Host: " << u.host;
    if (u.port != "80") req << ":" << u.port;
    req << "\r\n";
    req << "Connection: close\r\n";

    if (!auth_header.empty()) {
        req << "Authorization: " << auth_header << "\r\n";
    }

    if (!body.empty()) {
        req << "Content-Type: " << content_type << "\r\n";
        req << "Content-Length: " << body.size() << "\r\n";
    }
    req << "\r\n";
    if (!body.empty()) req << body;

    std::string request = req.str();
    ssize_t sent = send(fd, request.data(), request.size(), 0);
    if (sent < 0) {
        close(fd);
        return {-1, "Send failed"};
    }

    std::string raw = read_all(fd);
    close(fd);

    return parse_response(raw);
}

HttpResponse http_post(std::string_view url, std::string_view body,
                       std::string_view content_type, std::string_view auth_header) {
    return do_request("POST", url, body, content_type, auth_header);
}

HttpResponse http_get(std::string_view url) {
    return do_request("GET", url, {}, {});
}
