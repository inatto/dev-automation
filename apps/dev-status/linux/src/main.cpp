#include <libayatana-appindicator/app-indicator.h>
#include <gtk/gtk.h>

#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cctype>
#include <csignal>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

namespace fs = std::filesystem;

namespace {

enum class StatusCode {
    Idle, Backup, Unzip, Zip, Sync, Clean, Done, Error, Paused, Exit
};

struct StatusPacket {
    StatusCode state = StatusCode::Idle;
    int progress = -1;
    std::string detail;
    std::string pauseFile;
};

struct AppState {
    AppIndicator* indicator = nullptr;
    GtkWidget* menu = nullptr;
    GtkWidget* pauseItem = nullptr;
    GtkWidget* soundItem = nullptr;
    StatusPacket current{};
    StatusCode lastWorkState = StatusCode::Idle;
    std::string socketPath;
    std::string stateDir;
    std::string soundDisabledFile;
    std::atomic<bool> running{true};
    int serverFd = -1;
};

std::string HomeDir() {
    const char* home = std::getenv("HOME");
    return home && *home ? home : "/tmp";
}

std::string DefaultStateDir() {
    if (const char* configured = std::getenv("AUTO_CODE_STATE_DIR"); configured && *configured) {
        return configured;
    }
    return HomeDir() + "/.local/state/dev-automation";
}

std::string Lower(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) {
        return static_cast<char>(std::tolower(c));
    });
    return value;
}

bool ParseState(const std::string& raw, StatusCode& state) {
    const auto value = Lower(raw);
    if (value == "idle") state = StatusCode::Idle;
    else if (value == "backup") state = StatusCode::Backup;
    else if (value == "unzip" || value == "extract") state = StatusCode::Unzip;
    else if (value == "zip" || value == "compress") state = StatusCode::Zip;
    else if (value == "sync") state = StatusCode::Sync;
    else if (value == "clean") state = StatusCode::Clean;
    else if (value == "done" || value == "ok") state = StatusCode::Done;
    else if (value == "error" || value == "fail") state = StatusCode::Error;
    else if (value == "paused" || value == "pause") state = StatusCode::Paused;
    else if (value == "exit" || value == "stop") state = StatusCode::Exit;
    else return false;
    return true;
}

const char* StateLabel(StatusCode state) {
    switch (state) {
        case StatusCode::Idle: return "Monitorando";
        case StatusCode::Backup: return "Backup";
        case StatusCode::Unzip: return "Descompactando";
        case StatusCode::Zip: return "Compactando";
        case StatusCode::Sync: return "Sincronizando";
        case StatusCode::Clean: return "Limpando";
        case StatusCode::Done: return "Concluído";
        case StatusCode::Error: return "Erro";
        case StatusCode::Paused: return "Pausado";
        case StatusCode::Exit: return "Encerrando";
    }
    return "Dev Automation";
}

const char* StateIcon(StatusCode state) {
    switch (state) {
        case StatusCode::Idle: return "dev-status-idle";
        case StatusCode::Backup: return "dev-status-backup";
        case StatusCode::Unzip: return "dev-status-unzip";
        case StatusCode::Zip: return "dev-status-zip";
        case StatusCode::Sync: return "dev-status-sync";
        case StatusCode::Clean: return "dev-status-clean";
        case StatusCode::Done: return "dev-status-done";
        case StatusCode::Error: return "dev-status-error";
        case StatusCode::Paused: return "dev-status-paused";
        case StatusCode::Exit: return "dev-status-idle";
    }
    return "dev-status-idle";
}

std::string EscapeField(std::string value) {
    for (char& c : value) {
        if (c == '\t' || c == '\n' || c == '\r') c = ' ';
    }
    return value;
}

std::vector<std::string> SplitTabs(const std::string& line) {
    std::vector<std::string> out;
    std::stringstream ss(line);
    std::string item;
    while (std::getline(ss, item, '\t')) out.push_back(item);
    return out;
}

bool FileExists(const std::string& path) {
    std::error_code ec;
    return !path.empty() && fs::exists(path, ec);
}

void SetPaused(const std::string& pauseFile, bool paused) {
    if (pauseFile.empty()) return;
    std::error_code ec;
    fs::create_directories(fs::path(pauseFile).parent_path(), ec);
    if (paused) {
        std::ofstream out(pauseFile);
        out << "paused\n";
    } else {
        fs::remove(pauseFile, ec);
    }
}

