#!/bin/sh
# Renders the Windows package definitions (Scoop, winget, Chocolatey) for one
# release. The output depends only on the arguments, so the same version and
# checksums always produce the same files.
set -eu

if [ "$#" -ne 4 ]; then
  echo "usage: $0 VERSION WINDOWS_X86_64_SHA256 WINDOWS_ARM64_SHA256 OUTPUT_DIR" >&2
  exit 1
fi

version="$1"
x86_64_sha256="$2"
arm64_sha256="$3"
out_dir="$4"

case "$version" in *[!0-9A-Za-z.-]*|'') echo "invalid version" >&2; exit 1;; esac
for checksum in "$x86_64_sha256" "$arm64_sha256"; do
  case "$checksum" in *[!0-9a-f]*|'') echo "invalid SHA256" >&2; exit 1;; esac
  [ "${#checksum}" -eq 64 ] || { echo "invalid SHA256" >&2; exit 1; }
done
[ -n "$out_dir" ] || { echo "invalid output directory" >&2; exit 1; }

repo_url="https://github.com/masato-umeno/back-directory"
download_url="$repo_url/releases/download/v${version}"
x86_64_zip="bd-core-x86_64-pc-windows-msvc.zip"
arm64_zip="bd-core-aarch64-pc-windows-msvc.zip"
description="Session-scoped directory backtracking for PowerShell, bash, and zsh"
profile_line='Invoke-Expression (& bd-core init powershell | Out-String)'

# winget conventionally stores checksums in upper case.
x86_64_sha256_upper=$(printf '%s' "$x86_64_sha256" | tr 'a-f' 'A-F')
arm64_sha256_upper=$(printf '%s' "$arm64_sha256" | tr 'a-f' 'A-F')

winget_id="masato-umeno.back-directory"
scoop_dir="$out_dir/scoop"
winget_dir="$out_dir/winget/manifests/m/masato-umeno/back-directory/$version"
choco_dir="$out_dir/chocolatey"
mkdir -p "$scoop_dir" "$winget_dir" "$choco_dir/tools"

# Scoop: copy to bucket/back-directory.json in the bucket repository.
cat > "$scoop_dir/back-directory.json" <<EOF
{
    "version": "${version}",
    "description": "${description}",
    "homepage": "${repo_url}",
    "license": "MIT",
    "architecture": {
        "64bit": {
            "url": "${download_url}/${x86_64_zip}",
            "hash": "${x86_64_sha256}"
        },
        "arm64": {
            "url": "${download_url}/${arm64_zip}",
            "hash": "${arm64_sha256}"
        }
    },
    "bin": "bd-core.exe",
    "notes": [
        "bd is a PowerShell function. Add this line to your PowerShell profile (\$PROFILE):",
        "",
        "    ${profile_line}",
        "",
        "Scoop does not edit your profile or delete history in %LOCALAPPDATA%\\\\back-directory."
    ],
    "checkver": "github",
    "autoupdate": {
        "architecture": {
            "64bit": {
                "url": "${repo_url}/releases/download/v\$version/${x86_64_zip}"
            },
            "arm64": {
                "url": "${repo_url}/releases/download/v\$version/${arm64_zip}"
            }
        }
    }
}
EOF

# winget: submit the version directory to microsoft/winget-pkgs.
cat > "$winget_dir/$winget_id.yaml" <<EOF
# yaml-language-server: \$schema=https://aka.ms/winget-manifest.version.1.10.0.schema.json
PackageIdentifier: ${winget_id}
PackageVersion: ${version}
DefaultLocale: en-US
ManifestType: version
ManifestVersion: 1.10.0
EOF

cat > "$winget_dir/$winget_id.installer.yaml" <<EOF
# yaml-language-server: \$schema=https://aka.ms/winget-manifest.installer.1.10.0.schema.json
PackageIdentifier: ${winget_id}
PackageVersion: ${version}
InstallerType: zip
NestedInstallerType: portable
NestedInstallerFiles:
- RelativeFilePath: bd-core.exe
  PortableCommandAlias: bd-core
Commands:
- bd-core
Installers:
- Architecture: x64
  InstallerUrl: ${download_url}/${x86_64_zip}
  InstallerSha256: ${x86_64_sha256_upper}
