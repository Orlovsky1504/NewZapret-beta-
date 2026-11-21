/* zapret-tray.c - tray companion for zapret-discord-youtube (C, WinAPI).
 *
 * Quick access plus a live health indicator:
 *   - status disc  : green = bypass works, yellow = degraded, red = broken,
 *                    gray = checking/no data (rechecked every 5 minutes)
 *   - "Проверить обход"  -> zapret.ps1 health-check  (read-only, console)
 *   - "Обновить индикатор" -> hidden health-check, updates the disc
 *   - "Автоподбор"        -> zapret.ps1 auto-select   (full benchmark)
 *   - "Открыть панель"    -> Zapret-Control.exe
 *
 * health-check exit codes: 0 = healthy, 1 = degraded, 2 = broken.
 *
 * Build (from tools/):
 *   x86_64-w64-mingw32-windres zapret-tray.rc -O coff -o zapret-tray-res.o
 *   x86_64-w64-mingw32-gcc -mwindows -municode -s -O2 -o ../Zapret-Tray.exe tray/zapret-tray.c zapret-tray-res.o
 *   rm -f zapret-tray-res.o
 */
#include <windows.h>
#include <shellapi.h>
#include <stdio.h>

#define WM_TRAY      (WM_APP + 1)
#define WM_STATUS    (WM_APP + 2)
#define IDM_CHECK    101
#define IDM_BENCH    102
#define IDM_PANEL    103
#define IDM_EXIT     104
#define IDM_REFRESH  105
#define IDT_CHECK    1

static NOTIFYICONDATAW g_nid;
static HINSTANCE       g_inst;
static WCHAR           g_root[MAX_PATH];
static HWND            g_hwnd;
static HICON           g_icons[4];        /* 0 gray, 1 green, 2 yellow, 3 red */
static volatile LONG   g_checking = 0;
static int             g_lastStatus = -2; /* -2: never checked yet */

static void RunInConsole(const wchar_t *verb)
{
    wchar_t ps[MAX_PATH];
    wchar_t cmd[1600];
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;

    GetSystemDirectoryW(ps, MAX_PATH);
    wcsncat(ps, L"\\WindowsPowerShell\\v1.0\\powershell.exe", MAX_PATH - wcslen(ps) - 1);
    swprintf(cmd, 1600,
        L"cmd.exe /k \"\"%s\" -NoProfile -ExecutionPolicy Bypass -File \"%s\\zapret.ps1\" %s\"",
        ps, g_root, verb);
    ZeroMemory(&si, sizeof si);
    si.cb = sizeof si;
    ZeroMemory(&pi, sizeof pi);
    if (CreateProcessW(NULL, cmd, NULL, NULL, FALSE, CREATE_NEW_CONSOLE, NULL, g_root, &si, &pi)) {
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
    } else {
        MessageBoxW(NULL, L"Не удалось запустить zapret.ps1.", L"Zapret Tray", MB_ICONERROR);
    }
}

static void RunPanel(void)
{
    wchar_t exe[MAX_PATH];
    swprintf(exe, MAX_PATH, L"%s\\Zapret-Control.exe", g_root);
    ShellExecuteW(NULL, L"open", exe, NULL, g_root, SW_SHOWNORMAL);
}

/* Colored status disc. Pixel format is a plain 32bpp DIB: DWORD 0xAARRGGBB. */
static HICON MakeStatusIcon(DWORD argb)
{
    const int size = 16;
    BITMAPV5HEADER bi;
    HDC screen;
    void *bits = NULL;
    HBITMAP color, mask;
    DWORD *px;
    int x, y;
    ICONINFO ii;
    HICON icon;
    unsigned char maskBits[64];   /* 16x16 1bpp, DWORD-aligned rows: 16 * 4 */

    ZeroMemory(&bi, sizeof bi);
    bi.bV5Size        = sizeof bi;
    bi.bV5Width       = size;
    bi.bV5Height      = -size;          /* top-down */
    bi.bV5Planes      = 1;
    bi.bV5BitCount    = 32;
    bi.bV5Compression = BI_RGB;
    screen = GetDC(NULL);
    color = CreateDIBSection(screen, (BITMAPINFO *)&bi, DIB_RGB_COLORS, &bits, NULL, 0);
    ReleaseDC(NULL, screen);
    if (!color || !bits) { return NULL; }
    px = (DWORD *)bits;
    for (y = 0; y < size; y++) {
        for (x = 0; x < size; x++) {
            double dx = x - 7.5, dy = y - 7.5;
            if (dx * dx + dy * dy <= 56.0) {
                px[y * size + x] = argb;
            } else {
                px[y * size + x] = 0;
            }
        }
    }
    ZeroMemory(maskBits, sizeof maskBits);
    mask = CreateBitmap(size, size, 1, 1, maskBits);   /* zeroed AND mask: use alpha */
    ZeroMemory(&ii, sizeof ii);
    ii.fIcon    = TRUE;
    ii.hbmColor = color;
    ii.hbmMask  = mask;
    icon = CreateIconIndirect(&ii);
    DeleteObject(color);
    DeleteObject(mask);
    return icon;
}

