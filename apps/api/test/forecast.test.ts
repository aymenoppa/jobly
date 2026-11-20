/**
 * Forecasts (services/forecast.ts, services/nws.ts): each source's answer turned into the app's own
 * shape, which source is asked, and what happens when it has nothing. Open-Meteo and the National
 * Weather Service are stand-ins here: fetch is stubbed.
 */
import { afterEach, describe, expect, it, vi } from "vitest";
import { checkOpenMeteoKey, dailyOutlook, placeWeather, placeWeathers, snowFallen, snowToday, winterAlerts } from "../src/services/forecast";

afterEach(() => vi.unstubAllGlobals());

/** Stub fetch: `answer` returns a Response, or a body to send back as JSON. The requests come back. */
function serve(answer: (url: URL) => Response | unknown) {
  const asked: URL[] = [];
  vi.stubGlobal("fetch", async (input: RequestInfo | URL) => {
    const url = new URL(String(input));
    asked.push(url);
    const out = answer(url);
    return out instanceof Response ? out : Response.json(out);
  });
  return asked;
}

// Two days of hours from midnight; it's 9:30pm on the first. Snow at noon, 8pm and 10pm today and 3am tomorrow.
const hours = ["2026-01-15", "2026-01-16"].flatMap((d) => Array.from({ length: 24 }, (_, h) => `${d}T${String(h).padStart(2, "0")}:00`));
const at = (values: Record<string, number>, otherwise: number) => hours.map((t) => values[t] ?? otherwise);
const openMeteo = {
  current: { time: "2026-01-15T21:30", temperature_2m: 30.6, apparent_temperature: 21.4, weather_code: 73, wind_speed_10m: 11.2, wind_gusts_10m: 24.6, wind_direction_10m: 315, snow_depth: 0.5, is_day: 0 },
  hourly: {
    time: hours,
    temperature_2m: at({}, 30.4),
    weather_code: at({ "2026-01-15T22:00": 73, "2026-01-16T03:00": 66, "2026-01-16T12:00": 2 }, 3),
    snowfall: at({ "2026-01-15T12:00": 2, "2026-01-15T20:00": 0.4, "2026-01-15T22:00": 0.6, "2026-01-16T03:00": 1.25 }, 0),
    precipitation_probability: at({}, 80),
    wind_speed_10m: at({}, 10),
    wind_gusts_10m: at({}, 22),
    is_day: hours.map((t) => (Number(t.slice(11, 13)) >= 7 && Number(t.slice(11, 13)) < 17 ? 1 : 0)),
  },
  daily: { time: ["2026-01-15", "2026-01-16"], weather_code: [73, 71], temperature_2m_min: [19.6, 22], temperature_2m_max: [31.2, 34], snowfall_sum: [3, 1.25], precipitation_probability_max: [90, 60], wind_speed_10m_max: [14, 9], wind_gusts_10m_max: [31, 18] },
};

