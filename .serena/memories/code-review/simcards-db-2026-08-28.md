# Code Review: simcards+db modules

## Files reviewed
- `projects/симкарты+бд/db_read.js`
- `projects/симкарты+бд/report_build.js`

## Verdict: ВОЗВРАТЬ (REJECTED)

## Critical issues (must fix)
1. **Hardcoded node_modules paths** — `require('D:/Тест/pong-advanced/node_modules/xlsx')` breaks portability
2. **Excel date conversion bug** — Lotus 1-2-3 leap year bug not handled (dates after 1900-02-28 off by 1 day)
3. **Invalid Excel formulas in Summary sheet** — MATCH() returns column number, not cell reference; range syntax broken
4. **No try/catch for XLSX.readFile** — unhandled exceptions on corrupt/missing files

## Major issues
5. **OOM risk** — 184k rows all in memory before writeFile (user says 8GB heap OK but should be documented)
6. **Temp files cleanup only on success** — should use finally block
7. **AutoFilter breaks after column Z** — `String.fromCharCode(64+n)` fails for AA, AB...

## Minor issues
8. Code duplication in row building (4 nearly identical blocks)
9. Magic color strings instead of constants
10. Mixed logging styles (console.log vs log())
11. Missing JSDoc for exported functions
12. `dst_host` validation silent skip

## Ratings
- Readability: 6/10
- Security: 7/10
- Performance: 5/10
- Architecture: 5/10

## Next steps
Fix critical + major issues, then request re-review.