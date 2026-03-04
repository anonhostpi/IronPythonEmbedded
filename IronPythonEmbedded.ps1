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

function Add-NamespacedObject {
    param(
        $Namespaces,
        $Properties,
        $Methods
    )

    $transpiled = foreach($ns in $Namespaces){
        "using namespace $ns"
    }
    $transpiled = $transpiled -join "`n"
    
    $object = New-Module {
        param($Transpiled)
        Invoke-Expression $Transpiled
    } -ArgumentList $transpiled

    $Properties.GetEnumerator() | ForEach-Object {
        $object | Add-Member -MemberType NoteProperty -Name $_.Name -Value $_.Value
    }
    $Methods.GetEnumerator() | ForEach-Object {
        $object | Add-Member -MemberType ScriptMethod -Name $_.Name -Value $_.Value
    }

    return $object
}

$virtual_files = Add-NamespacedObject `
    -Namespaces "System.IO","System.IO.Compression","System.Text" `
    -Properties @{
        Archived = @{}
        Loaded = @{}
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

$builder = New-Object psobject -Property $builder

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
        [System.IO.File]::OpenRead($Path)
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
        [System.IO.MemoryStream]::new($Data)
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

        $norm_name = $virtual_files.Normalize($Fullname)
        
        foreach($module in @(
            "$norm_name.py"
            "$norm_name/__init__.py"
        )) {
            if ($virtual_files.Exists($module, $builder.VRoot)) {
                return $builder
            }
        }
        return $null
    }
    load_module = {
        param([string] $Fullname)

        $norm_name = $virtual_files.Normalize($Fullname)
        
        foreach($module in @(
            "$norm_name.py"
            "$norm_name/__init__.py"
        )) {
            $source = $virtual_files.Get($module, $builder.VRoot)
            if ($null -ne $source) {
                $mod_scope = $builder.Engine.CreateScope()
                $builder.Engine.Execute($source, $mod_scope)

                $sys_scope = $builder.Engine.CreateScope()
                $sys_scope.SetVariable("_mod_scope", $mod_scope)
                $sys_scope.SetVariable("_mod_name", $Fullname)
                $builder.Engine.Execute(
                    "import sys; sys.modules[_mod_name] = _mod_scope", $sys_scope
                )

                return $mod_scope
            }
        }
        throw "No module named $Fullname"
    }
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
