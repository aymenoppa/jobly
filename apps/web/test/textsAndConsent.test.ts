/**
 * Who gets texted, on the screens that decide it: the office's Texts switch on a client and on
 * each contact, a new contact starting unticked for texts, the line under a public form's phone box
 * that says what giving a number agrees to, and where a number came from shown to the office.
 * Checked in the screens' own source, as the other screens' wording is.
 */
import { readFileSync } from "node:fs";
import { fileURLToPath, URL } from "node:url";
import { describe, expect, it } from "vitest";
import { TEXT_TICK_HINT } from "../src/features/clients/ContactsCard";
import { TEXTS_BACK_ON_BODY } from "../src/features/clients/TextsSwitch";

const source = (path: string) => readFileSync(fileURLToPath(new URL(path, import.meta.url)), "utf8");

describe("the office's Texts switch", () => {
  it("is on the client and on each contact, for owners, admins and the office", () => {
    const page = source("../src/features/clients/ClientPage.tsx");
    expect(page).toContain("{isOffice && c.phone ? (");
    expect(page).toContain("<TextsSwitch clientId={c.id} name={c.display_name} phone={c.phone} stop={stopFor(c.phone)} since={c.sms_opt_out_at} />");
    expect(page).toContain("<ContactsCard clientId={c.id} canEdit={canSell} canSetTexts={isOffice} />");
    expect(source("../src/features/clients/ContactsCard.tsx")).toContain("{c.phone && canSetTexts && <span className=\"small\"><TextsSwitch clientId={clientId} contactId={c.id}");
  });

  it("goes through the server's one way to set it, asks how they asked, and says to turn texts back on only if they asked", () => {
    const control = source("../src/features/clients/TextsSwitch.tsx");
    expect(control).toContain("api.post<{ on: boolean; phone: string }>(`/clients/${clientId}/texts`");
    expect(control).toContain('<Field label="How did they ask?">');
    expect(TEXTS_BACK_ON_BODY).toContain("Only turn texts back on if they asked you to.");
    // A number that texted STOP is Twilio's to turn back on: the switch is locked.
    expect(control).toContain("const locked = Boolean(stop && twilioHasStop(stop.source));");
    expect(control).toContain("disabled={locked || set.isPending}");
  });
});

describe("agreeing to texts", () => {
  it("leaves a new contact unticked for texts, with a hint to tick only who agreed", () => {
    const card = source("../src/features/clients/ContactsCard.tsx");
    expect(card).toContain("notify_sms: contact?.notify_sms ?? false,");
    // An existing contact keeps the tick they have; emails still start ticked.
    expect(card).toContain("notify_email: contact?.notify_email ?? true,");
    expect(TEXT_TICK_HINT).toBe("Tick only if they've agreed to get texts.");
    expect(card).toContain("{TEXT_TICK_HINT}");
  });

  it("says under a public form's phone box what giving a number agrees to, when the business texts", () => {
    for (const page of ["../src/features/booking/BookingFormPage.tsx", "../src/features/public/ReferralPage.tsx"]) {
      expect(source(page), page).toContain('<Field label="Phone" hint={view.data.company.texts ? textDisclosure(view.data.company.name) : undefined}>');
    }
  });

  it("shows the office where a client's number came from", () => {
    const page = source("../src/features/clients/ClientPage.tsx");
    expect(page).toContain("sms_consent_at, sms_consent_source");
    expect(page).toContain("textConsentLine(c.sms_consent_source, c.sms_consent_at ? formatDate(c.sms_consent_at) : null)");
  });
});
