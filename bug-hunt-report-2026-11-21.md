# Bug Hunt Report — 2026-11-21 (запуск по запросу “баг хантом займись”)

**Основа:** `eae9bf6 → 32c6651 → 66ab8f8` (3.0.3-3.0.6), ветка `main` актуальна, `Test-Build 860/860 PASS`, релиз `3.0.6` `5f90403 success`.

## Инструменты
- `qa/bug-hunt4.py` — XAML/FindName/format/locale
- `qa/bug-hunt.ps1 / bug-hunt2.ps1 / bug-hunt3.ps1` — логика, парсинг, вердикты
- `qa/check-action-wiring.ps1` — 4145 вызовов
- `qa/check-integrity.ps1` — сверка с эталоном 2.9.13
- `tests/Test-Build.ps1` (pwsh 7.4.6)

## Найдено

### 1. Критический (исправлен в 3.0.5)
**`Zapret-Control.ps1:2047 InvokeMethodOnNull`** — `FindName('txtLogFilter').Add_TextChanged` на `$null` → падение панели `код 1`.
- Причина: в `2.9.18` добавлены кодовые FindName для `txtLogFilter/txtWhatsNew/btnCopyLog/btnClearLog/btnOpenReleases`, XAML для них не добавлен.
- Признаки: `bug-hunt4` 5× `code-unknown-name`, пользовательский лог `Process exited early code=1`, ручной `powershell -File` → `InvokeMethodOnNull`.
- Фикс: гварды `if ($el=FindName('x')) { $el.Add_... }` + `if ($m.Success -and $script:TxtWhatsNew)` в `3.0.5 32c6651`.

### 2. Высокий (открыт)
**`Zapret-Control.ps1:2507 Set-UserStrategy — неизвестная команда`**
- `check-action-wiring` → `PROBLEM: Zapret-Control.ps1:2507 неизвестная команда: Set-UserStrategy` (1/4145).
- Контекст — `btnStrategyCompareApplyBest`:
  ```ps1
  Start-ControlAction -Title ('Применение '+$best) -Action {
      param($StrategyId)
      Set-UserStrategy -StrategyId $StrategyId | Out-Null  # ← нет такой функции
      Write-Host ('Применена: '+$StrategyId)
      [void](Invoke-ZapretServiceRestartPrompt -Reason 'Стратегия из сравнения')
  } -ArgumentList @($best)
  ```
- В `src/parts/Zapret.UserStrategies.ps1` есть `Set-UserStrategyParam`, `Set-UserStrategyFake`, `New-UserStrategy`, но нет `Set-UserStrategy`.
- Ожидаемо: `Install-ZapretStrategy` / `Set-Strategy` / `Switch-Strategy`.
- Эффект: кнопка “Применить лучшую” в сравнении стратегий упадёт.

### 3. Средний (открыт, статика)
**`bug-hunt4` 5× `code-unknown-name` всё ещё флагается** даже с гвардами:
```
797  FindName('txtLogFilter') — нет в XAML
798  FindName('txtWhatsNew') — нет в XAML
2089 FindName('btnCopyLog') — нет в XAML
2090 FindName('btnClearLog') — нет в XAML
2091 FindName('txtLogFilter') второй вызов
2095 FindName('btnOpenReleases') — нет в XAML
```
Гварды предотвращают падение, но фича не работает — нет UI. Требует либо добавить XAML (TextBox/Buttons), либо удалить мёртвый код.

### 4. Низкий (шум, можно игнор)
**`bug-hunt4` 2× `xaml-unused-name`:**
```
152 toggleButton не подключён через FindName
201 dropDownBorder не подключён через FindName
```
Это части шаблонов (`ControlTemplate`), используются via `TargetName` в триггерах, а не кодом. Не баг.

**`check-integrity` 1 problem** — сверка с `2.9.13` (61 совпало/9 отличается) — ожидаемо: версия выросла, файлы менялись.

## Проверено и OK
- `bug-hunt` / `bug-hunt2` / `bug-hunt3` — ALL PASS
- `Test-Build` — 860/860 PASS (pwsh 7.4.6)
- `release.yml` + `update-manifest.json` — авто-синк SHA после `3.0.1`, `README badge` уже правится.

## Рекомендация (следующий шаг)
1. Починить `2507` — заменить `Set-UserStrategy` на реальную команду (проверить `Zapret.Runtime`/`Zapret.Strategies`).
2. Для `2.9.18` фич — либо доделать XAML (панель “Журнал” с фильтром/копированием + “Что нового”), либо выпилить `FindName` до появления UI.

Хочешь — сделаю `3.0.7` с фиксом `Set-UserStrategy` и уберу мёртвые FindName.
