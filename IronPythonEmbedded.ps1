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
    3. Builds a zip entry index mapping virtual paths to zip entry names
    4. Compiles a custom PlatformAdaptationLayer via Add-Type that lazily extracts
       files from the zip on demand (no pre-loading of stdlib)
    5. Registers a Python sys.meta_path importer that uses the PAL for module loading
    6. Returns a configured ScriptEngine ready to execute Python code

.NOTES
    Requires PowerShell 7+ (pwsh) for .NET Core/.NET 8+ compatibility with IronPython 3.4.x
#>

# --- Configuration ---
$ipyVersion = "3.4.2"
$ipyReleaseUrl = "https://github.com/IronLanguages/ironpython3/releases/download/v$ipyVersion/IronPython.$ipyVersion.zip"
$ipyVirtualRoot = "/ipy"

# TODO: Download IronPython release zip into memory
# $ipyZipBytes = (Invoke-WebRequest -Uri $ipyReleaseUrl).Content
# $ipyZipStream = [System.IO.MemoryStream]::new($ipyZipBytes)
# $ipyZip = [System.IO.Compression.ZipArchive]::new($ipyZipStream)

# TODO: Extract DLLs from zip and load via [Assembly]::Load(byte[])
# For now, load from disk install for development
$ipyRoot = "$env:USERPROFILE\ipyenv\v$ipyVersion"
[System.Reflection.Assembly]::LoadFrom("$ipyRoot\Microsoft.Scripting.dll") | Out-Null
[System.Reflection.Assembly]::LoadFrom("$ipyRoot\Microsoft.Dynamic.dll") | Out-Null
[System.Reflection.Assembly]::LoadFrom("$ipyRoot\IronPython.dll") | Out-Null

# For development, open the zip from the unzipped directory's parent
# In production, this will be the downloaded zip
$ipyZipPath = $null
# Check for local zip first
$localZip = Join-Path (Split-Path $ipyRoot) "IronPython.$ipyVersion.zip"
if (Test-Path $localZip) {
    $ipyZipPath = $localZip
}

# --- Compile LazyPAL via Add-Type ---
# The PAL holds a ZipArchive and a cache Hashtable.
# On FileExists/OpenFileStream, it checks the cache first, then lazily
# extracts from the zip on demand. The entry index maps virtual paths
# to zip entry full names for O(1) lookup.
#
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
    "$runtimeDir\System.IO.Compression.dll"
) -TypeDefinition @'
using System;
using System.IO;
using System.IO.Compression;
using System.Collections;
using System.Linq;
using Microsoft.Scripting;

public class LazyZipPAL : PlatformAdaptationLayer {
    private Hashtable _cache;       // virtual path -> byte[] (lazy-populated)
    private Hashtable _entryIndex;  // virtual path -> zip entry full name
    private ZipArchive _zip;        // kept open for lazy extraction

    public LazyZipPAL(ZipArchive zip, Hashtable entryIndex) {
        _zip = zip;
        _entryIndex = entryIndex;
        _cache = new Hashtable();
    }

    // Add a pre-loaded file (e.g. vendored packages loaded from separate zips)
    public void AddFile(string virtualPath, byte[] content) {
        _cache[virtualPath] = content;
        if (!_entryIndex.ContainsKey(virtualPath)) {
            _entryIndex[virtualPath] = null; // mark as known file, no zip entry
        }
    }

    private string Norm(string path) {
        return path.Replace("\\", "/");
    }

    private bool IsKnown(string path) {
        return _cache.ContainsKey(path) || _entryIndex.ContainsKey(path);
    }

    private byte[] Resolve(string path) {
        if (_cache.ContainsKey(path)) {
            return (byte[])_cache[path];
        }
        if (_entryIndex.ContainsKey(path) && _entryIndex[path] != null) {
            string entryName = (string)_entryIndex[path];
            var entry = _zip.GetEntry(entryName);
            if (entry != null) {
                using (var stream = entry.Open()) {
                    var ms = new MemoryStream();
                    stream.CopyTo(ms);
                    byte[] data = ms.ToArray();
                    _cache[path] = data; // cache for next access
                    return data;
                }
            }
        }
        return null;
    }

    public override bool FileExists(string path) {
        return IsKnown(Norm(path)) || base.FileExists(path);
    }

