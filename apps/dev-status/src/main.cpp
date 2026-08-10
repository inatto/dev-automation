#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <aclapi.h>
#include <shellapi.h>

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cwctype>
#include <iterator>
#include <cwchar>
#include <memory>
#include <string>
#include <thread>
#include <vector>

namespace {

constexpr wchar_t kWindowClass[] = L"DevAutomationStatusTrayWindow.v2";
constexpr wchar_t kMutexName[] = L"Local\\DevAutomationStatus.Server.v1";
constexpr wchar_t kPipeName[] = L"\\\\.\\pipe\\dev-automation-status-v1";
constexpr UINT kStatusMessage = WM_APP + 41;
constexpr UINT kTrayMessage = WM_APP + 42;
constexpr UINT kTrayIconId = 1;
constexpr GUID kTrayGuid{
    0xda5b2f34, 0x66d5, 0x4176, {0x8f, 0xa5, 0x08, 0x74, 0xc6, 0x0c, 0x7c, 0x34}
};
constexpr std::uint32_t kProtocolMagic = 0x44565331; // DVS1
constexpr std::uint32_t kProtocolVersion = 1;
constexpr int kNoProgress = -1;

UINT g_taskbarCreated = 0;

enum class StatusCode : std::uint32_t {
    Idle = 0,
    Backup = 1,
    Unzip = 2,
    Zip = 3,
    Sync = 4,
    Clean = 5,
    Done = 6,
    Error = 7,
    Exit = 8,
};

struct StatusPacket {
    std::uint32_t magic = kProtocolMagic;
    std::uint32_t version = kProtocolVersion;
    StatusCode state = StatusCode::Idle;
    std::int32_t progress = kNoProgress;
    wchar_t detail[240]{};
};

static_assert(sizeof(StatusPacket) <= 1024);

struct AppState {
    StatusPacket current{};
    HICON trayIcon = nullptr;
    bool trayAdded = false;
};

std::wstring ToLower(std::wstring value) {
    std::transform(value.begin(), value.end(), value.begin(), [](wchar_t c) {
        return static_cast<wchar_t>(towlower(c));
    });
    return value;
}

bool TryParseState(const std::wstring& raw, StatusCode& state) {
    const auto value = ToLower(raw);
    if (value == L"idle") state = StatusCode::Idle;
    else if (value == L"backup") state = StatusCode::Backup;
    else if (value == L"unzip" || value == L"extract") state = StatusCode::Unzip;
    else if (value == L"zip" || value == L"compress") state = StatusCode::Zip;
    else if (value == L"sync") state = StatusCode::Sync;
    else if (value == L"clean") state = StatusCode::Clean;
    else if (value == L"done" || value == L"ok") state = StatusCode::Done;
    else if (value == L"error" || value == L"fail") state = StatusCode::Error;
    else if (value == L"exit" || value == L"stop") state = StatusCode::Exit;
    else return false;
    return true;
}

bool TryParseProgress(const wchar_t* raw, int& progress) {
    if (!raw || !*raw) return false;
    wchar_t* end = nullptr;
    const long value = wcstol(raw, &end, 10);
    if (!end || *end != L'\0' || value < 0 || value > 100) return false;
    progress = static_cast<int>(value);
    return true;
}

std::wstring StateLabel(StatusCode state) {
    switch (state) {
        case StatusCode::Idle: return L"Monitorando";
        case StatusCode::Backup: return L"Backup";
        case StatusCode::Unzip: return L"Descompactando";
        case StatusCode::Zip: return L"Compactando";
        case StatusCode::Sync: return L"Sincronizando";
        case StatusCode::Clean: return L"Limpando";
        case StatusCode::Done: return L"Concluído";
        case StatusCode::Error: return L"Erro";
        case StatusCode::Exit: return L"Encerrando";
    }
    return L"Dev Automation";
}

wchar_t StateGlyph(StatusCode state) {
    switch (state) {
        case StatusCode::Idle: return L'D';
        case StatusCode::Backup: return L'B';
        case StatusCode::Unzip: return L'U';
        case StatusCode::Zip: return L'Z';
        case StatusCode::Sync: return L'S';
        case StatusCode::Clean: return L'C';
        case StatusCode::Done: return L'V';
        case StatusCode::Error: return L'!';
        default: return L'D';
    }
}

COLORREF StateColor(StatusCode state) {
    switch (state) {
        case StatusCode::Backup: return RGB(111, 66, 193);
        case StatusCode::Unzip: return RGB(0, 120, 215);
        case StatusCode::Zip: return RGB(202, 80, 16);
        case StatusCode::Sync: return RGB(0, 153, 153);
        case StatusCode::Clean: return RGB(96, 96, 96);
        case StatusCode::Done: return RGB(16, 124, 16);
        case StatusCode::Error: return RGB(196, 43, 28);
        default: return RGB(80, 80, 80);
    }
}

HICON CreateStatusIcon(StatusCode state) {
    constexpr int size = 32;
    HDC screen = GetDC(nullptr);
    if (!screen) return nullptr;

    HDC colorDc = CreateCompatibleDC(screen);
    HDC maskDc = CreateCompatibleDC(screen);
    HBITMAP colorBitmap = CreateCompatibleBitmap(screen, size, size);
    HBITMAP maskBitmap = CreateBitmap(size, size, 1, 1, nullptr);
    ReleaseDC(nullptr, screen);

    if (!colorDc || !maskDc || !colorBitmap || !maskBitmap) {
        if (colorDc) DeleteDC(colorDc);
        if (maskDc) DeleteDC(maskDc);
        if (colorBitmap) DeleteObject(colorBitmap);
        if (maskBitmap) DeleteObject(maskBitmap);
        return nullptr;
    }

    const auto oldColor = SelectObject(colorDc, colorBitmap);
    const auto oldMask = SelectObject(maskDc, maskBitmap);

    RECT rect{0, 0, size, size};
    FillRect(colorDc, &rect, static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH)));
    FillRect(maskDc, &rect, static_cast<HBRUSH>(GetStockObject(WHITE_BRUSH)));

    HBRUSH colorBrush = CreateSolidBrush(StateColor(state));
    const auto oldColorBrush = SelectObject(colorDc, colorBrush);
    const auto oldColorPen = SelectObject(colorDc, GetStockObject(NULL_PEN));
    Ellipse(colorDc, 1, 1, size - 1, size - 1);

    const auto oldMaskBrush = SelectObject(maskDc, GetStockObject(BLACK_BRUSH));
    const auto oldMaskPen = SelectObject(maskDc, GetStockObject(NULL_PEN));
    Ellipse(maskDc, 1, 1, size - 1, size - 1);

    wchar_t glyph[2]{StateGlyph(state), L'\0'};
    SetBkMode(colorDc, TRANSPARENT);
    SetTextColor(colorDc, RGB(255, 255, 255));

    HFONT font = CreateFontW(
        -20, 0, 0, 0, FW_BOLD, FALSE, FALSE, FALSE,
        DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
        CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_SWISS, L"Segoe UI");
    const auto oldFont = SelectObject(colorDc, font ? font : GetStockObject(DEFAULT_GUI_FONT));
    DrawTextW(colorDc, glyph, 1, &rect, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    SelectObject(colorDc, oldFont);
    if (font) DeleteObject(font);

    SelectObject(colorDc, oldColorBrush);
    SelectObject(colorDc, oldColorPen);
    SelectObject(maskDc, oldMaskBrush);
    SelectObject(maskDc, oldMaskPen);
    SelectObject(colorDc, oldColor);
    SelectObject(maskDc, oldMask);

    ICONINFO info{};
    info.fIcon = TRUE;
    info.hbmMask = maskBitmap;
    info.hbmColor = colorBitmap;
    HICON icon = CreateIconIndirect(&info);

    DeleteObject(colorBrush);
    DeleteObject(colorBitmap);
    DeleteObject(maskBitmap);
    DeleteDC(colorDc);
    DeleteDC(maskDc);
    return icon;
}

