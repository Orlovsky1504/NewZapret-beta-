/* winprobe.c - native WinDivert health probe for zapret-discord-youtube (C, WinAPI).
 *
 * Opens the WinDivert driver once with a filter that matches nothing, then
 * closes it. Prints the exact Win32 error when the driver cannot be opened -
 * the same failure surface winws.exe hits at startup (exit code 177 & Co).
 *
 * Exit codes: 0 = driver opened fine, 1 = WinDivertOpen failed (error printed),
 *             2 = environment broken (WinDivert.dll missing or incomplete).
 *
 * Build (from tools/):
 *   x86_64-w64-mingw32-gcc -municode -mconsole -s -O2 -Wall -o ../bin/WinProbe.exe winprobe/winprobe.c
 */
#include <windows.h>
#include <stdio.h>

typedef void *WD_HANDLE;
typedef WD_HANDLE (WINAPI *WinDivertOpenFn)(const char *, int, short, unsigned long long);
typedef int      (WINAPI *WinDivertCloseFn)(WD_HANDLE);

static int IsAdmin(void)
{
    BOOL isAdmin = FALSE;
    SID_IDENTIFIER_AUTHORITY ntAuth = {SECURITY_NT_AUTHORITY};
    PSID group = NULL;
    if (AllocateAndInitializeSid(&ntAuth, 2, SECURITY_BUILTIN_DOMAIN_RID,
                                 DOMAIN_ALIAS_RID_ADMINS, 0, 0, 0, 0, 0, 0, &group)) {
        CheckTokenMembership(NULL, group, &isAdmin);
        FreeSid(group);
    }
    return isAdmin ? 1 : 0;
}

static void PrintWin32Error(unsigned long err)
{
    wchar_t buf[512];
    DWORD n = FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
                             NULL, (DWORD)err, MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
                             buf, (DWORD)(sizeof buf / sizeof buf[0]), NULL);
    while (n > 0 && (buf[n - 1] == L'\r' || buf[n - 1] == L'\n' || buf[n - 1] == L' ')) { buf[--n] = 0; }
    if (n > 0) {
        printf("WinProbe: описание ошибки: %ls\n", buf);
    }
}

int wmain(int argc, wchar_t **argv)
{
    wchar_t path[MAX_PATH + 32];
    HMODULE dll;
    WinDivertOpenFn pOpen;
    WinDivertCloseFn pClose;
    WD_HANDLE handle;
    unsigned long err;

    (void)argc; (void)argv;
    SetConsoleOutputCP(65001);

    printf("WinProbe: проверка драйвера WinDivert (zapret-discord-youtube).\n");
    printf("WinProbe: права администратора: %s\n", IsAdmin() ? "есть" : "НЕТ (открывать драйвер может только администратор)");

    /* WinDivert.dll lives next to us in bin\; fall back to the normal search. */
    if (!GetModuleFileNameW(NULL, path, MAX_PATH)) { path[0] = 0; }
    {
        wchar_t *slash = wcsrchr(path, L'\\');
        if (slash) { *(slash + 1) = 0; }
        else { path[0] = 0; }
        if (wcslen(path) + 12 < MAX_PATH + 32) { wcscat(path, L"WinDivert.dll"); }
    }
    dll = LoadLibraryW(path);
    if (!dll) { dll = LoadLibraryW(L"WinDivert.dll"); }
    if (!dll) {
        err = GetLastError();
        printf("WinProbe: НЕ удалось загрузить WinDivert.dll, код ошибки = %lu\n", err);
        PrintWin32Error(err);
        return 2;
    }

    pOpen = (WinDivertOpenFn)GetProcAddress(dll, "WinDivertOpen");
    pClose = (WinDivertCloseFn)GetProcAddress(dll, "WinDivertClose");
    if (!pOpen || !pClose) {
        err = GetLastError();
        printf("WinProbe: в WinDivert.dll нет нужных функций, код ошибки = %lu\n", err);
        PrintWin32Error(err);
        return 2;
    }

    /* A filter that matches (almost) nothing: opens the driver without
     * capturing any real traffic. WINDIVERT_LAYER_NETWORK = 0. */
    SetLastError(0);
    handle = pOpen("tcp.DstPort == 65535", 0, 0, 0);
    err = GetLastError();
    if (handle == NULL || handle == (WD_HANDLE)(LONG_PTR)-1) {
        printf("WinProbe: WinDivertOpen НЕ удался, код ошибки = %lu\n", err);
        PrintWin32Error(err);
        if (!IsAdmin()) {
            printf("WinProbe: подсказка: запустите проверку от имени администратора.\n");
        }
        return 1;
    }
    pClose(handle);
    printf("WinProbe: WinDivertOpen прошёл успешно, драйвер открывается.\n");
    return 0;
}
