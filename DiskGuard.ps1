﻿﻿﻿#Requires -Version 5.1
<#
.SYNOPSIS
    DiskGuard - 坏盘（SSD / HDD）安全隔离与只读导出辅助工具。

.DESCRIPTION
    一键应用之前讨论的三套方案与配套加固：

      A  全局默认离线：san policy=offlineall + automount disable + automount scrub
         作用：新接入的磁盘一律以脱机状态出现，不分配盘符、不挂载、不索引、不 TRIM。
         必须在插入硬盘盒之前执行。

      B  把指定磁盘立即脱机（插上后补救用）。
         注意：此时枚举阶段的 I/O 已经发生，只能减少后续读写。

      C  把指定磁盘只读联机（能稳定认盘、想直接拷文件时用）。
         会设置磁盘只读 + 取消开机自检 + Defender 排除。

    Status   查看当前策略、加固项和所有磁盘状态。
    Restore  还原所有由本工具做过的改动。

.PARAMETER Mode
    A / B / C / Status / Restore。不传则进入交互菜单。

.PARAMETER DiskNumber
    方案 B / C 要操作的磁盘编号。不传则在运行时列出磁盘让你选。

.PARAMETER SkipHardening
    跳过配套加固（优化驱动器任务、Storage Sense、Windows Search、Defender 排除）。

.PARAMETER Force
    跳过确认提示，适合脚本化调用。

.EXAMPLE
    .\DiskGuard.ps1
    交互菜单。

.EXAMPLE
    .\DiskGuard.ps1 -Mode A -Force
    插盘前一次性应用方案 A 与全部配套加固。

.EXAMPLE
    .\DiskGuard.ps1 -Mode B -DiskNumber 2
    把 2 号磁盘脱机。

.EXAMPLE
    .\DiskGuard.ps1 -Restore
    还原全部改动。
