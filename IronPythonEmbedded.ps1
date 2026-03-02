#Requires -Version 7.0
<#
.SYNOPSIS
    Single-file embeddable IronPython for PowerShell.
    Downloads IronPython release zip, loads DLLs and stdlib in-memory,
    and provides a custom PlatformAdaptationLayer for disk-free module imports.

.DESCRIPTION
    This script:
    1. Downloads the IronPython release zip into memory (or uses a cached copy)
    2. Loads IronPython.dll, Microsoft.Scripting.dll, Microsoft.Dynamic.dll via [Assembly]::Load(byte[])
    3. Populates an in-memory file index (Hashtable of path -> byte[]) from the stdlib zip
    4. Compiles a custom PlatformAdaptationLayer via Add-Type that serves files from memory
    5. Registers a Python sys.meta_path importer that uses the PAL for module loading
    6. Returns a configured ScriptEngine ready to execute Python code

.NOTES
    Requires PowerShell 7+ (pwsh) for .NET Core/.NET 8+ compatibility with IronPython 3.4.x
#>

# TODO: Download IronPython release zip into memory
# $ipyZipBytes = (Invoke-WebRequest -Uri $releaseUrl).Content
# $ipyZip = [System.IO.Compression.ZipArchive]::new([System.IO.MemoryStream]::new($ipyZipBytes))

# TODO: Extract DLLs from zip and load via [Assembly]::Load(byte[])
# For now, load from disk install for development
$ipyRoot = "$env:USERPROFILE\ipyenv\v3.4.2"
[System.Reflection.Assembly]::LoadFrom("$ipyRoot\Microsoft.Scripting.dll") | Out-Null
[System.Reflection.Assembly]::LoadFrom("$ipyRoot\Microsoft.Dynamic.dll") | Out-Null
[System.Reflection.Assembly]::LoadFrom("$ipyRoot\IronPython.dll") | Out-Null

# --- Compile InMemoryPAL via Add-Type ---
# Uses Hashtable/ArrayList instead of Dictionary<>/List<> to avoid
# generic type forwarding issues across .NET version boundaries.
# -IgnoreWarnings demotes CS1701 assembly version warnings to non-fatal.

$runtimeDir = [System.IO.Path]::GetDirectoryName([object].Assembly.Location)
$coreLib = [object].Assembly.Location

Add-Type -WarningAction SilentlyContinue -IgnoreWarnings -ReferencedAssemblies @(
    "$ipyRoot\Microsoft.Scripting.dll"
    "$ipyRoot\Microsoft.Dynamic.dll"
    $coreLib
    "$runtimeDir\System.Linq.dll"
    "$runtimeDir\System.Collections.dll"
    "$runtimeDir\System.Collections.NonGeneric.dll"
    "$runtimeDir\System.Runtime.dll"
    "$runtimeDir\System.IO.dll"
) -TypeDefinition @'
using System;
using System.IO;
using System.Collections;
using System.Linq;
using Microsoft.Scripting;

public class InMemoryPAL : PlatformAdaptationLayer {
    private Hashtable _files;

    public InMemoryPAL(Hashtable files) {
        _files = files;
    }

    private string Norm(string path) {
        return path.Replace("\\", "/");
    }

    public override bool FileExists(string path) {
        return _files.ContainsKey(Norm(path)) || base.FileExists(path);
    }

    public override Stream OpenFileStream(string path, FileMode mode, FileAccess access, FileShare share, int bufferSize) {
        string n = Norm(path);
        if (_files.ContainsKey(n)) {
            return new MemoryStream((byte[])_files[n], false);
        }
        return base.OpenFileStream(path, mode, access, share, bufferSize);
    }

    public override bool DirectoryExists(string path) {
        string prefix = Norm(path).TrimEnd('/') + "/";
        foreach (string key in _files.Keys) {
            if (key.StartsWith(prefix)) return true;
        }
        return base.DirectoryExists(path);
    }

