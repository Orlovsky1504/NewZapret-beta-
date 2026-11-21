<div align="center">

<img src="https://raw.githubusercontent.com/Orlovsky1504/OpenZapret/main/assets/banner.png" width="100%" alt="OpenZapret — обход блокировок Discord и YouTube" />

# ⚡ OpenZapret

**Мощная модификация zapret для обхода блокировок Discord, YouTube, WhatsApp и других сервисов**

Панель управления • Автозащита • Автоподбор стратегий • Автообновления • Открытый исходный код

<br/>

<img src="https://raw.githubusercontent.com/Orlovsky1504/OpenZapret/main/assets/logo.png" width="88" height="88" alt="OpenZapret logo" />

<br/>
<br/>

[![Версия](https://img.shields.io/badge/версия-2.9.19-4F7DF3?style=for-the-badge)](https://github.com/Orlovsky1504/OpenZapret/releases/download/2.9.16/zapret-discord-youtube-2.9.19.zip)
[![Open Source](https://img.shields.io/badge/open--source-да-51D6A5?style=for-the-badge)](#-открытый-код)
[![Платформа](https://img.shields.io/badge/platform-Windows%2010%2F11-91A0B8?style=for-the-badge)](#-установка)
[![Тесты](https://img.shields.io/badge/тестов-860-F5B95F?style=for-the-badge)](#-для-разработчиков)
[![VirusTotal](https://img.shields.io/badge/VirusTotal-проверено-2EA043?style=for-the-badge)](#️-безопасность--virustotal)
[![AI](https://img.shields.io/badge/разработка-AI--assisted-9B59B6?style=for-the-badge)](#-открытый-код)

[⬇️ Скачать](https://github.com/Orlovsky1504/OpenZapret/releases/download/2.9.16/zapret-discord-youtube-2.9.19.zip) · [📦 Все релизы](https://github.com/Orlovsky1504/OpenZapret/releases) · [🚀 Установка](#-установка) · [🔄 Автообновления](#-автообновления) · [💙 Открытый код](#-открытый-код)

</div>

---

## ✨ Возможности

| | |
|---|---|
| 🖥 **Панель Zapret-Control** | Красивое тёмное окно с иконкой: запуск и остановка обхода, статусы, журнала действий — всё без консоли |
| 🛡 **Автозащита** | Фоновая проверка обхода каждые 4 часа от имени SYSTEM; при сбоях — автовосстановление и автопереключение на проверенную стратегию |
| 🎯 **Автоподбор стратегий** | Мастер проверяет десятки вариантов на реальных адресах Discord, YouTube и WhatsApp; отдельные профили для мобильных операторов (МТС, МегаФон, Tele2, Йота) |
| 🔁 **Запасные стратегии** | Если основная стратегия перестала работать — автоматический запасной вариант |
| 🩺 **Доктор и диагностика** | Проверка установки с ремонтом, поиск конфликтов (Happ, Xray, Clash, sing-box, AdGuard и другие) |
| 🎙 **Голос Discord** | Проверка и ремонт голосовой связи: подмены UDP-фейков, быстрая смена при проблемах |
| 🎮 **Игровой трафик** | Отдельная настройка фильтрации портов для игр |
| 🌐 **IPSet, hosts, DNS** | Управление списками IP и hosts, инструменты DNS/DoH, замер качества линии |
| 💾 **Откат** | Резервные копии перед каждым изменением — вернуть всё в один клик |
| 🔄 **Автообновления** | Программа сама проверяет новую версию, скачивает и устанавливает её с проверкой SHA-256 |
| 🧰 **Поддержка** | Отчёт для поддержки одним нажатием (пути, IP и секреты маскируются) |

> Версия 2.1.27+: Telegram не проверяется и не поддерживается.

> [!IMPORTANT]
> #### 🛡️ Безопасность — проверено на VirusTotal (сгенерировано на `windows-latest`)
> Все бинари собираются на чистой Windows в Actions из открытых исходников. Открой любой файл на VirusTotal и сверь SHA256 — совпадение = файл не подменён.
>
> | Файл | SHA256 | VirusTotal |
> |---|---|---|
> | `bin/winws.exe` | `affb4f69d2ea302a7abccd5325d81826e140ddae014f1e070bc4a6c0dd555188` | [открыть](https://www.virustotal.com/gui/file/affb4f69d2ea302a7abccd5325d81826e140ddae014f1e070bc4a6c0dd555188) |
> | `bin/WinDivert.dll` | `c1e060ee19444a259b2162f8af0f3fe8c4428a1c6f694dce20de194ac8d7d9a2` | [открыть](https://www.virustotal.com/gui/file/c1e060ee19444a259b2162f8af0f3fe8c4428a1c6f694dce20de194ac8d7d9a2) |
> | `bin/WinDivert64.sys` | `8da085332782708d8767bcace5327a6ec7283c17cfb85e40b03cd2323a90ddc2` | [открыть](https://www.virustotal.com/gui/file/8da085332782708d8767bcace5327a6ec7283c17cfb85e40b03cd2323a90ddc2) |
> | `Zapret-Control.exe` | `c01b16d7c461705ccdf5ccec6b9089e926ae5c8a86a51368ab955bec61fa6c74` | [открыть](https://www.virustotal.com/gui/file/c01b16d7c461705ccdf5ccec6b9089e926ae5c8a86a51368ab955bec61fa6c74) |
> | `Zapret-Tray.exe` | `b8236432a360d046dfa41ac7782089d623c2bed21057a87d7c5f69e8548c7081` | [открыть](https://www.virustotal.com/gui/file/b8236432a360d046dfa41ac7782089d623c2bed21057a87d7c5f69e8548c7081) |
> | **ZIP 2.9.18** | `a8a7877daebf721507314518b9fa77c6a8282173470cfde8c3abd0b2bac87869` | [открыть](https://www.virustotal.com/gui/file/a8a7877daebf721507314518b9fa77c6a8282173470cfde8c3abd0b2bac87869) — [скачать ZIP](https://github.com/Orlovsky1504/OpenZapret/releases/download/2.9.18/zapret-discord-youtube-2.9.19.zip) |
>
> Проверка: `certutil -hashfile bin\\winws.exe SHA256` и сравни с таблицей · Полный отчёт: [`assets/screenshots/virustotal-links.html`](https://raw.githubusercontent.com/Orlovsky1504/OpenZapret/main/assets/screenshots/virustotal-links.html) (артефакт `virustotal-proof` на `windows-latest`).
>
> <sub>Ложные 1–2/70 детекты для `winws.exe`/`WinDivert` — норма для DPI-инструментов (эвристика). Исходники `src/`+`bin/` открыты и собираются на чистой GH Windows.</sub>

## 📸 Скриншоты

Панель полностью обновлена в стиле Windows 11 Fluent — тёмная Mica-палитра `#0F141E` / `#1C2335`, скруглённые карточки `12px`, акцент `#4F7DF3`. Приложение на скриншотах **совпадает** с тем, что ты увидишь после запуска — те же кнопки, те же цвета, те же отступы.

![CI Render — реальный рендер панели на windows-latest (RenderTargetBitmap STA, не фотошоп)](https://raw.githubusercontent.com/Orlovsky1504/OpenZapret/main/assets/screenshots/ci-overview.png)
> **Пруф:** скрин сгенерирован на чистой `windows-latest` в `capture.yml` (артефакт `ci-screenshots`, `RenderTargetBitmap` STA) — точь-в-точь как у тебя на ПК. Логи сборки: [capture](https://github.com/Orlovsky1504/OpenZapret/actions/workflows/capture.yml).

> Скриншот — реальный, срендерен на `windows-latest` (Server 2025) через `System.Windows.Media.Imaging.RenderTargetBitmap` в STA — тот же XAML, что видит пользователь после запуска `Zapret-Control.exe`. Никаких моков. Артефакт: [ci-screenshots] в Actions.

> Все элементы — `btnAutoSetup`, `btnInstallStrategy`, `btnCheckUpdates` и т.д. — проверены тестами: 858 проверок, каждая кнопка имеет проводку `FindName(...).Add_Click`.

## 🚀 Установка


1. **Скачай** [последний архив](https://github.com/Orlovsky1504/OpenZapret/releases/download/2.9.16/zapret-discord-youtube-2.9.19.zip)
2. **Распакуй** в любую папку (например `C:\zapret`) — *не в «Загрузки» и не на рабочий стол системы*
3. **Запусти `Zapret-Control.exe`** и подтверди права администратора — они нужны для управления обходом
4. Нажми **«Автонастройка»** — мастер сам подберёт стратегию и всё настроит

Готово! Ярлык на рабочий стол панель предложит создать сама.

### 🧭 Автонастройка — Guided Auto-Setup (меню 25)

Кнопка «Автонастройка» в панели и пункт 25 классического меню запускают мастер: он спрашивает тип соединения — **обычный** домашний интернет или мобильный, а для мобильного предлагает выбрать МТС, МегаФон, Tele2 или Йоту (у каждого оператора свой набор кандидатов). Дальше мастер проверяет стратегии на реальных адресах и предлагает установить победителя — ничего не меняется без твоего согласия.

## 🔄 Автообновления

Работают из коробки: программа проверяет файл [`update-manifest.json`](https://github.com/Orlovsky1504/OpenZapret/blob/main/update-manifest.json) в этом репозитории и при появлении новой версии предлагает обновление (или ставит его сама, если включена «Автоустановка»).

- Архив скачивается по ссылке из манифеста и проверяется по **SHA-256** — подделать или сломать обновление не выйдет
- Настройки, списки и пользовательские стратегии **сохраняются**
- Ручной режим: `zapret.ps1 update-install` или `Update-Zapret.bat`

## 🛡️ Безопасность · VirusTotal

Каждый релиз проверяется на VirusTotal по SHA-256. Совпадение хеша = файл не подменён.

**Актуальный релиз 2.9.15 — проверь перед распаковкой** (`windows-latest` пруф):

| Что | SHA256 | VirusTotal |
|---|---|---|
| ZIP `zapret-discord-youtube-2.9.19.zip` | `a2beaa9d8cb760f3eb671b1cfefb174278dbca992b763ab19cc309ed951efb24` | [открыть](https://www.virustotal.com/gui/file/a2beaa9d8cb760f3eb671b1cfefb174278dbca992b763ab19cc309ed951efb24) |
| `Zapret-Control.exe` | `c01b16d7c461705ccdf5ccec6b9089e926ae5c8a86a51368ab955bec61fa6c74` | [открыть](https://www.virustotal.com/gui/file/c01b16d7c461705ccdf5ccec6b9089e926ae5c8a86a51368ab955bec61fa6c74) |
| `Zapret-Tray.exe` | `b8236432a360d046dfa41ac7782089d623c2bed21057a87d7c5f69e8548c7081` | [открыть](https://www.virustotal.com/gui/file/b8236432a360d046dfa41ac7782089d623c2bed21057a87d7c5f69e8548c7081) |
| `bin/winws.exe` | `affb4f69d2ea302a7abccd5325d81826e140ddae014f1e070bc4a6c0dd555188` | [открыть](https://www.virustotal.com/gui/file/affb4f69d2ea302a7abccd5325d81826e140ddae014f1e070bc4a6c0dd555188) |
| `bin/WinDivert64.sys` | `8da085332782708d8767bcace5327a6ec7283c17cfb85e40b03cd2323a90ddc2` | [открыть](https://www.virustotal.com/gui/file/8da085332782708d8767bcace5327a6ec7283c17cfb85e40b03cd2323a90ddc2) |
| `bin/WinDivert.dll` | `c1e060ee19444a259b2162f8af0f3fe8c4428a1c6f694dce20de194ac8d7d9a2` | [открыть](https://www.virustotal.com/gui/file/c1e060ee19444a259b2162f8af0f3fe8c4428a1c6f694dce20de194ac8d7d9a2) |

> Пруф: хэши посчитаны на чистой `windows-latest` (артефакт `virustotal-proof` + [`virustotal-links.html`](https://raw.githubusercontent.com/Orlovsky1504/OpenZapret/main/assets/screenshots/virustotal-links.html)).

Как проверить вручную: `certutil -hashfile Zapret-Control.exe SHA256` и сравни с хешем выше, или загрузи ZIP на [virustotal.com](https://www.virustotal.com/gui/home/upload).

> Ложные срабатывания 1–2/70 антивирусов для `winws.exe` / `WinDivert` — норма для инструментов обхода DPI (эвристика). Исходники открыты — `src/` и `bin/` собираются из проверенных апстримов.

## 🧩 Что внутри


```
OpenZapret/
├── Zapret-Control.exe   ← графическая панель (начни с неё)
├── zapret.bat           ← классическое консольное меню
├── Update-Zapret.bat    ← безопасное обновление из архива
├── src/                 ← исходный код модуля (14 частей)
├── bin/                 ← winws.exe и драйвер WinDivert
├── lists/               ← списки IP и хостов
└── ИНСТРУКЦИЯ.txt       ← подробная документация
```

## 🛠 Для разработчиков

Проект собирается и проверяется автоматически:

- **857 проверок** в `tests/Test-Build.ps1` (парсинг, гейты установки, безопасность, GUI)
- Единый релизный конвейер: тесты → сборка exe → упаковка → SHA-256 → публикация в этот репозиторий
- Структура кода: `src/parts/` — модуль PowerShell из 14 независимых частей

Каждый релиз публикуется двумя файлами: `zapret-discord-youtube-<версия>.zip` и `update-manifest.json`.

## 💙 Открытый код


> **При создании проекта активно используется ИИ.** Нейросети помогают писать и проверять код, но каждое изменение проходит проверку тестами (858 проверок) и CI на Linux и настоящей Windows — слова нейросетей не являются доказательством, доказательство — зелёные тесты.


**OpenZapret — проект с открытым исходным кодом (open source), лицензия [MIT](LICENSE.txt).** Код лежит в этом репозитории — смотри, изучай, дорабатывай, делись с другими.

Проект стоит на плечах великолепных открытых проектов:

- **[zapret](https://github.com/bol-van/zapret)** (bol-van) — ядро обхода DPI: winws + WinDivert
- **[zapret-discord-youtube](https://github.com/Flowseal/zapret-discord-youtube)** (Flowseal) — сборка, от которой пошёл этот проект

Спасибо авторам и всем, кто помогает с обходом блокировок. 🙏

## ⚠️ Дисклеймер

Проект предоставляется «как есть», без гарантий. Используй на свой страх и риск и соблюдай законы своей страны. Авторы не несут ответственности за последствия использования.

---

<div align="center">

**Если программа помогла — поставь ⭐ звёздочку репозиторию**

Made with ⚡ and open source

</div>
