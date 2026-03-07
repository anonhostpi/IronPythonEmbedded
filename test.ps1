$builder = . "$PSScriptRoot\IronPythonEmbedded.ps1"
$engine = $builder.Build()

# Test: inline
$scope = $engine.CreateScope()
$result = $engine.Execute("2 + 2", $scope)
Write-Host "Inline: 2+2 = $result" -ForegroundColor Green

# Test: stdlib import
$engine.Execute("import json", $scope)
Write-Host "Stdlib json: OK" -ForegroundColor Green

# Test: stdlib with actual usage
$result = $engine.Execute("json.dumps({chr(97): 1, chr(98): 2})", $scope)
Write-Host "json.dumps: $result" -ForegroundColor Green

# Test: stdlib package with submodules
$engine.Execute("import os.path", $scope)
Write-Host "os.path: OK" -ForegroundColor Green

# Test: in-memory module via Add
$engine.Add("/ipy/testmod.py", "def add(a,b): return a+b")
$engine.Execute("import testmod", $scope)
$result = $engine.Execute("testmod.add(5, 3)", $scope)
Write-Host "In-memory import: add(5,3) = $result" -ForegroundColor Green

Write-Host "`nDone" -ForegroundColor Green
