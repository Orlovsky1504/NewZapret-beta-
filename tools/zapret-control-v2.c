#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#include <windows.h>
#include <shellapi.h>
#include <stdio.h>
#include <wchar.h>

int WINAPI wWinMain(HINSTANCE h, HINSTANCE p, PWSTR c, int s){
    (void)h;(void)p;(void)c;(void)s;
    wchar_t exe[MAX_PATH], dir[MAX_PATH], ps1[MAX_PATH], win[MAX_PATH], ps[MAX_PATH], args[4096];
    if(!GetModuleFileNameW(NULL, exe, MAX_PATH)){ MessageBoxW(NULL, L"Не удалось определить путь.", L"OpenZapret", MB_OK|MB_ICONERROR); return 1; }
    wchar_t *q=wcsrchr(exe, L'\\'); if(q) *q=0;
    wcsncpy(dir, exe, MAX_PATH);
    _snwprintf(ps1, MAX_PATH, L"%s\\Zapret-Control.ps1", dir);
    if(GetFileAttributesW(ps1)==INVALID_FILE_ATTRIBUTES){ MessageBoxW(NULL, L"Не найден Zapret-Control.ps1 рядом с приложением.\nРаспакуйте архив полностью.", L"OpenZapret", MB_OK|MB_ICONERROR); return 1; }
    UINT n=GetWindowsDirectoryW(win, MAX_PATH); if(!n){ MessageBoxW(NULL, L"Не найден Windows.", L"OpenZapret", MB_OK|MB_ICONERROR); return 1; }
    _snwprintf(ps, MAX_PATH, L"%s\\System32\\WindowsPowerShell\\v1.0\\powershell.exe", win);
    if(GetFileAttributesW(ps)==INVALID_FILE_ATTRIBUTES){ MessageBoxW(NULL, L"Не найден PowerShell 5.1.", L"OpenZapret", MB_OK|MB_ICONERROR); return 1; }
    _snwprintf(args, 4096, L"-NoLogo -NoProfile -ExecutionPolicy Bypass -File \"%s\"", ps1);
    SHELLEXECUTEINFOW sei={0};
    sei.cbSize=sizeof(sei);
    sei.lpVerb=L"runas";
    sei.lpFile=ps;
    sei.lpParameters=args;
    sei.nShow=SW_SHOWNORMAL;
    if(!ShellExecuteExW(&sei)){
        DWORD e=GetLastError();
        if(e==ERROR_CANCELLED) return 0;
        sei.lpVerb=NULL;
        sei.lpFile=ps;
        sei.lpParameters=args;
        if(!ShellExecuteExW(&sei)){
            wchar_t m[512];
            _snwprintf(m,512,L"Не удалось запустить панель (%lu).", GetLastError());
            MessageBoxW(NULL,m,L"OpenZapret",MB_OK|MB_ICONERROR);
            return 1;
        }
    }
    return 0;
}
