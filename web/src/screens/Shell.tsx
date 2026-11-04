import { useEffect, useState } from "react";
import { OwnershipMark } from "./OwnershipMark";
import { CompanySettlement } from "./CompanySettlement";
import { Accounts } from "./Accounts";

type Section = { id: string; label: string; title: string; empty: string; phone: boolean };

// Экраны появятся в следующих тикетах; пока у каждого пустое состояние.
const sections: Section[] = [
  { id: "overview", label: "Обзор", title: "Обзор", empty: "Счетов пока нет. Добавьте первый счёт, и здесь появятся остаток, свои деньги и аванс.", phone: true },
  { id: "entries", label: "Записи", title: "Записи", empty: "Записей пока нет. Запишите первую трату.", phone: true },
  { id: "inbox", label: "Инбокс", title: "Инбокс", empty: "Инбокс пуст: черновиков, записей без категории и новых заметок нет.", phone: true },
  { id: "company", label: "С компанией", title: "Расчёт с компанией", empty: "", phone: true },
  { id: "accounts", label: "Счета", title: "Счета", empty: "Счетов пока нет. Добавьте карту, банковский счёт или наличные.", phone: false },
];

function sectionFromHash(): Section {
  const id = window.location.hash.replace(/^#\/?/, "");
  return sections.find((s) => s.id === id) ?? sections[0]!;
}

export function Shell({
  email,
  name,
  onSignOut,
  accountingStartDate,
}: {
  email: string;
  name: string | null;
  onSignOut: () => void;
  accountingStartDate: string;
}) {
  const [current, setCurrent] = useState(sectionFromHash);

  useEffect(() => {
    const onHash = () => setCurrent(sectionFromHash());
    window.addEventListener("hashchange", onHash);
    return () => window.removeEventListener("hashchange", onHash);
  }, []);

  const link = (s: Section) => (
    <a key={s.id} href={`#/${s.id}`} aria-current={s.id === current.id ? "page" : undefined}>
      {s.label}
    </a>
  );
  const phoneSections = sections.filter((s) => s.phone);

  return (
    <div className="shell">
      <header className="shell__header">
        <span className="shell__brand">
          <OwnershipMark />
          Трекер затрат
        </span>
        <span className="shell__header-actions">
          <a className="button button--quiet" href="#/accounts" aria-current={current.id === "accounts" ? "page" : undefined}>
            Счета
          </a>
          <button className="button button--quiet" type="button" onClick={onSignOut}>
            Выйти
          </button>
        </span>
      </header>

      <aside className="shell__side">
        <span className="shell__brand">
          <OwnershipMark />
          Трекер затрат
        </span>
        <CaptureButton wide />
        <nav className="nav nav--side" aria-label="Разделы">
          {sections.map(link)}
        </nav>
        <div className="shell__account">
          <span>{name ?? email}</span>
          {name && <span className="muted">{email}</span>}
          <button className="button button--quiet" type="button" onClick={onSignOut}>
            Выйти
          </button>
        </div>
      </aside>

      <main className="shell__main">
        <section className="section" aria-labelledby="section-title">
          <h1 id="section-title">{current.title}</h1>
          {current.id === "company" ? (
            <CompanySettlement accountingStartDate={accountingStartDate} />
          ) : current.id === "accounts" ? (
            <Accounts accountingStartDate={accountingStartDate} />
          ) : (
            <p className="empty">{current.empty}</p>
          )}
        </section>
      </main>

      <nav className="nav nav--bottom" aria-label="Разделы">
        {phoneSections.slice(0, 2).map(link)}
        <CaptureButton />
        {phoneSections.slice(2).map(link)}
      </nav>
    </div>
  );
}

/** «Записать»: форма записи появится в тикете 07. */
function CaptureButton({ wide }: { wide?: boolean }) {
  return (
    <button className="capture" type="button" disabled title="Запись появится в следующей версии" aria-label="Записать">
      {wide ? "+ Записать" : "+"}
    </button>
  );
}