std::wstring StatusText(const StatusPacket& packet) {
    std::wstring text = L"Dev Automation — " + StateLabel(packet.state);
    if (packet.progress >= 0 && packet.progress <= 100 &&
        packet.state != StatusCode::Done && packet.state != StatusCode::Error) {
        text += L" (" + std::to_wstring(packet.progress) + L"%)";
    }
    if (packet.detail[0] != L'\0') {
        text += L" — ";
        text += packet.detail;
    }
    return text;
}

void RemoveTrayIcon(HWND hwnd, AppState& app) {
    if (app.trayAdded) {
        NOTIFYICONDATAW data{};
        data.cbSize = sizeof(data);
        data.hWnd = hwnd;
        data.uID = kTrayIconId;
        data.uFlags = NIF_GUID;
        data.guidItem = kTrayGuid;
        Shell_NotifyIconW(NIM_DELETE, &data);
        app.trayAdded = false;
    }
    if (app.trayIcon) {
        DestroyIcon(app.trayIcon);
        app.trayIcon = nullptr;
    }
}

void UpdateTrayIcon(HWND hwnd, AppState& app, bool forceAdd = false) {
    if (app.current.state == StatusCode::Exit) {
        RemoveTrayIcon(hwnd, app);
        return;
    }

    HICON icon = CreateStatusIcon(app.current.state);
    if (!icon) icon = LoadIconW(nullptr, IDI_APPLICATION);

    NOTIFYICONDATAW data{};
    data.cbSize = sizeof(data);
    data.hWnd = hwnd;
    data.uID = kTrayIconId;
    data.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP | NIF_GUID;
    data.uCallbackMessage = kTrayMessage;
    data.hIcon = icon;
    data.guidItem = kTrayGuid;

    std::wstring tip = StatusText(app.current);
    if (tip.size() >= std::size(data.szTip)) tip.resize(std::size(data.szTip) - 1);
    wcscpy_s(data.szTip, tip.c_str());

    if (forceAdd || !app.trayAdded) {
        if (Shell_NotifyIconW(NIM_ADD, &data)) {
            app.trayAdded = true;
            data.uVersion = NOTIFYICON_VERSION_4;
            Shell_NotifyIconW(NIM_SETVERSION, &data);
        }
    } else {
        Shell_NotifyIconW(NIM_MODIFY, &data);
    }

    if (app.trayIcon) DestroyIcon(app.trayIcon);
    app.trayIcon = (icon && icon != LoadIconW(nullptr, IDI_APPLICATION)) ? icon : nullptr;
}