    public override Stream OpenFileStream(string path, FileMode mode, FileAccess access, FileShare share, int bufferSize) {
        string n = Norm(path);
        byte[] data = Resolve(n);
        if (data != null) {
            return new MemoryStream(data, false);
        }
        return base.OpenFileStream(path, mode, access, share, bufferSize);
    }

    public override bool DirectoryExists(string path) {
        string prefix = Norm(path).TrimEnd('/') + "/";
        foreach (string key in _entryIndex.Keys) {
            if (key.StartsWith(prefix)) return true;
        }
        return base.DirectoryExists(path);
    }

    public override string[] GetFileSystemEntries(string path, string searchPattern, bool includeFiles, bool includeDirectories) {
        string prefix = Norm(path).TrimEnd('/') + "/";
        var matches = new ArrayList();
        var dirs = new Hashtable(); // track unique subdirectories
        foreach (string key in _entryIndex.Keys) {
            if (key.StartsWith(prefix)) {
                var rest = key.Substring(prefix.Length);
                int slash = rest.IndexOf('/');
                if (slash < 0 && includeFiles) {
                    matches.Add(key);
                } else if (slash >= 0 && includeDirectories) {
                    string dir = prefix + rest.Substring(0, slash);
                    if (!dirs.ContainsKey(dir)) {
                        dirs[dir] = true;
                        matches.Add(dir);
                    }
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

# --- Build zip entry index ---
# Maps virtual paths to zip entry names. Cheap — just string mapping, no extraction.
$entryIndex = @{}

if ($ipyZipPath) {
    $ipyZipStream = [System.IO.File]::OpenRead($ipyZipPath)
    $ipyZip = [System.IO.Compression.ZipArchive]::new($ipyZipStream, [System.IO.Compression.ZipArchiveMode]::Read)

    foreach ($entry in $ipyZip.Entries) {
        $name = $entry.FullName
        # Skip directories
        if ($name.EndsWith("/")) { continue }

        # Map lib/ entries to virtual path
        if ($name.StartsWith("lib/")) {
            $virtualPath = "$ipyVirtualRoot/lib/" + $name.Substring(4)
            $entryIndex[$virtualPath] = $name
        }
        # Map net8.0/ DLL entries (for reference, not loaded via PAL)
        # DLLs are loaded via [Assembly]::Load, not via the Python importer
    }
    Write-Host "Indexed $($entryIndex.Count) stdlib entries from zip" -ForegroundColor Green
} else {
    Write-Host "No zip found — using disk stdlib for development" -ForegroundColor Yellow
}

# --- Create PAL instance ---
if ($ipyZip) {
    $pal = [LazyZipPAL]::new($ipyZip, $entryIndex)
} else {
    # Fallback: empty PAL, stdlib from disk
    $pal = [LazyZipPAL]::new(
        $null,
        $entryIndex
    )
}

# --- Create IronPython engine ---
$engine = [IronPython.Hosting.Python]::CreateEngine()
$paths = $engine.GetSearchPaths()
if ($ipyZip) {
    # Virtual path — meta_path importer serves files from zip via PAL
    $paths.Add("$ipyVirtualRoot/lib")
    $paths.Add("$ipyVirtualRoot/lib/site-packages")
    # Also add disk paths as fallback — engine's built-in importer uses default PAL
    # TODO: Wire LazyZipPAL into ScriptHost to eliminate disk dependency entirely
    $paths.Add("$ipyRoot\lib")
    $paths.Add("$ipyRoot\lib\site-packages")
} else {
    # Disk fallback for development
    $paths.Add("$ipyRoot\lib")
    $paths.Add("$ipyRoot\lib\site-packages")
}
$engine.SetSearchPaths($paths)

# --- Register Python meta_path importer ---
# Bridges the PAL into Python's import system
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
                stream = self.pal.OpenFileStream(
                    filepath,
                    System.IO.FileMode.Open,
                    System.IO.FileAccess.Read,
                    System.IO.FileShare.Read,
                    8192
                )
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
$engine.Execute("sys.meta_path.insert(0, InMemoryImporter(pal_instance, '$ipyVirtualRoot'))", $scope)

# --- Export ---
@{
    Engine     = $engine
    Scope      = $scope
    PAL        = $pal
    EntryIndex = $entryIndex
    Zip        = $ipyZip
}
