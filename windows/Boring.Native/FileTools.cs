using Boring.Core;
using SkiaSharp;
using PdfSharp.Pdf;
using PdfSharp.Pdf.IO;
using PdfSharp.Drawing;

namespace Boring.Native;
public static class FileTools
{
    public static async Task<ShelfItem> Image(Shelf shelf, ShelfItem item, string format, int width = 0)
    {
        var temporary = Path.Combine(Path.GetTempPath(), Guid.NewGuid() + "." + format);
        try {
            await Task.Run(() => {
                using var bitmap = SKBitmap.Decode(item.Path) ?? throw new InvalidOperationException("Choose a PNG, JPEG or WebP image.");
                using var resized = width > 0 && width < bitmap.Width ? bitmap.Resize(new SKImageInfo(width, Math.Max(1, (int)(bitmap.Height * (double)width / bitmap.Width))), new SKSamplingOptions(SKCubicResampler.Mitchell)) : null;
                using var image = SKImage.FromBitmap(resized ?? bitmap);
                using var data = image.Encode(format switch { "png" => SKEncodedImageFormat.Png, "webp" => SKEncodedImageFormat.Webp, _ => SKEncodedImageFormat.Jpeg }, 85);
                using var output = File.Create(temporary); data.SaveTo(output);
            });
            return await shelf.Add(temporary);
        } finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
    public static async Task<ShelfItem> Pdf(Shelf shelf, IEnumerable<ShelfItem> items)
    {
        var temporary = Path.Combine(Path.GetTempPath(), "Boring-" + Guid.NewGuid() + ".pdf");
        try {
            await Task.Run(() => {
                using var document = new PdfDocument();
                foreach (var item in items) {
                    if (Path.GetExtension(item.Path).Equals(".pdf", StringComparison.OrdinalIgnoreCase)) {
                        using var source = PdfReader.Open(item.Path, PdfDocumentOpenMode.Import);
                        foreach (var page in source.Pages) document.AddPage(page);
                    } else {
                        using var image = XImage.FromFile(item.Path); var page = document.AddPage();
                        var scale = Math.Min(page.Width.Point / image.PointWidth, page.Height.Point / image.PointHeight);
                        using var graphics = XGraphics.FromPdfPage(page);
                        graphics.DrawImage(image, (page.Width.Point - image.PointWidth * scale) / 2, (page.Height.Point - image.PointHeight * scale) / 2, image.PointWidth * scale, image.PointHeight * scale);
                    }
                }
                if (document.PageCount == 0) throw new InvalidOperationException("Add images or PDFs first.");
                document.Options.CompressContentStreams = true; document.Save(temporary);
            });
            return await shelf.Add(temporary);
        } finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
