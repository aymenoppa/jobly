/**
 * Trade weather rules (rain days, paving temperatures, sealcoat dry time). Each business starts with
 * its trade preset's and changes them in Settings → Weather rules (set_weather_rules). Fetching lives
 * in the API.
 */
import { isPavingWork, pavingWorkLabel, type PavingWork } from "./paving";
import { addDays } from "./time";

export interface WeatherRule {
  service_id?: string;          // the price list item's id: matched first, so renaming the item keeps its rule
  applies_to?: string;          // its name (all a rule had before ids); neither = whole job
  work?: string;                // a kind of paving calculator work (PAVING_WORK) instead of an item: jobs priced with the calculator that have it
  min_temp_f?: number;          // e.g. hot-mix asphalt needs 50°F
  max_temp_f?: number;          // e.g. shingles scuff above 90°F
  max_rain_pct?: number;        // e.g. mowing skips above 70%
  max_wind_mph?: number;        // e.g. spraying stops above 10 mph
  requires_dry_hours?: number;  // e.g. sealcoat needs 24 dry hours after
}

export interface DayOutlook {
  date: string; // YYYY-MM-DD
  temp_min_f: number | null;
  temp_max_f: number | null;
  rain_chance_pct: number | null;
  wind_max_mph?: number | null;
  snow_in?: number | null; // inches of snow from 6pm the evening before through that day: an overnight storm counts whole
}

/**
 * Where a business's forecasts come from (Settings → Weather rules, companies.settings.weather_source):
 * the US National Weather Service, free for any use, with Open-Meteo's forecast for a property
 * outside the United States; Open-Meteo's free service everywhere, which its terms keep to
 * non-commercial use; or Open-Meteo with the business's own paid key (Apps → Open-Meteo). The
 * Weather Service is the default: its forecasters set how much snow an inch of water makes storm by
 * storm, where Open-Meteo counts a flat 7 to 1 and so calls most cold storms short.
 */
export const WEATHER_SOURCES = ["nws", "open_meteo", "open_meteo_commercial"] as const;
export type WeatherSource = (typeof WEATHER_SOURCES)[number];
export const WEATHER_SOURCE_LABELS: Record<WeatherSource, string> = {
  open_meteo: "Open-Meteo (non-commercial)",
  open_meteo_commercial: "Open-Meteo (commercial)",
  nws: "US National Weather Service",
};
/** The source a business chose; the National Weather Service until it picks another. */
export const weatherSourceOf = (settings: unknown): WeatherSource => {
  const chosen = (settings as { weather_source?: unknown } | null | undefined)?.weather_source;
  return WEATHER_SOURCES.includes(chosen as WeatherSource) ? (chosen as WeatherSource) : "nws";
};

/** What the sky is doing, in the few words the app uses, however the forecast's provider codes it. */
export type Sky = "clear" | "partly_cloudy" | "cloudy" | "fog" | "drizzle" | "rain" | "freezing_rain" | "snow" | "storm";

/**
 * A place's weather in detail, for the Snow app's weather view: now, hour by hour and day by day.
 * Times are the place's own, as "2026-11-14T18:00". Whatever provider it comes from is turned into
 * this in the API (services/external.ts), so the page never knows which.
 */
export interface PlaceWeather {
  /** Whose forecast this is: the business's choice, or Open-Meteo where that one has none for the place. */
  source: WeatherSource;
  /** wind_from_deg: the compass bearing the wind blows from (0 north, 90 east). */
  now: { time: string; night: boolean; temp_f: number | null; feels_f: number | null; sky: Sky; wind_mph: number | null; gust_mph: number | null; wind_from_deg: number | null; snow_depth_in: number | null };
  /** The next 48 hours, starting with this one. */
  hours: Array<{ time: string; night: boolean; temp_f: number | null; sky: Sky; snow_in: number; rain_chance_pct: number | null; wind_mph: number | null; gust_mph: number | null }>;
  /** Today and the days after it; snow_in is that date's own snow, midnight to midnight. */
  days: Array<{ date: string; sky: Sky; temp_min_f: number | null; temp_max_f: number | null; snow_in: number; rain_chance_pct: number | null; wind_max_mph: number | null; gust_max_mph: number | null }>;
  /** Inches of snow for each date counted from 6pm the evening before, as snow alerts count it. */
  snow_by_day: Record<string, number>;
}

