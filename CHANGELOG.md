# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog, and this project adheres to
Semantic Versioning.

## [Unreleased]

- Add a Homebrew formula that installs prebuilt release binaries; it does not edit shell
  rc files.
- Add Windows support: `bd-core` builds for Windows (x64 and ARM64) and stores state in
  `%LOCALAPPDATA%\back-directory`, and a PowerShell wrapper (`scripts/bd.ps1`) supports
  Windows PowerShell 5.1 and PowerShell 7+.
- Add `bd-core init powershell`, which prints the PowerShell wrapper for a one-line
  profile setup.
- Add Scoop, winget, and Chocolatey package definitions rendered from release assets;
  they do not edit the PowerShell profile.
- Add a Nix flake with a pinned development shell and `nix flake check`.
- Reject unexpected arguments to `bd optimize` and `bd vacuum` in the wrappers.
- Fix the wrappers leaving the next directory change unrecorded after a failed `cd`.
- Run one shared check script (`scripts/check.sh`) locally and in CI.
- Delete the events and undo moves of sessions removed by retention cleanup.

## [0.1.2] - 2026-01-03

- Fix `doctor --json` output to avoid trailing commas in JSON.
- Prevent `install.sh` from appending duplicate shell `source` lines.
- Clarify uninstall steps to remove `bd-core` rather than `bd`.

## [0.1.1] - 2026-01-02

- Fix bash wrapper always showing help due to a malformed test.

## [0.1.0] - 2026-01-02

- Initial public release.
