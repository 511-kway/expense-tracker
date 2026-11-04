import { formatMoney } from "./money";

/** Итог с компанией словами: кто кому должен по нетто с сервера (docs/design.md, GLOSSARY.md). */
export function debtDirection(netMinor: number): string {
  if (netMinor > 0) return `Компания должна вам ${formatMoney(netMinor, "KZT")}`;
  if (netMinor < 0) return `Вы должны компании ${formatMoney(-netMinor, "KZT")}`;
  return "Вы с компанией в расчёте";
}

/** Курс с сервера строкой («475.25») → для экрана с десятичной запятой, без float. */
export function formatRate(rate: string): string {
  return rate.replace(".", ",");
}
