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

#region MARK: Configuration
$config = @{
    Version = "3.4.2"
    VRoot = "/ipy"
    HRoot = $null
    URL = $null
    Local = $null
}
#endregion

#region MARK: Defaults
$config.HRoot = If ([string]::IsNullOrWhiteSpace($config.HRoot)) {
    "$(Resolve-Path "$(Resolve-Path "~")\ipyenv\v$($config.Version)" -ErrorAction SilentlyContinue)"
}
$config.URL = If ([string]::IsNullOrWhiteSpace($config.URL)) {
    "https://github.com/IronLanguages/ironpython3/releases/download/v$(
        $config.Version
    )/IronPython.$(
        $config.Version
    ).zip"
}
$config.Local = If ([string]::IsNullOrWhiteSpace($config.Local)) {
    If(-not [string]::IsNullOrWhiteSpace($config.HRoot)) {
        "$(
            Resolve-Path "$(
                $config.HRoot
            )\IronPython.$(
                $config.Version
            ).zip" -ErrorAction SilentlyContinue
        )"
    }
}
#endregion

#region MARK: NamespacedObject
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
        If (-not [string]::IsNullOrWhiteSpace($Transpiled)){
            Invoke-Expression $Transpiled
        }
        $Transpiled = $null
        Set-Item Function:New-NamespacedObject -Value $NamespacedObjectFactory
        $NamespacedObjectFactory = $null

        . ([scriptblock]::Create((& {
            $shadow_module = $Module
            $Module = $null
            $shadow_module
        }).ToString()))

        Export-ModuleMember
    } -ArgumentList $transpiled, $new_namespaced_object_factory, $Module

    $Properties.GetEnumerator() | ForEach-Object {
        $object | Add-Member -MemberType NoteProperty -Name $_.Name -Value $_.Value
    }

    $sb = @(
        ({ param($Object, $Methods) }.ToString())
        ($Methods.Keys | ForEach-Object {
            "`$Object | Add-Member -MemberType ScriptMethod -Name '$_' -Value {$(
                $Methods."$_"
            )}"
        })
    ) -join "`n"

    $object.Invoke([scriptblock]::Create($sb), $object, $Methods)

    return $object
}
#endregion

