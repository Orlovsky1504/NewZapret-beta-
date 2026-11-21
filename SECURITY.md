# Security Policy

## Why this tool is security-sensitive

zapret-discord-youtube runs a packet-manipulation engine (`winws.exe`) with
the WinDivert driver, which requires **administrator rights** and loads a
driver into the Windows kernel. A malicious build of this tool - or a
tampered binary in `bin/` - would have full system access. Treat it like
any other privileged software.

## Verify what you run

1. Download ONLY from the official release page:
   https://github.com/Flowseal/zapret-discord-youtube/releases
2. Compare the SHA256 of the archive with the checksums printed in the
   release workflow logs.
3. After extracting, run `zapret.bat` -> `Run Diagnostics` - it
   Authenticode-verifies `bin/winws.exe`, `WinDivert.dll`, `WinDivert64.sys`
   and `cygwin1.dll`, and warns if any of them fails the check.
4. The `bin/` files originate from
   [zapret-win-bundle](https://github.com/bol-van/zapret-win-bundle) (bol-van).
5. WinDivert is flagged by some antiviruses. Do NOT whitelist files from
   untrusted sources; instead verify hashes as above.

## Reporting a vulnerability

If you find a security issue in this project (e.g. command injection,
unsafe elevation, tampering in the update flow), please report it
privately via a security advisory on GitHub, or open an issue with as few
weaponized details as possible. Do not post working exploits publicly
before a fix is available.
