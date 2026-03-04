#Requires -Version 7.0
<#
.SYNOPSIS
    Single-file embeddable IronPython for PowerShell.

.DESCRIPTION
    Pure PowerShell IronPython embedding with:
    - Lazy zip extraction for stdlib and vendored packages
    - In-memory module loading via sys.meta_path
    - No Add-Type / no C# compilation
    - Supports multiple zip sources (local path or URL)
    - Falls back to real filesystem for stdlib

.NOTES
    Requires PowerShell 7+ (pwsh) for .NET Core/.NET 8+ compatibility with IronPython 3.4.x
#>

return (nmo {

# --- Configuration ---
$builder = @{
    Version = "3.4.2"
    VRoot = "/ipy"
    References = @(
        "IronPython.dll"
    )
}

function New-NamespacedObject {
    param(
        $Namespaces,
        $Properties = @(),
        $Methods = @(),
        [scriptblock] $Module = {}
    )

    $transpiled = foreach($ns in $Namespaces){
        "using namespace $ns"
    }
    $transpiled = $transpiled -join "`n"

    $new_namespaced_object_factory = (Get-Item Function:New-NamespacedObject).ScriptBlock
    
    $object = New-Module {
        param($Transpiled, $NamespacedObjectFactory, $Module)
        Invoke-Expression $Transpiled
        $Transpiled = $null
        Set-Item Function:New-NamespacedObject -Value $NamespacedObjectFactory
        $NamespacedObjectFactory = $null

        . (& {
            $shadow_module = $Module
            $Module = $null
            $shadow_module
        })

        Export-ModuleMember
    } -ArgumentList $transpiled, $new_namespaced_object_factory, $Module

    $Properties.GetEnumerator() | ForEach-Object {
        $object | Add-Member -MemberType NoteProperty -Name $_.Name -Value $_.Value
    }
    $Methods.GetEnumerator() | ForEach-Object {
        $object | Add-Member -MemberType ScriptMethod -Name $_.Name -Value $_.Value
    }

    return $object
}

$virtual_files = New-NamespacedObject `
    -Namespaces "System.IO","System.IO.Compression","System.Text" `
    -Properties @{
        Archived = @{}
        Loaded = @{}
        Builtins = @{}
        Runtime = $null
        Initialized = $false
    } `
    -Methods @{
        Normalize = {
            param([string] $Path)

            return $Path.Replace('\', '/')
        }
        AddArchive = {
            param(
                [IO.Stream] $Stream,
                [string]    $Prefix,
                [string]    $VirtualRoot
            )

            $zip = $this.Invoke({
                param([IO.Stream] $Stream)

                [ZipArchive]::new($Stream, [ZipArchiveMode]::Read)
            }, $Stream)

            $norm_prefix    = $this.Normalize($Prefix).TrimEnd('/')
            $norm_root      = $this.Normalize($VirtualRoot).TrimEnd('/')

            foreach ($entry in $Zip.Entries) {
                $norm_path  = $this.Normalize($entry.FullName)
                if ($norm_path.EndsWith('/')) { continue }

                $suffix = $null
                switch("$norm_prefix"){
                    ""                                      { $suffix = $norm_path }
                    { "$norm_path" -like "$norm_prefix/*" } { $suffix = $norm_path.Substring($norm_prefix.Length + 1) }
                    "$norm_path"                            { return }
                    default                                 { return }
                }

                $this.Archived["$norm_root/$suffix"] = $entry
            }
        }
        Load = {
            param(
                [string] $VirtualPath,
                [byte[]] $Bytes
            )

            $this.Loaded[$VirtualPath] = $Bytes
            if( $this.Archived.ContainsKey($VirtualPath) ){
                $this.Archived.Remove($VirtualPath)
            }
        }
        Auto = {
            param(
                [string] $VirtualPath,
                $Content
            )

            $bytes = $this.Invoke({
                param($Content)

                switch($Content.GetType()) {
                    ([byte[]]) {
                        $Content
                    }
                    ([string]) {
                        If (Test-Path $Content) {
                            [File]::ReadAllBytes($Content)
                        } Else {
                            [Encoding]::UTF8.GetBytes($Content)
                        }
                    }
                    default {
                        throw "Content must be byte[], a file path string, or inline text"
                    }
                }
            }, $Content)

            $this.Load($VirtualPath, $bytes)
        }
        Exists = {
            param(
                [string] $Path,
                [string] $Prefix
            )

            $norm_path = $this.Normalize($Path)
            $norm_prefix = $this.Normalize($Prefix).TrimEnd('/')

            If( -not [string]::IsNullOrEmpty($norm_prefix) ){
                $norm_path = "$norm_prefix/$norm_path"
            }
            
            foreach($store in @(
                $this.Loaded,
                $this.Archived
            )) {
                if ($store.ContainsKey($norm_path)) { return $true }
            }
        }
        Get = {
            param(
                [string] $Path,
                [string] $Prefix
            )

            $norm_path = $this.Normalize($Path)
            $norm_prefix = $this.Normalize($Prefix).TrimEnd('/')

            If( -not [string]::IsNullOrEmpty($norm_prefix) ){
                $norm_path = "$norm_prefix/$norm_path"
            }

            $this.Invoke({
                param(
                    $VirtualFiles,
                    [string] $Normalized
                )

                $loaded = $VirtualFiles.Loaded

                If ($loaded.ContainsKey($Normalized)) {
                    return [Encoding]::UTF8.GetString([byte[]] $loaded[$Normalized])
                }
                
                $archived = $VirtualFiles.Archived

                If ($archived.ContainsKey($Normalized)) {
                    [ZipArchiveEntry] $entry = $archived[$Normalized]

                    $stream = $entry.Open()
                    $ms = [MemoryStream]::new()
                    $stream.CopyTo($ms)

                    $bytes = $ms.ToArray()
                    $stream.Close()

                    $VirtualFiles.Load($Normalized, $bytes)

                    return [Encoding]::UTF8.GetString($bytes)
                }

                return $null
            }, $this, $norm_path)
        }
    }

$builder.Engine = $null

$builder = New-NamespacedObject `
    -Namespaces "System.Management.Automation" `
    -Properties $builder

# Dynamic Props
$builder | Add-Member -MemberType ScriptProperty -Name URL -Value {
    return "https://github.com/IronLanguages/ironpython3/releases/download/v$($this.Version)/IronPython.$($this.Version).zip"
}
$builder | Add-Member -MemberType ScriptProperty -Name HRoot -Value {
    "$(Resolve-Path "~")\ipyenv\v$($this.Version)"
}
$builder | Add-Member -MemberType ScriptProperty -Name Zip -Value {
    Join-Path (Split-Path $this.HRoot) "IronPython.$($this.Version).zip"
}

# --- Zip management methods ---

$builder | Add-Member -MemberType ScriptMethod -Name FromPath -Value {
    param(
        [string] $Path,
        [string] $Prefix,
        [string] $VirtualRoot
    )

    return $virtual_files.AddArchive(
        [System.IO.File]::OpenRead($Path),
        $Prefix,
        $VirtualRoot
    )
}

$builder | Add-Member -MemberType ScriptMethod -Name FromUrl -Value {
    param(
        [string] $Url,
        [string] $Prefix,
        [string] $VirtualRoot
    )

    $data = & {
        $client = [System.Net.Http.HttpClient]::new()
        $client.GetByteArrayAsync($Url).GetAwaiter().GetResult()
        $client.Dispose() | Out-Null
    }

    return $this.FromBytes($data, $Prefix, $VirtualRoot)
}

$builder | Add-Member -MemberType ScriptMethod -Name FromBytes -Value {
    param(
        [byte[]] $Data,
        [string] $Prefix,
        [string] $VirtualRoot
    )

    return $virtual_files.AddArchive(
        [System.IO.MemoryStream]::new($Data),
        $Prefix,
        $VirtualRoot
    )
}

$builder | Add-Member -MemberType ScriptMethod -Name From -Value {
    param(
        [string]$Location,
        [string]$Prefix,
        [string]$VirtualRoot
    )

    switch -Wildcard ($Location) {
        "http://*"  {}
        "https://*" {}
        default     { return $this.FromPath($Location, $Prefix, $VirtualRoot) }
    }

    $this.FromUrl($Location, $Prefix, $VirtualRoot)
}

$builder | Add-Member -MemberType ScriptMethod -Name AddFile -Value {
    param(
        [string]$VirtualPath,
        $Content
    )

    $virtual_files.Auto($VirtualPath, $Content)
}

# --- File resolution methods ---

$builder | Add-Member -MemberType ScriptMethod -Name Has -Value {
    param([string]$Path)

    return $virtual_files.Exists($Path)
}

# --- Load assemblies ---

$builder | Add-Member -MemberType ScriptMethod -Name Load -Value {
    param(
        [string]$Zip = $this.Zip,
        [string]$URL = $this.URL,
        [string]$ArchiveRoot = "lib",
        [string]$VirtualRoot = "$($this.VRoot)/lib"
    )

    $virtual_files.Initialized = $true

    $this.References | ForEach-Object {
        [System.Reflection.Assembly]::LoadFrom("$($this.HRoot)\$_") | Out-Null
    }

    if (Test-Path $Zip) {
        $this.FromPath($Zip, $ArchiveRoot, $VirtualRoot)
    } else {
        $this.FromUrl($URL, $ArchiveRoot, $VirtualRoot)
    }
}

# --- Python import adapter ---

$adapter = @{
    find_module = {
        param(
            [string] $Fullname,
            $path
        )

        # Skip modules with C# built-in implementations
        if ($virtual_files.Builtins.ContainsKey($Fullname)) {
            return $null
        }

        $norm_name = $builder.ConvertName($Fullname)

        foreach($search_root in @("$($builder.VRoot)", "$($builder.VRoot)/lib", "$($builder.VRoot)/lib/site-packages")) {
            foreach($candidate in @(
                "$norm_name.py"
                "$norm_name/__init__.py"
            )) {
                if ($virtual_files.Exists($candidate, $search_root)) {
                    return $builder
                }
            }
        }
        return $null
    }
    load_module = {
        param([string] $Fullname)

        $rt = $virtual_files.Runtime

        # Check sys.modules cache
        [void] $rt.SetVariable("_name", $Fullname)
        $cached = $builder.Engine.Execute("sys.modules.get(_name)", $rt)
        if ($null -ne $cached) {
            return $cached
        }

        $norm_name = $builder.ConvertName($Fullname)

        foreach($search_root in @("$($builder.VRoot)", "$($builder.VRoot)/lib", "$($builder.VRoot)/lib/site-packages")) {
            foreach($candidate in @(
                "$norm_name.py"
                "$norm_name/__init__.py"
            )) {
                $source = $virtual_files.Get($candidate, $search_root)
                if ($null -ne $source) {
                    $is_package = $candidate.EndsWith("__init__.py")

                    # Create proper Python module
                    $mod = $builder.Engine.Execute("types.ModuleType(_name)", $rt)
                    [void] $rt.SetVariable("_mod", $mod)
                    [void] $rt.SetVariable("_loader", $builder)

                    # Set module metadata
                    [void] $builder.Engine.Execute("_mod.__name__ = _name", $rt)
                    [void] $builder.Engine.Execute("_mod.__loader__ = _loader", $rt)

                    if ($is_package) {
                        [void] $rt.SetVariable("_path", "$search_root/$norm_name")
                        [void] $builder.Engine.Execute(
                            "_mod.__package__ = _name; _mod.__path__ = [_path]", $rt
                        )
                    } else {
                        [void] $builder.Engine.Execute(
                            "_mod.__package__ = _name.rpartition('.')[0]", $rt
                        )
                    }

                    # Register before executing (prevents circular imports)
                    [void] $builder.Engine.Execute("sys.modules[_name] = _mod", $rt)

                    # Execute source in module namespace
                    [void] $rt.SetVariable("_source", $source)
                    try {
                        [void] $builder.Engine.Execute(
                            "exec(compile(_source, _name, 'exec'), _mod.__dict__)", $rt
                        )
                    } catch {
                        [void] $builder.Engine.Execute("sys.modules.pop(_name, None)", $rt)
                        throw
                    }

                    return $mod
                }
            }
        }
        throw "No module named $Fullname"
    }
}

$builder | Add-Member -MemberType ScriptMethod -Name ConvertName -Value {
    param([string] $Fullname)

    $virtual_files.Normalize($Fullname).Replace('.', '/')
}

# ScriptMethods -- PowerShell-callable (PascalCase)
$builder | Add-Member -MemberType ScriptMethod -Name    FindModule `
    -Value                                              $adapter.find_module

$builder | Add-Member -MemberType ScriptMethod -Name    LoadModule `
    -Value                                              $adapter.load_module

# Func NoteProperties -- Python-callable (snake_case)
$builder | Add-Member -MemberType NoteProperty -Name    find_module `
    -Value ([Func[string, object, object]]              $adapter.find_module)
$builder | Add-Member -MemberType NoteProperty -Name    load_module `
    -Value ([Func[string, object]]                      $adapter.load_module)

# --- Start engine ---

$builder | Add-Member -MemberType ScriptMethod -Name Start -Value {
    & {
        if (-not $virtual_files.Initialized) {
            $this.Load()
        }

        $this.Engine = [IronPython.Hosting.Python]::CreateEngine()
        $search_paths = $this.Engine.GetSearchPaths()

        $paths = @("lib", "lib/site-packages")

        @(
            @{ Path = $this.VRoot;  Separator = "/" },
            @{ Path = $this.HRoot;  Separator = [System.IO.Path]::DirectorySeparatorChar }
        ) | ForEach-Object {
            $root = $_.Path
            $sep = $_.Separator
            $paths | ForEach-Object {
                $search_paths.Add(@($root, $_) -join $sep)
            }
        }

        $this.Engine.SetSearchPaths($search_paths)

        # Collect built-in module names (C# implementations that must not be shadowed by .py files)
        $scope = $builder.Engine.CreateScope()
        $builder.Engine.Execute(
            "import sys, _sre, sre_compile, sre_parse, sre_constants, re",
            $scope
        )
        $builtin_names = $builder.Engine.Execute(
            "[k for k,v in sys.modules.items() if not getattr(v, '__file__', None)]",
            $scope
        )
        $virtual_files.Builtins = @{}
        foreach ($name in $builtin_names) {
            $virtual_files.Builtins[$name] = $true
        }

        # Cache types and sys in a persistent scope (before meta_path registration to avoid recursion)
        $virtual_files.Runtime = $builder.Engine.CreateScope()
        $builder.Engine.Execute("import types, sys", $virtual_files.Runtime)

        # Register on sys.meta_path -- shim normalizes find_module's optional path arg
        $scope = $builder.Engine.CreateScope()
        $scope.SetVariable("_importer", $builder)
        $builder.Engine.Execute("import sys; sys.meta_path.insert(0, type('Shim',(),{'find_module':lambda s,n,p=None:_importer.find_module(n,p),'load_module':lambda s,n:_importer.load_module(n)})())", $scope)
    } | Out-Null
}

# --- Lock/internalize exports ---
Export-ModuleMember
# --- Actual export ---
}).Invoke({ $builder })
