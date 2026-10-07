import SwiftUI
import UniformTypeIdentifiers

enum ShelfTool: String, CaseIterable, Identifiable {
    case whatsapp, save, compress, convert, copyPath
    case balanced, smaller, smallest, pdf, png, jpeg, heic, mergePDF, extractPDF, pdfImages, preview

    static let primary: [Self] = [.whatsapp, .save, .compress, .convert, .copyPath]
    var id: String { rawValue }
    var title: String {
        switch self {
        case .whatsapp: "WhatsApp"
        case .save: "Save to Shelf"
        case .compress: "Compress"
        case .convert: "Convert"
        case .copyPath: "Copy Path"
        case .balanced: "Balanced"
        case .smaller: "Smaller"
        case .smallest: "Smallest"
        case .pdf: "Make PDF"
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .heic: "HEIC"
        case .mergePDF: "Merge PDFs"
        case .extractPDF: "Split Pages"
        case .pdfImages: "PDF to PNG"
        case .preview: "Edit in Preview"
        }
    }
    var symbol: String {
        switch self {
        case .whatsapp: "message.fill"
        case .save: "tray.and.arrow.down.fill"
        case .compress, .balanced, .smaller, .smallest: "arrow.down.right.and.arrow.up.left"
        case .convert: "arrow.trianglehead.2.clockwise.rotate.90"
        case .copyPath: "link"
        case .pdf, .mergePDF: "doc.richtext"
        case .png, .jpeg, .heic, .pdfImages: "photo"
        case .extractPDF: "doc.on.doc"
        case .preview: "pencil.tip.crop.circle"
        }
    }
    var tint: Color {
        switch self {
        case .whatsapp: .green
        case .save: .cyan
        case .compress, .balanced, .smaller, .smallest: .orange
        case .convert, .png, .jpeg, .heic: .indigo
        case .pdf, .mergePDF, .extractPDF, .pdfImages: .red
        case .copyPath, .preview: .white
        }
    }
    var children: [Self] {
        switch self {
        case .compress: [.balanced, .smaller, .smallest]
        case .convert: [.pdf, .png, .jpeg, .heic, .mergePDF, .extractPDF, .pdfImages, .preview]
        default: []
        }
    }
    var detail: String {
        switch self {
        case .compress: "Images, PDFs & video"
        case .convert: "Images & PDF tools"
        case .balanced: "Quality first · 1080p video"
        case .smaller: "Less space · 720p video"
        case .smallest: "Smallest size · 480p video"
        case .pdf: "Images into one document"
        case .mergePDF: "Combine documents in order"
        case .extractPDF: "One PDF per page"
        case .pdfImages: "One image per page"
        case .preview: "Native markup & annotations"
        default: ""
        }
    }

    func supports(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        let pdfs = urls.allSatisfy { $0.pathExtension.lowercased() == "pdf" }
        let images = urls.allSatisfy { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
        switch self {
        case .png, .jpeg, .heic: return images
        case .mergePDF: return pdfs && urls.count > 1
        case .extractPDF, .pdfImages: return pdfs
        case .pdf, .preview:
            return urls.allSatisfy { $0.pathExtension.lowercased() == "pdf" || UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
        case .compress, .balanced, .smaller, .smallest:
            return urls.allSatisfy {
                guard let type = UTType(filenameExtension: $0.pathExtension) else { return false }
                return type.conforms(to: .image) || type.conforms(to: .pdf) || type.conforms(to: .movie) || type.conforms(to: .video)
            }
        case .convert: return children.contains { $0.supports(urls) }
        default: return true
        }
    }
}
