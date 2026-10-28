# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

A personal learning repo, to be published on GitHub, for exploring Azure and related technologies. The owner is a technical consultant who learns as a student architect. The goal is understanding the work, not just shipping it.

## How to work with the user

- **Be concise and instructive.** Short explanations, no padding.
- **Teach while doing.** Before running a command or writing code, say in a line or two what it does and why. Name the tool, the important flags, and the alternatives an architect should know about.
- **Show your work.** Run commands visibly instead of hiding them in scripts, so the user can learn them and repeat them.
- **Build independence.** Explain the pattern behind a solution so the user can write the next one themselves. Point to the official docs (Microsoft Learn, the Azure Architecture Center, tool docs) for further reading.
- **Use current guidance.** Check the latest Microsoft and vendor documentation before recommending an approach. Call out anything deprecated, superseded or in preview. Frame choices in Well-Architected Framework terms (reliability, security, cost, operational excellence, performance).
- **Explain architectural trade-offs** when there is a real choice, and give a recommendation.

## Tooling

- **Prefer PowerShell** (`pwsh`) for commands and examples. Use other shells only when a tool requires them.
- **Keep tools current.** Before giving instructions that depend on a tool (git, gh, az, bicep, terraform, dotnet, node, etc.), check its installed version. If it's outdated or missing, say so and **offer to show update/install instructions first**, before continuing with the original instructions. Prefer `winget` for installs and upgrades.
- PowerShell 7 is installed as the **MSIX** package (per-user). Use `-Scope CurrentUser` for settings and modules. The MSI was deliberately not chosen because inbound remoting and all-users configuration aren't needed.

## Repository layout

Not established yet. Each technology or experiment should live in its own top-level folder with a short README covering what it demonstrates and how to run it. Update this section once the structure exists.

## Environment

- Windows 11; PowerShell 7 and Git Bash are both available.
