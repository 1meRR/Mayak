[CmdletBinding()]
param(
    [string]$ProjectRoot = ".",
    [string]$OutputFile = ".\full_project_dump.txt",
    [ValidateSet("list", "skip", "base64")]
    [string]$BinaryMode = "list",
    [int]$MaxBase64FileSizeMB = 10,
    [switch]$IncludeHidden,
    [switch]$NoDefaultExcludes
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

try {
    Add-Type -AssemblyName System.Text.Encoding.CodePages | Out-Null
} catch {
}

try {
    [System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance)
} catch {
}

function Get-AbsPath {
    param([string]$PathValue)
    return [System.IO.Path]::GetFullPath($PathValue)
}

function New-Utf8NoBomWriter {
    param([string]$Path)
    $dir = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $enc = New-Object System.Text.UTF8Encoding($false)
    return New-Object System.IO.StreamWriter($Path, $false, $enc)
}

function Get-RelativePathSafe {
    param(
        [string]$BasePath,
        [string]$TargetPath
    )
    $baseUri = New-Object System.Uri(($BasePath.TrimEnd('\') + '\'))
    $targetUri = New-Object System.Uri($TargetPath)
    $relativeUri = $baseUri.MakeRelativeUri($targetUri)
    $relative = [System.Uri]::UnescapeDataString($relativeUri.ToString())
    return ($relative -replace '/', '\')
}

function Test-IsHiddenItem {
    param([System.IO.FileSystemInfo]$Item)
    return (($Item.Attributes -band [System.IO.FileAttributes]::Hidden) -ne 0)
}

function Get-DefaultExcludedDirs {
    return @(
        ".git",
        ".svn",
        ".hg",
        ".idea",
        ".vs",
        ".vscode",
        "node_modules",
        "target",
        "dist",
        "build",
        "out",
        "bin",
        "obj",
        "__pycache__",
        ".pytest_cache",
        ".mypy_cache",
        ".ruff_cache",
        ".next",
        ".nuxt",
        ".venv",
        "venv",
        "env",
        ".dart_tool",
        ".gradle",
        ".terraform",
        ".cache",
        ".sass-cache",
        "coverage"
    )
}

function Test-ExcludeDir {
    param([System.IO.DirectoryInfo]$Dir)

    if (-not $IncludeHidden.IsPresent -and (Test-IsHiddenItem $Dir)) {
        return $true
    }

    if (-not $NoDefaultExcludes.IsPresent) {
        foreach ($name in (Get-DefaultExcludedDirs)) {
            if ($Dir.Name -ieq $name) {
                return $true
            }
        }
    }

    return $false
}

function Test-ExcludeFile {
    param(
        [System.IO.FileInfo]$File,
        [string]$ResolvedOutputFile
    )

    if ($File.FullName -ieq $ResolvedOutputFile) {
        return $true
    }

    if (-not $IncludeHidden.IsPresent -and (Test-IsHiddenItem $File)) {
        return $true
    }

    return $false
}

function Get-TextEncodingGuess {
    param([byte[]]$Bytes)

    if ($Bytes.Length -ge 3) {
        if ($Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
            return "utf8bom"
        }
    }

    if ($Bytes.Length -ge 2) {
        if ($Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) {
            return "utf16le"
        }
        if ($Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) {
            return "utf16be"
        }
    }

    return ""
}

function Test-IsProbablyBinary {
    param([byte[]]$Bytes)

    if ($Bytes.Length -eq 0) {
        return $false
    }

    $sampleSize = [Math]::Min($Bytes.Length, 8192)
    $nullCount = 0
    $controlCount = 0

    for ($i = 0; $i -lt $sampleSize; $i++) {
        $b = $Bytes[$i]

        if ($b -eq 0) {
            $nullCount++
            continue
        }

        if (($b -lt 9) -or (($b -gt 13) -and ($b -lt 32))) {
            $controlCount++
        }
    }

    if ($nullCount -gt 0) {
        return $true
    }

    $ratio = $controlCount / [double]$sampleSize
    return ($ratio -gt 0.30)
}

function Try-DecodeBytes {
    param([byte[]]$Bytes)

    $encodings = New-Object System.Collections.Generic.List[object]
    $sig = Get-TextEncodingGuess $Bytes

    if ($sig -eq "utf8bom") {
        $encodings.Add([PSCustomObject]@{
            Name = "UTF-8 BOM"
            Encoding = New-Object System.Text.UTF8Encoding($true, $true)
        })
    }

    if ($sig -eq "utf16le") {
        $encodings.Add([PSCustomObject]@{
            Name = "UTF-16 LE"
            Encoding = New-Object System.Text.UnicodeEncoding($false, $true, $true)
        })
    }

    if ($sig -eq "utf16be") {
        $encodings.Add([PSCustomObject]@{
            Name = "UTF-16 BE"
            Encoding = New-Object System.Text.UnicodeEncoding($true, $true, $true)
        })
    }

    $encodings.Add([PSCustomObject]@{
        Name = "UTF-8"
        Encoding = New-Object System.Text.UTF8Encoding($false, $true)
    })

    try {
        $enc1251 = [System.Text.Encoding]::GetEncoding(
            1251,
            [System.Text.EncoderFallback]::ExceptionFallback,
            [System.Text.DecoderFallback]::ExceptionFallback
        )
        $encodings.Add([PSCustomObject]@{
            Name = "Windows-1251"
            Encoding = $enc1251
        })
    } catch {
    }

    try {
        $encodings.Add([PSCustomObject]@{
            Name = "System ANSI"
            Encoding = [System.Text.Encoding]::Default
        })
    } catch {
    }

    $seen = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($item in $encodings) {
        if ($seen.Contains($item.Name)) {
            continue
        }

        [void]$seen.Add($item.Name)

        try {
            $text = $item.Encoding.GetString($Bytes)
            if ($text.Contains([char]0xFFFD)) {
                continue
            }

            return [PSCustomObject]@{
                Success = $true
                EncodingName = $item.Name
                Text = $text
            }
        } catch {
        }
    }

    return [PSCustomObject]@{
        Success = $false
        EncodingName = ""
        Text = $null
    }
}

function Get-FileDumpContent {
    param([System.IO.FileInfo]$File)

    try {
        $bytes = [System.IO.File]::ReadAllBytes($File.FullName)
    } catch {
        return [PSCustomObject]@{
            Kind = "error"
            EncodingName = ""
            Content = "ERROR: Failed to read file bytes. $($_.Exception.Message)"
        }
    }

    if ($bytes.Length -eq 0) {
        return [PSCustomObject]@{
            Kind = "text"
            EncodingName = "empty"
            Content = ""
        }
    }

    if (Test-IsProbablyBinary $bytes) {
        if ($BinaryMode -eq "skip") {
            return [PSCustomObject]@{
                Kind = "binary"
                EncodingName = ""
                Content = "[BINARY FILE SKIPPED]"
            }
        }

        if ($BinaryMode -eq "list") {
            return [PSCustomObject]@{
                Kind = "binary"
                EncodingName = ""
                Content = "[BINARY FILE]"
            }
        }

        if ($BinaryMode -eq "base64") {
            $maxBytes = $MaxBase64FileSizeMB * 1MB
            if ($bytes.Length -gt $maxBytes) {
                return [PSCustomObject]@{
                    Kind = "binary"
                    EncodingName = ""
                    Content = "[BINARY FILE TOO LARGE FOR BASE64: $($bytes.Length) bytes]"
                }
            }

            return [PSCustomObject]@{
                Kind = "base64"
                EncodingName = "base64"
                Content = [System.Convert]::ToBase64String($bytes)
            }
        }
    }

    $decoded = Try-DecodeBytes $bytes
    if ($decoded.Success) {
        return [PSCustomObject]@{
            Kind = "text"
            EncodingName = $decoded.EncodingName
            Content = $decoded.Text
        }
    }

    if ($BinaryMode -eq "base64") {
        $maxBytes = $MaxBase64FileSizeMB * 1MB
        if ($bytes.Length -le $maxBytes) {
            return [PSCustomObject]@{
                Kind = "base64"
                EncodingName = "base64"
                Content = [System.Convert]::ToBase64String($bytes)
            }
        }
    }

    return [PSCustomObject]@{
        Kind = "unknown"
        EncodingName = ""
        Content = "[FAILED TO DECODE AS TEXT]"
    }
}

function Add-Tree {
    param(
        [System.IO.DirectoryInfo]$Directory,
        [string]$Prefix,
        [System.Collections.Generic.List[string]]$Collector,
        [string]$ResolvedOutputFile
    )

    $dirs = @()
    $files = @()

    try {
        foreach ($d in (Get-ChildItem -LiteralPath $Directory.FullName -Directory -Force | Sort-Object Name)) {
            if (-not (Test-ExcludeDir $d)) {
                $dirs += $d
            }
        }

        foreach ($f in (Get-ChildItem -LiteralPath $Directory.FullName -File -Force | Sort-Object Name)) {
            if (-not (Test-ExcludeFile $f $ResolvedOutputFile)) {
                $files += $f
            }
        }
    } catch {
        $Collector.Add($Prefix + "\-- [ACCESS DENIED OR ERROR]")
        return
    }

    $items = @()
    $items += $dirs
    $items += $files

    for ($i = 0; $i -lt $items.Count; $i++) {
        $item = $items[$i]
        $isLast = ($i -eq ($items.Count - 1))
        $branch = if ($isLast) { "\-- " } else { "+-- " }
        $nextPrefix = if ($isLast) { $Prefix + "    " } else { $Prefix + "|   " }

        if ($item -is [System.IO.DirectoryInfo]) {
            $Collector.Add($Prefix + $branch + $item.Name + "\")
            Add-Tree -Directory $item -Prefix $nextPrefix -Collector $Collector -ResolvedOutputFile $ResolvedOutputFile
        } else {
            $Collector.Add($Prefix + $branch + $item.Name)
        }
    }
}

function Get-TreeLines {
    param(
        [string]$RootPath,
        [string]$ResolvedOutputFile
    )

    $result = New-Object System.Collections.Generic.List[string]
    $result.Add(".")
    $rootDir = Get-Item -LiteralPath $RootPath
    Add-Tree -Directory $rootDir -Prefix "" -Collector $result -ResolvedOutputFile $ResolvedOutputFile
    return $result
}

function Get-AllFiles {
    param(
        [string]$RootPath,
        [string]$ResolvedOutputFile
    )

    $result = New-Object System.Collections.Generic.List[System.IO.FileInfo]

    function Walk {
        param([System.IO.DirectoryInfo]$Dir)

        try {
            foreach ($f in (Get-ChildItem -LiteralPath $Dir.FullName -File -Force | Sort-Object Name)) {
                if (-not (Test-ExcludeFile $f $ResolvedOutputFile)) {
                    $result.Add($f)
                }
            }
        } catch {
        }

        try {
            foreach ($d in (Get-ChildItem -LiteralPath $Dir.FullName -Directory -Force | Sort-Object Name)) {
                if (-not (Test-ExcludeDir $d)) {
                    Walk $d
                }
            }
        } catch {
        }
    }

    $rootDir = Get-Item -LiteralPath $RootPath
    Walk $rootDir
    return ($result | Sort-Object FullName)
}

$projectRootResolved = Get-AbsPath $ProjectRoot
$outputFileResolved = Get-AbsPath $OutputFile

$writer = New-Utf8NoBomWriter $outputFileResolved

try {
    $writer.WriteLine(("=" * 120))
    $writer.WriteLine("PROJECT DUMP")
    $writer.WriteLine(("=" * 120))
    $writer.WriteLine("Generated: " + (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))
    $writer.WriteLine("Project  : " + $projectRootResolved)
    $writer.WriteLine("Output   : " + $outputFileResolved)
    $writer.WriteLine("BinaryMode: " + $BinaryMode)
    $writer.WriteLine("IncludeHidden: " + $IncludeHidden.IsPresent)
    $writer.WriteLine("NoDefaultExcludes: " + $NoDefaultExcludes.IsPresent)
    $writer.WriteLine("")

    $writer.WriteLine(("=" * 120))
    $writer.WriteLine("DIRECTORY TREE")
    $writer.WriteLine(("=" * 120))
    foreach ($line in (Get-TreeLines -RootPath $projectRootResolved -ResolvedOutputFile $outputFileResolved)) {
        $writer.WriteLine($line)
    }
    $writer.WriteLine("")

    $allFiles = Get-AllFiles -RootPath $projectRootResolved -ResolvedOutputFile $outputFileResolved

    $writer.WriteLine(("=" * 120))
    $writer.WriteLine("FILES INDEX")
    $writer.WriteLine(("=" * 120))
    $index = 0
    foreach ($file in $allFiles) {
        $index++
        $rel = Get-RelativePathSafe -BasePath $projectRootResolved -TargetPath $file.FullName
        $writer.WriteLine(("[{0}] {1} ({2} bytes)" -f $index, $rel, $file.Length))
    }
    $writer.WriteLine("TOTAL FILES: " + $index)
    $writer.WriteLine("")

    $current = 0
    foreach ($file in $allFiles) {
        $current++
        $rel = Get-RelativePathSafe -BasePath $projectRootResolved -TargetPath $file.FullName
        $info = Get-FileDumpContent $file

        $writer.WriteLine(("=" * 120))
        $writer.WriteLine(("FILE {0}/{1}: {2}" -f $current, $index, $rel))
        $writer.WriteLine(("=" * 120))
        $writer.WriteLine("FullPath   : " + $file.FullName)
        $writer.WriteLine("SizeBytes  : " + $file.Length)
        $writer.WriteLine("Created    : " + $file.CreationTime.ToString("yyyy-MM-dd HH:mm:ss"))
        $writer.WriteLine("Modified   : " + $file.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss"))
        $writer.WriteLine("Attributes : " + $file.Attributes.ToString())

        if ($info.EncodingName -ne "") {
            $writer.WriteLine("Encoding   : " + $info.EncodingName)
        } else {
            $writer.WriteLine("Encoding   : ")
        }

        $writer.WriteLine("ContentType: " + $info.Kind)
        $writer.WriteLine("----- BEGIN CONTENT -----")
        $writer.WriteLine($info.Content)
        $writer.WriteLine("----- END CONTENT -----")
        $writer.WriteLine("")
        $writer.Flush()
    }

    $writer.WriteLine(("=" * 120))
    $writer.WriteLine("SUMMARY")
    $writer.WriteLine(("=" * 120))
    $writer.WriteLine("Files dumped: " + $index)
    $writer.WriteLine("Finished    : " + (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))
    $writer.Flush()
}
finally {
    $writer.Dispose()
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host "Dump file: $outputFileResolved" -ForegroundColor Green