/** A rule in one line, as Settings lists it: "Paver patio: at most 50% rain, 24 dry hours after". */
export function weatherRuleSummary(rule: WeatherRule): string {
  const { min_temp_f: low, max_temp_f: high } = rule;
  const parts = [
    rule.max_rain_pct != null && `at most ${rule.max_rain_pct}% rain`,
    low != null && high != null ? `${low}°F to ${high}°F` : low != null ? `at least ${low}°F` : high != null && `at most ${high}°F`,
    rule.max_wind_mph != null && `wind at most ${rule.max_wind_mph} mph`,
    rule.requires_dry_hours && `${rule.requires_dry_hours} dry hours after`,
  ].filter(Boolean);
  return `${isPavingWork(rule.work) ? pavingWorkLabel(rule.work) : rule.applies_to || "Every job"}: ${parts.join(", ") || "no limits"}`;
}

/** The rules with each one's price list item called what it's called now (`names`: id → name). */
export function namedWeatherRules(rules: WeatherRule[], names: Map<string, string>): WeatherRule[] {
  return rules.map((r) => (r.service_id && names.has(r.service_id) ? { ...r, applies_to: names.get(r.service_id) } : r));
}

/**
 * The rules a job's visits are checked against: the job's own when it has any, otherwise the
 * company's (settings.weather_rules, set in Settings) for the services on the job, plus those for
 * every job. A rule's item is matched by id first (`serviceIds`: the job's items' ids → their names
 * now), then by name: rules saved before ids have only that. A rule for a kind of paving calculator
 * work goes by the kinds on the job's calculator lines (`work`, from pavingWorkOn), which have no
 * price list item to match. All of it comes from JSON people can edit, so anything that isn't a rule
 * is skipped.
 */
export function jobWeatherRules(jobRules: unknown, companyRules: unknown, services: string[], serviceIds = new Map<string, string>(), work: readonly PavingWork[] = []): WeatherRule[] {
  const list = (rules: unknown) => (Array.isArray(rules) ? (rules.filter((r) => r && typeof r === "object") as WeatherRule[]) : []);
  const own = list(jobRules);
  if (own.length) return own;
  const names = new Set(services.map((s) => s.trim().toLowerCase()));
  const applies = (r: WeatherRule) =>
    isPavingWork(r.work)
      ? work.includes(r.work)
      : (!r.applies_to && !r.service_id) || (r.service_id != null && serviceIds.has(r.service_id)) || (r.applies_to != null && names.has(String(r.applies_to).trim().toLowerCase()));
  // A rule for calculator work is called by its kind, whatever name it was saved with.
  return namedWeatherRules(list(companyRules).filter(applies), serviceIds).map((r) => (isPavingWork(r.work) ? { ...r, applies_to: pavingWorkLabel(r.work) } : r));
}

/** Reasons a visit on `date` breaks its rules; empty when the weather is fine. */
export function weatherRisks(rules: WeatherRule[], date: string, outlook: DayOutlook[]): string[] {
  const byDate = new Map(outlook.map((d) => [d.date, d]));
  const day = byDate.get(date);
  const reasons: string[] = [];
  for (const rule of rules) {
    const label = rule.applies_to ? `${rule.applies_to}: ` : "";
    if (day && rule.min_temp_f != null && day.temp_min_f != null && day.temp_min_f < rule.min_temp_f) {
      reasons.push(`${label}low of ${Math.round(day.temp_min_f)}°F is below ${rule.min_temp_f}°F`);
    }
    if (day && rule.max_temp_f != null && day.temp_max_f != null && day.temp_max_f > rule.max_temp_f) {
      reasons.push(`${label}high of ${Math.round(day.temp_max_f)}°F is above ${rule.max_temp_f}°F`);
    }
    if (day && rule.max_rain_pct != null && day.rain_chance_pct != null && day.rain_chance_pct > rule.max_rain_pct) {
      reasons.push(`${label}${day.rain_chance_pct}% chance of rain`);
    }
    if (day && rule.max_wind_mph != null && day.wind_max_mph != null && day.wind_max_mph > rule.max_wind_mph) {
      reasons.push(`${label}wind up to ${Math.round(day.wind_max_mph)} mph`);
    }
    if (rule.requires_dry_hours) {
      // The dry time starts on the visit day itself, so rain that day counts too.
      const days = Math.max(1, Math.ceil(rule.requires_dry_hours / 24));
      for (let i = 0; i <= days; i++) {
        const next = byDate.get(addDays(date, i));
        if (next?.rain_chance_pct != null && next.rain_chance_pct >= 50) {
          reasons.push(`${label}rain likely on ${next.date} during the ${rule.requires_dry_hours}-hour dry time`);
        }
      }
    }
  }
  return reasons;
}
