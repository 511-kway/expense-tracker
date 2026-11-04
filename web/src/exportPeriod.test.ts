import { describe, expect, it } from "vitest";
import { filenameFromDisposition, presetPeriod } from "./exportPeriod";

describe("presetPeriod", () => {
  it("this month runs from the 1st to today", () => {
    expect(presetPeriod("month", "2026-11-04")).toEqual({ from: "2026-11-01", to: "2026-11-04" });
  });
  it("last month is the whole previous calendar month, across a year boundary too", () => {
    expect(presetPeriod("last_month", "2026-11-04")).toEqual({ from: "2026-10-01", to: "2026-10-31" });
    expect(presetPeriod("last_month", "2027-01-15")).toEqual({ from: "2026-12-01", to: "2026-12-31" });
    expect(presetPeriod("last_month", "2028-03-01")).toEqual({ from: "2028-02-01", to: "2028-02-29" });
  });
  it("this year runs from January 1st to today", () => {
    expect(presetPeriod("year", "2026-11-04")).toEqual({ from: "2026-01-01", to: "2026-11-04" });
  });
  it("all time has no bounds", () => {
    expect(presetPeriod("all", "2026-11-04")).toEqual({ from: null, to: null });
  });
});

describe("filenameFromDisposition", () => {
  it("takes the archive name the server sent, otherwise a fallback", () => {
    expect(filenameFromDisposition('attachment; filename="export_2026-11-01_2026-11-30_csv.zip"', "x.zip")).toBe(
      "export_2026-11-01_2026-11-30_csv.zip",
    );
    expect(filenameFromDisposition(null, "x.zip")).toBe("x.zip");
  });
});
