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
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.goto("/");

  await expect(page).toHaveTitle(/MojiPond/);
  await expect(
    page.getByRole("heading", {
      level: 1,
      name: /type :wave:.+get 👋/i,
    }),
  ).toBeVisible();
  await expect(page.getByText("Mac app in final testing.")).toHaveCount(0);
  await expect(page.getByText(/Native macOS app/i)).toHaveCount(0);
  await expect(page.getByText(/typing analytics/i)).toHaveCount(0);
  await expect(page.getByText(/built-in Unicode catalog/i)).toHaveCount(0);
  await expect(page.locator(".hero-summary > span")).toHaveText([
    "MojiPond puts emoji suggestions beside your cursor.",
    "Pick one and keep typing.",
  ]);

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
  await expect(page.locator(".hero-picker-shell img")).toHaveCount(0);
  await expect(page.getByRole("option")).toHaveCount(5);
  await expect(page.getByRole("option").last()).toBeVisible();
  await expect(page.locator(".picker-keys")).toBeVisible();
  await expectNoHorizontalOverflow(page);
});

test("hero demo types, replaces, and sends the shortcut", async ({ page }) => {
  await page.goto("/");

  const demo = page.locator("[data-hero-demo]");
  const observed = await page.evaluate(() => {
    const demo = document.querySelector<HTMLElement>("[data-hero-demo]");
    const input = document.querySelector<HTMLInputElement>(
      "[data-shortcode-input]",
    );
    const demoMessage = document.querySelector<HTMLElement>(
      "[data-demo-message]",
    );

    return new Promise<{
      values: string[];
      phases: string[];
      sentBubbleVisible: boolean;
    }>((resolve, reject) => {
      if (!demo || !input || !demoMessage) {
        reject(new Error("Hero demo is missing."));
        return;
      }

      const values = new Set<string>();
      const phases = new Set<string>();
      const deadline = Date.now() + 6_000;
      const sample = () => {
        values.add(input.value);
        phases.add(demo.dataset.phase ?? "");
        if (demo.dataset.phase === "sent") {
          resolve({
            values: [...values],
            phases: [...phases],
            sentBubbleVisible: !demoMessage.hidden,
          });
          return;
        }
        if (Date.now() >= deadline) {
          reject(new Error("Hero demo did not finish."));
          return;
        }
        window.setTimeout(sample, 40);
      };
      sample();
    });
  });

  expect(observed.values).toEqual(
    expect.arrayContaining(["That fixed it :wa", "That fixed it 👋", ""]),
  );
  expect(observed.phases).toEqual(
    expect.arrayContaining(["accepting", "inserted", "sent"]),
  );
  expect(observed.sentBubbleVisible).toBe(true);
  await expect(demo).toHaveAttribute("data-phase", "sent");
  await expect(page.locator("[data-demo-message]")).toContainText(
    "That fixed it 👋",
  );
  await expect(page.getByRole("button", { name: "Pause demo" })).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Play demo" })).toHaveCount(0);
});

test("hero demo stays still when reduced motion is requested", async ({
  page,
}) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.goto("/");

  const demo = page.locator("[data-hero-demo]");
  const input = page.getByRole("combobox", { name: "Message" });
  await expect(demo).toHaveAttribute("data-phase", "picker");
  await expect(demo).toHaveAttribute("data-mode", "static");
  await expect(input).toHaveValue("That fixed it :wa");
  await expect(
    page.getByRole("listbox", { name: "Emoji suggestions" }),
  ).toBeVisible();

  await page.waitForTimeout(800);
  await expect(demo).toHaveAttribute("data-phase", "picker");
  await expect(demo).toHaveAttribute("data-mode", "static");
  await expect(input).toHaveValue("That fixed it :wa");
});

test("focusing and typing permanently stops the autoplay", async ({ page }) => {
  await page.goto("/");

  const demo = page.locator("[data-hero-demo]");
  const input = page.getByRole("combobox", { name: "Message" });
  await input.focus();
  await input.fill("My own message");

  await expect(demo).toHaveAttribute("data-mode", "interactive");
  await page.waitForTimeout(2_200);
  await expect(input).toHaveValue("My own message");
  await expect(demo).toHaveAttribute("data-mode", "interactive");
});

