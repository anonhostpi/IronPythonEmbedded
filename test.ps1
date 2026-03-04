$builder = . "$PSScriptRoot\IronPythonEmbedded.ps1"

$builder.Load()
$builder.Start()

# Test: inline
$scope = $builder.Engine.CreateScope()
$result = $builder.Engine.Execute("2 + 2", $scope)
Write-Host "Inline: 2+2 = $result" -ForegroundColor Green

# Test: in-memory module via AddFile
$builder.PAL.AddFile("$($builder.VRoot)/testmod.py", [System.Text.Encoding]::UTF8.GetBytes("def add(a,b): return a+b"))
$result = $builder.Engine.Execute("import testmod; testmod.add(5, 3)", $scope)
Write-Host "In-memory import: add(5,3) = $result" -ForegroundColor Green

# Test: stdlib import
$builder.Engine.Execute("import json", $scope)
Write-Host "Stdlib json: OK" -ForegroundColor Green

# Test: CodeMethod callable from PowerShell
# Test: ScriptMethod from PowerShell (PascalCase)
$result = $builder.FindModule("testmod")
Write-Host "FindModule('testmod') from PS: $($null -ne $result)" -ForegroundColor Cyan

# Test: Func NoteProperty from PowerShell (needs .Invoke)
$result2 = $builder.find_module.Invoke("testmod", $null)
Write-Host "find_module.Invoke('testmod') from PS: $($null -ne $result2)" -ForegroundColor Cyan

Write-Host "`nDone" -ForegroundColor Green
