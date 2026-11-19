/**
 * Forecasts, from whichever source the business chose (Settings → Weather rules): the US National
 * Weather Service (the default; services/nws.ts: free for any use, United States only), Open-Meteo's
 * free service (its terms keep it to non-commercial use), or Open-Meteo with the business's own
 * paid key (Apps → Open-Meteo). Whatever the source, callers get the app's own shapes (PlaceWeather,
 * DayOutlook), so nothing else knows whose forecast it is. A place the chosen source has nothing
 * for (the Weather Service outside the United States, or while it's down) gets Open-Meteo's.
 */
import { addDays, weatherSourceOf, type DayOutlook, type PlaceWeather, type Sky, type WeatherSource } from "@jobly/core";
import type { Env } from "../env";
import { loadSecret } from "../integrations/tokens";
import type { Db } from "../lib/supabase";
import { placeKey } from "./external";
import { nwsAlerts, nwsHours, type NwsHour, type WinterAlert } from "./nws";

/** A business's source, with its Open-Meteo key when it pays for one. */
export interface Forecaster { source: WeatherSource; key?: string }
export const FREE: Forecaster = { source: "open_meteo" };

/** The business's forecast source. Open-Meteo's paid service with no key on file is the free one. */
export async function forecasterFor(env: Env, admin: Db, companyId: string, settings: unknown): Promise<Forecaster> {
  const source = weatherSourceOf(settings);
  if (source !== "open_meteo_commercial") return { source };
  const key = (await loadSecret(env, admin, companyId, "open_meteo").catch(() => null))?.api_key;
  return key ? { source, key } : FREE;
}

const round = (n: number | null | undefined, places = 0) => (n == null ? null : Math.round(n * 10 ** places) / 10 ** places);
const highest = (numbers: Array<number | null>) => numbers.reduce<number | null>((top, n) => (n != null && (top == null || n > top) ? n : top), null);
const lowest = (numbers: Array<number | null>) => numbers.reduce<number | null>((low, n) => (n != null && (low == null || n < low) ? n : low), null);

/** The hour of the evening a day's snow is counted from. */
const SNOW_DAY_STARTS = 18;

/**
 * Inches of snow for each day, from 6pm the evening before through the day itself: a storm that
 * comes in overnight is one storm for the morning's plowing, not two halves on two dates. The first
 * day in a forecast has no evening before it, so it's that day's own snow.
 */
export function snowByDay(hours: Array<{ time: string; snow_in: number }>): Record<string, number> {
  const days: Record<string, number> = {};
  for (const { time, snow_in: inches } of hours) {
    const date = time.slice(0, 10);
    days[date] = (days[date] ?? 0) + inches;
    if (Number(time.slice(11, 13)) >= SNOW_DAY_STARTS) days[addDays(date, 1)] = (days[addDays(date, 1)] ?? 0) + inches;
  }
  for (const date of Object.keys(days)) days[date] = round(days[date], 2)!;
  return days;
}

// ---------------------------------------------------------------------------------------------
// Open-Meteo
// ---------------------------------------------------------------------------------------------

const OPEN_METEO = "https://api.open-meteo.com/v1/forecast";
/** The paid service: the same questions and answers, at its own address, with the customer's key. */
const OPEN_METEO_PAID = "https://customer-api.open-meteo.com/v1/forecast";

interface OpenMeteoPlace {
  current?: { time: string; temperature_2m?: number; apparent_temperature?: number; weather_code?: number; wind_speed_10m?: number; wind_gusts_10m?: number; wind_direction_10m?: number; snow_depth?: number; is_day?: number };
  hourly?: { time: string[]; temperature_2m?: Array<number | null>; weather_code?: Array<number | null>; snowfall?: Array<number | null>; precipitation_probability?: Array<number | null>; wind_speed_10m?: Array<number | null>; wind_gusts_10m?: Array<number | null>; is_day?: Array<number | null> };
  daily?: { time: string[]; weather_code?: Array<number | null>; temperature_2m_min?: Array<number | null>; temperature_2m_max?: Array<number | null>; snowfall_sum?: Array<number | null>; precipitation_probability_max?: Array<number | null>; wind_speed_10m_max?: Array<number | null>; wind_gusts_10m_max?: Array<number | null> };
}