static void ApplyStatus(int code)   /* 0 green, 1 yellow, 2 red, -1 gray */
{
    int idx;
    const wchar_t *tip;

    switch (code) {
    case 0:  idx = 1; tip = L"zapret — обход работает";        break;
    case 1:  idx = 2; tip = L"zapret — обход работает частично"; break;
    case 2:  idx = 3; tip = L"zapret — обход НЕ работает";      break;
    default: idx = 0; tip = L"zapret — статус неизвестен";      break;
    }
    g_nid.hIcon = g_icons[idx] ? g_icons[idx] : LoadIconW(NULL, IDI_APPLICATION);
    wcsncpy(g_nid.szTip, tip, (sizeof g_nid.szTip / sizeof g_nid.szTip[0]) - 1);
    g_nid.uFlags = NIF_ICON | NIF_TIP | NIF_MESSAGE;
    Shell_NotifyIconW(NIM_MODIFY, &g_nid);

    /* balloon only on real transitions: into broken, or recovery after broken */
    if (code >= 0 && g_lastStatus >= 0 && code != g_lastStatus) {
        if (code == 2) {
            g_nid.uFlags = NIF_INFO;
            wcscpy(g_nid.szInfoTitle, L"zapret");
            wcscpy(g_nid.szInfo, L"Обход перестал работать. Нажмите «Проверить обход» в трее.");
            g_nid.dwInfoFlags = NIIF_WARNING;
            Shell_NotifyIconW(NIM_MODIFY, &g_nid);
        } else if (code == 0 && g_lastStatus == 2) {
            g_nid.uFlags = NIF_INFO;
            wcscpy(g_nid.szInfoTitle, L"zapret");
            wcscpy(g_nid.szInfo, L"Обход снова работает.");
            g_nid.dwInfoFlags = NIIF_INFO;
            Shell_NotifyIconW(NIM_MODIFY, &g_nid);
        }
    }
    if (code >= 0) { g_lastStatus = code; }
}

static DWORD WINAPI CheckThreadProc(LPVOID param)
{
    wchar_t ps[MAX_PATH];
    wchar_t cmd[1600];
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    DWORD code = (DWORD)-1;

    (void)param;
    GetSystemDirectoryW(ps, MAX_PATH);
    wcsncat(ps, L"\\WindowsPowerShell\\v1.0\\powershell.exe", MAX_PATH - wcslen(ps) - 1);
    swprintf(cmd, 1600,
        L"\"%s\" -NoProfile -ExecutionPolicy Bypass -File \"%s\\zapret.ps1\" health-check",
        ps, g_root);
    ZeroMemory(&si, sizeof si);
    si.cb = sizeof si;
    si.dwFlags = STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;
    ZeroMemory(&pi, sizeof pi);
    if (CreateProcessW(NULL, cmd, NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL, g_root, &si, &pi)) {
        WaitForSingleObject(pi.hProcess, 120000);
        if (!GetExitCodeProcess(pi.hProcess, &code)) { code = (DWORD)-1; }
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
    }
    PostMessageW(g_hwnd, WM_STATUS, (WPARAM)(int)code, 0);
    InterlockedExchange(&g_checking, 0);
    return 0;
}

/* One-shot watchdog notice written by zapret.ps1 (.service\watchdog-notice.txt):
 * shown as a balloon exactly once, then deleted. */
static void CheckNotice(void)
{
    wchar_t path[MAX_PATH];
    HANDLE h;
    char buf[1024];
    DWORD read = 0;
    wchar_t wbuf[512];

    swprintf(path, MAX_PATH, L"%s\\.service\\watchdog-notice.txt", g_root);
    if (GetFileAttributesW(path) == INVALID_FILE_ATTRIBUTES) { return; }
    h = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
    if (h == INVALID_HANDLE_VALUE) { return; }
    ReadFile(h, buf, (DWORD)(sizeof buf - 1), &read, NULL);
    CloseHandle(h);
    buf[read] = 0;
    if (!MultiByteToWideChar(CP_UTF8, 0, buf, -1, wbuf, (int)(sizeof wbuf / sizeof wbuf[0]))) { return; }
    wbuf[(sizeof wbuf / sizeof wbuf[0]) - 1] = 0;
    g_nid.uFlags = NIF_INFO;
    wcscpy(g_nid.szInfoTitle, L"zapret — автозащита");
    wcsncpy(g_nid.szInfo, wbuf, (sizeof g_nid.szInfo / sizeof g_nid.szInfo[0]) - 1);
    g_nid.szInfo[(sizeof g_nid.szInfo / sizeof g_nid.szInfo[0]) - 1] = 0;
    g_nid.dwInfoFlags = NIIF_INFO;
    Shell_NotifyIconW(NIM_MODIFY, &g_nid);
    DeleteFileW(path);
}