void SetSoundDisabled(const std::string& path, bool disabled) {
    std::error_code ec;
    fs::create_directories(fs::path(path).parent_path(), ec);
    if (disabled) {
        std::ofstream out(path);
        out << "disabled\n";
    } else {
        fs::remove(path, ec);
    }
}

std::string StatusText(const StatusPacket& packet) {
    std::string text = std::string("Dev Automation — ") + StateLabel(packet.state);
    if (packet.progress >= 0 && packet.progress <= 100 &&
        packet.state != StatusCode::Done && packet.state != StatusCode::Error) {
        text += " (" + std::to_string(packet.progress) + "%)";
    }
    if (!packet.detail.empty()) text += " — " + packet.detail;
    return text;
}

void RefreshMenuLabels(AppState* app) {
    if (!app || !app->pauseItem || !app->soundItem) return;
    const bool paused = FileExists(app->current.pauseFile);
    gtk_menu_item_set_label(GTK_MENU_ITEM(app->pauseItem), paused ? "Despausar dev-manager" : "Pausar dev-manager");
    const bool soundDisabled = FileExists(app->soundDisabledFile);
    gtk_menu_item_set_label(GTK_MENU_ITEM(app->soundItem), soundDisabled ? "Ativar som" : "Desativar som");
}

void UpdateIndicator(AppState* app, const StatusPacket& packet) {
    if (!app) return;
    app->current = packet;
    if (packet.state != StatusCode::Idle && packet.state != StatusCode::Paused &&
        packet.state != StatusCode::Done && packet.state != StatusCode::Exit) {
        app->lastWorkState = packet.state;
    }

    if (packet.state == StatusCode::Exit) {
        app_indicator_set_status(app->indicator, APP_INDICATOR_STATUS_PASSIVE);
        app->running = false;
        gtk_main_quit();
        return;
    }

    StatusCode iconState = packet.state;
    if (packet.state == StatusCode::Done && app->lastWorkState != StatusCode::Idle) {
        iconState = app->lastWorkState;
    }
    app_indicator_set_icon_full(app->indicator, StateIcon(iconState), StatusText(packet).c_str());
    app_indicator_set_title(app->indicator, StatusText(packet).c_str());
    app_indicator_set_status(app->indicator, APP_INDICATOR_STATUS_ACTIVE);
    RefreshMenuLabels(app);
}

struct PendingPacket {
    AppState* app;
    StatusPacket packet;
};

gboolean ApplyPacketOnMain(gpointer data) {
    std::unique_ptr<PendingPacket> pending(static_cast<PendingPacket*>(data));
    UpdateIndicator(pending->app, pending->packet);
    return G_SOURCE_REMOVE;
}

void ServerLoop(AppState* app) {
    while (app->running) {
        int client = accept(app->serverFd, nullptr, nullptr);
        if (client < 0) {
            if (errno == EINTR) continue;
            if (!app->running) break;
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
            continue;
        }

        std::string data;
        char buffer[2048];
        for (;;) {
            const ssize_t n = read(client, buffer, sizeof(buffer));
            if (n <= 0) break;
            data.append(buffer, static_cast<std::size_t>(n));
            if (data.find('\n') != std::string::npos) break;
        }
        close(client);

        const auto newline = data.find('\n');
        if (newline != std::string::npos) data.resize(newline);
        auto fields = SplitTabs(data);
        if (fields.empty()) continue;

        StatusPacket packet;
        if (!ParseState(fields[0], packet.state)) continue;
        if (fields.size() > 1 && !fields[1].empty()) {
            try { packet.progress = std::stoi(fields[1]); } catch (...) { packet.progress = -1; }
        }
        if (fields.size() > 2) packet.pauseFile = fields[2];
        if (fields.size() > 3) packet.detail = fields[3];

        auto* pending = new PendingPacket{app, packet};
        g_idle_add(ApplyPacketOnMain, pending);
    }
}

