import { describe, expect, it } from "vitest";
import { commands } from "../lib/commands";
import { shopAvailability } from "../lib/catalog";

describe("published Molly source-backed content", () => {
  it("has unique command names and documents actual known prefix cases", () => {
    const names = commands.map((command) => command.name);
    expect(new Set(names).size).toBe(names.length);
    expect(commands.find((command) => command.name === "daily")?.prefix).toBe(true);
    expect(commands.find((command) => command.name === "transaction")?.prefix).toBe(false);
    expect(commands.some((command) => command.name === "eval")).toBe(false);
  });
  it("does not invent shop prices where main has no catalog", () => {
    expect(shopAvailability.available).toBe(false);
    expect(commands.some((command) => command.name === "shop" || command.name === "mine")).toBe(false);
  });
});
