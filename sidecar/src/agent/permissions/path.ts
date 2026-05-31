import { existsSync, realpathSync } from "node:fs";
import { dirname, isAbsolute, relative, resolve } from "node:path";

export function isPathWithinRoot(path: string, root: string): boolean {
	const rel = relative(resolve(root), resolve(path));
	return rel === "" || (!rel.startsWith("..") && !isAbsolute(rel));
}

export function isPathWithinRootRealpath(path: string, root: string): boolean {
	const realRoot = realpathSync(root);
	const existing = nearestExistingAncestor(path);
	const realExisting = realpathSync(existing);
	return isPathWithinRoot(realExisting, realRoot);
}

function nearestExistingAncestor(path: string): string {
	let current = resolve(path);
	while (!existsSync(current)) {
		const parent = dirname(current);
		if (parent === current) return current;
		current = parent;
	}
	return current;
}
