# ---------------------------------------------------------------------------
# User strategies (clone a built-in strategy into strategies-user.json)
# ---------------------------------------------------------------------------

function Merge-StrategyLists {
    # Pure: base list overlaid by the user list (user wins on id, new ids appended).
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Base,
        [AllowEmptyCollection()][array]$User = @()
    )
    $merged = New-Object System.Collections.Generic.List[object]
    $index = @{}
    foreach ($s in $Base) { $merged.Add($s); $index[([string]$s.id).ToLowerInvariant()] = $merged.Count - 1 }
    foreach ($s in $User) {
        $key = ([string]$s.id).ToLowerInvariant()
        if ($index.ContainsKey($key)) {
            $merged[$index[$key]] = $s
        } else {
            $index[$key] = $merged.Count
            $merged.Add($s)
        }
    }
    return $merged.ToArray()
}

function Read-UserStrategies {
    param([string]$UserFile = $script:UserStrategiesFile)
    if (-not (Test-Path -LiteralPath $UserFile)) { return @() }
    try {
        $json = [IO.File]::ReadAllText($UserFile) | ConvertFrom-Json
    } catch {
        throw "strategies-user.json повреждён: $($_.Exception.Message). Исправьте или удалите файл и попробуйте снова."
    }
    $list = @($json.strategies)
    foreach ($s in $list) {
        if (-not $s.id -or -not $s.args) { throw 'strategies-user.json: у каждой стратегии обязательны поля id и args.' }
    }
    return $list
}