/** Open-Meteo's forecast for these places, in the order asked: one request however many there are. */
async function openMeteo(places: Array<{ lat: number; lng: number }>, days: number, key?: string, pastDays = 0): Promise<OpenMeteoPlace[]> {
  const params = new URLSearchParams({
    latitude: places.map((p) => p.lat.toFixed(4)).join(","),
    longitude: places.map((p) => p.lng.toFixed(4)).join(","),
    current: "temperature_2m,apparent_temperature,weather_code,wind_speed_10m,wind_gusts_10m,wind_direction_10m,snow_depth,is_day",
    hourly: "temperature_2m,weather_code,snowfall,precipitation_probability,wind_speed_10m,wind_gusts_10m,is_day",
    daily: "weather_code,temperature_2m_min,temperature_2m_max,snowfall_sum,precipitation_probability_max,wind_speed_10m_max,wind_gusts_10m_max",
    temperature_unit: "fahrenheit",
    precipitation_unit: "inch", // snowfall in inches too
    wind_speed_unit: "mph",
    timezone: "auto",
    forecast_days: String(days),
    ...(pastDays ? { past_days: String(pastDays) } : {}),
    ...(key ? { apikey: key } : {}),
  });
  const response = await fetch(`${key ? OPEN_METEO_PAID : OPEN_METEO}?${params}`, { signal: AbortSignal.timeout(15_000) });
  if (!response.ok) throw new Error(`Open-Meteo returned ${response.status}`);
  // One place comes back by itself, several as a list.
  const body = (await response.json()) as OpenMeteoPlace | OpenMeteoPlace[];
  return Array.isArray(body) ? body : [body];
}

/** A WMO weather code, as Open-Meteo gives it, in the app's words. */
function skyOf(code: number | null | undefined): Sky {
  if (code == null || code <= 1) return "clear";
  if (code === 2) return "partly_cloudy";
  if (code === 45 || code === 48) return "fog";
  if (code >= 51 && code <= 55) return "drizzle";
  if (code === 56 || code === 57 || code === 66 || code === 67) return "freezing_rain";
  if ((code >= 61 && code <= 65) || (code >= 80 && code <= 82)) return "rain";
  if ((code >= 71 && code <= 77) || code === 85 || code === 86) return "snow";
  if (code >= 95) return "storm";
  return "cloudy";
}

/** Open-Meteo's answer for a place as the app's own, or null when it has no days in it. */
function fromOpenMeteo({ current, hourly, daily }: OpenMeteoPlace, source: WeatherSource): PlaceWeather | null {
  if (!daily?.time) return null;
  const all = (hourly?.time ?? []).map((time, i) => ({
    time,
    night: hourly!.is_day?.[i] === 0,
    temp_f: round(hourly!.temperature_2m?.[i]),
    sky: skyOf(hourly!.weather_code?.[i]),
    snow_in: round(hourly!.snowfall?.[i] ?? 0, 2)!,
    rain_chance_pct: hourly!.precipitation_probability?.[i] ?? null,
    wind_mph: round(hourly!.wind_speed_10m?.[i]),
    gust_mph: round(hourly!.wind_gusts_10m?.[i]),
  }));
  // The hours start at midnight today: what's shown starts with the hour it is now.
  const first = current ? Math.max(0, all.findIndex((h) => h.time >= `${current.time.slice(0, 13)}:00`)) : 0;
  return {
    source,
    now: {
      time: current?.time ?? all[0]?.time ?? `${daily.time[0]}T00:00`,
      night: current?.is_day === 0,
      temp_f: round(current?.temperature_2m),
      feels_f: round(current?.apparent_temperature),
      sky: skyOf(current?.weather_code),
      wind_mph: round(current?.wind_speed_10m),
      gust_mph: round(current?.wind_gusts_10m),
      wind_from_deg: round(current?.wind_direction_10m),
      // With inches asked for, the snow on the ground comes in feet.
      snow_depth_in: current?.snow_depth == null ? null : round(current.snow_depth * 12, 1),
    },
    hours: all.slice(first, first + 48),
    days: daily.time.map((date, i) => ({
      date,
      sky: skyOf(daily.weather_code?.[i]),
      temp_min_f: round(daily.temperature_2m_min?.[i]),
      temp_max_f: round(daily.temperature_2m_max?.[i]),
      snow_in: round(daily.snowfall_sum?.[i] ?? 0, 1)!,
      rain_chance_pct: daily.precipitation_probability_max?.[i] ?? null,
      wind_max_mph: round(daily.wind_speed_10m_max?.[i]),
      gust_max_mph: round(daily.wind_gusts_10m_max?.[i]),
    })),
    snow_by_day: snowByDay(all),
  };
}

