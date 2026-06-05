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

### Dependency-injection registration correctness (startup-breaking — weight `high`)

A wrong DI registration compiles fine and throws only at startup or first resolve, so
check the diff's `Program.cs`/service-registration lines against how the type is consumed:

- **`AddDbContextFactory<TContext>` does NOT register `TContext` itself**, only
  `IDbContextFactory<TContext>`. If anything still constructor-injects `TContext`
  directly, it throws `InvalidOperationException: Unable to resolve service for type …`.
  Switching `AddDbContext` → `AddDbContextFactory` (or vice-versa) without updating every
  consumer is a startup break. Register both (`AddDbContext` + `AddDbContextFactory`) if
  both injection styles are used.
- **Lifetime / captive-dependency mismatch:** a singleton (or the factory used by one)
  injecting a scoped service like a `DbContext`; `AddDbContext` is scoped by default and
  cannot be injected into a singleton — that's why a singleton resolver needs the factory.
- **Missing registration / duplicate or conflicting registration** for a service the diff
  newly injects; interface registered but the diff injects the concrete type (or vice
  versa); `TryAdd*` vs `Add*` changing which implementation wins.