function Write-UserStrategies {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Strategies,
        [string]$UserFile = $script:UserStrategiesFile
    )
    $payload = [ordered]@{ schemaVersion = 1; strategies = @($Strategies) }
    [IO.File]::WriteAllText($UserFile, ($payload | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
    $script:Strategies = $null   # drop the merged cache
}

function Test-StrategyShareText {
    param([AllowEmptyString()][string]$Value, [int]$MaxLength, [string]$Field, [switch]$AllowEmpty)
    if ($null -eq $Value -or (-not $AllowEmpty -and [string]::IsNullOrWhiteSpace($Value))) {
        throw "Поле '$Field' отсутствует или пустое."
    }
    if ($Value.Length -gt $MaxLength) { throw "Поле '$Field' длиннее лимита $MaxLength символов." }
    if ($Value -match '[\x00-\x1F\x7F]') { throw "Поле '$Field' содержит управляющие символы." }
}

function ConvertTo-StrategyShareString {
    # Pure export: gzip compact JSON, then Base64 with a versioned prefix.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Strategy)
    foreach ($field in @('id','name','description','args')) {
        if ($null -eq $Strategy.PSObject.Properties[$field]) { throw "Стратегия не содержит обязательное поле '$field'." }
    }
    $id = [string]$Strategy.id
    $name = [string]$Strategy.name
    $description = [string]$Strategy.description
    $strategyArgs = [string]$Strategy.args
    if (-not (Test-StrategyCloneId -Id $id)) { throw "Недопустимый ID стратегии '$id'." }
    Test-StrategyShareText -Value $name -MaxLength 80 -Field 'name'
    Test-StrategyShareText -Value $description -MaxLength 512 -Field 'description' -AllowEmpty
    Test-StrategyShareText -Value $strategyArgs -MaxLength 16384 -Field 'args'
    $problems = Test-StrategyArgs -Expanded $strategyArgs -Template
    if ($problems.Count -gt 0) { throw ('Небезопасные args: ' + ($problems -join '; ')) }
    [void](Expand-StrategyArgs -Template $strategyArgs)

    $jsonObject = [ordered]@{ id = $id; name = $name; description = $description; args = $strategyArgs }
    $json = ConvertTo-Json -InputObject $jsonObject -Compress -Depth 4
    $encoding = New-Object System.Text.UTF8Encoding($false, $true)
    $bytes = $encoding.GetBytes($json)
    $output = New-Object System.IO.MemoryStream
    $gzip = New-Object System.IO.Compression.GZipStream($output, [System.IO.Compression.CompressionMode]::Compress, $true)
    try { $gzip.Write($bytes, 0, $bytes.Length) } finally { $gzip.Dispose() }
    $encoded = [Convert]::ToBase64String($output.ToArray())
    $output.Dispose()
    $shareString = 'zapret1:' + $encoded
    if ($shareString.Length -gt 16384) { throw 'Строка стратегии превышает лимит 16 КБ.' }
    return $shareString
}

function ConvertTo-StrategyShareCode {
    # Backward-compatible alias for callers using the earlier function name.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Strategy)
    return (ConvertTo-StrategyShareString -Strategy $Strategy)
}

function Export-UserStrategy {
    # Print a one-line share string and copy it when a clipboard provider exists.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Id)
    $strategy = Get-Strategy -Id $Id
    if (-not $strategy) { throw "Стратегия '$Id' не найдена." }
    $shareString = ConvertTo-StrategyShareString -Strategy $strategy
    Write-Host $shareString -ForegroundColor Cyan
    try {
        if (Get-Command Set-Clipboard -ErrorAction SilentlyContinue) {
            Set-Clipboard -Value $shareString -ErrorAction Stop
            Write-Ok 'Код стратегии скопирован в буфер обмена.'
        } else {
            Write-Info2 'Буфер обмена недоступен; скопируйте строку из консоли.'
        }
    } catch { Write-Info2 'Не удалось записать в буфер обмена; скопируйте строку из консоли.' }
    return $shareString
}

function ConvertFrom-StrategyShareString {
    # Pure, bounded decoder and validator. It never writes imported data.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ShareString,
        [string]$NewId
    )
    if (-not $ShareString.StartsWith('zapret1:', [StringComparison]::Ordinal)) { throw 'Неизвестный формат обмена стратегией (ожидается префикс zapret1:).' }
    $encoded = $ShareString.Substring(8)
    if ($ShareString.Length -gt 16384 -or $encoded.Length -eq 0 -or $encoded -notmatch '^[A-Za-z0-9+/]+={0,2}$' -or ($encoded.Length % 4) -ne 0) {
        throw 'Строка Base64 повреждена или превышает лимит 16 КБ.'
    }
    try { $compressed = [Convert]::FromBase64String($encoded) } catch { throw 'Строка Base64 повреждена.' }
    if ($compressed.Length -gt 12282) { throw 'Сжатый payload превышает лимит 16 КБ.' }

    $compressedStream = New-Object System.IO.MemoryStream(, $compressed)
    $gzip = $null
    $output = New-Object System.IO.MemoryStream
    try {
        $gzip = New-Object System.IO.Compression.GZipStream($compressedStream, [System.IO.Compression.CompressionMode]::Decompress)
        $buffer = New-Object byte[] 4096
        while (($read = $gzip.Read($buffer, 0, $buffer.Length)) -gt 0) {
            if (($output.Length + $read) -gt 32768) { throw 'Распакованный payload превышает лимит 32 КБ.' }
            $output.Write($buffer, 0, $read)
        }
        $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
        $json = $utf8.GetString($output.ToArray())
    } catch {
        if ($_.Exception.Message -match 'лимит') { throw }
        throw 'Не удалось распаковать payload (неверный gzip/Base64).'
    } finally {
        if ($null -ne $gzip) { $gzip.Dispose() }
        $compressedStream.Dispose()
        $output.Dispose()
    }
    try { $data = ConvertFrom-Json -InputObject $json -ErrorAction Stop } catch { throw 'Payload содержит некорректный JSON.' }
    if ($null -eq $data -or $data -is [System.Array] -or $data -isnot [pscustomobject]) { throw 'Payload должен быть одним JSON-объектом.' }
    $propertyNames = @($data.PSObject.Properties | ForEach-Object { $_.Name } | Sort-Object)
    if (($propertyNames -join ',') -ne 'args,description,id,name') { throw 'Payload должен содержать только поля id, name, description и args.' }
    foreach ($field in @('id','name','description','args')) {
        if ($data.$field -isnot [string]) { throw "Поле '$field' должно быть строкой." }
    }
    if (-not (Test-StrategyCloneId -Id $data.id)) { throw "Недопустимый ID стратегии '$($data.id)'." }
    Test-StrategyShareText -Value $data.name -MaxLength 80 -Field 'name'
    Test-StrategyShareText -Value $data.description -MaxLength 512 -Field 'description' -AllowEmpty
    Test-StrategyShareText -Value $data.args -MaxLength 16384 -Field 'args'

    $problems = Test-StrategyArgs -Expanded $data.args -Template
    if ($problems.Count -gt 0) { throw ('Импортированная стратегия отклонена: ' + ($problems -join '; ')) }
    try { [void](Expand-StrategyArgs -Template $data.args) } catch { throw ("Импортированная стратегия отклонена: {0}" -f $_.Exception.Message) }

    if ($NewId) {
        $newIdNorm = $NewId.Trim().ToLowerInvariant()
        if (-not (Test-StrategyCloneId -Id $newIdNorm)) { throw "Недопустимый новый ID '$NewId'." }
        $data.id = $newIdNorm
    }
    return [pscustomobject]@{ id = $data.id; name = $data.name; description = $data.description; args = $data.args }
}

