/* OpenZapret Smart Launcher v3 — диагностический, с логом */
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#include <windows.h>
#include <winsvc.h>
#include <shellapi.h>
#include <stdio.h>

#define MUTEX_NAME L"Global\\OpenZapret_ControlCenter_Mutex"
#define SPLASH_CLASS L"OpenZapretSplash"

static HANDLE g_mutex = NULL;
static HWND g_splash = NULL;
static HBRUSH g_bgBrush = NULL;
static HFONT g_font = NULL;
static wchar_t g_logPath[MAX_PATH] = {0};

static void Log(const wchar_t *fmt, ...) {
    if (!g_logPath[0]) {
        wchar_t tmp[MAX_PATH];
        GetTempPathW(MAX_PATH, tmp);
        _snwprintf(g_logPath, MAX_PATH, L"%sOpenZapret-Launcher.log", tmp);
    }
    FILE *f = _wfopen(g_logPath, L"a, ccs=UTF-8");
    if (!f) return;
    SYSTEMTIME st; GetLocalTime(&st);
    fwprintf(f, L"[%02d:%02d:%02d.%03d] ", st.wHour, st.wMinute, st.wSecond, st.wMilliseconds);
    va_list ap; va_start(ap, fmt);
    vfwprintf(f, fmt, ap);
    va_end(ap);
    fwprintf(f, L"\n");
    fclose(f);
}

static int QuickServiceState(void) {
    SC_HANDLE scm = OpenSCManagerW(NULL, NULL, SC_MANAGER_CONNECT);
    if (!scm) return -1;
    SC_HANDLE svc = OpenServiceW(scm, L"zapret", SERVICE_QUERY_STATUS);
    if (!svc) { CloseServiceHandle(scm); return -1; }
    SERVICE_STATUS st; int res=-1;
    if (QueryServiceStatus(svc, &st)) {
        if (st.dwCurrentState==SERVICE_RUNNING) res=1;
        else if (st.dwCurrentState==SERVICE_STOPPED) res=0;
        else res=2;
    }
    CloseServiceHandle(svc); CloseServiceHandle(scm);
    return res;
}

static void ShowError(const wchar_t *msg) {
    Log(L"ERROR: %s", msg);
    MessageBoxW(NULL, msg, L"OpenZapret", MB_OK|MB_ICONERROR);
}

static LRESULT CALLBACK SplashProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    switch(msg){
    case WM_PAINT: {
        PAINTSTRUCT ps; HDC hdc=BeginPaint(hwnd,&ps);
        RECT rc; GetClientRect(hwnd,&rc);
        SetBkMode(hdc, TRANSPARENT);
        SetTextColor(hdc, RGB(232,238,248));
        HFONT old=SelectObject(hdc,g_font);
        DrawTextW(hdc,L"OpenZapret",-1,&rc,DT_CENTER|DT_VCENTER|DT_SINGLELINE);
        SelectObject(hdc,old); EndPaint(hwnd,&ps); return 0;
    }
    case WM_TIMER:
        if(wParam==1){ KillTimer(hwnd,1); DestroyWindow(hwnd); } return 0;
    case WM_DESTROY: g_splash=NULL; return 0;
    }
    return DefWindowProcW(hwnd,msg,wParam,lParam);
}

static HWND ShowSplash(void){
    WNDCLASSW wc={0};
    wc.lpfnWndProc=SplashProc; wc.hInstance=GetModuleHandleW(NULL);
    wc.lpszClassName=SPLASH_CLASS;
    wc.hbrBackground=CreateSolidBrush(RGB(15,20,30));
    wc.hCursor=LoadCursorW(NULL,IDC_ARROW);
    g_bgBrush=wc.hbrBackground; RegisterClassW(&wc);
    int sw=GetSystemMetrics(SM_CXSCREEN), sh=GetSystemMetrics(SM_CYSCREEN);
    HWND hwnd=CreateWindowExW(WS_EX_TOPMOST|WS_EX_TOOLWINDOW, SPLASH_CLASS, L"OpenZapret",
        WS_POPUP|WS_BORDER,(sw-320)/2,(sh-80)/2,320,80,NULL,NULL,GetModuleHandleW(NULL),NULL);
    if(!hwnd) return NULL;
    g_font=CreateFontW(18,0,0,0,FW_SEMIBOLD,FALSE,FALSE,FALSE,DEFAULT_CHARSET,OUT_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,CLEARTYPE_QUALITY,DEFAULT_PITCH,L"Segoe UI");
    ShowWindow(hwnd,SW_SHOW); UpdateWindow(hwnd);
    SetTimer(hwnd,1,5000,NULL); // 5с авто-закрытие
    return hwnd;
}

