import { describe, expect, it } from "vitest";
import { createSession, makeState, readSession, verifyCsrf, verifyState } from "../lib/auth";

const secret = "test-only-session-secret-that-is-long-enough-for-hmac";

describe("OAuth state protection", () => {
  it("accepts a matching signed state once within its time window", () => {
    const state = makeState(secret, 1000);
    expect(verifyState(state, state, secret, 1001)).toBe(true);
    expect(verifyState(state, `${state}x`, secret, 1001)).toBe(false);
    expect(verifyState(state, state, "a-different-secret-that-is-also-long-enough", 1001)).toBe(false);
    expect(verifyState(state, state, secret, 1000 + 601)).toBe(false);
  });
});

describe("signed sessions", () => {
  it("round-trips minimal identity without any provider token", () => {
    const cookie = createSession({ id: "12345678901234567", username: "molly", avatar: null }, secret, 5000);
    expect(readSession(cookie, secret, 5001)).toMatchObject({ id: "12345678901234567", username: "molly", exp: 5000 + 60 * 60 * 8 });
    expect(cookie.includes("access_token")).toBe(false);
  });
  it("rejects tampered, expired, oversized, and malformed cookies", () => {
    const cookie = createSession({ id: "12345678901234567", username: "molly", avatar: null }, secret, 5000);
    expect(readSession(`${cookie}x`, secret, 5001)).toBeNull();
    expect(readSession(cookie, secret, 5000 + 60 * 60 * 8)).toBeNull();
    expect(readSession("x".repeat(2049), secret)).toBeNull();
    expect(readSession(undefined, secret)).toBeNull();
  });
  it("rejects invalid identity claims", () => {
    expect(() => createSession({ id: "not-an-id", username: "x", avatar: null }, secret)).toThrow("invalid_user");
  });
  it("matches a session CSRF token without accepting malformed values", () => {
    expect(verifyCsrf("a".repeat(32), "a".repeat(32))).toBe(true);
    expect(verifyCsrf("a".repeat(32), "b".repeat(32))).toBe(false);
    expect(verifyCsrf("a".repeat(32), "a".repeat(31))).toBe(false);
    expect(verifyCsrf("a".repeat(32), "x".repeat(129))).toBe(false);
  });
});
