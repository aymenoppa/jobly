/**
 * A snow customer at a glance, in a popup over the Snow page, the way the Schedule opens a visit
 * (VisitDetails.tsx): where it is (the address opens the person's maps app), who to call, how it's
 * served and by whom, the notes its crew reads on a visit, its photos, and its files, which are
 * added here. Edit opens how it's served (SnowSiteDialog), for the roles snow_sites lets write. A
 * sheet on phones.
 */
import { clockText } from "@jobly/core/snow";
import { useQuery } from "@tanstack/react-query";
import { Link } from "react-router-dom";
import { Button } from "@/components/ui/Button";
import { Dialog } from "@/components/ui/Dialog";
import { Icon } from "@/components/ui/Icon";
import { MapsLink } from "@/components/ui/MapsLink";
import { Note } from "@/components/ui/Note";
import { Skeleton } from "@/components/ui/Skeleton";
import { ErrorState } from "@/components/ui/States";
import { supabase, unwrapOne } from "@/lib/api";
import { placeText } from "@/lib/maps";
import { hasRole, useSession } from "@/lib/session";
import { PhotosCard } from "../files/PhotosCard";
import { PlansCard } from "../plans/PlansCard";
import { customer, inches, located, nameOf, type Member, type Site } from "./snowData";

export function SnowSiteDetails({ site, team, onEdit, onWeather, onClose }: { site: Site; team: Member[]; onEdit: () => void; onWeather: () => void; onClose: () => void }) {
  const session = useSession();
  const more = useQuery({
    queryKey: ["snow", session.company.id, "details", site.job_id],
    queryFn: async () =>
      unwrapOne(await supabase().from("jobs").select("client:clients(id, phone), property:properties(id, line1, line2, city, region, postal_code, lat, lng, notes)").eq("id", site.job_id).maybeSingle(), "This job"),
  });
  const { client, property } = more.data ?? {};
  const address = property ? placeText(property) : "";
  const members = new Map(team.map((m) => [m.user_id, m]));
  const people = site.people.map((p) => nameOf(members.get(p.user_id)));
  const service = [site.clear_by && `Clear by ${clockText(site.clear_by)}`, site.priority === 1 && "First priority", site.priority === 3 && "After the others", site.tell_client && "Customer is told"].filter(Boolean);
  return (
    <Dialog open onClose={onClose} title={customer(site)} description={<>Job #{site.job.number} · {site.job.title}</>} size="lg" focusField={false}>
      <div className="dialog-body">
        <div className="visit-facts">
          <Icon name="pin" size={16} />
          <div>
            {more.isPending ? (
              <Skeleton width="70%" />
            ) : more.error ? (
              <ErrorState compact error={more.error} onRetry={() => more.refetch()} />
            ) : address ? (
              <MapsLink place={property!}>{address}</MapsLink>
            ) : (
              <span className="muted">No address on the job</span>
            )}
            {property?.notes && <span className="muted small pre-wrap" style={{ display: "block", marginTop: 4 }}>{property.notes}</span>}
          </div>

          {client && (
            <>
              <Icon name="user" size={16} />
              <div>
                <Link to={`/clients/${client.id}`}>{site.job.client?.display_name ?? "Client"}</Link>
                {client.phone && <> · <a href={`tel:${client.phone}`}>{client.phone}</a></>}
              </div>
            </>
          )}

          <Icon name="snow" size={16} />
          <div>
            Plow at {inches(Number(site.trigger_in))}
            {site.salt_trigger_in != null ? `, salt at ${inches(Number(site.salt_trigger_in))}` : ", no salting"}
            {site.repeat_in != null && `, again every ${inches(Number(site.repeat_in))}`}
            {service.length > 0 && <span className="muted" style={{ display: "block" }}>{service.join(" · ")}</span>}
          </div>

          <Icon name="users" size={16} />
          <div>
            {site.job.crew?.name ?? (people.length ? people.join(", ") : <span className="text-danger">No one assigned</span>)}
            {site.job.crew && people.length > 0 && <span className="muted" style={{ display: "block" }}>{people.join(", ")}</span>}
          </div>

          <Icon name="note" size={16} />
          <div>{site.job.instructions ? <Note text={site.job.instructions} /> : <span className="muted">No instructions for the crew yet.</span>}</div>
        </div>

        <div className="visit-actions">
          {hasRole(session, "admin", "office") && <Button variant="primary" icon="edit" onClick={onEdit}>Edit</Button>}
          {address && <MapsLink className="btn" place={property!}><Icon name="navigation" size={16} />Directions</MapsLink>}
          {client?.phone && <a className="btn" href={`tel:${client.phone}`}><Icon name="phone" size={16} />Call</a>}
          {located(site) && <Button icon="cloudSnow" onClick={onWeather}>Weather</Button>}
          <Link className="btn" to={`/jobs/${site.job_id}`}><Icon name="job" size={16} />Open job</Link>
        </div>

        <PhotosCard jobId={site.job_id} />
        {/* Once the property is known, so its files from earlier work load with the job's. */}
        {more.data && <PlansCard scope={{ kind: "job", id: site.job_id, propertyId: property?.id ?? null }} />}
      </div>
    </Dialog>
  );
}