void ApplyStatus(HWND hwnd, AppState& app, const StatusPacket& packet) {
    app.current = packet;
    UpdateTrayIcon(hwnd, app);
}

LRESULT CALLBACK WindowProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam) {
    auto* app = reinterpret_cast<AppState*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));

    if (message == WM_NCCREATE) {
        auto* create = reinterpret_cast<CREATESTRUCTW*>(lParam);
        app = static_cast<AppState*>(create->lpCreateParams);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(app));
    }

    if (message == g_taskbarCreated && app) {
        app->trayAdded = false;
        UpdateTrayIcon(hwnd, *app, true);
        return 0;
    }

    switch (message) {
        case kStatusMessage: {
            std::unique_ptr<StatusPacket> packet(reinterpret_cast<StatusPacket*>(lParam));
            if (!app || !packet) return 0;
            ApplyStatus(hwnd, *app, *packet);
            if (packet->state == StatusCode::Exit) DestroyWindow(hwnd);
            return 0;
        }
        case kTrayMessage:
            // O ícone é apenas indicador de status. Não abre janelas ao clicar.
            return 0;
        case WM_CLOSE:
            DestroyWindow(hwnd);
            return 0;
        case WM_DESTROY:
            if (app) RemoveTrayIcon(hwnd, *app);
            PostQuitMessage(0);
            return 0;
        default:
            return DefWindowProcW(hwnd, message, wParam, lParam);
    }
}

class PipeSecurity {
public:
    PipeSecurity() = default;
    PipeSecurity(const PipeSecurity&) = delete;
    PipeSecurity& operator=(const PipeSecurity&) = delete;

    ~PipeSecurity() {
        if (acl_) LocalFree(acl_);
        if (token_) CloseHandle(token_);
    }