/** Whether an Open-Meteo key works: null when it does, otherwise what to tell the person who pasted it. */
export async function checkOpenMeteoKey(key: string, fetcher: typeof fetch = fetch): Promise<string | null> {
  const response = await fetcher(`${OPEN_METEO_PAID}?latitude=40&longitude=-100&current=temperature_2m&apikey=${encodeURIComponent(key)}`, { signal: AbortSignal.timeout(10_000) }).catch(() => null);
  if (!response) return "Open-Meteo couldn't be reached to check the key. Try again in a minute.";
  if (response.ok) return null;
  return response.status === 400 || response.status === 401 || response.status === 403
    ? "Open-Meteo doesn't recognize that key. Copy it again from your Open-Meteo account: it comes with a paid plan."
    : `Open-Meteo couldn't check the key just now (it answered ${response.status}). Try again in a minute.`;
}

// ---------------------------------------------------------------------------------------------
// The National Weather Service's hours as the app's own
// ---------------------------------------------------------------------------------------------

/** What a day's weather mostly was: anything wintry or wet that lasts, else the usual sky. */
function daySky(hours: NwsHour[]): Sky {
  const count = (sky: Sky) => hours.filter((h) => h.sky === sky).length;
  for (const sky of ["storm", "freezing_rain", "snow", "rain", "drizzle", "fog"] as const) if (count(sky) >= 2) return sky;
  return (["cloudy", "partly_cloudy", "clear"] as const).reduce((most, sky) => (count(sky) > count(most) ? sky : most), "cloudy");
}

function fromNws(hours: NwsHour[]): PlaceWeather {
  // Ice in the forecast is freezing rain, whatever the forecasters' words for the hour.
  const icy = hours.map((h) => ({ ...h, sky: h.ice_in > 0 ? ("freezing_rain" as const) : h.sky }));
  const now = icy[0]!;
  const dates = [...new Set(icy.map((h) => h.time.slice(0, 10)))];
  return {
    source: "nws",
    // The Weather Service forecasts; what's on the ground it doesn't say.
    now: { time: now.time, night: now.night, temp_f: now.temp_f, feels_f: now.feels_f, sky: now.sky, wind_mph: now.wind_mph, gust_mph: now.gust_mph, wind_from_deg: now.wind_from_deg, snow_depth_in: null },
    hours: icy.slice(0, 48).map((h) => ({ time: h.time, night: h.night, temp_f: h.temp_f, sky: h.sky, snow_in: h.snow_in, rain_chance_pct: h.rain_chance_pct, wind_mph: h.wind_mph, gust_mph: h.gust_mph })),
    days: dates.map((date) => {
      const day = icy.filter((h) => h.time.startsWith(date));
      return {
        date,
        sky: daySky(day),
        temp_min_f: lowest(day.map((h) => h.temp_f)),
        temp_max_f: highest(day.map((h) => h.temp_f)),
        snow_in: round(day.reduce((total, h) => total + h.snow_in, 0), 1)!,
        rain_chance_pct: highest(day.map((h) => h.rain_chance_pct)),
        wind_max_mph: highest(day.map((h) => h.wind_mph)),
        gust_max_mph: highest(day.map((h) => h.gust_mph)),
      };
    }),
    snow_by_day: snowByDay(icy),
  };
}