    public override string[] GetFileSystemEntries(string path, string searchPattern, bool includeFiles, bool includeDirectories) {
        string prefix = Norm(path).TrimEnd('/') + "/";
        var matches = new ArrayList();
        foreach (string key in _files.Keys) {
            if (key.StartsWith(prefix)) {
                var rest = key.Substring(prefix.Length);
                if (rest.IndexOf('/') < 0 && includeFiles) {
                    matches.Add(key);
                }
            }
        }
        try {
            matches.AddRange(base.GetFileSystemEntries(path, searchPattern, includeFiles, includeDirectories));
        } catch {}
        return (string[])matches.ToArray(typeof(string));
    }
}
'@

# --- Build in-memory file index ---
# TODO: Populate from stdlib zip entries instead of empty
$fileIndex = @{}

# TODO: Extract lib/ entries from IronPython zip into $fileIndex
# foreach ($entry in $ipyZip.Entries) {
#     if ($entry.FullName.StartsWith("lib/") -and !$entry.FullName.EndsWith("/")) {
#         $stream = $entry.Open()
#         $ms = [System.IO.MemoryStream]::new()
#         $stream.CopyTo($ms)
#         $fileIndex["/ipy/lib/" + $entry.FullName.Substring(4)] = $ms.ToArray()
#         $stream.Close()
#     }
# }

# TODO: Also populate vendored packages (ruamel.yaml, jinja2, markupsafe)

# --- Create PAL instance ---
$pal = [InMemoryPAL]::new($fileIndex)

# --- Create IronPython engine ---
# TODO: Wire PAL into ScriptHost for full in-memory operation
# For now, use standard engine with disk stdlib paths for development
$engine = [IronPython.Hosting.Python]::CreateEngine()
$paths = $engine.GetSearchPaths()
$paths.Add("$ipyRoot\lib")
$paths.Add("$ipyRoot\lib\site-packages")
$engine.SetSearchPaths($paths)

# --- Register Python meta_path importer ---
# Bridges the PAL into Python's import system for vendored packages
$_metaPathSetup = @'
import sys, types, clr
import System

class InMemoryImporter:
    def __init__(self, pal, virtual_root):
        self.pal = pal
        self.root = virtual_root

    def find_module(self, fullname, path=None):
        parts = fullname.replace('.', '/')
        for c in [self.root + '/' + parts + '.py',
                   self.root + '/' + parts + '/__init__.py']:
            if self.pal.FileExists(c):
                return self
        return None

    def load_module(self, fullname):
        if fullname in sys.modules:
            return sys.modules[fullname]
        parts = fullname.replace('.', '/')
        for filepath in [self.root + '/' + parts + '.py',
                          self.root + '/' + parts + '/__init__.py']:
            if self.pal.FileExists(filepath):
                stream = self.pal.OpenFileStream(filepath, System.IO.FileMode.Open, System.IO.FileAccess.Read, System.IO.FileShare.Read, 8192)
                buf = System.IO.MemoryStream()
                stream.CopyTo(buf)
                source = System.Text.Encoding.UTF8.GetString(buf.ToArray())
                stream.Close()
                mod = types.ModuleType(fullname)
                mod.__file__ = filepath
                mod.__loader__ = self
                if filepath.endswith('__init__.py'):
                    mod.__path__ = [self.root + '/' + parts]
                    mod.__package__ = fullname
                else:
                    mod.__package__ = fullname.rpartition('.')[0]
                sys.modules[fullname] = mod
                exec(compile(source, filepath, 'exec'), mod.__dict__)
                return mod
        raise ImportError('No module named ' + fullname)
'@

$scope = $engine.CreateScope()
$scope.SetVariable("pal_instance", $pal)
$engine.Execute($_metaPathSetup, $scope)
$engine.Execute("sys.meta_path.insert(0, InMemoryImporter(pal_instance, '/ipy'))", $scope)

# --- Export ---
# Return the engine and scope for use by the caller
@{
    Engine = $engine
    Scope  = $scope
    PAL    = $pal
    Files  = $fileIndex
}
