// Reports assemblies in the feed's packages whose PE machine type contradicts their folder.
// Usage: dotnet run tools/CheckPayloadArch.cs -- <feed-dir>
// Replaces a per-entry unzip/od loop in dist.local.sh that spawned ~2000 processes; process
// creation on Windows costs ~250 ms each, which made that loop take most of ten minutes.
using System.IO.Compression;
using System.Text.RegularExpressions;

var feed = args[0];
var include = new Regex(@"^(lib|ref)/[^/]+/.*\.dll$|^runtimes/[^/]+/lib/[^/]+/.*\.dll$");
var offenders = 0;

foreach (var pkg in Directory.GetFiles(feed, "*.nupkg").Order(StringComparer.Ordinal))
{
    using var zip = ZipFile.OpenRead(pkg);
    foreach (var entry in zip.Entries)
    {
        var name = entry.FullName;
        if (!include.IsMatch(name)) continue;
        var machine = ProbeMachine(entry);
        if (machine is null) continue;
        // 0x014c is both AnyCPU and x86, and is always acceptable.
        if (machine == "014c") continue;
        // DirectWriteForwarder is C++/CLI and cannot be AnyCPU, yet it has to appear in lib/<tfm>
        // so a RID-neutral restore resolves the reference; see dist.local.sh.
        if (Regex.IsMatch(name, @"^lib/[^/]+/DirectWriteForwarder\.dll$")) continue;
        if (name.StartsWith("runtimes/", StringComparison.Ordinal))
        {
            var rid = name.Split('/')[1];
            var expected = rid switch { "win-x64" => "8664", "win-arm64" => "aa64", "win-x86" => "014c", _ => null };
            if (expected == machine) continue;
            Console.Error.WriteLine($"  wrong-arch for {rid}: {Path.GetFileName(pkg)} {name} (machine 0x{machine})");
        }
        else
        {
            Console.Error.WriteLine($"  arch-stamped: {Path.GetFileName(pkg)} {name} (machine 0x{machine})");
        }
        offenders++;
    }
}

if (offenders > 0)
{
    Console.Error.WriteLine($"  {offenders} assemblies carry an architecture their folder cannot promise; they will");
    Console.Error.WriteLine("  fail to load, or fail the consumer's build with CS8012 where the entry is under ref/.");
    Console.Error.WriteLine("  See OpenDevelop doc/technotes/librewpf.md.");
}
else
{
    Console.WriteLine("  lib/, ref/ and every runtimes/<rid>/lib/ entry carry a loadable architecture.");
}

static string? ProbeMachine(ZipArchiveEntry entry)
{
    using var stream = entry.Open();
    var buffer = new MemoryStream();
    stream.CopyTo(buffer);
    var bytes = buffer.GetBuffer();
    var length = (int)buffer.Length;
    if (length < 64) return null;
    var offset = BitConverter.ToInt32(bytes, 60);
    if (offset < 0 || offset + 6 > length) return null;
    return BitConverter.ToUInt16(bytes, offset + 4).ToString("x4");
}