#region MARK: PackageSystem Methods
$methods = (& {
    $categories = @{
        Status = @{
            InStore = {
                param(
                    $Stores = ($internal.Keys | ForEach-Object { $_ }),
                    $Key
                )

                foreach($store in $Stores){
                    if ($internal."$store".ContainsKey($Key)) { return $true }
                }
            }
            IsBuiltin = {
                param([string] $Fullname)

                return $this.InStore("Builtins", $Fullname)
            }
            IsLoaded = {
                param([string] $Path)

                return $this.InStore("Loaded", $Path)
            }
            IsPacked = {
                param([string] $Path)

                return $this.InStore("Archived", $Path)
            }
            Exists = {
                param(
                    [string] $Root,
                    [string] $Suffix
                )

                return $this.InStore(@(
                    "Loaded", "Archived"
                ), $this.Join($Root,$Suffix))
            }

            IsInstalled = {
                $internal.Installed
            }
        }
        Getters = @{
            Resolve = {
                param([string] $Path)

                $paths = & {
                    $internal.Loaded.Keys | ForEach-Object { $_ }
                    $internal.Archived.Keys | ForEach-Object { $_ }
                }

                foreach($p in $paths) {
                    If($p -like $Path) { return $p }
                }
            }
            GetBytes = {
                param(
                    [string] $Root,
                    [string] $Suffix
                )

                $path = $this.Join($Root,$Suffix)

                If ($this.IsLoaded($path)) {
                    return ([byte[]] $internal.Loaded[$path])
                }

                If ($this.IsPacked($path)) {
                    $entry = $internal.Archived[$path]

                    $stream = $entry.Open()
                    $ms = [MemoryStream]::new()
                    $stream.CopyTo($ms)

                    $bytes = $ms.ToArray()
                    $stream.Close()

                    $this.SetFile($Root, $Suffix, $bytes)

                    return $bytes
                }

                return $null
            }
            GetString = {
                param(
                    [string] $Root,
                    [string] $Suffix
                )

                $bytes = $this.GetBytes($Root, $Suffix)
                
                If ($null -ne $bytes) {
                    return [Encoding]::UTF8.GetString($bytes)
                }

                return $null
            }
        }
        Helpers = @{
            Normalize = {
                param([string] $Path)

                return $Path.Replace('\', '/')
            }
            Rasterize = {
                param([string] $Fullname)

                return $Fullname.Replace('.', '/')
            }
            Join = {
                param(
                    [string] $Root,
                    [string] $Suffix,
                    $Content
                )

                $normalized_root = $this.Normalize($Root).TrimEnd('/')
                $normalized_suffix = $this.Normalize($Suffix)

                If([string]::IsNullOrWhiteSpace($Root)){
                    $normalized_suffix
                } Else {
                    "$normalized_root/$normalized_suffix"
                }
            }
            GetExternalFileBytes = {
                param([string] $Path)

                return [File]::ReadAllBytes($Path)
            }
            GetExternalURLBytes = {
                param([string] $URL)

                (& {
                    $client = [HttpClient]::new()
                    $client.GetByteArrayAsync($Url).GetAwaiter().GetResult()
                    $client.Dispose() | Out-Null
                })
            }
            GetExternalStreamBytes = {
                param([Stream] $Stream)

                $ms = [System.IO.MemoryStream]::new()
                $stream.CopyTo($ms) | Out-Null
                $ms.ToArray()
            }
            GetExternalBytesAuto = {
                param($Source)
                switch($Source.GetType()) {
                    ([Stream]) {
                        $this.GetExternalStreamBytes($Source)
                    }
                    ([byte[]]) {
                        $Source
                    }
                    ([string]) {
                        $exists = Try {
                            [bool](Test-Path $Source -ErrorAction SilentlyContinue)
                        } Catch { $false }

                        If($exists) {
                            return $this.GetExternalFileBytes($Source)
                        }

                        $has_newlines = $Source.Contains("`r") -or $Source.Contains("`n")
                        $remote = If (-not $has_newlines){
                            switch -Wildcard ($Source) {
                                "http://*"  { $true }
                                "https://*" { $true }
                                default     { $false }
                            }
                        } Else {
                            $false
                        }

                        If ($remote) {
                            return $this.GetExternalURLBytes($Source)
                        }

                        [Encoding]::UTF8.GetBytes($Source)
                    }
                    default {
                        throw "Content must be a Stream object, byte[], a file path, a url, or raw text"
                    }
                }
            }
            GetExternalFileStream = {
                param([string] $Path)

                return [File]::OpenRead($Path)
            }
            GetExternalByteStream = {
                param([byte[]] $Data)

                return [MemoryStream]::new($Data)
            }
            GetExternalURLStream = {
                param([string] $URL)

                (& {
                    $client = [HttpClient]::new()
                    $response = $client.GetAsync($Url, [HttpCompletionOption]::ResponseHeadersRead)
                    $response = $response.GetAwaiter().GetResult()
                    $response.Content.ReadAsStream()
                })
            }
        }
        Adding = @{
            AddArchive = {
                param(
                    [Stream] $Stream,
                    $Prefixes,
                    [string] $Root
                )

                $zip = [ZipArchive]::new($Stream, [ZipArchiveMode]::Read)
                
                foreach($entry in $Zip.Entries) {
                    $normalized_entry_name = $this.Normalize($entry.FullName)
                    If ($normalized_entry_name.EndsWith('/')) { continue }

                    $suffix = $null

                    If ([string]::IsNullOrWhiteSpace($Prefixes)) { 
                        $suffix = $normalized_entry_name
                    } Else {
                        foreach($prefix in $Prefixes){
                            $normalized_prefix = $this.Normalize($prefix).TrimEnd('/')
                            If ($normalized_entry_name -like "$normalized_prefix/*") {
                                $regex_prefix = "^(" + [regex]::Escape($normalized_prefix).Replace('\*','[^/]*').Replace('\?','[^/]') + ")/"
                                If ($normalized_entry_name -match $regex_prefix) {
                                    $suffix = $normalized_entry_name.Substring($Matches[1].Length + 1)
                                }
                                break
                            }
                        }
                    }

                    If ([string]::IsNullOrWhiteSpace($suffix)) { continue }

                    $internal.Archived[$this.Join($Root,$suffix)] = $entry
                }
            }
            SetFile = {
                param(
                    [string] $Root,
                    [string] $Suffix,
                    [byte[]] $Bytes
                )

                $path = $this.Join($Root, $Suffix)

                $internal.Loaded[$path] = $Bytes
                If ($internal.Archived.ContainsKey($path)) {
                    $internal.Archived.Remove($path) | Out-Null
                }
            }
            Add = {
                param($Path, $Content)

                $bytes = $this.GetExternalBytesAuto($Content)
                
                Try {
                    $this.AddArchive(
                        $this.GetExternalByteStream($bytes),
                        $null,
                        $Path
                    )
                } Catch {
                    $this.SetFile($null, $Path, $this.GetExternalBytesAuto($Content))
                }
            }
        }
        Installation = @{
            Install = {
                param([Stream] $Stream)

                $this.AddArchive(
                    $stream,
                    @("lib", $internal.Version),
                    $this.VRoot
                ) | Out-Null
                $internal.Installed = $true
            }
            InstallFromPath = {
                param([string] $Path)
                
                $this.Install($this.GetExternalFileStream($Path))
                $this.Load()
            }
            InstallFromURL = {
                param([string] $URL)

                $this.Install($this.GetExternalURLStream($URL))
                $this.Load()
            }
            InstallFromBytes = {
                param([byte[]] $Data)

                $this.Install($this.GetExternalByteStream($Data))
                $this.Load()
            }
            InstallRemote = {
                $this.InstallFromURL($this.URL)
            }
            InstallLocal = {
                $this.InstallFromPath($this.Local)
            }
            Load = {
                Try {
                    [Python] | Out-Null
                } Catch {
                    $alc = [System.Runtime.Loader.AssemblyLoadContext]::Default
                    foreach($dll in @(
                        "Microsoft.Dynamic.dll"
                        "Microsoft.Scripting.dll"
                        "IronPython.dll"
                        "IronPython.Modules.dll"
                    )) {
                        $bytes = $this.GetBytes($this.VRoot, $dll)
                        $alc.LoadFromStream([MemoryStream]::new($bytes)) | Out-Null
                    }
                }
            }
        }
        Runtime = @{
            Attach = {
                param($Engine)

                $internal.Engine = $Engine
                $internal.Self = $this

                $search_paths = $Engine.GetSearchPaths()

                $paths = @("lib", "lib/site-packages")

                @(
                    @{ Path = $this.VRoot;  Separator = "/" },
                    @{ Path = $this.HRoot;  Separator = [Path]::DirectorySeparatorChar }
                ) | ForEach-Object {
                    $root = $_.Path
                    $sep = $_.Separator
                    $paths | ForEach-Object {
                        $search_paths.Add(@($root, $_) -join $sep) | Out-Null
                    }
                }

                $Engine.SetSearchPaths($search_paths) | Out-Null

                $scope = $Engine.CreateScope()
                $engine.Execute(
                    "import sys, _sre, sre_compile, sre_parse, sre_constants, re",
                    $scope
                ) | Out-Null
                $builtins = $engine.Execute(
                    "[k for k,v in sys.modules.items() if not getattr(v, '__file__', None)]",
                    $scope
                )
                foreach($name in $builtins){
                    $internal.Builtins[$name] = $true
                }

                $internal.Adapter = New-Object psobject
                $internal.Adapter | Add-Member `
                    -MemberType NoteProperty `
                    -Name find_module `
                    -Value ([Func[string, object, object]]{
                        param(
                            [string] $Fullname,
                            $path
                        )

                        if ($internal.Builtins.ContainsKey($Fullname)) {
                            return $null
                        }

                        $normalized_path = $internal.Self.Rasterize($Fullname)

                        foreach($search_root in @(
                            $internal.Self.VRoot,
                            "$($internal.Self.VRoot)/lib",
                            "$($internal.Self.VRoot)/lib/site-packages"
                        )) {
                            foreach($candidate in @(
                                "$normalized_path.py"
                                "$normalized_path/__init__.py"
                            )) {
                                if ($internal.Self.Exists($search_root, $candidate)) {
                                    return $internal.Adapter
                                }
                            }
                        }

                        return $null
                    })
                $internal.LoadScope = $Engine.CreateScope()
                $Engine.Execute("import types, sys", $internal.LoadScope) | Out-Null
                $internal.Adapter | Add-Member `
                    -MemberType NoteProperty `
                    -Name load_module `
                    -Value ([Func[string, object]] {
                        param(
                            [string] $Fullname,
                            $path
                        )

                        $engine = $internal.Engine
                        $scope = $internal.LoadScope
                        $pkgs = $internal.Self

                        $cached = $engine.Execute("sys.modules.get('$Fullname')", $scope)
                        If ($null -ne $cached) {
                            return $cached
                        }

                        $normalized_path = $pkgs.Rasterize($Fullname)

                        foreach($search_root in @(
                            $pkgs.VRoot,
                            "$($pkgs.VRoot)/lib",
                            "$($pkgs.VRoot)/lib/site-packages"
                        )) {
                            foreach($candidate in @(
                                "$normalized_path.py"
                                "$normalized_path/__init__.py"
                            )) {
                                $source = $pkgs.GetString($search_root, $candidate)
                                If ($null -ne $source) {
                                    $is_package = $candidate.EndsWith("__init__.py")

                                    $mod = $engine.Execute(
                                        "types.ModuleType('$Fullname')",
                                        $scope
                                    )

                                    & {

                                        $scope.SetVariable("mod", $mod)
                                        $scope.SetVariable("loader", $internal.Adapter)
                                    } | Out-Null

                                    & {
                                        "mod.__name__ = '$Fullname'"
                                        "mod.__loader__ = loader"

                                        If ($is_package) {
                                            "mod.__package__ = '$Fullname'"
                                            "mod.__path__ = ['$search_root/$normalized_path']"
                                        } Else {
                                            "mod.__package__ = '$Fullname'.rpartition('.')[0]"
                                        }

                                        "sys.modules['$Fullname'] = mod"
                                    } | ForEach-Object {
                                        $engine.Execute($_, $scope)
                                    } | Out-Null

                                    (& {
                                        Try {
                                            $scope.SetVariable("source", $source)
                                            $engine.Execute(
                                                "exec(compile(source, '$Fullname', 'exec'), mod.__dict__)",
                                                $scope
                                            )
                                        } Catch {
                                            $engine.Execute("sys.modules.pop('$Fullname',None)", $Scope)
                                            throw
                                        }
                                    }) | Out-Null

                                    return $mod
                                }
                            }
                        }
                        throw "No module named $Fullname"
                    })

                $scope = $Engine.CreateScope()
                $scope.SetVariable("_importer", $internal.Adapter) | Out-Null

                $inner_adapter = @(
                    "import sys"
                    "sys.meta_path.insert(0, $(
                        "type('Shim',(),{$(
                            @(
                                "'find_module':lambda s,n,p=None:_importer.find_module(n,p)"
                                "'load_module':lambda s,n:_importer.load_module(n)"
                            ) -join ","
                        )})()"
                    ))"
                ) -join "; "

                $Engine.Execute($inner_adapter, $scope) | Out-Null

                $Engine | Add-Member `
                    -MemberType ScriptMethod `
                    -Name "Has" `
                    -Value {
                        param([string] $Path)
                        $internal.Self.Exists($null, $Path)
                    }
                $Engine | Add-Member `
                    -MemberType ScriptMethod `
                    -Name "Add" `
                    -Value {
                        param($Path, $Package)

                        $internal.Self.Add($Path, $Package)
                    }

                return $Engine
            }
        }
    }

    $methods = @{}
    $categories.GetEnumerator() | ForEach-Object {
        # $category = $_.Name
        $additions = $_.Value
        $additions.GetEnumerator() | ForEach-Object {
            $methods."$($_.Name)" = $_.Value
        }
    }
    return $methods
})
#endregion

