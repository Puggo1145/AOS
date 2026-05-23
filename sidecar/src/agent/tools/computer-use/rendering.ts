import { readFileSync, unlinkSync } from "node:fs";
import { supportsVision } from "../../../llm/models/capabilities";
import type { ToolResultContent } from "../../../llm/types";
import type { ComputerUseBounds, ComputerUseGetAppStateResult } from "../../../rpc/rpc-types";
import type { ToolExecContext } from "../types";

export function renderComputerUseAppStateResult(result: unknown, ctx: ToolExecContext): ToolResultContent[] {
  const state = result as ComputerUseGetAppStateResult;
  const screenshot = state.screenshot;
  const content: ToolResultContent[] = [{ type: "text", text: renderComputerUseAppStateText(state) }];
  if (screenshot) {
    const imageContent = consumeScreenshotFile(screenshot, ctx);
    if (imageContent) content.push(imageContent);
  }
  return content;
}

export function renderComputerUseAppStateText(state: ComputerUseGetAppStateResult): string {
  const lines = [
    "<app_state>",
    `App=${renderAppIdentity(state)} (pid ${state.pid})`,
    `State ID: ${state.stateId}`,
    `Elements: ${state.elementCount}`,
  ];
  if (state.screenshot) {
    lines.push(
      `Screenshot: ${state.screenshot.format} ${state.screenshot.width}x${state.screenshot.height} px @${state.screenshot.scaleFactor}x`,
      `Screenshot windowFrame: ${renderBounds(state.screenshot.coordinateSpace.windowFrame)}`,
      `Screenshot windowBounds: ${renderBounds(state.screenshot.coordinateSpace.windowBounds)}`,
      `Screenshot pixelSize: ${state.screenshot.coordinateSpace.pixelSize.width}x${state.screenshot.coordinateSpace.pixelSize.height} px`,
    );
  }
  const tree = state.treeMarkdown.trim();
  if (tree.length > 0) lines.push(tree);
  lines.push("</app_state>");
  return lines.join("\n");
}

function consumeScreenshotFile(
  screenshot: NonNullable<ComputerUseGetAppStateResult["screenshot"]>,
  ctx: ToolExecContext,
): ToolResultContent | null {
  try {
    if (!supportsVision(ctx.model)) return null;
    return {
      type: "image",
      data: readFileSync(screenshot.imagePath).toString("base64"),
      mimeType: screenshot.format === "jpeg" ? "image/jpeg" : "image/png",
    };
  } finally {
    unlinkSync(screenshot.imagePath);
  }
}

function renderBounds(bounds: ComputerUseBounds): string {
  return `x=${bounds.x} y=${bounds.y} width=${bounds.width} height=${bounds.height}`;
}

function renderAppIdentity(state: ComputerUseGetAppStateResult): string {
  if (state.bundleId) return state.bundleId;
  if (state.appName) return state.appName;
  return "unknown";
}
