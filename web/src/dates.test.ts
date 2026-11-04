import { describe, expect, it } from "vitest";
import { formatDate, todayInAlmaty } from "./dates";

describe("todayInAlmaty", () => {
  it("gives the Almaty calendar date (UTC+5), not the UTC one", () => {
    expect(todayInAlmaty(new Date("2026-11-04T18:59:00Z"))).toBe("2026-11-04");
    expect(todayInAlmaty(new Date("2026-11-04T19:00:00Z"))).toBe("2026-11-05");
  });
});

describe("formatDate", () => {
  it("writes an ISO date the Russian way, without the year suffix", () => {
    expect(formatDate("2026-11-01")).toBe("1 ноября 2026");
  });
});