#>
[CmdletBinding()]
param(
    [ValidateSet('A', 'B', 'C', 'Status', 'Restore')]
    [string]$Mode,

    [int]$DiskNumber = -1,

    [switch]$SkipHardening,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# ============================================================
# 提权
# ============================================================
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    $exe = (Get-Process -Id $PID).Path
    if (-not $exe) { $exe = 'powershell.exe' }

    $argList = @('-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($PSBoundParameters.ContainsKey('Mode')) { $argList += @('-Mode', $Mode) }
    if ($DiskNumber -ge 0) { $argList += @('-DiskNumber', [string]$DiskNumber) }
    if ($SkipHardening) { $argList += '-SkipHardening' }
    if ($Force) { $argList += '-Force' }

    try {
        Start-Process -FilePath $exe -Verb RunAs -ArgumentList $argList
        exit
    }
    catch {
        Write-Host '需要管理员权限，请右键以管理员身份运行。' -ForegroundColor Red
        exit 1
    }
}

# ============================================================
# 常量与状态文件
# ============================================================
$StateDir  = Join-Path $env:ProgramData 'DiskGuard'
$StateFile = Join-Path $StateDir 'state.json'
if (-not (Test-Path $StateDir)) {
    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
}

$PartmgrKey  = 'HKLM:\SYSTEM\CurrentControlSet\Services\partmgr\Parameters'
$MountMgrKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\mountmgr'
$WSearchKey  = 'HKLM:\SYSTEM\CurrentControlSet\Services\WSearch'
$SsKeys = @(
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy'
)

# ============================================================
# 通用辅助
# ============================================================
function Invoke-Diskpart {
    param([string[]]$Commands)
    $tmp = Join-Path $env:TEMP ('diskguard_dp_' + [guid]::NewGuid().ToString('N') + '.txt')
    Set-Content -Path $tmp -Value $Commands -Encoding ASCII
    try {
        $out = & diskpart.exe /s $tmp 2>&1
        return ($out | Out-String)
    }
    finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Get-SanPolicyValue {
    $v = (Get-ItemProperty -Path $PartmgrKey -Name SanPolicy -ErrorAction SilentlyContinue).SanPolicy
    if ($null -eq $v) { return 1 }
    return [int]$v
}

function Get-SanPolicyName {
    param([int]$Value)
    switch ($Value) {
        1 { 'OnlineAll（所有新盘自动联机）' }
        2 { 'OfflineShared（共享总线盘离线）' }
        3 { 'OfflineAll（所有新盘默认离线）' }
        4 { 'OfflineInternal（内置盘离线）' }
        default { "未知($Value)" }
    }
}

function Get-AutoMountDisabled {
    $v = (Get-ItemProperty -Path $MountMgrKey -Name NoAutoMount -ErrorAction SilentlyContinue).NoAutoMount
    if ($null -eq $v) { return $false }
    return ([int]$v -eq 1)
}

function Get-SystemDiskNumber {
    try {
        $letter = $env:SystemDrive.TrimEnd(':')
        return (Get-Partition -DriveLetter $letter).DiskNumber
    }
    catch {
        return $null
    }
}

function Read-State {
    if (-not (Test-Path $StateFile)) { return $null }
    try {
        return (Get-Content -Path $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

function Save-State {
    param([hashtable]$Patch)
    $merged = @{}
    $cur = Read-State
    if ($cur) {
        foreach ($p in $cur.PSObject.Properties) { $merged[$p.Name] = $p.Value }
    }
    foreach ($k in $Patch.Keys) { $merged[$k] = $Patch[$k] }
    $merged['UpdatedAt'] = (Get-Date).ToString('s')
    $merged | ConvertTo-Json -Depth 8 | Set-Content -Path $StateFile -Encoding UTF8
}

function Add-StateList {
    param([string]$Name, [object[]]$Items)
    $merged = @()
    $cur = Read-State
    if ($cur -and $cur.PSObject.Properties[$Name]) {
        $merged = @($cur.$Name)
    }
    $merged = @($merged + $Items | Select-Object -Unique)
    $h = @{}
    $h[$Name] = $merged
    Save-State $h
}

function Set-DiskOfflineState {
    param([int]$Number, [bool]$Offline)
    try {
        Set-Disk -Number $Number -IsOffline $Offline -ErrorAction Stop
    }
    catch {
        $cmd = if ($Offline) { 'offline disk' } else { 'online disk' }
        Invoke-Diskpart @("select disk $Number", $cmd, 'exit') | Out-Null
    }
}

function Set-DiskReadOnlyState {
    param([int]$Number, [bool]$ReadOnly)
    try {
        Set-Disk -Number $Number -IsReadOnly $ReadOnly -ErrorAction Stop
    }
    catch {
        $cmd = if ($ReadOnly) { 'attributes disk set readonly' } else { 'attributes disk clear readonly' }
        Invoke-Diskpart @("select disk $Number", $cmd, 'exit') | Out-Null
    }
}

function Show-Disks {
    $sys = Get-SystemDiskNumber
    Get-Disk | Sort-Object Number | ForEach-Object {
        [pscustomobject]@{
            '编号'     = $_.Number
            '型号'     = $_.FriendlyName
            '容量GB'   = [math]::Round($_.Size / 1GB, 1)
            '总线'     = $_.BusType
            '系统盘'   = ($_.Number -eq $sys -or $_.IsBoot -or $_.IsSystem)
            '脱机'     = $_.IsOffline
            '只读'     = $_.IsReadOnly
        }
    } | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
}

# ============================================================
# 配套加固
# ============================================================
function Get-DefragTask {
    return (Get-ScheduledTask -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag' -ErrorAction SilentlyContinue)
}

function Enable-Hardening {
    param([string[]]$Letters = @())

    $lettersClean = @($Letters | Where-Object { $_ })

    # 1. 优化驱动器计划任务（TRIM 的来源）
    $task = Get-DefragTask
    if ($task -and $task.State -ne 'Disabled') {
        Disable-ScheduledTask -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag' -ErrorAction SilentlyContinue | Out-Null
        Save-State @{ DefragTaskWasEnabled = $true }
        Write-Host '  [OK] 已禁用「优化驱动器」计划任务（停止 retrim）' -ForegroundColor Green
    }
    else {
        Save-State @{ DefragTaskWasEnabled = $false }
        Write-Host '  [--] 「优化驱动器」任务本就是禁用状态' -ForegroundColor DarkGray
    }

    # 2. Storage Sense
    $ssSnapshot = @{}
    foreach ($key in $SsKeys) {
        if (Test-Path $key) {
            $val = (Get-ItemProperty -Path $key -Name '01' -ErrorAction SilentlyContinue).'01'
            if ($null -eq $val) { $ssSnapshot[$key] = '__absent__' }
            else { $ssSnapshot[$key] = [int]$val }
            Set-ItemProperty -Path $key -Name '01' -Value 0 -Type DWord -ErrorAction SilentlyContinue
        }
    }
    Save-State @{ StorageSense = $ssSnapshot }
    Write-Host '  [OK] 已关闭 Storage Sense' -ForegroundColor Green

    # 3. Windows Search
    $ws = $null
    if ($null -ne (Get-Service -Name WSearch -ErrorAction SilentlyContinue)) {
        $ws = (Get-ItemProperty -Path $WSearchKey -Name Start -ErrorAction SilentlyContinue).Start
        if ($ws -ne 4) {
            Stop-Service -Name WSearch -Force -ErrorAction SilentlyContinue
            Set-Service -Name WSearch -StartupType Disabled -ErrorAction SilentlyContinue
            Write-Host '  [OK] 已停止并禁用 Windows Search' -ForegroundColor Green
        }
        else {
            Write-Host '  [--] Windows Search 本就是禁用状态' -ForegroundColor DarkGray
        }
    }
    else {
        Write-Host '  [--] 本系统没有 Windows Search 服务' -ForegroundColor DarkGray
    }
    Save-State @{ WSearchStartBefore = $ws }

    # 4. Defender 排除 + 取消开机自检
    $added = @()
    foreach ($l in $lettersClean) {
        $path = "$($l):\"
        try {
            Add-MpPreference -ExclusionPath $path -ErrorAction Stop
            $added += $path
            Write-Host "  [OK] Defender 已排除 $path" -ForegroundColor Green
        }
        catch {
            Write-Host "  [!!] Defender 排除失败（多半被篡改防护拦截）: $path" -ForegroundColor Yellow
        }
        try {
            & chkntfs.exe "/x" "$($l):" 2>&1 | Out-Null
            Write-Host "  [OK] 已取消 $($l): 的开机自检" -ForegroundColor Green
            Add-StateList -Name 'ChkntfsExcluded' -Items @("$($l):")
        }
        catch {
            Write-Host "  [!!] chkntfs 设置失败: $($l):" -ForegroundColor Yellow
        }
    }
    if ($added.Count -gt 0) {
        Add-StateList -Name 'DefenderExclusions' -Items $added
    }
    if ($lettersClean.Count -eq 0) {
        Write-Host '  [--] 磁盘处于脱机状态，没有盘符，索引/杀软本就不会访问，跳过排除' -ForegroundColor DarkGray
    }
}

# ============================================================
# 状态显示
# ============================================================
function Show-Status {
    Write-Host ''
    Write-Host '========== 当前状态 ==========' -ForegroundColor Cyan
    Write-Host ("SAN 策略      : {0}" -f (Get-SanPolicyName (Get-SanPolicyValue)))
    Write-Host ("自动挂载      : {0}" -f $(if (Get-AutoMountDisabled) { '已禁用（新卷不自动挂载）' } else { '启用' }))
    $task = Get-DefragTask
    if ($task) {
        Write-Host ("优化驱动器任务: {0}" -f $task.State)
    }
    $svc = Get-Service -Name WSearch -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Host ("Windows Search: {0} / {1}" -f $svc.Status, $svc.StartType)
    }
    $st = Read-State
    if ($st) {
        if ($st.DefenderExclusions) {
            Write-Host ("Defender 排除 : {0}" -f (@($st.DefenderExclusions) -join ', '))
        }
        if ($st.ChkntfsExcluded) {
            Write-Host ("取消自检      : {0}" -f (@($st.ChkntfsExcluded) -join ', '))
        }
        if ($st.OfflineDisks) {
            Write-Host ("本工具脱机过的: {0}" -f (@($st.OfflineDisks) -join ', '))
        }
        Write-Host ("最后更新      : {0}" -f $st.UpdatedAt)
    }
    Write-Host ''
    Write-Host '========== 磁盘列表 ==========' -ForegroundColor Cyan
    Show-Disks
}

# ============================================================
# 方案 A
# ============================================================
function Invoke-ModeA {
    Write-Host ''
    Write-Host '===== 方案 A：新接入磁盘默认离线 =====' -ForegroundColor Cyan
    Write-Host '前提：硬盘盒必须还没有插上。' -ForegroundColor Yellow
    Write-Host '执行内容：san policy=offlineall / automount disable / automount scrub' -ForegroundColor DarkGray

    if (-not $Force) {
        $ans = Read-Host '确认执行？(y/N)'
        if ($ans -notmatch '^[Yy]') { Write-Host '已取消。' -ForegroundColor Yellow; return }
    }

    $sanBefore    = Get-SanPolicyValue
    $mountBefore  = Get-AutoMountDisabled

    Invoke-Diskpart @('san policy=offlineall', 'automount disable', 'automount scrub', 'exit') | Out-Null

    Save-State @{
        SanPolicyBefore         = $sanBefore
        AutoMountDisabledBefore = $mountBefore
    }

    Write-Host '  [OK] SAN 策略已设为 OfflineAll' -ForegroundColor Green
    Write-Host '  [OK] 自动挂载已禁用，历史盘符记忆已清理' -ForegroundColor Green

    if (-not $SkipHardening) {
        Enable-Hardening -Letters @()
    }

    Write-Host ''
    Write-Host '现在可以插硬盘盒了：它会在磁盘管理里显示为「脱机」，资源管理器看不到。' -ForegroundColor Cyan
    Write-Host '用完执行 Restore 还原。' -ForegroundColor Cyan
}

# ============================================================
# 方案 B
# ============================================================
function Invoke-ModeB {
    Write-Host ''
    Write-Host '===== 方案 B：指定磁盘立即脱机 =====' -ForegroundColor Cyan

    $n = Resolve-DiskNumber
    if ($null -eq $n) { return }

    $d = Get-Disk -Number $n -ErrorAction Stop
    $sys = Get-SystemDiskNumber
    if ($d.IsBoot -or $d.IsSystem -or $n -eq $sys) {
        Write-Host "磁盘 $n 是系统盘，拒绝操作。" -ForegroundColor Red
        return
    }

    Write-Host ("目标: #{0}  {1}  {2} GB" -f $d.Number, $d.FriendlyName, [math]::Round($d.Size / 1GB, 1))
    if ($d.IsOffline) {
        Write-Host '该磁盘已经是脱机状态。' -ForegroundColor Green
        return
    }

    if (-not $Force) {
        $ans = Read-Host '确认脱机？(y/N)'
        if ($ans -notmatch '^[Yy]') { Write-Host '已取消。' -ForegroundColor Yellow; return }
    }

    Set-DiskOfflineState -Number $n -Offline $true
    Add-StateList -Name 'OfflineDisks' -Items @($n)
    Write-Host "  [OK] 磁盘 $n 已脱机" -ForegroundColor Green
    Write-Host '注意：如果盘在枚举阶段就卡死，这一步只能减少后续读写，无法阻止已经发生的 I/O。' -ForegroundColor Yellow
}

# ============================================================
# 方案 C
# ============================================================
function Invoke-ModeC {
    Write-Host ''
    Write-Host '===== 方案 C：指定磁盘只读联机 =====' -ForegroundColor Cyan
    Write-Host '适合：盘能稳定识别，你想直接往外拷文件。' -ForegroundColor DarkGray

    $n = Resolve-DiskNumber
    if ($null -eq $n) { return }

    $d = Get-Disk -Number $n -ErrorAction Stop
    $sys = Get-SystemDiskNumber
    if ($d.IsBoot -or $d.IsSystem -or $n -eq $sys) {
        Write-Host "磁盘 $n 是系统盘，拒绝操作。" -ForegroundColor Red
        return
    }

    Write-Host ("目标: #{0}  {1}  {2} GB" -f $d.Number, $d.FriendlyName, [math]::Round($d.Size / 1GB, 1))
    if (-not $Force) {
        $ans = Read-Host '确认只读联机？(y/N)'
        if ($ans -notmatch '^[Yy]') { Write-Host '已取消。' -ForegroundColor Yellow; return }
    }

    Set-DiskReadOnlyState -Number $n -ReadOnly $true
    Add-StateList -Name 'ReadOnlyDisks' -Items @($n)
    Write-Host "  [OK] 磁盘 $n 已设为只读" -ForegroundColor Green

    Set-DiskOfflineState -Number $n -Offline $false
    Write-Host "  [OK] 磁盘 $n 已联机（只读）" -ForegroundColor Green

    $letters = @(Get-Partition -DiskNumber $n -ErrorAction SilentlyContinue |
        Where-Object { $_.DriveLetter } |
        ForEach-Object { [string]$_.DriveLetter })

    if ($letters.Count -gt 0) {
        Write-Host ("  [OK] 可见盘符: {0}" -f ($letters -join ', ')) -ForegroundColor Green
    }
    else {
        Write-Host '  [!!] 没有识别到盘符（分区表可能已损坏），需要走 testdisk/photorec' -ForegroundColor Yellow
    }

    if (-not $SkipHardening) {
        Enable-Hardening -Letters $letters
    }
}

# ============================================================
# 还原
# ============================================================
function Invoke-Restore {
    Write-Host ''
    Write-Host '===== 还原所有改动 =====' -ForegroundColor Cyan

    $st = Read-State
    if (-not $st) {
        Write-Host '没有找到本工具的状态记录，只做安全默认还原。' -ForegroundColor Yellow
    }

    if (-not $Force) {
        $ans = Read-Host '确认还原？(y/N)'
        if ($ans -notmatch '^[Yy]') { Write-Host '已取消。' -ForegroundColor Yellow; return }
    }

    # 1. SAN 策略 + 自动挂载
    Invoke-Diskpart @('san policy=onlineall', 'automount enable', 'exit') | Out-Null
    Write-Host '  [OK] SAN 策略恢复为 OnlineAll，自动挂载已启用' -ForegroundColor Green

    # 2. 优化驱动器任务
    if ($st -and $st.DefragTaskWasEnabled -eq $true) {
        Enable-ScheduledTask -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag' -ErrorAction SilentlyContinue | Out-Null
        Write-Host '  [OK] 已重新启用「优化驱动器」任务' -ForegroundColor Green
    }

    # 3. Storage Sense
    if ($st -and $st.StorageSense) {
        foreach ($p in $st.StorageSense.PSObject.Properties) {
            $key = $p.Name
            $val = $p.Value
            if (-not (Test-Path $key)) { continue }
            if ($val -eq '__absent__') {
                Remove-ItemProperty -Path $key -Name '01' -ErrorAction SilentlyContinue
            }
            else {
                Set-ItemProperty -Path $key -Name '01' -Value ([int]$val) -Type DWord -ErrorAction SilentlyContinue
            }
        }
        Write-Host '  [OK] Storage Sense 已恢复' -ForegroundColor Green
    }

    # 4. Windows Search
    if ($st -and $st.WSearchStartBefore -and $null -ne (Get-Service -Name WSearch -ErrorAction SilentlyContinue)) {
        $start = [int]$st.WSearchStartBefore
        switch ($start) {
            2 { Set-Service -Name WSearch -StartupType Automatic -ErrorAction SilentlyContinue }
            3 { Set-Service -Name WSearch -StartupType Manual -ErrorAction SilentlyContinue }
            4 { Set-Service -Name WSearch -StartupType Disabled -ErrorAction SilentlyContinue }
        }
        if ($start -ne 4) {
            Start-Service -Name WSearch -ErrorAction SilentlyContinue
        }
        Write-Host '  [OK] Windows Search 已恢复' -ForegroundColor Green
    }

    # 5. Defender 排除
    if ($st -and $st.DefenderExclusions) {
        $paths = @($st.DefenderExclusions)
        try {
            Remove-MpPreference -ExclusionPath $paths -ErrorAction Stop
            Write-Host ("  [OK] 已移除 Defender 排除: {0}" -f ($paths -join ', ')) -ForegroundColor Green
        }
        catch {
            Write-Host '  [!!] 移除 Defender 排除失败，请手动在安全中心删除。' -ForegroundColor Yellow
        }
    }

    # 6. 开机自检
    if ($st -and $st.ChkntfsExcluded) {
        try {
            & chkntfs.exe "/d" 2>&1 | Out-Null
            Write-Host '  [OK] 已恢复所有卷的默认开机自检设置' -ForegroundColor Green
        }
        catch {
            Write-Host '  [!!] chkntfs /d 执行失败，请手动检查。' -ForegroundColor Yellow
        }
    }

    # 7. 只读标记（脱机状态保持不动，避免把坏盘重新拉上线）
    if ($st -and $st.ReadOnlyDisks) {
        foreach ($n in @($st.ReadOnlyDisks)) {
            try {
                Set-DiskReadOnlyState -Number ([int]$n) -ReadOnly $false
                Write-Host "  [OK] 磁盘 $n 只读标记已清除" -ForegroundColor Green
            }
            catch {
                Write-Host "  [!!] 清除磁盘 $n 只读标记失败" -ForegroundColor Yellow
            }
        }
    }

    Remove-Item -Path $StateFile -Force -ErrorAction SilentlyContinue
    Write-Host ''
    Write-Host '还原完成。脱机的磁盘不会被自动拉上线，需要时请在磁盘管理里手动联机。' -ForegroundColor Cyan
}

# ============================================================
# 磁盘编号解析
# ============================================================
function Resolve-DiskNumber {
    if ($DiskNumber -ge 0) { return $DiskNumber }

    Write-Host ''
    Write-Host '当前磁盘：' -ForegroundColor Cyan
    Show-Disks

    $input = Read-Host '请输入要操作的磁盘编号（直接回车取消）'
    if ([string]::IsNullOrWhiteSpace($input)) { return $null }
    if ($input -notmatch '^\d+$') {
        Write-Host '编号无效。' -ForegroundColor Red
        return $null
    }
    return [int]$input
}

# ============================================================
# 交互菜单
# ============================================================
function Show-Menu {
    while ($true) {
        try { Clear-Host } catch { }
        Write-Host '========================================' -ForegroundColor Cyan
        Write-Host '  DiskGuard - 坏盘安全隔离工具' -ForegroundColor Cyan
        Write-Host '========================================' -ForegroundColor Cyan
        Write-Host ''
        Write-Host '  A   方案A：新接入磁盘默认离线（插盘前执行，最推荐）'
        Write-Host '  B   方案B：把指定磁盘立即脱机（已插上盘的补救）'
        Write-Host '  C   方案C：把指定磁盘只读联机（直接拷文件）'
        Write-Host '  S   查看当前状态'
        Write-Host '  R   还原所有改动'
        Write-Host '  Q   退出'
        Write-Host ''
        $choice = Read-Host '请选择'

        if ([string]::IsNullOrWhiteSpace($choice)) { continue }

        switch ($choice.ToUpper()) {
            'A' { Invoke-ModeA }
            'B' { Invoke-ModeB }
            'C' { Invoke-ModeC }
            'S' { Show-Status }
            'R' { Invoke-Restore }
            'Q' { return }
            default { Write-Host '无效选项。' -ForegroundColor Yellow }
        }

        Write-Host ''
        Read-Host '按回车继续' | Out-Null
    }
}

# ============================================================
# 入口
# ============================================================
if (-not $Mode) {
    Show-Menu
}
else {
    switch ($Mode) {
        'A'       { Invoke-ModeA }
        'B'       { Invoke-ModeB }
        'C'       { Invoke-ModeC }
        'Status'  { Show-Status }
        'Restore' { Invoke-Restore }
    }
}
