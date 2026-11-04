import AxeBuilder from "@axe-core/playwright";
import { expect, test } from "@playwright/test";

test("public layouts fit the requested mobile, tablet, and desktop widths", async ({ page }) => {
  for (const width of [360, 390, 768, 1440]) {
    for (const route of ["/", "/meet-molly", "/commands", "/shop", "/dashboard"]) {
      await page.setViewportSize({ width, height: 900 });
      await page.goto(route);
      const dimensions = await page.evaluate(() => ({ document: document.documentElement.scrollWidth, viewport: document.documentElement.clientWidth }));
      expect(dimensions.document, `horizontal overflow at ${width}px on ${route}`).toBeLessThanOrEqual(dimensions.viewport);
      if (route === "/") await expect(page.getByRole("heading", { level: 1 })).toContainText("Molly");
    }
  }
});

test("mobile navigation and command search work", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/");
  await page.locator(".mobile-menu summary").click();
  await page.locator(".mobile-menu").getByRole("link", { name: "Commands" }).click();
  await expect(page.getByRole("heading", { level: 1 })).toContainText("Commands");
  await page.getByPlaceholder("Search commands…").fill("daily");
  await expect(page.locator(".command-card")).toHaveCount(1);
  await expect(page.locator(".command-card").first()).toContainText("Claim your daily reward");
});

test("dashboard stays honest about missing bot integration and protects its API", async ({ page, request }) => {
  await page.goto("/dashboard");
  await expect(page.getByRole("button", { name: "Discord login is not configured yet" })).toBeDisabled();
  await expect(page.getByText("Server list unavailable")).toBeVisible();
  const response = await request.get("/api/dashboard/guilds");
  expect(response.status()).toBe(401);
  expect((await request.get("/api/auth/login")).status()).toBe(503);
  expect((await request.get("/api/auth/callback")).status()).toBe(503);
});

test("public pages meet axe WCAG 2.1 AA checks", async ({ page }) => {
  for (const route of ["/", "/meet-molly", "/commands", "/shop", "/diary", "/dashboard", "/support", "/legal/privacy"]) {
    await page.goto(route);
    const results = await new AxeBuilder({ page }).withTags(["wcag2a", "wcag2aa", "wcag21a", "wcag21aa"]).analyze();
    expect(results.violations, `${route}: ${results.violations.map((item) => `${item.id}: ${item.nodes.map((node) => node.target.join(", ")).join(" | ")}`).join("; ")}`).toEqual([]);
  }
});

test("response has security headers and nonce-based script policy", async ({ page }) => {
  const response = await page.goto("/");
  const headers = response?.headers() || {};
  expect(headers["x-content-type-options"]).toBe("nosniff");
  expect(headers["x-frame-options"]).toBe("DENY");
  expect(headers["referrer-policy"]).toBe("strict-origin-when-cross-origin");
  expect(headers["content-security-policy"]).toContain("'nonce-");
  expect(headers["content-security-policy"]).not.toContain("unsafe-eval");
});
