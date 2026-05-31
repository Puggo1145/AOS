// Strip lone UTF-16 surrogates and the U+FEFF byte order mark.
//
// Some upstream APIs (notably OpenAI / Google) reject payloads that
// contain orphan surrogate code units (e.g. when the model produces a
// half-formed emoji). This is a defensive cleanup applied just before
// serialization.

const LONE_HIGH_SURROGATE = /[\uD800-\uDBFF](?![\uDC00-\uDFFF])/g;
const LONE_LOW_SURROGATE = /(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/g;
const BOM = /﻿/g;

export function sanitizeSurrogates(input: string): string {
	return input
		.replace(LONE_HIGH_SURROGATE, "")
		.replace(LONE_LOW_SURROGATE, "")
		.replace(BOM, "");
}
