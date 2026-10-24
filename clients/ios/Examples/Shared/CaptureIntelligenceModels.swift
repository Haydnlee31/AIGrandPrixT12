import Foundation
import CommonThreadKit

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
    var productAnalysis: ProductAnalysis? = nil
    var transcript: String? = nil
    init(productName: String?, categoryPath: [String], brand: String?, style: [String], summary: String,
         uncertainties: [String], prompts: [Prompt], evidence: [String], analyzedAt: Double, schemaVersion: Int? = nil) {
        self.productName = productName; self.categoryPath = categoryPath; self.brand = brand; self.style = style
        self.summary = summary; self.uncertainties = uncertainties; self.prompts = prompts; self.evidence = evidence
        self.analyzedAt = analyzedAt; self.schemaVersion = schemaVersion
    }
    var searchableText: String {
        var terms = [productName ?? "", brand ?? "", summary, transcript ?? ""]
        terms.append(contentsOf: categoryPath); terms.append(contentsOf: style)
        for product in productAnalysis?.products ?? [] {
            terms.append(contentsOf: [product.productType, product.brand?.value ?? "", product.model?.value ?? ""])
            terms.append(contentsOf: product.categoryPath)
            terms.append(contentsOf: product.attributes.map { $0.name + " " + $0.value })
            terms.append(contentsOf: product.searchTerms); terms.append(contentsOf: product.useCases)
        }
        return terms.joined(separator: " ")
    }
    enum CodingKeys: String, CodingKey {
        case productName = "product_name", categoryPath = "category_path", analyzedAt = "analyzed_at"
        case schemaVersion = "schema_version", productAnalysis = "product_analysis", transcript
        case brand, style, summary, uncertainties, prompts, evidence
    }
}


struct IntentRefinementResult: Decodable, Sendable {
    let question: String
    let choices: [String]
    let schemaVersion: Int
    enum CodingKeys: String, CodingKey { case question, choices; case schemaVersion = "schema_version" }
}

struct IntentRefinementContext: Identifiable {
    let id = UUID()
    let analysis: CaptureIntelligenceResult
    let selectedIntent: String
    let existingIntents: [String]
}
