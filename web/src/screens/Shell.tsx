import { useEffect, useState } from "react";
import { OwnershipMark } from "./OwnershipMark";
import { CompanySettlement } from "./CompanySettlement";
import { Accounts, type AccountRow } from "./Accounts";
import { Categories, type CategoryRow } from "./Categories";
import { Entries } from "./Entries";
import { EntryForm, type EntryPrefill, type SaveResult } from "./EntryForm";
import { QuickCapture } from "./QuickCapture";
import { Inbox, useInboxCount } from "./Inbox";
import { NoteComposer, Notes, type NoteRow } from "./Notes";
import { SheetDialog } from "./form";
import { RefundForm, refundParentOf, type RefundParent } from "./RefundForm";
import { supabase } from "../supabase";
import { warningLines, type EntryRow } from "../entries";

type Section = { id: string; label: string; title: string; empty: string; phone: boolean };

// Экраны появятся в следующих тикетах; пока у каждого пустое состояние.
const sections: Section[] = [
  { id: "overview", label: "Обзор", title: "Обзор", empty: "Счетов пока нет. Добавьте первый счёт, и здесь появятся остаток, свои деньги и аванс.", phone: true },
  { id: "entries", label: "Записи", title: "Записи", empty: "Записей пока нет. Запишите первую трату.", phone: true },
  { id: "inbox", label: "Инбокс", title: "Инбокс", empty: "Инбокс пуст: черновиков, записей без категории и новых заметок нет.", phone: true },
  { id: "company", label: "С компанией", title: "Расчёт с компанией", empty: "", phone: true },
  { id: "accounts", label: "Счета", title: "Счета", empty: "Счетов пока нет. Добавьте карту, банковский счёт или наличные.", phone: false },
  { id: "categories", label: "Категории", title: "Категории", empty: "", phone: false },
  { id: "notes", label: "Заметки", title: "Заметки", empty: "", phone: false },
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
  // Лист записи: быстрый ввод (quick), новая полная (entry не задан, prefill из быстрого ввода)
  // или правка. revision перемонтирует экран и обновляет бейдж инбокса после сохранения.
  const [sheet, setSheet] = useState<
    {
      quick?: boolean;
      entry?: EntryRow;
      refundOf?: RefundParent;
      prefill?: EntryPrefill;
      /** Разбор заметки: полная форма из неё. */
      note?: NoteRow;
      /** Новая заметка. */
      newNote?: boolean;
    } | null
  >(null);
  const [revision, setRevision] = useState(0);
  const inboxCount = useInboxCount(revision);
  const [toast, setToast] = useState<string | null>(null);
  const [notices, setNotices] = useState<string[]>([]);

  useEffect(() => {
    if (!toast) return;
    const t = window.setTimeout(() => setToast(null), 3000);
    return () => window.clearTimeout(t);
  }, [toast]);

  async function saved(result: SaveResult) {
    setSheet(null);
    setToast(result.message);
    setRevision((r) => r + 1);
    const extra = result.problem ? [result.problem] : [];
    if (result.warnings.length === 0) return setNotices(extra);
    const { data } = await supabase.from("accounts").select("id, name, currency");
    const names = new Map((data ?? []).map((a) => [a.id as string, a.name as string]));
    const currencies = new Map((data ?? []).map((a) => [a.id as string, a.currency as string]));
    setNotices([...extra, ...warningLines(result.warnings, names, currencies)]);
  }

  useEffect(() => {
    const onHash = () => {
      setCurrent(sectionFromHash());
      setSheet(null);
    };
    window.addEventListener("hashchange", onHash);
    return () => window.removeEventListener("hashchange", onHash);
  }, []);

  const link = (s: Section) => (
    <a key={s.id} href={`#/${s.id}`} aria-current={s.id === current.id ? "page" : undefined}>
      {s.label}
      {s.id === "inbox" && inboxCount > 0 && (
        <span className="badge" aria-label={`, ждут внимания: ${inboxCount}`}>
          {inboxCount}
        </span>
      )}
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
          <a className="button button--quiet" href="#/categories" aria-current={current.id === "categories" ? "page" : undefined}>
            Категории
          </a>
          <a className="button button--quiet" href="#/notes" aria-current={current.id === "notes" ? "page" : undefined}>
            Заметки
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
        <CaptureButton wide onClick={() => setSheet({ quick: true })} />
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
          {notices.length > 0 && (
            <div className="notice" role="status">
              <ul>
                {notices.map((n) => (
                  <li key={n}>{n}</li>
                ))}
              </ul>
              <button className="button button--quiet" type="button" onClick={() => setNotices([])}>
                Понятно
              </button>
            </div>
          )}
          <div key={`${current.id}:${revision}`} className="section__body">
            {current.id === "company" ? (
              <CompanySettlement accountingStartDate={accountingStartDate} onEdit={(entry) => setSheet({ entry })} />
            ) : current.id === "accounts" ? (
              <Accounts accountingStartDate={accountingStartDate} />
            ) : current.id === "categories" ? (
              <Categories />
            ) : current.id === "entries" ? (
              <Entries onEdit={(entry) => setSheet({ entry })} onCreate={() => setSheet({ quick: true })} />
            ) : current.id === "inbox" ? (
              <Inbox
                onOpen={(entry) => setSheet({ entry })}
                onOpenNote={(note) => setSheet({ note })}
                onCapture={() => setSheet({ quick: true })}
              />
            ) : current.id === "notes" ? (
              <Notes onProcess={(note) => setSheet({ note })} onOpenEntry={(entry) => setSheet({ entry })} />
            ) : (
              <p className="empty">{current.empty}</p>
            )}
          </div>
        </section>
      </main>

      {sheet?.newNote && (
        <SheetDialog title="Заметка" onClose={() => setSheet(null)}>
          <NoteComposer
            onSaved={() => {
              setSheet(null);
              setToast("Заметка сохранена");
              setRevision((r) => r + 1);
            }}
          />
        </SheetDialog>
      )}
      {sheet && !sheet.newNote && (
        <EntrySheet
          key={
            sheet.refundOf
              ? `refund:${sheet.refundOf.entry_id}`
              : sheet.note
                ? `note:${sheet.note.id}`
                : (sheet.entry?.entry_id ?? (sheet.quick ? "quick" : sheet.prefill ? "expanded" : "new"))
          }
          quick={sheet.quick}
          prefill={sheet.prefill}
          onExpand={(prefill) => setSheet({ prefill })}
          onNote={() => setSheet({ newNote: true })}
          note={sheet.note}
          entry={sheet.entry}
          refundOf={sheet.refundOf}
          onRefund={(refundOf) => setSheet({ refundOf })}
          accountingStartDate={accountingStartDate}
          onClose={() => setSheet(null)}
          onSaved={(r) => void saved(r)}
        />
      )}
      {toast && (
        <p className="toast" role="status">
          {toast}
        </p>
      )}

      <nav className="nav nav--bottom" aria-label="Разделы">
        {phoneSections.slice(0, 2).map(link)}
        <CaptureButton onClick={() => setSheet({ quick: true })} />
        {phoneSections.slice(2).map(link)}
      </nav>
    </div>
  );
}

