const NBSP = " ";
const MINUS = "−";

const SUFFIX_SIGNS: Record<string, string> = { KZT: "₸", EUR: "€", RUB: "₽", TRY: "₺" };
const PREFIX_SIGNS: Record<string, string> = { USD: "$" };

function groupThousands(digits: string): string {
  return digits.replace(/\B(?=(\d{3})+(?!\d))/g, NBSP);
}

/**
 * Сумма в минимальных единицах (тиынах, центах) → текст для экрана:
 * неразрывный пробел между тысячами, запятая перед копейками,
 * копейки только если не нулевые.
 */
export function formatMoney(minor: number, currency: string): string {
  if (!Number.isSafeInteger(minor)) throw new RangeError(`not whole minor units: ${minor}`);
  const abs = Math.abs(minor);
  const major = Math.trunc(abs / 100);
  const kopecks = abs % 100;
  const fraction = kopecks === 0 ? "" : `,${String(kopecks).padStart(2, "0")}`;
  const number = `${groupThousands(String(major))}${fraction}`;
  const sign = minor < 0 ? MINUS : "";

  const prefix = PREFIX_SIGNS[currency];
  if (prefix) return `${sign}${prefix}${number}`;
  return `${sign}${number}${NBSP}${SUFFIX_SIGNS[currency] ?? currency}`;
}

export type ParsedAmount = { ok: true; minor: number } | { ok: false; error: AmountInputError };
export type AmountInputError = "empty" | "invalid" | "too_many_decimals";

/** Текст из поля суммы → минимальные единицы, без float. */
export function parseAmountInput(text: string): ParsedAmount {
  const compact = text.replace(/[\s\u00a0]/g, "");
  if (compact === "") return { ok: false, error: "empty" };
  const match = /^(\d+)(?:[.,](\d*))?$/.exec(compact);
  if (!match) return { ok: false, error: "invalid" };
  const whole = match[1] ?? "";
  const fraction = match[2] ?? "";
  if (fraction.length > 2) return { ok: false, error: "too_many_decimals" };
  const minor = Number(whole) * 100 + Number(fraction.padEnd(2, "0"));
  if (!Number.isSafeInteger(minor)) return { ok: false, error: "invalid" };
  return { ok: true, minor };
}

/** Текст поля суммы при наборе → тот же текст с разделителем тысяч. */
export function formatAmountInput(text: string): string {
  const compact = text.replace(/[\s ]/g, "");
  const match = /^(\d*)([.,]\d*)?$/.exec(compact);
  if (!match) return text;
  return `${groupThousands(match[1] ?? "")}${match[2] ?? ""}`;
}
