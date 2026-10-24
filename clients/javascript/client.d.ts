import type { Capture, CaptureResult, Identity, Health, Capabilities, SavedItemView, CollectionPage, AnnotationResponse, AnnotationResult, Hypotheses, HypothesisFeedback, HypothesisView, StartDiscovery, DiscoveryView, Discoveries, DiscoveryEvent, Catalog, CreateWatch, WatchView, Watches, UpdateWatch, SimulatedPrice, QueuedPriceCheck, Notifications, JobView, TraceView, Deleted, Reset } from './types';
export * from './types';
import type { CatalogSources, CatalogSearchPage, CatalogRecord, LibrarySearchPage, AnalysisQueued, ExplorePage, ProductAnalysis } from './types';
export interface ReadOptions { signal?: AbortSignal; timeoutMs?: number }
export interface MutationOptions extends ReadOptions { idempotencyKey: string }
export interface PageOptions extends ReadOptions { offset?: number; limit?: number }
/** Explicit opt-in analysis APIs. They never change the native library destination automatically. */
export interface MultimodalCapabilities {
  enabled: boolean; schema_version: 1; content_types: string[];
  max_assets: number; max_images: number; max_audio: number; max_asset_bytes: number; actions_execute: false;
}
export interface MultimodalCaptureInput {
  title?: string; text?: string; note?: string; url?: string | null;
  client?: 'ios_app' | 'ios_share_extension' | 'chrome_extension' | 'web';
}
export interface MultimodalCaptureEdit { revision: number; title?: string; text?: string; note?: string }
export interface MultimodalAssetInput { revision: number; media_type: string; data_base64: string }
export interface MultimodalTranscriptEdit { revision: number; transcript: string }
export interface MultimodalAsset {
  id: string; media_type: string; kind: 'image' | 'audio'; size_bytes: number;
  status: 'pending' | 'ready' | 'failed'; transcript: string | null; transcript_origin?: 'provider' | 'user' | null;
}
export interface MultimodalPreview {
  product_name: string | null; category_path: string[]; brand: string | null; style: string[];
  summary: string; uncertainties: string[]; evidence: string[]; schema_version: 2; analyzed_at?: number;
  prompts: Array<{id: string; text: string; question: string | null}>;
}
export interface MultimodalResult { analysis: ProductAnalysis; preview: MultimodalPreview; source_assets: string[] }
export interface MultimodalCapture {
  id: string; revision: number; status: 'pending' | 'ready' | 'enrichment_failed';
  stage: 'draft' | 'transcribing' | 'analyzing' | 'ready' | 'failed';
  title: string; text: string; note: string; url: string | null; client: string;
  assets: MultimodalAsset[]; result: MultimodalResult | null; error_code: string | null;
  created_at: number; updated_at: number; published_save_id: string | null;
}
export class APIError extends Error { status: number; code: string; retryable: boolean; requestId: string | null; current: DiscoveryView | null; }
export function newMutationKey(): string;
export class CommonThreadClient {
  constructor(options?: {baseURL?: string; token?: string | (() => string | Promise<string>); fetchImpl?: typeof fetch});
  request<T = unknown>(path: string, options?: ReadOptions & {method?: string; body?: unknown; idempotencyKey?: string}): Promise<T>;
  health(options?: ReadOptions): Promise<Health>;
  me(options?: ReadOptions): Promise<Identity>;
  capabilities(options?: ReadOptions): Promise<Capabilities>;
  multimodalCapabilities(options?: ReadOptions): Promise<MultimodalCapabilities>;
  createMultimodalCapture(payload: MultimodalCaptureInput, options: MutationOptions): Promise<MultimodalCapture>;
  getMultimodalCapture(id: string, options?: ReadOptions): Promise<MultimodalCapture>;
  uploadMultimodalAsset(id: string, payload: MultimodalAssetInput, options: MutationOptions): Promise<MultimodalCapture>;
  updateMultimodalCapture(id: string, payload: MultimodalCaptureEdit, options: MutationOptions): Promise<MultimodalCapture>;
  updateMultimodalTranscript(id: string, assetId: string, payload: MultimodalTranscriptEdit, options: MutationOptions): Promise<MultimodalCapture>;
  analyzeMultimodalCapture(id: string, revision: number, options: MutationOptions): Promise<MultimodalCapture>;
  deleteMultimodalAsset(id: string, assetId: string, revision: number, options: MutationOptions): Promise<MultimodalCapture>;
  /** Published captures must be removed through deleteSave(published_save_id). */
  deleteMultimodalCapture(id: string, options: MutationOptions): Promise<Deleted>;
  /** Explicitly publishes a ready capture and freezes further attachment/note edits. */
  publishMultimodalCapture(id: string, revision: number, options: MutationOptions): Promise<CaptureResult>;
  waitForMultimodalCapture(id: string, options?: ReadOptions & {expectedRevision?: number; intervalMs?: number}): Promise<MultimodalCapture>;
  /** Save a URL, image_data_url, or both; provider keys stay on the backend. */
  capture(payload: Capture, options: MutationOptions): Promise<CaptureResult>;
  getSave(id: string, options?: ReadOptions): Promise<SavedItemView>;
  collection(options?: PageOptions): Promise<CollectionPage>;
  searchLibrary(options?: PageOptions & {query?: string; category?: string}): Promise<LibrarySearchPage>;
  analyzeSave(id: string, options: MutationOptions): Promise<AnalysisQueued>;
  /** Records a confirmed annotation. annotation_only does not schedule or purchase. */
  respond(id: string, payload: AnnotationResponse, options: MutationOptions): Promise<AnnotationResult>;
  deleteSave(id: string, options: MutationOptions): Promise<Deleted>;
  hypotheses(options?: ReadOptions): Promise<Hypotheses>;
  hypothesisFeedback(id: string, payload: HypothesisFeedback, options: MutationOptions): Promise<HypothesisView>;
  startDiscovery(payload: StartDiscovery, options: MutationOptions): Promise<DiscoveryView>;
  discoverySessions(options?: PageOptions): Promise<Discoveries>;
  getDiscovery(id: string, options?: ReadOptions): Promise<DiscoveryView>;
  discoveryEvent(id: string, payload: DiscoveryEvent, options: MutationOptions): Promise<DiscoveryView>;
  catalog(options?: ReadOptions): Promise<Catalog>;
  catalogSources(options?: ReadOptions): Promise<CatalogSources>;
  explore(options?: PageOptions & {query?: string; source?: string}): Promise<ExplorePage>;
  searchProducts(options: PageOptions & {source: string; query: string}): Promise<CatalogSearchPage>;
  catalogItem(source: string, id: string, options?: ReadOptions): Promise<CatalogRecord>;
  createWatch(payload: CreateWatch, options: MutationOptions): Promise<WatchView>;
  watches(options?: PageOptions): Promise<Watches>;
  getWatch(id: string, options?: ReadOptions): Promise<WatchView>;
  updateWatch(id: string, payload: UpdateWatch, options: MutationOptions): Promise<WatchView>;
  simulatePrice(id: string, payload: SimulatedPrice, options: MutationOptions): Promise<QueuedPriceCheck>;
  notifications(options?: PageOptions): Promise<Notifications>;
  getJob(id: string, options?: ReadOptions): Promise<JobView>;
  trace(options?: ReadOptions): Promise<TraceView>;
  resetDemo(options: MutationOptions): Promise<Reset>;
  waitForSave(id: string, options?: ReadOptions & {intervalMs?: number; timeoutMs?: number}): Promise<SavedItemView>;
}
