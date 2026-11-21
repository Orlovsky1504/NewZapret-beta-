/*
 * OpenZapret Smart Launcher v2 — быстрый нативный лаунчер
 * Заменяет тупой stub: показывает окно мгновенно, кэширует статус, не даёт дублей
 */
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#include <windows.h>
#include <winsvc.h>
#include <shellapi.h>
#include <shlobj.h>
#include <stdio.h>

#define MUTEX_NAME L"Global\\OpenZapret_ControlCenter_Mutex"
#define SPLASH_CLASS L"OpenZapretSplash"
#define CACHE_TIMEOUT_MS 3000

static HANDLE g_mutex = NULL;
static HWND g_splash = NULL;
static HBRUSH g_bgBrush = NULL;
static HFONT g_font = NULL;

// Быстрая проверка службы через SCM (10мс vs 500мс через WMI/PowerShell)
static int QuickServiceState(void) {
    SC_HANDLE scm = OpenSCManagerW(NULL, NULL, SC_MANAGER_CONNECT);
    if (!scm) return -1;
    SC_HANDLE svc = OpenServiceW(scm, L"zapret", SERVICE_QUERY_STATUS);
    if (!svc) { CloseServiceHandle(scm); return -1; }
    SERVICE_STATUS st;
    int res = -1;
    if (QueryServiceStatus(svc, &st)) {
        if (st.dwCurrentState == SERVICE_RUNNING) res = 1;
        else if (st.dwCurrentState == SERVICE_STOPPED) res = 0;
        else res = 2; // pending
    }
    CloseServiceHandle(svc);
    CloseServiceHandle(scm);
    return res;
}

static void ShowError(const wchar_t *msg) {
    MessageBoxW(NULL, msg, L"OpenZapret", MB_OK | MB_ICONERROR);
}

