#Requires -Version 7.0
<#
.SYNOPSIS
    Single-file embeddable IronPython for PowerShell.

.DESCRIPTION
    Compiles a custom PlatformAdaptationLayer (LazyZipPAL) via Add-Type that:
    - Accepts zip archives (local path or URL) as Python library sources
    - Lazily extracts files on demand (zero startup overhead)
    - Supports multiple zips (stdlib, vendored packages, user libraries)
    - Falls back to real filesystem for anything not in the zips

.NOTES
    Requires PowerShell 7+ (pwsh) for .NET Core/.NET 8+ compatibility with IronPython 3.4.x
#>

# --- Configuration ---
$ipyVersion = "3.4.2"
$ipyReleaseUrl = "https://github.com/IronLanguages/ironpython3/releases/download/v$ipyVersion/IronPython.$ipyVersion.zip"
$ipyVirtualRoot = "/ipy"

# --- Load IronPython assemblies ---
# TODO: Load from zip via [Assembly]::Load(byte[]) instead of disk
$ipyRoot = "$(Resolve-Path "~")\ipyenv\v$ipyVersion"
[System.Reflection.Assembly]::LoadFrom("$ipyRoot\Microsoft.Scripting.dll") | Out-Null
[System.Reflection.Assembly]::LoadFrom("$ipyRoot\Microsoft.Dynamic.dll") | Out-Null
[System.Reflection.Assembly]::LoadFrom("$ipyRoot\IronPython.dll") | Out-Null

# --- Compile LazyZipPAL via Add-Type ---
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
    "$runtimeDir\System.Net.Http.dll"
) -TypeDefinition @'
using System;
using System.IO;
using System.IO.Compression;
using System.Collections;
using System.Linq;
using System.Net.Http;
using Microsoft.Scripting;

public class LazyZipPAL : PlatformAdaptationLayer {
    private Hashtable _cache;       // virtual path -> byte[] (lazy-populated)
    private Hashtable _entryIndex;  // virtual path -> ZipArchiveEntry
    private ArrayList _zips;        // open ZipArchive instances (kept alive for lazy reads)

    public LazyZipPAL() {
        _cache = new Hashtable();
        _entryIndex = new Hashtable();
        _zips = new ArrayList();
    }

    // 1-arg: auto-detect path vs URL, mount all entries at virtualRoot "/"
    public LazyZipPAL(string pathOrUrl) : this(pathOrUrl, "", "/") {}

    // 3-arg: auto-detect path vs URL with explicit prefix and virtualRoot
    public LazyZipPAL(string pathOrUrl, string prefix, string virtualRoot) : this() {
        AddZip(pathOrUrl, prefix, virtualRoot);
    }

    // 4-arg: local path with URL fallback, explicit prefix and virtualRoot
    public LazyZipPAL(string localPath, string fallbackUrl, string prefix, string virtualRoot) : this() {
        if (File.Exists(localPath)) {
            AddZipFromPath(localPath, prefix, virtualRoot);
        } else {
            AddZipFromUrl(fallbackUrl, prefix, virtualRoot);
        }
    }

    // Auto-detect: URL (http/https) vs local file path
    public int AddZip(string pathOrUrl, string prefix, string virtualRoot) {
        if (pathOrUrl.StartsWith("http://") || pathOrUrl.StartsWith("https://")) {
            return AddZipFromUrl(pathOrUrl, prefix, virtualRoot);
        }
        return AddZipFromPath(pathOrUrl, prefix, virtualRoot);
    }

    // 2-arg convenience: local path with URL fallback
    public int AddZip(string localPath, string fallbackUrl, string prefix, string virtualRoot) {
        if (File.Exists(localPath)) {
            return AddZipFromPath(localPath, prefix, virtualRoot);
        }
        return AddZipFromUrl(fallbackUrl, prefix, virtualRoot);
    }

    // --- Additive methods for loading library sources ---

    // Add a zip from a local file path, mapping entries under a virtual root.
    // prefix: the path prefix inside the zip to map (e.g. "lib/")
    // virtualRoot: where to mount them (e.g. "/ipy/lib")
    public int AddZipFromPath(string path, string prefix, string virtualRoot) {
        var stream = File.OpenRead(path);
        var zip = new ZipArchive(stream, ZipArchiveMode.Read);
        return AddZipInternal(zip, prefix, virtualRoot);
    }

    // Add a zip from a byte array (e.g. downloaded into memory)
    public int AddZipFromBytes(byte[] data, string prefix, string virtualRoot) {
        var stream = new MemoryStream(data);
        var zip = new ZipArchive(stream, ZipArchiveMode.Read);
        return AddZipInternal(zip, prefix, virtualRoot);
    }

    // Add a zip from a URL (downloads into memory)
    public int AddZipFromUrl(string url, string prefix, string virtualRoot) {
        using (var client = new HttpClient()) {
            var data = client.GetByteArrayAsync(url).GetAwaiter().GetResult();
            return AddZipFromBytes(data, prefix, virtualRoot);
        }
    }

    private int AddZipInternal(ZipArchive zip, string prefix, string virtualRoot) {
        _zips.Add(zip);
        string norm_prefix = prefix.Replace("\\", "/").TrimEnd('/');
        string norm_root = virtualRoot.Replace("\\", "/").TrimEnd('/');
        int count = 0;
        foreach (var entry in zip.Entries) {
            string name = entry.FullName.Replace("\\", "/");
            if (name.EndsWith("/")) continue; // skip directories

            if (norm_prefix.Length == 0 || name.StartsWith(norm_prefix + "/") || name == norm_prefix) {
                string suffix = norm_prefix.Length == 0
                    ? name
                    : name.Substring(norm_prefix.Length + 1);
                string virtualPath = norm_root + "/" + suffix;
                _entryIndex[virtualPath] = entry;
                count++;
            }
        }
        return count;
    }

    // Add a single file directly (e.g. inline Python code)
    public void AddFile(string virtualPath, byte[] content) {
        _cache[virtualPath] = content;
        if (!_entryIndex.ContainsKey(virtualPath)) {
            _entryIndex[virtualPath] = null;
        }
    }

    // --- PAL overrides ---

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
            var entry = (ZipArchiveEntry)_entryIndex[path];
            using (var stream = entry.Open()) {
                var ms = new MemoryStream();
                stream.CopyTo(ms);
                byte[] data = ms.ToArray();
                _cache[path] = data;
                return data;
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
        var dirs = new Hashtable();
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

# --- Create PAL and load stdlib zip ---
# 4-arg constructor: local path with URL fallback
$localZip = Join-Path (Split-Path $ipyRoot) "IronPython.$ipyVersion.zip"
$pal = [LazyZipPAL]::new($localZip, $ipyReleaseUrl, "lib", "$ipyVirtualRoot/lib")

# --- Create IronPython engine ---
$engine = [IronPython.Hosting.Python]::CreateEngine()
$paths = $engine.GetSearchPaths()
$paths.Add("$ipyVirtualRoot/lib")
$paths.Add("$ipyVirtualRoot/lib/site-packages")
# Disk fallback — engine's built-in importer uses default PAL, not ours
# TODO: Wire LazyZipPAL into ScriptHost to eliminate disk dependency
$paths.Add("$ipyRoot\lib")
$paths.Add("$ipyRoot\lib\site-packages")
$engine.SetSearchPaths($paths)

# --- Register Python meta_path importer ---
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
    Engine = $engine
    Scope  = $scope
    PAL    = $pal
}
