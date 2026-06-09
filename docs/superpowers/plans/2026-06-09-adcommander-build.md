# ADCommander Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build ADCommander — a unified PowerShell AD/Entra admin toolkit combining ADInsight, AD-Health-Checker, and six new admin features.

**Architecture:** Single launcher dot-sources 13 focused modules. Shared Connect-Source and Export-HTML modules serve all features. Four modules are ported from ADInsight unchanged; nine are new. Module auto-install runs before any feature is accessed.

**Tech Stack:** PowerShell 5.1+, ActiveDirectory (RSAT), GroupPolicy (RSAT), Microsoft.Graph SDK, BitLocker (built-in).

---

## Task 1: Git scaffold + Install-Requirements.ps1

- [ ] Init repo and add remote
```bash
cd /project/ADCommander
git init && git config user.email "dallas.milem@gmail.com" && git config user.name "Dallas Milem"
git remote add origin https://github.com/homestead367/ad-commander.git
```

- [ ] Create `Modules/Install-Requirements.ps1`
- [ ] Verify syntax, commit

## Task 2: Connect-Source.ps1
- [ ] Port from ADInsight (identical logic, ADCommander branding)
- [ ] Verify syntax, commit

## Task 3: Export-HTML.ps1
- [ ] Expand from ADInsight — add report types: HealthCheck, StaleAccounts, PasswordExpiry, ComputerSearch, GroupInfo, GroupComparison, PrivilegedAccess
- [ ] Verify syntax, commit

## Task 4: Search-User.ps1 + Compare-Users.ps1 + Get-UserGPO.ps1
- [ ] Port all three from ADInsight unchanged
- [ ] Verify syntax, commit

## Task 5: Invoke-HealthCheck.ps1
- [ ] Build 8 check-category functions + orchestrator
- [ ] Verify syntax, commit

## Task 6: Get-StaleAccounts.ps1 + Get-PasswordExpiry.ps1
- [ ] Build both new modules
- [ ] Verify syntax, commit

## Task 7: Search-Computer.ps1 + Get-GroupInfo.ps1
- [ ] Build both new modules
- [ ] Verify syntax, commit

## Task 8: Invoke-AccountActions.ps1 + Get-PrivilegedAccess.ps1
- [ ] Build both new modules
- [ ] Verify syntax, commit

## Task 9: ADCommander.ps1 launcher + README.md
- [ ] Build launcher with grouped menu, current-user prompt, Install-Requirements call
- [ ] Write README
- [ ] Verify syntax, commit

## Task 10: Final syntax check all files + push
- [ ] pwsh parser check all 14 files
- [ ] git push origin main
