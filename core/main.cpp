#include "core.h"

#include <iostream>
#include <string>
#include <csignal>
#include <cstring>
#include <poll.h>
#include <unistd.h>

static volatile bool g_running = true;

static void signal_handler(int) {
    g_running = false;
}

// Phase 1 stub callbacks
static void stub_http_request(const char*, const char*, const char*, const char*,
                               void (*)(const char*, int, void*), void*) {}
static void stub_websocket_send(const char*) {}
static void stub_send_notification(const char* title, const char* body) {
    std::cerr << "[Notification] " << title << ": " << body << std::endl;
}
static void stub_schedule_timer(double, int) {}
static void stub_cancel_timer(int) {}
static void stub_add_reaction(const char*, const char*, const char*) {}
static void stub_remove_reaction(const char*, const char*, const char*) {}

static void print_usage(const char* argv0) {
    std::cerr << "Usage: " << argv0 << " [options]\n"
              << "  -c, --config PATH    Path to config.json (default: ./config.json)\n"
              << "  -w, --working-dir PATH   Working directory for data (default: ./working)\n"
              << "  -h, --help           Show this help\n";
}

int main(int argc, char* argv[]) {
    // Parse args
    std::string config_path = "config.json";
    std::string working_dir;
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "-h") == 0 || std::strcmp(argv[i], "--help") == 0) {
            print_usage(argv[0]);
            return 0;
        } else if ((std::strcmp(argv[i], "-w") == 0 || std::strcmp(argv[i], "--working-dir") == 0)
                   && i + 1 < argc) {
            working_dir = argv[++i];
        } else if ((std::strcmp(argv[i], "-c") == 0 || std::strcmp(argv[i], "--config") == 0)
                   && i + 1 < argc) {
            config_path = argv[++i];
        } else {
            // Positional arg: treat as config path for backward compat
            config_path = argv[i];
        }
    }

    // Set up signal handlers
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);

    // Phase 1 callbacks
    PlatformCallbacks callbacks{};
    callbacks.http_request = stub_http_request;
    callbacks.websocket_send = stub_websocket_send;
    callbacks.send_notification = stub_send_notification;
    callbacks.schedule_timer = stub_schedule_timer;
    callbacks.cancel_timer = stub_cancel_timer;
    callbacks.add_reaction = stub_add_reaction;
    callbacks.remove_reaction = stub_remove_reaction;

    // Initialize core
    core_initialize(config_path.c_str(), callbacks,
                    working_dir.empty() ? nullptr : working_dir.c_str());

    std::cerr << "Assistant ready. Type your messages (Ctrl+D or Ctrl+C to quit).\n"
              << std::endl;

    // Main loop: read from stdin with timeout for heartbeat checks
    struct pollfd pfd;
    pfd.fd = STDIN_FILENO;
    pfd.events = POLLIN;

    std::string line_buffer;

    while (g_running) {
        // Poll stdin with 30-second timeout (heartbeat interval)
        int ret = poll(&pfd, 1, 30000);

        if (ret < 0) {
            if (errno == EINTR) continue; // signal interrupted
            break;
        }

        if (ret == 0) {
            // Timeout — run heartbeat
            core_check_tasks();
            continue;
        }

        if (pfd.revents & POLLIN) {
            std::string line;
            if (!std::getline(std::cin, line)) {
                // EOF
                break;
            }

            // Skip empty lines
            if (line.empty()) continue;

            // Special commands for Phase 1 testing
            if (line == "/quit" || line == "/exit") break;

            if (line == "/status") {
                std::cout << "Meals: " << core_get_meals() << std::endl;
                std::cout << "Chores: " << core_get_chores() << std::endl;
                std::cout << "Reminders: " << core_get_reminders() << std::endl;
                std::cout << "Notes: " << core_get_notes() << std::endl;
                continue;
            }

            if (line == "/tasks") {
                core_check_tasks();
                std::cout << "Task queue checked." << std::endl;
                continue;
            }

            if (line == "/reload") {
                core_on_config_changed();
                std::cout << "Config reloaded." << std::endl;
                continue;
            }

            // Process as a user message
            std::cout << std::endl;
            core_on_message_received("User", line.c_str(), "", "", nullptr, 0);
            std::cout << std::endl;
        }

        if (pfd.revents & (POLLHUP | POLLERR)) {
            break;
        }
    }

    std::cerr << "\nShutting down..." << std::endl;
    core_shutdown();
    return 0;
}
