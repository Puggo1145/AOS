// Capability predicates.
//
// Reasoning capabilities (thinking, supported efforts, default, request-
// time resolution) live in `./effort.ts` — this module re-exports them
// so call sites can keep importing capability bits from a single path.
// Vision is the only non-reasoning capability today and is fully
// derivable from `Model.input`.

import type { Api, Model } from "../types";

export {
  supportsThinking,
  supportsEffort,
  supportedEfforts,
  defaultEffort,
} from "./effort";

export function supportsVision<TApi extends Api>(model: Model<TApi>): boolean {
  return model.input.includes("image");
}
