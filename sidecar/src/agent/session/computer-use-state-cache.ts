import type { ComputerUseCoordinateSpace } from "../../rpc/rpc-types";

export interface ComputerUseScreenshotStateRecord {
  stateId: string;
  windowId: number;
  coordinateSpace: ComputerUseCoordinateSpace;
  recordedAt: number;
}

export type ComputerUseScreenshotStateRecordInput = Omit<ComputerUseScreenshotStateRecord, "recordedAt"> & {
  recordedAt?: number;
};

export type ComputerUseStateCacheLookup =
  | { kind: "found"; record: ComputerUseScreenshotStateRecord }
  | { kind: "missing" }
  | { kind: "expired" };

export const COMPUTER_USE_STATE_CACHE_TTL_MILLISECONDS = 30_000;

/// Session-scoped coordinate metadata for screenshots returned by
/// `get_app_state`. The model speaks in screenshot-local pixels; the sidecar
/// uses this cache to translate those pixels into Core-facing screen points.
export class ComputerUseStateCache {
  private readonly records = new Map<string, ComputerUseScreenshotStateRecord>();

  constructor(
    private readonly options: {
      ttlMilliseconds?: number;
      now?: () => number;
    } = {},
  ) {}

  record(record: ComputerUseScreenshotStateRecordInput): void {
    this.records.set(record.stateId, {
      ...record,
      recordedAt: record.recordedAt ?? this.now(),
    });
  }

  lookup(stateId: string): ComputerUseStateCacheLookup {
    const record = this.records.get(stateId);
    if (!record) return { kind: "missing" };
    if (this.now() - record.recordedAt > this.ttlMilliseconds) {
      this.records.delete(stateId);
      return { kind: "expired" };
    }
    return { kind: "found", record };
  }

  clear(): void {
    this.records.clear();
  }

  private get ttlMilliseconds(): number {
    return this.options.ttlMilliseconds ?? COMPUTER_USE_STATE_CACHE_TTL_MILLISECONDS;
  }

  private now(): number {
    return this.options.now?.() ?? Date.now();
  }
}