test("the demo supports keyboard selection", async ({ page }) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.goto("/");

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
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.goto("/");

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

test("Return inserts an open suggestion, then sends multiple messages", async ({
  page,
}) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.goto("/");

  const input = page.getByRole("combobox", { name: "Message" });
  const listbox = page.getByRole("listbox", { name: "Emoji suggestions" });
  const userMessages = page.locator("[data-user-message]");

  await input.focus();
  await page.keyboard.press("Enter");
  await expect(input).toHaveValue("That fixed it 👋");
  await expect(listbox).toBeHidden();
  await expect(userMessages).toHaveCount(0);

  await page.keyboard.press("Enter");
  await expect(userMessages).toHaveCount(1);
  await expect(userMessages.nth(0)).toHaveText("That fixed it 👋");
  await expect(input).toHaveValue("");
  await expect(input).toBeFocused();

  await input.fill("Nice :frog:");
  await expect(input).toHaveValue("Nice 🐸");
  await page.keyboard.press("Enter");
  await expect(userMessages).toHaveCount(2);
  await expect(userMessages.nth(1)).toHaveText("Nice 🐸");
  await expect(input).toHaveValue("");
  await expect(input).toBeFocused();
});

test("the send button resolves a suggestion and keeps every message", async ({
  page,
}) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.goto("/");

  const input = page.getByRole("combobox", { name: "Message" });
  const send = page.getByRole("button", { name: "Send message" });
  const userMessages = page.locator("[data-user-message]");

  await input.fill("Ship it :frog");
  await send.click();
  await expect(userMessages).toHaveText(["Ship it 🐸"]);

  for (let index = 1; index <= 5; index += 1) {
    await input.fill(`Message ${index}`);
    await send.click();
  }

  await expect(userMessages).toHaveCount(6);
  await expect(userMessages.last()).toHaveText("Message 5");
});

test("moving the caret refreshes the active shortcut", async ({ page }) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.goto("/");

  const input = page.getByRole("combobox", { name: "Message" });
  const listbox = page.getByRole("listbox", { name: "Emoji suggestions" });
  await input.fill("Use :wave here");
  await input.evaluate((element: HTMLInputElement) => {
    element.setSelectionRange(4, 4);
  });
  await expect(listbox).toBeHidden();

  await input.evaluate((element: HTMLInputElement) => {
    element.setSelectionRange(8, 8);
  });
  await expect(listbox).toBeVisible();
  await page.keyboard.press("Tab");
  await expect(input).toHaveValue("Use 👋 here");
});

test("home page stays focused on the hero and demo", async ({ page }) => {
  await page.goto("/");

  for (const question of [
    "What happens?",
    "What happens to animated emoji?",
    "What ZIP files can I import?",
    "Why does it need macOS permissions?",
    "Where does it work?",
  ]) {
    await expect(page.getByText(question, { exact: true })).toHaveCount(0);
  }
  await expect(page.locator(".details-section")).toHaveCount(0);
  await expect(page.locator(".demo-section")).toHaveCount(0);
  await expect(page.locator("#try")).toHaveCount(0);
  await expect(page.locator("[data-hero-demo-shell]")).toHaveCount(1);
  await expect(page.getByRole("combobox", { name: "Message" })).toHaveCount(1);
  await expect(
    page.getByRole("button", { name: /(?:pause|play) demo/i }),
  ).toHaveCount(0);
  await expect(page.getByRole("link", { name: "Privacy" })).toHaveCount(0);
  await expect(page.getByRole("link", { name: "Terms" })).toHaveCount(0);
});

test("footer links to the deployed source revision", async ({ page }) => {
  await page.goto("/");

  const sourceLink = page.getByRole("link", {
    name: /© 2026 MojiPond · commit/i,
  });
  await expect(sourceLink).toHaveAttribute(
    "href",
    /^https:\/\/github\.com\/iamrajjoshi\/mojipond\/(?:commit\/[0-9a-f]{40}|commits\/main)$/i,
  );
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
  const pickerBox = await page.locator(".hero-picker-shell").boundingBox();
  const heroBox = await page.locator(".hero").boundingBox();
  expect(copyBox).not.toBeNull();
  expect(pickerBox).not.toBeNull();
  expect(heroBox).not.toBeNull();
  expect((copyBox?.y ?? 0) + (copyBox?.height ?? 0)).toBeLessThanOrEqual(
    pickerBox?.y ?? 0,
  );
  expect((pickerBox?.y ?? 0) + (pickerBox?.height ?? 0)).toBeLessThanOrEqual(
    (heroBox?.y ?? 0) + (heroBox?.height ?? 0) + 1,
  );
});

test("removed legal routes use the branded 404", async ({ page }) => {
  for (const path of ["/privacy/", "/terms/"]) {
    const response = await page.goto(path);
    expect(response?.status()).toBe(404);
    await expect(
      page.getByRole("heading", { name: "That shortcut leads nowhere." }),
    ).toBeVisible();
  }

  const response = await page.goto("/missing-page/");
  expect(response?.status()).toBe(404);
  await expect(
    page.getByRole("heading", { name: "That shortcut leads nowhere." }),
  ).toBeVisible();
});
