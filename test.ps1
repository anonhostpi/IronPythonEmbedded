$ipy = . "$PSScriptRoot\IronPythonEmbedded.ps1"

# Test: inline
$result = $ipy.Engine.Execute("2 + 2", $ipy.Scope)
Write-Host "Inline: 2+2 = $result" -ForegroundColor Green

# Test: in-memory module via AddFile
$ipy.PAL.AddFile("/ipy/testmod.py", [System.Text.Encoding]::UTF8.GetBytes("def add(a,b): return a+b"))
$result = $ipy.Engine.Execute("import testmod; testmod.add(5, 3)", $ipy.Scope)
Write-Host "In-memory import: add(5,3) = $result" -ForegroundColor Green

# Test: stdlib import
$ipy.Engine.Execute("import json", $ipy.Scope)
Write-Host "Stdlib json: OK" -ForegroundColor Green

# Test: add another zip (e.g. a vendored package)
# $ipy.PAL.AddZipFromPath("path/to/ruamel.yaml.whl", "ruamel", "/ipy/lib/site-packages/ruamel")
Write-Host "AddZipFromPath/AddZipFromUrl/AddZipFromBytes available for extension" -ForegroundColor Cyan
