/*
 * OpenZapret launcher.
 *
 * A tiny native Windows executable so the panel looks and behaves like a real
 * application: double-click Zapret-Control.exe (icon + "Application" file type,
 * no console window ever). It locates Windows PowerShell 5.1 and starts
 * Zapret-Control.ps1 from the same folder, hidden. The script itself handles
 * the administrator elevation request. Nothing else is bundled or changed.
 */
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#include <windows.h>
#include <stdio.h>

static void ShowError(const wchar_t *message)
{
    MessageBoxW(NULL, message, L"OpenZapret", MB_OK | MB_ICONERROR);
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE prevInstance, PWSTR commandLine, int showMode)
{
    wchar_t modulePath[MAX_PATH];
    wchar_t scriptPath[MAX_PATH];
    wchar_t psPath[MAX_PATH];
    wchar_t args[2 * MAX_PATH];
    wchar_t errorText[256];
    wchar_t *slash;
    STARTUPINFOW startupInfo;
    PROCESS_INFORMATION processInfo;
    UINT len;

    (void)instance;
    (void)prevInstance;
    (void)commandLine;
    (void)showMode;

    if (!GetModuleFileNameW(NULL, modulePath, MAX_PATH)) {
        ShowError(L"Не удалось определить путь приложения.");
        return 1;
    }
    slash = wcsrchr(modulePath, L'\\');
    if (slash) {
        *slash = L'\0';
    }

    _snwprintf(scriptPath, MAX_PATH, L"%s\\Zapret-Control.ps1", modulePath);
    scriptPath[MAX_PATH - 1] = L'\0';
    if (GetFileAttributesW(scriptPath) == INVALID_FILE_ATTRIBUTES) {
        ShowError(L"Не найден Zapret-Control.ps1 рядом с приложением.\nРаспакуйте архив полностью в одну папку.");
        return 1;
    }

    len = GetWindowsDirectoryW(psPath, MAX_PATH);
    if (len == 0 || len >= MAX_PATH - 64) {
        ShowError(L"Не удалось определить каталог Windows.");
        return 1;
    }
    _snwprintf(psPath + len, MAX_PATH - len,
               L"\\System32\\WindowsPowerShell\\v1.0\\powershell.exe");
    psPath[MAX_PATH - 1] = L'\0';
    if (GetFileAttributesW(psPath) == INVALID_FILE_ATTRIBUTES) {
        ShowError(L"Не найден Windows PowerShell 5.1 (powershell.exe).");
        return 1;
    }

    _snwprintf(args, 2 * MAX_PATH,
               L"-NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File \"%s\"",
               scriptPath);
    args[2 * MAX_PATH - 1] = L'\0';

    ZeroMemory(&startupInfo, sizeof(startupInfo));
    startupInfo.cb = sizeof(startupInfo);
    startupInfo.dwFlags = STARTF_USESHOWWINDOW;
    startupInfo.wShowWindow = SW_HIDE;
    ZeroMemory(&processInfo, sizeof(processInfo));

    if (!CreateProcessW(psPath, args, NULL, NULL, FALSE, CREATE_NO_WINDOW,
                        NULL, modulePath, &startupInfo, &processInfo)) {
        _snwprintf(errorText, 256,
                   L"Не удалось запустить Windows PowerShell (код ошибки %lu).",
                   (unsigned long)GetLastError());
        errorText[255] = L'\0';
        ShowError(errorText);
        return 1;
    }
    CloseHandle(processInfo.hThread);
    CloseHandle(processInfo.hProcess);
    return 0;
}
