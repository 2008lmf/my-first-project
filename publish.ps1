<#
.SYNOPSIS
    一键把当前目录发布为 GitHub 仓库：建仓 -> 关联 origin -> 提交 -> 推送。

.DESCRIPTION
    首次发布和后续同步都能用。token 只走内存，不会写进 .git/config 或磁盘。

.EXAMPLE
    .\publish.ps1
    # 交互式粘贴 token（不回显），仓库名默认取当前目录名

.EXAMPLE
    .\publish.ps1 -RepoName my-first-project -Visibility public -Description "我的第一个项目"

.NOTES
    需要一个 GitHub Personal Access Token（classic 勾 repo，或 fine-grained 勾
    Administration: Read and write + Contents: Read and write）。
#>
[CmdletBinding()]
param(
    [string]$RepoName,
    [string]$Description = 'My first GitHub project',
    [ValidateSet('public', 'private')]
    [string]$Visibility = 'public',
    [string]$Token,
    [string]$Branch = 'main',
    [switch]$SkipPush
)

# 刻意不用 Stop：git 把进度/警告写到 stderr，调用方一旦用 2>&1 合并流，
# PowerShell 会把原生命令的 stderr 当成错误记录，Stop 模式下会直接终止脚本。
# 所有 git 调用统一走 Invoke-Git，用退出码判断成败。
$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest

function Write-Step { param([string]$Msg) Write-Host "==> $Msg" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Msg) Write-Host "    $Msg" -ForegroundColor DarkGray }

function Invoke-Git {
    param([Parameter(Mandatory)][string[]]$GitArgs, [switch]$Quiet)
    $raw  = & git @GitArgs 2>&1
    $exit = $LASTEXITCODE
    $lines = @($raw | ForEach-Object { $_.ToString() })
    if (-not $Quiet) { $lines | Where-Object { $_.Trim() } | ForEach-Object { Write-Ok $_ } }
    [pscustomobject]@{ Lines = $lines; ExitCode = $exit }
}

# ---------- 0. 定位仓库根 ----------
$root = (Get-Location).Path
if (-not (Test-Path (Join-Path $root '.git'))) {
    Write-Step "git init ($root)"
    $r = Invoke-Git @('init', '-b', $Branch)
    if ($r.ExitCode -ne 0) { throw "git init 失败：$($r.Lines -join ' ')" }
}
if (-not $RepoName) { $RepoName = Split-Path -Leaf $root }
Write-Ok "仓库目录: $root"
Write-Ok "仓库名称: $RepoName"

# ---------- 1. 取 token ----------
if (-not $Token) { $Token = $env:GITHUB_TOKEN }
if (-not $Token) {
    Write-Step '需要 GitHub Personal Access Token'
    Write-Ok '生成地址: https://github.com/settings/tokens/new  （勾选 repo 权限）'
    $secure = Read-Host '粘贴 token 后回车（输入不回显）' -AsSecureString
    $Token  = [System.Net.NetworkCredential]::new('', $secure).Password
}
if ([string]::IsNullOrWhiteSpace($Token)) { throw 'token 为空，已中止。' }

$headers = @{
    Authorization          = "Bearer $Token"
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
    'User-Agent'           = 'publish.ps1'
}

# ---------- 2. 校验 token / 拿到账号 ----------
Write-Step '校验 token'
try {
    $me    = Invoke-RestMethod -Uri 'https://api.github.com/user' -Headers $headers -Method Get
    $owner = $me.login
    Write-Ok "已登录: $owner"
} catch {
    $code = $_.Exception.Response.StatusCode.value__
    throw "token 校验失败 (HTTP $code)。检查是否过期、是否勾了 repo 权限。"
}

# ---------- 3. 创建远端仓库（已存在则复用）----------
Write-Step "创建远端仓库 $owner/$RepoName"
$payload = @{
    name        = $RepoName
    description = $Description
    private     = ($Visibility -eq 'private')
    auto_init   = $false
    has_issues  = $true
    has_wiki    = $false
} | ConvertTo-Json
# PS 5.1 在 ContentType 没有 charset 时按 ASCII 编码请求体，中文描述会变成 "???"。
# 显式转成 UTF-8 字节再发。
$bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($payload)

