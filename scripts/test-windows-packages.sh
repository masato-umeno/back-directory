#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

sha_a=$(printf a%.0s $(seq 1 64))
sha_b=$(printf b%.0s $(seq 1 64))
render="$ROOT_DIR/scripts/render-windows-packages.sh"

"$render" 9.8.7 "$sha_a" "$sha_b" "$tmpdir/one"
"$render" 9.8.7 "$sha_a" "$sha_b" "$tmpdir/two"
diff -r "$tmpdir/one" "$tmpdir/two"

if "$render" 9.8.7 "$sha_a" not-a-checksum "$tmpdir/bad" 2>/dev/null; then
  echo "render-windows-packages.sh accepted an invalid checksum" >&2
  exit 1
fi

scoop="$tmpdir/one/scoop/back-directory.json"
winget="$tmpdir/one/winget/manifests/m/masato-umeno/back-directory/9.8.7"
choco="$tmpdir/one/chocolatey"

# Every generated file must parse in its own format.
ruby -rjson -ryaml -rrexml/document -e '
  scoop, winget, choco = ARGV
  manifest = JSON.parse(File.read(scoop))
  raise "scoop bin" unless manifest["bin"] == "bd-core.exe"
  raise "scoop arch" unless manifest["architecture"].keys.sort == ["64bit", "arm64"]
  raise "scoop autoupdate" unless manifest["autoupdate"]["architecture"]["64bit"]["url"].include?("/v$version/")

  docs = Dir[File.join(winget, "*.yaml")].sort.map { |f| YAML.safe_load(File.read(f)) }
  raise "winget file count" unless docs.size == 3
  raise "winget types" unless docs.map { |d| d["ManifestType"] }.sort == ["defaultLocale", "installer", "version"]
  docs.each do |d|
    raise "winget id" unless d["PackageIdentifier"] == "masato-umeno.back-directory"
    raise "winget version" unless d["PackageVersion"] == "9.8.7"
  end
  installer = docs.find { |d| d["ManifestType"] == "installer" }
  raise "winget installers" unless installer["Installers"].map { |i| i["Architecture"] } == ["x64", "arm64"]
  raise "winget nested" unless installer["NestedInstallerFiles"][0]["RelativeFilePath"] == "bd-core.exe"

  nuspec = REXML::Document.new(File.read(File.join(choco, "back-directory.nuspec")))
  raise "nuspec version" unless nuspec.elements["package/metadata/version"].text == "9.8.7"
' "$scoop" "$winget" "$choco"

grep -q "releases/download/v9.8.7/bd-core-x86_64-pc-windows-msvc.zip" "$scoop"
grep -q "\"hash\": \"$sha_b\"" "$scoop"
grep -q "InstallerSha256: $(printf '%s' "$sha_a" | tr 'a-f' 'A-F')" "$winget/masato-umeno.back-directory.installer.yaml"
grep -q "Checksum64     = '$sha_a'" "$choco/tools/chocolateyinstall.ps1"

# Package installs must tell the user about the profile line, never write it.
for file in "$scoop" "$winget/masato-umeno.back-directory.locale.en-US.yaml" \
  "$choco/back-directory.nuspec" "$choco/tools/chocolateyinstall.ps1"; do
  grep -q 'Invoke-Expression (& bd-core init powershell | Out-String)' "$file"
done
if grep -rqE 'Add-Content|Set-Content|Out-File|post_install|pre_install' "$tmpdir/one"; then
  echo "Windows packages must not edit the PowerShell profile" >&2
  exit 1
fi

if command -v pwsh >/dev/null 2>&1; then
  BD_PARSE_FILE="$choco/tools/chocolateyinstall.ps1" pwsh -NoProfile -Command '
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($env:BD_PARSE_FILE, [ref]$null, [ref]$errors)
    if ($errors.Count -gt 0) { $errors | ForEach-Object { Write-Error $_ }; exit 1 }
  '
fi