function ConvertFrom-StrategyShareCode {
    # Backward-compatible alias for callers using the earlier function name.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Payload, [string]$NewId)
    return (ConvertFrom-StrategyShareString -ShareString $Payload -NewId $NewId)
}

function Import-UserStrategy {
    # Validates and persists one portable strategy; caller may then offer service install.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Alias('Payload')][string]$ShareString,
        [string]$NewId,
        [string]$UserFile = $script:UserStrategiesFile
    )
    $strategy = ConvertFrom-StrategyShareString -ShareString $ShareString -NewId $NewId
    $id = $strategy.id.ToLowerInvariant()
    if (@(Get-Strategies | Where-Object { $_.id.ToLowerInvariant() -eq $id }).Count -gt 0) {
        throw "Стратегия '$id' уже существует. Используйте -NewId с другим идентификатором."
    }
    $user = @(Read-UserStrategies -UserFile $UserFile)
    if (@($user | Where-Object { $_.id.ToLowerInvariant() -eq $id }).Count -gt 0) {
        throw "Стратегия '$id' уже есть в strategies-user.json."
    }
    $entry = [pscustomobject]@{
        id = $strategy.id; name = $strategy.name; legacyFile = $null
        description = $strategy.description; args = $strategy.args
    }
    $user += $entry
    $parent = Split-Path -Parent $UserFile
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Write-UserStrategies -Strategies @($user) -UserFile $UserFile
    Write-Ok ("Импортирована пользовательская стратегия '{0}'." -f $id)
    Write-Log "User strategy imported: $id"
    return $entry
}

function Test-StrategyCloneId {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Id)
    return ($Id -match '(?-i)^[a-z0-9][a-z0-9-]{1,40}$')
}

function New-UserStrategy {
    # Clones $BaseId into strategies-user.json under $NewId.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$BaseId,
        [Parameter(Mandatory = $true)][string]$NewId,
        [string]$UserFile = $script:UserStrategiesFile
    )
    $newIdNorm = $NewId.Trim().ToLowerInvariant()
    if (-not (Test-StrategyCloneId -Id $newIdNorm)) {
        throw "Идентификатор '$NewId' не подходит: строчные латинские буквы, цифры и '-', первая — буква/цифра, 2-41 символ."
    }
    $base = Get-Strategy $BaseId
    if (-not $base) { throw "Базовая стратегия '$BaseId' не найдена (см. zapret.ps1 list)." }
    if (@(Get-Strategies | Where-Object { $_.id.ToLowerInvariant() -eq $newIdNorm }).Count -gt 0) {
        throw "Стратегия '$newIdNorm' уже существует. Выберите другое имя."
    }
    $userExisting = @(Read-UserStrategies -UserFile $UserFile | Where-Object { $_.id.ToLowerInvariant() -eq $newIdNorm })
    if ($userExisting.Count -gt 0) {
        throw "Стратегия '$newIdNorm' уже есть в strategies-user.json. Выберите другое имя."
    }
    $clone = [pscustomobject]@{
        id          = $newIdNorm
        name        = $newIdNorm
        legacyFile  = $null
        description = "Пользовательская копия '$($base.id)'. $($base.description)"
        args        = $base.args
    }
    $user = @(Read-UserStrategies -UserFile $UserFile)
    $user += $clone
    Write-UserStrategies -Strategies @($user) -UserFile $UserFile
    Write-Ok ("Создана пользовательская стратегия '{0}' (копия '{1}')." -f $newIdNorm, $base.id)
    Write-Info2 ("Файл: {0} (не затирается обновлениями; настройка — через меню Clone Strategy)" -f $UserFile)
    Write-Log "User strategy cloned: $($base.id) -> $newIdNorm"
    return $clone
}