$builder = New-NamespacedObject `
    -Namespaces "System.Management.Automation", "IronPython.Hosting", "System.IO" `
    -Module {
        $internal = @{
            Factory = $null
        }
    } `
    -Properties @{
        Default = (& {
            $default = @{}

            $config.GetEnumerator() | ForEach-Object {
                If (-not [string]::IsNullOrWhiteSpace($_.Value)) {
                    $default[$_.Name] = $_.Value
                }
            }

            return $default
        })
    } `
    -Methods @{
        Build = {
            param(
                $Zip = $this.Default.Local,
                $URL = $this.Default.URL,
                $VRoot = $this.Default.VRoot,
                $HRoot = $this.Default.HRoot
            )

            $pkgs = & $internal.Factory $Zip $URL $VRoot $HRoot

            $engine = [Python]::CreateEngine()
            return $pkgs.Attach($engine)
        }
    }

$builder.Invoke({
    param($Factory)

    $internal.Factory = $Factory
}, {
    param(
        [string] $Zip,
        [string] $URL,
        [string] $VRoot,
        [string] $HRoot
    )

    $namespaces = @(
        "System.IO", "System.IO.Compression", "System.Text"
        "System.Net.Http"
        "System.Reflection", "IronPython.Hosting"
    )

    $pkgs = New-NamespacedObject `
        -Namespaces $namespaces `
        -Properties @{
            VRoot = $VRoot
            HRoot = $HRoot
            URL = $URL
            Local = $Zip
        } `
        -Module {
            $major = [Environment]::Version.Major
            If($major -eq 9){
                $major = 8
            }

            $internal = @{
                Version = "net$major*"
                Archived = @{}
                Loaded = @{}
                Builtins = @{}
                Engine = $null
                Installed = $false
            }
        } `
        -Methods $methods
    
    Try {
        If (Test-Path $pkgs.Local) {
            $pkgs.InstallLocal()
        } Else {
            throw "Need to download"
        }
    } Catch {
        $pkgs.InstallRemote()
    }

    return $pkgs
})

# --- Lock/internalize exports ---
Export-ModuleMember
# --- Actual export ---
}).Invoke({ $builder })