    bool Initialize() {
        if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token_)) return false;

        DWORD size = 0;
        GetTokenInformation(token_, TokenUser, nullptr, 0, &size);
        if (GetLastError() != ERROR_INSUFFICIENT_BUFFER || size == 0) return false;

        tokenInfo_.resize(size);
        if (!GetTokenInformation(token_, TokenUser, tokenInfo_.data(), size, &size)) return false;

        auto* tokenUser = reinterpret_cast<TOKEN_USER*>(tokenInfo_.data());
        EXPLICIT_ACCESSW access{};
        access.grfAccessPermissions = GENERIC_READ | GENERIC_WRITE;
        access.grfAccessMode = SET_ACCESS;
        access.grfInheritance = NO_INHERITANCE;
        access.Trustee.TrusteeForm = TRUSTEE_IS_SID;
        access.Trustee.TrusteeType = TRUSTEE_IS_USER;
        access.Trustee.ptstrName = static_cast<LPWSTR>(tokenUser->User.Sid);

        if (SetEntriesInAclW(1, &access, nullptr, &acl_) != ERROR_SUCCESS) return false;
        if (!InitializeSecurityDescriptor(&descriptor_, SECURITY_DESCRIPTOR_REVISION)) return false;
        if (!SetSecurityDescriptorDacl(&descriptor_, TRUE, acl_, FALSE)) return false;

        attributes_.nLength = sizeof(attributes_);
        attributes_.lpSecurityDescriptor = &descriptor_;
        attributes_.bInheritHandle = FALSE;
        return true;
    }

    SECURITY_ATTRIBUTES* attributes() { return &attributes_; }

private:
    HANDLE token_ = nullptr;
    std::vector<std::byte> tokenInfo_;
    PACL acl_ = nullptr;
    SECURITY_DESCRIPTOR descriptor_{};
    SECURITY_ATTRIBUTES attributes_{};
};

bool IsValidPacket(const StatusPacket& packet) {
    const auto rawState = static_cast<std::uint32_t>(packet.state);
    return packet.magic == kProtocolMagic &&
           packet.version == kProtocolVersion &&
           rawState <= static_cast<std::uint32_t>(StatusCode::Exit) &&
           packet.progress >= kNoProgress && packet.progress <= 100 &&
           packet.detail[std::size(packet.detail) - 1] == L'\0';
}

void PipeServerLoop(HWND hwnd) {
    PipeSecurity security;
    if (!security.Initialize()) {
        auto packet = std::make_unique<StatusPacket>();
        packet->state = StatusCode::Error;
        wcscpy_s(packet->detail, L"Falha ao proteger o canal IPC");
        PostMessageW(hwnd, kStatusMessage, 0, reinterpret_cast<LPARAM>(packet.release()));
        return;
    }

    for (;;) {
        HANDLE pipe = CreateNamedPipeW(
            kPipeName,
            PIPE_ACCESS_INBOUND,
            PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
            1,
            0,
            sizeof(StatusPacket),
            0,
            security.attributes());

        if (pipe == INVALID_HANDLE_VALUE) {
            Sleep(500);
            continue;
        }

        const BOOL connected = ConnectNamedPipe(pipe, nullptr) ? TRUE : (GetLastError() == ERROR_PIPE_CONNECTED);
        if (!connected) {
            CloseHandle(pipe);
            continue;
        }

        StatusPacket packet{};
        DWORD bytesRead = 0;
        const BOOL readOk = ReadFile(pipe, &packet, sizeof(packet), &bytesRead, nullptr);
        DisconnectNamedPipe(pipe);
        CloseHandle(pipe);

        if (!readOk || bytesRead != sizeof(packet) || !IsValidPacket(packet)) continue;

        auto copy = std::make_unique<StatusPacket>(packet);
        if (!PostMessageW(hwnd, kStatusMessage, 0, reinterpret_cast<LPARAM>(copy.get()))) continue;
        copy.release();

        if (packet.state == StatusCode::Exit) return;
    }
}

bool SendPacket(const StatusPacket& packet) {
    if (!WaitNamedPipeW(kPipeName, 250)) {
        const DWORD error = GetLastError();
        if (error != ERROR_FILE_NOT_FOUND && error != ERROR_SEM_TIMEOUT) return false;
    }

    HANDLE pipe = CreateFileW(kPipeName, GENERIC_WRITE, 0, nullptr, OPEN_EXISTING, 0, nullptr);
    if (pipe == INVALID_HANDLE_VALUE) return false;

    DWORD written = 0;
    const BOOL ok = WriteFile(pipe, &packet, sizeof(packet), &written, nullptr);
    CloseHandle(pipe);
    return ok && written == sizeof(packet);
}