/** «Записать»: открывает быстрый ввод траты; из него полная форма для любой записи. */
function CaptureButton({ wide, onClick }: { wide?: boolean; onClick: () => void }) {
  return (
    <button className="capture" type="button" onClick={onClick} aria-label="Записать">
      {wide ? "+ Записать" : "+"}
    </button>
  );
}

/**
 * Лист записи: свежие счета и категории с сервера, затем форма. Возврат покупки (новый по трате
 * или открытый из ленты) идёт своей формой: счёт и категория у него от траты.
 */
function EntrySheet(props: {
  quick?: boolean;
  prefill?: EntryPrefill;
  onExpand: (prefill: EntryPrefill) => void;
  onNote: () => void;
  note?: NoteRow;
  entry?: EntryRow;
  refundOf?: RefundParent;
  onRefund: (parent: RefundParent) => void;
  accountingStartDate: string;
  onClose: () => void;
  onSaved: (result: SaveResult) => void;
}) {
  const [refs, setRefs] = useState<{ accounts: AccountRow[]; categories: CategoryRow[] } | null | "error">(null);
  const refundParent = props.refundOf ?? (props.entry?.type === "refund" ? refundParentOf(props.entry) : null);
  useEffect(() => {
    if (refundParent) return;
    void (async () => {
      const [a, c] = await Promise.all([
        supabase
          .from("v_account_balances")
          .select("account_id, name, bank, type, mask, currency, start_date, balance_minor, advance_minor, own_minor, is_archived, has_entries")
          .order("name"),
        supabase.from("categories").select("id, name, is_archived").order("name"),
      ]);
      if (a.error || c.error) setRefs("error");
      else setRefs({ accounts: a.data as AccountRow[], categories: c.data as CategoryRow[] });
    })();
  }, []);
  if (refundParent)
    return (
      <SheetDialog title="Возврат покупки" onClose={props.onClose}>
        <RefundForm
          parent={refundParent}
          refund={props.entry?.type === "refund" ? props.entry : undefined}
          onSaved={props.onSaved}
        />
      </SheetDialog>
    );
  return (
    <SheetDialog
      title={
        props.quick
          ? "Быстрая трата"
          : props.note
            ? "Запись из заметки"
            : props.entry?.status === "draft"
              ? "Черновик"
              : props.entry
                ? "Запись"
                : "Новая запись"
      }
      onClose={props.onClose}
    >
      {refs === null ? (
        <p className="muted" aria-busy="true">Загружаем счета и категории…</p>
      ) : refs === "error" ? (
        <p className="error" role="alert">
          Не получилось загрузить счета и категории. Закройте и откройте форму снова.
        </p>
      ) : props.quick ? (
        <QuickCapture
          accounts={refs.accounts}
          accountingStartDate={props.accountingStartDate}
          onSaved={props.onSaved}
          onExpand={props.onExpand}
          onNote={props.onNote}
        />
      ) : (
        <EntryForm
          entry={props.entry}
          prefill={props.prefill}
          fromNote={props.note}
          accounts={refs.accounts}
          categories={refs.categories}
          accountingStartDate={props.accountingStartDate}
          onSaved={props.onSaved}
          onRefund={props.onRefund}
        />
      )}
    </SheetDialog>
  );
}
