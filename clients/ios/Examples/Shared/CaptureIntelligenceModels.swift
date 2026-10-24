import Foundation

struct CaptureIntelligenceResult: Codable, Sendable {
    struct Prompt: Codable, Identifiable, Sendable { let id: String; let text: String }
    let productName: String?
    let categoryPath: [String]
    let brand: String?
    let style: [String]
    let summary: String
    let uncertainties: [String]
    let prompts: [Prompt]
    let evidence: [String]
    let analyzedAt: Double
    var searchableText: String { ([productName ?? "", brand ?? "", summary] + categoryPath + style).joined(separator: " ") }
    enum CodingKeys: String, CodingKey {
        case productName = "product_name", categoryPath = "category_path", analyzedAt = "analyzed_at"
        case brand, style, summary, uncertainties, prompts, evidence
    }
}
