/**
 * Closing or archiving a job from its page (features/jobs/closing.ts): it asks first only when
 * visits will go with it, and says how many. Which visits go is the database's to say
 * (supabase/tests/closed_jobs_test.sql).
 */
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { closeQuestion } from "../src/features/jobs/closing";

describe("closing or archiving a job", () => {
  it("asks nothing when no visits go with it", () => {
    expect(closeQuestion("archived", 12, 0)).toBeNull();
    expect(closeQuestion("completed", 12, 0)).toBeNull();
  });

  it("says how many upcoming visits are removed, and that reopening brings them back", () => {
    expect(closeQuestion("archived", 12, 8)).toEqual({
      title: "Archive job #12?",
      body: "This also removes 8 upcoming visits from the schedule. Reopening the job schedules them again.",
      confirmLabel: "Archive job",
    });
    expect(closeQuestion("completed", 40, 1)).toEqual({
      title: "Close job #40?",
      body: "This also removes 1 upcoming visit from the schedule. Reopening the job schedules them again.",
      confirmLabel: "Close job",
    });
  });

  it("is asked by the job's page for both, with the database's count, and a reopened recurring job gets its visits made again", () => {
    const page = readFileSync(fileURLToPath(new URL("../src/features/jobs/JobPage.tsx", import.meta.url)), "utf8");
    expect(page).toContain('rpc("job_visits_to_remove", { p_job: id })');
    expect(page).toContain('onSelect: () => closeJob("completed")');
    expect(page).toContain('onSelect: () => closeJob("archived")');
    expect(page).toContain('if (patch.status === "active" && j?.kind === "recurring" && canDispatch) await api.post(`/jobs/${id}/generate-visits`)');
  });
});
