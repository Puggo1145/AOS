// Calculate cost from a usage object, mutating the cost sub-object in
// place and returning it. Per guide §8 the call site reuses the same
// usage object across stream events so partial costs are visible to the
// UI before `done`.

import type { Api, Model, Usage, UsageCost } from "../types";

export function calculateCost<TApi extends Api>(
	model: Model<TApi>,
	usage: Usage,
): UsageCost {
	usage.cost.input = (model.cost.input / 1_000_000) * usage.input;
	usage.cost.output = (model.cost.output / 1_000_000) * usage.output;
	usage.cost.cacheRead = (model.cost.cacheRead / 1_000_000) * usage.cacheRead;
	usage.cost.cacheWrite =
		(model.cost.cacheWrite / 1_000_000) * usage.cacheWrite;
	usage.cost.total =
		usage.cost.input +
		usage.cost.output +
		usage.cost.cacheRead +
		usage.cost.cacheWrite;
	return usage.cost;
}
