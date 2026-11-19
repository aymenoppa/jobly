/** What the Share dialog says after people are added to a guide (ShareGuideDialog.tsx). */

/**
 * What adding people did, in a sentence: who was added, and whether each got the link. `typed` is
 * how many addresses were typed. Not `ok` when someone was added but not emailed, with why.
 */
export function addedNote(result: { added: string[]; emailed: string[]; problem: string | null }, typed: number): { ok: boolean; text: string } {
  const n = result.added.length;
  if (!n) return { ok: true, text: typed === 1 ? "They're already on the list." : "They're all on the list already." };
  const who = n === 1 ? result.added[0]! : `${n} people`;
  if (result.emailed.length === n) return { ok: true, text: `Added ${who} and emailed ${n === 1 ? "them" : "each of them"} the link.` };
  if (result.emailed.length) return { ok: false, text: `Added ${who}, and emailed ${result.emailed.length} of them the link. ${result.problem ?? "The rest weren't emailed."}` };
  return { ok: false, text: `Added ${who}. ${result.problem ?? "They weren't emailed the link."}` };
}
