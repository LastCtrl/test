# QA Report: result_симкарты_бд (v2).xlsx + filials/

**Date:** 2026-09-01  
**Reviewer:** qa-engineer  
**Verdict:** **ВОЗВРАТЬ** (REJECTED)

---

## Executive Summary

The v2 deliverable contains **8 critical/major bugs** that violate the acceptance criteria. The main issues are:
1. Wrong column order in key sheets (`src_host` not first)
2. Incorrect column prefixes (`[БД]`, `[1С]`) where clean names required
3. Summary totals mismatch (39567 vs 39568)
4. Missing breakdown tables in Summary
5. "Причина" column contains 60+ values instead of 2 expected
6. Filter metadata columns (`ВидТелефона`, `СпособНазначенияАйПи`, `ОператорСвязи`) contain garbage data

---

## Detailed Findings

### Main File: `result_симкарты_бд (v2).xlsx`

| # | Bug | Severity | Location | Expected | Actual |
|---|-----|----------|----------|----------|--------|
| 1 | **src_host not first column** | **critical** | «Совпадения» sheet | `src_host` in column 1 | Column 1 = `[1С] АйПиАдрес`; `src_host` at col 26 as `[БД] src_host` |
| 2 | **[БД] prefix on src_host** | **critical** | «Только в БД» sheet | `src_host` (clean) | Column 1 = `[БД] src_host` |
| 3 | **[1С] prefix on first column** | **major** | «Только в 1С» sheet | `src_host` / `АйПиАдрес` (clean) | Column 1 = `[1С] АйПиАдрес` |
| 4 | **Summary total mismatch** | **critical** | «Сводка» row 48 (ИТОГО) | Совпадения = 39568 | ИТОГО shows 39567 (off by 1) |
| 5 | **Missing breakdown: incorrect by PhoneType** | **major** | «Сводка» | Table for incorrect IPs grouped by ВидТелефона | Only Operator breakdown exists for incorrect |
| 6 | **Missing breakdown: incorrect by AssignmentMethod** | **major** | «Сводка» | Table for incorrect IPs grouped by СпособНазначенияАйПи | Missing |
| 7 | **Missing breakdown: by reasons (пусто/некорректный формат)** | **major** | «Сводка» | Table with counts for "пусто" vs "некорректный формат" | Missing |
| 8 | **Причина column has 60+ values** | **critical** | «Некорректные IP (1С)» col 18 | Only `пусто` / `некорректный формат` | 60+ values including device models, garbage, raw data |
| 9 | **СпособНазначенияАйПи has 16 values** | **major** | «Некорректные IP (1С)» col 10 | Only `Статический` / `пусто` | 16 values including filial names |
| 10 | **ОператорСвязи has 2529 values** | **major** | «Некорректные IP (1С)» col 11 | Operator names (МТС, А1, life:) | Filial names, dates, garbage, empty |

### Filials (16 files in `filials/`)

| # | Bug | Severity | Location | Expected | Actual |
|---|-----|----------|----------|----------|--------|
| 11 | **Incorrect IP sheet has 18 columns with [1С] prefix** | **major** | Each filial «Некорректные IP (1С)» | `АйПиАдрес \| Причина простая \| 1С поля` (no Raw, no prefixes) | 18 columns all `[1С] ...`, last col = `[1С] Причина` (not simplified) |
| 12 | **No "Причина простая" simplification in filials** | **major** | Each filial «Некорректные IP (1С)» | Simple reason: `пусто` / `некорректный формат` | Same 60+ values as main file |

---

## Acceptance Criteria Checklist

### Main File

