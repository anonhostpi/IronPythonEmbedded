# IronPythonEmbedded

Single-file embeddable IronPython for PowerShell 7+.

## Features

- Pure PowerShell — no `Add-Type` / no C# compilation
- Lazy zip extraction for stdlib and vendored packages
- In-memory module loading via `sys.meta_path`
- Automatic download of IronPython 3.4.2 if not available locally
- Add modules at runtime from files, URLs, zip archives, or raw strings

## Requirements

- PowerShell 7+ (pwsh)
- .NET 8+ runtime

## Quick Start

```powershell
$builder = . "./IronPythonEmbedded.ps1"
$engine = $builder.Build()

$scope = $engine.CreateScope()
$engine.Execute("2 + 2", $scope)  # => 4
```

## Usage

### Inline Execution

```powershell
$scope = $engine.CreateScope()
$result = $engine.Execute("2 + 2", $scope)
```

### Stdlib Imports

Stdlib modules are loaded from the IronPython zip — no disk extraction needed:

```powershell
$engine.Execute("import json", $scope)
$result = $engine.Execute("json.dumps({'key': 'value'})", $scope)
```

### In-Memory Modules

Add Python modules at runtime without writing to disk:

```powershell
$engine.Add("/ipy/mymod.py", "def greet(name): return f'Hello, {name}!'")
$engine.Execute("import mymod", $scope)
$result = $engine.Execute("mymod.greet('World')", $scope)
```

The `Add` method accepts file paths, URLs, byte arrays, zip archives, or raw source strings.

### Check Module Existence

```powershell
$engine.Has("/ipy/mymod.py")  # => $true
```

## Configuration

Edit the `$config` block at the top of `IronPythonEmbedded.ps1`:

```powershell
$config = @{
    Version = "3.4.2"       # IronPython version
    VRoot   = "/ipy"        # Virtual root path for in-memory files
    HRoot   = $null         # Host root (defaults to ~/ipyenv/v<version>)
    URL     = $null         # Download URL (defaults to GitHub releases)
    Local   = $null         # Local zip path (defaults to $HRoot/IronPython.<version>.zip)
}
```

## Tests

```powershell
pwsh -File test.ps1
```