- Architecture: arm64
  InstallerUrl: ${download_url}/${arm64_zip}
  InstallerSha256: ${arm64_sha256_upper}
ManifestType: installer
ManifestVersion: 1.10.0
EOF

cat > "$winget_dir/$winget_id.locale.en-US.yaml" <<EOF
# yaml-language-server: \$schema=https://aka.ms/winget-manifest.defaultLocale.1.10.0.schema.json
PackageIdentifier: ${winget_id}
PackageVersion: ${version}
PackageLocale: en-US
Publisher: masato-umeno
PublisherUrl: https://github.com/masato-umeno
PublisherSupportUrl: ${repo_url}/issues
PackageName: back-directory
PackageUrl: ${repo_url}
License: MIT
LicenseUrl: ${repo_url}/blob/v${version}/LICENSE
ShortDescription: ${description}
Description: |-
  back-directory (bd) records the directories you visit in each shell session
  and lets you go back N steps with "bd N", cancel the last jump with "bd c",
  and list recent targets with "bd ls".
Moniker: back-directory
Tags:
- cd
- cli
- directory
- navigation
- powershell
- shell
ReleaseNotesUrl: ${repo_url}/releases/tag/v${version}
InstallationNotes: |-
  bd is a PowerShell function. Add this line to your PowerShell profile (\$PROFILE):

      ${profile_line}

  The installer does not edit your profile.
ManifestType: defaultLocale
ManifestVersion: 1.10.0
EOF

# Chocolatey: run "choco pack" in this directory, then "choco push".
cat > "$choco_dir/back-directory.nuspec" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://schemas.microsoft.com/packaging/2015/06/nuspec.xsd">
  <metadata>
    <id>back-directory</id>
    <version>${version}</version>
    <title>back-directory (bd)</title>
    <authors>masato-umeno</authors>
    <owners>masato-umeno</owners>
    <projectUrl>${repo_url}</projectUrl>
    <licenseUrl>${repo_url}/blob/v${version}/LICENSE</licenseUrl>
    <requireLicenseAcceptance>false</requireLicenseAcceptance>
    <projectSourceUrl>${repo_url}</projectSourceUrl>
    <packageSourceUrl>${repo_url}/blob/v${version}/scripts/render-windows-packages.sh</packageSourceUrl>
    <docsUrl>${repo_url}#readme</docsUrl>
    <bugTrackerUrl>${repo_url}/issues</bugTrackerUrl>
    <tags>back-directory bd cd directory navigation powershell cli</tags>
    <summary>${description}</summary>
    <description><![CDATA[back-directory (bd) records the directories you visit in each shell session and lets you go back N steps with \`bd N\`, cancel the last jump with \`bd c\`, and list recent targets with \`bd ls\`.

## Setup

\`bd\` is a PowerShell function. After installing, add this line to your PowerShell profile (\`\$PROFILE\`):

    ${profile_line}

The package does not edit your profile, and uninstalling it keeps your history in \`%LOCALAPPDATA%\\back-directory\`.

This package installs the 64-bit (x64) build.]]></description>
    <releaseNotes>${repo_url}/releases/tag/v${version}</releaseNotes>
  </metadata>
  <files>
    <file src="tools\\**" target="tools" />
  </files>
</package>
EOF

cat > "$choco_dir/tools/chocolateyinstall.ps1" <<EOF
\$ErrorActionPreference = 'Stop'

\$toolsDir = Split-Path -Parent \$MyInvocation.MyCommand.Definition

\$packageArgs = @{
  PackageName    = \$env:ChocolateyPackageName
  UnzipLocation  = \$toolsDir
  Url64bit       = '${download_url}/${x86_64_zip}'
  Checksum64     = '${x86_64_sha256}'
  ChecksumType64 = 'sha256'
}

Install-ChocolateyZipPackage @packageArgs

Write-Host ''
Write-Host 'bd is a PowerShell function. Add this line to your PowerShell profile (\$PROFILE):'
Write-Host ''
Write-Host '    ${profile_line}'
Write-Host ''
Write-Host 'Chocolatey does not edit your profile.'
EOF
