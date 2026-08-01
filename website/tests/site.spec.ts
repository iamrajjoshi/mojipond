import AxeBuilder from "@axe-core/playwright";
import { expect, test, type Page } from "@playwright/test";

const expectNoHorizontalOverflow = async (page: Page) => {
  const dimensions = await page.evaluate(() => ({
    clientWidth: document.documentElement.clientWidth,
    scrollWidth: document.documentElement.scrollWidth,
  }));
  expect(dimensions.scrollWidth).toBeLessThanOrEqual(
    dimensions.clientWidth + 1,
  );
};

test("home page is a full-screen product landing page", async ({ page }) => {
  await page.goto("/");

  await expect(page).toHaveTitle(/MojiPond/);
  await expect(
    page.getByRole("heading", {
      level: 1,
      name: /type :wave:.+get 👋/i,
    }),
  ).toBeVisible();
  await expect(page.getByRole("link", { name: /try it/i })).toBeVisible();
  await expect(page.getByText("Mac app in final testing.")).toHaveCount(0);
  await expect(page.getByText(/Native macOS app/i)).toHaveCount(0);
  await expect(page.getByText(/typing analytics/i)).toHaveCount(0);
  await expect(page.getByText(/built-in Unicode catalog/i)).toHaveCount(0);

  const heroBox = await page.locator(".hero").boundingBox();
  const viewport = page.viewportSize();
  expect(heroBox).not.toBeNull();
  expect(viewport).not.toBeNull();
  expect(heroBox?.x).toBeLessThanOrEqual(1);
  expect(heroBox?.width).toBeGreaterThanOrEqual((viewport?.width ?? 0) - 1);
  expect(heroBox?.height).toBeGreaterThanOrEqual((viewport?.height ?? 0) - 1);

  await expect(page.locator(".pond-scene source").last()).toHaveAttribute(
    "srcset",
    /3840w/,
  );
  await expect(
    page.locator('.pond-scene source[media="(max-width: 700px)"]'),
  ).toHaveAttribute("srcset", /2160w/);
  await expectNoHorizontalOverflow(page);
});

test("the demo supports keyboard selection", async ({ page }) => {
  await page.goto("/#try");

  const input = page.getByRole("combobox", { name: "Message" });
  const listbox = page.getByRole("listbox", { name: "Emoji suggestions" });
  await expect(input).toHaveValue("That fixed it :wa");
  await expect(listbox).toBeVisible();
  await expect(listbox.getByRole("option")).toHaveCount(5);

  await input.focus();
  await page.keyboard.press("ArrowDown");
  await expect(
    listbox.getByRole("option", { name: /:warning:/i }),
  ).toHaveAttribute("aria-selected", "true");

  await page.keyboard.press("Tab");
  await expect(input).toHaveValue("That fixed it ⚠️");
  await expect(listbox).toBeHidden();
});

test("the demo replaces exact shortcuts and recovers after a correction", async ({
  page,
}) => {
  await page.goto("/#try");

  const input = page.getByRole("combobox", { name: "Message" });
  const listbox = page.getByRole("listbox", { name: "Emoji suggestions" });

  await input.fill("Nice :frog:");
  await expect(input).toHaveValue("Nice 🐸");
  await expect(listbox).toBeHidden();

  await input.fill("Nice :fro ");
  await expect(listbox).toBeHidden();
  await page.keyboard.press("Backspace");
  await expect(listbox).toBeVisible();
  await expect(listbox.getByRole("option", { name: /:frog:/i })).toBeVisible();
});

test("demo presets open the matching suggestion", async ({ page }) => {
  await page.goto("/#try");

  await page.getByRole("button", { name: ":sparkles:" }).click();
  await expect(page.getByRole("combobox", { name: "Message" })).toHaveValue(
    "That fixed it :spa",
  );
  const sparkles = page.getByRole("option", { name: /:sparkles:/i });
  await expect(sparkles).toHaveAttribute("aria-selected", "true");
  await sparkles.click();
  await expect(page.getByRole("combobox", { name: "Message" })).toHaveValue(
    "That fixed it ✨",
  );
  await expect(page.getByRole("combobox", { name: "Message" })).toBeFocused();
});

test("home page keeps the five practical answers", async ({ page }) => {
  await page.goto("/");

  for (const question of [
    "What happens?",
    "What happens to animated emoji?",
    "What ZIP files can I import?",
    "Why does it need macOS permissions?",
    "Where does it work?",
  ]) {
    await expect(page.getByText(question, { exact: true })).toBeVisible();
  }
  await expect(page.locator("#privacy")).toHaveCount(0);
});

test("home page has no detectable accessibility violations", async ({
  page,
}) => {
  await page.goto("/");
  const results = await new AxeBuilder({ page }).analyze();
  expect(results.violations).toEqual([]);
});

test("mobile layout stays inside the viewport", async ({ page, isMobile }) => {
  test.skip(!isMobile, "Mobile layout applies only to the mobile project.");
  await page.goto("/");
  await expectNoHorizontalOverflow(page);
});

test("short viewports keep the picker below the hero copy", async ({
  page,
}) => {
  await page.setViewportSize({ width: 720, height: 450 });
  await page.goto("/");

  const copyBox = await page.locator(".hero-copy").boundingBox();
  const pickerBox = await page.locator(".hero-picker").boundingBox();
  expect(copyBox).not.toBeNull();
  expect(pickerBox).not.toBeNull();
  expect((copyBox?.y ?? 0) + (copyBox?.height ?? 0)).toBeLessThanOrEqual(
    pickerBox?.y ?? 0,
  );
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

test("privacy page describes local Noto filtering", async ({ page }) => {
  await page.goto("/privacy/");

  await expect(page.getByText(/filters it on your Mac/)).toBeVisible();
  await expect(page.getByText(/doesn't send your search query/)).toBeVisible();
});
