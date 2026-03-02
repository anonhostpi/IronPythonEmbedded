$ipy = . "$PSScriptRoot\IronPythonEmbedded.ps1"

# Test: inline
$result = $ipy.Engine.Execute("2 + 2", $ipy.Scope)
Write-Host "Inline: 2+2 = $result" -ForegroundColor Green

# Test: in-memory module via PAL
$ipy.PAL.AddFile("/ipy/testmod.py", [System.Text.Encoding]::UTF8.GetBytes("def add(a,b): return a+b"))
$result = $ipy.Engine.Execute("import testmod; testmod.add(5, 3)", $ipy.Scope)
Write-Host "In-memory import: add(5,3) = $result" -ForegroundColor Green

# Test: stdlib import
$ipy.Engine.Execute("import json", $ipy.Scope)
Write-Host "Stdlib json: OK" -ForegroundColor Green

# Test: check how many entries were lazily cached vs indexed
$cached = $ipy.PAL.GetType().GetField('_cache', [System.Reflection.BindingFlags]::NonPublic -bor [System.Reflection.BindingFlags]::Instance).GetValue($ipy.PAL)
Write-Host "Zip entries indexed: $($ipy.EntryIndex.Count)" -ForegroundColor Cyan
Write-Host "Entries lazily cached: $($cached.Count)" -ForegroundColor Cyan