static void StartCheck(void)
{
    if (InterlockedCompareExchange(&g_checking, 1, 0) != 0) { return; }
    CheckNotice();
    ApplyStatus(-1);
    if (!CreateThread(NULL, 0, CheckThreadProc, NULL, 0, NULL)) {
        InterlockedExchange(&g_checking, 0);
    }
}

static void ShowMenu(HWND hwnd)
{
    POINT pt;
    HMENU menu;

    GetCursorPos(&pt);
    menu = CreatePopupMenu();
    AppendMenuW(menu, MF_STRING, IDM_CHECK,   L"Проверить обход (в консоли)");
    AppendMenuW(menu, MF_STRING, IDM_REFRESH, L"Обновить индикатор");
    AppendMenuW(menu, MF_STRING, IDM_BENCH,   L"Автоподбор стратегий (несколько минут)");
    AppendMenuW(menu, MF_SEPARATOR, 0, NULL);
    AppendMenuW(menu, MF_STRING, IDM_PANEL,   L"Открыть панель");
    AppendMenuW(menu, MF_STRING, IDM_EXIT,    L"Выход");
    SetMenuDefaultItem(menu, IDM_PANEL, FALSE);
    SetForegroundWindow(hwnd);
    TrackPopupMenu(menu, TPM_RIGHTBUTTON, pt.x, pt.y, 0, hwnd, NULL);
    DestroyMenu(menu);
}

static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam)
{
    switch (msg) {
    case WM_TRAY:
        if (LOWORD(lParam) == WM_RBUTTONUP) { ShowMenu(hwnd); return 0; }
        if (LOWORD(lParam) == WM_LBUTTONDBLCLK) { RunPanel(); return 0; }
        return 0;
    case WM_STATUS:
        ApplyStatus((int)(LONG)wParam);
        return 0;
    case WM_TIMER:
        if (wParam == IDT_CHECK) { StartCheck(); }
        return 0;
    case WM_COMMAND:
        switch (LOWORD(wParam)) {
        case IDM_CHECK:   RunInConsole(L"health-check"); return 0;
        case IDM_REFRESH: StartCheck();                  return 0;
        case IDM_BENCH:   RunInConsole(L"auto-select");  return 0;
        case IDM_PANEL:   RunPanel();                    return 0;
        case IDM_EXIT:    DestroyWindow(hwnd);           return 0;
        }
        return 0;
    case WM_DESTROY:
        Shell_NotifyIconW(NIM_DELETE, &g_nid);
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

int WINAPI wWinMain(HINSTANCE hInstance, HINSTANCE hPrevInstance, PWSTR pCmdLine, int nCmdShow)
{
    WNDCLASSW wc;
    MSG msg;
    HANDLE mutex;
    wchar_t *slash;

    (void)hPrevInstance; (void)pCmdLine; (void)nCmdShow;

    mutex = CreateMutexW(NULL, TRUE, L"ZapretTrayMutex");
    if (mutex && GetLastError() == ERROR_ALREADY_EXISTS) { return 0; }

    g_inst = hInstance;
    GetModuleFileNameW(NULL, g_root, MAX_PATH);
    slash = wcsrchr(g_root, L'\\');
    if (slash) { *slash = 0; }

    /* app palette as 0xAARRGGBB: gray #75849C, green #51D6A5, yellow #F5B95F, red #F28B82 */
    g_icons[0] = MakeStatusIcon(0xFF75849C);
    g_icons[1] = MakeStatusIcon(0xFF51D6A5);
    g_icons[2] = MakeStatusIcon(0xFFF5B95F);
    g_icons[3] = MakeStatusIcon(0xFFF28B82);

    ZeroMemory(&wc, sizeof wc);
    wc.lpfnWndProc   = WndProc;
    wc.hInstance     = hInstance;
    wc.lpszClassName = L"ZapretTrayWindow";
    wc.hIcon         = LoadIconW(hInstance, L"IDI_APPICON");
    RegisterClassW(&wc);

    g_hwnd = CreateWindowW(L"ZapretTrayWindow", L"Zapret Tray", 0, 0, 0, 0, 0,
                           HWND_MESSAGE, NULL, hInstance, NULL);

    ZeroMemory(&g_nid, sizeof g_nid);
    g_nid.cbSize           = sizeof g_nid;
    g_nid.hWnd             = g_hwnd;
    g_nid.uID              = 1;
    g_nid.uFlags           = NIF_MESSAGE | NIF_ICON | NIF_TIP;
    g_nid.uCallbackMessage = WM_TRAY;
    g_nid.hIcon            = g_icons[0] ? g_icons[0] : (wc.hIcon ? wc.hIcon : LoadIconW(NULL, IDI_APPLICATION));
    wcscpy(g_nid.szTip, L"zapret — проверка обхода…");
    Shell_NotifyIconW(NIM_ADD, &g_nid);

    SetTimer(g_hwnd, IDT_CHECK, 5 * 60 * 1000, NULL); /* recheck every 5 minutes */
    StartCheck();                                     /* first check right away  */

    while (GetMessageW(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    return 0;
}
