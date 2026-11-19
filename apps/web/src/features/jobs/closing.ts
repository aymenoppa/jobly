/**
 * Closing or archiving a job from its page. The database takes the visits its schedule made that
 * are still to come off the schedule with it (supabase/migrations/20261113000120_closed_jobs_leave_the_schedule.sql),
 * so the page asks first when there are any, with how many (public.job_visits_to_remove).
 */

/** What the page asks before closing or archiving a job that loses `going` visits; null when it loses none, and nothing is asked. */
export function closeQuestion(status: "completed" | "archived", jobNumber: number | null, going: number): { title: string; body: string; confirmLabel: string } | null {
  if (!(going > 0)) return null;
  const act = status === "archived" ? "Archive" : "Close";
  return {
    title: `${act} job #${jobNumber ?? ""}?`,
    body: `This also removes ${going} upcoming ${going === 1 ? "visit" : "visits"} from the schedule. Reopening the job schedules them again.`,
    confirmLabel: `${act} job`,
  };
}
