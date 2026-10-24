"""Typed, source-attributed product observations, separate from confirmed intent.

These are model observations of captured content. They are not verified catalog
identities, statements that a person wants to buy, or facts about live offers.
"""
from __future__ import annotations

import unicodedata
from typing import Annotated, Literal

from pydantic import AfterValidator, BaseModel, ConfigDict, Field, StringConstraints, ValidationError, ValidationInfo, field_validator, model_validator


def normalized_text(value: str) -> str:
    return " ".join(unicodedata.normalize("NFKC", value).casefold().split())


def _text(value: str) -> str:
    if not value.strip() or any(ord(char) < 32 or ord(char) == 127 for char in value):
        raise ValueError("Use nonempty text without control characters")
    return value


ShortText = Annotated[str, StringConstraints(min_length=1, max_length=80, strip_whitespace=True), AfterValidator(_text)]
EvidenceText = Annotated[str, StringConstraints(min_length=1, max_length=160, strip_whitespace=True), AfterValidator(_text)]


class UnderstandingModel(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True, allow_inf_nan=False)


class ProductFact(UnderstandingModel):
    value: ShortText
    basis: Literal["image", "captured_text", "user_note"]
    evidence: EvidenceText
    certainty: Literal["observed", "inferred"]

    @model_validator(mode="after")
    def validate_source(self, info: ValidationInfo):
        context = info.context
        if context is None:
            # Public decoding of already-persisted observations has no source
            # pixels/text. The provider boundary performs contextual validation.
            return self
        if self.basis == "image":
            if not context.get("image_present"):
                raise ValueError("Image evidence requires a captured image")
        else:
            source = context.get(self.basis, "")
            if normalized_text(self.evidence) not in normalized_text(source):
                raise ValueError("Text evidence must quote the supplied source")
        return self


class ProductAttribute(ProductFact):
    name: Annotated[str, StringConstraints(min_length=1, max_length=40, strip_whitespace=True), AfterValidator(_text)]


class ProductObservation(UnderstandingModel):
    product_type: ShortText
    category_path: list[ShortText] = Field(min_length=1, max_length=6)
    brand: ProductFact | None
    model: ProductFact | None
    attributes: list[ProductAttribute] = Field(max_length=12)
    use_cases: list[ShortText] = Field(max_length=5)
    search_terms: list[ShortText] = Field(max_length=12)

    @model_validator(mode="after")
    def observed_identity(self):
        for identity in (self.brand, self.model):
            if identity is None:
                continue
            if identity.certainty != "observed":
                raise ValueError("Brand and model require an observed label or explicit supplied text")
            if normalized_text(identity.value) not in normalized_text(identity.evidence):
                raise ValueError("Identity evidence must contain its name")
        for values in (self.category_path, self.use_cases, self.search_terms):
            if len({normalized_text(value) for value in values}) != len(values):
                raise ValueError("Repeated category or search values are not allowed")
        if len({(normalized_text(a.name), normalized_text(a.value)) for a in self.attributes}) != len(self.attributes):
            raise ValueError("Repeated attributes are not allowed")
        return self


class ProductAnalysis(UnderstandingModel):
    schema_version: Literal[1]
    summary: Annotated[str, StringConstraints(min_length=1, max_length=600, strip_whitespace=True), AfterValidator(_text)]
    products: list[ProductObservation] = Field(max_length=4)
    intent_context: list[EvidenceText] = Field(max_length=8)
    uncertainties: list[EvidenceText] = Field(max_length=8)

    @field_validator("schema_version", mode="before")
    @classmethod
    def integer_version(cls, value):
        if type(value) is not int:
            raise ValueError("Analysis schema version must be an integer")
        return value


def analysis_terms(analysis: ProductAnalysis | dict | None) -> list[str]:
    """Return bounded search facets without treating inferred context as intent.

    Old/invalid observations contribute no terms. Stable normalized values make
    Library indexing and catalog retrieval deterministic across interfaces.
    """
    try:
        parsed = analysis if isinstance(analysis, ProductAnalysis) else ProductAnalysis.model_validate(analysis)
    except (ValidationError, ValueError, TypeError):
        return []
    values = []
    for product in parsed.products:
        values.extend([product.product_type, *product.category_path])
        values.extend(fact.value for fact in (product.brand, product.model) if fact is not None)
        values.extend(attribute.value for attribute in product.attributes)
        values.extend(product.use_cases)
        values.extend(product.search_terms)
    return list(dict.fromkeys(normalized_text(value) for value in values))


def strict_analysis_schema() -> dict:
    """Expand local Pydantic refs to an embeddable strict Responses schema."""
    schema = ProductAnalysis.model_json_schema()
    definitions = schema.pop("$defs", {})

    def resolve(value):
        if isinstance(value, list):
            return [resolve(child) for child in value]
        if not isinstance(value, dict):
            return value
        if "$ref" in value:
            return resolve(definitions[value["$ref"].rsplit("/", 1)[-1]])
        return {key: resolve(child) for key, child in value.items() if key not in {"title", "default"}}

    return resolve(schema)
