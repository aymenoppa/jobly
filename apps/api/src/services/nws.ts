/**
 * The US National Weather Service (api.weather.gov) as a forecast source: its forecasters' own
 * gridded forecast, free for any use and with no key, for places in the United States. Anywhere
 * else it has nothing (a 404), and services/forecast.ts falls back to Open-Meteo.
 *
 * A place is first looked up for its grid cell (about 2.5 km, on its forecast office's own grid),
 * which never moves, so that's remembered. The cell's forecast comes as layers (temperature,
 * snowfall, wind and so on), each a list of values that hold for a stretch of hours; hoursOf lays
 * them out hour by hour in the place's own time. Its active alerts (winter storm warnings and the
 * like) come by point.
 */
import { localDate, localTime, type Sky } from "@jobly/core";
import { placeKey } from "./external";

// NWS asks every caller to say who it is; a key isn't needed.
const HEADERS = { "User-Agent": "Jobly (jobly.com)", Accept: "application/geo+json" };
const HOUR = 3_600_000;

async function ask<T>(url: string): Promise<T | null> {
  const response = await fetch(url, { headers: HEADERS, signal: AbortSignal.timeout(15_000) });
  if (response.status === 404) return null;
  if (!response.ok) throw new Error(`The National Weather Service returned ${response.status}`);
  return (await response.json()) as T;
}

interface Grid { url: string; timeZone: string }
/** Grid cells by place: null for a place outside the United States. A failed lookup isn't remembered. */
const grids = new Map<string, Promise<Grid | null>>();

function gridFor(lat: number, lng: number): Promise<Grid | null> {
  const key = placeKey(lat, lng);
  let found = grids.get(key);
  if (!found) {
    found = ask<{ properties?: { forecastGridData?: string; timeZone?: string } }>(`https://api.weather.gov/points/${lat.toFixed(4)},${lng.toFixed(4)}`).then((point) =>
      point?.properties?.forecastGridData && point.properties.timeZone ? { url: point.properties.forecastGridData, timeZone: point.properties.timeZone } : null,
    );
    grids.set(key, found);
    found.catch(() => grids.delete(key));
    // shortcut: every place ever asked about stays in memory, a few hundred bytes each; cap it if one server comes to hold hundreds of thousands.
  }
  return found;
}

interface Layer { values: Array<{ validTime: string; value: number | null }> }
interface WeatherLayer { values: Array<{ validTime: string; value: Array<{ coverage: string | null; weather: string | null }> }> }
interface GridData {
  properties?: {
    temperature?: Layer; apparentTemperature?: Layer; snowfallAmount?: Layer; iceAccumulation?: Layer; windSpeed?: Layer; windGust?: Layer;
    windDirection?: Layer; probabilityOfPrecipitation?: Layer; skyCover?: Layer; weather?: WeatherLayer;
  };
}

/** "2026-11-14T06:00:00+00:00/PT6H" as the hours it covers (UTC, in milliseconds). */
function hoursIn(validTime: string): number[] {
  const [start, length] = validTime.split("/");
  const span = /^P(?:(\d+)D)?(?:T(?:(\d+)H)?)?/.exec(length ?? "");
  const count = Math.max(1, Number(span?.[1] ?? 0) * 24 + Number(span?.[2] ?? 0));
  const first = Date.parse(start ?? "");
  return Number.isNaN(first) ? [] : Array.from({ length: count }, (_, i) => first + i * HOUR);
}

/** A layer hour by hour. An amount (snow, ice) is spread evenly over the hours it fell in. */
function byHour(layer: Layer | undefined, amount = false): Map<number, number> {
  const hours = new Map<number, number>();
  for (const { validTime, value } of layer?.values ?? []) {
    if (value == null) continue;
    const covered = hoursIn(validTime);
    for (const hour of covered) hours.set(hour, amount ? value / covered.length : value);
  }
  return hours;
}

const fahrenheit = (c: number | undefined) => (c == null ? null : Math.round((c * 9) / 5 + 32));
const mph = (kmh: number | undefined) => (kmh == null ? null : Math.round(kmh / 1.609344));
const inchesOf = (mm: number | undefined) => (mm ?? 0) / 25.4;

/**
 * The forecasters' words for the weather ("snow_showers", "freezing_rain", "freezing_fog"...), or
 * failing those how much of the sky is cloud. Freezing rain, freezing drizzle and sleet are ice
 * falling; freezing fog and ice fog are fog, and ice crystals and frost are neither.
 */
function skyOf(kinds: string[], cover: number | undefined): Sky {
  const has = (...words: string[]) => kinds.some((k) => words.some((word) => k.includes(word)));
  if (has("thunder", "hail")) return "storm";
  if (has("freezing_rain", "freezing_drizzle", "sleet")) return "freezing_rain";
  if (has("snow")) return "snow";
  if (has("drizzle")) return "drizzle";
  if (has("rain")) return "rain";
  if (has("fog")) return "fog";
  return cover == null || cover < 25 ? "clear" : cover < 65 ? "partly_cloudy" : "cloudy";
}

