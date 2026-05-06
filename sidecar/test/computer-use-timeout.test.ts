import { expect, test } from "bun:test";
import { RPCMethod } from "../src/rpc/rpc-types";
import { computerUseTimeoutMs } from "../src/agent/tools/computer-use";

test("computer_use_type_text timeout is computed from text length plus 1s buffer", () => {
  const text = "a".repeat(1_000);

  expect(computerUseTimeoutMs(RPCMethod.computerUseTypeText, { text })).toBe(31_000);
});

test("computer_use_type_text timeout counts grapheme clusters like Swift Character", () => {
  const text = "e\u0301".repeat(10);

  expect(computerUseTimeoutMs(RPCMethod.computerUseTypeText, { text })).toBe(5_000);
});

test("non-type_text computer use methods keep their fixed budgets", () => {
  expect(computerUseTimeoutMs(RPCMethod.computerUsePressKey, {})).toBe(5_000);
});