function Set-UserStrategyParam {
    # Replaces ALL occurrences of --dpi-desync-<param>=<number> in the clone's args.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][ValidateSet('repeats', 'split-pos', 'seqovl')][string]$Param,
        [Parameter(Mandatory = $true)][int]$Value,
        [string]$UserFile = $script:UserStrategiesFile
    )
    if ($Value -lt 1 -or $Value -gt 100000) { throw 'Значение вне разумных пределов (1..100000).' }
    $user = @(Read-UserStrategies -UserFile $UserFile)
    $target = @($user | Where-Object { $_.id -eq $Id.Trim().ToLowerInvariant() }) | Select-Object -First 1
    if (-not $target) { throw "Стратегия '$Id' не найдена в strategies-user.json. Сначала клонируйте: clone-strategy <base-id> <new-id>." }
    $flag = switch ($Param) {
        'repeats'   { '--dpi-desync-repeats' }
        'split-pos' { '--dpi-desync-split-pos' }
        'seqovl'    { '--dpi-desync-split-seqovl' }
    }
    $pattern = "$flag=\d+"
    if ($target.args -notmatch $pattern) { throw "В args стратегии '$($target.id)' нет '$flag=<число>' - менять нечего." }
    $target.args = $target.args -replace $pattern, "$flag=$Value"
    $updated = @($user | ForEach-Object { if ($_.id -eq $target.id) { $target } else { $_ } })
    Write-UserStrategies -Strategies $updated -UserFile $UserFile
    Write-Ok ("{0} -> {1} у стратегии '{2}'." -f $Param, $Value, $target.id)
    return (Get-Strategy $target.id)
}

function Set-UserStrategyFake {
    # Replaces every ACTIVE_*.bin reference in the clone's args with another fake.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$FakeBaseName,
        [string]$UserFile = $script:UserStrategiesFile
    )
    if ($FakeBaseName -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$') { throw 'Invalid fake name.' }
    if (-not (Test-Path -LiteralPath (Join-Path $script:BinDir ($FakeBaseName + '.bin')))) {
        throw "bin\$FakeBaseName.bin не найден."
    }
    $user = @(Read-UserStrategies -UserFile $UserFile)
    $target = @($user | Where-Object { $_.id -eq $Id.Trim().ToLowerInvariant() }) | Select-Object -First 1
    if (-not $target) { throw "Стратегия '$Id' не найдена в strategies-user.json. Сначала клонируйте: clone-strategy <base-id> <new-id>." }
    $newArgs = [regex]::Replace($target.args, '(--dpi-desync-fake-[a-z0-9-]+="\{BIN\})ACTIVE_[A-Za-z0-9_.-]+\.bin', '${1}' + $FakeBaseName + '.bin')
    if ($newArgs -eq $target.args) { throw "В args стратегии '$($target.id)' нет ACTIVE_*.bin-фейков - менять нечего." }
    $target.args = $newArgs
    $updated = @($user | ForEach-Object { if ($_.id -eq $target.id) { $target } else { $_ } })
    Write-UserStrategies -Strategies $updated -UserFile $UserFile
    Write-Ok ("ACTIVE_*.bin-фейки у '{0}' заменены на '{1}'." -f $target.id, $FakeBaseName)
    return (Get-Strategy $target.id)
}
