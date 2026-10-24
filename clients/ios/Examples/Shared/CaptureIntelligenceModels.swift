import Foundation

struct CaptureIntelligenceResult: Codable, Sendable {
    struct Prompt: Codable, Identifiable, Sendable {
        let id: String
        let text: String
        let question: String?
        init(id: String, text: String, question: String? = nil) {
            self.id = id; self.text = text; self.question = question
        }
    }
    let productName: String?
    let categoryPath: [String]
    let brand: String?
    let style: [String]
    let summary: String
    let uncertainties: [String]
    let prompts: [Prompt]
    let evidence: [String]
    let analyzedAt: Double
    let schemaVersion: Int?
    init(productName: String?, categoryPath: [String], brand: String?, style: [String], summary: String,
         uncertainties: [String], prompts: [Prompt], evidence: [String], analyzedAt: Double, schemaVersion: Int? = nil) {
        self.productName = productName; self.categoryPath = categoryPath; self.brand = brand; self.style = style
        self.summary = summary; self.uncertainties = uncertainties; self.prompts = prompts; self.evidence = evidence
        self.analyzedAt = analyzedAt; self.schemaVersion = schemaVersion
    }
    var searchableText: String { ([productName ?? "", brand ?? "", summary] + categoryPath + style).joined(separator: " ") }
    enum CodingKeys: String, CodingKey {
        case productName = "product_name", categoryPath = "category_path", analyzedAt = "analyzed_at"
        case schemaVersion = "schema_version"
        case brand, style, summary, uncertainties, prompts, evidence
    }
}
