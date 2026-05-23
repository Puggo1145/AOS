import { ToolUserError } from "../types";
import type { ComputerUsePoint } from "../../../rpc/rpc-types";
import type { ComputerUseArgs } from "./types";

export function requireCaptureMode(args: ComputerUseArgs): "vision" | "ax" {
  const captureMode = requireString(args, "captureMode");
  if (captureMode !== "vision" && captureMode !== "ax") {
    throw new ToolUserError(`captureMode must be "vision" or "ax".`);
  }
  return captureMode;
}

export function validateMouseArgs(args: ComputerUseArgs): void {
  requireString(args, "stateId");
  const event = requireEvent(args);
  const kind = requireString(event, "event.kind");
  switch (kind) {
    case "click":
      requireEnum(event, "event.button", ["left", "right"]);
      requirePoint(event, "point", "event.point");
      if ("count" in event) requirePositiveInteger(event, "event.count");
      return;
    case "drag":
      requireEnum(event, "event.button", ["left", "right"]);
      requirePoint(event, "from", "event.from");
      requirePoint(event, "to", "event.to");
      return;
    default:
      throw new ToolUserError(`event.kind must be one of click, drag.`);
  }
}

export function validateKeyboardArgs(args: ComputerUseArgs): void {
  const event = requireEvent(args);
  const kind = requireString(event, "event.kind");
  switch (kind) {
    case "text":
      requireString(event, "event.text");
      if ("delayMilliseconds" in event) requireIntegerRange(event, "event.delayMilliseconds", 0, 200);
      return;
    case "keyPress":
      requireString(event, "event.key");
      if ("modifiers" in event) requireStringArray(event, "event.modifiers");
      if ("count" in event) requirePositiveInteger(event, "event.count");
      return;
    case "hotkey":
      requireNonEmptyStringArray(event, "event.modifiers");
      requireString(event, "event.key");
      return;
    default:
      throw new ToolUserError(`event.kind must be one of text, keyPress, hotkey.`);
  }
}

export function validateAXArgs(args: ComputerUseArgs): void {
  const event = requireEvent(args);
  const kind = requireString(event, "event.kind");
  switch (kind) {
    case "focus":
      return;
    case "action":
      requireEnum(event, "event.action", [
        "press",
        "showMenu",
        "pick",
        "confirm",
        "cancel",
        "open",
        "increment",
        "decrement",
        "scrollToVisible",
      ]);
      return;
    case "setValue":
    case "setSelectedText":
      requireString(event, "event.value");
      return;
    case "scroll":
      requireEnum(event, "event.direction", ["up", "down", "left", "right"]);
      requirePositiveNumber(event, "event.pages");
      return;
    default:
      throw new ToolUserError(`event.kind must be one of focus, action, setValue, setSelectedText, scroll.`);
  }
}

export function validateMouseEventWithinScreenshot(
  event: Record<string, unknown>,
  pixelSize: { width: number; height: number },
): void {
  if (pixelSize.width <= 0 || pixelSize.height <= 0) {
    throw new ToolUserError(`screenshot pixelSize must be greater than 0.`);
  }
  const kind = requireString(event, "event.kind");
  switch (kind) {
    case "click":
      validateScreenshotPoint(requirePoint(event, "point", "event.point"), pixelSize);
      return;
    case "drag":
      validateScreenshotPoint(requirePoint(event, "from", "event.from"), pixelSize);
      validateScreenshotPoint(requirePoint(event, "to", "event.to"), pixelSize);
      return;
    default:
      throw new ToolUserError(`event.kind must be one of click, drag.`);
  }
}

export function requireEvent(args: ComputerUseArgs): Record<string, unknown> {
  const event = args.event;
  if (!event || typeof event !== "object" || Array.isArray(event)) {
    throw new ToolUserError("event must be an object.");
  }
  return event as Record<string, unknown>;
}

export function requireString(obj: Record<string, unknown>, path: string): string {
  const key = leafKey(path);
  const value = obj[key];
  if (typeof value !== "string" || value.length === 0) {
    throw new ToolUserError(`${path} is required and must be a non-empty string.`);
  }
  return value;
}

export function requireInteger(obj: Record<string, unknown>, path: string): number {
  const value = obj[leafKey(path)];
  if (typeof value !== "number" || !Number.isInteger(value)) {
    throw new ToolUserError(`${path} must be an integer.`);
  }
  return value;
}

function validateScreenshotPoint(point: ComputerUsePoint, pixelSize: { width: number; height: number }): void {
  if (point.x < 0 || point.x > pixelSize.width || point.y < 0 || point.y > pixelSize.height) {
    throw new ToolUserError(
      `screenshot point ${point.x},${point.y} is outside screenshot ${pixelSize.width}x${pixelSize.height}.`,
    );
  }
}

function requireEnum(obj: Record<string, unknown>, path: string, values: string[]): string {
  const value = requireString(obj, path);
  if (!values.includes(value)) {
    throw new ToolUserError(`${path} must be one of ${values.join(", ")}.`);
  }
  return value;
}

function requirePositiveInteger(obj: Record<string, unknown>, path: string): number {
  const value = requireInteger(obj, path);
  if (value <= 0) {
    throw new ToolUserError(`${path} must be a positive integer.`);
  }
  return value;
}

function requireIntegerRange(obj: Record<string, unknown>, path: string, min: number, max: number): number {
  const value = requireInteger(obj, path);
  if (value < min || value > max) {
    throw new ToolUserError(`${path} must be an integer between ${min} and ${max}.`);
  }
  return value;
}

function requireNumber(obj: Record<string, unknown>, path: string): number {
  const value = obj[leafKey(path)];
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw new ToolUserError(`${path} is required and must be a number.`);
  }
  return value;
}

function requirePositiveNumber(obj: Record<string, unknown>, path: string): number {
  const value = requireNumber(obj, path);
  if (value <= 0) {
    throw new ToolUserError(`${path} is required and must be greater than 0.`);
  }
  return value;
}

function requireStringArray(obj: Record<string, unknown>, path: string): string[] {
  const value = obj[leafKey(path)];
  if (!Array.isArray(value) || !value.every((item) => typeof item === "string" && item.length > 0)) {
    throw new ToolUserError(`${path} is required and must be an array of non-empty strings.`);
  }
  return value;
}

function requireNonEmptyStringArray(obj: Record<string, unknown>, path: string): string[] {
  const value = requireStringArray(obj, path);
  if (value.length === 0) {
    throw new ToolUserError(`${path} is required and must contain at least one non-empty string.`);
  }
  return value;
}

function requirePoint(obj: Record<string, unknown>, key: string, path: string): ComputerUsePoint {
  const value = obj[key];
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new ToolUserError(`${path} is required and must be an object.`);
  }
  const point = value as Record<string, unknown>;
  return {
    x: requireNumber(point, `${path}.x`),
    y: requireNumber(point, `${path}.y`),
  };
}

function leafKey(path: string): string {
  const parts = path.split(".");
  return parts[parts.length - 1]!;
}
