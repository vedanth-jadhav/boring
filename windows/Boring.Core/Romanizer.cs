using System.Buffers.Binary;
using System.Text;
using System.Text.RegularExpressions;

namespace Boring.Core;
/// <summary>Uses the same attested Dakshina tables as the macOS app; never translates lyrics.</summary>
public sealed partial class Romanizer(string resourceDirectory)
{
    private readonly Dictionary<string, byte[]> lexicons = [];
    private readonly Dictionary<string, string> cache = [];
    [GeneratedRegex(@"[\p{L}\p{M}]+")]
    private static partial Regex Words();
    public string Convert(string text) => Words().Replace(text, match => Word(match.Value));
    private string Word(string word) {
        if (cache.TryGetValue(word, out var result)) return result;
        var normalized = word.Normalize(NormalizationForm.FormKC);
        var first = normalized[0];
        var language = first is >= '\u0900' and <= '\u097f' ? "hi" : first is >= '\u0a00' and <= '\u0a7f' ? "pa" : first is >= '\u0600' and <= '\u06ff' ? "ur" : "";
        if (language.Length == 0) return word;
        if (!lexicons.TryGetValue(language, out var data)) {
            var path = Path.Combine(resourceDirectory, language + ".lexicon");
            data = File.Exists(path) ? File.ReadAllBytes(path) : []; lexicons[language] = data;
        }
        result = Lookup(data, normalized) ?? word; // Preserve unknown spellings instead of inventing pronunciation.
        if (cache.Count >= 1500) cache.Clear(); cache[word] = result; return result;
    }
    private static string? Lookup(byte[] data, string word) {
        if (data.Length < 16 || !data.AsSpan(0, 8).SequenceEqual("BNRL0001"u8)) return null;
        var count = BinaryPrimitives.ReadInt32LittleEndian(data.AsSpan(8));
        if (count is <= 0 or > 1_000_000 || 12L + (count + 1L) * 4 >= data.Length) return null;
        var payload = 12 + (count + 1) * 4; var key = Encoding.UTF8.GetBytes(word);
        var low = 0; var high = count;
        while (low < high) {
            var middle = (low + high) / 2;
            var start = payload + BinaryPrimitives.ReadInt32LittleEndian(data.AsSpan(12 + middle * 4));
            var end = payload + BinaryPrimitives.ReadInt32LittleEndian(data.AsSpan(12 + (middle + 1) * 4));
            if (start < payload || end <= start || end > data.Length) return null;
            var record = data.AsSpan(start, end - start); var separator = record.IndexOf((byte)0);
            if (separator < 0 || record[^1] != 0) return null;
            var comparison = record[..separator].SequenceCompareTo(key);
            if (comparison == 0) return Encoding.UTF8.GetString(record[(separator + 1)..^1]);
            if (comparison < 0) low = middle + 1; else high = middle;
        }
        return null;
    }
}