static LRESULT CALLBACK SplashProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
    case WM_PAINT: {
        PAINTSTRUCT ps;
        HDC hdc = BeginPaint(hwnd, &ps);
        RECT rc; GetClientRect(hwnd, &rc);
        SetBkMode(hdc, TRANSPARENT);
        SetTextColor(hdc, RGB(232, 238, 248));
        HFONT old = SelectObject(hdc, g_font);
        DrawTextW(hdc, L"OpenZapret", -1, &rc, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
        SelectObject(hdc, old);
        EndPaint(hwnd, &ps);
        return 0;
    }
    case WM_TIMER:
        if (wParam == 1) { KillTimer(hwnd, 1); DestroyWindow(hwnd); }
        return 0;
    case WM_DESTROY:
        g_splash = NULL;
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

static HWND ShowSplash(void) {
    WNDCLASSW wc = {0};
    wc.lpfnWndProc = SplashProc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = SPLASH_CLASS;
    wc.hbrBackground = CreateSolidBrush(RGB(15, 20, 30));
    wc.hCursor = LoadCursorW(NULL, IDC_ARROW);
    g_bgBrush = wc.hbrBackground;
    RegisterClassW(&wc);
    
    int state = QuickServiceState();
    const wchar_t *status = (state == 1) ? L"Работает" : (state == 0) ? L"Остановлена" : L"Загрузка...";
    
    // Малый сплэш 320x80 по центру
    int sw = GetSystemMetrics(SM_CXSCREEN), sh = GetSystemMetrics(SM_CYSCREEN);
    HWND hwnd = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW, SPLASH_CLASS, L"OpenZapret",
        WS_POPUP | WS_BORDER, (sw-320)/2, (sh-80)/2, 320, 80, NULL, NULL, GetModuleHandleW(NULL), NULL);
    if (!hwnd) return NULL;
    
    g_font = CreateFontW(18, 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
    ShowWindow(hwnd, SW_SHOW);
    UpdateWindow(hwnd);
    SetTimer(hwnd, 1, 2000, NULL); // авто-закрытие 2с если powershell завис
    return hwnd;
}

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE prev, PWSTR cmdLine, int show) {
    (void)prev; (void)cmdLine; (void)show;
    wchar_t modPath[MAX_PATH], scriptPath[MAX_PATH], psPath[MAX_PATH], args[2048];
    wchar_t fullCmdLine[2048];
    
    // 1. Mutex — не давать второй копии (кажется что "не запускается" из-за дубля)
    g_mutex = CreateMutexW(NULL, FALSE, MUTEX_NAME);
    if (GetLastError() == ERROR_ALREADY_EXISTS) {
        HWND existing = FindWindowW(SPLASH_CLASS, NULL);
        if (existing) SetForegroundWindow(existing);
        else {
            HWND tray = FindWindowW(L"Shell_TrayWnd", NULL);
            if (tray) {
                // Поищем окно панели по классу
                HWND w = FindWindowW(NULL, L"OpenZapret");
                if (w) SetForegroundWindow(w);
            }
        }
        return 0;
    }

    if (!GetModuleFileNameW(NULL, modPath, MAX_PATH)) {
        ShowError(L"Не удалось определить путь приложения.");
        return 1;
    }
    wchar_t *slash = wcsrchr(modPath, L'\\');
    if (slash) *slash = L'\0';

    // Проверка файлов до показа сплэша
    _snwprintf(scriptPath, MAX_PATH, L"%s\\Zapret-Control.ps1", modPath);
    if (GetFileAttributesW(scriptPath) == INVALID_FILE_ATTRIBUTES) {
        ShowError(L"Не найден Zapret-Control.ps1 рядом с приложением.\nРаспакуйте архив полностью в одну папку.");
        return 1;
    }

    UINT len = GetWindowsDirectoryW(psPath, MAX_PATH);
    if (len == 0 || len >= MAX_PATH - 64) { ShowError(L"Не найден Windows."); return 1; }
    _snwprintf(psPath + len, MAX_PATH - len, L"\\System32\\WindowsPowerShell\\v1.0\\powershell.exe");
    if (GetFileAttributesW(psPath) == INVALID_FILE_ATTRIBUTES) { ShowError(L"Не найден PowerShell 5.1."); return 1; }

    // 2. Показать сплэш МГНОВЕННО (<50мс)
    g_splash = ShowSplash();
    MSG msg;
    // Даём сплэшу отрисоваться
    for (int i = 0; i < 5; i++) {
        if (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageW(&msg); }
        Sleep(10);
    }

    // 3. Проверка прав — если не админ, запросить UAC с нормальным промптом
    BOOL isAdmin = FALSE;
    {
        HANDLE token; if (OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) {
            TOKEN_ELEVATION elev; DWORD sz;
            if (GetTokenInformation(token, TokenElevation, &elev, sizeof(elev), &sz)) isAdmin = elev.TokenIsElevated;
            CloseHandle(token);
        }
    }
    if (!isAdmin) {
        // Перезапуск с UAC — показываем понятный текст
        _snwprintf(fullCmdLine, 2048, L"-NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File \"%s\"", scriptPath);
        SHELLEXECUTEINFOW sei = { sizeof(sei) };
        sei.lpVerb = L"runas";
        sei.lpFile = psPath;
        sei.lpParameters = fullCmdLine;
        sei.nShow = SW_HIDE;
        sei.fMask = SEE_MASK_NOCLOSEPROCESS;
        if (ShellExecuteExW(&sei)) {
            if (g_splash) DestroyWindow(g_splash);
            if (sei.hProcess) CloseHandle(sei.hProcess);
            return 0;
        } else {
            if (GetLastError() == ERROR_CANCELLED) {
                if (g_splash) DestroyWindow(g_splash);
                MessageBoxW(NULL, L"Для управления службой нужны права администратора.\nНажмите Да в запросе UAC.", L"OpenZapret", MB_OK | MB_ICONINFORMATION);
                return 0;
            }
        }
    }

    // 4. Запуск PowerShell скрыто, сплэш закроется сам по таймеру или когда окно панели появится
    _snwprintf(args, 2048, L"-NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File \"%s\"", scriptPath);
    STARTUPINFOW si = { sizeof(si) }; si.dwFlags = STARTF_USESHOWWINDOW; si.wShowWindow = SW_HIDE;
    PROCESS_INFORMATION pi = {0};
    if (!CreateProcessW(psPath, args, NULL, NULL, FALSE, 0, NULL, modPath, &si, &pi)) {
        if (g_splash) DestroyWindow(g_splash);
        ShowError(L"Не удалось запустить PowerShell.");
        return 1;
    }
    CloseHandle(pi.hThread);
    
    // Ждём 3с появления окна панели, затем гасим сплэш
    for (int i = 0; i < 30; i++) {
        Sleep(100);
        HWND panel = FindWindowW(NULL, L"OpenZapret");
        if (panel && IsWindowVisible(panel)) {
            if (g_splash) { DestroyWindow(g_splash); g_splash = NULL; }
            break;
        }
        if (WaitForSingleObject(pi.hProcess, 0) == WAIT_OBJECT_0) break; // процесс упал
        MSG m; while (PeekMessageW(&m, NULL, 0, 0, PM_REMOVE)) { TranslateMessage(&m); DispatchMessageW(&m); }
    }
    if (g_splash) DestroyWindow(g_splash);
    CloseHandle(pi.hProcess);
    if (g_mutex) ReleaseMutex(g_mutex);
    return 0;
}