// единый цикл ожидания панели
static void WaitForPanel(HANDLE hProc, const wchar_t *where){
    Log(L"WaitForPanel %ls hProc=%p", where, hProc);
    for(int i=0;i<100;i++){ // 10с
        Sleep(100);
        HWND panel=FindWindowW(NULL, L"OpenZapret");
        if(panel && panel!=g_splash && IsWindowVisible(panel)){
            Log(L"Panel found after %d*100ms handle=%p", i, panel);
            if(g_splash){ DestroyWindow(g_splash); g_splash=NULL; }
            // дать панели выйти на передний план
            SetForegroundWindow(panel);
            return;
        }
        if(hProc && WaitForSingleObject(hProc,0)==WAIT_OBJECT_0){
            DWORD code=0; GetExitCodeProcess(hProc,&code);
            Log(L"Process exited early code=%lu after %d*100ms", code, i);
            if(g_splash){ DestroyWindow(g_splash); g_splash=NULL; }
            wchar_t msg[1024];
            // проверим лог powershell если есть
            _snwprintf(msg,1024,
                L"Панель не запустилась (код %lu).\n\n"
                L"Попробуйте вручную:\n"
                L"1) Запустите PowerShell от администратора\n"
                L"2) cd \"%s\"\n"
                L"3) powershell -NoProfile -ExecutionPolicy Bypass -File .\\Zapret-Control.ps1\n\n"
                L"Лог лаунчера: %s",
                code, L"[папка zapret]", g_logPath);
            // покажем только если код !=0
            if(code!=0) ShowError(msg);
            return;
        }
        MSG m; while(PeekMessageW(&m,NULL,0,0,PM_REMOVE)){ TranslateMessage(&m); DispatchMessageW(&m); if(m.message==WM_QUIT) return; }
    }
    Log(L"Timeout 10s no panel");
    if(g_splash){ DestroyWindow(g_splash); g_splash=NULL; }
}

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE prev, PWSTR cmdLine, int show){
    (void)prev;(void)cmdLine;(void)show;
    wchar_t modPath[MAX_PATH], scriptPath[MAX_PATH], psPath[MAX_PATH], args[2048], fullCmdLine[2048];
    // лог инициализация
    {
        wchar_t tmp[MAX_PATH]; GetTempPathW(MAX_PATH, tmp);
        _snwprintf(g_logPath, MAX_PATH, L"%sOpenZapret-Launcher.log", tmp);
        // перезапишем лог каждый запуск? дописываем с разделителем
        FILE *f=_wfopen(g_logPath,L"a, ccs=UTF-8"); if(f){ fwprintf(f,L"\n=== Launch %lu ===\n", GetTickCount()); fclose(f); }
    }
    Log(L"Launcher v3 start cmdLine=%ls", cmdLine?cmdLine:L"");
    g_mutex=CreateMutexW(NULL,FALSE,MUTEX_NAME);
    if(GetLastError()==ERROR_ALREADY_EXISTS){
        Log(L"Mutex exists - second instance");
        HWND existing=FindWindowW(SPLASH_CLASS,NULL);
        if(existing){ SetForegroundWindow(existing); Log(L"Focus splash"); return 0; }
        HWND w=FindWindowW(NULL,L"OpenZapret");
        if(w){ SetForegroundWindow(w); Log(L"Focus panel %p",w); return 0; }
        ShowError(L"Панель уже запущена (проверьте трей и Alt+Tab).");
        return 0;
    }
    if(!GetModuleFileNameW(NULL,modPath,MAX_PATH)){ ShowError(L"Не удалось определить путь приложения."); return 1; }
    wchar_t *slash=wcsrchr(modPath,L'\\'); if(slash) *slash=L'\0';
    Log(L"modPath=%ls", modPath);
    _snwprintf(scriptPath,MAX_PATH,L"%s\\Zapret-Control.ps1",modPath);
    Log(L"scriptPath=%ls", scriptPath);
    if(GetFileAttributesW(scriptPath)==INVALID_FILE_ATTRIBUTES){
        ShowError(L"Не найден Zapret-Control.ps1 рядом с приложением.\nРаспакуйте архив полностью в одну папку.");
        return 1;
    }
    UINT len=GetWindowsDirectoryW(psPath,MAX_PATH);
    if(len==0||len>=MAX_PATH-64){ ShowError(L"Не найден Windows."); return 1; }
    _snwprintf(psPath+len,MAX_PATH-len,L"\\System32\\WindowsPowerShell\\v1.0\\powershell.exe");
    Log(L"psPath=%ls", psPath);
    if(GetFileAttributesW(psPath)==INVALID_FILE_ATTRIBUTES){ ShowError(L"Не найден PowerShell 5.1."); return 1; }

    g_splash=ShowSplash();
    Log(L"splash shown %p", g_splash);
    MSG msg; for(int i=0;i<5;i++){ if(PeekMessageW(&msg,NULL,0,0,PM_REMOVE)){TranslateMessage(&msg);DispatchMessageW(&msg);} Sleep(10); }

    BOOL isAdmin=FALSE;
    { HANDLE token; if(OpenProcessToken(GetCurrentProcess(),TOKEN_QUERY,&token)){
        TOKEN_ELEVATION elev; DWORD sz;
        if(GetTokenInformation(token,TokenElevation,&elev,sizeof(elev),&sz)) isAdmin=elev.TokenIsElevated;
        CloseHandle(token);
    }}
    Log(L"isAdmin=%d", isAdmin);

    if(!isAdmin){
        Log(L"Requesting UAC via ShellExecuteEx");
        _snwprintf(fullCmdLine,2048,L"-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File \"%s\"",scriptPath);
        SHELLEXECUTEINFOW sei={sizeof(sei)};
        sei.lpVerb=L"runas"; sei.lpFile=psPath; sei.lpParameters=fullCmdLine;
        sei.nShow=SW_HIDE; sei.fMask=SEE_MASK_NOCLOSEPROCESS;
        if(ShellExecuteExW(&sei)){
            Log(L"ShellExecuteEx OK hProcess=%p", sei.hProcess);
            // ждём панель 10с, как и в админ-ветке
            WaitForPanel(sei.hProcess, L"elevated");
            if(sei.hProcess) CloseHandle(sei.hProcess);
            if(g_mutex) ReleaseMutex(g_mutex);
            return 0;
        } else {
            DWORD err=GetLastError();
            Log(L"ShellExecuteEx FAIL err=%lu", err);
            if(g_splash){ DestroyWindow(g_splash); g_splash=NULL; }
            if(err==ERROR_CANCELLED){
                MessageBoxW(NULL,L"Для управления службой нужны права администратора.\nНажмите Да в запросе UAC.",L"OpenZapret",MB_OK|MB_ICONINFORMATION);
                return 0;
            } else {
                wchar_t buf[512]; _snwprintf(buf,512,L"Не удалось запросить права администратора (ошибка %lu).", err);
                ShowError(buf); return 1;
            }
        }
    }

    // уже админ — CreateProcess
    Log(L"CreateProcess direct");
    _snwprintf(args,2048,L"\"%s\" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File \"%s\"",psPath,scriptPath);
    Log(L"args=%ls", args);
    STARTUPINFOW si={sizeof(si)}; si.dwFlags=STARTF_USESHOWWINDOW; si.wShowWindow=SW_HIDE;
    PROCESS_INFORMATION pi={0};
    if(!CreateProcessW(NULL, args, NULL,NULL,FALSE,0,NULL,modPath,&si,&pi)){
        DWORD err=GetLastError();
        Log(L"CreateProcess FAIL err=%lu", err);
        if(g_splash) DestroyWindow(g_splash);
        wchar_t buf[512]; _snwprintf(buf,512,L"Не удалось запустить PowerShell (ошибка %lu).\nЛог: %ls", err, g_logPath);
        ShowError(buf); return 1;
    }
    Log(L"CreateProcess OK pid=%lu hProcess=%p", pi.dwProcessId, pi.hProcess);
    CloseHandle(pi.hThread);
    WaitForPanel(pi.hProcess, L"direct");
    CloseHandle(pi.hProcess);
    if(g_mutex) ReleaseMutex(g_mutex);
    Log(L"exit");
    return 0;
}