void OnPause(GtkMenuItem*, gpointer userData) {
    auto* app = static_cast<AppState*>(userData);
    if (!app || app->current.pauseFile.empty()) return;
    const bool paused = FileExists(app->current.pauseFile);
    SetPaused(app->current.pauseFile, !paused);
    StatusPacket packet = app->current;
    packet.state = paused ? StatusCode::Idle : StatusCode::Paused;
    packet.detail = paused ? "Monitorando" : "Pausado pelo indicador";
    UpdateIndicator(app, packet);
}

void OnSound(GtkMenuItem*, gpointer userData) {
    auto* app = static_cast<AppState*>(userData);
    if (!app) return;
    const bool disabled = FileExists(app->soundDisabledFile);
    SetSoundDisabled(app->soundDisabledFile, !disabled);
    RefreshMenuLabels(app);
}

void OnQuit(GtkMenuItem*, gpointer userData) {
    auto* app = static_cast<AppState*>(userData);
    if (!app) return;
    app->running = false;
    app_indicator_set_status(app->indicator, APP_INDICATOR_STATUS_PASSIVE);
    gtk_main_quit();
}

GtkWidget* BuildMenu(AppState* app) {
    GtkWidget* menu = gtk_menu_new();
    app->pauseItem = gtk_menu_item_new_with_label("Pausar dev-manager");
    app->soundItem = gtk_menu_item_new_with_label("Desativar som");
    GtkWidget* separator = gtk_separator_menu_item_new();
    GtkWidget* quitItem = gtk_menu_item_new_with_label("Fechar indicador");

    g_signal_connect(app->pauseItem, "activate", G_CALLBACK(OnPause), app);
    g_signal_connect(app->soundItem, "activate", G_CALLBACK(OnSound), app);
    g_signal_connect(quitItem, "activate", G_CALLBACK(OnQuit), app);

    gtk_menu_shell_append(GTK_MENU_SHELL(menu), app->pauseItem);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), app->soundItem);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), separator);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), quitItem);
    gtk_widget_show_all(menu);
    return menu;
}

bool CheckServer(const std::string& socketPath) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return false;
    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    if (socketPath.size() >= sizeof(addr.sun_path)) {
        close(fd);
        return false;
    }
    std::strncpy(addr.sun_path, socketPath.c_str(), sizeof(addr.sun_path) - 1);
    const bool ok = connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == 0;
    close(fd);
    return ok;
}

bool SendPacket(const std::string& socketPath, const StatusPacket& packet) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return false;

    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    if (socketPath.size() >= sizeof(addr.sun_path)) {
        close(fd);
        return false;
    }
    std::strncpy(addr.sun_path, socketPath.c_str(), sizeof(addr.sun_path) - 1);
    if (connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
        close(fd);
        return false;
    }

    std::string payload = Lower(StateLabel(packet.state)); // overwritten below
    switch (packet.state) {
        case StatusCode::Idle: payload = "idle"; break;
        case StatusCode::Backup: payload = "backup"; break;
        case StatusCode::Unzip: payload = "unzip"; break;
        case StatusCode::Zip: payload = "zip"; break;
        case StatusCode::Sync: payload = "sync"; break;
        case StatusCode::Clean: payload = "clean"; break;
        case StatusCode::Done: payload = "done"; break;
        case StatusCode::Error: payload = "error"; break;
        case StatusCode::Paused: payload = "paused"; break;
        case StatusCode::Exit: payload = "exit"; break;
    }
    payload += "\t" + std::to_string(packet.progress);
    payload += "\t" + EscapeField(packet.pauseFile);
    payload += "\t" + EscapeField(packet.detail) + "\n";

    const char* ptr = payload.data();
    std::size_t left = payload.size();
    while (left > 0) {
        const ssize_t n = write(fd, ptr, left);
        if (n <= 0) break;
        ptr += n;
        left -= static_cast<std::size_t>(n);
    }
    close(fd);
    return left == 0;
}

int CreateServer(const std::string& socketPath) {
    if (CheckServer(socketPath)) return -2;

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;

    // Remove somente socket órfão. Nunca derruba um servidor vivo.
    unlink(socketPath.c_str());
    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    if (socketPath.size() >= sizeof(addr.sun_path)) {
        close(fd);
        return -1;
    }
    std::strncpy(addr.sun_path, socketPath.c_str(), sizeof(addr.sun_path) - 1);
    if (bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
        close(fd);
        return -1;
    }
    chmod(socketPath.c_str(), 0600);
    if (listen(fd, 8) != 0) {
        close(fd);
        unlink(socketPath.c_str());
        return -1;
    }
    return fd;
}