describe("Open-Meteo", () => {
  it("gives now, the hours from this one on and the days, in the app's words and units", async () => {
    const asked = serve(() => openMeteo);
    const w = await placeWeather(40.588, -111.638);
    expect([asked[0]!.host, asked[0]!.searchParams.get("latitude"), asked[0]!.searchParams.get("precipitation_unit"), asked[0]!.searchParams.get("temperature_unit"), asked[0]!.searchParams.get("wind_speed_unit"), asked[0]!.searchParams.get("apikey")])
      .toEqual(["api.open-meteo.com", "40.5880", "inch", "fahrenheit", "mph", null]);
    expect(w.source).toBe("open_meteo");
    // Half a foot of snow on the ground is 6 inches.
    expect(w.now).toEqual({ time: "2026-01-15T21:30", night: true, temp_f: 31, feels_f: 21, sky: "snow", wind_mph: 11, gust_mph: 25, wind_from_deg: 315, snow_depth_in: 6 });
    // The hours start with this one (9pm), not at midnight, and run to the end of what there is.
    expect(w.hours[0]).toMatchObject({ time: "2026-01-15T21:00", night: true, temp_f: 30, sky: "cloudy", snow_in: 0 });
    expect(w.hours).toHaveLength(27);
    expect(w.hours.filter((h) => h.snow_in > 0).map((h) => [h.time, h.sky, h.snow_in])).toEqual([["2026-01-15T22:00", "snow", 0.6], ["2026-01-16T03:00", "freezing_rain", 1.25]]);
    expect(w.days).toEqual([
      { date: "2026-01-15", sky: "snow", temp_min_f: 20, temp_max_f: 31, snow_in: 3, rain_chance_pct: 90, wind_max_mph: 14, gust_max_mph: 31 },
      { date: "2026-01-16", sky: "snow", temp_min_f: 22, temp_max_f: 34, snow_in: 1.3, rain_chance_pct: 60, wind_max_mph: 9, gust_max_mph: 18 },
    ]);
    // As the alerts count it: tomorrow is the snow from 6pm today on (0.4 + 0.6) plus tomorrow's own (1.25), not noon's 2.
    expect(w.snow_by_day["2026-01-16"]).toBe(2.25);
    // Weather rules read the same days, with that snow.
    expect((await dailyOutlook(40.588, -111.638, 2))[1]).toEqual({ date: "2026-01-16", temp_min_f: 22, temp_max_f: 34, rain_chance_pct: 60, wind_max_mph: 9, snow_in: 2.25 });
  });

  it("asks about a hundred places at a time, and leaves out a place it couldn't get rather than calling it clear", async () => {
    const places = Array.from({ length: 150 }, (_, i) => ({ lat: 30 + i * 0.05, lng: -100 }));
    const asked = serve((url) => (url.searchParams.get("latitude")!.split(",").length === 100 ? url.searchParams.get("latitude")!.split(",").map(() => openMeteo) : new Response("busy", { status: 429 })));
    expect((await placeWeathers(places)).size).toBe(100);
    expect(asked.map((u) => u.searchParams.get("latitude")!.split(",").length)).toEqual([100, 50]);
    await expect(placeWeather(30, -100)).rejects.toThrow("no forecast");
  });

  it("goes to the paid service, with the business's key, for a business that pays for it", async () => {
    const asked = serve(() => openMeteo);
    expect((await placeWeather(40.588, -111.638, { source: "open_meteo_commercial", key: "paid-key" })).source).toBe("open_meteo_commercial");
    expect([asked[0]!.host, asked[0]!.searchParams.get("apikey")]).toEqual(["customer-api.open-meteo.com", "paid-key"]);
  });

  it("says what fell on the last days, each counted from the evening before", async () => {
    const asked = serve(() => ({ hourly: { time: hours, snowfall: openMeteo.hourly.snowfall } }));
    const fallen = await snowFallen([{ lat: 40.588, lng: -111.638 }]);
    expect([asked[0]!.searchParams.get("past_days"), fallen.get("40.59,-111.64")]).toEqual(["2", { "2026-01-15": 3, "2026-01-16": 2.25, "2026-01-17": 0 }]);
  });

  it("adds up today's own storm: what has fallen since 6pm last night, and what the forecast still has coming by 6pm tonight", async () => {
    // It's 9:30pm on the 15th in the forecast above: 0.4 at 8pm has fallen for the 16th's storm, 0.6 at 10pm and 1.25 at 3am are coming.
    const asked = serve(() => openMeteo);
    const weather = await placeWeathers([{ lat: 40.59, lng: -111.64 }]);
    expect(Object.fromEntries(await snowToday([{ lat: 40.59, lng: -111.64 }], weather, "2026-01-16"))).toEqual({ "40.59,-111.64": 2.25 });
    // The look back is one day, and the snow at noon on the 15th, before 6pm, is the 15th's own.
    expect(asked.at(-1)!.searchParams.get("past_days")).toBe("1");
    expect(Object.fromEntries(await snowToday([{ lat: 40.59, lng: -111.64 }], weather, "2026-01-15"))).toEqual({ "40.59,-111.64": 2 });
    // The look back fails: what's coming still counts. A place with no forecast isn't answered for.
    serve((url) => (url.searchParams.has("past_days") ? new Response("busy", { status: 429 }) : openMeteo));
    expect(Object.fromEntries(await snowToday([{ lat: 40.59, lng: -111.64 }, { lat: 1, lng: 1 }], weather, "2026-01-16"))).toEqual({ "40.59,-111.64": 1.85 });
  });

  it("checks a pasted key, and says in plain words what's wrong with one that doesn't work", async () => {
    serve(() => ({ current: {} }));
    expect(await checkOpenMeteoKey("good-key-123")).toBeNull();
    serve(() => Response.json({ reason: "The supplied API key is invalid.", error: true }, { status: 400 }));
    expect(await checkOpenMeteoKey("bad-key-1234")).toMatch(/doesn't recognize that key/);
    vi.stubGlobal("fetch", async () => { throw new Error("offline"); });
    expect(await checkOpenMeteoKey("good-key-123")).toMatch(/couldn't be reached/);
  });
});

describe("the National Weather Service", () => {
  // The forecast for a cell in Utah (UTC-7), issued for 2026-01-16 02:00 UTC on: 7pm on the 15th there.
  const point = { properties: { forecastGridData: "https://api.weather.gov/gridpoints/SLC/108,167", timeZone: "America/Denver" } };
  const grid = {
    properties: {
      temperature: { values: [{ validTime: "2026-01-16T02:00:00+00:00/PT6H", value: 0 }, { validTime: "2026-01-16T08:00:00+00:00/PT30H", value: -5 }] },
      apparentTemperature: { values: [{ validTime: "2026-01-16T02:00:00+00:00/P1DT12H", value: -10 }] },
      // 76.2 mm (3 in) over six hours from 11pm local: half an inch an hour.
      snowfallAmount: { values: [{ validTime: "2026-01-16T06:00:00+00:00/PT6H", value: 76.2 }] },
      iceAccumulation: { values: [{ validTime: "2026-01-16T14:00:00+00:00/PT1H", value: 2.54 }] },
      windSpeed: { values: [{ validTime: "2026-01-16T02:00:00+00:00/P1DT12H", value: 16.09344 }] },
      windGust: { values: [{ validTime: "2026-01-16T02:00:00+00:00/P1DT12H", value: 48.28032 }] },
      windDirection: { values: [{ validTime: "2026-01-16T02:00:00+00:00/P1DT12H", value: 160 }] },
      probabilityOfPrecipitation: { values: [{ validTime: "2026-01-16T02:00:00+00:00/P1DT12H", value: 70 }] },
      skyCover: { values: [{ validTime: "2026-01-16T02:00:00+00:00/P1DT12H", value: 90 }] },
      weather: {
        values: [
          { validTime: "2026-01-16T02:00:00+00:00/PT4H", value: [{ coverage: "chance", weather: "snow" }] },
          { validTime: "2026-01-16T06:00:00+00:00/PT6H", value: [{ coverage: "likely", weather: "snow" }] },
          { validTime: "2026-01-16T20:00:00+00:00/PT2H", value: [{ coverage: "patchy", weather: "freezing_fog" }] },
          { validTime: "2026-01-17T10:00:00+00:00/PT1H", value: [{ coverage: "likely", weather: "freezing_drizzle" }] },
        ],
      },
    },
  };
  const nws = (url: URL) => (url.pathname.startsWith("/points/") ? point : url.pathname.startsWith("/gridpoints/") ? grid : undefined);

  it("lays its forecast out hour by hour in the place's own time, in the app's units", async () => {
    vi.useFakeTimers({ toFake: ["Date"], now: new Date("2026-01-16T02:20:00Z") });
    const asked = serve((url) => nws(url) ?? new Response("no", { status: 500 }));
    const w = await placeWeather(40.61, -111.61, { source: "nws" });
    vi.useRealTimers();
    expect(asked.map((u) => u.host + u.pathname)).toEqual(["api.weather.gov/points/40.6100,-111.6100", "api.weather.gov/gridpoints/SLC/108,167"]);
    expect(w.source).toBe("nws");
    // 0°C, 10 mph gusting 30 from the south-southeast; only a chance of snow isn't the sky's picture.
    expect(w.now).toEqual({ time: "2026-01-15T19:00", night: true, temp_f: 32, feels_f: 14, sky: "cloudy", wind_mph: 10, gust_mph: 30, wind_from_deg: 160, snow_depth_in: null });
    expect(w.hours.filter((h) => h.snow_in > 0).map((h) => [h.time, h.snow_in, h.sky])).toEqual([
      ["2026-01-15T23:00", 0.5, "snow"], ["2026-01-16T00:00", 0.5, "snow"], ["2026-01-16T01:00", 0.5, "snow"], ["2026-01-16T02:00", 0.5, "snow"], ["2026-01-16T03:00", 0.5, "snow"], ["2026-01-16T04:00", 0.5, "snow"],
    ]);
    // Ice in the forecast is freezing rain, whatever the hour's words; so is freezing drizzle.
    expect(w.hours.find((h) => h.time === "2026-01-16T07:00")!.sky).toBe("freezing_rain");
    expect(w.hours.find((h) => h.time === "2026-01-17T03:00")!.sky).toBe("freezing_rain");
    // Freezing fog is fog: nothing falls, and nobody is warned of ice for it.
    expect(w.hours.find((h) => h.time === "2026-01-16T13:00")!.sky).toBe("fog");
    // The storm from 11pm is all tomorrow's, as the alerts count it. (It's still 32° at midnight.)
    expect([w.snow_by_day["2026-01-15"], w.snow_by_day["2026-01-16"]]).toEqual([0.5, 3]);
    expect(w.days[1]).toMatchObject({ date: "2026-01-16", sky: "snow", temp_min_f: 23, temp_max_f: 32, snow_in: 2.5, rain_chance_pct: 70, wind_max_mph: 10, gust_max_mph: 30 });
  });

  it("falls back to Open-Meteo where the Weather Service has nothing: outside the United States, or while it's down", async () => {
    const asked = serve((url) => (url.host === "api.weather.gov" ? new Response("not found", { status: 404 }) : openMeteo));
    expect((await placeWeather(51.5, -0.12, { source: "nws" })).source).toBe("open_meteo");
    expect(asked.map((u) => u.host)).toEqual(["api.weather.gov", "api.open-meteo.com"]);
    serve((url) => (url.host === "api.weather.gov" ? new Response("down", { status: 503 }) : openMeteo));
    expect((await placeWeather(44.27, -71.3, { source: "nws" })).source).toBe("open_meteo");
  });

  it("gives the winter alerts in force where the customers are, once each", async () => {
    const alert = (id: string, event: string) => ({ properties: { id, event, headline: `${event} until 6 PM`, areaDesc: "Wasatch Mountains", severity: "Severe", ends: "2026-01-17T01:00:00+00:00", description: "Heavy snow." } });
    const asked = serve(() => ({ features: [alert("a1", "Winter Storm Warning"), alert("a2", "Air Quality Alert")] }));
    // Two customers a mile apart are one question; one fifty miles off is another.
    const alerts = await winterAlerts([{ lat: 40.588, lng: -111.638 }, { lat: 40.6, lng: -111.65 }, { lat: 41.3, lng: -111.6 }]);
    expect(asked.map((u) => u.searchParams.get("point"))).toEqual(["40.6000,-111.6500", "41.3000,-111.6000"]);
    expect(alerts).toEqual([{ id: "a1", event: "Winter Storm Warning", headline: "Winter Storm Warning until 6 PM", area: "Wasatch Mountains", severity: "Severe", ends: "2026-01-17T01:00:00+00:00", description: "Heavy snow." }]);
  });
});
