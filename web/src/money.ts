const NBSP = " ";
const MINUS = "−";

const SUFFIX_SIGNS: Record<string, string> = { KZT: "₸", EUR: "€", RUB: "₽", TRY: "₺" };
const PREFIX_SIGNS: Record<string, string> = { USD: "$" };

/** Убирает пробелы и неразрывные пробелы (разделители тысяч). */
function compact(text: string): string {
  return text.replace(/\s/g, "");
}

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
  const minorPart = abs % 100;
  const major = (abs - minorPart) / 100;
  const fraction = minorPart === 0 ? "" : `,${String(minorPart).padStart(2, "0")}`;
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
  const digits = compact(text);
  if (digits === "") return { ok: false, error: "empty" };
  const match = /^(\d+)(?:[.,](\d*))?$/.exec(digits);
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
  const match = /^(\d*)([.,]\d*)?$/.exec(compact(text));
  if (!match) return text;
  return `${groupThousands(match[1] ?? "")}${match[2] ?? ""}`;
}

/** Необязательное поле суммы: пустое = ноль, иначе минимальные единицы или null при ошибке ввода. */
export function amountOrZero(text: string): number | null {
  const parsed = parseAmountInput(text);
  if (parsed.ok) return parsed.minor;
  return parsed.error === "empty" ? 0 : null;
}

/** Сумма в минимальных единицах → текст поля суммы для правки: «60 000», «1 500,50». */
export function minorToAmountInput(minor: number): string {
  if (!Number.isSafeInteger(minor) || minor < 0) throw new RangeError(`not a whole non-negative amount: ${minor}`);
  const minorPart = minor % 100;
  const major = (minor - minorPart) / 100;
  return formatAmountInput(minorPart === 0 ? String(major) : `${major},${String(minorPart).padStart(2, "0")}`);
}

/** Знак валюты, как его показывает formatMoney: «₸», «$», иначе ISO-код. */
export function currencySign(currency: string): string {
  return PREFIX_SIGNS[currency] ?? SUFFIX_SIGNS[currency] ?? currency;
}

export type ParsedRate = { ok: true; rate: string } | { ok: false; error: AmountInputError };

/**
 * Текст поля курса → десятичная строка для сервера («453,87» → "453.87"), без float: курс
 * numeric(18,8), не больше 8 знаков после запятой, больше нуля.
 */
export function parseRateInput(text: string): ParsedRate {
  const digits = compact(text);
  if (digits === "") return { ok: false, error: "empty" };
  const match = /^(\d+)(?:[.,](\d*))?$/.exec(digits);
  if (!match) return { ok: false, error: "invalid" };
  const whole = (match[1] ?? "").replace(/^0+(?=\d)/, "");
  const fraction = (match[2] ?? "").replace(/0+$/, "");
  if ((match[2] ?? "").length > 8) return { ok: false, error: "too_many_decimals" };
  if (/^0*$/.test(whole + fraction)) return { ok: false, error: "invalid" };
  return { ok: true, rate: fraction ? `${whole}.${fraction}` : whole };
}

/** Курс с сервера (строка или число из numeric) → «453,87», «1 234,5»: без лишних нулей. */
export function formatRate(rate: string | number): string {
  const [whole = "", fraction = ""] = String(rate).split(".");
  const trimmed = fraction.replace(/0+$/, "");
  return `${groupThousands(whole)}${trimmed ? `,${trimmed}` : ""}`;
}
