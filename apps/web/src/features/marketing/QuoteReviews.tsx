/**
 * Marketing → Reviews: "Reviews on quotes" (settings.quote_reviews, reviews.quote_pick;
 * 20261113001130_reviews_on_quotes.sql). Off, nothing changes. On, a quote in the Client Hub (and its
 * PDF, with the second tick) shows the business's Google rating and count and up to three reviews:
 * the ones picked here with "Show on quotes" on a review, else the newest with 5 stars and words.
 * Each shows as it is on Google, the reviewer's name and their words (core reviews.ts quoteReviews), so the
 * office sees here what clients will see.
 */
import { QUOTE_REVIEWS, reviewerDisplayName, type QuoteReviewRow } from "@jobly/core/reviews";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Button } from "@/components/ui/Button";
import { FormError } from "@/components/ui/Field";
import { supabase, unwrap } from "@/lib/api";
import { formatDate } from "@/lib/format";
import { useSession } from "@/lib/session";

type Picked = QuoteReviewRow & { id: string };

export interface QuoteReviewState {
  show: boolean;
  pdf: boolean;
  /** The picked reviews, in order. */
  picked: Picked[];
}

/** The switch and the picks. */
export function useQuoteReviews() {
  const session = useSession();
  return useQuery({
    queryKey: ["quote-reviews", session.company.id],
    queryFn: async (): Promise<QuoteReviewState> => {
      const [company, picked] = await Promise.all([
        supabase().from("companies").select("settings").eq("id", session.company.id).single(),
        supabase().from("reviews").select("id, reviewer_name, reviewer_anonymous, rating, comment, posted_at, quote_pick, deleted_at").eq("company_id", session.company.id).not("quote_pick", "is", null).order("quote_pick"),
      ]);
      const s = ((unwrap(company).settings ?? {}) as { quote_reviews?: { show?: boolean; pdf?: boolean } }).quote_reviews;
      return { show: s?.show === true, pdf: s?.show === true && s?.pdf === true, picked: unwrap(picked) as Picked[] };
    },
  });
}

/** The picks still on Google: one taken off Google never shows, and can't be picked again. */
export const livePicks = (state: QuoteReviewState | undefined) => (state?.picked ?? []).filter((r) => !r.deleted_at);

/** Saves the switch, the PDF tick and the picks together (set_quote_reviews). */
export function useSetQuoteReviews() {
  const session = useSession();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (next: { show: boolean; pdf: boolean; ids: string[] }) =>
      unwrap(await supabase().rpc("set_quote_reviews", { p_company: session.company.id, p_show: next.show, p_pdf: next.pdf, p_ids: next.ids })),
    onSettled: () => {
      for (const key of ["quote-reviews", "reviews"]) queryClient.invalidateQueries({ queryKey: [key, session.company.id] });
    },
  });
}

/**
 * The review menu's item for picking it to show on quotes, or taking it off: three at most, so the
 * fourth says to take one off first.
 */
export function quotePickItem(reviewId: string, state: QuoteReviewState | undefined, save: (ids: string[]) => void) {
  const ids = livePicks(state).map((r) => r.id);
  const on = ids.includes(reviewId);
  return {
    label: on ? "Stop showing on quotes" : ids.length >= QUOTE_REVIEWS ? `Show on quotes (${QUOTE_REVIEWS} picked already)` : "Show on quotes",
    icon: "quote" as const,
    hidden: !state,
    disabled: !on && ids.length >= QUOTE_REVIEWS,
    onSelect: () => save(on ? ids.filter((id) => id !== reviewId) : [...ids, reviewId]),
  };
}

export function QuoteReviewsCard({ hasReviews }: { hasReviews: boolean }) {
  const state = useQuoteReviews();
  const save = useSetQuoteReviews();
  const s = state.data;
  if (!s) return null;
  const picked = livePicks(s);
  const ids = picked.map((r) => r.id);
  const set = (next: Partial<{ show: boolean; pdf: boolean; ids: string[] }>) => save.mutate({ show: s.show, pdf: s.pdf, ids, ...next });
  return (
    <div className="card card-pad stack-sm">
      <strong>Reviews on quotes</strong>
      <label className="switch-row" style={{ fontWeight: 400 }}>
        <input type="checkbox" className="switch" checked={s.show} disabled={save.isPending} onChange={(e) => set({ show: e.target.checked, pdf: e.target.checked && s.pdf })} />
        Show reviews on quotes
      </label>
      {s.show && (
        <label className="switch-row" style={{ fontWeight: 400 }}>
          <input type="checkbox" className="switch" checked={s.pdf} disabled={save.isPending} onChange={(e) => set({ pdf: e.target.checked })} />
          On the quote's PDF too
        </label>
      )}
      <span className="muted small">
        Clients see your Google rating and up to three reviews on the quote as they are on Google: the reviewer's name and their words, with a link to Google to read the rest of a long one. {hasReviews ? "" : "Nothing shows until Google reviews come in."}
      </span>
      {picked.length ? (
        <div className="stack-sm" style={{ gap: 4 }}>
          {picked.map((r) => (
            <div key={r.id} className="row-between small">
              <span>{reviewerDisplayName(r)} · {"★".repeat(r.rating ?? 0)} · {formatDate(r.posted_at)}</span>
              <Button size="sm" variant="ghost" aria-label={`Stop showing ${reviewerDisplayName(r)}'s review on quotes`} onClick={() => set({ ids: ids.filter((id) => id !== r.id) })}>Take off</Button>
            </div>
          ))}
        </div>
      ) : (
        <span className="muted small">None picked, so quotes show your most recent reviews with 5 stars and words. Pick your own with Show on quotes in a review's menu.</span>
      )}
      <FormError error={save.error} />
    </div>
  );
}