// ---------------------------------------------------------------------------------------------
// What callers ask for
// ---------------------------------------------------------------------------------------------

/** How many places go in one Open-Meteo request: its address stays well under what servers accept. */
const PLACES_PER_REQUEST = 100;
/** How many places are asked of the Weather Service at once: it takes one a request and doesn't say what its limit is. */
const NWS_AT_ONCE = 4;

/**
 * The weather at many places, by placeKey, for `days` days. A place whose forecast couldn't be had
 * (an outage, a rate limit) is left out, which isn't a clear sky: callers check again later.
 */
export async function placeWeathers(places: Array<{ lat: number; lng: number }>, forecaster: Forecaster = FREE, days = 3): Promise<Map<string, PlaceWeather>> {
  const unique = [...new Map(places.map((p) => [placeKey(p.lat, p.lng), p])).entries()];
  const found = new Map<string, PlaceWeather>();
  let rest = unique;
  if (forecaster.source === "nws") {
    rest = [];
    for (let i = 0; i < unique.length; i += NWS_AT_ONCE) {
      await Promise.all(
        unique.slice(i, i + NWS_AT_ONCE).map(async ([key, place]) => {
          const hours = await nwsHours(place.lat, place.lng).catch(() => null);
          if (hours) found.set(key, fromNws(hours));
          else rest.push([key, place]);
        }),
      );
    }
  }
  const paid = forecaster.source === "open_meteo_commercial" ? forecaster.key : undefined;
  for (let i = 0; i < rest.length; i += PLACES_PER_REQUEST) {
    const batch = rest.slice(i, i + PLACES_PER_REQUEST);
    const answers = await openMeteo(batch.map(([, place]) => place), days, paid).catch(() => []);
    batch.forEach(([key], n) => {
      const weather = answers[n] && fromOpenMeteo(answers[n], paid ? "open_meteo_commercial" : "open_meteo");
      if (weather) found.set(key, weather);
    });
  }
  return found;
}

/** One place's weather in detail: now, the next 48 hours and up to 10 days. Throws when there's no forecast to be had. */
export async function placeWeather(lat: number, lng: number, forecaster: Forecaster = FREE): Promise<PlaceWeather> {
  const weather = (await placeWeathers([{ lat, lng }], forecaster, 10)).get(placeKey(lat, lng));
  // No forecast isn't good weather: callers treat this like a failed request.
  if (!weather) throw new Error("There's no forecast for that place right now");
  return weather;
}

/** A place's days as weather rules read them, with each day's snow counted from the evening before. */
export async function dailyOutlook(lat: number, lng: number, days = 7, forecaster: Forecaster = FREE): Promise<DayOutlook[]> {
  const weather = (await placeWeathers([{ lat, lng }], forecaster, days)).get(placeKey(lat, lng));
  if (!weather) throw new Error("There's no forecast for that place right now");
  return weather.days.map((d) => ({ date: d.date, temp_min_f: d.temp_min_f, temp_max_f: d.temp_max_f, rain_chance_pct: d.rain_chance_pct, wind_max_mph: d.wind_max_mph, snow_in: weather.snow_by_day[d.date] ?? null }));
}

