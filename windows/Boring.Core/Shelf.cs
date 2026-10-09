using System.IO.Compression;

namespace Boring.Core;
public sealed class Shelf(Settings settings, string? root = null)
{
    public string Root { get; } = Path.Combine(root ?? Settings.DataRoot, "Shelf");
    public async Task<ShelfItem> Add(string path)
    {
        if (!File.Exists(path) && !Directory.Exists(path)) throw new FileNotFoundException("Choose an existing file or folder", path);
        var directory = Path.Combine(Root, Guid.NewGuid().ToString("N")); Directory.CreateDirectory(directory);
        var target = Path.Combine(directory, Path.GetFileName(path));
        if (Directory.Exists(path)) await Task.Run(() => CopyDirectory(path, target));
        else { await using var input = File.OpenRead(path); await using var output = File.Create(target); await input.CopyToAsync(output); }
        var item = new ShelfItem(target, Path.GetFileName(path), DateTimeOffset.Now);
        settings.Shelf.Add(item); settings.Save(root); return item;
    }
    public void Remove(ShelfItem item)
    {
        // Only delete a managed copy, never the original file or arbitrary settings paths.
        var full = Path.GetFullPath(item.Path);
        if (full.StartsWith(Path.GetFullPath(Root) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) { if (File.Exists(full)) File.Delete(full); else if (Directory.Exists(full)) Directory.Delete(full, true); }
        settings.Shelf.Remove(item); settings.Save(root);
    }
    public async Task<ShelfItem> Zip(IEnumerable<ShelfItem> selected)
    {
        var temporary = Path.Combine(Path.GetTempPath(), "Boring-" + Guid.NewGuid() + ".zip");
        try {
            await Task.Run(() => { using var zip = ZipFile.Open(temporary, ZipArchiveMode.Create);
                var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                foreach (var item in selected) {
                    var name = item.Name; var i = 1;
                    while (!names.Add(name)) name = $"{Path.GetFileNameWithoutExtension(item.Name)} ({i++}){Path.GetExtension(item.Name)}";
                    if (Directory.Exists(item.Path)) {
                        zip.CreateEntry(name + "/");
                        foreach (var file in Directory.EnumerateFiles(item.Path, "*", SearchOption.AllDirectories)) zip.CreateEntryFromFile(file, name + "/" + Path.GetRelativePath(item.Path, file).Replace('\\', '/'), CompressionLevel.Optimal);
                    } else zip.CreateEntryFromFile(item.Path, name, CompressionLevel.Optimal);
                }
            });
            return await Add(temporary);
        } finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
    public static void CopyDirectory(string source, string target) {
        var directory = new DirectoryInfo(source);
        if (directory.LinkTarget != null) throw new IOException("Add the files inside a linked folder directly.");
        Directory.CreateDirectory(target);
        foreach (var file in directory.EnumerateFiles()) { if (file.LinkTarget != null) throw new IOException("Add linked files directly."); file.CopyTo(Path.Combine(target, file.Name)); }
        foreach (var folder in directory.EnumerateDirectories()) CopyDirectory(folder.FullName, Path.Combine(target, folder.Name));
    }
}