| Check | Status | Notes |
|-------|--------|-------|
| «Некорректные IP (1С)» - 8321 rows | ✅ PASS | 8321 data rows confirmed |
| Columns: АйПиАдрес \| Причина \| остальные 1С | ❌ FAIL | All cols have `[1С]` prefix; Причина not simplified |
| Freeze 2 columns | ✅ PASS | xSplit=2.0 confirmed |
| No Белтелеком | ✅ PASS | Not found in ОператорСвязи |
| ВидТелефона ∈ {Мобильный, Сим карта, пусто} | ✅ PASS | Values: ``, `М1`, `Мобильный`, `Сим карта` |
| СпособНазначенияАйПи ∈ {Статический, пусто} | ❌ FAIL | 16 values including filial names |
| Причина простая (пусто/некорректный формат) | ❌ FAIL | 60+ values |
| «Совпадения (сгруппированные)» - 1109 rows | ✅ PASS | 1109 data rows confirmed |
| Columns: src_host \| filials \| count \| Описание | ✅ PASS | Correct, no prefix |
| «Совпадения» / «Только в 1С» / «Только в БД» - src_host first | ❌ FAIL | All three sheets violate this |
| «Сводка» - existing blocks | ✅ PASS | Present |
| «Сводка» - filial table with totals | ⚠️ PARTIAL | Totals row has mismatch (39567 vs 39568) |
| «Сводка» - 2 breakdown sets (correct + incorrect) | ❌ FAIL | Only correct has 3 breakdowns; incorrect only has Operator |
| «Сводка» - by reasons (пусто/некорректный формат) | ❌ FAIL | Missing |

### Filials (16 files)

| Check | Status | Notes |
|-------|--------|-------|
| 3 sheets per file | ✅ PASS | All 16 have: Группированные, Некорректные, Сводка |
| Only filials with data | ✅ PASS | All 16 have at least incorrect IPs |
| Same incorrect filter (norm: trim+lowercase) | ✅ PASS | Consistent with main |
| Причина простая: пусто / некорректный формат | ❌ FAIL | 60+ values in Причина column |
| «Совпадения (сгруппированные)» - src_host first, no [БД] | ✅ PASS | All 16 correct |
| «Некорректные IP (1С)» - no Raw, freeze 2 cols | ⚠️ PARTIAL | Freeze OK (xSplit=2), but 18 cols with [1С] prefix |
| «Сводка» simplified | ✅ PASS | Present |

---

## Root Cause Analysis

The bugs stem from **report_build_v2.js** not implementing the specification correctly:

1. **Column ordering**: The code writes 1C columns first, then DB columns with `[БД]` prefix, instead of putting `src_host` first without prefix.

2. **Prefix handling**: The `[1С]` and `[БД]` prefixes are added unconditionally. The spec requires clean column names for the primary key (`src_host`).

3. **SimplifyReason not working**: The `simplifyReason` function (mentioned in dev-1's commit) appears to not be applied, or the filter `passesIncorrectFilter` is not filtering correctly.

4. **Metadata columns not normalized**: `ВидТелефона`, `СпособНазначенияАйПи`, `ОператорСвязи` contain raw 1C values instead of normalized lookup values.

5. **Summary breakdown generation**: The `addBreakdownTable` helper only generates breakdowns for "correct" IPs (Matches + Only in 1C), not for "incorrect" IPs.

6. **Off-by-one in totals**: Likely a counting error in the summary aggregation (39567 vs 39568).

---

## Recommendations for Fix

1. **Reorder columns** in «Совпадения», «Только в 1С», «Только в БД» to put `src_host` first (clean name, no prefix).

2. **Remove `[БД]` prefix** from `src_host` in «Только в БД».

3. **Remove `[1С]` prefix** from first column in «Только в 1С» (or rename to `src_host`).

4. **Fix `simplifyReason`** to map all non-empty invalid formats to `некорректный формат`, empty to `пусто`.

5. **Normalize metadata columns** before writing: map `ВидТелефона` to `{Мобильный, Сим карта, пусто}`, `СпособНазначенияАйПи` to `{Статический, пусто}`, `ОператорСвязи` to known operators.

6. **Extend `addBreakdownTable`** to generate breakdowns for incorrect IPs by all 3 dimensions + by reasons.

7. **Fix summary totals** to match actual sheet row counts.

8. **Redesign filial «Некорректные IP (1С)»** to have only 3 column groups: `АйПиАдрес`, `Причина простая`, then selected 1C fields (no Raw, no prefixes).

---

## Files to Fix

- `report_build_v2.js` - main report generator
- `filials_build.js` - filial report generator (uses same helpers)

---

## Sign-off

**QA Engineer:** qa-engineer  
**Status:** **ВОЗВРАТЬ** — Fix all critical/major bugs and resubmit for re-review.