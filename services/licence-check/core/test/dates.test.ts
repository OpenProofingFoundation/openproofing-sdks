import assert from "node:assert/strict";
import { it } from "node:test";
import { isCalendarDate, isDateTime } from "../src/index.js";

it("validates calendar days including early years without Date.UTC's 1900 offset", () => {
  for (const value of ["0001-01-01", "0099-12-31", "2000-02-29"]) assert.equal(isCalendarDate(value), true, value);
  for (const value of ["1900-02-29", "2026-02-30", "2026-00-01"]) assert.equal(isCalendarDate(value), false, value);
});
it("rejects normalized time overflow and non-string completion values", () => {
  for (const value of ["2026-10-11T24:00:00Z", "2026-02-30T12:00:00Z", "2026-10-11T12:60:00Z",
    "2026-10-11T12:00:60Z", "2026-10-11T12:00:00+24:00", null, 1234])
    assert.equal(isDateTime(value), false, String(value));
  assert.equal(isDateTime("2026-10-11T12:00:00.123+05:30"), true);
});
