import type { Capture, CaptureResult, Identity, Health, Capabilities, SavedItemView, CollectionPage, AnnotationResponse, AnnotationResult, Hypotheses, HypothesisFeedback, HypothesisView, StartDiscovery, DiscoveryView, Discoveries, DiscoveryEvent, Catalog, CreateWatch, WatchView, Watches, UpdateWatch, SimulatedPrice, QueuedPriceCheck, Notifications, JobView, TraceView, Deleted, Reset } from './types';
export * from './types';
export interface ReadOptions { signal?: AbortSignal; timeoutMs?: number }
export interface MutationOptions extends ReadOptions { idempotencyKey: string }
export interface PageOptions extends ReadOptions { offset?: number; limit?: number }
export class APIError extends Error { status: number; code: string; retryable: boolean; requestId: string | null; current: DiscoveryView | null; }
export function newMutationKey(): string;
export class CommonThreadClient {
  constructor(options?: {baseURL?: string; token?: string | (() => string | Promise<string>); fetchImpl?: typeof fetch});
  request<T = unknown>(path: string, options?: ReadOptions & {method?: string; body?: unknown; idempotencyKey?: string}): Promise<T>;
  health(options?: ReadOptions): Promise<Health>;
  me(options?: ReadOptions): Promise<Identity>;
  capabilities(options?: ReadOptions): Promise<Capabilities>;
  capture(payload: Capture, options: MutationOptions): Promise<CaptureResult>;
  getSave(id: string, options?: ReadOptions): Promise<SavedItemView>;
  collection(options?: PageOptions): Promise<CollectionPage>;
  respond(id: string, payload: AnnotationResponse, options: MutationOptions): Promise<AnnotationResult>;
  deleteSave(id: string, options: MutationOptions): Promise<Deleted>;
  hypotheses(options?: ReadOptions): Promise<Hypotheses>;
  hypothesisFeedback(id: string, payload: HypothesisFeedback, options: MutationOptions): Promise<HypothesisView>;
  startDiscovery(payload: StartDiscovery, options: MutationOptions): Promise<DiscoveryView>;
  discoverySessions(options?: PageOptions): Promise<Discoveries>;
  getDiscovery(id: string, options?: ReadOptions): Promise<DiscoveryView>;
  discoveryEvent(id: string, payload: DiscoveryEvent, options: MutationOptions): Promise<DiscoveryView>;
  catalog(options?: ReadOptions): Promise<Catalog>;
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
