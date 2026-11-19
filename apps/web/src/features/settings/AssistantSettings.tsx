/**
 * Settings → AI assistants, for everyone: the one place to add Jobly to Claude or ChatGPT (the
 * connector link and the steps for each), the assistants you've connected and what each can change,
 * and, for owners and admins, the company's own limits and what assistants did
 * (features/apps/AssistantAccess.tsx). The Claude and ChatGPT pages under Apps point here.
 *
 * Also here, because it's each person's own: using your ChatGPT plan for Jobly's own AI
 * (features/apps/ChatGptPlan.tsx).
 */
import { Button } from "@/components/ui/Button";
import { copyText } from "@/lib/clipboard";
import { hasRole, useSession } from "@/lib/session";
import { AssistantAccess, ConnectedAssistants } from "@/features/apps/AssistantAccess";
import { ChatGptPlanCard } from "@/features/apps/ChatGptPlan";
import { CONNECTOR_STEPS } from "@/features/apps/assistantConnections";

export function AssistantSettings() {
  const session = useSession();
  const mcpUrl = `${window.location.origin}/mcp`;
  return (
    <div className="narrow stack">
      <section className="card card-pad stack-sm" aria-labelledby="assistants-connect">
        <strong id="assistants-connect">Connect Claude or ChatGPT</strong>
        <span className="muted small">
          Ask about your clients and schedule, or have it set up your price list, crews, checklists, booking forms, guides and automations for you. It signs in as you, so it never sees more than you can.
        </span>
        <div className="row wrap" style={{ gap: 8 }}>
          <code className="code-pill grow">{mcpUrl}</code>
          <Button icon="copy" onClick={() => copyText(mcpUrl, "Connector link copied")}>Copy</Button>
        </div>
        <details className="more-options">
          <summary>How to add it</summary>
          <div className="stack-sm">
            <strong className="small">Claude</strong>
            <ol className="app-steps">{CONNECTOR_STEPS.anthropic.map((s) => <li key={s}>{s}</li>)}</ol>
            <strong className="small">ChatGPT</strong>
            <ol className="app-steps">{CONNECTOR_STEPS.chatgpt.map((s) => <li key={s}>{s}</li>)}</ol>
          </div>
        </details>
      </section>
      <ConnectedAssistants card />
      {/* Not an assistant that uses Jobly, but Jobly's own AI on this person's ChatGPT plan: shown to whoever may connect one. */}
      {session.role !== "subcontractor" && <ChatGptPlanCard where="settings" />}
      {hasRole(session, "admin") && (
        <section className="card card-pad stack-sm">
          <strong>For everyone at {session.company.name}</strong>
          <AssistantAccess />
        </section>
      )}
    </div>
  );
}
