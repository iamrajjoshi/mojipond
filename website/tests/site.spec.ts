import AxeBuilder from "@axe-core/playwright";
import { expect, test, type Page } from "@playwright/test";
import type { ReleaseManifest } from "../src/lib/releaseManifest";

const availableRelease = {
  version: "1.2.3",
  asset: { byteCount: 10_485_760 },
} satisfies ReleaseManifest;

const expectNoHorizontalOverflow = async (page: Page) => {
  const dimensions = await page.evaluate(() => ({
    clientWidth: document.documentElement.clientWidth,
    scrollWidth: document.documentElement.scrollWidth,
  }));
  expect(dimensions.scrollWidth).toBeLessThanOrEqual(
    dimensions.clientWidth + 1,
  );
};

const expectPreviewState = async (page: Page) => {
  const downloadActions = page.locator("[data-release-download]");
  await expect(downloadActions).toHaveCount(2);
  await expect(downloadActions.nth(0)).toBeHidden();
  await expect(downloadActions.nth(1)).toBeHidden();
  await expect(page.locator("[data-release-detail]")).toHaveText([
    "Public build pending Apple signing",
    "Public build pending Apple signing",
  ]);
};

test("home page explains the product without a false download", async ({
  page,
}) => {
  await page.goto("/");

  await expect(page).toHaveTitle(/MojiPond/);
  await expect(
    page.getByRole("heading", {
      level: 1,
      name: /your emoji, one colon away/i,
    }),
  ).toBeVisible();
  await expect(page.getByText("Native Mac app")).toBeVisible();
  await expectPreviewState(page);
  await expectNoHorizontalOverflow(page);
});

test("one release check updates every download action", async ({ page }) => {
  let releaseRequestCount = 0;
  await page.route("**/releases/release.json", async (route) => {
    releaseRequestCount += 1;
    await route.fulfill({
      json: availableRelease,
    });
  });

  await page.goto("/");

  await expect(
    page.getByRole("link", { name: "Download for macOS" }),
  ).toHaveCount(2);
  await expect(page.locator("[data-release-detail]")).toHaveText([
    "Version 1.2.3 · 10 MB · macOS 14 or newer",
    "Version 1.2.3 · 10 MB · macOS 14 or newer",
  ]);
  expect(releaseRequestCount).toBe(1);
});

test("invalid release metadata keeps the preview state", async ({ page }) => {
  await page.route("**/releases/release.json", async (route) => {
    await route.fulfill({
      json: {
        version: "latest",
        asset: { byteCount: "unknown" },
      },
    });
  });

  await page.goto("/");

  await expectPreviewState(page);
});

test("home page has no detectable accessibility violations", async ({
  page,
}) => {
  await page.goto("/");
  const results = await new AxeBuilder({ page }).analyze();
  expect(results.violations).toEqual([]);
});

test("keyboard users can open the first answer", async ({ page }) => {
  await page.goto("/#faq");
  const firstAnswer = page.locator("details").first();
  const firstQuestion = firstAnswer.locator("summary");

  await firstQuestion.focus();
  await expect(firstQuestion).toBeFocused();
  await page.keyboard.press("Enter");

  await expect(firstAnswer).toHaveAttribute("open", "");
  await expect(
    page.getByText(/Unicode shortcuts work in supported macOS text fields/),
  ).toBeVisible();
});

test("mobile navigation opens, closes, and does not overflow", async ({
  page,
  isMobile,
}) => {
  test.skip(!isMobile, "Mobile navigation applies only to the mobile project.");
  await page.goto("/");

  const menuButton = page.locator("[data-menu-button]");
  await menuButton.click();
  await expect(
    page.getByRole("navigation", { name: "Mobile navigation" }),
  ).toBeVisible();
  await expect(menuButton).toHaveAttribute("aria-expanded", "true");

  await page.keyboard.press("Escape");
  await expect(menuButton).toHaveAttribute("aria-expanded", "false");
  await expectNoHorizontalOverflow(page);
});

test("legal pages and the branded 404 are reachable", async ({ page }) => {
  for (const path of ["/privacy/", "/terms/"]) {
    const response = await page.goto(path);
    expect(response?.ok()).toBe(true);
    await expect(page.getByRole("heading", { level: 1 })).toBeVisible();
  }

  const response = await page.goto("/missing-page/");
  expect(response?.status()).toBe(404);
  await expect(
    page.getByRole("heading", { name: "That shortcut leads nowhere." }),
  ).toBeVisible();
});