StatusPacket ParseArgs(int argc, char** argv, bool& valid) {
    StatusPacket packet;
    valid = false;
    if (argc < 2) return packet;
    if (!ParseState(argv[1], packet.state)) return packet;
    valid = true;

    int index = 2;
    if (index < argc) {
        std::string maybeProgress = argv[index];
        bool digits = !maybeProgress.empty() && std::all_of(maybeProgress.begin(), maybeProgress.end(), [](unsigned char c) { return std::isdigit(c) != 0; });
        if (digits) {
            packet.progress = std::stoi(maybeProgress);
            if (packet.progress < 0 || packet.progress > 100) packet.progress = -1;
            ++index;
        }
    }

    while (index < argc) {
        const std::string arg = argv[index];
        if (arg == "--pause-file" && index + 1 < argc) {
            packet.pauseFile = argv[++index];
        } else if (arg == "--detail" && index + 1 < argc) {
            packet.detail = argv[++index];
        } else {
            if (!packet.detail.empty()) packet.detail += ' ';
            packet.detail += arg;
        }
        ++index;
    }
    return packet;
}

std::string ExecutableDir(const char* argv0) {
    std::error_code ec;
    fs::path p = fs::weakly_canonical(fs::path(argv0), ec);
    if (ec) p = fs::absolute(fs::path(argv0), ec);
    return p.parent_path().string();
}

int RunServer(int argc, char** argv, const StatusPacket& initial) {
    gtk_init(&argc, &argv);

    AppState app;
    app.stateDir = DefaultStateDir();
    fs::create_directories(app.stateDir);
    app.socketPath = app.stateDir + "/dev-status-linux.sock";
    app.soundDisabledFile = app.stateDir + "/dev-manager.sound-disabled";
    app.current = initial;

    app.serverFd = CreateServer(app.socketPath);
    if (app.serverFd < 0) {
        std::cerr << "[dev-status/linux] ERRO: não foi possível criar socket " << app.socketPath << "\n";
        return 2;
    }

    const std::string iconDir = ExecutableDir(argv[0]) + "/../icons";
    app.indicator = app_indicator_new("dev-automation-status", "dev-status-idle", APP_INDICATOR_CATEGORY_APPLICATION_STATUS);
    app_indicator_set_icon_theme_path(app.indicator, iconDir.c_str());
    app_indicator_set_title(app.indicator, "Dev Automation");
    app_indicator_set_status(app.indicator, APP_INDICATOR_STATUS_ACTIVE);

    app.menu = BuildMenu(&app);
    app_indicator_set_menu(app.indicator, GTK_MENU(app.menu));
    UpdateIndicator(&app, initial);

    std::thread serverThread(ServerLoop, &app);
    gtk_main();

    app.running = false;
    if (app.serverFd >= 0) {
        shutdown(app.serverFd, SHUT_RDWR);
        close(app.serverFd);
        app.serverFd = -1;
    }
    if (serverThread.joinable()) serverThread.join();
    unlink(app.socketPath.c_str());
    return 0;
}

} // namespace

int main(int argc, char** argv) {
    const std::string stateDir = DefaultStateDir();
    fs::create_directories(stateDir);
    const std::string socketPath = stateDir + "/dev-status-linux.sock";

    if (argc >= 2 && std::string(argv[1]) == "status") {
        std::cout << (CheckServer(socketPath) ? "ativo\n" : "inativo\n");
        return 0;
    }

    bool valid = false;
    StatusPacket packet = ParseArgs(argc, argv, valid);
    if (!valid) {
        std::cerr << "Uso: dev-status-linux <idle|backup|unzip|zip|sync|clean|done|error|paused|exit> [0-100] [--pause-file arquivo] [--detail texto]\n";
        return 2;
    }

    if (SendPacket(socketPath, packet)) return 0;
    if (packet.state == StatusCode::Exit) return 0;

    // Primeira chamada vira o servidor residente. O wrapper normalmente a inicia
    // em background, mas executar diretamente também funciona.
    return RunServer(argc, argv, packet);
}