try {
    $repo = Invoke-RestMethod -Uri 'https://api.github.com/user/repos' -Headers $headers `
        -Method Post -Body $bodyBytes -ContentType 'application/json; charset=utf-8'
    Write-Ok "已创建: $($repo.html_url)"
} catch {
    $code = $_.Exception.Response.StatusCode.value__
    if ($code -eq 422) {
        Write-Ok '同名仓库已存在，直接复用。'
        $repo = Invoke-RestMethod -Uri "https://api.github.com/repos/$owner/$RepoName" -Headers $headers
        # 已有仓库时顺手把描述对齐（同样走 UTF-8 字节）
        $patch = [System.Text.Encoding]::UTF8.GetBytes((@{ description = $Description } | ConvertTo-Json))
        Invoke-RestMethod -Uri "https://api.github.com/repos/$owner/$RepoName" -Headers $headers `
            -Method Patch -Body $patch -ContentType 'application/json; charset=utf-8' | Out-Null
    } else {
        throw "建仓失败 (HTTP $code)"
    }
}

# ---------- 4. 关联 origin（干净 URL，不含 token）----------
$remoteUrl = "https://github.com/$owner/$RepoName.git"
$listRes   = Invoke-Git @('remote') -Quiet
$remotes   = @($listRes.Lines | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($remotes -contains 'origin') {
    Invoke-Git @('remote', 'set-url', 'origin', $remoteUrl) -Quiet | Out-Null
} else {
    Invoke-Git @('remote', 'add', 'origin', $remoteUrl) -Quiet | Out-Null
}
Write-Step "origin -> $remoteUrl"

# ---------- 5. 提交 ----------
Write-Step '暂存并提交'
$hasHead = (Invoke-Git @('rev-parse', '--verify', '--quiet', 'HEAD') -Quiet).ExitCode -eq 0

Invoke-Git @('add', '-A') -Quiet | Out-Null
$staged = (Invoke-Git @('diff', '--cached', '--quiet') -Quiet).ExitCode -ne 0
if ($staged) {
    $msg = if ($hasHead) { 'chore: publish update' } else { 'chore: initial commit' }
    $c = Invoke-Git @('commit', '-m', $msg) -Quiet
    if ($c.ExitCode -ne 0) { throw "提交失败：$($c.Lines -join ' ')" }
    Write-Ok "已提交: $msg"
} else {
    Write-Ok '没有需要提交的改动'
}

# ---------- 6. 推送 ----------
if ($SkipPush) {
    Write-Step '已跳过推送 (-SkipPush)'
} else {
    Write-Step "推送到 $Branch"
    $pushUrl = "https://${Token}@github.com/$owner/$RepoName.git"
    $env:GIT_TERMINAL_PROMPT = '0'   # 认证失败时直接报错，不要卡在弹窗
    $p = Invoke-Git @('push', $pushUrl, "${Branch}:${Branch}")
    if ($p.ExitCode -ne 0) {
        throw @'
推送失败。常见原因：
  1) token 没有 Contents: Read and write 权限
  2) 远端仓库已有提交（网页建仓时勾了 README），先执行：
     git pull --rebase --allow-unrelated-histories origin main
  3) 网络/代理问题
'@
    }

    # 用干净 URL 建立上游跟踪，避免 token 落进 .git/config
    Invoke-Git @('config', "branch.$Branch.remote", 'origin') -Quiet | Out-Null
    Invoke-Git @('config', "branch.$Branch.merge", "refs/heads/$Branch") -Quiet | Out-Null
}

Write-Host ''
Write-Host "完成 -> $($repo.html_url)" -ForegroundColor Green
Write-Host "克隆命令: git clone $remoteUrl" -ForegroundColor DarkGray
