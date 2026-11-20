import { describe, expect, it } from "vitest";
import { clampIndex, counterLabel, galleryOf, isPlainClick, nearby, slideLabel } from "../src/features/files/gallery";

const click = (over: Partial<Parameters<typeof isPlainClick>[0]> = {}) => ({ button: 0, metaKey: false, ctrlKey: false, shiftKey: false, altKey: false, defaultPrevented: false, ...over });

describe("the photo gallery", () => {
  it("starts on the photo asked for, kept to the photos there are", () => {
    expect(clampIndex(2, 8)).toBe(2);
    expect(clampIndex(-1, 8)).toBe(0);
    expect(clampIndex(12, 8)).toBe(7);
    expect(clampIndex(2.7, 8)).toBe(2);
    expect(clampIndex(Number.NaN, 8)).toBe(0);
    expect(clampIndex(3, 0)).toBe(0);
  });

  it("counts from one, for the counter and for a screen reader", () => {
    expect(counterLabel(2, 8)).toBe("3 of 8");
    expect(counterLabel(0, 1)).toBe("1 of 1");
    expect(counterLabel(9, 8)).toBe("8 of 8");
    expect(slideLabel(2, 8)).toBe("Photo 3 of 8");
  });

  it("loads the photo showing and the one either side, never past the ends", () => {
    expect(nearby(3, 8)).toEqual([2, 3, 4]);
    expect(nearby(0, 8)).toEqual([0, 1]);
    expect(nearby(7, 8)).toEqual([6, 7]);
    expect(nearby(0, 1)).toEqual([0]);
    expect(nearby(0, 0)).toEqual([]);
  });

  it("leaves out photos with no link, so the tapped one is found among those it shows", () => {
    const photos = [
      { id: "a", url: "https://x/a.jpg", file_name: "a.jpg" },
      { id: "b", url: null, file_name: "b.jpg" },
      { id: "c", url: "https://x/c.jpg", file_name: "c.jpg" },
    ];
    const shown = galleryOf(photos, (p) => p.file_name);
    expect(shown).toEqual([
      { id: "a", url: "https://x/a.jpg", alt: "a.jpg" },
      { id: "c", url: "https://x/c.jpg", alt: "c.jpg" },
    ]);
    expect(shown.findIndex((p) => p.id === "c")).toBe(1);
  });

  it("opens on a plain click, and leaves new tabs, windows and downloads to the link", () => {
    expect(isPlainClick(click())).toBe(true);
    expect(isPlainClick(click({ ctrlKey: true }))).toBe(false);
    expect(isPlainClick(click({ metaKey: true }))).toBe(false);
    expect(isPlainClick(click({ shiftKey: true }))).toBe(false);
    expect(isPlainClick(click({ altKey: true }))).toBe(false);
    expect(isPlainClick(click({ button: 1 }))).toBe(false);
    expect(isPlainClick(click({ defaultPrevented: true }))).toBe(false);
  });
});
