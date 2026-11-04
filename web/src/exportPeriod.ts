/** Период экспорта: даты ISO включительно, null = без границы (вся история с этой стороны). */
export type Period = { from: string | null; to: string | null };

export type PeriodPreset = "month" | "last_month" | "year" | "all";

const iso = (y: number, m: number, d: number) =>
  `${String(y).padStart(4, "0")}-${String(m).padStart(2, "0")}-${String(d).padStart(2, "0")}`;

/** Готовый период относительно сегодняшней даты (ISO, по Алматы). */
export function presetPeriod(preset: PeriodPreset, today: string): Period {
  const [y, m] = today.split("-").map(Number) as [number, number];
  switch (preset) {
    case "month":
      return { from: iso(y, m, 1), to: today };
    case "last_month": {
      const [py, pm] = m === 1 ? [y - 1, 12] : [y, m - 1];
      // Нулевой день следующего месяца = последний день этого.
      const last = new Date(Date.UTC(py, pm, 0)).getUTCDate();
      return { from: iso(py, pm, 1), to: iso(py, pm, last) };
    }
    case "year":
      return { from: iso(y, 1, 1), to: today };
    case "all":
      return { from: null, to: null };
  }
}

/** Имя файла из заголовка Content-Disposition ответа функции экспорта. */
export function filenameFromDisposition(header: string | null, fallback: string): string {
  return /filename="([^"]+)"/.exec(header ?? "")?.[1] ?? fallback;
}