std::wstring CurrentExecutablePath() {
    std::vector<wchar_t> buffer(32768);
    const DWORD length = GetModuleFileNameW(nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
    if (length == 0 || length >= buffer.size()) return {};
    return std::wstring(buffer.data(), length);
}

bool StartServerProcess() {
    const auto executable = CurrentExecutablePath();
    if (executable.empty()) return false;

    std::wstring command = L"\"" + executable + L"\" --server";
    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    PROCESS_INFORMATION process{};

    const BOOL ok = CreateProcessW(
        executable.c_str(),
        command.data(),
        nullptr,
        nullptr,
        FALSE,
        CREATE_NEW_PROCESS_GROUP,
        nullptr,
        nullptr,
        &startup,
        &process);

    if (!ok) return false;
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    return true;
}

int SendCommand(StatusPacket packet) {
    if (SendPacket(packet)) return 0;
    if (!StartServerProcess()) return 4;

    for (int attempt = 0; attempt < 50; ++attempt) {
        if (SendPacket(packet)) return 0;
        Sleep(100);
    }
    return 6;
}

StatusPacket PacketFromArgs(int argc, wchar_t** argv, bool& ok) {
    StatusPacket packet{};
    ok = false;
    if (argc < 2 || !TryParseState(argv[1], packet.state)) return packet;

    int detailStart = 2;
    if (argc >= 3) {
        int progress = kNoProgress;
        if (TryParseProgress(argv[2], progress)) {
            packet.progress = progress;
            detailStart = 3;
        }
    }

    std::wstring detail;
    for (int i = detailStart; i < argc; ++i) {
        if (!detail.empty()) detail += L" ";
        detail += argv[i];
    }
    if (detail.size() >= std::size(packet.detail)) detail.resize(std::size(packet.detail) - 1);
    if (!detail.empty()) wcscpy_s(packet.detail, detail.c_str());

    ok = true;
    return packet;
}

int RunServer(HINSTANCE instance) {
    HANDLE mutex = CreateMutexW(nullptr, TRUE, kMutexName);
    if (!mutex) return 10;
    if (GetLastError() == ERROR_ALREADY_EXISTS) {
        CloseHandle(mutex);
        return 0;
    }

    g_taskbarCreated = RegisterWindowMessageW(L"TaskbarCreated");

    AppState app{};
    app.current.state = StatusCode::Idle;

    WNDCLASSEXW windowClass{};
    windowClass.cbSize = sizeof(windowClass);
    windowClass.lpfnWndProc = WindowProc;
    windowClass.hInstance = instance;
    windowClass.hIcon = LoadIconW(nullptr, IDI_APPLICATION);
    windowClass.hIconSm = LoadIconW(nullptr, IDI_APPLICATION);
    windowClass.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    windowClass.lpszClassName = kWindowClass;

    if (!RegisterClassExW(&windowClass) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
        CloseHandle(mutex);
        return 11;
    }

    // Janela oculta somente para receber mensagens do Shell/IPC. WS_EX_TOOLWINDOW
    // impede botão próprio na taskbar; o estado aparece exclusivamente no tray.
    HWND hwnd = CreateWindowExW(
        WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
        kWindowClass,
        L"Dev Automation Status",
        WS_POPUP,
        0,
        0,
        0,
        0,
        nullptr,
        nullptr,
        instance,
        &app);

    if (!hwnd) {
        CloseHandle(mutex);
        return 12;
    }

    ShowWindow(hwnd, SW_HIDE);
    UpdateTrayIcon(hwnd, app, true);
    std::thread(PipeServerLoop, hwnd).detach();

    MSG message{};
    while (GetMessageW(&message, nullptr, 0, 0) > 0) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }

    ReleaseMutex(mutex);
    CloseHandle(mutex);
    return 0;
}

} // namespace

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int) {
    int argc = 0;
    wchar_t** argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (!argv) return 20;

    if (argc == 1 || (argc == 2 && _wcsicmp(argv[1], L"--server") == 0)) {
        LocalFree(argv);
        return RunServer(instance);
    }

    bool ok = false;
    const StatusPacket packet = PacketFromArgs(argc, argv, ok);
    LocalFree(argv);
    if (!ok) return 2;
    return SendCommand(packet);
}
