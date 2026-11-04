import { describe, expect, it } from "vitest";
import { debtDirection, formatRate } from "./overview";

describe("debtDirection", () => {
  it("a positive net reads as the company owing you that much", () => {
    expect(debtDirection(600000)).toBe("Компания должна вам 6\u00a0000\u00a0₸");
  });
  it("a negative net reads as you owing the company, without a minus", () => {
    expect(debtDirection(-900050)).toBe("Вы должны компании 9\u00a0000,50\u00a0₸");
  });
  it("zero means you and the company are settled", () => {
    expect(debtDirection(0)).toBe("Вы с компанией в расчёте");
  });
});

describe("formatRate", () => {
  it("shows the server's rate string with a decimal comma", () => {
    expect(formatRate("475.25")).toBe("475,25");
    expect(formatRate("480")).toBe("480");
  });
});
