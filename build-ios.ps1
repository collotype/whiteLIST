$ErrorActionPreference = "Stop"

function Require($cmd, $hint) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Write-Host "Missing: $cmd" -ForegroundColor Red
        Write-Host $hint -ForegroundColor Yellow
        exit 1
    }
}

Require "git" "Install Git for Windows."
Require "gh" "Install GitHub CLI: winget install --id GitHub.cli"

$root = (git rev-parse --show-toplevel 2>$null)
if (-not $root) { throw "Run this script inside the whiteLIST repository." }
Set-Location $root

gh auth status | Out-Host

$branch = (git branch --show-current).Trim()
if (-not $branch) { throw "Cannot determine current branch." }

if (git status --porcelain) {
    throw "Commit/push your changes first. Working tree is not clean."
}

Write-Host "[1/3] Starting iOS build..." -ForegroundColor Cyan
gh workflow run "build-ios.yml" --ref $branch
Start-Sleep -Seconds 4

$runId = gh run list `
    --workflow "build-ios.yml" `
    --branch $branch `
    --limit 1 `
    --json databaseId `
    --jq '.[0].databaseId'

if (-not $runId) { throw "Could not find the GitHub Actions run." }

Write-Host "[2/3] Watching build #$runId..." -ForegroundColor Cyan
gh run watch $runId --exit-status

$dist = Join-Path $root "dist"
if (Test-Path $dist) { Remove-Item $dist -Recurse -Force }
New-Item -ItemType Directory -Path $dist | Out-Null

Write-Host "[3/3] Downloading IPA..." -ForegroundColor Cyan
gh run download $runId --name "OpenFlux-iOS" --dir $dist

$ipa = Get-ChildItem $dist -Filter "*.ipa" -Recurse | Select-Object -First 1
if (-not $ipa) { throw "IPA not found." }

Write-Host ""
Write-Host "DONE" -ForegroundColor Green
Write-Host "IPA: $($ipa.FullName)" -ForegroundColor Green
Write-Host "Sign this IPA with Sideloadly."
