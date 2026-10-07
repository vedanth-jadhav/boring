import AVFoundation
import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum ShelfMediaProcessor {
    static func process(_ tool: ShelfTool, urls: [URL]) async throws -> [URL] {
        if tool == .pdf || tool == .mergePDF {
            let document = PDFDocument()
            for url in urls {
                if url.pathExtension.lowercased() == "pdf", let source = PDFDocument(url: url), !source.isLocked {
                    for index in 0..<source.pageCount {
                        guard let page = source.page(at: index) else { continue }
                        document.insert(page, at: document.pageCount)
                    }
                } else if tool == .pdf, let image = NSImage(contentsOf: url), let page = PDFPage(image: image) {
                    document.insert(page, at: document.pageCount)
                } else { throw failure("Select images or unlocked PDFs for this action.") }
            }
            guard document.pageCount > 0 else { throw failure("No pages could be read.") }
            let destination = try ShelfFileLibrary.destination(named: tool == .mergePDF ? "Merged.pdf" : "Images.pdf")
            guard document.write(to: destination) else { throw failure("The PDF could not be saved.") }
            return [destination]
        }
        var results: [URL] = []
        for url in urls {
            try Task.checkCancellation()
            let isPDF = url.pathExtension.lowercased() == "pdf"
            if tool == .extractPDF || tool == .pdfImages {
                guard let document = PDFDocument(url: url), !document.isLocked else { throw failure("Select an unlocked PDF.") }
                for index in 0..<document.pageCount {
                    guard let page = document.page(at: index) else { continue }
                    let name = "\(url.deletingPathExtension().lastPathComponent)-page-\(index + 1)"
                    if tool == .extractPDF {
                        let output = PDFDocument()
                        output.insert(page, at: 0)
                        let destination = try ShelfFileLibrary.destination(named: name + ".pdf")
                        guard output.write(to: destination) else { throw failure("A PDF page could not be saved.") }
                        results.append(destination)
                    } else {
                        let image = try rasterize(page, maxDimension: 2400)
                        results.append(try writeImage(image, type: .png, quality: 1, name: name + ".png"))
                    }
                }
            } else if [.balanced, .smaller, .smallest].contains(tool) {
                let quality = tool == .balanced ? 0.82 : tool == .smaller ? 0.62 : 0.42
                let dimension: CGFloat = tool == .balanced ? 2400 : tool == .smaller ? 1600 : 1000
                if isPDF {
                    guard let input = PDFDocument(url: url), !input.isLocked else { throw failure("This PDF is locked or unreadable.") }
                    let output = PDFDocument()
                    for index in 0..<input.pageCount {
                        try Task.checkCancellation()
                        guard let page = input.page(at: index) else { continue }
                        let cgImage = try rasterize(page, maxDimension: dimension)
                        let data = NSMutableData()
                        guard let encoder = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw failure("PDF compression failed.") }
                        CGImageDestinationAddImage(encoder, cgImage, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                        guard CGImageDestinationFinalize(encoder), let image = NSImage(data: data as Data), let newPage = PDFPage(image: image) else { throw failure("PDF compression failed.") }
                        newPage.setBounds(page.bounds(for: .mediaBox), for: .mediaBox)
                        output.insert(newPage, at: output.pageCount)
                    }
                    let destination = try ShelfFileLibrary.destination(named: url.deletingPathExtension().lastPathComponent + "-smaller.pdf")
                    guard output.write(to: destination) else { throw failure("The PDF could not be saved.") }
                    results.append(try keepSmaller(destination, original: url))
                } else if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .movie) || type.conforms(to: .video) {
                    results.append(try await compressVideo(url, tool: tool))
                } else {
                    let image = try loadImage(url)
                    let scaled = try scale(image, maxDimension: dimension)
                    let hasAlpha = [.first, .last, .premultipliedFirst, .premultipliedLast].contains(image.alphaInfo)
                    let type: UTType = hasAlpha ? .png : .jpeg
                    let destination = try writeImage(scaled, type: type, quality: quality, name: url.deletingPathExtension().lastPathComponent + "-smaller." + (hasAlpha ? "png" : "jpg"), sourceURL: url)
                    results.append(try keepSmaller(destination, original: url))
                }
            } else {
                let type: UTType = tool == .jpeg ? .jpeg : tool == .heic ? .heic : .png
                let image = try loadImage(url)
                results.append(try writeImage(image, type: type, quality: 0.9, name: url.deletingPathExtension().lastPathComponent + "-converted." + (type.preferredFilenameExtension ?? "png"), sourceURL: url))
            }
        }
        return results
    }

    private static func loadImage(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw failure("This tool supports images, PDFs, and videos. Choose a compatible file.")
        }
        return image
    }

    private static func writeImage(_ image: CGImage, type: UTType, quality: Double, name: String, sourceURL: URL? = nil) throws -> URL {
        let url = try ShelfFileLibrary.destination(named: name)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { throw failure("This image format cannot be written on this Mac.") }
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if let sourceURL, let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil), let sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any], let orientation = sourceProperties[kCGImagePropertyOrientation] {
            properties[kCGImagePropertyOrientation] = orientation
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw failure("The image could not be saved.") }
        return url
    }

    private static func scale(_ image: CGImage, maxDimension: CGFloat) throws -> CGImage {
        let ratio = min(1, maxDimension / CGFloat(max(image.width, image.height)))
        let width = max(1, Int(CGFloat(image.width) * ratio)), height = max(1, Int(CGFloat(image.height) * ratio))
        guard ratio < 1 else { return image }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw failure("Image resizing failed.") }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let output = context.makeImage() else { throw failure("Image resizing failed.") }
        return output
    }

    private static func rasterize(_ page: PDFPage, maxDimension: CGFloat) throws -> CGImage {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { throw failure("This PDF page has no valid size.") }
        let ratio = min(3, maxDimension / max(bounds.width, bounds.height))
        let size = CGSize(width: max(1, bounds.width * ratio), height: max(1, bounds.height * ratio))
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw failure("PDF rendering failed.") }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.scaleBy(x: ratio, y: ratio)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: context)
        guard let image = context.makeImage() else { throw failure("PDF rendering failed.") }
        return image
    }

    private static func compressVideo(_ url: URL, tool: ShelfTool) async throws -> URL {
        let preset = tool == .balanced ? AVAssetExportPreset1920x1080 : tool == .smaller ? AVAssetExportPreset1280x720 : AVAssetExportPreset640x480
        guard let exporter = AVAssetExportSession(asset: AVURLAsset(url: url), presetName: preset) else { throw failure("This video cannot be compressed.") }
        let destination = try ShelfFileLibrary.destination(named: url.deletingPathExtension().lastPathComponent + "-smaller.mp4")
        exporter.shouldOptimizeForNetworkUse = true
        try await exporter.export(to: destination, as: .mp4)
        return try keepSmaller(destination, original: url)
    }

    private static func keepSmaller(_ output: URL, original: URL) throws -> URL {
        let old = try original.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let new = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        if new >= old {
            try? FileManager.default.removeItem(at: output.deletingLastPathComponent())
            return original
        }
        return output
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "ShelfTools", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
