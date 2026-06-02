## Profile: ASP.NET Core / .NET 9 modernization

Treat this diff as a production-sensitive ASP.NET Core / .NET 9 modernization change.
In addition to the general goals above, weight these heavily where the diff touches them.

### Additional review goals

- Alignment with supported ASP.NET Core / .NET 9 practices.
- Legacy carryover / migration anti-patterns that should not remain.
- Rollback safety and maintainability/upgrade friction toward .NET 10 (these inform
  impact wording; they are not standalone findings).

### Prioritise findings affecting

startup/deployment safety · request pipeline · auth/authorization outcomes · exception
handling & observability · configuration binding & environment-specific behavior ·
dependency/package supportability · static/shared mutable state · infrastructure leakage
& tight coupling · obsolete/unsupported APIs.

### Migration-specific checks (where the diff touches them)

Minimal hosting model & `Program.cs` wiring · endpoint routing · middleware ordering
(esp. auth/authz placement) · `IOptions` / configuration binding · nullable reference
type implications · Native AOT risks · trimming risks · APIs deprecated/removed in
ASP.NET Core / .NET 9 · package support status for the target framework.