/**
 * How much snow fell at these places on each of the last two days, by placeKey then date, each day
 * counted from 6pm the evening before as the alerts count it: the forecast's own estimate after
 * the fact, for the storm log. Always Open-Meteo's (with the business's key when it pays for one),
 * since it keeps the last days and the Weather Service only looks ahead.
 */
export async function snowFallen(places: Array<{ lat: number; lng: number }>, forecaster: Forecaster = FREE): Promise<Map<string, Record<string, number>>> {
  const unique = [...new Map(places.map((p) => [placeKey(p.lat, p.lng), p])).entries()];
  const paid = forecaster.source === "open_meteo_commercial" ? forecaster.key : undefined;
  const fallen = new Map<string, Record<string, number>>();
  for (let i = 0; i < unique.length; i += PLACES_PER_REQUEST) {
    const batch = unique.slice(i, i + PLACES_PER_REQUEST);
    const answers = await openMeteo(batch.map(([, place]) => place), 1, paid, 2).catch(() => []);
    batch.forEach(([key], n) => {
      const hourly = answers[n]?.hourly;
      if (hourly?.time) fallen.set(key, snowByDay(hourly.time.map((time, h) => ({ time, snow_in: hourly.snowfall?.[h] ?? 0 }))));
    });
  }
  return fallen;
}

/**
 * Today's own storm at each place, by placeKey: the snow from 6pm last night to 6pm tonight (after
 * that it's tomorrow's storm, which is told about on its own). What has fallen is Open-Meteo's
 * estimate after the fact, as in snowFallen, since the Weather Service only looks ahead; what's
 * still coming is the place's own forecast (`weather`, as placeWeathers gave it). A place Open-Meteo
 * doesn't answer for counts what's coming alone, and one with no forecast isn't in the answer.
 */
export async function snowToday(places: Array<{ lat: number; lng: number }>, weather: Map<string, PlaceWeather>, today: string, forecaster: Forecaster = FREE): Promise<Map<string, number>> {
  const from = `${addDays(today, -1)}T${SNOW_DAY_STARTS}:00`;
  const to = `${today}T${SNOW_DAY_STARTS}:00`;
  const unique = [...new Map(places.map((p) => [placeKey(p.lat, p.lng), p])).entries()].filter(([key]) => weather.has(key));
  const paid = forecaster.source === "open_meteo_commercial" ? forecaster.key : undefined;
  const totals = new Map<string, number>();
  for (let i = 0; i < unique.length; i += PLACES_PER_REQUEST) {
    const batch = unique.slice(i, i + PLACES_PER_REQUEST);
    const answers = await openMeteo(batch.map(([, place]) => place), 1, paid, 1).catch(() => []);
    batch.forEach(([key], n) => {
      const hours = weather.get(key)!.hours;
      // The forecast starts with the hour it is now: everything before that has fallen.
      const now = hours[0]?.time ?? to;
      const past = answers[n]?.hourly;
      const fallen = (past?.time ?? []).reduce((total, time, h) => (time >= from && time < now && time < to ? total + (past!.snowfall?.[h] ?? 0) : total), 0);
      const coming = hours.reduce((total, h) => (h.time >= from && h.time < to ? total + h.snow_in : total), 0);
      totals.set(key, round(fallen + coming, 2)!);
    });
  }
  return totals;
}

/**
 * The official winter alerts in force where these places are (winter storm warnings and the like),
 * from the National Weather Service whatever the business's forecast source: they're the
 * government's to give. One question for each stretch of about 15 miles, a dozen at most.
 */
export async function winterAlerts(places: Array<{ lat: number; lng: number }>): Promise<WinterAlert[]> {
  const areas = [...new Map(places.map((p) => [`${Math.round(p.lat * 4)},${Math.round(p.lng * 4)}`, p])).values()].slice(0, 12);
  const alerts = (await Promise.all(areas.map((p) => nwsAlerts(p.lat, p.lng)))).flat();
  return [...new Map(alerts.map((a) => [a.id, a])).values()];
}

export type { WinterAlert };