export interface NwsHour {
  /** The place's own time, as "2026-11-14T18:00". */
  time: string;
  night: boolean;
  temp_f: number | null;
  feels_f: number | null;
  sky: Sky;
  snow_in: number;
  ice_in: number;
  rain_chance_pct: number | null;
  wind_mph: number | null;
  gust_mph: number | null;
  wind_from_deg: number | null;
}

/** The cell's forecast hour by hour from this hour on, in the place's own time. */
function hoursOf(data: GridData, timeZone: string, now: Date): NwsHour[] {
  const p = data.properties ?? {};
  const temperature = byHour(p.temperature);
  const feels = byHour(p.apparentTemperature);
  const snow = byHour(p.snowfallAmount, true);
  const ice = byHour(p.iceAccumulation, true);
  const wind = byHour(p.windSpeed);
  const gust = byHour(p.windGust);
  const direction = byHour(p.windDirection);
  const chance = byHour(p.probabilityOfPrecipitation);
  const cover = byHour(p.skyCover);
  // Weather that's only a chance isn't the sky's picture; what's likely, or already has snow or ice forecast, is.
  const kinds = new Map<number, string[]>();
  for (const { validTime, value } of p.weather?.values ?? []) {
    const sure = value.filter((w) => w.weather && w.coverage !== "chance" && w.coverage !== "slight_chance").map((w) => w.weather!);
    const maybe = value.filter((w) => w.weather).map((w) => w.weather!);
    for (const hour of hoursIn(validTime)) kinds.set(hour, (snow.get(hour) ?? 0) > 0 || (ice.get(hour) ?? 0) > 0 ? maybe : sure);
  }
  const first = Math.floor(now.getTime() / HOUR) * HOUR;
  const last = Math.max(...temperature.keys());
  const hours: NwsHour[] = [];
  for (let hour = first; hour <= last; hour += HOUR) {
    if (!temperature.has(hour)) continue;
    const at = new Date(hour);
    const clock = Number(localTime(at, timeZone).slice(0, 2));
    hours.push({
      time: `${localDate(at, timeZone)}T${String(clock).padStart(2, "0")}:00`,
      // shortcut: night by the clock (before 7am, from 6pm), not by sunrise and sunset; it only picks the sun or the moon in a picture.
      night: clock < 7 || clock >= 18,
      temp_f: fahrenheit(temperature.get(hour)),
      feels_f: fahrenheit(feels.get(hour) ?? temperature.get(hour)),
      sky: skyOf(kinds.get(hour) ?? [], cover.get(hour)),
      snow_in: Math.round(inchesOf(snow.get(hour)) * 100) / 100,
      ice_in: Math.round(inchesOf(ice.get(hour)) * 100) / 100,
      rain_chance_pct: chance.has(hour) ? Math.round(chance.get(hour)!) : null,
      wind_mph: mph(wind.get(hour)),
      gust_mph: mph(gust.get(hour) ?? wind.get(hour)),
      wind_from_deg: direction.has(hour) ? Math.round(direction.get(hour)!) : null,
    });
  }
  return hours;
}

/** The place's forecast hour by hour, or null where the Weather Service has none (outside the United States). */
export async function nwsHours(lat: number, lng: number, now = new Date()): Promise<NwsHour[] | null> {
  const grid = await gridFor(lat, lng);
  if (!grid) return null;
  const data = await ask<GridData>(grid.url);
  const hours = data ? hoursOf(data, grid.timeZone, now) : [];
  return hours.length ? hours : null;
}

/** An official alert in force somewhere a snow customer is. */
export interface WinterAlert {
  id: string;
  /** "Winter Storm Warning" */
  event: string;
  headline: string;
  area: string;
  severity: string;
  /** When it ends, as an instant, when the alert says. */
  ends: string | null;
  description: string;
}

/** The events snow work cares about: winter weather, ice and the cold wind that drifts snow. */
const WINTER = /winter|snow|blizzard|ice storm|freezing|sleet|wind chill|extreme cold|frost|freeze/i;

/** The winter alerts in force at a place; none outside the United States. */
export async function nwsAlerts(lat: number, lng: number): Promise<WinterAlert[]> {
  const found = await ask<{ features?: Array<{ properties?: { id?: string; event?: string; headline?: string; areaDesc?: string; severity?: string; ends?: string | null; expires?: string | null; description?: string } }> }>(
    `https://api.weather.gov/alerts/active?point=${lat.toFixed(4)},${lng.toFixed(4)}`,
  ).catch(() => null);
  return (found?.features ?? []).flatMap(({ properties: a }) =>
    a?.id && a.event && WINTER.test(a.event)
      ? [{ id: a.id, event: a.event, headline: a.headline ?? a.event, area: a.areaDesc ?? "", severity: a.severity ?? "", ends: a.ends ?? a.expires ?? null, description: (a.description ?? "").slice(0, 4000) }]
      : [],
  );
}
